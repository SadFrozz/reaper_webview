// =================================================================================
// Includes and Platform Definitions (ФИНАЛЬНЫЙ ПРАВИЛЬНЫЙ ПОРЯДОК)
// =================================================================================
#ifdef _WIN32
  #include <windows.h>
  #include <windowsx.h>
  #include <shlwapi.h>
  #pragma comment(lib, "shlwapi.lib")
#endif

#include "sdk/reaper_plugin.h"

#ifdef _WIN32
  #include "WDL/swell/swell-win32.h"
  #include <wrl.h>
  #include <wil/com.h>
  #include "WebView2.h"
#else
  #define SWELL_TARGET_COCOA
  #include "WDL/swell/swell.h"
  #import <Cocoa/Cocoa.h>
  #import <WebKit/WebKit.h>
#endif

#include "resource.h"
#include <string>
#include <cstdio>

#define REAPERAPI_IMPLEMENT
#include "sdk/reaper_plugin_functions.h"

// =================================================================================
// Global Variables
// =================================================================================
REAPER_PLUGIN_HINSTANCE g_hInst = nullptr;
HWND g_hwnd = nullptr; // HWND нашего диалога
static WNDPROC g_prevDockWndProc = nullptr;

#ifdef _WIN32
    wil::com_ptr<ICoreWebView2Controller> webviewController;
    wil::com_ptr<ICoreWebView2> webview;
    HMODULE g_hWebView2Loader = nullptr;
#else
    WKWebView* g_webView = nullptr;
#endif

// =================================================================================
// Forward Declarations & Logging
// =================================================================================
void WEBVIEW_Navigate(const char* url);
LRESULT CALLBACK WebViewDlgProc(HWND hwndDlg, UINT uMsg, WPARAM wParam, LPARAM lParam);
void Log(const char* format, ...);

// =================================================================================
// WebView Implementation (Platform Specific)
// =================================================================================
void CreateWebView(HWND parent)
{
#ifdef _WIN32
    wchar_t userDataPath[MAX_PATH] = {0};
    if (GetResourcePath && GetResourcePath()[0]) {
        MultiByteToWideChar(CP_UTF8, 0, GetResourcePath(), -1, userDataPath, MAX_PATH);
        PathAppendW(userDataPath, L"\\WebView2_UserData");
        CreateDirectoryW(userDataPath, NULL);
    }
    
    g_hWebView2Loader = LoadLibraryA("WebView2Loader.dll");
    if (!g_hWebView2Loader) { Log("Failed to load WebView2Loader.dll"); return; }

    using CreateEnv_t = HRESULT(STDMETHODCALLTYPE*)(PCWSTR, PCWSTR, ICoreWebView2EnvironmentOptions*, ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler*);
    auto pCreate = reinterpret_cast<CreateEnv_t>(GetProcAddress(g_hWebView2Loader, "CreateCoreWebView2EnvironmentWithOptions"));
    if (!pCreate) { Log("Failed to get CreateCoreWebView2EnvironmentWithOptions"); return; }
    
    pCreate(nullptr, userDataPath, nullptr,
        Microsoft::WRL::Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
            [parent](HRESULT result, ICoreWebView2Environment* env) -> HRESULT {
                if (FAILED(result)) return result;
                env->CreateCoreWebView2Controller(parent, Microsoft::WRL::Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                    [parent](HRESULT result, ICoreWebView2Controller* controller) -> HRESULT {
                        if (controller) {
                            webviewController = controller;
                            webviewController->get_CoreWebView2(&webview);
                            webviewController->put_IsVisible(TRUE);
                            RECT bounds; GetClientRect(parent, &bounds);
                            webviewController->put_Bounds(bounds);
                            WEBVIEW_Navigate("https://reaper.fm");
                        }
                        return S_OK;
                    }).Get());
                return S_OK;
            }).Get());
