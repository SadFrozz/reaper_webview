// Reaper WebView Plugin
// (c) Andrew "SadFrozz" Brodsky
// 2025 and later
// webview_win.cpp
// Edge WebView2 for Windows implementation

#ifdef _WIN32

#define RWV_WITH_WEBVIEW2 1
#include "predef.h"

#include <shlwapi.h>
#include <direct.h>
#pragma comment(lib, "Shlwapi.lib")

#include "log.h"
#include "globals.h"
#include "helpers.h"
#include "webview.h"

// forward (panel layout kept in main.mm)
void LayoutTitleBarAndWebView(HWND hwnd, bool titleVisible);
// Forward declaration for updating find counters (implemented in main.mm)
void UpdateFindCounter(WebViewInstanceRecord* rec);

// Helper to escape a string for single-quoted JS literal
static std::wstring JSStringEscape(const std::string& s)
{
  std::wstring out; out.reserve(s.size());
  for (char c : s) {
    switch(c) {
      case '\\': out += L"\\\\"; break;
      case '\'': out += L"\\'"; break;
      case '\n': out += L"\\n"; break;
      case '\r': break; // skip
      default: out.push_back((wchar_t)(unsigned char)c); break;
    }
  }
  return out;
}

using Microsoft::WRL::Callback;

static HMODULE LoadWebView2Loader()
{
  HMODULE h = LoadLibraryA("WebView2Loader.dll");
  if (h) { LogRaw("LoadLibrary(WebView2Loader.dll) -> OK (default search)"); return h; }

  char mod[MAX_PATH]{};
  GetModuleFileNameA((HMODULE)g_hInst, mod, MAX_PATH);
  std::string dir = mod;
  auto p = dir.find_last_of("\\/"); if (p != std::string::npos) dir.resize(p);
  std::string full = dir + "\\WebView2Loader.dll";
  h = LoadLibraryA(full.c_str());
  if (h) { LogF("LoadLibrary -> OK (plugin dir): %s", full.c_str()); return h; }

  char exe[MAX_PATH]{};
  GetModuleFileNameA(NULL, exe, MAX_PATH);
  dir = exe; p = dir.find_last_of("\\/"); if (p != std::string::npos) dir.resize(p);
  full = dir + "\\WebView2Loader.dll";
  h = LoadLibraryA(full.c_str());
  if (h) { LogF("LoadLibrary -> OK (reaper.exe dir): %s", full.c_str()); return h; }

  DWORD gle = GetLastError();
  LogF("LoadLibrary(WebView2Loader.dll) FAILED, GetLastError=%lu", gle);
  return NULL;
}

