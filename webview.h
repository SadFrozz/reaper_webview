// Reaper WebView Plugin
// (c) Andrew "SadFrozz" Brodsky
// 2025 and later
// webview.h
#pragma once
#include "predef.h"

// Платформо-специфичная инициализация WebView, реализации — в webview_win.cpp / webview_mac.mm
void StartWebView(HWND hwnd, const std::string& initial_url);

#ifdef _WIN32
// Native Find API helpers (implemented in webview_win.cpp)
void WinEnsureNativeFind(struct WebViewInstanceRecord* rec); // acquire ICoreWebView2Find and options if available
void WinFindStartOrUpdate(struct WebViewInstanceRecord* rec); // (re)start search with current rec->findQuery/options
void WinFindNavigate(struct WebViewInstanceRecord* rec, bool forward); // navigate next/prev
void WinFindClose(struct WebViewInstanceRecord* rec); // stop & release if needed
#endif
