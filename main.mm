#define REAPER_PLUGIN_VERSION "0.1"
#define REAPER_PLUGIN_NAME "reaper_webview"

#ifdef _WIN32
#include <windows.h>
#include <wil/com.h>
#include <WebView2.h>
#else
#include <Cocoa/Cocoa.h>
#include <WebKit/WebKit.h>
#endif

#include "reaper_plugin.h"
#include "swell.h"

#include <string>
#include <vector>
#include <filesystem>
#include <fstream>

// Глобальные переменные
HINSTANCE g_hInst = NULL;
HWND g_hwndParent = NULL;
HWND g_hwndWebView = NULL;

#ifdef _WIN32
static wil::com_ptr<ICoreWebView2Controller> webviewController;
static wil::com_ptr<ICoreWebView2> webview;
#else
// Для macOS мы будем хранить указатель на наш кастомный NSView
static WKWebView* nsWebView = nil;
static NSView* myNSView = nil; // Кастомный NSView, который будет содержать WKWebView
#endif

// --- Логирование для отладки ---
void Log(const std::string& message) {
    static std::ofstream logFile;
    if (!logFile.is_open()) {
        char path;
        snprintf(path, sizeof(path), "%s/reaper_webview_log.txt", GetResourcePath());
        logFile.open(path, std::ios_base::app);
    }
    if (logFile.is_open()) {
        logFile << message << std::endl;
    }
}

// --- Платформенно-специфичная логика инициализации WebView ---

#ifdef _WIN32
void InitializeWebView2(HWND hwnd) {
    Log("Attempting to initialize WebView2...");
    std::wstring userDataFolder = L"";
    // Получаем путь к AppData
    char path;
    snprintf(path, sizeof(path), "%s/WebView2_UserData", GetResourcePath());
    
    wchar_t wpath;
    MultiByteToWideChar(CP_UTF8, 0, path, -1, wpath, MAX_PATH);
    userDataFolder = wpath;

    CreateCoreWebView2EnvironmentWithOptions(nullptr, userDataFolder.c_str(), nullptr,
        Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
            [hwnd](HRESULT result, ICoreWebView2Environment* env) -> HRESULT {
                if (FAILED(result)) {
                    Log("Failed to create WebView2 environment.");
                    return result;
                }
                Log("WebView2 environment created.");
                env->CreateCoreWebView2Controller(hwnd, Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                    [hwnd](HRESULT result, ICoreWebView2Controller* controller) -> HRESULT {
                        if (FAILED(result)) {
                            Log("Failed to create WebView2 controller.");
                            return result;
                        }
                        Log("WebView2 controller created.");
                        webviewController = controller;
                        webviewController->get_CoreWebView2(&webview);

                        RECT bounds;
                        GetClientRect(hwnd, &bounds);
                        webviewController->put_Bounds(bounds);

                        webview->Navigate(L"https://www.reaper.fm/");
                        
                        // Добавляем обработчики событий, если нужно
                        return S_OK;
                    }).Get());
                return S_OK;
            }).Get());
}
#else
// macOS
void InitializeWKWebView(NSView* parentView) {
    if (!parentView) {
        Log("macOS: Parent NSView is null.");
        return;
    }
    Log("macOS: Initializing WKWebView...");
    
    NSRect frame = [parentView bounds];
    WKWebViewConfiguration* config = init];
    nsWebView = initWithFrame:frame configuration:config];
   ;
    
   ;
    
    NSURL* url =;
    NSURLRequest* request =;
   ;
    
    Log("macOS: WKWebView initialized and added to parent view.");
}
#endif

// --- Кроссплатформенная оконная процедура ---
LRESULT CALLBACK WebViewWndProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam) {
    switch (uMsg) {
        case WM_CREATE:
        {
            Log("WM_CREATE received.");
#ifdef _WIN32
            InitializeWebView2(hwnd);
#else
            // На macOS мы получаем нативный NSView и инициализируем WKWebView в нем
            NSView* parentView = SWELL_GetViewForHWND(hwnd);
            InitializeWKWebView(parentView);
#endif
            return 0;
        }
        case WM_SIZE:
        {
            Log("WM_SIZE received.");
#ifdef _WIN32
            if (webviewController) {
                RECT bounds;
                GetClientRect(hwnd, &bounds);
                webviewController->put_Bounds(bounds);
            }
#else
            // На macOS SWELL/Cocoa должны обрабатывать изменение размера автоматически
#endif
            return 0;
        }
        case WM_DESTROY:
        {
            Log("WM_DESTROY received.");
#ifdef _WIN32
            webviewController = nullptr;
            webview = nullptr;
#else
            if (nsWebView) {
               ;
                nsWebView = nil;
            }
#endif
            g_hwndWebView = NULL;
            return 0;
        }
    }
    return DefWindowProc(hwnd, uMsg, wParam, lParam);
}

