// Reaper WebView Plugin
// (c) Andrew "SadFrozz" Brodsky
// 2025 and later
// webview_mac.mm

#ifdef __APPLE__

#include "predef.h"
#include "globals.h"
#include "helpers.h"
#include "webview.h"
#include "log.h"
#include <unordered_map> // for observer maps

// Forward decls for functions implemented in main.mm (mac UI helpers)
extern "C" void MacFindNavigate(struct WebViewInstanceRecord* rec, bool forward);
// EnsureFindBarCreated is implemented in main.mm; not directly accessible here, so do not call.


// Per-instance storage of WKWebView (WebViewInstanceRecord)

@interface FRZWebViewDelegate : NSObject <WKNavigationDelegate, WKScriptMessageHandler>
@end

static HWND s_hostHwnd = NULL;
static FRZWebViewDelegate* g_delegate = nil;
static void ObserveTitleIfNeeded(WKWebView* wv, HWND hwnd);

@implementation FRZWebViewDelegate
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
  if (s_hostHwnd) UpdateTitlesExtractAndApply(s_hostHwnd);
  for(auto &kv: g_instances){ WebViewInstanceRecord* r=kv.second.get(); if(r && r->webView==webView){ r->findLastHighlightedQuery.clear(); r->findLastHighlightedCase=false; LogF("[Find][mac-fast] nav finish -> reset cache id='%s'", r->id.c_str()); break; } }
}
- (void)userContentController:(WKUserContentController *)userContentController
      didReceiveScriptMessage:(WKScriptMessage *)message
{
  if (![message.name isEqualToString:@"frzCtx"]) return;

  // Global cursor coordinates (Cocoa: origin 0,0 is bottom-left)
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

  // JS hook for right-click (custom context menu) and disabling selection
  WKUserContentController* ucc = [[WKUserContentController alloc] init];
  [cfg setUserContentController:ucc];

  NSString *js =
  @"(function(){"
  // Suppress the page's native context menu
    "window.addEventListener('contextmenu', function(e){ e.preventDefault(); "
      "try{ window.webkit.messageHandlers.frzCtx.postMessage('CTX'); }catch(_){ }"
    "}, true);"

  // Disable text selection
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

  // ================= Focus tracking (mac) =================
  static bool s_focusHooksInstalled = false;
  if(!s_focusHooksInstalled){
    s_focusHooksInstalled = true;
    // Helper to resolve webview -> instance
    auto updateActiveForWebView = ^(WKWebView* target, const char* reason){
      if(!target) return; WebViewInstanceRecord* recMatch=nullptr; for(auto &kv: g_instances){ WebViewInstanceRecord* r=kv.second.get(); if(r && r->webView == target){ recMatch = r; break; } }
      if(!recMatch) return; unsigned long tick = (unsigned long)([NSDate timeIntervalSinceReferenceDate]*1000.0);
      recMatch->lastFocusTick = tick; UpdateFocusChain(recMatch->id); if(g_activeInstanceId != recMatch->id){ if(!g_activeInstanceId.empty()) g_lastFocusedInstanceId = g_activeInstanceId; g_activeInstanceId = recMatch->id; }
      LogF("[FocusTick][mac] activate id='%s' reason=%s tick=%lu", recMatch->id.c_str(), reason, (unsigned long)recMatch->lastFocusTick);
    };
    // Window key notifications
    [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidBecomeKeyNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification* n){
      NSWindow* w = (NSWindow*)n.object; if(!w) return; NSResponder* fr = [w firstResponder]; if(!fr) return; // Walk up to WKWebView
      NSView* v = nil; if([fr isKindOfClass:[NSView class]]) v=(NSView*)fr; while(v){ if([v isKindOfClass:[WKWebView class]]){ updateActiveForWebView((WKWebView*)v, "becomeKey"); break; } v=v.superview; }
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowDidResignKeyNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification* n){
      // Log only; keep last-focused for fallback
      if(!g_activeInstanceId.empty()){ LogF("[FocusTick][mac] resign window activeId='%s'", g_activeInstanceId.c_str()); }
    }];
    // Local mouse down monitor to catch clicks inside a webview even if window already key
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown handler:^NSEvent*(NSEvent* e){
      NSWindow* w = e.window; if(!w) return e; NSPoint loc = [e locationInWindow]; NSView* hit = [w.contentView hitTest:loc]; NSView* cur = hit; while(cur){ if([cur isKindOfClass:[WKWebView class]]){ updateActiveForWebView((WKWebView*)cur, "mouseDown"); break; } cur=cur.superview; }
      return e;
    }];

    // Cmd+F (find) key monitor similar to Windows Ctrl+F behavior.
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent*(NSEvent* e){
      if((e.modifierFlags & NSEventModifierFlagCommand) && !((e.modifierFlags & NSEventModifierFlagOption))){
        NSString* chars = e.charactersIgnoringModifiers;
        if(chars.length==1){
          unichar c=[chars characterAtIndex:0];
          if(c=='f' || c=='F'){
            // Determine active instance (fallback to any webview under key window)
            WebViewInstanceRecord* rec = nullptr;
            if(!g_activeInstanceId.empty()) rec = GetInstanceById(g_activeInstanceId);
            if(!rec){
              for(auto &kv: g_instances){ if(kv.second && kv.second->webView){ rec = kv.second.get(); break; } }
            }
            if(rec){
              if(!rec->showFindBar){
                rec->showFindBar = true;
                LayoutTitleBarAndWebView(rec->hwnd, rec->titleBarView && ![rec->titleBarView isHidden]);
                if(rec->findEdit){ [(NSTextField*)rec->findEdit selectText:nil]; [[(NSTextField*)rec->findEdit window] makeFirstResponder:(NSTextField*)rec->findEdit]; }
                LogRaw("[FindCmdF][mac] show find bar (Cmd+F)");
              } else {
                if(rec->findEdit){ [[(NSTextField*)rec->findEdit window] makeFirstResponder:(NSTextField*)rec->findEdit]; }
                bool shift = (e.modifierFlags & NSEventModifierFlagShift)!=0;
                MacFindNavigate(rec, !shift);
                LogF("[FindCmdF][mac] nav %s query='%s'", shift?"prev":"next", rec->findQuery.c_str());
              }
              return (NSEvent*)nil; // swallow
            }
          }
        }
      }
      return e; // pass through
    }];

    // ================= Visibility polling timer =================
    static dispatch_source_t s_visTimer = nullptr;
    auto isHostVisible = ^bool(WebViewInstanceRecord* r){ if(!r || !r->hwnd) return false; NSView* v=(NSView*)r->hwnd; if(![v window]) return false; if([v isHidden]) return false; if([v alphaValue] <= 0.01) return false; // primitive; could extend
      // Also check any ancestor hidden
      NSView* cur=v; while(cur){ if([cur isHidden]) return false; cur=cur.superview; } return true; };
    if(!s_visTimer){
      s_visTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
      dispatch_source_set_timer(s_visTimer, dispatch_time(DISPATCH_TIME_NOW, 500ull*1000*1000), 500ull*1000*1000, 50ull*1000*1000);
      dispatch_source_set_event_handler(s_visTimer, ^{
        // If current active became invisible -> demote to last
        if(!g_activeInstanceId.empty()){
          WebViewInstanceRecord* active = GetInstanceById(g_activeInstanceId);
            if(!isHostVisible(active)){
              if(!g_activeInstanceId.empty()){
                if(g_lastFocusedInstanceId != g_activeInstanceId) g_lastFocusedInstanceId = g_activeInstanceId;
                LogF("[FocusTick][mac] deactivate id='%s' reason=hidden", g_activeInstanceId.c_str());
                g_activeInstanceId.clear();
              }
            }
        }
        // If no active -> try pick a visible one (but do not overwrite if multiple visible)
        if(g_activeInstanceId.empty()){
          WebViewInstanceRecord* candidate=nullptr; int visibleCount=0;
          for(auto &kv: g_instances){ WebViewInstanceRecord* r=kv.second.get(); if(isHostVisible(r)){ visibleCount++; if(!candidate) candidate=r; } }
          if(visibleCount==1 && candidate){ candidate->lastFocusTick = (unsigned long)([NSDate timeIntervalSinceReferenceDate]*1000.0); g_activeInstanceId = candidate->id; LogF("[FocusTick][mac] auto-activate id='%s' reason=soleVisible", candidate->id.c_str()); }
        }
      });
      dispatch_resume(s_visTimer);
    }
  }
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

