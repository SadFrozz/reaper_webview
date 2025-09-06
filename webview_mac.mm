// webview_mac.mm
#define SWELL_TARGET_COCOA
#include "WDL/swell/swell.h"
#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#include "webview.h"
#include "resource.h"

// Глобальная переменная только для macOS
WKWebView* g_webView = nullptr;

void Log(const char* format, ...); // Объявление

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