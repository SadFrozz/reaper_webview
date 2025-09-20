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
