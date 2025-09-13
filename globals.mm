// Reaper WebView Plugin
// (c) Andrew "SadFrozz" Brodsky
// 2025 and later
// globals.mm

#define RWV_WITH_WEBVIEW2 1
#include "predef.h"
#include "globals.h"
#include "helpers.h"

REAPER_PLUGIN_HINSTANCE g_hInst = nullptr;
HWND   g_hwndParent = nullptr;
int    g_command_id = 0;

const char* kDockIdent  = "reaper_webview";
const char* kDefaultURL = "https://www.reaper.fm/";
const char* kTitleBase  = "WebView";

#ifdef _WIN32
HWND   g_dlg = nullptr;
wil::com_ptr<ICoreWebView2Controller> g_controller;
wil::com_ptr<ICoreWebView2>           g_webview;
HMODULE g_hWebView2Loader = nullptr;
bool    g_com_initialized = false;
#else
HWND       g_dlg = nullptr;
WKWebView* g_webView = nil;
#endif

std::string g_lastTabTitle;
std::string g_lastWndText;

std::string g_titleOverride = kTitleBase;
std::string g_instanceId;
ShowPanelMode g_showPanelMode = ShowPanelMode::Unset;

int  g_last_dock_idx        = -1;
bool g_last_dock_float      = false;
int  g_want_dock_on_create  = -1;

#ifdef _WIN32
HWND     g_titleBar        = nullptr;
HFONT    g_titleFont       = nullptr;
HBRUSH   g_titleBrush      = nullptr;
COLORREF g_titleTextColor  = RGB(0,0,0);
COLORREF g_titleBkColor    = GetSysColor(COLOR_BTNFACE);
int      g_titleBarH       = 24;  // фикс, без привязки к DPI
int      g_titlePadX       = 8;
#else
NSView*      g_titleBarView = nil;
NSTextField* g_titleLabel   = nil;
CGFloat      g_titleBarH    = 24.0;
CGFloat      g_titlePadX    = 8.0;
#endif

std::unordered_map<std::string,int>      g_registered_commands;
std::unordered_map<int, CommandHandler>  g_cmd_handlers;
std::vector<std::unique_ptr<gaccel_register_t>> g_gaccels;
