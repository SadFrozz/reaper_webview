// ИСПРАВЛЕНО: Удален #define REAPER_PLUGIN_VERSION, так как он определяется в reaper_plugin.h
// и вызывал предупреждение о переопределении.

// --- Платформо-зависимые включения ---
#ifdef _WIN32
    #include <windows.h>
    #include <string>
    #include <wil/com.h>
    #include <WebView2.h>
    #include <wrl.h> // ИСПРАВЛЕНО: Добавлен необходимый заголовок для Microsoft::WRL::Callback
#else
    #include <Cocoa/Cocoa.h>
    #include <WebKit/WebKit.h>
#endif

#include "reaper_plugin.h"
#include "swell.h" // SWELL должен быть включен после системных заголовков

// --- Стандартные библиотеки ---
#include <string>
#include <vector>
#include <filesystem>
#include <fstream>
#include <cstdio> // для snprintf

// --- Глобальные переменные ---
static HINSTANCE g_hInst = NULL;
static HWND g_hwndParent = NULL;
static HWND g_hwndWebView = NULL;

#ifdef _WIN32
    static wil::com_ptr<ICoreWebView2Controller> webviewController;
    static wil::com_ptr<ICoreWebView2> webview;
#else
    static WKWebView* nsWebView = nil;
#endif

// --- Логирование для отладки ---
void Log(const std::string& message) {
    static std::ofstream logFile;
    if (!logFile.is_open()) {
        const char* resourcePath = GetResourcePath(); // ИСПРАВЛЕНО: Вызов функции REAPER API
        if (resourcePath) {
            std::string path = std::string(resourcePath) + "/reaper_webview_log.txt";
            logFile.open(path, std::ios_base::app);
        }
    }
    if (logFile.is_open()) {
        logFile << message << std::endl;
    }
}

// --- Платформенно-специфичная логика инициализации WebView ---

#ifdef _WIN32
void InitializeWebView2(HWND hwnd) {
    Log("Attempting to initialize WebView2...");
    const char* resourcePath = GetResourcePath();
    if (!resourcePath) {
        Log("Failed to get REAPER resource path.");
        return;
    }
    std::string userDataPathStr = std::string(resourcePath) + "\\WebView2_UserData";
    std::wstring userDataPathW(userDataPathStr.begin(), userDataPathStr.end());

    using namespace Microsoft::WRL; // ИСПРАВЛЕНО: Добавлено пространство имен для Callback

    CreateCoreWebView2EnvironmentWithOptions(nullptr, userDataPathW.c_str(), nullptr,
        Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
            [hwnd](HRESULT result, ICoreWebView2Environment* env) -> HRESULT {
                if (FAILED(result)) { Log("Failed to create WebView2 environment."); return result; }
                Log("WebView2 environment created.");
                env->CreateCoreWebView2Controller(hwnd, Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                    [hwnd](HRESULT result, ICoreWebView2Controller* controller) -> HRESULT {
                        if (FAILED(result)) { Log("Failed to create WebView2 controller."); return result; }
                        Log("WebView2 controller created.");
                        webviewController = controller;
                        webviewController->get_CoreWebView2(&webview);
                        RECT bounds;
                        GetClientRect(hwnd, &bounds);
                        webviewController->put_Bounds(bounds);
                        webview->Navigate(L"https://www.reaper.fm/");
                        return S_OK;
                    }).Get()); // ИСПРАВЛЕНО:.Get() вызывается для объекта Callback
                return S_OK;
            }).Get()); // ИСПРАВЛЕНО:.Get() вызывается для объекта Callback
}
#else // macOS
void InitializeWKWebView(HWND hwnd) {
    NSView* parentView = SWELL_GetViewForHWND(hwnd);
    if (!parentView) { Log("macOS: Parent NSView is null."); return; }
    Log("macOS: Initializing WKWebView...");

    // ИСПРАВЛЕНО: Корректный синтаксис Objective-C
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
            Log("WM_CREATE received.");
#ifdef _WIN32
            InitializeWebView2(hwnd);
#else
            InitializeWKWebView(hwnd);
#endif
            return 0;
        case WM_SIZE:
            Log("WM_SIZE received.");
#ifdef _WIN32
            if (webviewController) {
                RECT bounds;
                GetClientRect(hwnd, &bounds);
                webviewController->put_Bounds(bounds);
            }
#endif
            return 0;
        case WM_DESTROY:
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
    return DefWindowProc(hwnd, uMsg, wParam, lParam);
}

// --- Функции-действия для REAPER ---
void OpenWebView() {
    if (g_hwndWebView && IsWindow(g_hwndWebView)) {
        Log("Window already exists, showing.");
        DockWindowActivate(g_hwndWebView);
        return;
    }
    Log("Attempting to open WebView window...");
    WNDCLASS wc = {};
    wc.lpfnWndProc = WebViewWndProc;
    wc.hInstance = g_hInst;
    wc.lpszClassName = "REAPER_WebView_SWELL";
    SWELL_RegisterWndClass(&wc);

    g_hwndWebView = SWELL_CreateWindow(
        "REAPER_WebView_SWELL", "REAPER WebView",
        WS_OVERLAPPEDWINDOW | WS_VISIBLE,
        -1, -1, 800, 600, // x/y -1 для док-окон
        g_hwndParent, NULL, g_hInst, NULL
    );

    if (!g_hwndWebView) { Log("SWELL_CreateWindow failed."); return; }
    Log("SWELL_CreateWindow succeeded.");
    DockWindowAdd(g_hwndWebView, "WebView", 0, true);
}

void RefreshWebView() {
    Log("Refresh action called.");
    if (g_hwndWebView && IsWindow(g_hwndWebView)) {
#ifdef _WIN32
        if (webview) { webview->Reload(); Log("WebView reloaded on Windows."); }
#else
        if (nsWebView) {; Log("WKWebView reloaded on macOS."); }
#endif
    } else {
        Log("Refresh failed: WebView window not found.");
    }
}

// --- Регистрация действий в REAPER ---
static COMMAND_T g_commandTable = {
    { { 0, 0, 0 }, "FRZZ_WEBVIEW_OPEN", NULL, NULL, 0, NULL, },
    { { 0, 0, 0 }, "FRZZ_WEBVIEW_REFRESH_PAGE", NULL, NULL, 0, NULL, },
    { {}, NULL, NULL, NULL, 0, NULL, }
};

// --- Точка входа плагина ---
extern "C" {
    REAPER_PLUGIN_DLL_EXPORT int REAPER_PLUGIN_ENTRYPOINT(REAPER_PLUGIN_HINSTANCE hInstance, reaper_plugin_info_t* rec) {
        if (rec) {
            g_hInst = hInstance;
            g_hwndParent = rec->hwnd_main;

            if (rec->caller_version!= REAPER_PLUGIN_VERSION_INT) return 0;

            // ИСПРАВЛЕНО: Корректная регистрация команд через rec->Register
            g_commandTable.doCommand = OpenWebView;
            g_commandTable.cmd = rec->Register("command_id", (void*)"FRZZ_WEBVIEW_OPEN");
            rec->Register("gaccel", &g_commandTable);

            g_commandTable.[1]doCommand = RefreshWebView;
            g_commandTable.[1]cmd = rec->Register("command_id", (void*)"FRZZ_WEBVIEW_REFRESH_PAGE");
            rec->Register("gaccel", &g_commandTable[1]);

            return 1;
        }
        return 0;
    }
}