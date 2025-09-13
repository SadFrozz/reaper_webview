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

#ifdef _WIN32
extern HWND   g_dlg;
extern wil::com_ptr<ICoreWebView2Controller> g_controller;
extern wil::com_ptr<ICoreWebView2>           g_webview;
extern HMODULE g_hWebView2Loader;
extern bool   g_com_initialized;
#else
extern HWND       g_dlg;
extern WKWebView* g_webView;
#endif

extern std::string g_lastTabTitle;
extern std::string g_lastWndText;

extern std::string g_titleOverride; // дефолт: kTitleBase
extern std::string g_instanceId;
enum class ShowPanelMode { Unset, Hide, Docker, Always };
extern ShowPanelMode g_showPanelMode;

// dock-состояние (для инфо/refresh)
extern int   g_last_dock_idx;
extern bool  g_last_dock_float;
extern int   g_want_dock_on_create; // -1 unknown(first run), 0 undock, 1 dock

// заголовочная панель
#ifdef _WIN32
extern HWND     g_titleBar;
extern HFONT    g_titleFont;
extern HBRUSH   g_titleBrush;
extern COLORREF g_titleTextColor;
extern COLORREF g_titleBkColor;
extern int      g_titleBarH;
extern int      g_titlePadX;
#else
extern NSView*      g_titleBarView;
extern NSTextField* g_titleLabel;
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
void OpenOrActivate(const std::string& url);
