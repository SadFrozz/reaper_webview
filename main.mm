// main.mm — SWELL/WebView2, док/андок без «передокивания», кастомный/дефолтный заголовок
//  • default title ("WebView"):  dock tab="WebView", panel "DOMAIN[:port] - TITLE"; undock caption "DOMAIN[:port] - TITLE"
//  • custom title (!= "WebView"): док/андок показывают ровно заданный текст; панель скрыта
//  • порт показываем только если нестандартный (http:80, https:443 — скрываем)

#ifdef _WIN32
  #ifndef WIN32_LEAN_AND_MEAN
  #define WIN32_LEAN_AND_MEAN
  #endif
  #include <winsock2.h>
  #include <windows.h>
  #include <wrl.h>
  #include <wil/com.h>
  #include <objbase.h>
  #include <shlwapi.h>
  #include <direct.h>
  #pragma comment(lib, "Shlwapi.lib")
  #include "deps/WebView2.h"
#else
  #include "WDL/swell/swell.h"
  #include "WDL/swell/swell-dlggen.h"
  #import <Cocoa/Cocoa.h>
  #import <WebKit/WebKit.h>
#endif

#include <string>
#include <mutex>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <ctype.h>

#include "WDL/wdltypes.h"

#ifndef REAPERAPI_IMPLEMENT
#define REAPERAPI_IMPLEMENT
#endif
#include "sdk/reaper_plugin.h"
#include "sdk/reaper_plugin_functions.h"

// ============================== Build-time logging ==============================
#ifndef ENABLE_LOG
  #ifdef NDEBUG
    #define ENABLE_LOG 0
  #else
    #define ENABLE_LOG 1
  #endif
#endif

#if ENABLE_LOG
static std::mutex& log_mutex() { static std::mutex m; return m; }
static void LogRaw(const char* s)
{
  if (!s) return;
#ifdef _WIN32
  OutputDebugStringA(s); OutputDebugStringA("\r\n");
#endif
  if (ShowConsoleMsg) { ShowConsoleMsg(s); ShowConsoleMsg("\n"); }
  std::lock_guard<std::mutex> lk(log_mutex());
  const char* res = GetResourcePath ? GetResourcePath() : nullptr;
  std::string path = res && *res ? (std::string(res)
#ifdef _WIN32
    + "\\reaper_webview_log.txt"
#else
    + "/reaper_webview_log.txt"
#endif
  ) : "reaper_webview_log.txt";
  FILE* f = nullptr;
#ifdef _WIN32
  fopen_s(&f, path.c_str(), "ab");
#else
  f = fopen(path.c_str(), "ab");
#endif
  if (f) { fwrite(s, 1, strlen(s), f); fwrite("\n", 1, 1, f); fclose(f); }
}
static void LogF(const char* fmt, ...) {
  char buf[4096] = {0}; va_list ap; va_start(ap, fmt);
#ifdef _WIN32
  _vsnprintf(buf, sizeof(buf)-1, fmt, ap);
#else
  vsnprintf(buf, sizeof(buf)-1, fmt, ap);
#endif
  va_end(ap); LogRaw(buf);
}
#else
  static inline void LogRaw(const char*) {}
  static inline void LogF(const char*, ...) {}
#endif

// ============================== Globals ==============================
static REAPER_PLUGIN_HINSTANCE g_hInst = nullptr;
static HWND   g_hwndParent = nullptr;
static int    g_command_id = 0;

static const char* kDockIdent  = "reaper_webview";
static const char* kDefaultURL = "https://www.reaper.fm/";
static const char* kTitleBase  = "WebView"; // «дефолт» для логики

#ifdef _WIN32
static HWND   g_dlg = nullptr;
static wil::com_ptr<ICoreWebView2Controller> g_controller;
static wil::com_ptr<ICoreWebView2>           g_webview;
static HMODULE g_hWebView2Loader = nullptr;
static bool   g_com_initialized = false;
#else
static HWND       g_dlg = nullptr;
static WKWebView* g_webView = nil;
#endif

// заголовки/панель
static std::string g_lastTabTitle;
static std::string g_lastWndText;

static std::string g_titleOverride = kTitleBase; // API SetTitle; "WebView" == дефолтная логика

// док-состояние (для инфо/refresh)
static int   g_last_dock_idx   = -1;
static bool  g_last_dock_float = false;
static int   g_want_dock_on_create = -1; // -1 unknown(first run), 0 undock, 1 dock

