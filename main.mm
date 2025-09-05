#ifdef _WIN32
    #define WM_APP_NAVIGATE (WM_APP + 1)
    #include <windows.h>
    #include <string>
    #include <wrl.h>
    #include <wil/com.h>
    #include <Shlwapi.h>
    #pragma comment(lib, "shlwapi.lib")
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

REAPER_PLUGIN_HINSTANCE g_hInst = nullptr;
HWND g_hwndParent = nullptr;
int g_command_id = 0;

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

#ifdef _WIN32
    HWND g_plugin_hwnd = nullptr;
    wil::com_ptr<ICoreWebView2Controller> webviewController;
    wil::com_ptr<ICoreWebView2> webview;
    HMODULE g_hWebView2Loader = nullptr;
#else
    NSWindow* g_pluginWindow = nil; 
    WKWebView* g_webView = nil; 
    id g_delegate = nil;
#endif

void Action_OpenWebView();
static void OpenWebViewWindow(const std::string& url);
void WEBVIEW_Navigate(const char* url);

bool HookCommandProc(int cmd, int flag)
{
    if (cmd == g_command_id) {
        Action_OpenWebView();
        return true;
    }
    // ИЗМЕНЕНИЕ: Обрабатываем новые команды
    if (cmd == NamedCommandLookup("FRZZ_WEBVIEW_REFRESH")) {
        if (g_plugin_hwnd && webview) webview->Reload();
        return true;
    }
    if (cmd == NamedCommandLookup("FRZZ_WEBVIEW_OPENURL")) {
        if (g_plugin_hwnd && webview) {
            char urlbuf[2048] = "https://";
            if (GetUserInputs("Open URL", 1, "URL:", urlbuf, sizeof(urlbuf))) {
                WEBVIEW_Navigate(urlbuf);
            }
        }
        return true;
    }
    return false;
}
// ИЗМЕНЕНИЕ (Windows): Добавляем ID для команд контекстного меню
#define IDC_REFRESH 40001
#define IDC_OPENURL 40002

extern "C" REAPER_PLUGIN_DLL_EXPORT int
REAPER_PLUGIN_ENTRYPOINT(REAPER_PLUGIN_HINSTANCE hInstance, reaper_plugin_info_t* rec) {
    g_hInst = hInstance;
    if (!rec) return 0;
    if (rec->caller_version != REAPER_PLUGIN_VERSION || !rec->GetFunc) return 0;
    if (REAPERAPI_LoadAPI(rec->GetFunc) != 0) return 0;
    
    g_hwndParent = rec->hwnd_main;
    Log("Plugin loaded successfully. API initialized.");

    g_command_id = NamedCommandLookup("FRZZ_WEBVIEW_OPEN_DEFAULT");
    if (!g_command_id) {
        g_command_id = plugin_register("command_id", (void*)"FRZZ_WEBVIEW_OPEN_DEFAULT");
        if (g_command_id) {
            static gaccel_register_t gaccel = { { 0, 0, 0 }, "WebView: Open (default)" };
            gaccel.accel.cmd = g_command_id;
            plugin_register("gaccel", &gaccel);
            Log("Action 'WebView: Open (default)' registered with command ID %d", g_command_id);
        }
    } else {
        Log("Action 'WebView: Open (default)' already registered with ID %d", g_command_id);
    }
    
    if (g_command_id) {
        plugin_register("hookcommand", (void*)HookCommandProc);
    } else {
        Log("!!! FAILED to register action.");
    }
    
    plugin_register("APIdef_WEBVIEW_Navigate", (void*)"void,const char*,url");
    plugin_register("API_WEBVIEW_Navigate", (void*)WEBVIEW_Navigate);
    plugin_register("command_id", (void*)"FRZZ_WEBVIEW_REFRESH");
    plugin_register("gaccel", new gaccel_register_t{ { 0, 0, 0 }, "WebView: Refresh Page" });
    
    plugin_register("command_id", (void*)"FRZZ_WEBVIEW_OPENURL");
    plugin_register("gaccel", new gaccel_register_t{ { 0, 0, 0 }, "WebView: Open URL..." });

    Log("API function 'WEBVIEW_Navigate' registered.");

    return 1;
}

