// webview.h
#pragma once
#include "sdk/reaper_plugin.h"

// Функции, которые должны быть реализованы для каждой платформы
void CreateWebView(HWND parent);
void NavigateWebView(const char* url);
void ResizeWebView(HWND parent);
void DestroyWebView();