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
    // FIX macOS: 1. Move SWELL includes to the top.
    // FIX macOS: 2. Add mergesort.h for __listview_mergesort_internal.
    #include "WDL/mergesort.h"
    #include "WDL/swell/swell-miscdlg.mm"
    // FIX macOS: 3. Suppress narrowing warning locally for swell-wnd.mm
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wc++11-narrowing"
    #include "WDL/swell/swell-wnd.mm"
    #pragma clang diagnostic pop
    #include "WDL/swell/swell-menu.mm"
#endif

#include "WDL/wdltypes.h"
#include "sdk/reaper_plugin.h"

#define REAPERAPI_IMPLEMENT
#include "sdk/reaper_plugin_functions.h"

REAPER_PLUGIN_HINSTANCE g_hInst = nullptr;
HWND g_hwndParent = nullptr;
HWND g_hwnd = nullptr;
int g_command_id_open = 0;
int g_command_id_refresh = 0;
int g_command_id_openurl = 0;
#ifdef _WIN32
const WCHAR* g_wndClassName = L"MyWebViewPlugin_WindowClass";
#endif

void WEBVIEW_Navigate(const char* url);
static void OpenWebViewWindow(const std::string& url);

#ifdef _WIN32
    wil::com_ptr<ICoreWebView2Controller> webviewController;
    wil::com_ptr<ICoreWebView2> webview;
    HMODULE g_hWebView2Loader = nullptr;
#endif

void Log(const char* format, ...) {
    char buf[4096];
    va_list args; va_start(args, format); vsnprintf(buf, sizeof(buf), format, args); va_end(args);
#ifdef _WIN32
    OutputDebugStringA("[reaper_webview] "); OutputDebugStringA(buf); OutputDebugStringA("\n");
    if (GetResourcePath) {
        char path[MAX_PATH];
        if (GetResourcePath() && GetResourcePath()[0]) {
            strcpy(path, GetResourcePath()); strcat(path, "\\reaper_webview_log.txt");
            FILE* fp = fopen(path, "a"); if (fp) { fprintf(fp, "%s\n", buf); fclose(fp); }
        }
    }
#else
    NSLog(@"[reaper_webview] %s", buf);
#endif
}

LRESULT screenset_callback(int action, const char *id, void *param, void *actionParm, int actionParmSize) {
    if (action == SCREENSET_ACTION_GETHWND) {
        if (!g_hwnd || !IsWindow(g_hwnd)) OpenWebViewWindow("https://www.reaper.fm/");
        return (LRESULT)g_hwnd;
    }
    if (action == SCREENSET_ACTION_IS_DOCKED) {
        return DockIsChildOfDock(g_hwnd, NULL) ? 1 : 0;
    }
    return 0;
}

bool HookCommandProc(int cmd, int flag) {
    if (cmd == g_command_id_open) {
        HWND hwnd_to_activate = g_hwnd;
        if (!hwnd_to_activate || !IsWindow(hwnd_to_activate)) {
            hwnd_to_activate = (HWND)screenset_callback(SCREENSET_ACTION_GETHWND, "FRZZ_WebView", NULL, NULL, 0);
        }
        if (hwnd_to_activate) DockWindowActivate(hwnd_to_activate);
        return true;
    }
    if (cmd == g_command_id_refresh) {
        if (g_hwnd) WEBVIEW_Navigate("refresh");
        else MessageBox(g_hwndParent, "WebView is not running. Open any URL via the Action List or run a ReaScript using API functions starting with FRZZ_WEBVIEW.", "WebView Error", MB_OK);
        return true;
    }
    if (cmd == g_command_id_openurl) {
        char urlbuf[2048] = "https://";
        if (GetUserInputs("Open URL", 1, "URL:", urlbuf, sizeof(urlbuf))) {
            if (!g_hwnd || !IsWindow(g_hwnd)) OpenWebViewWindow(urlbuf);
            else WEBVIEW_Navigate(urlbuf);
        }
        return true;
    }
    return false;
}