void Action_OpenWebView() {
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
void OpenWebViewWindow(const std::string& url) {
    Log("OpenWebViewWindow called for URL: %s", url.c_str());
    if (g_plugin_hwnd && IsWindow(g_plugin_hwnd)) {
        DockWindowActivate(g_plugin_hwnd);
        return;
    }
    WNDCLASSW wc{0};
    wc.lpfnWndProc   = WebViewWndProc;
    wc.hInstance     = (HINSTANCE)g_hInst;
    wc.lpszClassName = L"MyWebViewPlugin_WindowClass";
    wc.hCursor       = LoadCursor(NULL, IDC_ARROW);
    if (!RegisterClassW(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        Log("!!! FAILED to register window class. Error: %lu", GetLastError());
        return;
    }
    Log("Window class registered successfully.");
    char* url_param = _strdup(url.c_str());
    g_plugin_hwnd = CreateWindowExW(
        0, wc.lpszClassName, L"Интегрированный WebView (Windows)",
        WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, g_hwndParent, NULL, (HINSTANCE)g_hInst, (LPVOID)url_param);
    if (!g_plugin_hwnd) {
        Log("!!! FAILED to create window. Error: %lu", GetLastError());
        free(url_param);
        return;
    }
    DockWindowAddEx(g_plugin_hwnd, "WebView", "FRZZ_WebView", true);
    Log("Window created (hwnd: %p) and registered in Docker.", g_plugin_hwnd);
}

LRESULT CALLBACK WebViewWndProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam) {
    switch (uMsg) {
        case WM_CREATE: {
            Log("WM_CREATE received for hwnd %p.", hwnd);
            wchar_t userDataPath[MAX_PATH] = {0};
            if (GetResourcePath) {
                char narrowPath[MAX_PATH];
                strcpy(narrowPath, GetResourcePath());
                MultiByteToWideChar(CP_UTF8, 0, narrowPath, -1, userDataPath, MAX_PATH);
                PathAppendW(userDataPath, L"WebView2_UserData");
                CreateDirectoryW(userDataPath, NULL);
                Log("WebView2 User Data Path will be: %S", userDataPath);
            } else {
                Log("!!! Could not get REAPER resource path. WebView2 might fail.");
            }
            
            char* initial_url_c = reinterpret_cast<char*>(((LPCREATESTRUCTW)lParam)->lpCreateParams); // Используем LPCREATESTRUCTW
            if (!initial_url_c) { Log("!!! WM_CREATE: lpCreateParams is NULL."); break; }
            std::string initial_url_str(initial_url_c);
            free(initial_url_c);
            std::wstring w_url(initial_url_str.begin(), initial_url_str.end());
            Log("WM_CREATE: Initial URL is %s", initial_url_str.c_str());
            g_hWebView2Loader = LoadLibraryA("WebView2Loader.dll");
            if (!g_hWebView2Loader) { DestroyWindow(hwnd); return 0; }
            using CreateEnv_t = HRESULT (STDMETHODCALLTYPE*)(PCWSTR, PCWSTR, ICoreWebView2EnvironmentOptions*, ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler*);
            auto pCreate = reinterpret_cast<CreateEnv_t>(GetProcAddress(g_hWebView2Loader, "CreateCoreWebView2EnvironmentWithOptions"));
            if (!pCreate) { DestroyWindow(hwnd); return 0; }
            Log("WM_CREATE: Starting WebView2 environment creation...");
            pCreate(nullptr, (userDataPath[0] ? userDataPath : nullptr), nullptr,
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

                        // ----- ИСПРАВЛЕНИЕ: Добавляем недостающий return -----
                        return S_OK;
                        // ----------------------------------------------------
                    }).Get());
            break;
        }
        case WM_CONTEXTMENU: {
            HMENU menu = CreatePopupMenu();
            if (menu) {
                // Добавляем стандартный пункт "Dock..."
                int pos = DockWindowAddEx_GetPosition(hwnd); // -1=undocked, 0-3=docked
                AddExtensionsMainMenu(); // Убедимся, что меню Extensions существует
                if (HMENU ex_menu = GetSubMenu(GetMenu(g_hwndParent), 5)) { // 5 - это обычно индекс меню Extensions
                    if (HMENU docker_menu = GetSubMenu(ex_menu, 0)) { // 0 - обычно "Docker"
                        MENUITEMINFO info{sizeof(info), MIIM_ID | MIIM_STRING | MIIM_STATE, 0, (pos >= 0 ? MFS_CHECKED : 0), 0, docker_menu, 0, 0, 0, "Dock WebView in Docker", 0, 0};
                        InsertMenuItem(menu, 0, TRUE, &info);
                    }
                }
                
                // Стандартный пункт "Close"
                AppendMenu(menu, MF_STRING, IDCANCEL, "Close");
                AppendMenu(menu, MF_SEPARATOR, 0, NULL);
                
                // Наши кастомные пункты
                AppendMenu(menu, MF_STRING, IDC_REFRESH, "Refresh Page");
                AppendMenu(menu, MF_STRING, IDC_OPENURL, "Open URL...");
                
                int cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, LOWORD(lParam), HIWORD(lParam), 0, hwnd, NULL);
                if (cmd == IDCANCEL) {
                    SendMessage(hwnd, WM_CLOSE, 0, 0);
                } else if (cmd == IDC_REFRESH) {
                    if (webview) webview->Reload();
                } else if (cmd == IDC_OPENURL) {
                    char urlbuf[2048] = "https://";
                    if (GetUserInputs("Open URL", 1, "URL:", urlbuf, sizeof(urlbuf))) {
                        WEBVIEW_Navigate(urlbuf);
                    }
                }
                DestroyMenu(menu);
            }
            return 0;
        }
        case WM_DESTROY: {
            Log("WM_DESTROY received for hwnd %p. Cleaning up.", hwnd);
            DockWindowRemove(hwnd);
            if (webviewController) { webviewController->Close(); webviewController = nullptr; webview = nullptr; }
            if (g_hWebView2Loader) { FreeLibrary(g_hWebView2Loader); g_hWebView2Loader = nullptr; }
            g_plugin_hwnd = NULL; return 0;
        }
        default: return DefWindowProc(hwnd, uMsg, wParam, lParam);
    }
    return DefWindowProcW(hwnd, uMsg, wParam, lParam); 
}

