// Reaper WebView Plugin
// (c) Andrew "SadFrozz" Brodsky
// 2025 and later
// webview_win.cpp
// Edge WebView2 for Windows implementation

#ifdef _WIN32

#define RWV_WITH_WEBVIEW2 1
#include "predef.h"
// WIL/WebView2 только здесь (TU помечен RWV_WITH_WEBVIEW2 перед predef.h)
#include "deps/wil/com.h"

#include <shlwapi.h>
#include <direct.h>
#pragma comment(lib, "Shlwapi.lib")

#include "log.h"
#include "globals.h"
#include "helpers.h"
#include "webview.h"

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
            [hwnd, wurl, activeId](HRESULT result, ICoreWebView2Controller* controller)->HRESULT
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
                rec->controller = controller; if (rec->controller) rec->controller->AddRef();
                rec->webview    = localWebView.get(); if (rec->webview) rec->webview->AddRef();
                if (!rec->hwnd) rec->hwnd = hwnd;
              }
              else {
                LogF("[ControllerCompleted] instance '%s' not found, releasing controller immediately", activeId.c_str());
                controller->Close();
                return S_OK;
              }

              if (localWebView)
              {
                wil::com_ptr<ICoreWebView2Settings> settings;
                if (SUCCEEDED(localWebView->get_Settings(&settings)) && settings)
                  settings->put_AreDefaultContextMenusEnabled(FALSE);

                // JS bridge: ПКМ из WebView2 -> локальное меню
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
