// Reaper WebView Plugin
// (c) Andrew "SadFrozz" Brodsky
// 2025 and later
// main.mm
// Notes:
//  - Legacy global g_dlg removed; all window handles resolved via instance records (GetInstanceById / GetInstanceByHwnd).
//  - Persistence stubs SaveInstanceStateAll/LoadInstanceStateAll currently just log state (no disk IO).

// init section

#define RWV_WITH_WEBVIEW2 1
// Request GetThemeColor symbol from REAPER API
#define REAPERAPI_WANT_GetThemeColor
#define REAPERAPI_WANT_GetColorThemeStruct
#ifndef REAPERAPI_IMPLEMENT
#define REAPERAPI_IMPLEMENT
#endif
#include "predef.h"

// ============================== Build-time logging ==============================
#include "log.h"

// ==================== include Globals and helpers ====================

#include "api.h"
#include "globals.h"   // extern-глобалы/прототипы
#include "helpers.h"

// ======================== Title panel (creation + logic stays here) =========================
#ifdef _WIN32
// Forward declarations (creation logic in this TU; layout needs external linkage)
static void DestroyTitleBarResources(WebViewInstanceRecord* rec);
static void EnsureTitleBarCreated(HWND hwnd);
void LayoutTitleBarAndWebView(HWND hwnd, bool titleVisible); // exported across TUs
static void SetTitleBarText(HWND hwnd, const std::string& s);
static LRESULT CALLBACK RWVTitleBarProc(HWND h, UINT m, WPARAM w, LPARAM l);
static void DestroyTitleBarResources(WebViewInstanceRecord* rec)
{
  if (!rec) return; if (rec->titleFont){ DeleteObject(rec->titleFont); rec->titleFont=nullptr;} if (rec->titleBrush){ DeleteObject(rec->titleBrush); rec->titleBrush=nullptr;} if (rec->titleBar && IsWindow(rec->titleBar)){ DestroyWindow(rec->titleBar); rec->titleBar=nullptr; }
}

static LRESULT CALLBACK RWVTitleBarProc(HWND h, UINT m, WPARAM w, LPARAM l)
{
  switch(m){
    case WM_NCCREATE: return 1;
    case WM_SETTEXT: InvalidateRect(h,nullptr,FALSE); break;
    case WM_PAINT:
    {
      PAINTSTRUCT ps; HDC dc=BeginPaint(h,&ps); RECT r; GetClientRect(h,&r);
      WebViewInstanceRecord* rec = GetInstanceByHwnd(GetParent(h));
      COLORREF bk, tx; GetPanelThemeColors(h, dc, &bk, &tx);
      if (rec){ if (rec->titleBkColor!=bk){ rec->titleBkColor=bk; if(rec->titleBrush){ DeleteObject(rec->titleBrush); rec->titleBrush=nullptr; }} rec->titleTextColor=tx; if(!rec->titleBrush) rec->titleBrush=CreateSolidBrush(bk);} 
      HBRUSH fill = (rec && rec->titleBrush)?rec->titleBrush:(HBRUSH)(COLOR_BTNFACE+1);
      FillRect(dc,&r,fill); SetBkMode(dc,TRANSPARENT); SetTextColor(dc,tx);
      WCHAR buf[512]; GetWindowTextW(h,buf,512); RECT tr=r; tr.left+=g_titlePadX; DrawTextW(dc,buf,-1,&tr,DT_SINGLELINE|DT_VCENTER|DT_LEFT|DT_NOPREFIX|DT_END_ELLIPSIS);
      EndPaint(h,&ps); return 0;
    }
  }
  return DefWindowProcW(h,m,w,l);
}

static void EnsureTitleBarCreated(HWND hwnd)
{
  WebViewInstanceRecord* rec = GetInstanceByHwnd(hwnd); if(!rec) return; if (rec->titleBar && !IsWindow(rec->titleBar)) rec->titleBar=nullptr; if(rec->titleBar) return;
  static bool s_reg=false; if(!s_reg){ WNDCLASSW wc{}; wc.lpfnWndProc=RWVTitleBarProc; wc.hInstance=(HINSTANCE)g_hInst; wc.lpszClassName=L"RWVTitleBar"; wc.hCursor=LoadCursor(nullptr,IDC_ARROW); wc.hbrBackground=NULL; RegisterClassW(&wc); s_reg=true; }
  LOGFONTW lf{}; SystemParametersInfoW(SPI_GETICONTITLELOGFONT,sizeof(lf),&lf,0); lf.lfHeight=-12; lf.lfWeight=FW_SEMIBOLD; rec->titleFont=CreateFontIndirectW(&lf);
  rec->titleBar = CreateWindowExW(0,L"RWVTitleBar",L"",WS_CHILD,0,0,10,g_titleBarH,hwnd,(HMENU)(INT_PTR)IDC_TITLEBAR,(HINSTANCE)g_hInst,nullptr);
  if(rec->titleBar && rec->titleFont) SendMessageW(rec->titleBar,WM_SETFONT,(WPARAM)rec->titleFont,TRUE);
}

