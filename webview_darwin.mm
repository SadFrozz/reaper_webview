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
void InstanceGoBack(WebViewInstanceRecord* rec) {
  if (!rec || !rec->webView) return; [rec->webView goBack]; }
void InstanceGoForward(WebViewInstanceRecord* rec) {
  if (!rec || !rec->webView) return; [rec->webView goForward]; }
void InstanceReload(WebViewInstanceRecord* rec) {
  if (!rec || !rec->webView) return; [rec->webView reload]; }
// New panel-based search API (macOS)
void InstanceSearchApply(WebViewInstanceRecord* rec, const std::string& query, int index, bool highlightAll, bool caseSens)
{
  if (!rec || !rec->webView) return;
  std::string safe=query; size_t p=0; while((p=safe.find("\\",p))!=std::string::npos){ safe.replace(p,1,"\\\\"); p+=2; }
  p=0; while((p=safe.find("\"",p))!=std::string::npos){ safe.replace(p,1,"\\\""); p+=2; }
  char buf[4096]; snprintf(buf,sizeof(buf),
    "(function(){if(!window.__frzFindApply)return; var r=window.__frzFindApply(\"%s\",%d,%s,%s); if(r){ try{ window.webkit.messageHandlers.frzCtx.postMessage('FINDMETA|'+r.count+'|'+r.index); }catch(e){} } })();",
    safe.c_str(), index, highlightAll?"true":"false", caseSens?"true":"false");
  NSString* js = [NSString stringWithUTF8String:buf];
  [rec->webView evaluateJavaScript:js completionHandler:nil];
}
void InstanceSearchClear(WebViewInstanceRecord* rec)
{
  if (!rec || !rec->webView) return;
  NSString* js = @"(function(){ if(window.__frzFindClear) window.__frzFindClear(); })();";
  [rec->webView evaluateJavaScript:js completionHandler:nil];
}
bool InstanceCanGoBack(WebViewInstanceRecord* rec) { if (!rec || !rec->webView) return false; return [rec->webView canGoBack]; }
bool InstanceCanGoForward(WebViewInstanceRecord* rec) { if (!rec || !rec->webView) return false; return [rec->webView canGoForward]; }

// ===== Панель поиска: helper для событий (macOS) =====
@interface FRZSearchPanelHelper : NSObject
@property (nonatomic, assign) WebViewInstanceRecord* rec;
@end
@implementation FRZSearchPanelHelper
- (void)applyCurrentQueryPreserveIndex:(BOOL)preserveIdx {
  WebViewInstanceRecord* r = self.rec; if (!r) return;
  int idx = preserveIdx ? (r->searchMatchIndex<0?0:r->searchMatchIndex) : 0;
  InstanceSearchApply(r, r->searchQuery, idx, r->searchHighlightAll, r->searchCaseSensitive);
}
- (void)onEditChange:(NSNotification*)n {
  WebViewInstanceRecord* r = self.rec; if(!r) return;
  if (!r->searchField) return;
  r->searchQuery = [[r->searchField stringValue] UTF8String];
  r->searchMatchIndex = 0;
  [self applyCurrentQueryPreserveIndex:NO];
}
- (void)onPrev:(id)sender {
  WebViewInstanceRecord* r = self.rec; if(!r) return; if (r->searchMatchCount>0) {
    r->searchMatchIndex = (r->searchMatchIndex<=0)? (r->searchMatchCount-1) : (r->searchMatchIndex-1);
    [self applyCurrentQueryPreserveIndex:YES];
  }
}
- (void)onNext:(id)sender {
  WebViewInstanceRecord* r = self.rec; if(!r) return; if (r->searchMatchCount>0) {
    r->searchMatchIndex = (r->searchMatchIndex+1) % r->searchMatchCount;
    [self applyCurrentQueryPreserveIndex:YES];
  }
}
- (void)onCase:(id)sender {
  WebViewInstanceRecord* r = self.rec; if(!r) return;
  r->searchCaseSensitive = ([r->searchCaseCheck state] == NSControlStateValueOn);
  r->searchMatchIndex = 0; [self applyCurrentQueryPreserveIndex:NO];
}
- (void)onAll:(id)sender {
  WebViewInstanceRecord* r = self.rec; if(!r) return;
  r->searchHighlightAll = ([r->searchAllCheck state] == NSControlStateValueOn);
  [self applyCurrentQueryPreserveIndex:YES];
}
- (void)onClose:(id)sender {
  WebViewInstanceRecord* r = self.rec; if(!r) return;
  InstanceSearchClear(r);
  r->searchQuery.clear(); r->searchMatchCount = 0; r->searchMatchIndex = -1;
  if (r->searchCounterField) [r->searchCounterField setStringValue:@"0/0"];
  if (r->searchPanelView) [r->searchPanelView setHidden:YES];
  r->searchPanelVisible = false;
}
@end

