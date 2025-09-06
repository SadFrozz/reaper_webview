// webview_win.cpp

// --- Шаг 1: Ключевые заголовки Windows ---
#include <windows.h>
#include <windowsx.h>
#include <shlwapi.h>
#pragma comment(lib, "shlwapi.lib")

// --- Шаг 2: Заголовки REAPER и WDL (в правильном порядке) ---
#include "sdk/reaper_plugin.h"
#include "WDL/swell/swell-win32.h"

// --- Шаг 3: Заголовки WebView2 и специфичные для проекта ---
#include <wrl.h>
#include <wil/com.h>
#include "WebView2.h"
#include "webview.h"
#include "resource.h"
#include <string>

// --- Шаг 4: Реализация REAPER API ---
// (Нужно, только если вы вызываете функции API напрямую в этом файле)
#include "sdk/reaper_plugin_functions.h"


// Глобальные переменные только для Windows
wil::com_ptr<ICoreWebView2Controller> webviewController;
wil::com_ptr<ICoreWebView2> webview;
HMODULE g_hWebView2Loader = nullptr;

void Log(const char* format, ...); // Объявление из main.cpp

void CreateWebView(HWND parent)
{
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
                            ResizeWebView(parent);
                            NavigateWebView("https://reaper.fm");
                        }
                        return S_OK;
                    }).Get());
                return S_OK;
            }).Get());
}

void NavigateWebView(const char* url) {
    if (!webview || !url) return;
    if (strcmp(url, "refresh") == 0) { webview->Reload(); return; }
    
    std::wstring w_url;
    int len = MultiByteToWideChar(CP_UTF8, 0, url, -1, NULL, 0);
    if (len > 0) {
        w_url.resize(len - 1);
        MultiByteToWideChar(CP_UTF8, 0, url, -1, &w_url[0], len);
        webview->Navigate(w_url.c_str());
    }
}

void ResizeWebView(HWND parent) {
    if (webviewController) {
        RECT bounds; GetClientRect(parent, &bounds);
        webviewController->put_Bounds(bounds);
    }
}

void DestroyWebView() {
    if (webviewController) { webviewController->Close(); webviewController = nullptr; webview = nullptr; }
    if (g_hWebView2Loader) { FreeLibrary(g_hWebView2Loader); g_hWebView2Loader = nullptr; }
}