void LayoutTitleBarAndWebView(HWND hwnd, bool titleVisible)
{
  RECT rc; GetClientRect(hwnd,&rc); int top=0; WebViewInstanceRecord* rec=GetInstanceByHwnd(hwnd);
  if(titleVisible && rec && rec->titleBar){ MoveWindow(rec->titleBar,0,0,(rc.right-rc.left),g_titleBarH,TRUE); ShowWindow(rec->titleBar,SW_SHOWNA); top=g_titleBarH; }
  else if(rec && rec->titleBar) ShowWindow(rec->titleBar,SW_HIDE);
  RECT brc=rc; brc.top+=top; if(rec && rec->controller) rec->controller->put_Bounds(brc);
}
static void SetTitleBarText(HWND hwnd, const std::string& s){ WebViewInstanceRecord* rec=GetInstanceByHwnd(hwnd); if(rec && rec->titleBar) SetWindowTextW(rec->titleBar,Widen(s).c_str()); }
#else
static void DestroyTitleBarResources(WebViewInstanceRecord* rec)
{ if(!rec) return; if(rec->titleLabel){ [rec->titleLabel removeFromSuperview]; rec->titleLabel=nil;} if(rec->titleBarView){ [rec->titleBarView removeFromSuperview]; rec->titleBarView=nil;} }

static void EnsureTitleBarCreated(HWND hwnd)
{
  WebViewInstanceRecord* rec=GetInstanceByHwnd(hwnd); if(!rec) return; if(rec->titleBarView) return; NSView* host=(NSView*)hwnd; if(!host) return;
  rec->titleBarView=[[NSView alloc] initWithFrame:NSMakeRect(0,0, host.bounds.size.width, g_titleBarH)];
  rec->titleLabel=[[NSTextField alloc] initWithFrame:NSMakeRect(g_titlePadX,2, host.bounds.size.width-2*g_titlePadX, g_titleBarH-4)];
  [rec->titleLabel setEditable:NO]; [rec->titleLabel setBordered:NO]; [rec->titleLabel setBezeled:NO]; [rec->titleLabel setDrawsBackground:YES];
  int bg=-1, tx=-1; GetPanelThemeColorsMac(&bg,&tx);
  auto colorFrom = ^NSColor*(int v){ if(v<0) return (NSColor*)nil; CGFloat r=((v>>16)&0xFF)/255.0,g=((v>>8)&0xFF)/255.0,b=(v&0xFF)/255.0; return [NSColor colorWithCalibratedRed:r green:g blue:b alpha:1.0]; };
  NSColor* bgC = colorFrom(bg); NSColor* txC = colorFrom(tx);
  [rec->titleLabel setBackgroundColor:bgC?bgC:[NSColor controlBackgroundColor]];
  [rec->titleLabel setTextColor:txC?txC:[NSColor controlTextColor]];
  [rec->titleLabel setFont:[NSFont systemFontOfSize:[NSFont systemFontSize]]];
  [rec->titleBarView addSubview:rec->titleLabel]; [host addSubview:rec->titleBarView]; [rec->titleBarView setHidden:YES];
}

void LayoutTitleBarAndWebView(HWND hwnd, bool titleVisible)
{
  NSView* host=(NSView*)hwnd; if(!host) return; WebViewInstanceRecord* rec=GetInstanceByHwnd(hwnd); CGFloat top=0;
  if(titleVisible && rec && rec->titleBarView){ [rec->titleBarView setFrame:NSMakeRect(0,0, host.bounds.size.width, g_titleBarH)]; [rec->titleLabel setFrame:NSMakeRect(g_titlePadX,2, host.bounds.size.width-2*g_titlePadX, g_titleBarH-4)]; [rec->titleBarView setHidden:NO]; top=g_titleBarH; }
  else if(rec && rec->titleBarView) [rec->titleBarView setHidden:YES];
  if(rec && rec->webView){ NSRect b=NSMakeRect(0, top, host.bounds.size.width, host.bounds.size.height-top); [rec->webView setFrame:b]; }
}
static void SetTitleBarText(HWND hwnd, const std::string& s){ WebViewInstanceRecord* rec=GetInstanceByHwnd(hwnd); if(!rec||!rec->titleLabel) return; NSString* t=[NSString stringWithUTF8String:s.c_str()]; [rec->titleLabel setStringValue:t?t:@""]; }
#endif

