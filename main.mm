
// main.mm — REAPER WebView extension with docking + VERBOSE LOGGING
// - Возвращено и усилено логирование (в файл + REAPER-консоль + OutputDebugString)
// - Исправлены имена Dock_* API, корректная обработка WM_CLOSE из докера
// - Более подробные логи жизненного цикла WebView2 (NavigationStarting/Completed/ProcessFailed)
// - Поддержка toggle-состояния экшена
//
// Windows: WebView2 (ICoreWebView2); macOS: WKWebView (TODO: перенести на SWELL для докинга)
// © 2025

#ifdef _WIN32
  #define WIN32_LEAN_AND_MEAN
  #include <windows.h>
  #include <shellapi.h>
  #include <string>
  #include <mutex>
  #include <wrl.h>
  #include <wil/com.h>
  #include <objbase.h> // CoInitializeEx
  #include "deps/WebView2.h"
#else
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

// -----------------------------
// Глобалы
// -----------------------------
static REAPER_PLUGIN_HINSTANCE g_hInst = nullptr;
static HWND   g_hwndParent = nullptr;
static int    g_command_id = 0;

#ifdef _WIN32
static HWND   g_hwnd = nullptr;
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

// -----------------------------
// ЛОГИРОВАНИЕ (файл + консоль REAPER + OutputDebugString)
// -----------------------------
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
  // Пытаемся в ресурсный путь REAPER; если не доступен — рядом с плагином
  const char* res = GetResourcePath ? GetResourcePath() : nullptr;
  if (res && *res)
  {
#ifdef _WIN32
    std::string p = std::string(res) + "\\reaper_webview_log.txt";
#else
    std::string p = std::string(res) + "/reaper_webview_log.txt";
#endif
    return p;
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
  OutputDebugStringA(s);
  OutputDebugStringA("\r\n");
#endif
  if (ShowConsoleMsg)
  {
    ShowConsoleMsg(s);
    ShowConsoleMsg("\n");
  }
  // файл
  std::lock_guard<std::mutex> lk(log_mutex());
  FILE* f = nullptr;
#ifdef _WIN32
  fopen_s(&f, GetLogPath().c_str(), "ab");
#else
  f = fopen(GetLogPath().c_str(), "ab");
#endif
  if (f)
  {
    fwrite(s, 1, strlen(s), f);
    fwrite("\n", 1, 1, f);
    fclose(f);
  }
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

// -----------------------------
// Прототипы
// -----------------------------
static void ShowOrCreateWebView(const std::string& url, bool activate=true);
static void ToggleWindow();
static void UpdateToggleState(bool visible);
static void WEBVIEW_Navigate(const char* url);

// -----------------------------
// HOOK на команду
// -----------------------------
static bool HookCommandProc(int cmd, int /*flag*/)
{
  if (cmd == g_command_id) { ToggleWindow(); return true; }
  return false;
}

#ifdef _WIN32
// -----------------------------
// WNDPROC с расширенными логами
// -----------------------------
static LRESULT CALLBACK WebViewWndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
  switch (msg)
  {
    case WM_CREATE:
    {
      LogF("[WM_CREATE] hwnd=%p", hwnd);
      if (!g_com_initialized)
      {
        HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
        g_com_initialized = SUCCEEDED(hr);
        LogF("CoInitializeEx -> 0x%lX (ok=%d)", (long)hr, (int)g_com_initialized);
      }

      char* initial = (char*)((LPCREATESTRUCTA)lp)->lpCreateParams;
      std::string initial_url = initial ? initial : "https://www.reaper.fm/";
      LogF("Initial URL: %s", initial_url.c_str());

      if (initial) free(initial);

      // Грузим WebView2Loader.dll
      if (!g_hWebView2Loader)
      {
        std::string candidate = GetModuleDir() + "\\WebView2Loader.dll";
        g_hWebView2Loader = LoadLibraryA(candidate.c_str());
        if (!g_hWebView2Loader) g_hWebView2Loader = LoadLibraryA("WebView2Loader.dll");
        LogF("LoadLibrary(WebView2Loader) -> %p", (void*)g_hWebView2Loader);
      }
      if (!g_hWebView2Loader)
      {
        MessageBox(hwnd, "WebView2Loader.dll not found.\nShip it next to the plugin.", "WebView error", MB_ICONERROR);
        LogRaw("FATAL: WebView2Loader.dll not found");
        return 0;
      }

      using CreateEnv_t = HRESULT (STDMETHODCALLTYPE*)(PCWSTR, PCWSTR, ICoreWebView2EnvironmentOptions*,
        ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler*);
      auto pCreateEnv = (CreateEnv_t)GetProcAddress(g_hWebView2Loader, "CreateCoreWebView2EnvironmentWithOptions");
      LogF("GetProcAddress(CreateCoreWebView2EnvironmentWithOptions) -> %p", (void*)pCreateEnv);
      if (!pCreateEnv)
      {
        MessageBox(hwnd, "CreateCoreWebView2EnvironmentWithOptions not found.", "WebView error", MB_ICONERROR);
        LogRaw("FATAL: CreateCoreWebView2EnvironmentWithOptions not found");
        return 0;
      }

      std::wstring wurl(initial_url.begin(), initial_url.end());
      LogRaw("Start WebView2 environment...");
      pCreateEnv(
        nullptr, nullptr, nullptr,
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

                  // Навешиваем события для логирования
                  if (g_webview)
                  {
                    g_webview->add_NavigationStarting(
                      Microsoft::WRL::Callback<ICoreWebView2NavigationStartingEventHandler>(
                        [](ICoreWebView2* /*sender*/, ICoreWebView2NavigationStartingEventArgs* args)->HRESULT
                        {
                          wil::unique_cotaskmem_string uri;
                          if (args && SUCCEEDED(args->get_Uri(&uri))) LogF("[NavigationStarting] %S", uri.get());
                          return S_OK;
                        }).Get(), nullptr);

                    g_webview->add_NavigationCompleted(
                      Microsoft::WRL::Callback<ICoreWebView2NavigationCompletedEventHandler>(
                        [](ICoreWebView2* /*sender*/, ICoreWebView2NavigationCompletedEventArgs* args)->HRESULT
                        {
                          BOOL ok = FALSE; if (args) args->get_IsSuccess(&ok);
                          COREWEBVIEW2_WEB_ERROR_STATUS st = COREWEBVIEW2_WEB_ERROR_STATUS_UNKNOWN;
                          if (args) args->get_WebErrorStatus(&st);
                          LogF("[NavigationCompleted] ok=%d status=%d", (int)ok, (int)st);
                          return S_OK;
                        }).Get(), nullptr);

                    g_webview->add_ProcessFailed(
                      Microsoft::WRL::Callback<ICoreWebView2ProcessFailedEventHandler>(
                        [](ICoreWebView2* /*sender*/, ICoreWebView2ProcessFailedEventArgs* args)->HRESULT
                        {
                          COREWEBVIEW2_PROCESS_FAILED_KIND k;
                          if (args && SUCCEEDED(args->get_ProcessFailedKind(&k)))
                            LogF("[ProcessFailed] kind=%d", (int)k);
                          return S_OK;
                        }).Get(), nullptr);
                  }

                  RECT rc; GetClientRect(hwnd, &rc);
                  g_controller->put_Bounds(rc);
                  g_controller->put_IsVisible(TRUE);

                  LogRaw("Navigate initial URL...");
                  g_webview->Navigate(wurl.c_str());
                  return S_OK;
                }).Get());
            return S_OK;
          }).Get());

      return 0;
    }

    case WM_SIZE:
    {
      if (g_controller) { RECT rc; GetClientRect(hwnd, &rc); g_controller->put_Bounds(rc); }
      return 0;
    }

    case WM_APP+1: // navigate
    {
      const char* url = (const char*)lp;
      LogF("[WM_APP+1] Navigate -> %s", url ? url : "(null)");
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
      LogRaw("[WM_CLOSE]");
      // Если мы в доке — удалим из докера, затем уничтожим окно
      int dockidx = -1;
      if (Dock_IsChildOfDock && Dock_IsChildOfDock(hwnd, &dockidx) >= 0)
      {
        LogF("Dock_IsChildOfDock -> %d, calling DockWindowRemove()", dockidx);
        if (DockWindowRemove) DockWindowRemove(hwnd);
      }
      DestroyWindow(hwnd);
      return 0;
    }

    case WM_DESTROY:
    {
      LogRaw("[WM_DESTROY]");
      g_controller = nullptr;
      g_webview = nullptr;
      if (g_hWebView2Loader) { FreeLibrary(g_hWebView2Loader); g_hWebView2Loader = nullptr; }
      if (g_com_initialized) { CoUninitialize(); g_com_initialized = false; }
      g_hwnd = nullptr;
      UpdateToggleState(false);
      return 0;
    }
  }
  return DefWindowProc(hwnd, msg, wp, lp);
}
#endif // _WIN32