void StartWebView(HWND hwnd, const std::string& initial_url)
{
  if (!g_com_initialized)
  {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    g_com_initialized = SUCCEEDED(hr);
    LogF("CoInitializeEx -> 0x%lX (ok=%d)", (long)hr, (int)g_com_initialized);
  }

  const char* res = GetResourcePath ? GetResourcePath() : nullptr;
  std::string base = (res && *res) ? std::string(res) : ".";
  std::string udf  = base + "\\WebView2Data";
  LogF("userDataFolder: %s", udf.c_str());
  _mkdir(udf.c_str());

  if (!g_hWebView2Loader)
  {
    g_hWebView2Loader = LoadWebView2Loader();
    LogF("LoadLibrary(WebView2Loader) -> %p", (void*)g_hWebView2Loader);
  }
  if (!g_hWebView2Loader) { LogRaw("FATAL: missing WebView2Loader.dll"); return; }

  using PFN_GetVer = HRESULT (STDMETHODCALLTYPE *)(PCWSTR, LPWSTR*);
  if (auto pGetVer = (PFN_GetVer)GetProcAddress(g_hWebView2Loader, "GetAvailableCoreWebView2BrowserVersionString"))
  {
    LPWSTR ver = nullptr; HRESULT hr = pGetVer(nullptr, &ver);
    LogF("GetAvailableCoreWebView2BrowserVersionString -> hr=0x%lX ver=%S", (long)hr, ver?ver:L"(null)");
    if (ver) CoTaskMemFree(ver);
  }

  using CreateEnv_t = HRESULT (STDMETHODCALLTYPE*)(PCWSTR, PCWSTR, ICoreWebView2EnvironmentOptions*,
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler*);
  auto pCreateEnv = (CreateEnv_t)GetProcAddress(g_hWebView2Loader, "CreateCoreWebView2EnvironmentWithOptions");
  LogF("GetProcAddress(CreateCoreWebView2EnvironmentWithOptions) -> %p", (void*)pCreateEnv);
  if (!pCreateEnv) { LogRaw("FATAL: CreateCoreWebView2EnvironmentWithOptions not found"); return; }

  std::wstring wurl(initial_url.begin(), initial_url.end());
  // Determine current active instance id for association
  std::string activeId = g_instanceId.empty()?std::string("wv_default"):g_instanceId;
  std::wstring wudf(udf.begin(), udf.end());

  LogRaw("Start WebView2 environment...");
  HRESULT hrEnv = pCreateEnv(nullptr, wudf.c_str(), nullptr,
    Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
  [hwnd, wurl, activeId](HRESULT result, ICoreWebView2Environment* env)->HRESULT
      {
        LogF("[EnvCompleted] hr=0x%lX env=%p", (long)result, (void*)env);
        if (FAILED(result) || !env) return S_OK;

        env->CreateCoreWebView2Controller(hwnd,
          Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
            [hwnd, wurl, activeId, env](HRESULT result, ICoreWebView2Controller* controller)->HRESULT
            {
              LogF("[ControllerCompleted] hr=0x%lX controller=%p", (long)result, (void*)controller);
              if (!controller) return S_OK;
              wil::com_ptr<ICoreWebView2> localWebView;
              controller->get_CoreWebView2(&localWebView);

              // Store into instance record
              WebViewInstanceRecord* rec = GetInstanceById(activeId);
              if (rec) {
                // Release any previous pointers before overwriting (should normally be null for first creation)
                if (rec->controller) { rec->controller->Release(); rec->controller = nullptr; }
                if (rec->webview)    { rec->webview->Release();    rec->webview = nullptr; }
                if (rec->environment) { rec->environment->Release(); rec->environment=nullptr; }
                rec->controller = controller; if (rec->controller) rec->controller->AddRef();
                rec->webview    = localWebView.get(); if (rec->webview) rec->webview->AddRef();
                if (env) { env->AddRef(); rec->environment = env; }
                if (!rec->hwnd) rec->hwnd = hwnd;
              }
              else {
                LogF("[ControllerCompleted] instance '%s' not found, releasing controller immediately", activeId.c_str());
                controller->Close();
                return S_OK;
              }

              if (localWebView)
              {
                // Try to acquire native Find interface once controller/webview ready
                WebViewInstanceRecord* recAcquire = GetInstanceById(activeId);
                if (recAcquire && recAcquire->webview) {
                  // Query latest extended interface that exposes get_Find (ICoreWebView2_28 onwards). We use raw QueryInterface by IID.
                  // The header might not expose symbolic name; use documented IID via __uuidof trick if available, else skip.
                  // Simplified: attempt to QI for ICoreWebView2_28 by GUID (fallback: ignore if not found).
                  // NOTE: If newer SDK not available in this header subset, this will safely fail.
                  struct ICoreWebView2_28; // forward (avoid including heavy sections)
                  // We cannot directly use __uuidof(ICoreWebView2_28) without full declaration; skip until WinEnsureNativeFind.
                }
                wil::com_ptr<ICoreWebView2Settings> settings;
                if (SUCCEEDED(localWebView->get_Settings(&settings)) && settings)
                  settings->put_AreDefaultContextMenusEnabled(FALSE);

                // JS bridge: ПКМ из WebView2 -> локальное меню (без JS find fallback)
                {
                  static const wchar_t* kFRZCtxJS = LR"JS(
                    window.addEventListener('contextmenu', function(e){
                      e.preventDefault();
                      var scale = window.devicePixelRatio || 1;
                      var px = Math.round(e.screenX * scale);
                      var py = Math.round(e.screenY * scale);
                      var s = 'CTX|' + px + '|' + py;
                      if (window.chrome && window.chrome.webview) window.chrome.webview.postMessage(s);
                    }, true);
                  )JS";
                  localWebView->AddScriptToExecuteOnDocumentCreated(
                    kFRZCtxJS,
                    Callback<ICoreWebView2AddScriptToExecuteOnDocumentCreatedCompletedHandler>(
                      [](HRESULT /*ec*/, PCWSTR /*id*/) -> HRESULT { return S_OK; }
                    ).Get());
                }

                // Receive 'CTX|x|y' и показать локальное меню
                localWebView->add_WebMessageReceived(
                  Callback<ICoreWebView2WebMessageReceivedEventHandler>(
                    [hwnd](ICoreWebView2*, ICoreWebView2WebMessageReceivedEventArgs* args)->HRESULT {
                      wil::unique_cotaskmem_string json;
                      if (SUCCEEDED(args->get_WebMessageAsJson(&json)) && json) {
                        std::string s = Narrow(std::wstring(json.get()));
                        if (!s.empty() && s.front()=='"' && s.back()=='"') s = s.substr(1, s.size()-2);
                        if (s.rfind("CTX|", 0) == 0) {
                          int sx=0, sy=0;
                          #ifdef _WIN32
                            sscanf_s(s.c_str()+4, "%d|%d", &sx, &sy);
                          #else
                            sscanf(s.c_str()+4, "%d|%d", &sx, &sy);
                          #endif
                          PostMessage(hwnd, WM_CONTEXTMENU, (WPARAM)hwnd, MAKELPARAM(sx, sy));
                        }
                      }
                      return S_OK;
                    }).Get(), nullptr);

                // Глушим дефолтное контекстное меню Edge
                Microsoft::WRL::ComPtr<ICoreWebView2_13> wv13;
                if (localWebView && SUCCEEDED(localWebView.get()->QueryInterface(IID_PPV_ARGS(&wv13)))) {
                  wv13->add_ContextMenuRequested(
                    Callback<ICoreWebView2ContextMenuRequestedEventHandler>(
                      [](ICoreWebView2*, ICoreWebView2ContextMenuRequestedEventArgs* args)->HRESULT {
                        args->put_Handled(TRUE);
                        return S_OK;
                      }).Get(),
                    nullptr);
                }

                localWebView->add_DocumentTitleChanged(
                  Callback<ICoreWebView2DocumentTitleChangedEventHandler>(
                    [activeId, hwnd](ICoreWebView2*, IUnknown*)->HRESULT
                    {
                      WebViewInstanceRecord* r = GetInstanceById(activeId);
                      HWND target = (r && r->hwnd && IsWindow(r->hwnd)) ? r->hwnd : (IsWindow(hwnd)?hwnd:NULL);
                      if (target) UpdateTitlesExtractAndApply(target); else LogF("[CallbackSkip] TitleChanged dead hwnd activeId='%s'", activeId.c_str());
                      return S_OK;
                    }).Get(), nullptr);

                localWebView->add_NavigationStarting(
                  Callback<ICoreWebView2NavigationStartingEventHandler>(
                    [activeId, hwnd](ICoreWebView2*, ICoreWebView2NavigationStartingEventArgs* args)->HRESULT
                    {
                      wil::unique_cotaskmem_string uri;
                      if (args && SUCCEEDED(args->get_Uri(&uri))) LogF("[NavigationStarting] %S", uri.get());
                      WebViewInstanceRecord* r = GetInstanceById(activeId);
                      HWND target = (r && r->hwnd && IsWindow(r->hwnd)) ? r->hwnd : (IsWindow(hwnd)?hwnd:NULL);
                      if (target) UpdateTitlesExtractAndApply(target); else LogF("[CallbackSkip] NavStarting dead hwnd activeId='%s'", activeId.c_str());
                      return S_OK;
                    }).Get(), nullptr);

                localWebView->add_NavigationCompleted(
                  Callback<ICoreWebView2NavigationCompletedEventHandler>(
                    [activeId, hwnd](ICoreWebView2*, ICoreWebView2NavigationCompletedEventArgs* args)->HRESULT
                    {
                      BOOL ok = FALSE; if (args) args->get_IsSuccess(&ok);
                      COREWEBVIEW2_WEB_ERROR_STATUS st = COREWEBVIEW2_WEB_ERROR_STATUS_UNKNOWN;
                      if (args) args->get_WebErrorStatus(&st);
                      LogF("[NavigationCompleted] ok=%d status=%d", (int)ok, (int)st);
                      WebViewInstanceRecord* r = GetInstanceById(activeId);
                      HWND target = (r && r->hwnd && IsWindow(r->hwnd)) ? r->hwnd : (IsWindow(hwnd)?hwnd:NULL);
                      if (target) UpdateTitlesExtractAndApply(target); else LogF("[CallbackSkip] NavCompleted dead hwnd activeId='%s'", activeId.c_str());
                      return S_OK;
                    }).Get(), nullptr);
              }

              RECT rc; GetClientRect(hwnd, &rc);
              LayoutTitleBarAndWebView(hwnd, false);
              controller->put_IsVisible(TRUE);
              LogRaw("Navigate initial URL...");
              WebViewInstanceRecord* recInit = GetInstanceById(activeId);
              if (recInit && recInit->webview) recInit->webview->Navigate(wurl.c_str());
              UpdateTitlesExtractAndApply(hwnd);
              return S_OK;
            }).Get());
        return S_OK;
      }).Get());
  LogF("CreateCoreWebView2EnvironmentWithOptions returned 0x%lX", (long)hrEnv);
}

