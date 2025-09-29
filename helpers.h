// Reaper WebView Plugin
// (c) Andrew "SadFrozz" Brodsky
// 2025 and later
// helpers.h
#pragma once

#include "predef.h"

#include "globals.h" // для ShowPanelMode, HWND, SDK функций

#ifdef _WIN32
std::wstring Widen(const std::string& s);
std::string  Narrow(const std::wstring& w);
#endif

std::string ExtractDomainFromUrl(const std::string& url);
void SetWndText(HWND hwnd, const std::string& s);
void SaveDockState(HWND hwnd);
void SetTabTitleInplace(HWND hwnd, const std::string& tabCaption);

// реализованы в helpers.mm
void SafePluginRegister(const char* name, void* p);
void SafePluginRegister(const char* name, const char* sig);
void SafePluginRegisterNull(const char* name);

void PlatformMakeTopLevel(HWND hwnd);

// tiny JSON helpers (реализация в helpers.mm)
bool is_truthy(const char* s);
std::string GetJsonString(const char* json, const char* key);
ShowPanelMode ParseShowPanel(const std::string& v);

// ================= URL normalization =================
// Normalize a user-entered URL:
//  - Trim spaces.
//  - If it has an http/https/file/about/data/mailto/... scheme, returns as-is.
//  - If it has another explicit scheme (e.g. spotify:, steam://), returns empty in outNormalized
//    and sets *outExternal to original (caller should open externally via ShellExecute / NSWorkspace).
//  - If it has no scheme, prefix with "https://".
// Returns true if navigation should proceed in embedded webview (outNormalized valid),
// false if should dispatch externally (outExternal filled) or input invalid.
// outReason may contain brief diagnostic for logging.
bool NormalizeOrDispatchURL(const std::string& input,
							std::string& outNormalized,
							std::string& outExternal,
							std::string& outReason);

// ================= Theme color helpers for panels =================
#ifdef _WIN32
// Resolve panel background/text colors using REAPER theme forwarding + fallback.
void GetPanelThemeColors(HWND panelHwnd, HDC dc, COLORREF* outBk, COLORREF* outTx);
#else
// Returns 24-bit RGB colors (background/text) via out params (may be -1 for fallback usage).
void GetPanelThemeColorsMac(int* outBg, int* outTx);
#endif
