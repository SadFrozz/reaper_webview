
// main.mm — REAPER WebView extension with dock support (Windows) and WebView2 fixes
// Drop-in replacement for original main.mm
//
// Notes:
// - Adds DockWindowAddEx()/DockWindowActivate()/DockWindowRemove() usage (Windows)
// - Adds action toggle state updates (SetToggleCommandState/RefreshToolbar2)
// - Fixes white-screen on Windows by calling CoInitializeEx and keeping the window alive
// - macOS path retained (WKWebView), TODO: switch to SWELL dialog to enable docking
//
// Build: ensure Ole32.lib linked on Windows (for CoInitializeEx), and ship WebView2Loader.dll next to the .dll
//
// © 2025

#ifdef _WIN32
  #define WIN32_LEAN_AND_MEAN
  #include <windows.h>
  #include <shellapi.h>
  #include <string>
  #include <wrl.h>
  #include <wil/com.h>
  #include "deps/WebView2.h"
  #include <objbase.h> // CoInitializeEx
#else
  #import <Cocoa/Cocoa.h>
  #import <WebKit/WebKit.h>
  #include <string>
#endif

#include "WDL/wdltypes.h"

// One translation unit must implement the REAPER API glue:
#ifndef REAPERAPI_IMPLEMENT
#define REAPERAPI_IMPLEMENT
#endif
#include "sdk/reaper_plugin.h"
#include "sdk/reaper_plugin_functions.h"

// -----------------------------
// Small logging helper
// -----------------------------
static void Log(const char* fmt, ...)
{
  char buf[2048] = {0};
  va_list ap; va_start(ap, fmt);
#ifdef _WIN32
  _vsnprintf(buf, sizeof(buf)-2, fmt, ap);
  OutputDebugStringA(buf);
  OutputDebugStringA("\r\n");
#else
  vsnprintf(buf, sizeof(buf)-2, fmt, ap);
  fprintf(stderr, "%s\n", buf);
#endif
  va_end(ap);
}

// -----------------------------
// Globals
// -----------------------------
static REAPER_PLUGIN_HINSTANCE g_hInst = nullptr;
static HWND   g_hwndParent = nullptr;
static int    g_command_id = 0;

#ifdef _WIN32
static HWND   g_hwnd = nullptr;
static bool   g_docked = false;
static const char* kDockIdent = "FRZZ_WEBVIEW_DOCK";
static const char* kTitle     = "WebView (dockable)";
static wil::com_ptr<ICoreWebView2Controller> g_controller;
static wil::com_ptr<ICoreWebView2>           g_webview;
static HMODULE g_hWebView2Loader = nullptr;
static bool   g_com_initialized = false;
#else
static NSWindow* g_pluginWindow = nil;
static WKWebView* g_webView = nil;
#endif

// Forward decls
static void ShowOrCreateWebView(const std::string& url, bool activate=true);
static void ToggleWindow();
static void UpdateToggleState(bool visible);

static void WEBVIEW_Navigate(const char* url);

// -----------------------------
// REAPER action hook
// -----------------------------
static bool HookCommandProc(int cmd, int flag)
{
  if (cmd == g_command_id)
  {
    ToggleWindow();
    return true;
  }
  return false;
}

