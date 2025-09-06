#ifdef _WIN32
    #define WM_APP_NAVIGATE (WM_APP + 1)
    #include <windows.h>
    #include <string>
    #include <wrl.h>
    #include <wil/com.h>
    #include <Shlwapi.h>
    #pragma comment(lib, "shlwapi.lib")
    #include <windowsx.h>
    #include "WebView2.h"
#else
    #import <Cocoa/Cocoa.h>
    #import <WebKit/WebKit.h>
    #include <string>
    #include "WDL/swell/swell.h"
#endif

#include "WDL/wdltypes.h"
#include "sdk/reaper_plugin.h"

#define REAPERAPI_IMPLEMENT
#include "sdk/reaper_plugin_functions.h"

#define IDC_DOCK 40003

// Глобальные переменные
REAPER_PLUGIN_HINSTANCE g_hInst = nullptr;
HWND g_hwndParent = nullptr;
HWND g_hwnd = nullptr;
int g_command_id_open = 0;
int g_command_id_refresh = 0;
int g_command_id_openurl = 0;

void WEBVIEW_Navigate(const char* url);

#ifdef _WIN32
    wil::com_ptr<ICoreWebView2Controller> webviewController;
    wil::com_ptr<ICoreWebView2> webview;
    HMODULE g_hWebView2Loader = nullptr;
#endif

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

void Action_OpenWebView();
static void OpenWebViewWindow(const std::string& url);

bool HookCommandProc(int cmd, int flag) {
    if (cmd == g_command_id_open) {
        Action_OpenWebView();
        return true;
    }
    if (cmd == g_command_id_refresh) {
        if (g_hwnd) {
            WEBVIEW_Navigate("refresh");
        } else {
            MessageBoxA(g_hwndParent, "WebView is not running. Open any URL via the Action List or run a ReaScript using API functions starting with FRZZ_WEBVIEW.", "WebView Error", MB_OK);
        }
        return true;
    }
    if (cmd == g_command_id_openurl) {
        char urlbuf[2048] = "https://";
        if (GetUserInputs("Open URL", 1, "URL:", urlbuf, sizeof(urlbuf))) {
            if (g_hwnd) {
                WEBVIEW_Navigate(urlbuf);
            } else {
                OpenWebViewWindow(urlbuf);
            }
        }
        return true;
    }
    return false;
}

// Helper-функция для регистрации действия
static int RegisterAction(const char* id, const char* name, int* cmd_id_var) {
    *cmd_id_var = NamedCommandLookup(id);
    if (!*cmd_id_var) {
        *cmd_id_var = plugin_register("command_id", (void*)id);
        if (*cmd_id_var) {
            static gaccel_register_t gaccel = { { 0, 0, 0 }, "" };
            gaccel.accel.cmd = *cmd_id_var;
            gaccel.desc = name;
            plugin_register("gaccel", &gaccel);
        }
    }
    return *cmd_id_var;
}


extern "C" REAPER_PLUGIN_DLL_EXPORT int
REAPER_PLUGIN_ENTRYPOINT(REAPER_PLUGIN_HINSTANCE hInstance, reaper_plugin_info_t* rec) {
    g_hInst = hInstance;
    if (!rec || rec->caller_version != REAPER_PLUGIN_VERSION || !rec->GetFunc || REAPERAPI_LoadAPI(rec->GetFunc) != 0) return 0;
    g_hwndParent = rec->hwnd_main;
    Log("Plugin loaded successfully. API initialized.");
    
    RegisterAction("FRZZ_WEBVIEW_OPEN_DEFAULT", "WebView: Open (default)", &g_command_id_open);
    RegisterAction("FRZZ_WEBVIEW_REFRESH_PAGE", "WebView: Refresh Page", &g_command_id_refresh);
    RegisterAction("FRZZ_WEBVIEW_OPEN_URL", "WebView: Open URL...", &g_command_id_openurl);

    if (g_command_id_open) {
        plugin_register("hookcommand", (void*)HookCommandProc);
    }
    
    plugin_register("APIdef_WEBVIEW_Navigate", (void*)"void,const char*,url");
    plugin_register("API_WEBVIEW_Navigate", (void*)WEBVIEW_Navigate);
    return 1;
}

void Action_OpenWebView() {
    Log("Action_OpenWebView triggered!");
    OpenWebViewWindow("https://www.reaper.fm/");
}

