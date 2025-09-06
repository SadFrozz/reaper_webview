// 1. Включаем общий C-совместимый PCH
#include "reaper_webview_pch.h"

// 2. Включаем C++/Objective-C зависимости, нужные ТОЛЬКО для этого файла
#ifdef _WIN32
  #include <wrl.h>
  #include <wil/com.h>
  #include "WebView2.h"
#else
  #import <Cocoa/Cocoa.h>
  #import <WebKit/WebKit.h>
#endif
#include <string>

// 3. Реализация REAPER API
#define REAPERAPI_IMPLEMENT
#include "sdk/reaper_plugin_functions.h"


// =================================================================================
// Global Variables
// =================================================================================
REAPER_PLUGIN_HINSTANCE g_hInst = nullptr;
HWND g_hwndParent = nullptr;
HWND g_hwnd = nullptr;
int g_command_id_open = 0;
int g_command_id_refresh = 0;
int g_command_id_openurl = 0;

#ifdef _WIN32
    wil::com_ptr<ICoreWebView2Controller> webviewController;
    wil::com_ptr<ICoreWebView2> webview;
    HMODULE g_hWebView2Loader = nullptr;
#else
    @interface MyNSView : NSView { @public WKWebView* webView; } @end
    @implementation MyNSView
    - (BOOL)isFlipped { return YES; }
    - (void)dealloc { [webView release]; [super dealloc]; }
    @end
#endif

// Forward declarations
void WEBVIEW_Navigate(const char* url);
static void OpenWebViewWindow(const std::string& url);
LRESULT CALLBACK SwellWndProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam);


// =================================================================================
// Logging
// =================================================================================
void Log(const char* format, ...) {
    char buf[4096];
    va_list args; va_start(args, format); vsnprintf(buf, sizeof(buf), format, args); va_end(args);
#ifdef _WIN32
    OutputDebugStringA("[reaper_webview] "); OutputDebugStringA(buf); OutputDebugStringA("\n");
#else
    NSLog(@"[reaper_webview] %s", buf);
#endif
}


// =================================================================================
// REAPER Integration
// =================================================================================
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
        else MessageBox(g_hwndParent, "WebView is not running.", "WebView Error", MB_OK);
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


// =================================================================================
// Window Management
// =================================================================================
void OpenWebViewWindow(const std::string& url) {
    if (g_hwnd && IsWindow(g_hwnd)) return;

    WNDCLASS wc = { 0, };
    wc.lpfnWndProc = SwellWndProc;
    wc.hInstance = g_hInst;
    wc.lpszClassName = "SWELL_WebView_Class";
    SWELL_RegisterClass(&wc);

    #ifdef _WIN32
        char* url_param = _strdup(url.c_str());
    #else
        char* url_param = strdup(url.c_str());
    #endif

    g_hwnd = CreateWindowEx(0, "SWELL_WebView_Class", "WebView", WS_CHILD | WS_VISIBLE, 0, 0, 800, 600, g_hwndParent, NULL, g_hInst, (LPVOID)url_param);

    if (!g_hwnd) {
        Log("SWELL CreateWindowEx failed.");
        free(url_param);
    }
}

// =================================================================================
// Platform-dependent Navigation and Window Procedure
// =================================================================================
void WEBVIEW_Navigate(const char* url) {
    if (!g_hwnd || !url) return;
    
#ifdef _WIN32
    if (webview) {
        if (strcmp(url, "refresh") == 0) { webview->Reload(); return; }
        std::wstring w_url;
        int len = MultiByteToWideChar(CP_UTF8, 0, url, -1, NULL, 0);
        if (len > 0) {
            w_url.resize(len - 1);
            MultiByteToWideChar(CP_UTF8, 0, url, -1, &w_url[0], len);
            webview->Navigate(w_url.c_str());
        }
    }
#else
    MyNSView* myView = (MyNSView*)SWELL_GetWindowLongPtr(g_hwnd, 0);
    if (!myView || !myView->webView) return;
    
    if (strcmp(url, "refresh") == 0) { [myView->webView reload]; return; }
    
    @autoreleasepool {
        NSString* nsURL = [NSString stringWithUTF8String:url];
        NSURL* URL = [NSURL URLWithString:nsURL];
        NSURLRequest* request = [NSURLRequest requestWithURL:URL];
        [myView->webView loadRequest:request];
    }
#endif
}