// --- Функции-действия для REAPER ---

void OpenWebView() {
    if (g_hwndWebView && IsWindow(g_hwndWebView)) {
        Log("Window already exists, showing and setting foreground.");
        ShowWindow(g_hwndWebView, SW_SHOW);
        SetForegroundWindow(g_hwndWebView);
        return;
    }

    Log("Attempting to open WebView window...");

    // 1. Регистрация класса окна с помощью SWELL (кроссплатформенно)
    WNDCLASS wc = {};
    wc.lpfnWndProc = WebViewWndProc;
    wc.hInstance = g_hInst;
    wc.lpszClassName = "REAPER_WebView_SWELL";
    SWELL_RegisterWndClass(&wc);

    // 2. Создание окна с помощью SWELL (кроссплатформенно)
    g_hwndWebView = SWELL_CreateWindow(
        "REAPER_WebView_SWELL",
        "REAPER WebView",
        WS_OVERLAPPEDWINDOW | WS_VISIBLE, // Используем стандартный стиль для док-окна
        100, 100, 800, 600,
        g_hwndParent, // Родительское окно REAPER
        NULL,
        g_hInst,
        NULL
    );

    if (!g_hwndWebView) {
        Log("SWELL_CreateWindow failed.");
        return;
    }
    
    Log("SWELL_CreateWindow succeeded.");

    // 3. Отображение окна (важно для Windows)
    ShowWindow(g_hwndWebView, SW_SHOW);
    UpdateWindow(g_hwndWebView);
}

void RefreshWebView() {
    Log("Refresh action called.");
    if (g_hwndWebView && IsWindow(g_hwndWebView)) {
#ifdef _WIN32
        if (webview) {
            webview->Reload();
            Log("WebView reloaded on Windows.");
        }
#else
        if (nsWebView) {
           ;
            Log("WKWebView reloaded on macOS.");
        }
#endif
    } else {
        Log("Refresh failed: WebView window not found.");
    }
}

// --- Регистрация действий в REAPER ---
static COMMAND_T g_commandTable = {
    { { DEFACCEL, "FRZZ_WEBVIEW_OPEN" }, "FRZZ_WEBVIEW_OPEN", OpenWebView, "Open WebView", 0, },
    { { DEFACCEL, "FRZZ_WEBVIEW_REFRESH_PAGE" }, "FRZZ_WEBVIEW_REFRESH_PAGE", RefreshWebView, "Refresh WebView Page", 0, },
    { {}, NULL, NULL, NULL, 0, }
};

// --- Точка входа плагина ---
extern "C" {
    REAPER_PLUGIN_DLL_EXPORT int REAPER_PLUGIN_ENTRYPOINT(REAPER_PLUGIN_HINSTANCE hInstance, reaper_plugin_info_t* rec) {
        if (rec) {
            g_hInst = hInstance;
            g_hwndParent = rec->hwnd_main;

            if (rec->caller_version!= REAPER_PLUGIN_VERSION_INT) {
                return 0;
            }

            int err = plugin_register("command_id", (void*)"FRZZ_WEBVIEW_OPEN");
            if (err == 0) return 0;
            plugin_register("gaccel", &g_commandTable);
            
            err = plugin_register("command_id", (void*)"FRZZ_WEBVIEW_REFRESH_PAGE");
            if (err == 0) return 0;
            plugin_register("gaccel", &g_commandTable[1]);

            // Регистрация док-окна
            static dock_frame_desc_t desc = { "WebView", "WebView", OpenWebView };
            rec->Register("docker", &desc);

            return 1;
        } else {
            return 0;
        }
    }
}