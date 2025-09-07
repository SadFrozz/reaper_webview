// main.mm — SWELL dockable WebView with stable tab title updates
// - Undocked caption:  "WebView: DOMAIN - TITLE"
// - Docker tab title:  "WebView: DOMAIN" (keeps non‑default ports 80/443 hidden)
// - Updates in-place; if docker refuses to repaint, one-shot fallback re-add to SAME dock slot
// - Logging: off in Release, on in Debug or if ENABLE_LOG=1

#ifdef _WIN32
  #ifndef WIN32_LEAN_AND_MEAN
  #define WIN32_LEAN_AND_MEAN
  #endif
  #include <windows.h>
  #include <string>
  #include <mutex>
  #include <wrl.h>
  #include <wil/com.h>
  #include <objbase.h>
  #include <shlwapi.h>
  #include <direct.h>
  #include "deps/WebView2.h"
  #pragma comment(lib, "Shlwapi.lib")
#else
  #include "WDL/swell/swell.h"
  #include "WDL/swell/swell-dlggen.h"
  #import <Cocoa/Cocoa.h>
  #import <WebKit/WebKit.h>
  #include <string>
  #include <mutex>
#endif

#include "WDL/wdltypes.h"

#ifndef REAPERAPI_IMPLEMENT
#define REAPERAPI_IMPLEMENT
#endif
#include "sdk/reaper_plugin.h"
#include "sdk/reaper_plugin_functions.h"

// --------------------------------------------------------------------
// Build-time logging control
// --------------------------------------------------------------------
#ifndef ENABLE_LOG
  #ifdef NDEBUG
    #define ENABLE_LOG 0
  #else
    #define ENABLE_LOG 1
  #endif
#endif

// --------------------------------------------------------------------
// Globals
// --------------------------------------------------------------------
static REAPER_PLUGIN_HINSTANCE g_hInst = nullptr;
static HWND   g_hwndParent = nullptr;
static int    g_command_id = 0;

static const char* kDockIdent  = "reaper_webview"; // stable ident
static const char* kTitleBase  = "WebView";
static const char* kDefaultURL = "https://www.reaper.fm/";

#ifdef _WIN32
static HWND   g_dlg = nullptr;
static wil::com_ptr<ICoreWebView2Controller> g_controller;
static wil::com_ptr<ICoreWebView2>           g_webview;
static HMODULE g_hWebView2Loader = nullptr;
static bool   g_com_initialized = false;
static std::wstring g_userDataFolder;
#else
static HWND      g_dlg = nullptr;
static WKWebView* g_webView = nil;
#endif

// last shown texts
static std::string g_lastTabTitle;
static std::string g_lastWndText;

// docker state tracking (for safe fallback re-add)
static int   g_last_dock_idx   = -1;
static bool  g_last_dock_float = false;
static bool  g_pending_readd   = false;
static const UINT_PTR TAB_READD_TIMER = 0x13A1;

// Forward declarations
static INT_PTR WINAPI WebViewDlgProc(HWND, UINT, WPARAM, LPARAM);
static void OpenOrActivate(const std::string& url);

// --------------------------------------------------------------------
// Logging (compiled out for Release)
// --------------------------------------------------------------------
#if ENABLE_LOG
static std::mutex& log_mutex() { static std::mutex m; return m; }
static std::string GetModuleDir()
{
#ifdef _WIN32
  char modPath[MAX_PATH] = {0};
  GetModuleFileNameA((HMODULE)g_hInst, modPath, MAX_PATH);
  std::string dir(modPath);
  size_t p = dir.find_last_of("\\/"); if (p != std::string::npos) dir.resize(p);
  return dir;
#else
  return ".";
#endif
}
static std::string GetLogPath()
{
  const char* res = GetResourcePath ? GetResourcePath() : nullptr;
  if (res && *res)
  {
#ifdef _WIN32
    return std::string(res) + "\\reaper_webview_log.txt";
#else
    return std::string(res) + "/reaper_webview_log.txt";
#endif
  }
#ifdef _WIN32
  return GetModuleDir() + "\\reaper_webview_log.txt";
#else
  return "reaper_webview_log.txt";
#endif
}
static void LogRaw(const char* s)
{
  if (!s) return;
#ifdef _WIN32
  OutputDebugStringA(s); OutputDebugStringA("\r\n");
#endif
  if (ShowConsoleMsg) { ShowConsoleMsg(s); ShowConsoleMsg("\n"); }
  std::lock_guard<std::mutex> lk(log_mutex());
  FILE* f = nullptr;
#ifdef _WIN32
  fopen_s(&f, GetLogPath().c_str(), "ab");
#else
  f = fopen(GetLogPath().c_str(), "ab");
#endif
  if (f) { fwrite(s, 1, strlen(s), f); fwrite("\n", 1, 1, f); fclose(f); }
}
static void LogF(const char* fmt, ...)
{
  char buf[4096] = {0};
  va_list ap; va_start(ap, fmt);
#ifdef _WIN32
  _vsnprintf(buf, sizeof(buf)-1, fmt, ap);
#else
  vsnprintf(buf, sizeof(buf)-1, fmt, ap);
#endif
  va_end(ap);
  LogRaw(buf);
}
#else
  static inline void LogRaw(const char*) {}
  static inline void LogF(const char*, ...) {}
