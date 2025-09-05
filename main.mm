// src/main.mm
#ifdef _WIN32
    // ИСПРАВЛЕНИЕ 4: Возвращаем определение WM_APP_NAVIGATE
    #define WM_APP_NAVIGATE (WM_APP + 1)
    #include <windows.h>
    #include <string>
    #include <wrl.h>
    #include <wil/com.h>
    #include "deps/WebView2.h"
#else
    #import <Cocoa/Cocoa.h>
    #import <WebKit/WebKit.h>
    #include <string>
#endif

#include "WDL/wdltypes.h"
#include "sdk/reaper_plugin_functions.h"

// ---------- Глобальные переменные ----------
void* g_hInst = nullptr;
HWND  g_hwndParent = nullptr;

#ifdef _WIN32
    HWND g_plugin_hwnd = nullptr;
    wil::com_ptr<ICoreWebView2Controller> webviewController;
    wil::com_ptr<ICoreWebView2> webview;
    HMODULE g_hWebView2Loader = nullptr;
#else
    NSWindow* g_pluginWindow = nil;
    WKWebView* g_webView = nil;
    // ИСПРАВЛЕНИЕ 2: Объявляем g_delegate
    id g_delegate = nil;
#endif

// ---------- Предварительные объявления (Forward Declarations) ----------
static void Action_OpenWebView(int, int, int, int, HWND);
static void OpenWebViewWindow(const std::string& url);
// ИСПРАВЛЕНИЕ 1: Добавляем предварительные объявления
static void WEBVIEW_Navigate(const char* url);
static gaccel_register_t g_accel_reg;


// ИСПРАВЛЕНИЕ 1: Определяем g_accel_reg до его использования
static gaccel_register_t g_accel_reg = {
    { 0, 0, 0 }, // accel { flag, key, cmd }
    "WebView: Open (default)" // desc
};


// ---------- Регистрация плагина ----------
extern "C" REAPER_PLUGIN_DLL_EXPORT int
REAPER_PLUGIN_ENTRYPOINT(REAPER_PLUGIN_HINSTANCE hInstance,
                         reaper_plugin_info_t* rec)
{
    if (!rec) return 0;
    g_hInst     = hInstance;
    g_hwndParent = rec->hwnd_main;

    if (rec->caller_version != REAPER_PLUGIN_VERSION) return 0;

    // Команда «Открыть WebView»
    // ИСПРАВЛЕНИЕ 3: Добавляем явное приведение типа (void*)
    int cmdId = rec->Register("command_id", (void*)Action_OpenWebView);
    
    // Зарегистрируем ускоритель
    g_accel_reg.accel.cmd = cmdId;
    if (cmdId > 0) rec->Register("gaccel", &g_accel_reg);

    // Экспортируем функцию для скриптов
    rec->Register("API_WEBVIEW_Navigate", (void*)WEBVIEW_Navigate);

    return 1;
}

// ---------- Команда из меню ----------
static void Action_OpenWebView(int, int, int, int, HWND)
{
    OpenWebViewWindow("https://www.reaper.fm/");
}