static void FRZ_UpdateSearchCounterMac(WebViewInstanceRecord* rec) {
  if (!rec || !rec->searchCounterField) return;
  int cur = (rec->searchMatchIndex>=0)?(rec->searchMatchIndex+1):0; int total = rec->searchMatchCount;
  [rec->searchCounterField setStringValue:[NSString stringWithFormat:@"%d/%d",cur,total]];
}


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
  id body = message.body;
  if ([body isKindOfClass:[NSString class]]) {
    NSString* str = (NSString*)body;
    if ([str hasPrefix:@"CTX"]) {
      NSPoint p = [NSEvent mouseLocation];
      int sx = (int)llround(p.x); int sy = (int)llround(p.y);
      if (s_hostHwnd) PostMessage((HWND)s_hostHwnd, WM_CONTEXTMENU, (WPARAM)s_hostHwnd, MAKELPARAM(sx, sy));
    } else if ([str hasPrefix:@"FINDMETA|"]) {
      int cnt=0, idx=0; sscanf([str UTF8String]+9, "%d|%d", &cnt, &idx);
      WebViewInstanceRecord* rec = GetInstanceByHwnd((HWND)s_hostHwnd);
      if (rec) { rec->searchMatchCount=cnt; rec->searchMatchIndex=idx; }
    }
  }
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
    "window.addEventListener('contextmenu', function(e){ e.preventDefault(); try{ window.webkit.messageHandlers.frzCtx.postMessage('CTX'); }catch(_){ } }, true);"
    "var st = document.createElement('style'); st.textContent='*{ -webkit-user-select:none !important; user-select:none !important; }'; document.documentElement.appendChild(st);"
    "window.addEventListener('mousedown', function(e){ if(e.button===2){ e.preventDefault(); } }, true);"
    // Search engine
    "if(!window.__frzFindApply){(function(){function clearMarks(){var old=document.querySelectorAll('mark.__frzfind');for(var i=0;i<old.length;i++){var m=old[i];var t=document.createTextNode(m.textContent);m.parentNode.replaceChild(t,m);}} window.__frzFindClear=clearMarks; window.__frzFindApply=function(q,idx,hiAll,caseSens){clearMarks(); if(!q){return {count:0,index:-1};} var flags=caseSens?'g':'gi'; var rx; try{rx=new RegExp(q.replace(/[.*+?^${}()|[\\]\\]/g,'\\$&'),flags);}catch(e){return {count:0,index:-1};} var matches=[]; function mark(n){ if(n.nodeType!==3) return; var txt=n.nodeValue; var m,last=0; var out=null; while((m=rx.exec(txt))){ if(!out) out=document.createDocumentFragment(); out.appendChild(document.createTextNode(txt.substring(last,m.index))); var hi=document.createElement('mark'); hi.className='__frzfind'; hi.style.background='#fff59d'; hi.style.color='#000'; hi.textContent=m[0]; out.appendChild(hi); matches.push(hi); last=m.index+m[0].length; if(!hiAll) break;} if(out){ out.appendChild(document.createTextNode(txt.substring(last))); n.parentNode.replaceChild(out,n);} } (function walk(el){ if(el.tagName==='SCRIPT'||el.tagName==='STYLE') return; for(var c=el.firstChild;c;){ var n=c.nextSibling; if(c.nodeType===3) mark(c); else walk(c); c=n;} })(document.body); if(!matches.length) return {count:0,index:-1}; if(idx<0) idx=0; if(idx>=matches.length) idx=matches.length-1; var cur=matches[idx]; cur.scrollIntoView({block:'center'}); cur.style.outline='2px solid #f57c00'; return {count:matches.length,index:idx};};})();}"
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

// Внешняя точка для безопасного снятия наблюдателя по WKWebView (используется из PurgeDeadInstances)
extern "C" void FRZ_RemoveTitleObserverFor(WKWebView* wv)
{
  if (!wv) return;
  auto it = g_kvoWrappers.find(wv);
  if (it != g_kvoWrappers.end()) {
    FRZKVOWrapper* wrap = it->second;
    @try { [wv removeObserver:wrap forKeyPath:@"title" context:kTitleObservationContext]; } @catch(...) {}
    g_kvoWrappers.erase(it);
  }
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