// ================= Native Find helpers =================
// Acquire find interface & options lazily
// Forward declare interface so we can QI (full vtbl already in included header).
struct ICoreWebView2_28;

// Helper to update counter labels (implemented in main.mm for Windows)

static void WinNativeFindUpdateCounters(WebViewInstanceRecord* rec)
{
  if (!rec || !rec->nativeFind) return;
  INT32 rawIdx=-1, rawTotal=0;
  rec->nativeFind->get_ActiveMatchIndex(&rawIdx); // may be -1 if not yet selected
  rec->nativeFind->get_MatchCount(&rawTotal);
  int uiIdx = 0; int uiTotal = 0;
  if (rawTotal > 0) {
    uiTotal = (int)rawTotal;
    if (rawIdx >= 0) uiIdx = (int)rawIdx + 1; // convert zero-based -> 1-based
  }
  rec->findCurrentIndex = uiIdx;
  rec->findTotalMatches = uiTotal;
  LogF("[FindNative] Counters rawIdx=%d rawTotal=%d uiIdx=%d uiTotal=%d", (int)rawIdx, (int)rawTotal, uiIdx, uiTotal);
  UpdateFindCounter(rec);
}

void WinEnsureNativeFind(WebViewInstanceRecord* rec)
{
  if (!rec || rec->nativeFind || !rec->webview) return;
  Microsoft::WRL::ComPtr<ICoreWebView2_28> wv28;
  if (FAILED(rec->webview->QueryInterface(IID_PPV_ARGS(&wv28))) || !wv28) {
    LogRaw("[FindNative] ICoreWebView2_28 not supported (no native find)");
    return;
  }
  if (FAILED(wv28->get_Find(&rec->nativeFind)) || !rec->nativeFind) {
    LogRaw("[FindNative] get_Find failed");
    return;
  }
  // Try to create initial options via Environment15 factory (will recreate per Start as needed)
  if (rec->environment && !rec->nativeFindOpts) {
    Microsoft::WRL::ComPtr<ICoreWebView2Environment15> env15;
    if (SUCCEEDED(rec->environment->QueryInterface(IID_PPV_ARGS(&env15))) && env15) {
      ICoreWebView2FindOptions* tmp = nullptr;
      HRESULT hrCF = env15->CreateFindOptions(&tmp);
      if (SUCCEEDED(hrCF) && tmp) {
        rec->nativeFindOpts = tmp; // keep
        LogF("[FindNative] initial CreateFindOptions hr=0x%lX opts=%p", (long)hrCF, (void*)rec->nativeFindOpts);
      } else {
        LogF("[FindNative] CreateFindOptions failed hr=0x%lX", (long)hrCF);
      }
    } else {
      LogRaw("[FindNative] Environment15 not available (no CreateFindOptions)");
    }
  }
  LogRaw("[FindNative] acquired ICoreWebView2Find (events subscribe)");
  // Subscribe events
  auto hr1 = rec->nativeFind->add_ActiveMatchIndexChanged(Callback<ICoreWebView2FindActiveMatchIndexChangedEventHandler>(
    [rec](ICoreWebView2Find*, IUnknown*)->HRESULT {
        WinNativeFindUpdateCounters(rec);
        if (rec->nativeFind && !rec->findHighlightAll && !rec->nativeFindAutoActivated) {
          INT32 rawIdx=-1, rawTotal=0; rec->nativeFind->get_ActiveMatchIndex(&rawIdx); rec->nativeFind->get_MatchCount(&rawTotal);
          if (rawIdx < 0 && rawTotal > 0) { rec->nativeFind->FindNext(); rec->nativeFindAutoActivated = true; LogRaw("[FindNative] Event auto FindNext (ActiveMatchIndexChanged) to select first match"); }
        }
        return S_OK; }
  ).Get(), reinterpret_cast<EventRegistrationToken*>(&rec->nativeFindActiveToken));
  auto hr2 = rec->nativeFind->add_MatchCountChanged(Callback<ICoreWebView2FindMatchCountChangedEventHandler>(
    [rec](ICoreWebView2Find*, IUnknown*)->HRESULT {
        WinNativeFindUpdateCounters(rec);
        if (rec->nativeFind && !rec->findHighlightAll && !rec->nativeFindAutoActivated) {
          INT32 rawIdx=-1, rawTotal=0; rec->nativeFind->get_ActiveMatchIndex(&rawIdx); rec->nativeFind->get_MatchCount(&rawTotal);
            if (rawIdx < 0 && rawTotal > 0) { rec->nativeFind->FindNext(); rec->nativeFindAutoActivated = true; LogRaw("[FindNative] Event auto FindNext (MatchCountChanged) to select first match"); }
        }
        return S_OK; }
  ).Get(), reinterpret_cast<EventRegistrationToken*>(&rec->nativeFindCountToken));
  LogF("[FindNative] ready find=%p opts=%p ev1=0x%lX ev2=0x%lX", (void*)rec->nativeFind, (void*)rec->nativeFindOpts, (long)hr1, (long)hr2);
}

