// ================================================================= //
//        КРОССПЛАТФОРМЕННЫЙ WEBVIEW ПЛАГИН С API V3 (FIX 4)       //
// ================================================================= //

#ifdef _WIN32
    #undef REAPER_PLUGIN_VERSION
    #define _WIN32_WINNT 0x0601
    #define WM_APP_NAVIGATE (WM_APP + 1)

    #include <windows.h>
    #include <string>
    #include <wrl.h>
    #include <wil/com.h>
    #include <stdio.h> // Для sprintf
    
    #if __has_include("deps/WebView2.h")
        #include "deps/WebView2.h"
        #include "deps/wil/com.h"
    #else
        #include "WebView2.h"
        #include <wil/com.h>
    #endif
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

// В начале файла добавьте:
#ifndef _WIN32
    #define MessageBoxA(hwnd, text, caption, type) MessageBox(hwnd, text, caption, type)
#endif

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

static void Action_OpenWebView(int command, int val, int valhw, int relmode, HWND hwnd)
{
    // ДИАГНОСТИКА 1: Проверяем, вызывается ли Action
    #ifdef _WIN32
        MessageBoxA(g_hwndParent, "Debug 1: Action called.", "Tracer", MB_OK | MB_TOPMOST);
    #else
        MessageBox(g_hwndParent, "Debug 1: Action called.", "Tracer", MB_OK | MB_TOPMOST);
    #endif
    OpenWebViewWindow("https://www.reaper.fm/");
}

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

extern "C" {
    REAPER_PLUGIN_DLL_EXPORT int REAPER_PLUGIN_ENTRYPOINT(REAPER_PLUGIN_HINSTANCE hInstance, reaper_plugin_info_t* rec) {
        if (!rec) return 0;
        g_hInst = hInstance;
        g_hwndParent = rec->hwnd_main;
        if (rec->caller_version != REAPER_PLUGIN_VERSION) return 0;
        g_accel_reg.accel.cmd = rec->Register("command_id", (void*)Action_OpenWebView);
        if (g_accel_reg.accel.cmd > 0) rec->Register("gaccel", &g_accel_reg);
        rec->Register("API_WEBVIEW_Navigate", (void*)WEBVIEW_Navigate);
        return 1;
    }
}

#ifdef _WIN32
// ####################### WINDOWS IMPLEMENTATION #######################

typedef HRESULT (STDMETHODCALLTYPE* CreateWebView2EnvironmentWithOptions_t)(PCWSTR, PCWSTR, ICoreWebView2EnvironmentOptions*, ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler*);

LRESULT CALLBACK WebViewWndProc(HWND, UINT, WPARAM, LPARAM);