// ====================== Native Find (macOS WKWebView) ======================
// Uses public API find:configuration:completionHandler: with WKFindConfiguration.
// Behavior approximates Windows implementation: n/N counter and navigation via Enter/buttons.
// Native highlight-all is not available – we supplement with JS highlight logic.

static void MacUpdateFindCounter(struct WebViewInstanceRecord* rec)
{
  if(!rec) return; if(rec->findCounterLabel){ int cur = rec->findCurrentIndex; int total = rec->findTotalMatches; rec->findCounterLabel.stringValue=[NSString stringWithFormat:@"%d/%d", (total>0?cur:0), total]; }
}

static void MacResetFindState(struct WebViewInstanceRecord* rec)
{
  if(!rec) return; rec->findCurrentIndex=0; rec->findTotalMatches=0; MacUpdateFindCounter(rec);
  // Remove current selection (visual reset) – safe via simple JS without altering structural DOM
  if(rec->webView){ [rec->webView evaluateJavaScript:@"window.getSelection && window.getSelection().removeAllRanges();" completionHandler:nil]; }
  // Remove all previously created highlight spans (span.__rwv_find)
  if(rec->webView){ [rec->webView evaluateJavaScript:@"(function(){ var xs=document.querySelectorAll('span.__rwv_find'); for(var i=0;i<xs.length;i++){ var s=xs[i]; var p=s.parentNode; while(s.firstChild) p.insertBefore(s.firstChild,s); p.removeChild(s);} })();" completionHandler:nil]; }
  rec->findLastHighlightedQuery.clear(); rec->findLastHighlightedCase=false;
}

