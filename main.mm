// ================================================================= //
//        КРОССПЛАТФОРМЕННЫЙ WEBVIEW ПЛАГИН С API V3 (FIX 2)       //
// ================================================================= //

#ifdef _WIN32
    #undef REAPER_PLUGIN_VERSION
    #define _WIN32_WINNT 0x0601
    #define WM_APP_NAVIGATE (WM_APP + 1)

    #include <windows.h>
    #include <string>
    #include <wrl.h>
    #include <wil/com.h>
    // Подключаем заголовочные файлы из папки deps
    #include "deps/WebView2.h"
    #include "deps/wil/com.h"
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
    HMODULE g_hWebView2Loader = NULL;
#else
    NSWindow* g_pluginWindow = nil;
    WKWebView* g_webView = nil;
    id g_delegate = nil;
#endif

// --- Прототипы ---
void OpenWebViewWindow(std::string url);

// ИСПРАВЛЕНИЕ: Сигнатура функции должна соответствовать ожиданиям Reaper API
static void Action_OpenWebView(int command, int val, int valhw, int relmode, HWND hwnd)
{
    OpenWebViewWindow("https://www.reaper.fm/");
}

// Возвращаемся к вашему оригинальному способу регистрации
static gaccel_register_t g_accel_reg = {
    { 0, 0, 0 },
    "WebView: Open (default)"
};


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
    REAPER_PLUGIN_DLL_EXPORT int REAPER_PLUGIN_ENTRYPOINT(REAPER_PLUGIN_HINSTANCE hInstance, reaper_plugin_info_t* rec) {
        if (!rec) return 0;

        g_hInst = hInstance;
        g_hwndParent = rec->hwnd_main;

        if (rec->caller_version != REAPER_PLUGIN_VERSION) {
            return 0;
        }
        
        // Регистрируем команду и получаем ее ID
        g_accel_reg.accel.cmd = rec->Register("command_id", (void*)Action_OpenWebView);
        if (g_accel_reg.accel.cmd > 0) {
            // Регистрируем action в секции Actions
            rec->Register("gaccel", &g_accel_reg);
        }

        rec->Register("API_WEBVIEW_Navigate", (void*)WEBVIEW_Navigate);
        
        return 1;
    }
}

// ================================================================= //
//                   РЕАЛИЗАЦИЯ ДЛЯ КАЖДОЙ ПЛАТФОРМЫ                 //
// ================================================================= //

#ifdef _WIN32
// ####################### WINDOWS IMPLEMENTATION #######################

typedef HRESULT (STDMETHODCALLTYPE* CreateWebView2EnvironmentWithOptions_t)(
    PCWSTR browserExecutableFolder,
    PCWSTR userDataFolder,
    ICoreWebView2EnvironmentOptions* environmentOptions,
    ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler* environment_created_handler);

LRESULT CALLBACK WebViewWndProc(HWND, UINT, WPARAM, LPARAM);

void OpenWebViewWindow(std::string url) {
    if (g_plugin_hwnd && IsWindow(g_plugin_hwnd)) {
        ShowWindow(g_plugin_hwnd, SW_SHOW);
        SetForegroundWindow(g_plugin_hwnd);
        return;
    }

    WNDCLASSA wc = { 0 };
    wc.lpfnWndProc = WebViewWndProc;
    wc.hInstance = (HINSTANCE)g_hInst;
    wc.lpszClassName = "MyWebViewPlugin_WindowClass";
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    RegisterClassA(&wc);

    char* url_param = _strdup(url.c_str());

    g_plugin_hwnd = CreateWindowExA(0, "MyWebViewPlugin_WindowClass", "Интегрированный WebView (Windows)",
        WS_OVERLAPPEDWINDOW, CW_USEDEFAULT, CW_USEDEFAULT, 1280, 720,
        g_hwndParent, NULL, (HINSTANCE)g_hInst, (LPVOID)url_param);

    if (!g_plugin_hwnd) {
        free(url_param);
    }
}

LRESULT CALLBACK WebViewWndProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam) {
    switch (uMsg) {
    case WM_CREATE: {
        char* initial_url_c = (char*)((LPCREATESTRUCTA)lParam)->lpCreateParams;
        if (!initial_url_c) break;

        std::string initial_url_str(initial_url_c);
        free(initial_url_c);

        std::wstring w_url(initial_url_str.begin(), initial_url_str.end());

        g_hWebView2Loader = LoadLibraryA("WebView2Loader.dll");
        if (!g_hWebView2Loader) {
            MessageBoxA(hwnd, "WebView2 Runtime not found. Please install Microsoft Edge WebView2 Runtime.", "Error", MB_ICONERROR);
            DestroyWindow(hwnd);
            break;
        }

        auto pCreateWebView2EnvironmentWithOptions =
            (CreateWebView2EnvironmentWithOptions_t)GetProcAddress(g_hWebView2Loader, "CreateCoreWebView2EnvironmentWithOptions");

        if (!pCreateWebView2EnvironmentWithOptions) {
            MessageBoxA(hwnd, "Failed to load WebView2 functions", "Error", MB_ICONERROR);
            DestroyWindow(hwnd);
            break;
        }

        pCreateWebView2EnvironmentWithOptions(nullptr, nullptr, nullptr,
            Microsoft::WRL::Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
                [hwnd, w_url](HRESULT result, ICoreWebView2Environment* env) -> HRESULT {
                    if (FAILED(result)) {
                        MessageBoxA(hwnd, "Failed to create WebView2 environment", "Error", MB_ICONERROR);
                        DestroyWindow(hwnd);
                        return result;
                    }

                    env->CreateCoreWebView2Controller(hwnd, Microsoft::WRL::Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                        [hwnd, w_url](HRESULT result, ICoreWebView2Controller* controller) -> HRESULT {
                            if (controller != nullptr) {
                                webviewController = controller;
                                webviewController->get_CoreWebView2(&webview);
                                RECT bounds;
                                GetClientRect(hwnd, &bounds);
                                webviewController->put_Bounds(bounds);
                                webview->Navigate(w_url.c_str());
                                ShowWindow(hwnd, SW_SHOW); // Показываем окно только после успешной инициализации
                            } else {
                                MessageBoxA(hwnd, "Failed to create WebView2 controller", "Error", MB_ICONERROR);
                                DestroyWindow(hwnd);
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
        if (webviewController != nullptr) {
            RECT bounds;
            GetClientRect(hwnd, &bounds);
            webviewController->put_Bounds(bounds);
        }
        break;
    case WM_DESTROY:
        if (webviewController) {
            webviewController->Close();
            webviewController = nullptr;
            webview = nullptr;
        }
        if (g_hWebView2Loader) {
            FreeLibrary(g_hWebView2Loader);
            g_hWebView2Loader = NULL;
        }
        g_plugin_hwnd = NULL;
        PostQuitMessage(0);
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
        if (url) {
            NSURLRequest* request = [NSURLRequest requestWithURL:url];
            [g_webView loadRequest:request];
        }
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
        if (nsURL) {
            // Вместо прямого вызова navigate, вызовем его через делегата, чтобы сохранить консистентность
            [g_delegate performSelectorOnMainThread:@selector(navigate:) withObject:nsURL waitUntilDone:NO];
        }
    }
}
#endif