// панель (в доке)
static const int IDC_TITLEBAR = 1002;
#ifdef _WIN32
static HWND   g_titleBar = nullptr;
static HFONT  g_titleFont = nullptr;
static HBRUSH g_titleBrush = nullptr;
static COLORREF g_titleTextColor = RGB(0,0,0);
static COLORREF g_titleBkColor   = GetSysColor(COLOR_BTNFACE);
static int    g_titleBarH = 24;       // фикс, без привязки к системному DPI
static int    g_titlePadX = 8;        // отступ слева
#else
static NSView*      g_titleBarView = nil;
static NSTextField* g_titleLabel   = nil;
static CGFloat      g_titleBarH    = 24.0;
static CGFloat      g_titlePadX    = 8.0;
#endif

// fwd
static INT_PTR WINAPI WebViewDlgProc(HWND, UINT, WPARAM, LPARAM);
static void OpenOrActivate(const std::string& url);

// ============================== helpers ==============================
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
#endif

static inline std::string ToLower(std::string s){ for (auto& c:s) c=(char)tolower((unsigned char)c); return s; }

// host[:port] (порт скрыть если http:80 / https:443)
static std::string ExtractDomainFromUrl(const std::string& url)
{
  if (url.empty()) return {};
  size_t scheme_end = url.find("://");
  std::string scheme; size_t host_start = 0;
  if (scheme_end != std::string::npos){ scheme = url.substr(0, scheme_end); host_start = scheme_end+3; }
  std::string scheme_l = ToLower(scheme);

  size_t end = url.find_first_of("/?#", host_start);
  std::string hostport = url.substr(host_start, (end==std::string::npos)?std::string::npos:(end-host_start));

  size_t at = hostport.rfind('@'); if (at != std::string::npos) hostport = hostport.substr(at+1);

  std::string host = hostport, port_str;
  if (!hostport.empty() && hostport[0]=='[') {
    size_t rb = hostport.find(']'); if (rb!=std::string::npos){ host=hostport.substr(0,rb+1); if (rb+1<hostport.size() && hostport[rb+1]==':') port_str=hostport.substr(rb+2); }
  } else {
    size_t colon = hostport.rfind(':');
    if (colon!=std::string::npos){ host=hostport.substr(0,colon); port_str=hostport.substr(colon+1); }
  }
  if (!host.empty() && host[0] != '[' && host.rfind("www.",0)==0) host = host.substr(4);

  bool drop_port = false;
  if (!port_str.empty()){
    int p=0; for(char c:port_str){ if(c<'0'||c>'9'){ p=-1; break;} p=p*10+(c-'0');}
    if (p>0 && ((scheme_l=="http" && p==80) || (scheme_l=="https" && p==443))) drop_port = true;
  }
  return drop_port || port_str.empty() ? host : (host + ":" + port_str);
}

static void SetWndText(HWND hwnd, const std::string& s)
{
  if (g_lastWndText == s) return;
#ifdef _WIN32
  SetWindowTextA(hwnd, s.c_str());
#else
  SetWindowText(hwnd, s.c_str());
#endif
  g_lastWndText = s;
}

static void SaveDockState(HWND hwnd)
{
  bool ff=false; int ii=-1;
  HWND cand[3] = { hwnd, GetParent(hwnd), GetAncestor(hwnd, GA_ROOT) };
  for (int k=0; k<3; ++k)
  {
    HWND h = cand[k]; if (!h) continue;
    bool f=false; int i = DockIsChildOfDock ? DockIsChildOfDock(h, &f) : -1;
    if (i >= 0) { g_last_dock_idx = i; g_last_dock_float = f; return; }
  }
  g_last_dock_idx = -1; g_last_dock_float = false;
}

static void SetTabTitleInplace(HWND hwnd, const std::string& tabCaption)
{
  SetWndText(hwnd, tabCaption);
  if (DockWindowRefreshForHWND) DockWindowRefreshForHWND(hwnd);
  if (DockWindowRefresh) DockWindowRefresh();
}