void WinFindStartOrUpdate(WebViewInstanceRecord* rec)
{
  if (!rec) return;
  WinEnsureNativeFind(rec);
  if (!rec->nativeFind) { LogRaw("[FindNative] not available (start/update ignored)" ); return; }
  if (rec->findQuery.empty()) {
    if (rec->nativeFindActive) { rec->nativeFind->Stop(); rec->nativeFindActive=false; rec->findCurrentIndex=0; rec->findTotalMatches=0; UpdateFindCounter(rec); }
    return;
  }
  // Always create a fresh options object to guarantee Start sees a "new or modified" instance per docs.
  if (rec->nativeFindOpts) { rec->nativeFindOpts->Release(); rec->nativeFindOpts = nullptr; }
  if (rec->environment) {
    Microsoft::WRL::ComPtr<ICoreWebView2Environment15> env15;
    if (SUCCEEDED(rec->environment->QueryInterface(IID_PPV_ARGS(&env15))) && env15) {
      ICoreWebView2FindOptions* fresh = nullptr; HRESULT hrC = env15->CreateFindOptions(&fresh);
      if (SUCCEEDED(hrC) && fresh) {
        rec->nativeFindOpts = fresh;
        std::wstring wq(rec->findQuery.begin(), rec->findQuery.end());
        rec->nativeFindOpts->put_FindTerm(wq.c_str());
        rec->nativeFindOpts->put_IsCaseSensitive(rec->findCaseSensitive ? TRUE : FALSE);
        rec->nativeFindOpts->put_ShouldHighlightAllMatches(rec->findHighlightAll ? TRUE : FALSE);
        rec->nativeFindOpts->put_SuppressDefaultFindDialog(TRUE);
        // We do NOT set ShouldMatchWord (leave default false)
      } else {
        LogF("[FindNative] CreateFindOptions (Start) failed hr=0x%lX", (long)hrC);
      }
    } else {
      LogRaw("[FindNative] Environment15 unavailable at Start (cannot create options)");
    }
  }
  if (!rec->nativeFindOpts) { LogRaw("[FindNative] Start aborted (no options)"); return; }
  // If previously active and query changed, stop to start a new session from top
  if (rec->nativeFindActive) rec->nativeFind->Stop();
  rec->nativeFindActive = true;
  rec->nativeFindAutoActivated = false; // reset for new session
  HRESULT hrStart = rec->nativeFind->Start(rec->nativeFindOpts, Callback<ICoreWebView2FindStartCompletedHandler>(
    [rec](HRESULT /*result*/) -> HRESULT {
        // We might not yet have ActiveMatchIndex; counters will update via events.
        // Force immediate counter poll for logging.
        WinNativeFindUpdateCounters(rec);
        // If highlightAll is false we often need an explicit first navigation to select first match.
        if (rec->nativeFind && !rec->findHighlightAll) {
          INT32 rawIdx=-1, rawTotal=0; rec->nativeFind->get_ActiveMatchIndex(&rawIdx); rec->nativeFind->get_MatchCount(&rawTotal);
          if (rawIdx < 0 && rawTotal > 0) { rec->nativeFind->FindNext(); rec->nativeFindAutoActivated = true; LogRaw("[FindNative] Auto FindNext to activate first match (highlightAll=0)"); }
        }
        // Attempt to force rendering highlight by programmatic focus move
        if (rec->controller) {
          Microsoft::WRL::ComPtr<ICoreWebView2Controller> c2; rec->controller->QueryInterface(IID_PPV_ARGS(&c2));
          if (c2) c2->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
        }
        return S_OK; }
  ).Get());
  LogF("[FindNative] Start term='%s' case=%d highlight=%d hr=0x%lX", rec->findQuery.c_str(), (int)rec->findCaseSensitive, (int)rec->findHighlightAll, (long)hrStart);
}