// API для скриптов
static void WEBVIEW_Navigate(const char* url)
{
    if (!url || !strlen(url)) return;

#ifdef _WIN32
    if (!g_plugin_hwnd || !IsWindow(g_plugin_hwnd))
        OpenWebViewWindow(std::string(url));
    else {
        char* copy = _strdup(url);
        PostMessage(g_plugin_hwnd, WM_APP_NAVIGATE, 0, (LPARAM)copy);
        ShowWindow(g_plugin_hwnd, SW_SHOW);
        SetForegroundWindow(g_plugin_hwnd);
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

/* ------------------------------------------------------------------------ */
/* -------------------------- WINDOWS IMPLEMENTATION ---------------------- */
/* ------------------------------------------------------------------------ */

#ifdef _WIN32

LRESULT CALLBACK WebViewWndProc(HWND, UINT, WPARAM, LPARAM);

void OpenWebViewWindow(const std::string& url)
{
    if (!LoadLibraryA("WebView2Loader.dll")) {
        MessageBox(g_hwndParent, "WebView2 Runtime not found.\nPlease install Microsoft Edge WebView2 Runtime.", "Error", MB_ICONERROR);
        return;
    }

    if (g_plugin_hwnd && IsWindow(g_plugin_hwnd)) {
        ShowWindow(g_plugin_hwnd, SW_SHOW);
        SetForegroundWindow(g_plugin_hwnd);
        return;
    }

    WNDCLASSA wc{0};
    wc.lpfnWndProc   = WebViewWndProc;
    wc.hInstance     = (HINSTANCE)g_hInst;
    wc.lpszClassName = "MyWebViewPlugin_WindowClass";
    wc.hCursor       = LoadCursor(NULL, IDC_ARROW);

    if (!RegisterClassA(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        MessageBox(g_hwndParent, "Failed to register window class.", "Tracer Error", MB_ICONERROR);
        return;
    }

    char* url_param = _strdup(url.c_str());

    g_plugin_hwnd = CreateWindowExA(
        0,
        wc.lpszClassName,
        "Интегрированный WebView (Windows)",
        WS_OVERLAPPEDWINDOW | WS_VISIBLE,
        CW_USEDEFAULT, CW_USEDEFAULT, 1280, 720,
        NULL, // Родитель – nullptr, чтобы избежать проблем с модальностью
        NULL,
        (HINSTANCE)g_hInst,
        (LPVOID)url_param
    );

    if (!g_plugin_hwnd) {
        MessageBox(g_hwndParent, "Failed to create window.", "Tracer Error", MB_ICONERROR);
        free(url_param);
        return;
    }
}

LRESULT CALLBACK WebViewWndProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam)
{
    switch (uMsg) {
        case WM_CREATE: {
            char* initial_url_c = reinterpret_cast<char*>(((LPCREATESTRUCTA)lParam)->lpCreateParams);
            if (!initial_url_c) break;

            std::string initial_url_str(initial_url_c);
            free(initial_url_c);

            std::wstring w_url(initial_url_str.begin(), initial_url_str.end());

            g_hWebView2Loader = LoadLibraryA("WebView2Loader.dll");
            if (!g_hWebView2Loader) {
                MessageBox(hwnd, "WebView2 Runtime not found.", "Error", MB_ICONERROR);
                DestroyWindow(hwnd);
                return 0;
            }

            using CreateEnv_t = HRESULT (STDMETHODCALLTYPE*)(PCWSTR, PCWSTR, ICoreWebView2EnvironmentOptions*, ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler*);
            auto pCreate = reinterpret_cast<CreateEnv_t>(GetProcAddress(g_hWebView2Loader, "CreateCoreWebView2EnvironmentWithOptions"));

            if (!pCreate) {
                MessageBox(hwnd, "Failed to load WebView2 functions.", "Error", MB_ICONERROR);
                DestroyWindow(hwnd);
                return 0;
            }

            pCreate(nullptr, nullptr, nullptr,
                Microsoft::WRL::Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
                    [hwnd, w_url](HRESULT result, ICoreWebView2Environment* env) -> HRESULT {
                        if (FAILED(result)) {
                            MessageBox(hwnd, "Failed to create WebView2 environment.", "Error", MB_ICONERROR);
                            DestroyWindow(hwnd);
                            return result;
                        }
                        env->CreateCoreWebView2Controller(hwnd, Microsoft::WRL::Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                            [hwnd, w_url](HRESULT result, ICoreWebView2Controller* controller) -> HRESULT {
                                if (!controller) {
                                    MessageBox(hwnd, "Failed to create WebView2 controller.", "Error", MB_ICONERROR);
                                    DestroyWindow(hwnd);
                                    return S_OK;
                                }
                                webviewController = controller;
                                webviewController->get_CoreWebView2(&webview);
                                RECT rc; GetClientRect(hwnd, &rc);
                                webviewController->put_Bounds(rc);
                                webview->Navigate(w_url.c_str());
                                return S_OK;
                            }).Get()
                        );
                        return S_OK;
                    }).Get()
            );
            break;
        }

        case WM_APP_NAVIGATE: {
            char* url = reinterpret_cast<char*>(lParam);
            if (webview && url) {
                std::wstring w_url(url, url + strlen(url));
                webview->Navigate(w_url.c_str());
            }
            free(url);
            return 0;
        }

        case WM_SIZE: {
            if (webviewController) {
                RECT rc; GetClientRect(hwnd, &rc);
                webviewController->put_Bounds(rc);
            }
            return 0;
        }

        case WM_DESTROY: {
            if (webviewController) {
                webviewController->Close();
                webviewController = nullptr;
                webview = nullptr;
            }
            if (g_hWebView2Loader) {
                FreeLibrary(g_hWebView2Loader);
                g_hWebView2Loader = nullptr;
            }
            g_plugin_hwnd = NULL;
            // PostQuitMessage(0); // Не нужно для немодальных окон в DLL
            return 0;
        }

        default:
            return DefWindowProc(hwnd, uMsg, wParam, lParam);
    }
    return 0;
}

#else

// ####################### MACOS IMPLEMENTATION #######################

@interface WebViewDelegate : NSObject <NSWindowDelegate>
- (void)navigate:(NSString*)urlString;
@end

@implementation WebViewDelegate
- (void)windowWillClose:(NSNotification *)notification {
    g_pluginWindow = nil;
    g_webView = nil;
    g_delegate = nil;
}
- (void)navigate:(NSString*)urlString {
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