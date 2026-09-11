// Reaper WebView Plugin
// (c) Andrew "SadFrozz" Brodsky
// 2025 and later
// webview.h
#pragma once
#include "predef.h"

// Platform-specific WebView initialization, implemented under src/platform/.
void StartWebView(HWND hwnd, const std::string& initial_url);

enum class WebViewEditCommand {
  Copy,
  Cut,
  Paste,
};

// Executes an editing command in the selected embedded browser instance.
// Returns false when the instance is not ready.
bool ExecuteWebViewEditCommand(struct WebViewInstanceRecord* rec, WebViewEditCommand command);

#ifdef _WIN32
// Native Find API helpers (implemented in webview_win.cpp)
void WinEnsureNativeFind(struct WebViewInstanceRecord* rec); // acquire ICoreWebView2Find and options if available
void WinFindStartOrUpdate(struct WebViewInstanceRecord* rec); // (re)start search with current rec->findQuery/options
void WinFindNavigate(struct WebViewInstanceRecord* rec, bool forward); // navigate next/prev
void WinFindClose(struct WebViewInstanceRecord* rec); // stop & release if needed
void WinRememberPageFocus(struct WebViewInstanceRecord* rec);
void WinRestorePageFocus(struct WebViewInstanceRecord* rec);
void WinRestoreContextMenuFocus(struct WebViewInstanceRecord* rec);
void WinUpdateShortcutForwarding(struct WebViewInstanceRecord* rec);
#endif

#ifdef __APPLE__
void MacRememberPageFocus(struct WebViewInstanceRecord* rec);
void MacRestorePageFocus(struct WebViewInstanceRecord* rec);
void MacRememberContextMenuFocus(struct WebViewInstanceRecord* rec);
void MacRestoreContextMenuFocus(struct WebViewInstanceRecord* rec);
#endif