#endif

#ifdef _WIN32
static std::wstring Widen(const std::string& s)
{
  if (s.empty()) return std::wstring();
  int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
  std::wstring w; w.resize(n ? (n-1) : 0);
  if (n > 1) MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &w[0], n);
  return w;
}
static std::string Narrow(const std::wstring& w)
{
  if (w.empty()) return std::string();
  int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, nullptr, 0, nullptr, nullptr);
  std::string s; s.resize(n ? (n-1) : 0);
  if (n > 1) WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, &s[0], n, nullptr, nullptr);
  return s;
}
static bool EnsureDirRecursive(const std::string& path)
{
  if (path.empty()) return false;
  if (PathFileExistsA(path.c_str())) return true;
  std::string p = path;
  for (char& c : p) if (c == '/') c = '\\';

  size_t i = 0;
  if (p.size() >= 2 && p[1] == ':') i = 3;
  else if (p.rfind("\\\\", 0) == 0)
  {
    size_t pos = p.find('\\', 2);
    if (pos == std::string::npos) return false;
    pos = p.find('\\', pos+1);
    if (pos == std::string::npos) return false;
    i = pos + 1;
  }
  for (; i < p.size(); ++i)
  {
    if (p[i] == '\\')
    {
      std::string sub = p.substr(0, i);
      if (!sub.empty() && !PathFileExistsA(sub.c_str()))
      {
        if (_mkdir(sub.c_str()) != 0 && GetLastError() != ERROR_ALREADY_EXISTS)
        {
          LogF("mkdir failed for %s (gle=%lu)", sub.c_str(), GetLastError());
          return false;
        }
      }
    }
  }
  if (!PathFileExistsA(p.c_str()))
  {
    if (_mkdir(p.c_str()) != 0 && GetLastError() != ERROR_ALREADY_EXISTS)
    {
      LogF("mkdir failed for %s (gle=%lu)", p.c_str(), GetLastError());
      return false;
    }
  }
  return PathFileExistsA(p.c_str());
}
#endif

// --------------------------------------------------------------------
// Titles
// --------------------------------------------------------------------
static std::string ToLower(std::string s)
{
  for (auto &c : s) c = (char)tolower((unsigned char)c);
  return s;
}

// keep port unless default (http:80 / https:443). strip leading "www."
static std::string ExtractDomainFromUrl(const std::string& url)
{
  if (url.empty()) return std::string();

  size_t scheme_end = url.find("://");
  std::string scheme;
  size_t host_start = 0;
  if (scheme_end != std::string::npos) { scheme = url.substr(0, scheme_end); host_start = scheme_end + 3; }
  std::string scheme_l = ToLower(scheme);

  size_t end = url.find_first_of("/?#", host_start);
  std::string hostport = url.substr(host_start, (end==std::string::npos) ? std::string::npos : (end - host_start));

  // remove userinfo if present
  size_t at = hostport.rfind('@');
  if (at != std::string::npos) hostport = hostport.substr(at + 1);

  std::string host = hostport;
  std::string port_str;

  if (!hostport.empty() && hostport[0] == '[')
  {
    // IPv6 [::1]:port
    size_t rb = hostport.find(']');
    if (rb != std::string::npos)
    {
      host = hostport.substr(0, rb+1);
      if (rb + 1 < hostport.size() && hostport[rb+1] == ':')
        port_str = hostport.substr(rb+2);
    }
  }
  else
  {
    size_t colon = hostport.rfind(':');
    if (colon != std::string::npos)
    {
      host = hostport.substr(0, colon);
      port_str = hostport.substr(colon + 1);
    }
  }

  if (!host.empty() && host[0] != '[' && host.rfind("www.", 0) == 0)
    host = host.substr(4);

  bool drop_port = false;
  if (!port_str.empty())
  {
    int port = 0;
    for (char c : port_str) { if (c<'0'||c>'9') { port=-1; break; } port = port*10 + (c-'0'); }
    if (port > 0)
    {
      if ((scheme_l == "http"  && port == 80) ||
          (scheme_l == "https" && port == 443))
        drop_port = true;
    }
  }

  std::string result = host;
  if (!port_str.empty() && !drop_port) result += ":" + port_str;
  return result;
}