// показать/скрыть панель + текст
static void UpdateTitleBarUI(HWND hwnd, const std::string& domain, const std::string& pageTitle, const std::string& effectiveTitle,
                             bool inDock, bool finalPanelVisible, ShowPanelMode mode)
{
  EnsureTitleBarCreated(hwnd);
  const bool wantVisible = finalPanelVisible; // уже рассчитано выше с учётом режима
  // Формирование текста панели:
  // Требование: панель НИКОГДА не показывает кастомный (override) заголовок.
  // Всегда используется fallback: домен [+ " - " + pageTitle].
  // (Кастомный заголовок по-прежнему может использоваться для таба докера или окна, но не для панели.)
  std::string panelText = domain.empty() ? "…" : domain;
  if (!pageTitle.empty()) panelText += " - " + pageTitle;
  SetTitleBarText(hwnd, panelText);
  LayoutTitleBarAndWebView(hwnd, wantVisible);
  LogF("[Panel] inDock=%d mode=%d visible=%d title='%s' (fallback only)", (int)inDock, (int)mode, (int)wantVisible, panelText.c_str());
}

// ============================== Titles (common) ==============================
void UpdateTitlesExtractAndApply(HWND hwnd)
{
  // Выбор текущей записи инстанса (active id определяется по hwnd -> ищем запись с таким hwnd)
    WebViewInstanceRecord* rec = GetInstanceByHwnd(hwnd);
  if (!rec) { // fallback на активный id
    rec = GetInstanceById(g_instanceId.empty()?std::string("wv_default"):g_instanceId);
  }
  if (!rec) rec = GetInstanceById(std::string("wv_default"));
  const std::string effectiveTitle = (rec && !rec->titleOverride.empty()) ? rec->titleOverride : kTitleBase;
  const ShowPanelMode effectivePanelMode = rec ? rec->panelMode : ShowPanelMode::Unset;
  std::string domain, pageTitle;

  #ifdef _WIN32
  if (rec && rec->webview)
    {
      wil::unique_cotaskmem_string wsrc, wtitle;
  if (SUCCEEDED(rec->webview->get_Source(&wsrc))  && wsrc)  domain    = ExtractDomainFromUrl(Narrow(std::wstring(wsrc.get())));
  if (SUCCEEDED(rec->webview->get_DocumentTitle(&wtitle)) && wtitle) pageTitle = Narrow(std::wstring(wtitle.get()));
    }
  #else
    if (rec && rec->webView)
    {
      NSURL* u = rec->webView.URL; if (u) domain = ExtractDomainFromUrl([[u absoluteString] UTF8String]);
      NSString* t = rec->webView.title; if (t) pageTitle = [t UTF8String];
    }
  #endif

  SaveDockState(hwnd);
  const bool inDock = (g_last_dock_idx >= 0);

  const bool defaultMode = (effectiveTitle.empty() || effectiveTitle == kTitleBase);

  auto panelVisible = [&](bool inDockLocal, bool defaultTitle){
  // ShowPanel per-instance: Unset, Hide, Docker, Always
  switch (effectivePanelMode)
    {
      case ShowPanelMode::Hide:   return false;
      case ShowPanelMode::Docker: return inDockLocal; // только в докере
      case ShowPanelMode::Always: return true;        // всегда
      case ShowPanelMode::Unset:  default:            return defaultTitle && inDockLocal; // старое поведение
    }
  };

  if (defaultMode)
  {
    if (inDock)
    {
      const std::string tabCaption = kTitleBase;
      WebViewInstanceRecord* rLocal = GetInstanceByHwnd(hwnd);
      if (rLocal && rLocal->lastTabTitle != tabCaption) {
        LogF("[TabTitle] in-dock (idx=%d float=%d) -> '%s'", g_last_dock_idx, (int)g_last_dock_float, tabCaption.c_str());
      }
      SetTabTitleInplace(hwnd, tabCaption);
  UpdateTitleBarUI(hwnd, domain, pageTitle, effectiveTitle, true, panelVisible(true, true), effectivePanelMode);
    }
    else
    {
      std::string wndCaption = domain.empty() ? "…" : domain;
      if (!pageTitle.empty()) wndCaption += " - " + pageTitle;
  SetWndText(hwnd, wndCaption);
  UpdateTitleBarUI(hwnd, domain, pageTitle, effectiveTitle, false, panelVisible(false, true), effectivePanelMode);
      LogF("[TitleUpdate] undock caption='%s'", wndCaption.c_str());
    }
  }
  else
  {
    if (inDock)
    {
      WebViewInstanceRecord* rLocal = GetInstanceByHwnd(hwnd);
      if (rLocal && rLocal->lastTabTitle != effectiveTitle) {
        LogF("[TabTitle] in-dock custom -> '%s' (last='%s')", effectiveTitle.c_str(), rLocal->lastTabTitle.c_str());
        // Принудительный редок: некоторые версии REAPER не обновляют вкладку корректно только через SetWindowText
        if (DockWindowRemove && DockWindowAddEx) {
          DockWindowRemove(hwnd);
          DockWindowAddEx(hwnd, effectiveTitle.c_str(), kDockIdent, true);
          if (DockWindowActivate) DockWindowActivate(hwnd);
          if (DockWindowRefreshForHWND) DockWindowRefreshForHWND(hwnd);
          if (DockWindowRefresh) DockWindowRefresh();
        }
      }
      SetTabTitleInplace(hwnd, effectiveTitle);
  UpdateTitleBarUI(hwnd, domain, pageTitle, effectiveTitle, true, panelVisible(true, false), effectivePanelMode);
    }
    else
    {
  SetWndText(hwnd, effectiveTitle);
  UpdateTitleBarUI(hwnd, domain, pageTitle, effectiveTitle, false, panelVisible(false, false), effectivePanelMode);
    LogF("[TitleUpdate] undock custom='%s'", effectiveTitle.c_str());
    }
  }

  // Retrofit: если мы в доке, есть кастомный effectiveTitle, но вкладка осталась базовой, попробуем пере-регистрировать.
  if (inDock && !defaultMode && rec && rec->lastTabTitle == kTitleBase && effectiveTitle != kTitleBase) {
    LogF("[DockRetrofitCheck] tab still '%s' want '%s' -> re-add", rec->lastTabTitle.c_str(), effectiveTitle.c_str());
    if (DockWindowRemove && DockWindowAddEx) {
      DockWindowRemove(hwnd);
      DockWindowAddEx(hwnd, effectiveTitle.c_str(), kDockIdent, true);
      if (DockWindowActivate) DockWindowActivate(hwnd);
      if (DockWindowRefreshForHWND) DockWindowRefreshForHWND(hwnd);
      if (DockWindowRefresh) DockWindowRefresh();
      // Обновим заголовок ещё раз сразу
      SetTabTitleInplace(hwnd, effectiveTitle);
    }
  }
}