LRESULT CALLBACK SwellWndProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam) {
    switch (uMsg) {
        case WM_CREATE: {
            char* initial_url_c = (char*)((CREATESTRUCT*)lParam)->lpCreateParams;
            if (!initial_url_c) return -1;
            std::string initial_url(initial_url_c);
            free(initial_url_c);
            
        #ifdef _WIN32
            wchar_t userDataPath[MAX_PATH] = {0};
            if (GetResourcePath && GetResourcePath()[0]) {
                char narrowPath[MAX_PATH];
                strcpy(narrowPath, GetResourcePath());
                MultiByteToWideChar(CP_UTF8, 0, narrowPath, -1, userDataPath, MAX_PATH);
                PathAppendW(userDataPath, L"\\WebView2_UserData");
                CreateDirectoryW(userDataPath, NULL);
            }
            std::wstring w_url(initial_url.begin(), initial_url.end());
            
            g_hWebView2Loader = LoadLibraryA("WebView2Loader.dll");
            if (!g_hWebView2Loader) { DestroyWindow(hwnd); return -1; }
            
            using CreateEnv_t = HRESULT (STDMETHODCALLTYPE*)(PCWSTR, PCWSTR, ICoreWebView2EnvironmentOptions*, ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler*);
            auto pCreate = reinterpret_cast<CreateEnv_t>(GetProcAddress(g_hWebView2Loader, "CreateCoreWebView2EnvironmentWithOptions"));
            if (!pCreate) { DestroyWindow(hwnd); return -1; }
            
            pCreate(nullptr, (userDataPath[0] ? userDataPath : nullptr), nullptr,
                Microsoft::WRL::Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
                    [hwnd, w_url](HRESULT result, ICoreWebView2Environment* env) -> HRESULT {
                        if (FAILED(result)) { DestroyWindow(hwnd); return result; }
                        env->CreateCoreWebView2Controller(hwnd, Microsoft::WRL::Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                            [hwnd, w_url](HRESULT result, ICoreWebView2Controller* controller) -> HRESULT {
                                if (controller) {
                                    webviewController = controller;
                                    webviewController->get_CoreWebView2(&webview);
                                    RECT rc; GetClientRect(hwnd, &rc);
                                    webviewController->put_Bounds(rc);
                                    webviewController->put_IsVisible(TRUE);
                                    webview->Navigate(w_url.c_str());
                                } else { DestroyWindow(hwnd); }
                                return S_OK;
                            }).Get());
                        return S_OK;
                    }).Get());
        #else
            NSView* parentView = (NSView*)SWELL_GetViewForHWND(hwnd);
            if (parentView) {
                MyNSView* myView = [[[MyNSView alloc] initWithFrame:[parentView bounds]] autorelease];
                WKWebViewConfiguration* config = [[[WKWebViewConfiguration alloc] init] autorelease];
                WKWebView* wv = [[[WKWebView alloc] initWithFrame:[parentView bounds] configuration:config] autorelease];
                myView->webView = wv;
                [myView addSubview:wv];
                [parentView addSubview:myView];
                SWELL_SetWindowLongPtr(hwnd, 0, (LONG_PTR)myView);
                WEBVIEW_Navigate(initial_url.c_str());
            }
        #endif
            return 0;
        }
        case WM_SIZE: {
        #ifdef _WIN32
            if (webviewController) { RECT rc; GetClientRect(hwnd, &rc); webviewController->put_Bounds(rc); }
        #else
            MyNSView* myView = (MyNSView*)SWELL_GetWindowLongPtr(hwnd, 0);
            if (myView) {
                NSRect frame = NSMakeRect(0, 0, LOWORD(lParam), HIWORD(lParam));
                [myView setFrame:frame];
                if(myView->webView) [myView->webView setFrame:frame];
            }
        #endif
            return 0;
        }
        case WM_SETFOCUS: {
        #ifdef _WIN32
            if (webviewController) webviewController->MoveFocus(COREWEBVIEW2_MOVE_FOCUS_REASON_PROGRAMMATIC);
        #endif
            return 0;
        }
        case WM_DESTROY: {
        #ifdef _WIN32
            if (webviewController) { webviewController->Close(); webviewController = nullptr; webview = nullptr; }
            if (g_hWebView2Loader) { FreeLibrary(g_hWebView2Loader); g_hWebView2Loader = nullptr; }
        #endif
            g_hwnd = NULL;
            return 0;
        }
    }
    return DefWindowProc(hwnd, uMsg, wParam, lParam);
}


// =================================================================================
// Plugin Entry Point
// =================================================================================
extern "C" REAPER_PLUGIN_DLL_EXPORT int
REAPER_PLUGIN_ENTRYPOINT(REAPER_PLUGIN_HINSTANCE hInstance, reaper_plugin_info_t* rec) {
    g_hInst = hInstance;
    if (!rec) {
        #ifdef _WIN32
        UnregisterClass("SWELL_WebView_Class", g_hInst);
        #endif
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