void OpenWebViewWindow(std::string url) {
    
    #ifdef _WIN32
        // Проверяем наличие WebView2 Runtime
        HMODULE hWebView2 = LoadLibraryA("WebView2Loader.dll");
        if (!hWebView2) {
            MessageBoxA(g_hwndParent, "WebView2 Runtime not found. Please install Microsoft Edge WebView2 Runtime.", "Error", MB_ICONERROR);
            return;
        }
        FreeLibrary(hWebView2);
    #endif
    // ДИАГНОСТИКА 2: Проверяем, вызывается ли функция создания окна
    MessageBoxA(g_hwndParent, "Debug 2: OpenWebViewWindow called.", "Tracer", MB_OK | MB_TOPMOST);

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
    
    // ДИАГНОСТИКА 3: Проверяем регистрацию класса окна
    if (!RegisterClassA(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        char error_buf[256];
        sprintf(error_buf, "Debug 3 FAILED: RegisterClassA failed! Error code: %lu", GetLastError());
        MessageBoxA(g_hwndParent, error_buf, "Tracer Error", MB_ICONERROR | MB_TOPMOST);
        return;
    }

    char* url_param = _strdup(url.c_str());

    g_plugin_hwnd = CreateWindowExA(
        0, 
        "MyWebViewPlugin_WindowClass", 
        "Интегрированный WebView (Windows)",
        WS_OVERLAPPEDWINDOW | WS_VISIBLE | WS_CHILD, // Добавляем WS_CHILD
        CW_USEDEFAULT, CW_USEDEFAULT, 1280, 720,
        g_hwndParent, // Родительское окно - REAPER
        NULL, 
        (HINSTANCE)g_hInst, 
        (LPVOID)url_param
    );

    if (g_plugin_hwnd) {
        MSG msg;
        while (GetMessage(&msg, g_plugin_hwnd, 0, 0)) {
            TranslateMessage(&msg);
            DispatchMessage(&msg);
        }
    }

    // ДИАГНОСТИКА 4: Проверяем, создалось ли окно
    if (g_plugin_hwnd) {
        MessageBoxA(g_hwndParent, "Debug 4: CreateWindowExA SUCCEEDED.", "Tracer", MB_OK | MB_TOPMOST);
        // ShowWindow и UpdateWindow теперь не так важны, так как мы добавили WS_VISIBLE
        // ShowWindow(g_plugin_hwnd, SW_SHOW);
        // UpdateWindow(g_plugin_hwnd);
    } else {
        char error_buf[256];
        sprintf(error_buf, "Debug 4 FAILED: CreateWindowExA failed! Error code: %lu", GetLastError());
        MessageBoxA(g_hwndParent, error_buf, "Tracer Error", MB_ICONERROR | MB_TOPMOST);
        free(url_param);
    }
}

LRESULT CALLBACK WebViewWndProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam) {
    switch (uMsg) {
    case WM_CREATE: {
        // ДИАГНОСТИКА 5: Проверяем, дошло ли сообщение до обработчика
        MessageBoxA(hwnd, "Debug 5: WM_CREATE received!", "Tracer", MB_OK | MB_TOPMOST);
        
        char* initial_url_c = (char*)((LPCREATESTRUCTA)lParam)->lpCreateParams;
        if (!initial_url_c) break;

        std::string initial_url_str(initial_url_c);
        free(initial_url_c);
        std::wstring w_url(initial_url_str.begin(), initial_url_str.end());

        g_hWebView2Loader = LoadLibraryA("WebView2Loader.dll");
        if (!g_hWebView2Loader) {
            MessageBoxA(hwnd, "WebView2 Runtime not found. Please install Microsoft Edge WebView2 Runtime.", "Error", MB_ICONERROR | MB_TOPMOST);
            DestroyWindow(hwnd);
            break;
        }

        auto pCreate = (CreateWebView2EnvironmentWithOptions_t)GetProcAddress(g_hWebView2Loader, "CreateCoreWebView2EnvironmentWithOptions");
        if (!pCreate) {
            MessageBoxA(hwnd, "Failed to load WebView2 functions", "Error", MB_ICONERROR | MB_TOPMOST);
            DestroyWindow(hwnd);
            break;
        }

        pCreate(nullptr, nullptr, nullptr,
            Microsoft::WRL::Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
                [hwnd, w_url](HRESULT result, ICoreWebView2Environment* env) -> HRESULT {
                    if (FAILED(result)) {
                        MessageBoxA(hwnd, "Failed to create WebView2 environment", "Error", MB_ICONERROR | MB_TOPMOST);
                        DestroyWindow(hwnd);
                        return result;
                    }
                    env->CreateCoreWebView2Controller(hwnd, Microsoft::WRL::Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                        [hwnd, w_url](HRESULT result, ICoreWebView2Controller* controller) -> HRESULT {
                            if (controller) {
                                webviewController = controller;
                                webviewController->get_CoreWebView2(&webview);
                                RECT bounds;
                                GetClientRect(hwnd, &bounds);
                                webviewController->put_Bounds(bounds);
                                webview->Navigate(w_url.c_str());
                            } else {
                                MessageBoxA(hwnd, "Failed to create WebView2 controller", "Error", MB_ICONERROR | MB_TOPMOST);
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
        if (webviewController) {
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

// ... код для macOS остается без изменений ...
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
            [g_delegate performSelectorOnMainThread:@selector(navigate:) withObject:nsURL waitUntilDone:NO];
        }
    }
}
#endif