static void SetWndText(HWND hwnd, const std::string& text)
{
  if (g_lastWndText == text) return;
#ifdef _WIN32
  SetWindowTextA(hwnd, text.c_str());
#else
  SetWindowText(hwnd, text.c_str());
#endif
  g_lastWndText = text;
}

// Save current docker idx/float for fallback
static void SaveDockState(HWND hwnd)
{
  bool isFloat = false;
  int idx = DockIsChildOfDock ? DockIsChildOfDock(hwnd, &isFloat) : -1;
  if (idx >= 0) { g_last_dock_idx = idx; g_last_dock_float = isFloat; }
  else { g_last_dock_idx = -1; g_last_dock_float = false; }
}

// In-place update: set window text appropriately and refresh docker (no re-add)
static void SetTabTitleInplace(HWND hwnd, const std::string& tabCaption)
{
  SetWndText(hwnd, tabCaption);
  if (DockWindowRefreshForHWND) DockWindowRefreshForHWND(hwnd);
  if (DockWindowRefresh) DockWindowRefresh();
}

// Fallback: re-add to the SAME dock slot + same float mode
static void ReaddWithSameDock(HWND hwnd, const std::string& tabCaption)
{
  // remember current idx/float
  SaveDockState(hwnd);
  if (g_last_dock_idx < 0) return;

  if (DockWindowRemove) DockWindowRemove(hwnd);
  if (Dock_UpdateDockID) Dock_UpdateDockID(kDockIdent, g_last_dock_float ? 4 : g_last_dock_idx);
  if (DockWindowAddEx) DockWindowAddEx(hwnd, tabCaption.c_str(), kDockIdent, true);
  if (DockWindowActivate) DockWindowActivate(hwnd);
  if (DockWindowRefreshForHWND) DockWindowRefreshForHWND(hwnd);
  if (DockWindowRefresh) DockWindowRefresh();

  LogF("[TabTitleFallback] readd '%s' (idx=%d float=%d)",
       tabCaption.c_str(), g_last_dock_idx, (int)g_last_dock_float);
}

// Extract current domain/title from engine and apply titles (with fallback scheduling)
static void UpdateTitlesExtractAndApply(HWND hwnd)
{
  std::string domain, pageTitle;

#ifdef _WIN32
  if (g_webview)
  {
    wil::unique_cotaskmem_string wsrc, wtitle;
    if (SUCCEEDED(g_webview->get_Source(&wsrc)) && wsrc) domain = ExtractDomainFromUrl(Narrow(wsrc.get()));
    if (SUCCEEDED(g_webview->get_DocumentTitle(&wtitle)) && wtitle) pageTitle = Narrow(wtitle.get());
  }
#else
  if (g_webView)
  {
    NSURL* u = g_webView.URL;
    if (u && u.host) domain = [[u.host lowercaseString] UTF8String];
    NSString* t = g_webView.title;
    if (t) pageTitle = [t UTF8String];
  }
#endif

  const std::string tabCaption = std::string(kTitleBase) + ": " + (domain.empty() ? std::string("…") : domain);
  const std::string wndCaption = pageTitle.empty() ? tabCaption : (tabCaption + " - " + pageTitle);

  SaveDockState(hwnd);
  const bool inDock = (g_last_dock_idx >= 0);

  if (inDock)
  {
    if (tabCaption != g_lastTabTitle)
    {
      LogF("[TabTitle] in-dock (idx=%d float=%d) -> '%s'",
           g_last_dock_idx, (int)g_last_dock_float, tabCaption.c_str());
      g_lastTabTitle = tabCaption;
    }
    SetTabTitleInplace(hwnd, tabCaption);

    // one-shot fallback if docker didn't repaint
    if (!g_pending_readd)
    {
      g_pending_readd = true;
      SetTimer(hwnd, TAB_READD_TIMER, 150, nullptr);
    }
  }
  else
  {
    SetWndText(hwnd, wndCaption);
    LogF("[TitleUpdate] inDock=0 caption='%s'", wndCaption.c_str());
  }
}