// ============================== dlg/docker ==============================
#ifndef _WIN32
#define IDD_WEBVIEW 2001
  SWELL_DEFINE_DIALOG_RESOURCE_BEGIN(
    IDD_WEBVIEW,
    WS_CAPTION|WS_THICKFRAME|WS_SYSMENU|WS_CLIPCHILDREN|WS_CLIPSIBLINGS,
    "WebView",
    900, 600, 1.0
  )
    { "", -1, "customcontrol", WS_CHILD|WS_VISIBLE, 0, 0, 300, 200, 0 }
  SWELL_DEFINE_DIALOG_RESOURCE_END(IDD_WEBVIEW)
#endif

static void SizeWebViewToClient(HWND hwnd)
{
  bool isFloat=false; int idx=-1;
  bool inDock = DockIsChildOfDock ? (DockIsChildOfDock(hwnd, &isFloat) >= 0) : false;
  // derive per-instance title
  bool wantPanel=false;
  if (inDock) {
        WebViewInstanceRecord* rec = GetInstanceByHwnd(hwnd);
    std::string t = rec ? rec->titleOverride : kTitleBase;
    if (t.empty()) t = kTitleBase;
    wantPanel = (t == kTitleBase);
  }
  LayoutTitleBarAndWebView(hwnd, wantPanel);
}

// ============================== WebView init ==============================
#ifndef WEBVIEWINITIALIZED
  #define WEBVIEWINITIALIZED
  #include "webview.h"
#endif

// ============================== контекстное меню дока ==============================
static inline int GET_LP_X(LPARAM lp) { return (int)(short)LOWORD(lp); }
static inline int GET_LP_Y(LPARAM lp) { return (int)(short)HIWORD(lp); }

static bool QueryDockState(HWND hwnd, bool* outFloat, int* outIdx)
{
  bool f=false; int i=-1; if (!outFloat) outFloat=&f; if (!outIdx) outIdx=&i;
  HWND cand[3] = { hwnd, GetParent(hwnd), GetAncestor(hwnd, GA_ROOT) };
  for (int k=0;k<3;k++)
  {
    HWND h=cand[k]; if(!h) continue;
    bool ff=false; int ii = DockIsChildOfDock ? DockIsChildOfDock(h,&ff) : -1;
    LogF("[DockQuery] cand=%p -> idx=%d float=%d", (void*)h, ii, (int)ff);
    if (ii>=0){ *outFloat=ff; *outIdx=ii; return true; }
  }
  *outFloat=false; *outIdx=-1;
  return false;
}

static void RememberWantDock(HWND hwnd)
{
  // Use same multi-candidate detection logic as SaveDockState to avoid false positives/negatives
  bool detected=false; bool isFloat=false; int idx=-1;
  HWND cand[3] = { hwnd, GetParent(hwnd), GetAncestor(hwnd, GA_ROOT) };
  for (int k=0;k<3;k++)
  {
    HWND h = cand[k]; if(!h) continue;
    bool f=false; int i = DockIsChildOfDock ? DockIsChildOfDock(h,&f) : -1;
    LogF("[DockRememberProbe] cand=%p -> idx=%d float=%d", (void*)h, i, (int)f);
    if (i>=0) { detected=true; isFloat=f; idx=i; break; }
  }
  g_want_dock_on_create = detected ? 1 : 0;
  // persist into instance record
  WebViewInstanceRecord* rec = GetInstanceById(g_instanceId.empty()?std::string("wv_default"):g_instanceId);
  if (rec) {
    rec->wantDockOnCreate = g_want_dock_on_create;
    if (detected) { rec->lastDockIdx = idx; rec->lastDockFloat = isFloat; }
  }
  LogF("[DockRemember] stored want_dock=%d (detected=%d idx=%d float=%d inst=%s)", g_want_dock_on_create, (int)detected, idx, (int)isFloat, rec?rec->id.c_str():"<none>");
}