#else
// ================================================================= //
//                  РЕАЛИЗАЦИЯ ДЛЯ MACOS (ИЗМЕНЕНИЯ)                 //
// ================================================================= //


// Глобальная переменная для хранения нашего HWND, созданного через SWELL
HWND g_swell_hwnd = nullptr;

// Наш кастомный NSView, который будет содержать WebView
@interface MyNSView : NSView
@end
@implementation MyNSView
- (BOOL)isFlipped { return YES; } // Важно для правильного отображения WebView
@end

// Функция обратного вызова для SWELL-окна
LRESULT CALLBACK SwellWndProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam)
{
    switch (uMsg) {
        case WM_CREATE: {
            Log("SWELL WM_CREATE called.");
            // Получаем нативный NSView, который Reaper выделил для нашего HWND
            NSView* parentView = (NSView*)Swell_GetNSView(hwnd);
            if (parentView) {
                NSRect frame = [parentView bounds];
                
                // Создаем наш NSView и WebView
                MyNSView* myView = [[MyNSView alloc] initWithFrame:frame];
                WKWebViewConfiguration* config = [[WKWebViewConfiguration alloc] init];
                g_webView = [[WKWebView alloc] initWithFrame:frame configuration:config];
                
                // Встраиваем WebView в наш NSView, а наш NSView - в родительский от Reaper
                [myView addSubview:g_webView];
                [parentView addSubview:myView];
                
                // Сохраняем указатель на наш NSView в данных окна для последующего доступа
                SetWindowLongPtr(hwnd, GWLP_USERDATA, (LONG_PTR)myView);
                
                // Загружаем URL
                if (lParam) {
                    const char* url = (const char*)((LPCREATESTRUCT)lParam)->lpCreateParams;
                    if (url) {
                        NSString* nsURL = [NSString stringWithUTF8String:url];
                        NSURL* URL = [NSURL URLWithString:nsURL];
                        NSURLRequest* request = [NSURLRequest requestWithURL:URL];
                        [g_webView loadRequest:request];
                    }
                }
            }
            return 0;
        }
        case WM_SIZE: {
            // При изменении размера окна докера, меняем размер нашего NSView и WebView
            MyNSView* myView = (MyNSView*)GetWindowLongPtr(hwnd, GWLP_USERDATA);
            if (myView) {
                NSRect frame = NSMakeRect(0, 0, LOWORD(lParam), HIWORD(lParam));
                [myView setFrame:frame];
                if (g_webView) {
                    [g_webView setFrame:frame];
                }
            }
            return 0;
        }
        case WM_DESTROY: {
            Log("SWELL WM_DESTROY called.");
            if (DockWindowRemove) DockWindowRemove(hwnd);
            g_swell_hwnd = nullptr;
            g_webView = nil; // Обнуляем, т.к. он будет удален вместе с myView
            return 0;
        }
    }
    return DefWindowProc(hwnd, uMsg, wParam, lParam);
}

void OpenWebViewWindow(const std::string& url) {
    Log("macOS OpenWebViewWindow called.");

    if (g_swell_hwnd) {
        if (DockWindowActivate) DockWindowActivate(g_swell_hwnd);
        return;
    }
    
    // 1. Регистрируем SWELL-класс окна
    WNDCLASS wc;
    memset(&wc, 0, sizeof(wc));
    wc.lpfnWndProc = SwellWndProc;
    wc.hInstance = g_hInst;
    wc.lpszClassName = "MyWebViewSwellClass";
    SWELL_RegisterClass(&wc);

    // 2. Создаем "пустое" SWELL-окно. Оно невидимо, но у него есть HWND.
    g_swell_hwnd = CreateWindowEx(0, "MyWebViewSwellClass", "WebView", 0, 0, 0, 0, 0, 
                                  g_hwndParent, 0, g_hInst, (void*)url.c_str());

    if (!g_swell_hwnd) {
        Log("!!! macOS: Failed to create SWELL window.");
        return;
    }
    
    // 3. Регистрируем это HWND в докере. Reaper сам покажет окно и встроит его.
    if (DockWindowAddEx) {
        DockWindowAddEx(g_swell_hwnd, "WebView", "FRZZ_WebView_macOS", true);
        Log("macOS SWELL window (hwnd: %p) registered in Docker.", g_swell_hwnd);
    }
}

void WEBVIEW_Navigate(const char* url) {
    if (!g_webView || !url) return;
    @autoreleasepool {
        NSString* nsURL = [NSString stringWithUTF8String:url];
        NSURL* URL = [NSURL URLWithString:nsURL];
        NSURLRequest* request = [NSURLRequest requestWithURL:URL];
        [g_webView loadRequest:request];
    }
}
#endif