// --------------------------------------------------------------------
// Dialog + Docker
// --------------------------------------------------------------------
static const int IDC_WEBVIEW_HOST = 1001;

#ifndef _WIN32
#define IDD_WEBVIEW 2001
SWELL_DEFINE_DIALOG_RESOURCE_BEGIN(IDD_WEBVIEW, 0, "WebView", 300, 200, 1.8)
BEGIN
  CONTROL         "",IDC_WEBVIEW_HOST,"customcontrol",WS_CHILD|WS_VISIBLE,0,0,300,200
END
SWELL_DEFINE_DIALOG_RESOURCE_END(IDD_WEBVIEW)
#endif

#ifdef _WIN32
struct MyDLGTEMPLATE : DLGTEMPLATE { WORD ext[3]; MyDLGTEMPLATE(){ memset(this,0,sizeof(*this)); } };
#endif

static void SizeWebViewToClient(HWND hwnd)
{
  RECT rc; GetClientRect(hwnd, &rc);
#ifdef _WIN32
  if (g_controller) g_controller->put_Bounds(rc);
#else
  if (g_webView)
  {
    NSView* view = (NSView*)SWELL_GetView(hwnd);
    if (view)
    {
      NSRect b = NSMakeRect(0,0, rc.right-rc.left, rc.bottom-rc.top);
      [g_webView setFrame:b];
    }
  }
#endif
}

// --------------------------------------------------------------------
// WebView setup
// --------------------------------------------------------------------
#ifdef _WIN32
static void StartWebView(HWND hwnd, const std::string& initial_url)
{
  if (!g_com_initialized)
  {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    g_com_initialized = SUCCEEDED(hr);
    LogF("CoInitializeEx -> 0x%lX (ok=%d)", (long)hr, (int)g_com_initialized);
  }

  const char* res = GetResourcePath ? GetResourcePath() : nullptr;
  std::string base = (res && *res) ? std::string(res) : GetModuleDir();
  std::string udf = base + "\\WebView2Data";
  LogF("userDataFolder: %s", udf.c_str());
  EnsureDirRecursive(udf);
  g_userDataFolder = Widen(udf);

  if (!g_hWebView2Loader)
  {
    std::string candidate = GetModuleDir() + "\\WebView2Loader.dll";
    g_hWebView2Loader = LoadLibraryA(candidate.c_str());
    if (!g_hWebView2Loader) g_hWebView2Loader = LoadLibraryA("WebView2Loader.dll");
    LogF("LoadLibrary(WebView2Loader) -> %p", (void*)g_hWebView2Loader);
  }
  if (!g_hWebView2Loader) { LogRaw("FATAL: missing WebView2Loader.dll"); return; }

  using PFN_GetVer = HRESULT (STDMETHODCALLTYPE *)(PCWSTR, LPWSTR*);
  auto pGetVer = (PFN_GetVer)GetProcAddress(g_hWebView2Loader, "GetAvailableCoreWebView2BrowserVersionString");
  if (pGetVer)
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

  std::wstring wurl = Widen(initial_url);
  LogRaw("Start WebView2 environment...");
  HRESULT hrEnv = pCreateEnv(nullptr, g_userDataFolder.c_str(), nullptr,
    Microsoft::WRL::Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
      [hwnd, wurl](HRESULT result, ICoreWebView2Environment* env)->HRESULT
      {
        LogF("[EnvCompleted] hr=0x%lX env=%p", (long)result, (void*)env);
        if (FAILED(result) || !env) return S_OK;
        env->CreateCoreWebView2Controller(hwnd,
          Microsoft::WRL::Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
            [hwnd, wurl](HRESULT result, ICoreWebView2Controller* controller)->HRESULT
            {
              LogF("[ControllerCompleted] hr=0x%lX controller=%p", (long)result, (void*)controller);
              if (!controller) return S_OK;
              g_controller = controller;
              g_controller->get_CoreWebView2(&g_webview);

              if (g_webview)
              {
                wil::com_ptr<ICoreWebView2Settings> settings;
                if (SUCCEEDED(g_webview->get_Settings(&settings)) && settings)
                  settings->put_AreDefaultContextMenusEnabled(FALSE);

                // update titles on changes
                g_webview->add_DocumentTitleChanged(
                  Microsoft::WRL::Callback<ICoreWebView2DocumentTitleChangedEventHandler>(
                    [](ICoreWebView2*, IUnknown*)->HRESULT
                    { UpdateTitlesExtractAndApply(g_dlg); return S_OK; }).Get(), nullptr);

                g_webview->add_NavigationStarting(
                  Microsoft::WRL::Callback<ICoreWebView2NavigationStartingEventHandler>(
                    [](ICoreWebView2*, ICoreWebView2NavigationStartingEventArgs* args)->HRESULT
                    {
                      wil::unique_cotaskmem_string uri;
                      if (args && SUCCEEDED(args->get_Uri(&uri))) LogF("[NavigationStarting] %S", uri.get());
                      UpdateTitlesExtractAndApply(g_dlg);
                      return S_OK;
                    }).Get(), nullptr);

                g_webview->add_NavigationCompleted(
                  Microsoft::WRL::Callback<ICoreWebView2NavigationCompletedEventHandler>(
                    [](ICoreWebView2*, ICoreWebView2NavigationCompletedEventArgs* args)->HRESULT
                    {
                      BOOL ok = FALSE; if (args) args->get_IsSuccess(&ok);
                      COREWEBVIEW2_WEB_ERROR_STATUS st = COREWEBVIEW2_WEB_ERROR_STATUS_UNKNOWN;
                      if (args) args->get_WebErrorStatus(&st);
                      LogF("[NavigationCompleted] ok=%d status=%d", (int)ok, (int)st);
                      UpdateTitlesExtractAndApply(g_dlg);
                      return S_OK;
                    }).Get(), nullptr);
              }

              RECT rc; GetClientRect(hwnd, &rc);
              g_controller->put_Bounds(rc);
              g_controller->put_IsVisible(TRUE);
              LogRaw("Navigate initial URL...");
              g_webview->Navigate(wurl.c_str());
              UpdateTitlesExtractAndApply(hwnd);
              return S_OK;
            }).Get());
        return S_OK;
      }).Get());
  LogF("CreateCoreWebView2EnvironmentWithOptions returned 0x%lX", (long)hrEnv);
}
#else
@interface FRZWebViewDelegate : NSObject <WKNavigationDelegate>
@end
@implementation FRZWebViewDelegate
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
  UpdateTitlesExtractAndApply((HWND)g_dlg);
}
@end
static FRZWebViewDelegate* g_delegate = nil;

