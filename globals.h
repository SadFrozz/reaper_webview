// Reaper WebView Plugin
// (c) Andrew "SadFrozz" Brodsky
// 2025 and later
// globals.h
#pragma once

#include "predef.h"

// compile-time constы для case/ID
#ifndef WM_SWELL_POST_UNDOCK_FIXSTYLE
  #define WM_SWELL_POST_UNDOCK_FIXSTYLE (WM_USER + 0x101)
#endif
#ifndef IDC_TITLEBAR
  #define IDC_TITLEBAR 1002
#endif

using CommandHandler = bool(*)(int flag);

// ====== extern-глобалы, 1 (инициализируются в globals.mm) ======
extern REAPER_PLUGIN_HINSTANCE g_hInst;
extern HWND   g_hwndParent;
extern int    g_command_id;

extern const char* kDockIdent;
extern const char* kDefaultURL;
extern const char* kTitleBase;

// STL headers required here because many translation units include only globals.h
#include <string>
#include <unordered_map>
#include <memory>
#include <vector>

#ifdef _WIN32
  // Forward declare WebView2 interfaces (headers included elsewhere). We avoid including heavy WIL headers here
  // to keep this header lightweight and prevent duplicate symbol template issues. Implementation files that need
  // smart pointers include deps/wil/com.h themselves.
  struct ICoreWebView2Controller;
  struct ICoreWebView2;
  // Legacy compatibility globals (DEPRECATED, will be removed): controller/webview kept only for code still referencing
    // Legacy globals removed: per-instance access only. (Declarations kept commented for reference during transition.)
    // extern wil::com_ptr<ICoreWebView2Controller> g_controller;
    // extern wil::com_ptr<ICoreWebView2>           g_webview;
  extern HMODULE g_hWebView2Loader;
  extern bool   g_com_initialized;
#else
  // macOS: форвард объявление класса (пер-инстансовый webView хранится в WebViewInstanceRecord)
  class WKWebView; // forward declare Objective-C class
#endif

// (deprecated globals for title caching removed; caching now per-instance)

extern std::string g_instanceId; // текущий активный id (для новых вызовов API)
enum class ShowPanelMode { Unset, Hide, Docker, Always };

// ================= Multi-instance support =================
struct WebViewInstanceRecord {
  std::string id;
  HWND hwnd = nullptr;
  std::string titleOverride;      // per-instance title override (defaults kTitleBase)
  ShowPanelMode panelMode = ShowPanelMode::Unset;
  std::string lastUrl;
  // Docking persistence per instance
  int  wantDockOnCreate = -1;     // -1 unknown, 0 undock, 1 dock
  int  lastDockIdx = -1;
  bool lastDockFloat = false;
#ifdef _WIN32
  ICoreWebView2Controller* controller = nullptr; // stored raw; lifetime managed in webview_win.cpp
  ICoreWebView2*           webview    = nullptr;
  // Per-instance title bar (Windows)
  HWND     titleBar       = nullptr;
  HFONT    titleFont      = nullptr;
  HBRUSH   titleBrush     = nullptr;
  COLORREF titleTextColor = RGB(0,0,0);
  COLORREF titleBkColor   = GetSysColor(COLOR_BTNFACE);
#else
  WKWebView* webView = nil;
  // Per-instance title bar (macOS)
  NSView*      titleBarView = nil;
  NSTextField* titleLabel   = nil;
#endif
  // Per-instance cached captions
  std::string lastTabTitle;
  std::string lastWndText;
};

extern std::unordered_map<std::string, std::unique_ptr<WebViewInstanceRecord>> g_instances; // id -> record
extern int g_randomInstanceCounter; // for random ids
WebViewInstanceRecord* GetInstanceById(const std::string& id);
WebViewInstanceRecord* EnsureInstanceAndMaybeNavigate(const std::string& id, const std::string& url, bool navigate, const std::string& newTitle, ShowPanelMode newMode);
std::string NormalizeInstanceId(const std::string& raw, bool* outWasRandom=nullptr);
WebViewInstanceRecord* GetInstanceByHwnd(HWND hwnd);
void PurgeDeadInstances();
// Persistence stubs (no file IO yet)
void SaveInstanceStateAll();
void LoadInstanceStateAll();

// dock-состояние (для инфо/refresh)
extern int   g_last_dock_idx;
extern bool  g_last_dock_float;
extern int   g_want_dock_on_create; // -1 unknown(first run), 0 undock, 1 dock (active instance hint)

// Общие размеры панели (константы, не per-instance)
#ifdef _WIN32
extern int      g_titleBarH;
extern int      g_titlePadX;
#else
extern CGFloat      g_titleBarH;
extern CGFloat      g_titlePadX;
#endif

// команды
extern std::unordered_map<std::string,int>      g_registered_commands;
extern std::unordered_map<int, CommandHandler>  g_cmd_handlers;
extern std::vector<std::unique_ptr<gaccel_register_t>> g_gaccels;

// ====== функции, используемые из разных TU ======
void UpdateTitlesExtractAndApply(HWND hwnd);
void LayoutTitleBarAndWebView(HWND hwnd, bool titleVisible);
void NavigateExisting(const std::string& url); // legacy single active instance navigation
void NavigateExistingInstance(const std::string& instanceId, const std::string& url);
// per-instance open/activate (creates window if missing)
void OpenOrActivateInstance(const std::string& instanceId, const std::string& url);