// -----------------------------
// Windows: window proc
// -----------------------------
#ifdef _WIN32
static LRESULT CALLBACK WebViewWndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
  switch (msg)
  {
    case WM_CREATE:
    {
      Log("WM_CREATE");
      if (!g_com_initialized)
      {
        HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
        g_com_initialized = SUCCEEDED(hr);
        Log("CoInitializeEx -> 0x%lX", (long)hr);
      }

      // Extract initial URL
      char* initial = (char*)((LPCREATESTRUCTA)lp)->lpCreateParams;
      std::string initial_url = initial ? initial : "https://www.reaper.fm/";
      if (initial) free(initial);

      // Load WebView2 loader (prefer plugin dir)
      if (!g_hWebView2Loader)
      {
        char modPath[MAX_PATH] = {0};
        GetModuleFileNameA((HMODULE)g_hInst, modPath, MAX_PATH);
        std::string dir(modPath);
        size_t p = dir.find_last_of("\\/"); if (p != std::string::npos) dir.resize(p);
        std::string candidate = dir + "\\WebView2Loader.dll";
        g_hWebView2Loader = LoadLibraryA(candidate.c_str());
        if (!g_hWebView2Loader) g_hWebView2Loader = LoadLibraryA("WebView2Loader.dll");
      }

      if (!g_hWebView2Loader)
      {
        MessageBox(hwnd, "WebView2Loader.dll not found.\nShip it next to the plugin.", "WebView error", MB_ICONERROR);
        return 0;
      }

      using CreateEnv_t = HRESULT (STDMETHODCALLTYPE*)(PCWSTR, PCWSTR, ICoreWebView2EnvironmentOptions*,
        ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler*);
      auto pCreateEnv = (CreateEnv_t)GetProcAddress(g_hWebView2Loader, "CreateCoreWebView2EnvironmentWithOptions");
      if (!pCreateEnv)
      {
        MessageBox(hwnd, "CreateCoreWebView2EnvironmentWithOptions not found.", "WebView error", MB_ICONERROR);
        return 0;
      }

      // Start async environment creation
      std::wstring wurl(initial_url.begin(), initial_url.end());
      Log("Start WebView2 env...");
      pCreateEnv(
        nullptr, nullptr, nullptr,
        Microsoft::WRL::Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
          [hwnd, wurl](HRESULT result, ICoreWebView2Environment* env)->HRESULT
          {
            Log("Env cb: 0x%lX", (long)result);
            if (FAILED(result) || !env) return S_OK;
            env->CreateCoreWebView2Controller(hwnd,
              Microsoft::WRL::Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                [hwnd, wurl](HRESULT result, ICoreWebView2Controller* controller)->HRESULT
                {
                  Log("Controller cb: 0x%lX", (long)result);
                  if (!controller) return S_OK;
                  g_controller = controller;
                  g_controller->get_CoreWebView2(&g_webview);

                  RECT rc; GetClientRect(hwnd, &rc);
                  g_controller->put_Bounds(rc);
                  g_controller->put_IsVisible(TRUE);

                  g_webview->Navigate(wurl.c_str());
                  return S_OK;
                }).Get());
            return S_OK;
          }).Get());

      return 0;
    }

    case WM_SIZE:
      if (g_controller) { RECT rc; GetClientRect(hwnd, &rc); g_controller->put_Bounds(rc); }
      return 0;

    case WM_APP+1: // navigate
    {
      const char* url = (const char*)lp;
      if (g_webview && url)
      {
        std::wstring w(url, url + strlen(url));
        g_webview->Navigate(w.c_str());
      }
      if (url) free((void*)url);
      return 0;
    }

    case WM_CLOSE:
    {
      // Hide instead of destroy; remove from dock if needed
      if (DockIsChildOfDock && DockIsChildOfDock(hwnd, nullptr) >= 0)
      {
        DockWindowRemove(hwnd);
      }
      ShowWindow(hwnd, SW_HIDE);
      UpdateToggleState(false);
      return 0;
    }

    case WM_DESTROY:
      Log("WM_DESTROY");
      g_controller = nullptr;
      g_webview = nullptr;
      if (g_hWebView2Loader) { FreeLibrary(g_hWebView2Loader); g_hWebView2Loader = nullptr; }
      if (g_com_initialized) { CoUninitialize(); g_com_initialized = false; }
      g_hwnd = nullptr;
      UpdateToggleState(false);
      return 0;
  }
  return DefWindowProc(hwnd, msg, wp, lp);
}
#endif // _WIN32

// -----------------------------
// Helpers
// -----------------------------
static void UpdateToggleState(bool visible)
{
  // Section 0 is main section. If you register in other section, adapt.
  SetToggleCommandState ? SetToggleCommandState(0, g_command_id, visible ? 1 : 0) : (void)0;
  if (RefreshToolbar2) RefreshToolbar2(0, g_command_id);
}

#ifdef _WIN32
static void EnsureWindowRegistered(WNDCLASSEXA& wc)
{
  static bool s_registered = false;
  if (s_registered) return;
  ZeroMemory(&wc, sizeof(wc));
  wc.cbSize = sizeof(wc);
  wc.style = CS_HREDRAW|CS_VREDRAW|CS_DBLCLKS;
  wc.lpfnWndProc = WebViewWndProc;
  wc.hInstance = (HINSTANCE)g_hInst;
  wc.hCursor = LoadCursor(NULL, IDC_ARROW);
  wc.lpszClassName = "FRZZ_WebView_Dock_Class";
  if (!RegisterClassExA(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS)
  {
    MessageBox(g_hwndParent, "Failed to register window class.", "WebView", MB_ICONERROR);
    return;
  }
  s_registered = true;
}

static void ShowOrCreateWebView(const std::string& url, bool activate/*=true*/)
{
  if (!g_hwnd)
  {
    WNDCLASSEXA wc; EnsureWindowRegistered(wc);
    char* urlParam = _strdup(url.c_str());
    g_hwnd = CreateWindowExA(
      0, wc.lpszClassName, kTitle,
      WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN | WS_CLIPSIBLINGS,
      CW_USEDEFAULT, CW_USEDEFAULT, 1200, 700,
      g_hwndParent, nullptr, (HINSTANCE)g_hInst, (LPVOID)urlParam);
    if (!g_hwnd) { MessageBox(g_hwndParent, "Failed to create window", "WebView", MB_ICONERROR); return; }

    // Register in docker (persist ident)
    if (DockWindowAddEx) DockWindowAddEx(g_hwnd, kTitle, kDockIdent, true);
    else if (DockWindowAdd) DockWindowAdd(g_hwnd, kTitle, 0, true);

    // Hide standalone window first; the docker will show it
    ShowWindow(g_hwnd, SW_HIDE);
  }

  if (activate)
  {
    if (DockWindowActivate) DockWindowActivate(g_hwnd);
    else ShowWindow(g_hwnd, SW_SHOW);
  }
  UpdateToggleState(true);
}

static void ToggleWindow()
{
  if (g_hwnd && IsWindowVisible(g_hwnd))
  {
    SendMessage(g_hwnd, WM_CLOSE, 0, 0);
  }
  else
  {
    ShowOrCreateWebView("https://www.reaper.fm/", true);
  }
}
#else
static void ShowOrCreateWebView(const std::string& url, bool activate/*=true*/)
{
  // TODO macOS: switch to SWELL dialog (CreateDialog) to get an HWND, then DockWindowAddEx
  if (!g_pluginWindow)
  {
    NSRect frame = NSMakeRect(0, 0, 1200, 700);
    g_pluginWindow = [[NSWindow alloc] initWithContentRect:frame
                      styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable)
                        backing:NSBackingStoreBuffered defer:NO];

    [g_pluginWindow setTitle:@"WebView"];
    WKWebViewConfiguration* cfg = [[WKWebViewConfiguration alloc] init];
    g_webView = [[WKWebView alloc] initWithFrame:[[g_pluginWindow contentView] bounds] configuration:cfg];
    [g_webView setAutoresizingMask:(NSViewWidthSizable|NSViewHeightSizable)];
    [[g_pluginWindow contentView] addSubview:g_webView];

    NSURL* u = [NSURL URLWithString:[NSString stringWithUTF8String:url.c_str()]];
    if (u) [g_webView loadRequest:[NSURLRequest requestWithURL:u]];
  }
  if (activate) [g_pluginWindow makeKeyAndOrderFront:nil];
  UpdateToggleState(true);
}

