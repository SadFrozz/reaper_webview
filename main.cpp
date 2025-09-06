// main.cpp
// --- Шаг 1: Системные заголовки ---
#ifdef _WIN32
  #include <windows.h>
#endif

// --- Шаг 2: Заголовки REAPER и WDL/SWELL ---
#include "sdk/reaper_plugin.h"

#ifdef _WIN32
  #include "WDL/swell/swell-win32.h"
#else
  #include "WDL/swell/swell.h"
#endif

// --- Шаг 3: Заголовки проекта ---
#include "webview.h"
#include "resource.h"

// --- Шаг 4: Стандартные библиотеки и реализация REAPER API ---
#include <cstdio>
#include <string>

#define REAPERAPI_IMPLEMENT
#include "sdk/reaper_plugin_functions.h"


// Глобальные переменные
REAPER_PLUGIN_HINSTANCE g_hInst = nullptr;
HWND g_hwnd = nullptr;
HWND g_hwndParent = nullptr;
int g_command_id = 0; // ID нашего кастомного экшена

// --- Логика экшена ---
void ToggleWebView()
{
    if (g_hwnd && IsWindow(g_hwnd))
        DockWindowRemove(g_hwnd);
    else
    {
        LRESULT CALLBACK WebViewDlgProc(HWND, UINT, WPARAM, LPARAM);
        LRESULT WINAPI DockWndProc(HWND, UINT, WPARAM, LPARAM);

        g_hwnd = CreateDialog(g_hInst, MAKEINTRESOURCE(IDD_WEBVIEW_MAIN), g_hwndParent, WebViewDlgProc);
        DockWindowAddEx(g_hwnd, "WebView", "WebView", true);
        
        HWND docker = GetParent(g_hwnd);
        SetWindowLongPtr(docker, GWLP_USERDATA, (LONG_PTR)GetWindowLongPtr(docker, GWLP_WNDPROC));
        SetWindowLongPtr(docker, GWLP_WNDPROC, (LONG_PTR)DockWndProc);
    }
}

// --- Перехватчик команд (Callback) ---
// REAPER вызывает эту функцию для *каждого* экшена. Мы проверяем, наш ли это.
bool HookCommandProc(int command, int flag)
{
    if (command == g_command_id) {
        ToggleWebView();
        return true; // Сообщаем REAPER, что мы обработали команду
    }
    return false; // Не наша команда, пусть REAPER обработает ее сам
}

// --- Диалоговая процедура ---
LRESULT CALLBACK WebViewDlgProc(HWND hwndDlg, UINT uMsg, WPARAM wParam, LPARAM lParam)
{
    switch (uMsg) {
        case WM_INITDIALOG:
            g_hwnd = hwndDlg;
            CreateWebView(hwndDlg);
            break;
        case WM_SIZE:
            ResizeWebView(hwndDlg);
            break;
        case WM_DESTROY:
            DestroyWebView();
            g_hwnd = NULL;
            break;
    }
    return 0;
}

// --- Процедура для докера ---
LRESULT WINAPI DockWndProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam)
{
    if (DockWindowMessage(hwnd, uMsg, wParam, lParam))
        return 0;
    
    WNDPROC oldProc = (WNDPROC)GetWindowLongPtr(hwnd, GWLP_USERDATA);
    if (oldProc) return oldProc(hwnd, uMsg, wParam, lParam);

    return DefWindowProc(hwnd, uMsg, wParam, lParam);
}

// --- Логирование ---
void Log(const char* format, ...) {
    char buf[4096];
    va_list args; va_start(args, format); vsnprintf(buf, sizeof(buf), format, args); va_end(args);
#ifdef _WIN32
    OutputDebugStringA("[reaper_webview] "); OutputDebugStringA(buf); OutputDebugStringA("\n");
#else
    NSLog(@"[reaper_webview] %s", buf);
#endif
}

// --- Точка входа плагина ---
extern "C" REAPER_PLUGIN_DLL_EXPORT int REAPER_PLUGIN_ENTRYPOINT(REAPER_PLUGIN_HINSTANCE hInstance, reaper_plugin_info_t *rec)
{
    g_hInst = hInstance;
    if (!rec || rec->caller_version != REAPER_PLUGIN_VERSION || !REAPERAPI_LoadAPI(rec->GetFunc))
        return 0;
    
    g_hwndParent = rec->hwnd_main;
    
    // "Чистый" способ регистрации экшена через SDK
    // 1. Регистрируем уникальный ID для нашей команды
    g_command_id = plugin_register("command_id", (void*)"FRZZ_WEBVIEW_OPEN");
    if (!g_command_id) return 0;

    // 2. Регистрируем описание для Action List
    static gaccel_register_t gaccel;
    memset(&gaccel, 0, sizeof(gaccel_register_t));
    gaccel.desc = "WebView: Open/close WebView window";
    gaccel.accel.cmd = g_command_id;
    plugin_register("gaccel", &gaccel);

    // 3. Регистрируем нашу callback-функцию для перехвата вызова экшена
    plugin_register("hookcommand", (void*)HookCommandProc);

    // Регистрация API
    plugin_register("APIdef_WEBVIEW_Navigate", (void*)"void,const char*,url");
    plugin_register("API_WEBVIEW_Navigate", (void*)NavigateWebView);

    return 1;
}