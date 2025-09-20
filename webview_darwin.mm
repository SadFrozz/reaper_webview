// Reaper WebView Plugin
// (c) Andrew "SadFrozz" Brodsky
// 2025 and later
// webview_mac.mm

#ifdef __APPLE__

#include "predef.h"
#include "globals.h"
#include "helpers.h"
#include "webview.h"
#include <unordered_map> // для карт наблюдателей


// Используется пер-инстансовое хранение WKWebView (WebViewInstanceRecord)

@interface FRZWebViewDelegate : NSObject <WKNavigationDelegate, WKScriptMessageHandler>
@end

static HWND s_hostHwnd = NULL;
static FRZWebViewDelegate* g_delegate = nil;
static void ObserveTitleIfNeeded(WKWebView* wv, HWND hwnd);

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
  std::string activeId = g_instanceId.empty()?std::string("wv_default"):g_instanceId;

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
  WKWebView* localWV = [[WKWebView alloc] initWithFrame:[host bounds] configuration:cfg];
  localWV.navigationDelegate = g_delegate;
  [localWV setAutoresizingMask:(NSViewWidthSizable|NSViewHeightSizable)];
  [host addSubview:localWV];

  // KVO на title чтобы оперативно подхватывать изменения заголовка документа
  ObserveTitleIfNeeded(localWV, hwnd);

  WebViewInstanceRecord* rec = GetInstanceById(activeId);
  if (rec) { rec->webView = localWV; if (!rec->hwnd) rec->hwnd = hwnd; }

  // Навигация
  NSString* s = [NSString stringWithUTF8String:initial_url.c_str()];
  NSURL* u = [NSURL URLWithString:s];
  if (u) [localWV loadRequest:[NSURLRequest requestWithURL:u]];

  UpdateTitlesExtractAndApply(hwnd);
}

// ===================== Title Observation =====================
// Отдельный статический sentinel для KVO контекста
static int g_titleObsSentinel = 0;
static void* kTitleObservationContext = &g_titleObsSentinel;

@interface FRZKVOWrapper : NSObject
@property (nonatomic, assign) HWND hwnd;
@end
@implementation FRZKVOWrapper @end

static std::unordered_map<WKWebView*, FRZKVOWrapper*> g_kvoWrappers;

static void ObserveTitleIfNeeded(WKWebView* wv, HWND hwnd)
{
  if (!wv) return;
  if (g_kvoWrappers.find(wv) != g_kvoWrappers.end()) return; // already
  FRZKVOWrapper* wrap = [[FRZKVOWrapper alloc] init];
  wrap.hwnd = hwnd;
  g_kvoWrappers[wv] = wrap;
  [wv addObserver:wrap forKeyPath:@"title" options:NSKeyValueObservingOptionNew context:kTitleObservationContext];
}

// Override observeValueForKeyPath via category on FRZKVOWrapper
@interface FRZKVOWrapper (Observer)
@end
@implementation FRZKVOWrapper (Observer)
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context
{
  if (context == kTitleObservationContext) {
    if (self.hwnd) UpdateTitlesExtractAndApply(self.hwnd);
    return;
  }
  [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
}
@end

// (Опционально) функция очистки наблюдателей — может вызываться при полном завершении плагина/инстансов
static void CleanupTitleObservers()
{
  for (auto &kv : g_kvoWrappers) {
    WKWebView* wv = kv.first; FRZKVOWrapper* wrap = kv.second;
    @try { [wv removeObserver:wrap forKeyPath:@"title" context:kTitleObservationContext]; }
    @catch(...) { }
  }
  g_kvoWrappers.clear();
}


void NavigateExisting(const std::string& url)
{
  if (url.empty()) return;
  std::string activeId = g_instanceId.empty()?std::string("wv_default"):g_instanceId;
  WebViewInstanceRecord* rec = GetInstanceById(activeId);
  if (!rec || !rec->webView) return;
  NSString* s = [NSString stringWithUTF8String:url.c_str()];
  NSURL* u = [NSURL URLWithString:s];
  if (u) [rec->webView loadRequest:[NSURLRequest requestWithURL:u]];
}

void NavigateExistingInstance(const std::string& instanceId, const std::string& url)
{
  if (url.empty()) return;
  WebViewInstanceRecord* rec = GetInstanceById(instanceId);
  if (!rec || !rec->webView || url.empty()) return;
  rec->lastUrl = url;
  NSString* s = [NSString stringWithUTF8String:url.c_str()];
  NSURL* u = [NSURL URLWithString:s];
  if (u) [rec->webView loadRequest:[NSURLRequest requestWithURL:u]];
}

#endif // __APPLE__