// ============================== Title panel (dock) ==============================
#ifdef _WIN32
static void DestroyTitleGdi()
{
  if (g_titleFont) { DeleteObject(g_titleFont); g_titleFont=nullptr; }
  if (g_titleBrush){ DeleteObject(g_titleBrush); g_titleBrush=nullptr; }
}
static void EnsureTitleBarCreated(HWND hwnd)
{
  if (g_titleBar && !IsWindow(g_titleBar)) g_titleBar = nullptr; // <=== анти-зомби
  if (g_titleBar) return;
  LOGFONT lf{}; SystemParametersInfo(SPI_GETICONTITLELOGFONT, sizeof(lf), &lf, 0);
  lf.lfHeight = -12; lf.lfWeight = FW_SEMIBOLD;
  g_titleFont = CreateFontIndirect(&lf);
  g_titleBkColor   = GetSysColor(COLOR_BTNFACE);
  g_titleTextColor = GetSysColor(COLOR_BTNTEXT);
  g_titleBrush = CreateSolidBrush(g_titleBkColor);

  g_titleBar = CreateWindowExA(0, "STATIC","", WS_CHILD|SS_LEFT|SS_NOPREFIX,
                               g_titlePadX, 0, 10, g_titleBarH, hwnd, (HMENU)(INT_PTR)IDC_TITLEBAR,
                               (HINSTANCE)g_hInst, NULL);
  if (g_titleBar && g_titleFont) SendMessage(g_titleBar, WM_SETFONT, (WPARAM)g_titleFont, TRUE);
}
static void LayoutTitleBarAndWebView(HWND hwnd, bool titleVisible)
{
  RECT rc; GetClientRect(hwnd, &rc);
  int top = 0;
  if (titleVisible && g_titleBar)
  {
    MoveWindow(g_titleBar, g_titlePadX, 0, (rc.right-rc.left) - 2*g_titlePadX, g_titleBarH, TRUE);
    ShowWindow(g_titleBar, SW_SHOWNA);
    top = g_titleBarH;
  }
  else if (g_titleBar) ShowWindow(g_titleBar, SW_HIDE);

  RECT brc = rc; brc.top += top;
  if (g_controller) g_controller->put_Bounds(brc);
}
static void SetTitleBarText(const std::string& s){ if (g_titleBar) SetWindowTextA(g_titleBar, s.c_str()); }
#else
static void EnsureTitleBarCreated(HWND hwnd)
{
  if (g_titleBarView) return;
  NSView* host = (NSView*)SWELL_GetView(hwnd); if (!host) return;
  g_titleBarView = [[NSView alloc] initWithFrame:NSMakeRect(0,0, host.bounds.size.width, g_titleBarH)];
  g_titleLabel   = [[NSTextField alloc] initWithFrame:NSMakeRect(g_titlePadX, 2, host.bounds.size.width-2*g_titlePadX, g_titleBarH-4)];
  [g_titleLabel setEditable:NO]; [g_titleLabel setBordered:NO]; [g_titleLabel setBezeled:NO];
  [g_titleLabel setDrawsBackground:YES];
  [g_titleLabel setBackgroundColor:[NSColor controlBackgroundColor]];
  [g_titleLabel setTextColor:[NSColor controlTextColor]];
  [g_titleLabel setFont:[NSFont systemFontOfSize:[NSFont systemFontSize]]];
  [g_titleBarView addSubview:g_titleLabel]; [host addSubview:g_titleBarView];
  [g_titleBarView setHidden:YES];
}
static void LayoutTitleBarAndWebView(HWND hwnd, bool titleVisible)
{
  NSView* host = (NSView*)SWELL_GetView(hwnd); if (!host) return;
  CGFloat top = 0;
  if (titleVisible && g_titleBarView)
  {
    [g_titleBarView setFrame:NSMakeRect(0,0, host.bounds.size.width, g_titleBarH)];
    [g_titleLabel   setFrame:NSMakeRect(g_titlePadX,2, host.bounds.size.width-2*g_titlePadX, g_titleBarH-4)];
    [g_titleBarView setHidden:NO];
    top = g_titleBarH;
  } else if (g_titleBarView) [g_titleBarView setHidden:YES];

  if (g_webView)
  {
    NSRect b = NSMakeRect(0, top, host.bounds.size.width, host.bounds.size.height - top);
    [g_webView setFrame:b];
  }
}
static void SetTitleBarText(const std::string& s)
{
  if (!g_titleLabel) return;
  NSString* t = [NSString stringWithUTF8String:s.c_str()];
  [g_titleLabel setStringValue:t ? t : @""];
}
#endif