#ifdef _WIN32
// ================================================================= //
//                      РЕАЛИЗАЦИЯ ДЛЯ WINDOWS                       //
// ================================================================= //
LRESULT CALLBACK WebViewWndProc(HWND, UINT, WPARAM, LPARAM);
void OpenWebViewWindow(const std::string& url) {
    if (g_hwnd && IsWindow(g_hwnd)) { DockWindowActivate(g_hwnd); return; }
    WNDCLASSW wc{0};
    wc.lpfnWndProc = WebViewWndProc; wc.hInstance = (HINSTANCE)g_hInst; wc.lpszClassName = L"MyWebViewPlugin_WindowClass"; wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    if (!RegisterClassW(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return;
    char* url_param = _strdup(url.c_str());
    g_hwnd = CreateWindowExW(0, wc.lpszClassName, L"WebView", WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, g_hwndParent, NULL, (HINSTANCE)g_hInst, (LPVOID)url_param);
    if (g_hwnd) DockWindowAddEx(g_hwnd, "WebView", "FRZZ_WebView", true);
}
void WEBVIEW_Navigate(const char* url) {
    if (g_hwnd && webview && url) {
        if (strcmp(url, "refresh") == 0) { webview->Reload(); return; }
        std::wstring w_url; int len = MultiByteToWideChar(CP_UTF8, 0, url, -1, NULL, 0);
        if (len > 0) { w_url.resize(len - 1); MultiByteToWideChar(CP_UTF8, 0, url, -1, &w_url[0], len); webview->Navigate(w_url.c_str()); }
    }
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
            char* initial_url_c = reinterpret_cast<char*>(((LPCREATESTRUCTW)lParam)->lpCreateParams);
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
                        return S_OK;
                    }).Get());
            break;
        }
        case WM_CLOSE: { DestroyWindow(hwnd); return 0; }
        case WM_DESTROY: {
            DockWindowRemove(hwnd);
            if (webviewController) { webviewController->Close(); webviewController = nullptr; webview = nullptr; }
            if (g_hWebView2Loader) { FreeLibrary(g_hWebView2Loader); g_hWebView2Loader = nullptr; }
            g_hwnd = NULL; return 0;
        }
        case WM_SIZE: { if (webviewController) { RECT rc; GetClientRect(hwnd, &rc); webviewController->put_Bounds(rc); } return 0; }
        case WM_COMMAND: { if (LOWORD(wParam) == IDCANCEL) SendMessage(hwnd, WM_CLOSE, 0, 0); return 0; }
        case WM_CONTEXTMENU: {
            HMENU menu = CreatePopupMenu();
            if (menu) {
                bool is_docked = DockIsChildOfDock(hwnd, NULL);
                AppendMenuA(menu, MF_STRING | (is_docked ? MFS_CHECKED : 0), IDC_DOCK, "Dock WebView in Docker");
                AppendMenuA(menu, MF_STRING, IDCANCEL, "Close");
                AppendMenuA(menu, MF_SEPARATOR, 0, NULL);
                AppendMenuA(menu, MF_STRING, g_command_id_refresh, "Refresh Page");
                AppendMenuA(menu, MF_STRING, g_command_id_openurl, "Open URL...");
                int cmd = TrackPopupMenu(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON, GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam), 0, hwnd, NULL);
                DestroyMenu(menu);

                if (cmd == IDC_DOCK) {
                    DockWindowRemove(hwnd); // Всегда сначала удаляем
                    if (!is_docked) { // Если не был пристыкован, стыкуем заново
                        DockWindowAddEx(hwnd, "WebView", "FRZZ_WebView", true);
                    }
                }
                else if (cmd == IDCANCEL) SendMessage(hwnd, WM_CLOSE, 0, 0);
                else if (cmd > 0) Main_OnCommand(cmd, 0);
            }
            return 0;
        }
    }
    return DefWindowProcW(hwnd, uMsg, wParam, lParam);
}
#else
// ================================================================= //
//                       РЕАЛИЗАЦИЯ ДЛЯ MACOS                        //
// ================================================================= //
@interface MyNSView : NSView { @public WKWebView* webView; } @end
@implementation MyNSView
- (BOOL)isFlipped { return YES; }
- (void)dealloc { [webView release]; [super dealloc]; }
@end
LRESULT CALLBACK SwellWndProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam) {
    switch (uMsg) {
        case WM_CREATE: {
            NSView* parentView = (NSView*)Swell_GetNSView(hwnd);
            if (parentView) {
                MyNSView* myView = [[[MyNSView alloc] initWithFrame:[parentView bounds]] autorelease];
                WKWebViewConfiguration* config = [[[WKWebViewConfiguration alloc] init] autorelease];
                WKWebView* wv = [[[WKWebView alloc] initWithFrame:[parentView bounds] configuration:config] autorelease];
                myView->webView = wv; [myView addSubview:wv]; [parentView addSubview:myView];
                SWELL_SetWindowLong(hwnd, GWL_USERDATA, (LONG_PTR)myView);
                if (lParam) WEBVIEW_Navigate((const char*)lParam);
            }
            return 0;
        }
        case WM_SIZE: {
            MyNSView* myView = (MyNSView*)SWELL_GetWindowLong(hwnd, GWL_USERDATA);
            if (myView) {
                NSRect frame = NSMakeRect(0, 0, GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam));
                [myView setFrame:frame];
                if(myView->webView) [myView->webView setFrame:frame];
            }
            return 0;
        }
        case WM_DESTROY: { if (DockWindowRemove) DockWindowRemove(hwnd); g_hwnd = nullptr; return 0; }
    }
    return DefWindowProc(hwnd, uMsg, wParam, lParam);
}
void OpenWebViewWindow(const std::string& url) {
    if (g_hwnd) { if (DockWindowActivate) DockWindowActivate(g_hwnd); return; }
    WNDCLASS wc = { 0, };
    wc.lpfnWndProc = SwellWndProc; wc.hInstance = g_hInst; wc.lpszClassName = "MyWebViewSwellClass";
    SWELL_RegisterClass(&wc);
    g_hwnd = CreateWindowEx(0, "MyWebViewSwellClass", "WebView", 0, 0, 0, 0, 0, g_hwndParent, 0, g_hInst, (void*)url.c_str());
    if (g_hwnd) DockWindowAddEx(g_hwnd, "WebView", "FRZZ_WebView_macOS", true);
}
void WEBVIEW_Navigate(const char* url) {
    if (!g_hwnd) return;
    MyNSView* myView = (MyNSView*)SWELL_GetWindowLong(g_hwnd, GWL_USERDATA);
    if (!myView || !myView->webView) return;
    if (strcmp(url, "refresh") == 0) { [myView->webView reload]; return; }
    @autoreleasepool {
        NSString* nsURL = [NSString stringWithUTF8String:url];
        NSURL* URL = [NSURL URLWithString:nsURL];
        NSURLRequest* request = [NSURLRequest requestWithURL:URL];
        [myView->webView loadRequest:request];
    }
}
#endif