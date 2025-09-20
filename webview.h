// Reaper WebView Plugin
// (c) Andrew "SadFrozz" Brodsky
// 2025 and later
// webview.h
#pragma once
#include "predef.h"

// Платформо-специфичная инициализация WebView, реализации — в webview_win.cpp / webview_mac.mm
void StartWebView(HWND hwnd, const std::string& initial_url);