#else
    @autoreleasepool {
        NSRect frame = [(NSView*)SWELL_GetViewForHWND(parent) bounds];
        WKWebViewConfiguration* config = [[[WKWebViewConfiguration alloc] init] autorelease];
        g_webView = [[[WKWebView alloc] initWithFrame:frame configuration:config] autorelease];
        [g_webView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        
        NSView* parentView = (NSView*)SWELL_GetViewForHWND(GetDlgItem(parent, IDC_WEBVIEW_PLACEHOLDER));
        [parentView addSubview:g_webView];
        WEBVIEW_Navigate("https://reaper.fm");
    }
#endif
}

void WEBVIEW_Navigate(const char* url) {
    if (!url) return;
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
    if (g_webView) {
        if (strcmp(url, "refresh") == 0) { [g_webView reload]; return; }
        @autoreleasepool {
            NSString* nsURL = [NSString stringWithUTF8String:url];
            NSURL* URL = [NSURL URLWithString:nsURL];
            NSURLRequest* request = [NSURLRequest requestWithURL:URL];
            [g_webView loadRequest:request];
        }
    }
#endif
}

// =================================================================================
// Dialog Procedure
// =================================================================================
LRESULT CALLBACK WebViewDlgProc(HWND hwndDlg, UINT uMsg, WPARAM wParam, LPARAM lParam)
{
    switch (uMsg) {
        case WM_INITDIALOG:
            g_hwnd = hwndDlg;
            CreateWebView(hwndDlg);
            break;
        case WM_SIZE:
        #ifdef _WIN32
            if (webviewController) {
                RECT rc; GetClientRect(hwndDlg, &rc);
                webviewController->put_Bounds(rc);
            }
        #endif
            break;
        case WM_DESTROY:
        #ifdef _WIN32
            if (webviewController) { webviewController->Close(); webviewController = nullptr; webview = nullptr; }
            if (g_hWebView2Loader) { FreeLibrary(g_hWebView2Loader); g_hWebView2Loader = nullptr; }
        #else
            g_webView = nil;
        #endif
            g_hwnd = NULL;
            break;
    }
    return 0;
}

// =================================================================================
// REAPER Integration & Plugin Entry
// =================================================================================
LRESULT WINAPI DockWndProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam)
{
    // Pass messages to the DlgProc
    if (DockWindowMessage(hwnd, uMsg, wParam, lParam))
        return 0;
    return g_prevDockWndProc(hwnd, uMsg, wParam, lParam);
}

static void toggle_action(COMMAND_T* ct)
{
    if (g_hwnd && IsWindow(g_hwnd))
        DockWindowRemove(g_hwnd);
    else
    {
        g_hwnd = CreateDialog(g_hInst, MAKEINTRESOURCE(IDD_WEBVIEW_MAIN), g_hwndParent, WebViewDlgProc);
        DockWindowAddEx(g_hwnd, "WebView", "WebView", true);
        g_prevDockWndProc = (WNDPROC)SetWindowLongPtr(GetParent(g_hwnd), GWLP_WNDPROC, (LONG_PTR)DockWndProc);
    }
}

static COMMAND_T g_command_table[] = {
    { { DEFACCEL, "SWS/FROZZ: Open WebView" }, "FRZZ_WEBVIEW_OPEN", toggle_action, },
    { {}, },
};

extern "C" REAPER_PLUGIN_DLL_EXPORT int REAPER_PLUGIN_ENTRYPOINT(REAPER_PLUGIN_HINSTANCE hInstance, reaper_plugin_info_t *rec)
{
    g_hInst = hInstance;
    if (!rec) return 0;
    if (rec->caller_version != REAPER_PLUGIN_VERSION) return 0;
    if (!REAPERAPI_LoadAPI(rec->GetFunc)) return 0;
    
    g_hwndParent = rec->hwnd_main;
    plugin_register("gaccel", &g_command_table[0]);
    
    plugin_register("APIdef_WEBVIEW_Navigate", (void*)"void,const char*,url");
    plugin_register("API_WEBVIEW_Navigate", (void*)WEBVIEW_Navigate);

    return 1;
}

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