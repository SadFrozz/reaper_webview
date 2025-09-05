#ifdef _WIN32
    #define WM_APP_NAVIGATE (WM_APP + 1)
    #include <windows.h>
    #include <string>
    #include <wrl.h>
    #include <wil/com.h>
    #include "WebView2.h"
#else
    #import <Cocoa/Cocoa.h>
    #import <WebKit/WebKit.h>
    #include <string>
#endif

#include "WDL/wdltypes.h"
#include "sdk/reaper_plugin.h"

#define REAPERAPI_IMPLEMENT
#include "sdk/reaper_plugin_functions.h"


// ================================================================= //
//                            ЛОГИРОВАНИЕ                            //
// ================================================================= //
REAPER_PLUGIN_HINSTANCE g_hInst = nullptr;
void Log(const char* format, ...) {
    char buf[4096];
    va_list args;
    va_start(args, format);
    vsnprintf(buf, sizeof(buf), format, args);
    va_end(args);
#ifdef _WIN32
    OutputDebugStringA("[reaper_webview] ");
    OutputDebugStringA(buf);
    OutputDebugStringA("\n");
    if (GetResourcePath) {
        char path[MAX_PATH];
        strcpy(path, GetResourcePath());
        strcat(path, "\\reaper_webview_log.txt");
        FILE* fp = fopen(path, "a");
        if (fp) { fprintf(fp, "%s\n", buf); fclose(fp); }
    }
#else
    NSLog(@"[reaper_webview] %s", buf);
#endif
}

// ================================================================= //
//                      ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ                        //
// ================================================================= //
HWND g_hwndParent = nullptr;
#ifdef _WIN32
    HWND g_plugin_hwnd = nullptr;
    wil::com_ptr<ICoreWebView2Controller> webviewController;
    wil::com_ptr<ICoreWebView2> webview;
    HMODULE g_hWebView2Loader = nullptr;
#else
    NSWindow* g_pluginWindow = nil; WKWebView* g_webView = nil; id g_delegate = nil;
#endif

// ================================================================= //
//                ОБЪЯВЛЕНИЕ ФУНКЦИЙ С C-СВЯЗЫВАНИЕМ                //
// ================================================================= //

// ИСПРАВЛЕНИЕ: Оборачиваем функции для Reaper в extern "C"
extern "C" {
    void WEBVIEW_Navigate(const char* url);
    void Action_OpenWebView(int command, int val, int valhw, int relmode, HWND hwnd);
}

static void OpenWebViewWindow(const std::string& url);
static gaccel_register_t g_accel_reg = { { 0, 0, 0 }, "WebView: Open (default)" };

// ================================================================= //
//                       ТОЧКА ВХОДА ПЛАГИНА                         //
// ================================================================= //

extern "C" REAPER_PLUGIN_DLL_EXPORT int
REAPER_PLUGIN_ENTRYPOINT(REAPER_PLUGIN_HINSTANCE hInstance, reaper_plugin_info_t* rec)
{
    g_hInst = hInstance;
    if (!rec) return 0;
    if (rec->caller_version != REAPER_PLUGIN_VERSION || !rec->GetFunc) return 0;
    if (REAPERAPI_LoadAPI(rec->GetFunc) != 0) return 0;
    
    g_hwndParent = rec->hwnd_main;
    Log("Plugin loaded successfully. API initialized.");

    int cmdId = plugin_register("command_id", (void*)Action_OpenWebView);
    if (cmdId > 0) {
        g_accel_reg.accel.cmd = cmdId;
        plugin_register("gaccel", &g_accel_reg);
        plugin_register("command_id_lookup", (void*)"_FRZZ_WEBVIEW_OPEN_DEFAULT");
        Log("Action 'WebView: Open (default)' registered with command ID %d", cmdId);
    } else {
        Log("!!! FAILED to register action.");
    }
    
    plugin_register("APIdef_WEBVIEW_Navigate", (void*)"void,const char*,url");
    plugin_register("API_WEBVIEW_Navigate", (void*)WEBVIEW_Navigate);
    Log("API function 'WEBVIEW_Navigate' registered.");

    return 1;
}

// ================================================================= //
//                  РЕАЛИЗАЦИЯ ФУНКЦИЙ ДЛЯ REAPER                    //
// ================================================================= //
void Action_OpenWebView(int command, int val, int valhw, int relmode, HWND hwnd)
{
    Log("Action_OpenWebView triggered!");
    OpenWebViewWindow("https://www.reaper.fm/");
}