static void StartWebView(HWND hwnd, const std::string& initial_url)
{
  NSView* host = (NSView*)SWELL_GetView(hwnd);
  if (!host) { LogRaw("SWELL host view missing"); return; }
  WKWebViewConfiguration* cfg = [[WKWebViewConfiguration alloc] init];
  g_webView = [[WKWebView alloc] initWithFrame:[host bounds] configuration:cfg];
  g_delegate = [[FRZWebViewDelegate alloc] init];
  g_webView.navigationDelegate = g_delegate;
  [g_webView setAutoresizingMask:(NSViewWidthSizable|NSViewHeightSizable)];
  [host addSubview:g_webView];

  NSString* s = [NSString stringWithUTF8String:initial_url.c_str()];
  NSURL* u = [NSURL URLWithString:s];
  if (u) [g_webView loadRequest:[NSURLRequest requestWithURL:u]];
  UpdateTitlesExtractAndApply(hwnd);
}
#endif

// --------------------------------------------------------------------
// Helpers (dock state + context menu)
// --------------------------------------------------------------------
static bool QueryDockState(HWND hwnd, bool* outIsFloating, int* outDockIdx)
{
  bool dummyFloat=false; int dummyIdx=-1;
  if (!outIsFloating) outIsFloating = &dummyFloat;
  if (!outDockIdx) outDockIdx = &dummyIdx;

  HWND candidates[3] = { hwnd, GetParent(hwnd), GetAncestor(hwnd, GA_ROOT) };
  for (int i=0;i<3;i++)
  {
    HWND h = candidates[i];
    if (!h) continue;
    bool f=false;
    int idx = DockIsChildOfDock ? DockIsChildOfDock(h, &f) : -1;
    LogF("[DockQuery] cand=%p -> idx=%d float=%d", h, idx, (int)f);
    if (idx >= 0) { *outDockIdx = idx; *outIsFloating = f; return true; }
  }
  *outDockIdx = -1; *outIsFloating = false;
  return false;
}

static inline int GET_LP_X(LPARAM lp) { return (int)(short)LOWORD(lp); }
static inline int GET_LP_Y(LPARAM lp) { return (int)(short)HIWORD(lp); }