// -----------------------------
// Служебные
// -----------------------------
static void UpdateToggleState(bool visible)
{
  if (SetToggleCommandState) SetToggleCommandState(0, g_command_id, visible ? 1 : 0);
  if (RefreshToolbar2) RefreshToolbar2(0, g_command_id);
}

#ifdef _WIN32
static void RegisterWindowClass()
{
  static bool s_registered = false;
  if (s_registered) return;
  WNDCLASSEXA wc = {0};
  wc.cbSize = sizeof(wc);
  wc.style = CS_HREDRAW|CS_VREDRAW|CS_DBLCLKS;
  wc.lpfnWndProc = WebViewWndProc;
  wc.hInstance = (HINSTANCE)g_hInst;
  wc.hCursor = LoadCursor(NULL, IDC_ARROW);
  wc.lpszClassName = "FRZZ_WebView_Dock_Class";
  if (!RegisterClassExA(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS)
  {
    MessageBox(g_hwndParent, "Failed to register window class.", "WebView", MB_ICONERROR);
  }
  else s_registered = true;
}

static void ShowOrCreateWebView(const std::string& url, bool activate/*=true*/)
{
  if (!g_hwnd)
  {
    RegisterWindowClass();
    char* urlParam = _strdup(url.c_str());
    g_hwnd = CreateWindowExA(
      0, "FRZZ_WebView_Dock_Class", kTitle,
      // Top-level окно без меню — REAPER сам перепривяжет в док и добавит свою панель с Dock/Close
      WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN | WS_CLIPSIBLINGS,
      CW_USEDEFAULT, CW_USEDEFAULT, 1200, 700,
      g_hwndParent, nullptr, (HINSTANCE)g_hInst, (LPVOID)urlParam);
    LogF("CreateWindowEx -> %p (GetLastError=%lu)", g_hwnd, GetLastError());

    if (!g_hwnd) return;

    // Регистрируем окно в докер (persist ident)
    if (DockWindowAddEx) { DockWindowAddEx(g_hwnd, kTitle, kDockIdent, true); LogRaw("DockWindowAddEx OK"); }
    else if (DockWindowAdd) { DockWindowAdd(g_hwnd, kTitle, 0, true); LogRaw("DockWindowAdd OK"); }

    // Docker сам покажет окно; пусть не мигает отдельно
    ShowWindow(g_hwnd, SW_HIDE);
  }

  if (activate)
  {
    if (DockWindowActivate) { DockWindowActivate(g_hwnd); LogRaw("DockWindowActivate"); }
    else ShowWindow(g_hwnd, SW_SHOW);
  }
  UpdateToggleState(true);
}

static void ToggleWindow()
{
  if (g_hwnd && IsWindow(g_hwnd) && IsWindowVisible(g_hwnd))
  {
    LogRaw("[Toggle] close -> WM_CLOSE");
    SendMessage(g_hwnd, WM_CLOSE, 0, 0);
  }
  else
  {
    LogRaw("[Toggle] open");
    ShowOrCreateWebView("https://www.reaper.fm/", true);
  }
}
#else
static void ShowOrCreateWebView(const std::string& url, bool activate/*=true*/)
{
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
// SWS-style API
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
// Entry
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

    LogRaw("=== Plugin init ===");
#ifdef _WIN32
    LogF("DLL dir: %s", GetModuleDir().c_str());
#endif
    LogF("Log path: %s", GetLogPath().c_str());

    g_command_id = plugin_register("command_id", (void*)"FRZZ_WEBVIEW_TOGGLE");
    if (g_command_id)
    {
      static gaccel_register_t gaccel = {{0,0,0}, "WebView: Toggle (dockable)"};
      gaccel.accel.cmd = g_command_id;
      plugin_register("gaccel", &gaccel);
      plugin_register("hookcommand", (void*)HookCommandProc);
      LogF("Registered command id=%d", g_command_id);
    }
    plugin_register("APIdef_WEBVIEW_Navigate", (void*)"void,const char*,url");
    plugin_register("API_WEBVIEW_Navigate",   (void*)WEBVIEW_Navigate);

    return 1;
  }
  else
  {
    LogRaw("=== Plugin unload ===");
    plugin_register("hookcommand", (void*)NULL);
    plugin_register("gaccel", (void*)NULL);
    if (g_command_id) plugin_register("command_id", (void*)NULL);

#ifdef _WIN32
    if (g_hwnd && IsWindow(g_hwnd))
    {
      int dockidx = -1;
      if (Dock_IsChildOfDock && Dock_IsChildOfDock(g_hwnd, &dockidx) >= 0)
      {
        LogF("Unload: remove from dock %d", dockidx);
        if (DockWindowRemove) DockWindowRemove(g_hwnd);
      }
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