static void ToggleWindow()
{
  if (g_pluginWindow && [g_pluginWindow isVisible]) { [g_pluginWindow orderOut:nil]; UpdateToggleState(false); }
  else ShowOrCreateWebView("https://www.reaper.fm/", true);
}
#endif

// -----------------------------
// SWS-style API function for scripts
// -----------------------------
static void WEBVIEW_Navigate(const char* url)
{
  if (!url || !*url) return;
#ifdef _WIN32
  if (!g_hwnd || !IsWindow(g_hwnd)) ShowOrCreateWebView(url, true);
  else
  {
    char* copy = _strdup(url);
    PostMessage(g_hwnd, WM_APP+1, 0, (LPARAM)copy);
  }
#else
  if (g_webView)
  {
    NSString* s = [NSString stringWithUTF8String:url];
    NSURL* u = [NSURL URLWithString:s];
    if (u) [g_webView loadRequest:[NSURLRequest requestWithURL:u]];
  }
#endif
}

// -----------------------------
// Entry point
// -----------------------------
extern "C" REAPER_PLUGIN_DLL_EXPORT int
REAPER_PLUGIN_ENTRYPOINT(REAPER_PLUGIN_HINSTANCE hInstance, reaper_plugin_info_t* rec)
{
  g_hInst = hInstance;

  if (rec)
  {
    if (rec->caller_version != REAPER_PLUGIN_VERSION || !rec->GetFunc) return 0;
    if (REAPERAPI_LoadAPI(rec->GetFunc) != 0) return 0;

    g_hwndParent = rec->hwnd_main;
    Log("Plugin init OK");

    // Register action + description
    g_command_id = plugin_register("command_id", (void*)"FRZZ_WEBVIEW_TOGGLE");
    if (g_command_id)
    {
      static gaccel_register_t gaccel = {{0,0,0}, "WebView: Toggle (dockable)"};
      gaccel.accel.cmd = g_command_id;
      plugin_register("gaccel", &gaccel);

      plugin_register("hookcommand", (void*)HookCommandProc);
    }

    // Expose API for scripts: WEBVIEW_Navigate(url)
    plugin_register("APIdef_WEBVIEW_Navigate", (void*)"void,const char*,url");
    plugin_register("API_WEBVIEW_Navigate",   (void*)WEBVIEW_Navigate);

    return 1;
  }
  else
  {
    // unload
    plugin_register("hookcommand", (void*)NULL);
    plugin_register("gaccel", (void*)NULL);
    if (g_command_id) plugin_register("command_id", (void*)NULL);

#ifdef _WIN32
    if (g_hwnd && IsWindow(g_hwnd))
    {
      if (DockWindowRemove) DockWindowRemove(g_hwnd);
      DestroyWindow(g_hwnd);
      g_hwnd = nullptr;
    }
    if (g_hWebView2Loader) { FreeLibrary(g_hWebView2Loader); g_hWebView2Loader = nullptr; }
    if (g_com_initialized) { CoUninitialize(); g_com_initialized = false; }
#else
    if (g_pluginWindow) { [g_pluginWindow close]; g_pluginWindow = nil; g_webView = nil; }
#endif
  }
  return 0;
}
