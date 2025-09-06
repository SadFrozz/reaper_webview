// ===================================================================
// ЗАГОЛОВКИ
// ===================================================================

// Сначала системные заголовки для Windows
#ifdef _WIN32
  #include <windows.h>
  #include <windowsx.h>
  #include <shlwapi.h>
  #pragma comment(lib, "shlwapi.lib")
#endif

// Затем REAPER SDK, который корректно настраивает типы
#include "sdk/reaper_plugin.h"

// Теперь SWELL и специфичные для платформы зависимости
#ifdef _WIN32
  #include "WDL/swell/swell-win32.h"
  #include <wrl.h>
  #include <wil/com.h>
  #include "WebView2.h"
#else
  #define SWELL_TARGET_COCOA
  #import <Cocoa/Cocoa.h>
  #import <WebKit/WebKit.h>
  #include "WDL/swell/swell.h"
#endif

// Заголовки проекта и стандартные библиотеки
#include "resource.h"
#include <string>
#include <cstdio>

// Реализация функций REAPER API в самом конце
#define REAPERAPI_IMPLEMENT
#include "sdk/reaper_plugin_functions.h"

// ===================================================================
// ГЛОБАЛЬНЫЕ ПЕРЕМЕННЫЕ
// ===================================================================
REAPER_PLUGIN_HINSTANCE g_hInst = nullptr;
HWND g_hwnd = nullptr;
HWND g_hwndParent = nullptr;
int g_command_id = 0;

#ifdef _WIN32
    wil::com_ptr<ICoreWebView2Controller> webviewController;
    wil::com_ptr<ICoreWebView2> webview;
    HMODULE g_hWebView2Loader = nullptr;
#else
    WKWebView* g_webView = nullptr;
#endif

// ===================================================================
// ПРОЦЕДУРЫ И ФУНКЦИИ
// ===================================================================
LRESULT CALLBACK DlgProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam);

void NavigateWebView(const char* url) {
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

void ToggleWindow()
{
    if (g_hwnd && IsWindow(g_hwnd))
    {
        DestroyWindow(g_hwnd);
        g_hwnd = NULL;
    }
    else
    {
        g_hwnd = CreateDialog(g_hInst, MAKEINTRESOURCE(IDD_DIALOG1), g_hwndParent, DlgProc);
        ShowWindow(g_hwnd, SW_SHOW);
    }
}

bool HookCommandProc(int command, int flag)
{
    if (command == g_command_id) {
        ToggleWindow();
        return true; 
    }
    return false;
}

LRESULT CALLBACK DlgProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam)
{
    switch (uMsg)
    {
        case WM_INITDIALOG:
        {
#ifdef _WIN32
            wchar_t userDataPath[MAX_PATH] = {0};
            if (GetResourcePath && GetResourcePath()[0]) {
                MultiByteToWideChar(CP_UTF8, 0, GetResourcePath(), -1, userDataPath, MAX_PATH);
                PathAppendW(userDataPath, L"\\WebView2_UserData");
                CreateDirectoryW(userDataPath, NULL);
            }
            g_hWebView2Loader = LoadLibraryA("WebView2Loader.dll");
            if (!g_hWebView2Loader) return TRUE;

            using CreateEnv_t = HRESULT(STDMETHODCALLTYPE*)(PCWSTR, PCWSTR, ICoreWebView2EnvironmentOptions*, ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler*);
            auto pCreate = reinterpret_cast<CreateEnv_t>(GetProcAddress(g_hWebView2Loader, "CreateCoreWebView2EnvironmentWithOptions"));
            if (!pCreate) return TRUE;
            
            pCreate(nullptr, userDataPath, nullptr,
                Microsoft::WRL::Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
                    [hwnd](HRESULT result, ICoreWebView2Environment* env) -> HRESULT {
                        if (FAILED(result)) return result;
                        env->CreateCoreWebView2Controller(hwnd, Microsoft::WRL::Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
                            [hwnd](HRESULT result, ICoreWebView2Controller* controller) -> HRESULT {
                                if (controller) {
                                    webviewController = controller;
                                    webviewController->get_CoreWebView2(&webview);
                                    webviewController->put_IsVisible(TRUE);
                                    RECT rc; GetClientRect(hwnd, &rc);
                                    webviewController->put_Bounds(rc);
                                    NavigateWebView("https://reaper.fm");
                                }
                                return S_OK;
                            }).Get());
                        return S_OK;
                    }).Get());
#else
            @autoreleasepool {
                HWND placeholder = GetDlgItem(hwnd, IDC_PLACEHOLDER);
                NSView* parentView = (NSView*)SWELL_GetViewForHWND(placeholder);
                if (!parentView) return TRUE;

                NSRect frame = [parentView bounds];
                WKWebViewConfiguration* config = [[[WKWebViewConfiguration alloc] init] autorelease];
                g_webView = [[[WKWebView alloc] initWithFrame:frame configuration:config] autorelease];
                [g_webView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
                
                [parentView addSubview:g_webView];
                NavigateWebView("https://reaper.fm");
            }
#endif
        }
        return TRUE;

        case WM_SIZE:
#ifdef _WIN32
            if (webviewController) {
                RECT rc; GetClientRect(hwnd, &rc);
                webviewController->put_Bounds(rc);
            }
#endif
            break;

        case WM_COMMAND:
            if (LOWORD(wParam) == IDCANCEL || LOWORD(wParam) == IDOK) {
                DestroyWindow(hwnd);
                g_hwnd = NULL;
            }
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
    return FALSE;
}

// ===================================================================
// ТОЧКА ВХОДА
// ===================================================================
extern "C" REAPER_PLUGIN_DLL_EXPORT int REAPER_PLUGIN_ENTRYPOINT(REAPER_PLUGIN_HINSTANCE hInstance, reaper_plugin_info_t *rec)
{
    g_hInst = hInstance;
    if (!rec || rec->caller_version != REAPER_PLUGIN_VERSION || !REAPERAPI_LoadAPI(rec->GetFunc)) return 0;
    
    g_hwndParent = rec->hwnd_main;
    
    g_command_id = plugin_register("command_id", (void*)"FRZZ_WEBVIEW_OPEN");
    if (!g_command_id) return 0;

    static gaccel_register_t gaccel;
    memset(&gaccel, 0, sizeof(gaccel_register_t));
    gaccel.desc = "WebView: Open/close WebView window";
    gaccel.accel.cmd = g_command_id;
    plugin_register("gaccel", &gaccel);

    plugin_register("hookcommand", (void*)HookCommandProc);
    plugin_register("APIdef_WEBVIEW_Navigate", (void*)"void,const char*,url");
    plugin_register("API_WEBVIEW_Navigate", (void*)NavigateWebView);

    return 1;
}