// Reaper WebView Plugin
// (c) Andrew "SadFrozz" Brodsky
// 2025 and later
// webview_mac.mm

#ifdef __APPLE__

#include "predef.h"
#include "globals.h"
#include "helpers.h"
#include "webview.h"


extern WKWebView* g_webView;

@interface FRZWebViewDelegate : NSObject <WKNavigationDelegate, WKScriptMessageHandler>
@end

static HWND s_hostHwnd = NULL;
static FRZWebViewDelegate* g_delegate = nil;

@implementation FRZWebViewDelegate
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
  if (s_hostHwnd) UpdateTitlesExtractAndApply(s_hostHwnd);
}
- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message
{
  if (![message.name isEqualToString:@"frzCtx"]) return;

  // Глобальные координаты курсора (Cocoa: 0,0 — снизу слева)
  NSPoint p = [NSEvent mouseLocation];
  int sx = (int)llround(p.x);
  int sy = (int)llround(p.y);

  if (s_hostHwnd) PostMessage((HWND)s_hostHwnd, WM_CONTEXTMENU, (WPARAM)s_hostHwnd, MAKELPARAM(sx, sy));
}
@end

void StartWebView(HWND hwnd, const std::string& initial_url)
{
  if (!hwnd) return;
  s_hostHwnd = hwnd;

  NSView* host = (NSView*)hwnd;
  if (!host) return;

  WKWebViewConfiguration* cfg = [[WKWebViewConfiguration alloc] init];

  // JS-хук для ПКМ и отключение selection
  WKUserContentController* ucc = [[WKUserContentController alloc] init];
  [cfg setUserContentController:ucc];

  NSString *js =
  @"(function(){"
    // Глушим собственное контекстное меню страницы
    "window.addEventListener('contextmenu', function(e){ e.preventDefault(); "
      "try{ window.webkit.messageHandlers.frzCtx.postMessage('CTX'); }catch(_){ }"
    "}, true);"

    // Отключаем выделение
    "var st = document.createElement('style');"
    "st.textContent='*{ -webkit-user-select:none !important; user-select:none !important; }';"
    "document.documentElement.appendChild(st);"

    // Блокируем mousedown правой кнопкой
    "window.addEventListener('mousedown', function(e){ if(e.button===2){ e.preventDefault(); } }, true);"
  "})();";

  WKUserScript* us = [[WKUserScript alloc] initWithSource:js
                                            injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                         forMainFrameOnly:NO];
  [ucc addUserScript:us];

  if (!g_delegate) g_delegate = [[FRZWebViewDelegate alloc] init];
  [ucc addScriptMessageHandler:g_delegate name:@"frzCtx"];

  // Создаём и вставляем WKWebView
  g_webView = [[WKWebView alloc] initWithFrame:[host bounds] configuration:cfg];
  g_webView.navigationDelegate = g_delegate;
  [g_webView setAutoresizingMask:(NSViewWidthSizable|NSViewHeightSizable)];
  [host addSubview:g_webView];

  // Навигация
  NSString* s = [NSString stringWithUTF8String:initial_url.c_str()];
  NSURL* u = [NSURL URLWithString:s];
  if (u) [g_webView loadRequest:[NSURLRequest requestWithURL:u]];

  UpdateTitlesExtractAndApply(hwnd);
}

#endif // __APPLE__