// показать/скрыть панель + текст
static void UpdateTitleBarUI(HWND hwnd, const std::string& domain, const std::string& pageTitle, bool inDock, bool usePanel)
{
  EnsureTitleBarCreated(hwnd);
  const bool wantVisible = inDock && usePanel;
  std::string panelText = domain.empty() ? "…" : domain;
  if (!pageTitle.empty()) panelText += " - " + pageTitle;
  SetTitleBarText(panelText);
  LayoutTitleBarAndWebView(hwnd, wantVisible);
}

// ============================== титулы (общая логика) ==============================
static void UpdateTitlesExtractAndApply(HWND hwnd)
{
  std::string domain, pageTitle;

#ifdef _WIN32
  if (g_webview)
  {
    wil::unique_cotaskmem_string wsrc, wtitle;
    if (SUCCEEDED(g_webview->get_Source(&wsrc))  && wsrc)  domain    = ExtractDomainFromUrl(Narrow(wsrc.get()));
    if (SUCCEEDED(g_webview->get_DocumentTitle(&wtitle)) && wtitle) pageTitle = Narrow(wtitle.get());
  }
#else
  if (g_webView)
  {
    NSURL* u = g_webView.URL; if (u) domain = ExtractDomainFromUrl([[u absoluteString] UTF8String]);
    NSString* t = g_webView.title; if (t) pageTitle = [t UTF8String];
  }
#endif

  SaveDockState(hwnd);
  const bool inDock = (g_last_dock_idx >= 0);

  const bool defaultMode = (g_titleOverride.empty() || g_titleOverride == kTitleBase);

  if (defaultMode)
  {
    // док: вкладка "WebView", панель DOMAIN[:port] - TITLE
    if (inDock)
    {
      const std::string tabCaption = kTitleBase;
      if (tabCaption != g_lastTabTitle)
      {
        LogF("[TabTitle] in-dock (idx=%d float=%d) -> '%s'", g_last_dock_idx, (int)g_last_dock_float, tabCaption.c_str());
        g_lastTabTitle = tabCaption;
      }
      SetTabTitleInplace(hwnd, tabCaption);
      UpdateTitleBarUI(hwnd, domain, pageTitle, true, true);
    }
    else
    {
      // андок: просто "DOMAIN[:port] - TITLE"
      std::string wndCaption = domain.empty() ? "…" : domain;
      if (!pageTitle.empty()) wndCaption += " - " + pageTitle;
      SetWndText(hwnd, wndCaption);
      UpdateTitleBarUI(hwnd, domain, pageTitle, false, true); // панель скрыта макетом
      LogF("[TitleUpdate] undock caption='%s'", wndCaption.c_str());
    }
  }
  else
  {
    // кастомный заголовок
    if (inDock)
    {
      if (g_titleOverride != g_lastTabTitle)
      {
        LogF("[TabTitle] in-dock custom -> '%s'", g_titleOverride.c_str());
        g_lastTabTitle = g_titleOverride;
      }
      SetTabTitleInplace(hwnd, g_titleOverride);
      UpdateTitleBarUI(hwnd, domain, pageTitle, true, false); // панель скрыта
    }
    else
    {
      SetWndText(hwnd, g_titleOverride);
      UpdateTitleBarUI(hwnd, domain, pageTitle, false, false);
      LogF("[TitleUpdate] undock custom='%s'", g_titleOverride.c_str());
    }
  }
}

// ============================== диалог/докер ==============================
#ifndef _WIN32
#define IDD_WEBVIEW 2001
SWELL_DEFINE_DIALOG_RESOURCE_BEGIN(IDD_WEBVIEW, 0, "WebView", 300, 200, 1.8)
BEGIN
  CONTROL         "",-1,"customcontrol",WS_CHILD|WS_VISIBLE,0,0,300,200
END
SWELL_DEFINE_DIALOG_RESOURCE_END(IDD_WEBVIEW)
#endif

static void SizeWebViewToClient(HWND hwnd)
{
  bool isFloat=false; int idx=-1;
  bool inDock = DockIsChildOfDock ? (DockIsChildOfDock(hwnd, &isFloat) >= 0) : false;
  const bool wantPanel = inDock && (g_titleOverride == kTitleBase);
  LayoutTitleBarAndWebView(hwnd, wantPanel);
}