static void ShowLocalDockMenu(HWND hwnd, int x, int y)
{
  HMENU m = CreatePopupMenu(); if (!m) return;
  bool f=false; int idx=-1; bool inDock = QueryDockState(hwnd,&f,&idx);

  WebViewInstanceRecord* rec = GetInstanceByHwnd(hwnd);
  const bool basicOnly = rec && rec->basicCtxMenu;

  if (!basicOnly) {
    // Reload / Back / Forward / Find stub
    AppendMenuA(m, MF_STRING, 10110, "Reload");
    // Forward / Back availability: attempt to query webview capabilities (platform-specific)
#ifdef _WIN32
    bool canBack=false, canFwd=false;
    if (rec && rec->webview) {
      wil::com_ptr<ICoreWebView2_2> wv2;
      if (SUCCEEDED(rec->webview->QueryInterface(IID_PPV_ARGS(&wv2))) && wv2) {
        BOOL cb=FALSE, cf=FALSE; wv2->get_CanGoBack(&cb); wv2->get_CanGoForward(&cf); canBack = cb; canFwd = cf; }
    }
#else
    bool canBack = (rec && rec->webView && rec->webView.canGoBack);
    bool canFwd  = (rec && rec->webView && rec->webView.canGoForward);
#endif
    AppendMenuA(m, MF_STRING | (canBack?0:MF_DISABLED|MF_GRAYED),   10111, "Back");
    AppendMenuA(m, MF_STRING | (canFwd?0:MF_DISABLED|MF_GRAYED),    10112, "Forward");
    AppendMenuA(m, MF_SEPARATOR, 0, NULL);
    AppendMenuA(m, MF_STRING, 10113, "Find on page (stub)");
    AppendMenuA(m, MF_SEPARATOR, 0, NULL);
  }

  AppendMenuA(m, MF_STRING | (inDock?MF_CHECKED:0), 10001, inDock ? "Undock window" : "Dock window in Docker");
  AppendMenuA(m, MF_SEPARATOR, 0, NULL);
  AppendMenuA(m, MF_STRING, 10099, "Close");

  HWND owner = GetAncestor(hwnd, GA_ROOT); if (!owner) owner = hwnd;
  SetForegroundWindow(owner);
  int cmd = TrackPopupMenu(m, TPM_RIGHTBUTTON|TPM_RETURNCMD|TPM_NONOTIFY, x, y, 0, owner, NULL);
  DestroyMenu(m);
  if (!cmd) return;

  if (cmd == 10001) {
    bool nowFloat=false; int nowIdx=-1;
    const bool nowDock = QueryDockState(hwnd,&nowFloat,&nowIdx);

    if (nowDock) {
      LogRaw("[Undock] Removing from dock...");
      if (DockWindowRemove) DockWindowRemove(hwnd); PlatformMakeTopLevel(hwnd);
    } else {
      LogRaw("[Dock] Adding to dock...");
      if (DockWindowAddEx) {
        WebViewInstanceRecord* recC = GetInstanceByHwnd(hwnd);
        const char* initTitle = kTitleBase;
        if (recC && !recC->titleOverride.empty() && recC->titleOverride != kTitleBase)
          initTitle = recC->titleOverride.c_str();
        DockWindowAddEx(hwnd, initTitle, kDockIdent, true);
      }
      if (DockWindowActivate) DockWindowActivate(hwnd);
    }
    UpdateTitlesExtractAndApply(hwnd);
  }
  else if (cmd == 10110) { // Reload
    WebViewInstanceRecord* r = GetInstanceByHwnd(hwnd);
#ifdef _WIN32
    if (r && r->webview) r->webview->Reload();
#else
    if (r && r->webView) [r->webView reload];
#endif
  }
  else if (cmd == 10111) { // Back
    WebViewInstanceRecord* r = GetInstanceByHwnd(hwnd);
#ifdef _WIN32
    if (r && r->webview) { wil::com_ptr<ICoreWebView2_2> wv2; if (SUCCEEDED(r->webview->QueryInterface(IID_PPV_ARGS(&wv2))) && wv2) { BOOL cb=FALSE; wv2->get_CanGoBack(&cb); if (cb) wv2->GoBack(); } }
#else
    if (r && r->webView && r->webView.canGoBack) [r->webView goBack];
#endif
  }
  else if (cmd == 10112) { // Forward
    WebViewInstanceRecord* r = GetInstanceByHwnd(hwnd);
#ifdef _WIN32
    if (r && r->webview) { wil::com_ptr<ICoreWebView2_2> wv2; if (SUCCEEDED(r->webview->QueryInterface(IID_PPV_ARGS(&wv2))) && wv2) { BOOL cf=FALSE; wv2->get_CanGoForward(&cf); if (cf) wv2->GoForward(); } }
#else
    if (r && r->webView && r->webView.canGoForward) [r->webView goForward];
#endif
  }
  else if (cmd == 10113) {
    LogRaw("[FindStub] Find on page invoked (not implemented)");
  }
  else if (cmd == 10099) SendMessage(hwnd, WM_CLOSE, 0, 0);
}

