// webview_mac.mm
#define SWELL_TARGET_COCOA

// --- Шаг 1: Заголовки REAPER и WDL (в правильном порядке) ---
#include "sdk/reaper_plugin.h"
#include "WDL/swell/swell.h"

// --- Шаг 2: Заголовки Cocoa/WebKit и специфичные для проекта ---
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include "webview.h"
#include "resource.h"
#include <string>

// --- Шаг 3: Реализация REAPER API ---
// (Нужно, только если вы вызываете функции API напрямую в этом файле)
#include "sdk/reaper_plugin_functions.h"


// Глобальная переменная только для macOS
WKWebView* g_webView = nullptr;

void Log(const char* format, ...); // Объявление из main.cpp

void CreateWebView(HWND parent)
{
    @autoreleasepool {
        HWND placeholder = GetDlgItem(parent, IDC_WEBVIEW_PLACEHOLDER);
        NSView* parentView = (NSView*)SWELL_GetViewForHWND(placeholder);
        if (!parentView) return;

        NSRect frame = [parentView bounds];
        WKWebViewConfiguration* config = [[[WKWebViewConfiguration alloc] init] autorelease];
        g_webView = [[[WKWebView alloc] initWithFrame:frame configuration:config] autorelease];
        [g_webView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        
        [parentView addSubview:g_webView];
        NavigateWebView("https://reaper.fm");
    }
}

void NavigateWebView(const char* url) {
    if (!g_webView || !url) return;
    if (strcmp(url, "refresh") == 0) { [g_webView reload]; return; }
    
    @autoreleasepool {
        NSString* nsURL = [NSString stringWithUTF8String:url];
        NSURL* URL = [NSURL URLWithString:nsURL];
        NSURLRequest* request = [NSURLRequest requestWithURL:URL];
        [g_webView loadRequest:request];
    }
}

void ResizeWebView(HWND parent) {
    // AutoresizingMask в Cocoa обрабатывает это автоматически
}

void DestroyWebView() {
    g_webView = nil; // ARC позаботится об остальном
}