void RegisterAction(const char* id, const char* name, int* cmd_id_var) {
    *cmd_id_var = NamedCommandLookup(id);
    if (!*cmd_id_var) {
        *cmd_id_var = plugin_register("command_id", (void*)id);
        if (*cmd_id_var) {
            static gaccel_register_t gaccel;
            memset(&gaccel, 0, sizeof(gaccel_register_t));
            gaccel.accel.cmd = *cmd_id_var;
            gaccel.desc = name;
            plugin_register("gaccel", &gaccel);
        }
    }
}

// FIX Windows: Add cleanup function for when the plugin unloads
void UnregisterPlugin() {
#ifdef _WIN32
    UnregisterClassW(g_wndClassName, (HINSTANCE)g_hInst);
#endif
}

extern "C" REAPER_PLUGIN_DLL_EXPORT int
REAPER_PLUGIN_ENTRYPOINT(REAPER_PLUGIN_HINSTANCE hInstance, reaper_plugin_info_t* rec) {
    g_hInst = hInstance;
    if (!rec) {
        UnregisterPlugin();
        return 0;
    }
    if (rec->caller_version != REAPER_PLUGIN_VERSION || !rec->GetFunc || REAPERAPI_LoadAPI(rec->GetFunc) != 0) return 0;
    
    g_hwndParent = rec->hwnd_main;
    screenset_registerNew((char*)"FRZZ_WebView", screenset_callback, NULL);
    RegisterAction("FRZZ_WEBVIEW_OPEN_DEFAULT", "WebView: Open (default)", &g_command_id_open);
    RegisterAction("FRZZ_WEBVIEW_REFRESH_PAGE", "WebView: Refresh Page", &g_command_id_refresh);
    RegisterAction("FRZZ_WEBVIEW_OPEN_URL", "WebView: Open URL...", &g_command_id_openurl);
    plugin_register("hookcommand", (void*)HookCommandProc);
    plugin_register("APIdef_WEBVIEW_Navigate", (void*)"void,const char*,url");
    plugin_register("API_WEBVIEW_Navigate", (void*)WEBVIEW_Navigate);
    return 1;
}