void WinFindNavigate(WebViewInstanceRecord* rec, bool forward)
{
  if (!rec) return;
  if (!rec->nativeFindActive || !rec->nativeFind) { LogRaw("[FindNative] navigate ignored (inactive)"); return; }
  if (forward) rec->nativeFind->FindNext(); else rec->nativeFind->FindPrevious();
  LogF("[FindNative] Navigate %s", forward?"next":"prev");
  if (rec->controller) {
    Microsoft::WRL::ComPtr<ICoreWebView2Controller> c2; rec->controller->QueryInterface(IID_PPV_ARGS(&c2));
    if (c2) c2->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
  }
}

void WinFindClose(WebViewInstanceRecord* rec)
{
  if (!rec) return;
  if (rec->nativeFind) {
    rec->nativeFind->Stop();
    rec->nativeFindActive = false;
    // Remove events if subscribed (value of token may be 0 for uninitialized)
  if (rec->nativeFindActiveToken.value) rec->nativeFind->remove_ActiveMatchIndexChanged(*reinterpret_cast<EventRegistrationToken*>(&rec->nativeFindActiveToken));
  if (rec->nativeFindCountToken.value) rec->nativeFind->remove_MatchCountChanged(*reinterpret_cast<EventRegistrationToken*>(&rec->nativeFindCountToken));
    rec->nativeFindActiveToken.value = 0; rec->nativeFindCountToken.value=0;
    if (rec->nativeFindOpts) { rec->nativeFindOpts->Release(); rec->nativeFindOpts = nullptr; }
    rec->nativeFind->Release(); rec->nativeFind = nullptr;
    LogRaw("[FindNative] stopped & released");
  }
}