void WEBVIEW_Navigate(const char* url)
{
    Log("API WEBVIEW_Navigate called with URL: %s", url);
    if (!url || !strlen(url)) return;
#ifdef _WIN32
    if (!g_plugin_hwnd || !IsWindow(g_plugin_hwnd))
        OpenWebViewWindow(std::string(url));
    else {
        char* copy = _strdup(url);
        PostMessage(g_plugin_hwnd, WM_APP_NAVIGATE, 0, (LPARAM)copy);
        ShowWindow(g_plugin_hwnd, SW_SHOW); SetForegroundWindow(g_plugin_hwnd);
    }
#else
    if (!g_pluginWindow)
        OpenWebViewWindow(std::string(url));
    else {
        NSString* nsURL = [NSString stringWithUTF8String:url];
        [g_delegate performSelectorOnMainThread:@selector(navigate:)
                                   withObject:nsURL waitUntilDone:NO];
        [g_pluginWindow makeKeyAndOrderFront:nil];
    }
#endif
}

// ================================================================= //
//                    РЕАЛИЗАЦИЯ ДЛЯ WINDOWS (ИЗМЕНЕНИЯ)             //
// ================================================================= //

#ifdef _WIN32
LRESULT CALLBACK WebViewWndProc(HWND, UINT, WPARAM, LPARAM);
void OpenWebViewWindow(const std::string& url)
{
    Log("OpenWebViewWindow called for URL: %s", url.c_str());
    if (!LoadLibraryA("WebView2Loader.dll")) {
        Log("!!! FAILED: WebView2Loader.dll not found.");
        MessageBox(g_hwndParent, "WebView2 Runtime not found.\nPlease install Microsoft Edge WebView2 Runtime.", "Error", MB_ICONERROR);
        return;
    }
    if (g_plugin_hwnd && IsWindow(g_plugin_hwnd)) {
        Log("Window already exists, bringing to front.");
        ShowWindow(g_plugin_hwnd, SW_SHOW); SetForegroundWindow(g_plugin_hwnd); return;
    }
    WNDCLASSA wc{0};
    wc.lpfnWndProc = WebViewWndProc; wc.hInstance = (HINSTANCE)g_hInst; wc.lpszClassName = "MyWebViewPlugin_WindowClass"; wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    if (!RegisterClassA(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        Log("!!! FAILED to register window class. Error: %lu", GetLastError());
        MessageBox(g_hwndParent, "Failed to register window class.", "Tracer Error", MB_ICONERROR); return;
    }
    Log("Window class registered successfully.");
    char* url_param = _strdup(url.c_str());
    g_plugin_hwnd = CreateWindowExA(
        0, wc.lpszClassName, "Интегрированный WebView (Windows)",
        WS_POPUPWINDOW | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_VISIBLE,
        CW_USEDEFAULT, CW_USEDEFAULT, 1280, 720,
        g_hwndParent, NULL, (HINSTANCE)g_hInst, (LPVOID)url_param);
    if (!g_plugin_hwnd) {
        Log("!!! FAILED to create window. Error: %lu", GetLastError());
        MessageBox(g_hwndParent, "Failed to create window.", "Tracer Error", MB_ICONERROR);
        free(url_param); return;
    }
    Log("Window created successfully (hwnd: %p).", g_plugin_hwnd);
}
LRESULT CALLBACK WebViewWndProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam) {
    switch (uMsg) {
        case WM_CREATE: {
            Log("WM_CREATE received for hwnd %p.", hwnd);
            char* initial_url_c = reinterpret_cast<char*>(((LPCREATESTRUCTA)lParam)->lpCreateParams);
            if (!initial_url_c) { Log("!!! WM_CREATE: lpCreateParams is NULL."); break; }
            std::string initial_url_str(initial_url_c);
            free(initial_url_c);
            std::wstring w_url(initial_url_str.begin(), initial_url_str.end());
            Log("WM_CREATE: Initial URL is %s", initial_url_str.c_str());
            g_hWebView2Loader = LoadLibraryA("WebView2Loader.dll");
            if (!g_hWebView2Loader) { Log("!!! WM_CREATE: Failed to load WebView2Loader.dll again."); DestroyWindow(hwnd); return 0; }
            using CreateEnv_t = HRESULT (STDMETHODCALLTYPE*)(PCWSTR, PCWSTR, ICoreWebView2EnvironmentOptions*, ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler*);
            auto pCreate = reinterpret_cast<CreateEnv_t>(GetProcAddress(g_hWebView2Loader, "CreateCoreWebView2EnvironmentWithOptions"));
            if (!pCreate) { Log("!!! WM_CREATE: Failed to get address of CreateCoreWebView2EnvironmentWithOptions."); DestroyWindow(hwnd); return 0; }
            Log("WM_CREATE: Starting WebView2 environment creation...");
            pCreate(nullptr, nullptr, nullptr,
                Microsoft::WRL::Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
                    [hwnd, w_url](HRESULT result, ICoreWebView2Environment* env) -> HRESULT {
                        Log("WebView env callback fired. HRESULT: 0x%lX", result);
                        if (FAILED(result)) { DestroyWindow(hwnd); return result; }
                        env->CreateCoreWebView2Controller(hwnd, Microsoft::WRL::Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                            [hwnd, w_url](HRESULT result, ICoreWebView2Controller* controller) -> HRESULT {
                                Log("WebView controller callback fired. HRESULT: 0x%lX", result);
                                if (controller) {
                                    webviewController = controller;
                                    webviewController->get_CoreWebView2(&webview);
                                    RECT rc; GetClientRect(hwnd, &rc);
                                    webviewController->put_Bounds(rc);
                                    webview->Navigate(w_url.c_str());
                                    Log("WebView controller created and navigation initiated.");
                                } else { DestroyWindow(hwnd); }
                                return S_OK;
                            }).Get());
                        return S_OK;
                    }).Get());
            break;
        }
        case WM_APP_NAVIGATE: {
            char* url = reinterpret_cast<char*>(lParam);
            Log("WM_APP_NAVIGATE received for URL: %s", url);
            if (webview && url) { std::wstring w_url(url, url + strlen(url)); webview->Navigate(w_url.c_str()); }
            free(url); return 0;
        }
        case WM_SIZE: { if (webviewController) { RECT rc; GetClientRect(hwnd, &rc); webviewController->put_Bounds(rc); } return 0; }
        case WM_DESTROY: {
            Log("WM_DESTROY received for hwnd %p. Cleaning up.", hwnd);
            if (webviewController) { webviewController->Close(); webviewController = nullptr; webview = nullptr; }
            if (g_hWebView2Loader) { FreeLibrary(g_hWebView2Loader); g_hWebView2Loader = nullptr; }
            g_plugin_hwnd = NULL; return 0;
        }
        default: return DefWindowProc(hwnd, uMsg, wParam, lParam);
    }
    return 0;
}