// Full JS-based highlight of all matches (independent of native current match)
static void MacBuildHighlightAll(struct WebViewInstanceRecord* rec)
{
  if(!rec || !rec->webView) return; if(rec->findQuery.empty()){ return; }
  // Diagnostics: check body presence and text length
  [rec->webView evaluateJavaScript:@"(function(){ try { var b=document.body; if(!b) return 'NOBODY'; var t=b.innerText||b.textContent||''; return 'LEN:'+t.length; } catch(e){ return 'ERR:'+e; } })();" completionHandler:^(id r, NSError* e){ if(!e && [r isKindOfClass:[NSString class]]) { LogF("[Find][mac-fast] bodyCheck %s query='%s'", [(NSString*)r UTF8String], rec->findQuery.c_str()); } }];
  bool same = (rec->findLastHighlightedQuery == rec->findQuery && rec->findLastHighlightedCase == rec->findCaseSensitive);
  if(same){
    __block bool hasSpans = true;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [rec->webView evaluateJavaScript:@"(function(){return document.querySelectorAll('span.__rwv_find').length;})()" completionHandler:^(id r, NSError* e){
      if(e){ hasSpans=false; }
      else { long v=0; if([r isKindOfClass:[NSNumber class]]) v=[(NSNumber*)r longValue]; hasSpans=(v>0); }
      dispatch_semaphore_signal(sem);
    }];
    long wr = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 40*1000*1000));
    if(hasSpans && wr==0){ LogF("[Find][mac-fast] skip rebuild (same+spans) query='%s'", rec->findQuery.c_str()); return; }
    LogF("[Find][mac-fast] force rebuild (same query but spans missing) query='%s'", rec->findQuery.c_str());
  }
  LogF("[Find][mac-fast] start rebuild query='%s' case=%d prevQuery='%s'", rec->findQuery.c_str(), (int)rec->findCaseSensitive, rec->findLastHighlightedQuery.c_str());
  std::string prevQuery = rec->findLastHighlightedQuery; __block int prevIndex = rec->findCurrentIndex;
  // Быстрый helper внедряется один раз в документ (если не внедрён)
  NSString* inject = @"(function(){if(window.__rwvFind&&window.__rwvFind.version===4)return;window.__rwvFind={version:4,MAX_MATCHES:5000,clear:function(){var xs=document.querySelectorAll('span.__rwv_find');for(var i=0;i<xs.length;i++){var s=xs[i];var p=s.parentNode;while(s.firstChild)p.insertBefore(s.firstChild,s);p.removeChild(s);}},collect:function(){if(!document.body)return [];var w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT,null);var arr=[];while(w.nextNode()){var n=w.currentNode;if(!n||!n.nodeValue)continue;var pn=n.parentNode;if(!pn)continue;var tn=pn.nodeName; if(tn==='SCRIPT'||tn==='STYLE'||tn==='NOSCRIPT') continue;arr.push(n);}return arr;},fallbackCount:function(term,caseSensitive){try{if(!document.body)return 0;var cs=!!caseSensitive;var text=document.body.innerText||document.body.textContent||'';if(!cs){text=text.toLowerCase();term=term.toLowerCase();}var cnt=0,idx=0;while((idx=text.indexOf(term,idx))!==-1){cnt++;idx+=term.length||1;}return cnt;}catch(e){return -1;}},highlight:function(term,caseSensitive){if(!term){this.clear();return 0;}if(!document.body)return 0;this.clear();var cs=!!caseSensitive;var tRaw=term;var t=cs?term:term.toLowerCase();var nodes=this.collect();if(!nodes.length)return 0;var starts=new Array(nodes.length);var parts=new Array(nodes.length);var acc=0;for(var i=0;i<nodes.length;i++){starts[i]=acc;var d=nodes[i].data;parts[i]=d;acc+=d.length;}var big=parts.join('');var space=cs?big:big.toLowerCase();var matches=[];var step=t.length||1;var pos=0;while((pos=space.indexOf(t,pos))!==-1){matches.push(pos);pos+=step;if(matches.length>this.MAX_MATCHES)break;}var tooMany=matches.length>this.MAX_MATCHES; if(tooMany) matches.length=this.MAX_MATCHES; if(!matches.length) return 0;function findNode(p){var lo=0,hi=starts.length-1,res=0;while(lo<=hi){var mid=(lo+hi)>>1; if(starts[mid]<=p){res=mid;lo=mid+1;} else hi=mid-1;} return res;}var tLen=tRaw.length;for(var mi=matches.length-1;mi>=0;mi--){var gS=matches[mi];var gE=gS+tLen;var sIdx=findNode(gS);var eIdx=findNode(gE-1);var sN=nodes[sIdx];var eN=nodes[eIdx];if(!sN||!eN) continue;var sOff=gS - starts[sIdx];var eOff=gE - starts[eIdx]; if(eOff<0)eOff=0; if(eOff>eN.data.length)eOff=eN.data.length;try{var r=document.createRange();r.setStart(sN,sOff);r.setEnd(eN,eOff);var span=document.createElement('span');span.className='__rwv_find';span.style.background='rgba(255,230,128,0.9)';span.style.outline='1px solid rgba(255,180,0,0.4)';span.appendChild(r.extractContents());r.insertNode(span);}catch(ex){}}return tooMany?-2:matches.length;}}})();";
  [rec->webView evaluateJavaScript:inject completionHandler:nil];
  // Очистка старых + подсветка через helper
  std::string q = rec->findQuery; 
  // Расширенное экранирование для безопасности JS строки: \ " \n \r \t
  std::string esc; esc.reserve(q.size()*2);
  for(char c: q){
    switch(c){
      case '"': esc += "\\\""; break;
      case '\\': esc += "\\\\"; break;
      case '\n': esc += "\\n"; break;
      case '\r': esc += "\\r"; break;
      case '\t': esc += "\\t"; break;
      default: esc.push_back(c); break;
    }
  }
  // Оборачиваем в try/catch чтобы не получать generic JS Exception в NSError
  std::string call = std::string("(function(){ try { if(!window.__rwvFind) return 0; return window.__rwvFind.highlight(\"") + esc + "\"," + (rec->findCaseSensitive?"true":"false") + "); } catch(e){ console.error('[rwv.find] runtime error', e); return -1; } })();";
  NSString* njs = [NSString stringWithUTF8String:call.c_str()];
  [rec->webView evaluateJavaScript:njs completionHandler:^(id r, NSError* e){ 
    if(e){ 
      LogF("[Find][mac-fast] js-eval error: %s", e.localizedDescription.UTF8String); 
  // On error reset state to avoid desynchronization
      rec->findCurrentIndex = 0; rec->findTotalMatches=0; rec->findLastHighlightedQuery.clear(); rec->findLastHighlightedCase=false; 
      dispatch_async(dispatch_get_main_queue(), ^{ MacUpdateFindCounter(rec); });
      return; 
    }
    int mCount=0; 
    if([r isKindOfClass:[NSNumber class]]) mCount=[(NSNumber*)r intValue];
    if(mCount == -1){
      LogF("[Find][mac-fast] runtime exception inside highlight (query='%s')", rec->findQuery.c_str());
      rec->findCurrentIndex = 0; rec->findTotalMatches=0; rec->findLastHighlightedQuery.clear(); rec->findLastHighlightedCase=false; 
      dispatch_async(dispatch_get_main_queue(), ^{ MacUpdateFindCounter(rec); });
      return;
    }
    if(mCount == -2){
  // Too many matches: highlight truncated; fallback count for approximate total and user refinement
      NSString* fb2 = [NSString stringWithFormat:@"(function(){ try { if(!window.__rwvFind) return 'NO_HELPER'; return 'FB:'+window.__rwvFind.fallbackCount(\"%@\",%s); } catch(e){ return 'FBERR:'+e; } })();", [NSString stringWithUTF8String:esc.c_str()], rec->findCaseSensitive?"true":"false"];
      [rec->webView evaluateJavaScript:fb2 completionHandler:^(id fr, NSError* fe){ if(!fe && [fr isKindOfClass:[NSString class]]){ LogF("[Find][mac-fast] too-many matches (limited) %s query='%s'", [(NSString*)fr UTF8String], rec->findQuery.c_str()); }}];
      rec->findLastHighlightedQuery.clear(); rec->findLastHighlightedCase=false; mCount = 0; // treat as zero highlighted
    }
    if(mCount==0 && !rec->findQuery.empty()){
  // Fallback (diagnostic only): count occurrences without DOM modification to confirm existence
      NSString* fb = [NSString stringWithFormat:@"(function(){ try { if(!window.__rwvFind) return 'NO_HELPER'; return 'FB:'+window.__rwvFind.fallbackCount(\"%@\",%s); } catch(e){ return 'FBERR:'+e; } })();", [NSString stringWithUTF8String:esc.c_str()], rec->findCaseSensitive?"true":"false"];
      [rec->webView evaluateJavaScript:fb completionHandler:^(id fr, NSError* fe){ if(!fe && [fr isKindOfClass:[NSString class]]){ LogF("[Find][mac-fast] fallback diag %s query='%s'", [(NSString*)fr UTF8String], rec->findQuery.c_str()); }}];
  // Allow future rebuilds (do not cache zero-result state)
      rec->findLastHighlightedQuery.clear(); rec->findLastHighlightedCase=false; LogF("[Find][mac-fast] zero matches -> clear lastHighlighted to allow rebuild query='%s'", rec->findQuery.c_str());
    }
    if(prevQuery == rec->findQuery){ if(prevIndex<1) prevIndex=1; if(prevIndex>mCount) prevIndex=mCount; rec->findCurrentIndex = mCount?prevIndex:0; }
    else { rec->findCurrentIndex = mCount>0?1:0; }
    rec->findTotalMatches=mCount; rec->findLastHighlightedQuery=rec->findQuery; rec->findLastHighlightedCase=rec->findCaseSensitive; int cur = rec->findCurrentIndex; size_t qlen = rec->findQuery.size();
    dispatch_async(dispatch_get_main_queue(), ^{ 
      MacUpdateFindCounter(rec); 
      LogF("[Find][mac-fast] rebuilt query='%s' len=%zu total=%d cur=%d", rec->findQuery.c_str(), qlen, mCount, cur);
      if(rec && rec->webView && cur>=1 && mCount>0){
        NSString* selJs = [NSString stringWithFormat:@"(function(){var L=document.querySelectorAll('span.__rwv_find'); for(var i=0;i<L.length;i++){L[i].classList.remove('__rwv_find_current'); L[i].style.background='rgba(255,230,128,0.9)'; L[i].style.outline='1px solid rgba(255,180,0,0.4)';} var i=%d; if(i>=1 && i<=L.length){var el=L[i-1]; el.classList.add('__rwv_find_current'); el.style.background='rgba(255,150,0,0.95)'; el.style.outline='2px solid rgba(255,90,0,0.9)'; el.scrollIntoView({block:'center'});} })();", cur];
        [rec->webView evaluateJavaScript:selJs completionHandler:nil];
      }
    }); 
  }];
}