static void ShowLocalDockMenu(HWND hwnd, int x, int y)
{
  HMENU m = CreatePopupMenu();
  if (!m) return;

  bool isFloat=false; int idx=-1;
  bool inDock = QueryDockState(hwnd, &isFloat, &idx);
  LogF("[DockState] inDock=%d idx=%d floating=%d", (int)inDock, idx, (int)isFloat);

  AppendMenuA(m, MF_STRING | (inDock?MF_CHECKED:0), 10001, inDock ? "Undock window" : "Dock window in Docker");
  AppendMenuA(m, MF_SEPARATOR, 0, NULL);
  AppendMenuA(m, MF_STRING, 10099, "Close");

  HWND owner = hwnd;
#ifdef _WIN32
  HWND root = GetAncestor(hwnd, GA_ROOT);
  if (root) owner = root;
  SetForegroundWindow(owner);
#endif
  int cmd = TrackPopupMenu(m, TPM_RIGHTBUTTON|TPM_RETURNCMD|TPM_NONOTIFY, x, y, 0, owner, NULL);
  DestroyMenu(m);
  if (!cmd) return;

  switch (cmd)
  {
    case 10001:
    {
      bool f=false; int d=-1;
      bool nowDock = QueryDockState(hwnd, &f, &d);
      if (nowDock)
      {
        if (DockWindowRemove) { LogRaw("Menu: Undock -> DockWindowRemove()"); DockWindowRemove(hwnd); }
#ifdef _WIN32
        // true top‑level window styles for Win
        LONG_PTR st  = GetWindowLongPtr(hwnd, GWL_STYLE);
        LONG_PTR exs = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
        LogF("[BeforeUndockStyles] style=0x%lX ex=0x%lX", (long)st, (long)exs);
        st &= ~WS_CHILD;
        st |= WS_OVERLAPPEDWINDOW;
        SetWindowLongPtr(hwnd, GWL_STYLE, st);
        SetWindowLongPtr(hwnd, GWL_EXSTYLE, exs & ~WS_EX_TOOLWINDOW);
        SetParent(hwnd, NULL);
        RECT rr{}; GetWindowRect(hwnd, &rr);
        int w = rr.right-rr.left, h = rr.bottom-rr.top;
        if (w < 200 || h < 120) { w = 900; h = 600; }
        SetWindowPos(hwnd, NULL, rr.left, rr.top, w, h, SWP_NOZORDER|SWP_FRAMECHANGED|SWP_SHOWWINDOW);
        ShowWindow(hwnd, SW_SHOWNORMAL);
        SetForegroundWindow(hwnd);
        BringWindowToTop(hwnd);
        SetActiveWindow(hwnd);
        BOOL vis = IsWindowVisible(hwnd);
        GetWindowRect(hwnd, &rr);
        LogF("[AfterUndock] visible=%d rect=(%ld,%ld)-(%ld,%ld) style=0x%lX ex=0x%lX",
             (int)vis, (long)rr.left,(long)rr.top,(long)rr.right,(long)rr.bottom,
             (long)GetWindowLongPtr(hwnd,GWL_STYLE), (long)GetWindowLongPtr(hwnd,GWL_EXSTYLE));
#else
        ShowWindow(hwnd, SW_SHOW);
#endif
      }
      else
      {
        if (DockWindowAddEx) { LogRaw("Menu: Dock -> DockWindowAddEx()"); DockWindowAddEx(hwnd, kTitleBase, kDockIdent, true); }
        if (DockWindowActivate) DockWindowActivate(hwnd);
        if (DockWindowRefreshForHWND) DockWindowRefreshForHWND(hwnd);
        if (DockWindowRefresh) DockWindowRefresh();
      }
      UpdateTitlesExtractAndApply(hwnd);
    }
    break;

    case 10099:
      SendMessage(hwnd, WM_CLOSE, 0, 0);
      break;
  }
}

