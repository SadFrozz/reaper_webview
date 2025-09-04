// ================================================================= //
//        КРОССПЛАТФОРМЕННЫЙ WEBVIEW ПЛАГИН С API V3 (FIX)         //
// ================================================================= //

#ifdef _WIN32
    #undef REAPER_PLUGIN_VERSION  // Убираем конфликтующее определение
    #define _WIN32_WINNT 0x0601
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

// SDK REAPER
#include "WDL/wdltypes.h"
#include "sdk/reaper_plugin_functions.h"

// --- Глобальные переменные ---
void* g_hInst = NULL;
HWND g_hwndParent = NULL;

#ifdef _WIN32
    HWND g_plugin_hwnd = NULL;
    wil::com_ptr<ICoreWebView2Controller> webviewController;
    wil::com_ptr<ICoreWebView2> webview;
#else
    NSWindow* g_pluginWindow = nil;
    WKWebView* g_webView = nil;
    id g_delegate = nil;
#endif

// --- Прототипы и действия ---
void OpenWebViewWindow(std::string url);
static gaccel_register_t g_action = { { 0, 0, 0 }, "WebView: Open (default)" };
void Action_OpenWebView(void* t) { OpenWebViewWindow("https://www.reaper.fm/"); }

void WEBVIEW_Navigate(const char* url) {
    if (url && strlen(url) > 0) {
        #ifdef _WIN32
            if (!g_plugin_hwnd || !IsWindow(g_plugin_hwnd)) {
                OpenWebViewWindow(url);
            } else {
                char* url_copy = _strdup(url);
                PostMessage(g_plugin_hwnd, WM_APP_NAVIGATE, 0, (LPARAM)url_copy);
                ShowWindow(g_plugin_hwnd, SW_SHOW);
                SetForegroundWindow(g_plugin_hwnd);
            }
        #else
            if (!g_pluginWindow) {
                OpenWebViewWindow(url);
            } else {
                NSString* nsURL = [NSString stringWithUTF8String:url];
                [g_delegate performSelectorOnMainThread:@selector(navigate:) withObject:nsURL waitUntilDone:NO];
                [g_pluginWindow makeKeyAndOrderFront:nil];
            }
        #endif
    }
}

// --- Точка входа плагина ---
extern "C" {
    REAPER_PLUGIN_DLL_EXPORT int REAPER_PLUGIN_ENTRYPOINT(void* hInstance, reaper_plugin_info_t* rec) {
        if (rec) {
            g_hInst = hInstance;
            g_hwndParent = rec->hwnd_main;

            rec->Register("gaccel", &g_action);
            rec->Register("action", (void*)Action_OpenWebView);

            rec->Register("API_WEBVIEW_Navigate", (void*)WEBVIEW_Navigate);
            
            return 1;
        }
        return 0;
    }
}

// ================================================================= //
//                   РЕАЛИЗАЦИЯ ДЛЯ КАЖДОЙ ПЛАТФОРМЫ                 //
// ================================================================= //

#ifdef _WIN32
// ####################### WINDOWS IMPLEMENTATION #######################

LRESULT CALLBACK WebViewWndProc(HWND, UINT, WPARAM, LPARAM);

void OpenWebViewWindow(std::string url) {
    if (g_plugin_hwnd && IsWindow(g_plugin_hwnd)) {
        ShowWindow(g_plugin_hwnd, SW_SHOW);
        SetForegroundWindow(g_plugin_hwnd);
        return;
    }

    WNDCLASSA wc = { 0 };  // Используем ANSI версию
    wc.lpfnWndProc = WebViewWndProc;
    wc.hInstance = (HINSTANCE)g_hInst;
    wc.lpszClassName = "MyWebViewPlugin_WindowClass";  // ANSI строка
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    RegisterClassA(&wc);

    g_plugin_hwnd = CreateWindowExA(0, "MyWebViewPlugin_WindowClass", "Интегрированный WebView (Windows)",
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 1280, 720,
        g_hwndParent, NULL, (HINSTANCE)g_hInst, (LPVOID)url.c_str());

    if (g_plugin_hwnd) {
        ShowWindow(g_plugin_hwnd, SW_SHOW);
    }
}

LRESULT CALLBACK WebViewWndProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam) {
    switch (uMsg) {
    case WM_CREATE: {
        const char* initial_url = (const char*)((LPCREATESTRUCTA)lParam)->lpCreateParams;
        std::wstring w_url(initial_url, initial_url + strlen(initial_url));

        CreateCoreWebView2EnvironmentWithOptions(nullptr, nullptr, nullptr,
            Microsoft::WRL::Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
                [hwnd, w_url](HRESULT result, ICoreWebView2Environment* env) -> HRESULT {
                    env->CreateCoreWebView2Controller(hwnd, Microsoft::WRL::Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                        [hwnd, w_url](HRESULT result, ICoreWebView2Controller* controller) -> HRESULT {
                            if (controller != nullptr) {
                                webviewController = controller;
                                webviewController->get_CoreWebView2(&webview);
                                RECT bounds; GetClientRect(hwnd, &bounds);
                                webviewController->put_Bounds(bounds);
                                webview->Navigate(w_url.c_str());
                            }
                            return S_OK;
                        }).Get());
                    return S_OK;
                }).Get());
        break;
    }
    case WM_APP_NAVIGATE: {
        char* url = (char*)lParam;
        if (webview && url) {
            std::wstring w_url(url, url + strlen(url));
            webview->Navigate(w_url.c_str());
        }
        free(url);
        break;
    }
    case WM_SIZE:
        if (webviewController != nullptr) { RECT bounds; GetClientRect(hwnd, &bounds); webviewController->put_Bounds(bounds); }
        break;
    case WM_DESTROY:
        if (webviewController) webviewController->Close();
        g_plugin_hwnd = NULL;
        break;
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
        NSURLRequest* request = [NSURLRequest requestWithURL:url];
        [g_webView loadRequest:request];
    }
}
@end

void OpenWebViewWindow(std::string url) {
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
        [g_delegate navigate:nsURL];
    }
}

#endif