extern "C" void MacFindStartOrUpdate(struct WebViewInstanceRecord* rec)
{
  if(!rec || !rec->webView) return; std::string q = rec->findQuery; if(q.empty()){ LogRaw("[Find][mac-native] empty query -> reset"); MacResetFindState(rec); return; }
  // Полностью JS: highlight + подсчёт
  MacBuildHighlightAll(rec);
}

extern "C" void MacFindNavigate(struct WebViewInstanceRecord* rec, bool forward)
{
  if(!rec || !rec->webView) return; if(rec->findQuery.empty()){ MacResetFindState(rec); return; }
  WKWebView* wv = rec->webView; // no rebuild here; navigation only
  LogF("[Find][mac-native] nav %s query='%s'", forward?"forward":"backward", rec->findQuery.c_str());
  // Simple cyclic navigation without native matchIndex: use local counters
  if(rec->findTotalMatches<=0){ MacFindStartOrUpdate(rec); return; }
  if(forward){ if(rec->findCurrentIndex < rec->findTotalMatches) rec->findCurrentIndex++; else rec->findCurrentIndex=1; }
  else { if(rec->findCurrentIndex>1) rec->findCurrentIndex--; else rec->findCurrentIndex=rec->findTotalMatches; }
  MacUpdateFindCounter(rec);
  int idx = rec->findCurrentIndex;
  // Update current highlight: apply __rwv_find_current class
  NSString* js = [NSString stringWithFormat:@"(function(){var L=document.querySelectorAll('span.__rwv_find'); for(var i=0;i<L.length;i++){L[i].classList.remove('__rwv_find_current'); L[i].style.background='rgba(255,230,128,0.9)'; L[i].style.outline='1px solid rgba(255,180,0,0.4)';} var i=%d; if(i>=1 && i<=L.length){var el=L[i-1]; el.classList.add('__rwv_find_current'); el.style.background='rgba(255,150,0,0.95)'; el.style.outline='2px solid rgba(255,90,0,0.9)'; el.scrollIntoView({block:'center'});} })();", idx];
  [wv evaluateJavaScript:js completionHandler:nil];
}

extern "C" void MacFindClose(struct WebViewInstanceRecord* rec)
{
  LogRaw("[Find][mac-native] close/reset"); MacResetFindState(rec);
}


#endif // __APPLE__