// --------------------------------------------------------------------
// Dialog proc
// --------------------------------------------------------------------
static INT_PTR WINAPI WebViewDlgProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
  switch (msg)
  {
    case WM_INITDIALOG:
    {
      g_dlg = hwnd;
      LogF("[WM_INITDIALOG] hwnd=%p", hwnd);

      // Resolve initial URL (from lp) and pre-compute docker tab title
      const char* initial = (const char*)lp;
      std::string url = initial && *initial ? initial : kDefaultURL;
      std::string initDomain = ExtractDomainFromUrl(url);
      std::string initTabCaption = std::string(kTitleBase) + ": " + (initDomain.empty() ? std::string("…") : initDomain);

      // Register in docker with initial tab text (no re-add later)
      if (DockWindowAddEx) { DockWindowAddEx(hwnd, initTabCaption.c_str(), kDockIdent, true); LogRaw("DockWindowAddEx OK"); }
      if (DockWindowActivate) { DockWindowActivate(hwnd); LogRaw("DockWindowActivate"); }
      if (DockWindowRefreshForHWND) { DockWindowRefreshForHWND(hwnd); LogRaw("DockWindowRefreshForHWND"); }
      if (DockWindowRefresh) { DockWindowRefresh(); LogRaw("DockWindowRefresh"); }
      g_lastTabTitle = initTabCaption;
      g_lastWndText.clear();
      g_pending_readd = false;
      SaveDockState(hwnd);

      StartWebView(hwnd, url);
      UpdateTitlesExtractAndApply(hwnd); // catch up
      return 1;
    }

    case WM_SIZE:
      SizeWebViewToClient(hwnd);
      return 0;

    case WM_TIMER:
      if (wp == TAB_READD_TIMER)
      {
        KillTimer(hwnd, TAB_READD_TIMER);
        bool stillInDock=false; int idx=-1;
        stillInDock = QueryDockState(hwnd, nullptr, &idx);
        g_pending_readd = false;
        if (stillInDock && !g_lastTabTitle.empty())
        {
          // As a last resort, re-add in the same slot to force a repaint
          ReaddWithSameDock(hwnd, g_lastTabTitle);
        }
        return 0;
      }
      break;

    case WM_CONTEXTMENU:
    {
      int x = GET_LP_X(lp), y = GET_LP_Y(lp);
      if (x == -1 && y == -1) { RECT r{}; GetWindowRect(hwnd, &r); x=(r.left+r.right)/2; y=(r.top+r.bottom)/2; }
      LogF("[WM_CONTEXTMENU] at %d,%d (src=0x%p)", x, y, (void*)wp);
      ShowLocalDockMenu(hwnd, x, y);
      return 0;
    }

    case WM_COMMAND:
      switch (LOWORD(wp))
      {
        case IDOK:
        case IDCANCEL:
          SendMessage(hwnd, WM_CLOSE, 0, 0);
          return 0;
      }
      break;

    case WM_CLOSE:
    {
      LogRaw("[WM_CLOSE]");
      bool f=false; int idx=-1; bool id = DockIsChildOfDock ? (DockIsChildOfDock(hwnd, &f) >= 0) : false;
      LogF("DockIsChildOfDock (on close) -> inDock=%d float=%d", (int)id, (int)f);
      if (id && DockWindowRemove) DockWindowRemove(hwnd);
#ifdef _WIN32
      g_controller = nullptr; g_webview = nullptr;
#endif
      DestroyWindow(hwnd);
      g_dlg = nullptr;
      return 0;
    }

    case WM_DESTROY:
      LogRaw("[WM_DESTROY]");
#ifdef _WIN32
      if (g_hWebView2Loader) { FreeLibrary(g_hWebView2Loader); g_hWebView2Loader = nullptr; }
      if (g_com_initialized) { CoUninitialize(); g_com_initialized = false; }
#endif
      return 0;
  }
  return 0;
}

// --------------------------------------------------------------------
// Open / Activate
// --------------------------------------------------------------------
static void OpenOrActivate(const std::string& url)
{
  if (g_dlg && IsWindow(g_dlg))
  {
    bool isFloat=false; int idx=-1;
    bool inDock = DockIsChildOfDock ? (DockIsChildOfDock(g_dlg, &isFloat) >= 0) : false;
    LogF("[OpenOrActivate] hasWnd, inDock=%d idx=%d float=%d", (int)inDock, idx, (int)isFloat);
    if (inDock)
    {
      if (DockWindowActivate) { DockWindowActivate(g_dlg); LogRaw("DockWindowActivate"); }
      if (DockWindowRefreshForHWND) DockWindowRefreshForHWND(g_dlg);
      if (DockWindowRefresh) DockWindowRefresh();
    }
    else
    {
#ifdef _WIN32
      ShowWindow(g_dlg, IsIconic(g_dlg) ? SW_RESTORE : SW_SHOW);
      SetForegroundWindow(g_dlg);
      SetActiveWindow(g_dlg);
      BringWindowToTop(g_dlg);
#else
      ShowWindow(g_dlg, SW_SHOW);
#endif
    }
    UpdateTitlesExtractAndApply(g_dlg);
    return;
  }

#ifdef _WIN32
  struct MyDLGTEMPLATE : DLGTEMPLATE { WORD ext[3]; MyDLGTEMPLATE(){ memset(this,0,sizeof(*this)); } } t;
  t.style = DS_SETFONT | DS_FIXEDSYS | DS_MODALFRAME | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME;
  t.cx = 900; t.cy = 600;
  t.dwExtendedStyle = 0;
  char* urlParam = _strdup(url.c_str());
  g_dlg = CreateDialogIndirectParam((HINSTANCE)g_hInst, &t, g_hwndParent, (DLGPROC)WebViewDlgProc, (LPARAM)urlParam);
  LogF("CreateDialogIndirectParam -> %p (gle=%lu)", g_dlg, GetLastError());
#else
  char* urlParam = strdup(url.c_str());
  g_dlg = CreateDialogParam((HINSTANCE)g_hInst, MAKEINTRESOURCE(IDD_WEBVIEW), g_hwndParent, WebViewDlgProc, (LPARAM)urlParam);
  LogF("CreateDialogParam -> %p", g_dlg);
#endif
}