// ============================== dlg proc ==============================
static INT_PTR WINAPI WebViewDlgProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
  switch (msg)
  {
    case WM_INITDIALOG:
    {
      char* initial = (char*)lp;
      std::string url = (initial && *initial) ? std::string(initial) : std::string(kDefaultURL);
      if (initial) free(initial);

      EnsureTitleBarCreated(hwnd);
      LayoutTitleBarAndWebView(hwnd, false);

      bool isFloat=false; int idx=-1; (void)QueryDockState(hwnd, &isFloat, &idx);
      LogF("[DockInit] g_want_dock_on_create=%d (idx=%d float=%d)", g_want_dock_on_create, idx, (int)isFloat);
      WebViewInstanceRecord* recInit = GetInstanceById(g_instanceId.empty()?std::string("wv_default"):g_instanceId);
      if (recInit && recInit->wantDockOnCreate >= 0) g_want_dock_on_create = recInit->wantDockOnCreate; // sync from instance
      const bool wantDock = (g_want_dock_on_create == 1) || (g_want_dock_on_create < 0);
      if (wantDock && DockWindowAddEx) {
        const char* initTitle = kTitleBase;
        if (recInit && !recInit->titleOverride.empty() && recInit->titleOverride != kTitleBase)
          initTitle = recInit->titleOverride.c_str();
        DockWindowAddEx(hwnd, initTitle, kDockIdent, true);
        if (DockWindowActivate) DockWindowActivate(hwnd);
        if (DockWindowRefreshForHWND) DockWindowRefreshForHWND(hwnd);
        if (DockWindowRefresh) DockWindowRefresh();
      } else {
        PlatformMakeTopLevel(hwnd);
      }
      if (recInit) {
        recInit->hwnd = hwnd; // bind window to instance (single-window model for now)
        if (recInit->wantDockOnCreate < 0) recInit->wantDockOnCreate = wantDock?1:0; // initialize inheritance
      }

      SaveDockState(hwnd);

      StartWebView(hwnd, url);
      UpdateTitlesExtractAndApply(hwnd);
      return 1;
    }

    // WM_CTLCOLORSTATIC no longer needed; custom class repaints itself.

    case WM_SIZE:
      SizeWebViewToClient(hwnd);
      return 0;

    case WM_SWELL_POST_UNDOCK_FIXSTYLE:
    {
    #ifndef _WIN32
      NSView* host = (NSView*)hwnd;
      NSWindow* win = [host window];
      if (win)
      {
        LogRaw("[POST_UNDOCK_FIXSTYLE] Applying resizable style mask.");
        NSUInteger currentStyleMask = [win styleMask];
        [win setStyleMask: currentStyleMask | NSWindowStyleMaskResizable];
      }
    #endif
      return 0;
    }

    case WM_CONTEXTMENU:
    {
      int x = (int)(short)LOWORD(lp), y = (int)(short)HIWORD(lp);
      if (x == -1 && y == -1) { RECT r{}; GetWindowRect(hwnd, &r); x=(r.left+r.right)/2; y=(r.top+r.bottom)/2; }
      ShowLocalDockMenu(hwnd, x, y);
      return 0;
    }

    case WM_COMMAND:
      switch (LOWORD(wp))
      {
        case IDOK:
        case IDCANCEL:
          SendMessage(hwnd, WM_CLOSE, 0, 0);
          return 0;
      }
      return 0; // other commands not handled

    case WM_CLOSE:
      LogRaw("[WM_CLOSE]");
      RememberWantDock(hwnd);
      // Очистить ссылки в записи инстанса
      for (auto &kv : g_instances) {
        if (kv.second && kv.second->hwnd == hwnd) {
          kv.second->hwnd = nullptr;
#ifdef _WIN32
          if (kv.second->controller) { kv.second->controller->Release(); kv.second->controller = nullptr; }
          if (kv.second->webview)    { kv.second->webview->Release();    kv.second->webview = nullptr; }
#else
          kv.second->webView = nil;
#endif
          LogF("[InstanceCleanup] id='%s' cleared on WM_CLOSE", kv.first.c_str());
          break;
        }
      }
      PurgeDeadInstances();
      { bool f=false; int idx=-1; bool id = DockIsChildOfDock ? (DockIsChildOfDock(hwnd,&f) >= 0) : false; if (id && DockWindowRemove) DockWindowRemove(hwnd); }
      DestroyWindow(hwnd);
      return 0;

    case WM_DESTROY:
      LogRaw("[WM_DESTROY]");
    case WM_TIMER:
      // (таймеры для повторного обновления заголовка удалены как лишняя нагрузка)
      break;
#ifdef _WIN32
      for (auto &kv : g_instances) {
        if (kv.second && kv.second->hwnd == hwnd) {
          kv.second->hwnd = nullptr; 
          if (kv.second->controller) { kv.second->controller->Release(); kv.second->controller = nullptr; }
          if (kv.second->webview)    { kv.second->webview->Release();    kv.second->webview = nullptr; }
          LogF("[InstanceCleanup] id='%s' cleared on WM_DESTROY", kv.first.c_str());
        }
      }
      PurgeDeadInstances();
#else
      for (auto &kv : g_instances) {
        if (kv.second && kv.second->hwnd == hwnd) {
          kv.second->hwnd = nullptr; kv.second->webView = nil;
          LogF("[InstanceCleanup] id='%s' cleared on WM_DESTROY", kv.first.c_str());
        }
      }
#endif
    #ifdef _WIN32
  DestroyTitleBarResources(GetInstanceByHwnd(hwnd));
      if (g_hWebView2Loader) { FreeLibrary(g_hWebView2Loader); g_hWebView2Loader = nullptr; }
      if (g_com_initialized) { CoUninitialize(); g_com_initialized = false; }
    #else
  DestroyTitleBarResources(GetInstanceByHwnd(hwnd));
    #endif
      return 0;
  }
  return 0;
}