#else
// ================================================================= //
//                     РЕАЛИЗАЦИЯ ДЛЯ MACOS                          //
// ================================================================= //

// ... код для macOS остается без изменений, но будет выводить логи через NSLog ...

@interface WebViewDelegate : NSObject <NSWindowDelegate>
- (void)navigate:(NSString*)urlString;
@end

@implementation WebViewDelegate
- (void)windowWillClose:(NSNotification *)notification {
    Log("macOS window is closing.");
    g_pluginWindow = nil;
    g_webView = nil;
    g_delegate = nil;
}
- (void)navigate:(NSString*)urlString {
    Log("macOS navigating to: %s", [urlString UTF8String]);
    if (g_webView) {
        NSURL* url = [NSURL URLWithString:urlString];
        if (url) {
            NSURLRequest* request = [NSURLRequest requestWithURL:url];
            [g_webView loadRequest:request];
        }
    }
}
@end

void OpenWebViewWindow(const std::string& url) {
    Log("macOS OpenWebViewWindow called.");
    if (g_pluginWindow) {
        [g_pluginWindow makeKeyAndOrderFront:nil];
        return;
    }
    
    @autoreleasepool {
        NSRect frame = NSMakeRect(0, 0, 1280, 720);
        g_pluginWindow = [[NSWindow alloc] initWithContentRect:frame
                                                     styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
                                                       backing:NSBackingStoreBuffered defer:NO];
        [g_pluginWindow setTitle:@"Интегрированный WebView (macOS)"];
        [g_pluginWindow center];

        WKWebViewConfiguration* config = [[WKWebViewConfiguration alloc] init];
        g_webView = [[WKWebView alloc] initWithFrame:frame configuration:config];
        [g_pluginWindow setContentView:g_webView];
        
        g_delegate = [[WebViewDelegate alloc] init];
        [g_pluginWindow setDelegate:g_delegate];
        [g_pluginWindow makeKeyAndOrderFront:nil];
        [g_pluginWindow setReleasedWhenClosed:NO];

        NSString* nsURL = [NSString stringWithUTF8String:url.c_str()];
        if (nsURL) {
            [g_delegate performSelectorOnMainThread:@selector(navigate:) withObject:nsURL waitUntilDone:NO];
        }
    }
}
#endif