// --------------------------------------------------------------------
// API
// --------------------------------------------------------------------
static void API_WEBVIEW_Navigate(const char* url)
{
  if (!url || !*url) return;
#ifdef _WIN32
  if (!g_dlg || !IsWindow(g_dlg))
  {
    OpenOrActivate(url);
    return;
  }
  if (g_webview) { std::wstring wurl = Widen(std::string(url)); g_webview->Navigate(wurl.c_str()); }
#else
  if (!g_dlg || !IsWindow(g_dlg)) { OpenOrActivate(url); return; }
  if (g_webView)
  {
    NSString* s = [NSString stringWithUTF8String:url];
    NSURL* u = [NSURL URLWithString:s];
    if (u) [g_webView loadRequest:[NSURLRequest requestWithURL:u]];
  }
#endif
}

// --------------------------------------------------------------------
// Hook command (OPEN; not toggle)
// --------------------------------------------------------------------
static bool HookCommandProc(int cmd, int /*flag*/)
{
  if (cmd == g_command_id) { OpenOrActivate(kDefaultURL); return true; }
  return false;
}

// --------------------------------------------------------------------
// Entry
// --------------------------------------------------------------------
extern "C" REAPER_PLUGIN_DLL_EXPORT int
REAPER_PLUGIN_ENTRYPOINT(REAPER_PLUGIN_HINSTANCE hInstance, reaper_plugin_info_t* rec)
{
  g_hInst = hInstance;

  if (rec)
  {
    if (rec->caller_version != REAPER_PLUGIN_VERSION || !rec->GetFunc) return 0;
    if (REAPERAPI_LoadAPI(rec->GetFunc) != 0) return 0;

    g_hwndParent = rec->hwnd_main;
    LogRaw("=== Plugin init ===");

    g_command_id = plugin_register("command_id", (void*)"FRZZ_WEBVIEW_OPEN");
    if (g_command_id)
    {
      static gaccel_register_t gaccel = {{0,0,0}, "WebView: Open (dockable)"};
      gaccel.accel.cmd = g_command_id;
      plugin_register("gaccel", &gaccel);
      plugin_register("hookcommand", (void*)HookCommandProc);
      LogF("Registered command id=%d", g_command_id);
    }

    plugin_register("APIdef_WEBVIEW_Navigate", (void*)"void,const char*,url");
    plugin_register("API_WEBVIEW_Navigate",   (void*)API_WEBVIEW_Navigate);
    return 1;
  }
  else
  {
    LogRaw("=== Plugin unload ===");
    plugin_register("hookcommand", (void*)NULL);
    plugin_register("gaccel", (void*)NULL);
    if (g_command_id) plugin_register("command_id", (void*)NULL);

    if (g_dlg && IsWindow(g_dlg))
    {
      bool f=false; int idx=-1; bool id = DockIsChildOfDock ? (DockIsChildOfDock(g_dlg, &f) >= 0) : false;
      LogF("Unload: inDock=%d float=%d", (int)id, (int)f);
      if (id && DockWindowRemove) DockWindowRemove(g_dlg);
      DestroyWindow(g_dlg);
      g_dlg = nullptr;
    }
#ifdef _WIN32
    g_controller = nullptr; g_webview = nullptr;
    if (g_hWebView2Loader) { FreeLibrary(g_hWebView2Loader); g_hWebView2Loader = nullptr; }
    if (g_com_initialized) { CoUninitialize(); g_com_initialized = false; }
#else
    g_webView = nil;
#endif
  }
  return 0;
}