void NavigateExisting(const std::string& url)
{
  if (url.empty()) return;
  // Use active instance id
  std::string activeId = g_instanceId.empty()?std::string("wv_default"):g_instanceId;
  WebViewInstanceRecord* rec = GetInstanceById(activeId);
  if (!rec || !rec->webview) { LogF("[NavigateExisting] active instance '%s' has no webview", activeId.c_str()); return; }
  std::wstring wurl(url.begin(), url.end());
  HRESULT hr = rec->webview->Navigate(wurl.c_str());
  LogF("[NavigateExisting] id='%s' Navigate('%s') hr=0x%lX", activeId.c_str(), url.c_str(), (long)hr);
}

void NavigateExistingInstance(const std::string& instanceId, const std::string& url)
{
  if (url.empty()) return;
  WebViewInstanceRecord* rec = GetInstanceById(instanceId);
  if (!rec || !rec->webview) { LogF("[NavigateExistingInstance] instance '%s' has no webview yet", instanceId.c_str()); return; }
  std::wstring wurl(url.begin(), url.end());
  HRESULT hr = rec->webview->Navigate(wurl.c_str());
  LogF("[NavigateExistingInstance] id='%s' Navigate('%s') hr=0x%lX", instanceId.c_str(), url.c_str(), (long)hr);
  rec->lastUrl = url;
}

#endif // _WIN32