#ifdef _WIN32
// ================================================================= //
//                      РЕАЛИЗАЦИЯ ДЛЯ WINDOWS                       //
// ================================================================= //
LRESULT CALLBACK WebViewWndProc(HWND, UINT, WPARAM, LPARAM);
void OpenWebViewWindow(const std::string& url) {
    Log("Attempting to open WebView window...");
    if (g_hwnd && IsWindow(g_hwnd)) {
        Log("Window already exists.");
        return;
    }
    WNDCLASSW wc{0};
    wc.lpfnWndProc = WebViewWndProc; wc.hInstance = (HINSTANCE)g_hInst; wc.lpszClassName = g_wndClassName; wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    if (!RegisterClassW(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        Log("RegisterClassW failed. Error code: %lu", GetLastError());
        return;
    }
    char* url_param = _strdup(url.c_str());
    g_hwnd = CreateWindowExW(0, g_wndClassName, L"WebView", WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, g_hwndParent, NULL, (HINSTANCE)g_hInst, (LPVOID)url_param);
    
    if (!g_hwnd) {
        Log("CreateWindowExW failed. Error code: %lu", GetLastError());
        free(url_param);
    } else {
        Log("CreateWindowExW succeeded. HWND: %p", g_hwnd);
    }
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
            if (GetResourcePath && GetResourcePath()[0]) {
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
            if (!initial_url_c) { Log("!!! WM_CREATE: lpCreateParams is NULL."); return -1; }
            std::string initial_url_str(initial_url_c);
            free(initial_url_c);
            std::wstring w_url(initial_url_str.begin(), initial_url_str.end());
            Log("WM_CREATE: Initial URL is %s", initial_url_str.c_str());
            g_hWebView2Loader = LoadLibraryA("WebView2Loader.dll");
            if (!g_hWebView2Loader) { Log("Failed to load WebView2Loader.dll"); DestroyWindow(hwnd); return -1; }
            using CreateEnv_t = HRESULT (STDMETHODCALLTYPE*)(PCWSTR, PCWSTR, ICoreWebView2EnvironmentOptions*, ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler*);
            auto pCreate = reinterpret_cast<CreateEnv_t>(GetProcAddress(g_hWebView2Loader, "CreateCoreWebView2EnvironmentWithOptions"));
            if (!pCreate) { Log("Failed to get CreateCoreWebView2EnvironmentWithOptions"); DestroyWindow(hwnd); return -1; }
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
            return 0;
        }
        case WM_CLOSE: { DestroyWindow(hwnd); return 0; }
        case WM_DESTROY: {
            Log("WM_DESTROY received for hwnd %p.", hwnd);
            if (webviewController) { webviewController->Close(); webviewController = nullptr; webview = nullptr; }
            if (g_hWebView2Loader) { FreeLibrary(g_hWebView2Loader); g_hWebView2Loader = nullptr; }
            g_hwnd = NULL; 
            return 0;
        }
        case WM_SIZE: { if (webviewController) { RECT rc; GetClientRect(hwnd, &rc); webviewController->put_Bounds(rc); } return 0; }
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

LRESULT SwellWndProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam) {
    switch (uMsg) {
        case WM_CREATE: {
            NSView* parentView = (NSView*)SWELL_GetViewForHWND(hwnd);
            if (parentView) {
                MyNSView* myView = [[[MyNSView alloc] initWithFrame:[parentView bounds]] autorelease];
                WKWebViewConfiguration* config = [[[WKWebViewConfiguration alloc] init] autorelease];
                WKWebView* wv = [[[WKWebView alloc] initWithFrame:[parentView bounds] configuration:config] autorelease];
                myView->webView = wv;
                [myView addSubview:wv];
                [parentView addSubview:myView];
                SWELL_SetWindowLong(hwnd, 0, (LONG_PTR)myView);
                if (lParam) {
                    const char* url_c_str = (const char*)lParam;
                    WEBVIEW_Navigate(url_c_str);
                }
            }
            return 0;
        }
        case WM_SIZE: {
            MyNSView* myView = (MyNSView*)SWELL_GetWindowLong(hwnd, 0);
            if (myView) {
                NSRect frame = NSMakeRect(0, 0, lParam & 0xFFFF, lParam >> 16);
                [myView setFrame:frame];
                if(myView->webView) [myView->webView setFrame:frame];
            }
            return 0;
        }
        case WM_DESTROY: { g_hwnd = nullptr; return 0; }
    }
    return DefWindowProc(hwnd, uMsg, wParam, lParam);
}
void OpenWebViewWindow(const std::string& url) {
    if (g_hwnd) return;
    WNDCLASS wc = { 0, };
    wc.lpfnWndProc = SwellWndProc;
    wc.hInstance = g_hInst;
    wc.lpszClassName = "MyWebViewSwellClass";
    SWELL_RegisterClass(&wc);
    g_hwnd = CreateWindowEx(0, "MyWebViewSwellClass", "WebView", 0, 0, 0, 0, 0, g_hwndParent, 0, g_hInst, (void*)url.c_str());
}
void WEBVIEW_Navigate(const char* url) {
    if (!g_hwnd) return;
    MyNSView* myView = (MyNSView*)SWELL_GetWindowLong(g_hwnd, 0);
    if (!myView || !myView->webView || !url) return;
    if (strcmp(url, "refresh") == 0) { [myView->webView reload]; return; }
    @autoreleasepool {
        NSString* nsURL = [NSString stringWithUTF8String:url];
        NSURL* URL = [NSURL URLWithString:nsURL];
        NSURLRequest* request = [NSURLRequest requestWithURL:URL];
        [myView->webView loadRequest:request];
    }
}
#endif