// ============================== window creation helper ==============================
static HWND CreateNewWebViewWindow(const std::string& url)
{
#ifdef _WIN32
  struct MyDLGTEMPLATE : DLGTEMPLATE { WORD ext[3]; MyDLGTEMPLATE(){ memset(this,0,sizeof(*this)); } } t;
  t.style = DS_SETFONT | DS_FIXEDSYS | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_CLIPCHILDREN;
  t.cx = 900; t.cy = 600; t.dwExtendedStyle = 0;
  char* urlParam = _strdup(url.c_str());
  HWND hwnd = CreateDialogIndirectParam((HINSTANCE)g_hInst, &t, g_hwndParent, (DLGPROC)WebViewDlgProc, (LPARAM)urlParam);
#else
  char* urlParam = strdup(url.c_str());
  HWND hwnd = CreateDialogParam((HINSTANCE)g_hInst, MAKEINTRESOURCE(IDD_WEBVIEW), g_hwndParent, WebViewDlgProc, (LPARAM)urlParam);
#endif
  if (hwnd && IsWindow(hwnd)) {
    bool floating=false; int dockId = DockIsChildOfDock ? DockIsChildOfDock(hwnd,&floating) : -1;
    if (dockId >= 0) {
      if (DockWindowActivate) DockWindowActivate(hwnd);
    } else {
      PlatformMakeTopLevel(hwnd);
    }
  }
  return hwnd;
}

// ============================== per-instance open/activate ==============================
void OpenOrActivateInstance(const std::string& instanceId, const std::string& url)
{
  WebViewInstanceRecord* rec = GetInstanceById(instanceId);
  if (!rec) {
    LogF("[InstanceOpen] unknown id '%s' (creating via EnsureInstance...)", instanceId.c_str());
    rec = EnsureInstanceAndMaybeNavigate(instanceId, url, false, std::string(), ShowPanelMode::Unset);
  }
  if (!rec) return;
  LogF("[InstanceOpen] id='%s' hwnd=%p wantDock=%d url='%s'", instanceId.c_str(), (void*)rec->hwnd, rec->wantDockOnCreate, url.c_str());

  // If this rec already has its own hwnd, just activate it
  if (rec->hwnd && IsWindow(rec->hwnd)) {
    g_instanceId = instanceId; // switch active context (still used by StartWebView callbacks)
    if (!url.empty()) NavigateExistingInstance(instanceId, url);
    else if (!rec->lastUrl.empty()) LogF("[InstanceActivate] id='%s' reuse lastUrl='%s'", instanceId.c_str(), rec->lastUrl.c_str());
    bool floating=false; int dockId = DockIsChildOfDock ? DockIsChildOfDock(rec->hwnd,&floating) : -1;
    if (dockId >= 0) { if (DockWindowActivate) DockWindowActivate(rec->hwnd); }
    else PlatformMakeTopLevel(rec->hwnd);
    UpdateTitlesExtractAndApply(rec->hwnd);
    return;
  }

  // Create new window for this instance
  g_instanceId = instanceId; // set before creation so StartWebView associates controller correctly
  if (rec->wantDockOnCreate >= 0) g_want_dock_on_create = rec->wantDockOnCreate; // supply hint
  HWND hwnd = CreateNewWebViewWindow(url);
  LogF("[InstanceCreate] created window %p for id='%s'", (void*)hwnd, instanceId.c_str());
  if (rec->hwnd == nullptr && hwnd) {
    rec->hwnd = hwnd; rec->lastUrl = url; rec->wantDockOnCreate = g_want_dock_on_create; }
}