// ============================== WebView init ==============================
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
  std::string base = (res && *res) ? std::string(res) : ".";
  std::string udf  = base + "\\WebView2Data";
  LogF("userDataFolder: %s", udf.c_str());
  _mkdir(udf.c_str());

  if (!g_hWebView2Loader)
  {
    g_hWebView2Loader = LoadLibraryA("WebView2Loader.dll");
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

  std::wstring wurl; wurl.assign(initial_url.begin(), initial_url.end());
  std::wstring wudf; wudf.assign(udf.begin(), udf.end());

  LogRaw("Start WebView2 environment...");
  HRESULT hrEnv = pCreateEnv(nullptr, wudf.c_str(), nullptr,
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
              LayoutTitleBarAndWebView(hwnd, false);
              g_controller->put_IsVisible(TRUE);
              LogRaw("Navigate initial URL...");
              if (g_webview) g_webview->Navigate(wurl.c_str());
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
{ UpdateTitlesExtractAndApply((HWND)g_dlg); }
@end
static FRZWebViewDelegate* g_delegate = nil;

static void StartWebView(HWND hwnd, const std::string& initial_url)
{
  NSView* host = (NSView*)SWELL_GetView(hwnd); if (!host) return;
  WKWebViewConfiguration* cfg = [[WKWebViewConfiguration alloc] init];
  g_webView = [[WKWebView alloc] initWithFrame:[host bounds] configuration:cfg];
  g_delegate = [[FRZWebViewDelegate alloc] init];
  g_webView.navigationDelegate = g_delegate;
  [g_webView setAutoresizingMask:(NSViewWidthSizable|NSViewHeightSizable)];
  [host addSubview:g_webView];

  NSString* s = [NSString stringWithUTF8String:initial_url.c_str()];
  NSURL* u = [NSURL URLWithString:s]; if (u) [g_webView loadRequest:[NSURLRequest requestWithURL:u]];
  UpdateTitlesExtractAndApply(hwnd);
}
#endif

// ============================== контекстное меню дока ==============================
static inline int GET_LP_X(LPARAM lp) { return (int)(short)LOWORD(lp); }
static inline int GET_LP_Y(LPARAM lp) { return (int)(short)HIWORD(lp); }

static bool QueryDockState(HWND hwnd, bool* outFloat, int* outIdx)
{
  bool f=false; int i=-1; if (!outFloat) outFloat=&f; if (!outIdx) outIdx=&i;
  HWND cand[3] = { hwnd, GetParent(hwnd), GetAncestor(hwnd, GA_ROOT) };
  for (int k=0;k<3;k++)
  {
    HWND h=cand[k]; if(!h) continue;
    bool ff=false; int ii = DockIsChildOfDock ? DockIsChildOfDock(h,&ff) : -1;
    LogF("[DockQuery] cand=%p -> idx=%d float=%d", (void*)h, ii, (int)ff);
    if (ii>=0){ *outFloat=ff; *outIdx=ii; return true; }
  }
  *outFloat=false; *outIdx=-1;
  return false;
}


static void RememberWantDock(HWND hwnd)
{
  bool isFloat=false; int idx=-1;
  bool inDock = DockIsChildOfDock ? (DockIsChildOfDock(hwnd, &isFloat) >= 0) : false;
  g_want_dock_on_create = inDock ? 1 : 0;
  LogF("[DockRemember] last=%s (float=%d, idx=%d)", inDock?"DOCK":"UNDOCK", (int)isFloat, idx);
}

static void ShowLocalDockMenu(HWND hwnd, int x, int y)
{
  HMENU m = CreatePopupMenu(); if (!m) return;
  bool f=false; int idx=-1; bool inDock = QueryDockState(hwnd,&f,&idx);
  AppendMenuA(m, MF_STRING | (inDock?MF_CHECKED:0), 10001, inDock ? "Undock window" : "Dock window in Docker");
  AppendMenuA(m, MF_SEPARATOR, 0, NULL);
  AppendMenuA(m, MF_STRING, 10099, "Close");

  HWND owner = GetAncestor(hwnd, GA_ROOT); if (!owner) owner = hwnd;
  SetForegroundWindow(owner);
  int cmd = TrackPopupMenu(m, TPM_RIGHTBUTTON|TPM_RETURNCMD|TPM_NONOTIFY, x, y, 0, owner, NULL);
  DestroyMenu(m);
  if (!cmd) return;

  if (cmd == 10001)
  {
    bool nowFloat=false; int nowIdx=-1; bool nowDock = QueryDockState(hwnd,&nowFloat,&nowIdx);
    if (nowDock)
    {
      if (DockWindowRemove) DockWindowRemove(hwnd);
#ifdef _WIN32
      LONG_PTR st  = GetWindowLongPtr(hwnd, GWL_STYLE);
      LONG_PTR exs = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
      st &= ~WS_CHILD; st |= WS_OVERLAPPEDWINDOW;
      SetWindowLongPtr(hwnd, GWL_STYLE, st);
      SetWindowLongPtr(hwnd, GWL_EXSTYLE, exs & ~WS_EX_TOOLWINDOW);
      SetParent(hwnd, NULL);
      RECT rr{}; GetWindowRect(hwnd,&rr);
      int w = rr.right-rr.left, h = rr.bottom-rr.top; if (w<200||h<120){ w=900; h=600; }
      SetWindowPos(hwnd,NULL, rr.left, rr.top, w, h, SWP_NOZORDER|SWP_FRAMECHANGED|SWP_SHOWWINDOW);
      ShowWindow(hwnd, SW_SHOWNORMAL);
#else
      ShowWindow(hwnd, SW_SHOW);
#endif
    }
    else
    {
      if (DockWindowAddEx) DockWindowAddEx(hwnd, kTitleBase, kDockIdent, true);
      if (DockWindowActivate) DockWindowActivate(hwnd);
      if (DockWindowRefreshForHWND) DockWindowRefreshForHWND(hwnd);
      if (DockWindowRefresh) DockWindowRefresh();
    }
    UpdateTitlesExtractAndApply(hwnd);
  }
  else if (cmd == 10099) SendMessage(hwnd, WM_CLOSE, 0, 0);
}

// ============================== dlg proc ==============================
static INT_PTR WINAPI WebViewDlgProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
  switch (msg)
  {
    case WM_INITDIALOG:
    {
    g_dlg = hwnd;
    LogF("[WM_INITDIALOG] hwnd=%p", hwnd);

    char* initial = (char*)lp;
    std::string url = (initial && *initial) ? std::string(initial) : std::string(kDefaultURL);
    if (initial) free(initial);

    // Панель создаём заранее, но пока скрыта (до определения док-состояния)
    EnsureTitleBarCreated(hwnd);
    LayoutTitleBarAndWebView(hwnd, false);

    // === ВОССТАНОВЛЕНИЕ предыдущего состояния окна ===
    bool isFloat=false; int idx=-1;
    bool nowDock = QueryDockState(hwnd, &isFloat, &idx); // почти всегда false на новом диалоге — просто для логов

    if (g_want_dock_on_create == 1 /*DOCK*/ || (g_want_dock_on_create < 0 /*первый запуск*/))
    {
        if (DockWindowAddEx) { DockWindowAddEx(hwnd, kTitleBase, kDockIdent, true); LogRaw("Init: forcing DOCK -> DockWindowAddEx()"); }
        if (DockWindowActivate) { DockWindowActivate(hwnd); LogRaw("DockWindowActivate"); }
        if (DockWindowRefreshForHWND) { DockWindowRefreshForHWND(hwnd); LogRaw("DockWindowRefreshForHWND"); }
        if (DockWindowRefresh) { DockWindowRefresh(); LogRaw("DockWindowRefresh"); }
    }
    else // g_want_dock_on_create == 0 → UNDOCK
    {
    #ifdef _WIN32
        // гарантируем настоящий top-level
        LONG_PTR st  = GetWindowLongPtr(hwnd, GWL_STYLE);
        LONG_PTR exs = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
        st &= ~WS_CHILD; st |= WS_OVERLAPPEDWINDOW;
        SetWindowLongPtr(hwnd, GWL_STYLE, st);
        SetWindowLongPtr(hwnd, GWL_EXSTYLE, exs & ~WS_EX_TOOLWINDOW);
        SetParent(hwnd, NULL);
        RECT rr{}; GetWindowRect(hwnd, &rr);
        int w = rr.right-rr.left, h = rr.bottom-rr.top;
        if (w < 200 || h < 120) { w = 900; h = 600; }
        SetWindowPos(hwnd, NULL, rr.left, rr.top, w, h, SWP_NOZORDER|SWP_FRAMECHANGED|SWP_SHOWWINDOW);
        ShowWindow(hwnd, SW_SHOWNORMAL);
        LogRaw("Init: forcing UNDOCK -> top-level styles applied");
    #else
        ShowWindow(hwnd, SW_SHOW);
    #endif
    }

    // теперь состояние известно
    SaveDockState(hwnd);

    // Запускаем движок
    StartWebView(hwnd, url);
    UpdateTitlesExtractAndApply(hwnd);

    #ifdef _WIN32
    ShowWindow(hwnd, SW_SHOW); SetForegroundWindow(hwnd);
    #else
    ShowWindow(hwnd, SW_SHOW);
    #endif
    return 1;
    }

#ifdef _WIN32
    case WM_CTLCOLORSTATIC:
      if ((HWND)lp == g_titleBar)
      {
        HDC hdc = (HDC)wp;
        SetBkColor(hdc, g_titleBkColor);
        SetTextColor(hdc, g_titleTextColor);
        if (!g_titleBrush) g_titleBrush = CreateSolidBrush(g_titleBkColor);
        return (INT_PTR)g_titleBrush;
      }
      break;
#endif

    case WM_SIZE:
      SizeWebViewToClient(hwnd);
      return 0;

    case WM_CONTEXTMENU:
    {
      int x = GET_LP_X(lp), y = GET_LP_Y(lp);
      if (x == -1 && y == -1) { RECT r{}; GetWindowRect(hwnd, &r); x=(r.left+r.right)/2; y=(r.top+r.bottom)/2; }
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
    RememberWantDock(hwnd); // <=== запомнить док/андок перед закрытием

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
    // сбрасываем указатель, чтобы панель пересоздалась на новом окне
    g_titleBar = nullptr;
    DestroyTitleGdi();
    if (g_hWebView2Loader) { FreeLibrary(g_hWebView2Loader); g_hWebView2Loader = nullptr; }
    if (g_com_initialized) { CoUninitialize(); g_com_initialized = false; }
    #else
    g_webView = nil;
    g_titleBarView = nil; g_titleLabel = nil;
    #endif
    return 0;
  }
  return 0;
}

// ============================== open/activate ==============================
static void OpenOrActivate(const std::string& url)
{
  if (g_dlg && IsWindow(g_dlg))
  {
    bool isFloat=false; int idx=-1;
    bool inDock = DockIsChildOfDock ? (DockIsChildOfDock(g_dlg, &isFloat) >= 0) : false;
    if (inDock)
    {
      if (DockWindowActivate) DockWindowActivate(g_dlg);
      if (DockWindowRefreshForHWND) DockWindowRefreshForHWND(g_dlg);
      if (DockWindowRefresh) DockWindowRefresh();
    }
    else
    {
#ifdef _WIN32
      ShowWindow(g_dlg, IsIconic(g_dlg) ? SW_RESTORE : SW_SHOW);
      SetForegroundWindow(g_dlg); SetActiveWindow(g_dlg); BringWindowToTop(g_dlg);
#else
      ShowWindow(g_dlg, SW_SHOW);
#endif
    }
    UpdateTitlesExtractAndApply(g_dlg);
    return;
  }

#ifdef _WIN32
  struct MyDLGTEMPLATE : DLGTEMPLATE { WORD ext[3]; MyDLGTEMPLATE(){ memset(this,0,sizeof(*this)); } } t;
  t.style = DS_SETFONT | DS_FIXEDSYS | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_CLIPCHILDREN;
  t.cx = 900; t.cy = 600; t.dwExtendedStyle = 0;
  char* urlParam = _strdup(url.c_str());
  g_dlg = CreateDialogIndirectParam((HINSTANCE)g_hInst, &t, g_hwndParent, (DLGPROC)WebViewDlgProc, (LPARAM)urlParam);
  LogF("CreateDialogIndirectParam -> %p (gle=%lu)", g_dlg, GetLastError());
  if (g_dlg) { ShowWindow(g_dlg, SW_SHOW); SetForegroundWindow(g_dlg); }
#else
  char* urlParam = strdup(url.c_str());
  g_dlg = CreateDialogParam((HINSTANCE)g_hInst, MAKEINTRESOURCE(IDD_WEBVIEW), g_hwndParent, WebViewDlgProc, (LPARAM)urlParam);
  if (g_dlg) ShowWindow(g_dlg, SW_SHOW);
#endif
}

// ============================== API ==============================
static void API_WEBVIEW_Navigate(const char* url)
{
  if (!url || !*url) return;
#ifdef _WIN32
  if (!g_dlg || !IsWindow(g_dlg)) { OpenOrActivate(url); return; }
  if (g_webview) { std::wstring wurl = Widen(std::string(url)); g_webview->Navigate(wurl.c_str()); }
#else
  if (!g_dlg || !IsWindow(g_dlg)) { OpenOrActivate(url); return; }
  if (g_webView) { NSString* s=[NSString stringWithUTF8String:url]; NSURL* u=[NSURL URLWithString:s]; if (u) [g_webView loadRequest:[NSURLRequest requestWithURL:u]]; }
#endif
  UpdateTitlesExtractAndApply(g_dlg);
}

// NEW: SetTitle (default = "WebView")
static void API_WEBVIEW_SetTitle(const char* title_or_null)
{
  g_titleOverride = (title_or_null && *title_or_null) ? std::string(title_or_null) : std::string(kTitleBase);
  if (g_dlg && IsWindow(g_dlg)) UpdateTitlesExtractAndApply(g_dlg);
}

// ============================== Hook command ==============================
static bool HookCommandProc(int cmd, int /*flag*/)
{
  if (cmd == g_command_id) { OpenOrActivate(kDefaultURL); return true; }
  return false;
}

// ============================== Registration blocks ==============================
static void RegisterCommandId()
{
  g_command_id = plugin_register("command_id", (void*)"FRZZ_WEBVIEW_OPEN");
  if (g_command_id)
  {
    static gaccel_register_t gaccel = {{0,0,0}, "WebView: Open (default url)"};
    gaccel.accel.cmd = g_command_id;
    plugin_register("gaccel", &gaccel);
    plugin_register("hookcommand", (void*)HookCommandProc);
    LogF("Registered command id=%d", g_command_id);
  }
}
static void UnregisterCommandId()
{
  plugin_register("hookcommand", (void*)NULL);
  plugin_register("gaccel", (void*)NULL);
  if (g_command_id) plugin_register("command_id", (void*)NULL);
  g_command_id = 0;
}

static void RegisterAPI()
{
  plugin_register("APIdef_WEBVIEW_Navigate", (void*)"void,const char*");
  plugin_register("API_WEBVIEW_Navigate",   (void*)API_WEBVIEW_Navigate);

  // ВАЖНО: без имен параметров, чтобы не ловить «1 names but 0 types»
  plugin_register("APIdef_WEBVIEW_SetTitle", (void*)"void,const char*");
  plugin_register("API_WEBVIEW_SetTitle",    (void*)API_WEBVIEW_SetTitle);
}
static void UnregisterAPI()
{
  plugin_register("API_WEBVIEW_Navigate", (void*)NULL);
  plugin_register("APIdef_WEBVIEW_Navigate", (void*)NULL);
  plugin_register("API_WEBVIEW_SetTitle", (void*)NULL);
  plugin_register("APIdef_WEBVIEW_SetTitle", (void*)NULL);
}

// ============================== Entry ==============================
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

    RegisterCommandId();
    RegisterAPI();
    return 1;
  }
  else
  {
    LogRaw("=== Plugin unload ===");
    UnregisterAPI();
    UnregisterCommandId();

    if (g_dlg && IsWindow(g_dlg))
    {
      bool f=false; int idx=-1; bool id = DockIsChildOfDock ? (DockIsChildOfDock(g_dlg, &f) >= 0) : false;
      if (id && DockWindowRemove) DockWindowRemove(g_dlg);
      DestroyWindow(g_dlg);
      g_dlg = nullptr;
    }
#ifdef _WIN32
    DestroyTitleGdi();
    g_controller = nullptr; g_webview = nullptr;
    if (g_hWebView2Loader) { FreeLibrary(g_hWebView2Loader); g_hWebView2Loader = nullptr; }
    if (g_com_initialized) { CoUninitialize(); g_com_initialized = false; }
#else
    g_webView = nil;
    g_titleBarView = nil; g_titleLabel = nil;
#endif
  }
  return 0;
}