// ============================== Hook command ==============================
static bool HookCommandProc(int cmd, int flag)
{
  if (cmd == g_command_id) {
    OpenOrActivateInstance("wv_default", kDefaultURL);
    return true; }

  auto it = g_cmd_handlers.find(cmd);
  if (it != g_cmd_handlers.end() && it->second) {
    return it->second(flag);
  }
  return false;
}

// ============================== Handlers ===================================
static bool Act_OpenDefault(int /*flag*/)
{
  OpenOrActivateInstance("wv_default", kDefaultURL);
  return true;
}

// ============================ structures =============================
struct CommandSpec {
  const char* name;      // "FRZZ_WEBVIEW_OPEN"
  const char* desc;      // "WebView: Open (default url)"
  CommandHandler handler;
};

static const CommandSpec kCommandSpecs[] = {
  { "FRZZ_WEBVIEW_OPEN", "WebView: Open (default url)", &Act_OpenDefault },
};

// ============================== Registration blocks ==============================
static void RegisterCommandId()
{
  plugin_register("hookcommand", (void*)HookCommandProc);

  for (const auto& spec : kCommandSpecs)
  {
    int id = (int)(intptr_t)plugin_register("command_id", (void*)spec.name);
    if (!id) { LogF("Failed to register command '%s'", spec.name); continue; }

    g_registered_commands[spec.name] = id;
    g_cmd_handlers[id] = spec.handler;

    if (!strcmp(spec.name, "FRZZ_WEBVIEW_OPEN"))
      g_command_id = id;

    auto acc = std::make_unique<gaccel_register_t>();
    memset(&acc->accel, 0, sizeof(acc->accel));
    acc->accel.cmd = id;
    acc->desc = spec.desc;
    plugin_register("gaccel", acc.get());
    g_gaccels.push_back(std::move(acc));

    LogF("Registered command '%s' id=%d", spec.name, id);
  }
}

static void UnregisterCommandId()
{
  plugin_register("hookcommand", (void*)NULL);
  plugin_register("gaccel", (void*)NULL);
  for (const auto& pair : g_registered_commands)
  {
      plugin_register("command_id", (void*)pair.first.c_str());
      LogF("Unregistered command '%s'", pair.first.c_str());
  }
  g_registered_commands.clear();
}

// ============================== Entry ==============================
extern "C" REAPER_PLUGIN_DLL_EXPORT int
REAPER_PLUGIN_ENTRYPOINT(REAPER_PLUGIN_HINSTANCE hInstance, reaper_plugin_info_t* rec)
{
  g_hInst = hInstance;

  if (rec)
  {
    LogF("Plugin entry: caller=0x%08X plugin=0x%08X",
         rec->caller_version, (unsigned)REAPER_PLUGIN_VERSION);

    if (!rec->GetFunc) return 0;

    if (rec->caller_version != REAPER_PLUGIN_VERSION)
      LogRaw("WARNING: REAPER/SDK version mismatch. Плагин продолжит работу. "
             "Если что-то не работает — проверьте обновления плагина и/или REAPER.");

    const int missing = REAPERAPI_LoadAPI(rec->GetFunc);
    if (missing)
      LogF("REAPERAPI_LoadAPI: missing=%d (продолжаем, используем доступные функции)", missing);

    if (!plugin_register)
    {
      LogRaw("FATAL: essential API missing: plugin_register == NULL. "
             "Обновите REAPER и/или плагин.");
      return 0;
    }

    g_hwndParent = rec->hwnd_main;
    LogRaw("=== Plugin init ===");

    RegisterCommandId();
    RegisterAPI();
    return 1;
  }
  else
  {
    LogRaw("=== Plugin unload ===");
    UnregisterCommandId();
  UnregisterAPI();

    // Destroy all instance windows
    for (auto &kv : g_instances) {
      if (kv.second && kv.second->hwnd && IsWindow(kv.second->hwnd)) {
        bool f=false; int idx=-1;
        bool inDock = DockIsChildOfDock ? (DockIsChildOfDock(kv.second->hwnd,&f) >= 0) : false;
        if (inDock && DockWindowRemove) DockWindowRemove(kv.second->hwnd);
        DestroyWindow(kv.second->hwnd);
        kv.second->hwnd = nullptr;
        LogF("[UnloadCleanup] destroyed hwnd for id='%s'", kv.first.c_str());
      }
    }
    PurgeDeadInstances();
#ifdef _WIN32
  // Destroy resources for all instances
  for (auto &kv : g_instances) DestroyTitleBarResources(kv.second.get());
    if (g_hWebView2Loader) { FreeLibrary(g_hWebView2Loader); g_hWebView2Loader = nullptr; }
    if (g_com_initialized) { CoUninitialize(); g_com_initialized = false; }
#else
  // macOS: per-instance UI элементы уже освобождены при уничтожении окон (нет глобальных g_titleBarView/g_titleLabel)
#endif
  }
  return 0;
}
