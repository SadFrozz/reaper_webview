// Reaper WebView Plugin
// (c) Andrew "SadFrozz" Brodsky
// 2025 and later
// main.mm
// Notes:
//  - Legacy global g_dlg removed; all window handles resolved via instance records (GetInstanceById / GetInstanceByHwnd).
//  - Persistence stubs SaveInstanceStateAll/LoadInstanceStateAll currently just log state (no disk IO).

// init section

#define RWV_WITH_WEBVIEW2 1
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

// forward declarations (implemented per-platform in webview_win.cpp / webview_darwin.mm)
void InstanceSearchApply(WebViewInstanceRecord* rec, const std::string& query, int index, bool highlightAll, bool caseSens);
void InstanceSearchClear(WebViewInstanceRecord* rec);

// ======================== Title panel (dock) =========================
#ifdef _WIN32
static void DestroyTitleBarResources(WebViewInstanceRecord* rec)
{
  if (!rec) return;
  if (rec->titleFont) { DeleteObject(rec->titleFont); rec->titleFont=nullptr; }
  if (rec->titleBrush){ DeleteObject(rec->titleBrush); rec->titleBrush=nullptr; }
  if (rec->titleBar && IsWindow(rec->titleBar)) { DestroyWindow(rec->titleBar); rec->titleBar=nullptr; }
  // Search panel controls (do not destroy if reused across navigations unless explicitly closed)
  if (rec->searchPanelHwnd && IsWindow(rec->searchPanelHwnd)) {
    DestroyWindow(rec->searchPanelHwnd); rec->searchPanelHwnd=nullptr;
    rec->searchEdit = rec->searchBtnPrev = rec->searchBtnNext = nullptr;
    rec->searchChkCase = rec->searchChkAll = nullptr;
    rec->searchCloseBtn = nullptr;
    rec->searchPanelVisible = false;
  }
}
static void EnsureTitleBarCreated(HWND hwnd)
{
  WebViewInstanceRecord* rec = GetInstanceByHwnd(hwnd); if (!rec) return;
  if (rec->titleBar && !IsWindow(rec->titleBar)) rec->titleBar = nullptr;
  if (rec->titleBar) return;
  LOGFONTW lf{}; SystemParametersInfoW(SPI_GETICONTITLELOGFONT, sizeof(lf), &lf, 0);
  lf.lfHeight = -12; lf.lfWeight = FW_SEMIBOLD;
  rec->titleFont = CreateFontIndirectW(&lf);
  rec->titleBkColor   = GetSysColor(COLOR_BTNFACE);
  rec->titleTextColor = GetSysColor(COLOR_BTNTEXT);
  rec->titleBrush = CreateSolidBrush(rec->titleBkColor);
  rec->titleBar = CreateWindowExW(0, L"STATIC", L"", WS_CHILD|SS_LEFT|SS_NOPREFIX,
                               g_titlePadX, 0, 10, g_titleBarH, hwnd, (HMENU)(INT_PTR)IDC_TITLEBAR,
                               (HINSTANCE)g_hInst, NULL);
  if (rec->titleBar && rec->titleFont) SendMessageW(rec->titleBar, WM_SETFONT, (WPARAM)rec->titleFont, TRUE);
}
void LayoutTitleBarAndWebView(HWND hwnd, bool titleVisible)
{
  RECT rc; GetClientRect(hwnd, &rc);
  int top = 0;
  WebViewInstanceRecord* rec = GetInstanceByHwnd(hwnd);
  if (titleVisible && rec && rec->titleBar)
  {
    MoveWindow(rec->titleBar, g_titlePadX, 0, (rc.right-rc.left) - 2*g_titlePadX, g_titleBarH, TRUE);
    ShowWindow(rec->titleBar, SW_SHOWNA);
    top = g_titleBarH;
  }
  else if (rec && rec->titleBar) ShowWindow(rec->titleBar, SW_HIDE);

  RECT brc = rc; brc.top += top;
  // Reserve space at bottom if search panel visible
  int bottomReserve = 0;
  if (rec && rec->searchPanelVisible && rec->searchPanelHwnd && IsWindow(rec->searchPanelHwnd)) {
    RECT prc; GetWindowRect(rec->searchPanelHwnd, &prc);
    bottomReserve = prc.bottom - prc.top; // panel height
  }
  brc.bottom -= bottomReserve;
  if (rec && rec->controller) rec->controller->put_Bounds(brc);
  // Position search panel at bottom
  if (rec && rec->searchPanelVisible && rec->searchPanelHwnd && IsWindow(rec->searchPanelHwnd)) {
    int ph = 0; RECT pr; GetClientRect(rec->searchPanelHwnd, &pr); ph = pr.bottom - pr.top;
    MoveWindow(rec->searchPanelHwnd, 0, rc.bottom - ph, rc.right - rc.left, ph, TRUE);
  }
}
static void SetTitleBarText(HWND hwnd, const std::string& s){ WebViewInstanceRecord* rec = GetInstanceByHwnd(hwnd); if (rec && rec->titleBar) SetWindowTextW(rec->titleBar, Widen(s).c_str()); }

// ================= Search Panel (Windows) =================
static const int kSearchPanelHeight = 32; // px

static void LayoutSearchPanel(WebViewInstanceRecord* rec)
{
  if (!rec || !rec->searchPanelHwnd || !IsWindow(rec->searchPanelHwnd)) return;
  RECT pr; GetClientRect(rec->searchPanelHwnd, &pr);
  const int totalW = pr.right - pr.left;
  const int hCtrl = 20;
  int y = 6; int x = 10;
  auto place = [&](HWND h, int w){ if(!h) return; MoveWindow(h, x, y, w, hCtrl, TRUE); x += w + 6; };
  place(rec->searchEdit, 200);
  place(rec->searchBtnPrev, 48);
  place(rec->searchBtnNext, 48);
  // dynamic width for checkboxes based on text
  auto widthFromText = [](HWND h){ if(!h) return 40; wchar_t buf[64]; GetWindowTextW(h, buf, 64); int len = (int)wcslen(buf); return 8 + len*7; };
  place(rec->searchChkCase, widthFromText(rec->searchChkCase));
  place(rec->searchChkAll, widthFromText(rec->searchChkAll));
  // Counter fixed width
  place(rec->searchCounterLabel, 60);
  // Close button pinned right
  if (rec->searchCloseBtn) {
    MoveWindow(rec->searchCloseBtn, totalW - 10 - 28, y, 28, hCtrl, TRUE);
  }
}

static void EnsureSearchPanel(WebViewInstanceRecord* rec)
{
  if (!rec || !rec->hwnd) return;
  if (rec->searchPanelHwnd && !IsWindow(rec->searchPanelHwnd)) rec->searchPanelHwnd = nullptr;
  if (rec->searchPanelHwnd) return; // already created
  HWND parent = rec->hwnd;
  rec->searchPanelHwnd = CreateWindowExW(0, L"STATIC", L"", WS_CHILD|WS_CLIPCHILDREN|WS_CLIPSIBLINGS,
    0, 0, 10, kSearchPanelHeight, parent, NULL, (HINSTANCE)g_hInst, NULL);
  if (!rec->searchPanelHwnd) return;
  HFONT sysFont = (HFONT)GetStockObject(DEFAULT_GUI_FONT);
  // Create child controls parented to panel (NOT main window)
  auto mkEdit = [&](int w){ HWND h=CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"", WS_CHILD|WS_VISIBLE|ES_AUTOHSCROLL, 0,0,w,20,rec->searchPanelHwnd,(HMENU)0,(HINSTANCE)g_hInst,NULL); if(h&&sysFont) SendMessageW(h,WM_SETFONT,(WPARAM)sysFont,TRUE); return h; };
  auto mkBtn = [&](const wchar_t* txt,int w){ HWND h=CreateWindowExW(0,L"BUTTON",txt,WS_CHILD|WS_VISIBLE|BS_PUSHBUTTON,0,0,w,20,rec->searchPanelHwnd,(HMENU)0,(HINSTANCE)g_hInst,NULL); if(h&&sysFont) SendMessageW(h,WM_SETFONT,(WPARAM)sysFont,TRUE); return h; };
  auto mkChk = [&](const wchar_t* txt){ int w=(int)(8+wcslen(txt)*7); HWND h=CreateWindowExW(0,L"BUTTON",txt,WS_CHILD|WS_VISIBLE|BS_AUTOCHECKBOX,0,0,w,20,rec->searchPanelHwnd,(HMENU)0,(HINSTANCE)g_hInst,NULL); if(h&&sysFont) SendMessageW(h,WM_SETFONT,(WPARAM)sysFont,TRUE); return h; };
  rec->searchEdit     = mkEdit(200);
  rec->searchBtnPrev  = mkBtn(L"Prev",48);
  rec->searchBtnNext  = mkBtn(L"Next",48);
  rec->searchChkCase  = mkChk(L"Case");
  rec->searchChkAll   = mkChk(L"All");
  rec->searchMatchCount = 0; rec->searchMatchIndex = -1;
  rec->searchCounterLabel = CreateWindowExW(0,L"STATIC",L"0/0",WS_CHILD|WS_VISIBLE|SS_LEFT, 0,0,60,20,rec->searchPanelHwnd,(HMENU)0,(HINSTANCE)g_hInst,NULL);
  if(rec->searchCounterLabel && sysFont) SendMessageW(rec->searchCounterLabel,WM_SETFONT,(WPARAM)sysFont,TRUE);
  rec->searchCloseBtn = CreateWindowExW(0,L"BUTTON",L"X",WS_CHILD|WS_VISIBLE|BS_PUSHBUTTON, 0,0,28,20,rec->searchPanelHwnd,(HMENU)0,(HINSTANCE)g_hInst,NULL);
  if (rec->searchCloseBtn && sysFont) SendMessageW(rec->searchCloseBtn, WM_SETFONT, (WPARAM)sysFont, TRUE);
  rec->searchPanelVisible = true;
  LayoutSearchPanel(rec);
}

static void UpdateSearchCounter(WebViewInstanceRecord* rec)
{
  if (!rec || !rec->searchPanelHwnd || !IsWindow(rec->searchPanelHwnd) || !rec->searchCounterLabel) return;
  wchar_t buf[64]; int cur = (rec->searchMatchIndex>=0)?(rec->searchMatchIndex+1):0; int total = rec->searchMatchCount; swprintf(buf,64,L"%d/%d",cur,total);
  SetWindowTextW(rec->searchCounterLabel, buf);
}

static void ShowSearchPanel(WebViewInstanceRecord* rec, bool show)
{
  if (!rec) return;
  if (show) {
    EnsureSearchPanel(rec);
    if (rec->searchPanelHwnd) ShowWindow(rec->searchPanelHwnd, SW_SHOWNA);
    rec->searchPanelVisible = true;
  } else if (rec->searchPanelHwnd) {
    ShowWindow(rec->searchPanelHwnd, SW_HIDE);
    rec->searchPanelVisible = false;
  }
  if (rec->hwnd) {
    // Preserve title bar visibility decision via UpdateTitlesExtractAndApply call
    UpdateTitlesExtractAndApply(rec->hwnd);
    LayoutSearchPanel(rec);
  }
}
#else
static void DestroyTitleBarResources(WebViewInstanceRecord* rec)
{
  if (!rec) return;
  if (rec->titleLabel) { [rec->titleLabel removeFromSuperview]; rec->titleLabel = nil; }
  if (rec->titleBarView) { [rec->titleBarView removeFromSuperview]; rec->titleBarView = nil; }
}
static void EnsureTitleBarCreated(HWND hwnd)
{
  WebViewInstanceRecord* rec = GetInstanceByHwnd(hwnd); if (!rec) return;
  if (rec->titleBarView) return;
  NSView* host = (NSView*)hwnd; if (!host) return;
  rec->titleBarView = [[NSView alloc] initWithFrame:NSMakeRect(0,0, host.bounds.size.width, g_titleBarH)];
  rec->titleLabel   = [[NSTextField alloc] initWithFrame:NSMakeRect(g_titlePadX, 2, host.bounds.size.width-2*g_titlePadX, g_titleBarH-4)];
  [rec->titleLabel setEditable:NO]; [rec->titleLabel setBordered:NO]; [rec->titleLabel setBezeled:NO];
  [rec->titleLabel setDrawsBackground:YES];
  [rec->titleLabel setBackgroundColor:[NSColor controlBackgroundColor]];
  [rec->titleLabel setTextColor:[NSColor controlTextColor]];
  [rec->titleLabel setFont:[NSFont systemFontOfSize:[NSFont systemFontSize]]];
  [rec->titleBarView addSubview:rec->titleLabel]; [host addSubview:rec->titleBarView];
  [rec->titleBarView setHidden:YES];
}
void LayoutTitleBarAndWebView(HWND hwnd, bool titleVisible)
{
  NSView* host = (NSView*)hwnd; if (!host) return;
  WebViewInstanceRecord* rec = GetInstanceByHwnd(hwnd);
  CGFloat top = 0;
  if (titleVisible && rec && rec->titleBarView)
  {
    [rec->titleBarView setFrame:NSMakeRect(0,0, host.bounds.size.width, g_titleBarH)];
    [rec->titleLabel   setFrame:NSMakeRect(g_titlePadX,2, host.bounds.size.width-2*g_titlePadX, g_titleBarH-4)];
    [rec->titleBarView setHidden:NO];
    top = g_titleBarH;
  } else if (rec && rec->titleBarView) [rec->titleBarView setHidden:YES];
  if (rec && rec->webView)
  {
    NSRect b = NSMakeRect(0, top, host.bounds.size.width, host.bounds.size.height - top);
    [rec->webView setFrame:b];
  }
}
static void SetTitleBarText(HWND hwnd, const std::string& s)
{
  WebViewInstanceRecord* rec = GetInstanceByHwnd(hwnd);
  if (!rec || !rec->titleLabel) return;
  NSString* t = [NSString stringWithUTF8String:s.c_str()];
  [rec->titleLabel setStringValue:t ? t : @""];
}
#endif

#ifndef _WIN32
// ================= Search Panel (macOS via SWELL abstraction) =================
static const int kSearchPanelHeight = 32;
static void EnsureSearchPanelMac(WebViewInstanceRecord* rec)
{
  if (!rec || !rec->hwnd) return;
  if (rec->searchPanelView) return;
  NSView* host = (NSView*)rec->hwnd; if (!host) return;
  rec->searchPanelView = [[NSView alloc] initWithFrame:NSMakeRect(0, host.bounds.size.height - kSearchPanelHeight, host.bounds.size.width, kSearchPanelHeight)];
  [rec->searchPanelView setWantsLayer:YES];
  rec->searchPanelView.layer.backgroundColor = [NSColor windowBackgroundColor].CGColor;
  CGFloat x=10; CGFloat y=6; CGFloat h=20;
  auto makeField = ^NSTextField*(CGFloat w){
    NSTextField* f=[[NSTextField alloc] initWithFrame:NSMakeRect(x,y,w,h)];
    [rec->searchPanelView addSubview:f]; x+=w+6; return f; };
  auto makeBtn = ^NSButton*(NSString* title, CGFloat w){ NSButton* b=[[NSButton alloc] initWithFrame:NSMakeRect(x,y,w,h)]; [b setTitle:title]; [b setButtonType:NSMomentaryPushInButton]; [rec->searchPanelView addSubview:b]; x+=w+6; return b; };
  auto makeChk = ^NSButton*(NSString* title){ NSButton* c=[[NSButton alloc] initWithFrame:NSMakeRect(x,y,60,h)]; [c setTitle:title]; [c setButtonType:NSSwitchButton]; [rec->searchPanelView addSubview:c]; x+=60+12; return c; };
  rec->searchField      = makeField(200);
  rec->searchPrevButton = makeBtn(@"Prev",48);
  rec->searchNextButton = makeBtn(@"Next",48);
  rec->searchCaseCheck  = makeChk(@"Case");
  rec->searchAllCheck   = makeChk(@"All");
  // Counter label
  rec->searchCounterField = [[NSTextField alloc] initWithFrame:NSMakeRect(x,y+2,60,h)];
  [rec->searchCounterField setEditable:NO]; [rec->searchCounterField setBordered:NO]; [rec->searchCounterField setBezeled:NO]; [rec->searchCounterField setDrawsBackground:NO];
  [rec->searchCounterField setStringValue:@"0/0"]; [rec->searchPanelView addSubview:rec->searchCounterField];
  x += 60;
  // Close button pinned to right
  rec->searchCloseButton = [[NSButton alloc] initWithFrame:NSMakeRect(host.bounds.size.width-34,y,28,h)];
  [rec->searchCloseButton setTitle:@"X"]; [rec->searchCloseButton setButtonType:NSMomentaryPushInButton];
  [rec->searchPanelView addSubview:rec->searchCloseButton];
  // Helper wiring
  if (!rec->searchHelper) {
    FRZSearchPanelHelper* helper = [[FRZSearchPanelHelper alloc] init];
    helper.rec = rec; rec->searchHelper = (__bridge_retained void*)helper;
    // Edit field change notifications
    [[NSNotificationCenter defaultCenter] addObserver:helper selector:@selector(onEditChange:) name:NSControlTextDidChangeNotification object:rec->searchField];
    [rec->searchPrevButton setTarget:helper]; [rec->searchPrevButton setAction:@selector(onPrev:)];
    [rec->searchNextButton setTarget:helper]; [rec->searchNextButton setAction:@selector(onNext:)];
    [rec->searchCaseCheck setTarget:helper]; [rec->searchCaseCheck setAction:@selector(onCase:)];
    [rec->searchAllCheck setTarget:helper]; [rec->searchAllCheck setAction:@selector(onAll:)];
    [rec->searchCloseButton setTarget:helper]; [rec->searchCloseButton setAction:@selector(onClose:)];
  }
  rec->searchPanelVisible = true;
  [host addSubview:rec->searchPanelView];
}

static void ShowSearchPanelMac(WebViewInstanceRecord* rec, bool show)
{
  if (!rec) return; if (!rec->searchPanelView && show) EnsureSearchPanelMac(rec);
  if (rec->searchPanelView) [rec->searchPanelView setHidden:!show];
  rec->searchPanelVisible = show;
  if (rec->hwnd) LayoutTitleBarAndWebView(rec->hwnd, false);
}

static void UpdateSearchCounterMac(WebViewInstanceRecord* rec)
{
  if (!rec || !rec->searchPanelView) return;
  int cur = (rec->searchMatchIndex>=0)?(rec->searchMatchIndex+1):0; int total = rec->searchMatchCount;
  NSString* txt=[NSString stringWithFormat:@"%d/%d",cur,total];
  for(NSView* v in rec->searchPanelView.subviews){ if([v isKindOfClass:[NSTextField class]]){ NSTextField* tf=(NSTextField*)v; if([[tf stringValue] containsString:@"/"]) { [tf setStringValue:txt]; break; } } }
}
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

// ================= Search Panel Cross-platform helpers =================
static void ShowSearchPanelUnified(WebViewInstanceRecord* rec, bool show)
{
  if (!rec) return;
#ifdef _WIN32
  ShowSearchPanel(rec, show);
#else
  ShowSearchPanelMac(rec, show);
#endif
}

static void UpdateSearchCounterUnified(WebViewInstanceRecord* rec)
{
  if (!rec) return;
#ifdef _WIN32
  UpdateSearchCounter(rec);
#else
  UpdateSearchCounterMac(rec);
#endif
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
  bool basic = rec ? rec->basicCtxMenu : false;
  if (basic) {
    // Only Dock/Undock + Close
    AppendMenuA(m, MF_STRING | (inDock?MF_CHECKED:0), 10001, inDock ? "Undock window" : "Dock window in Docker");
    AppendMenuA(m, MF_SEPARATOR, 0, NULL);
    AppendMenuA(m, MF_STRING, 10099, "Close");
  } else {
    bool canBack = InstanceCanGoBack(rec);
    bool canFwd  = InstanceCanGoForward(rec);
    AppendMenuA(m, MF_STRING | (rec?0:MF_GRAYED), 10112, "Reload");
    AppendMenuA(m, MF_SEPARATOR, 0, NULL);
    AppendMenuA(m, MF_STRING | ( (rec && canBack)?0:MF_GRAYED), 10110, "Back");
    AppendMenuA(m, MF_STRING | ( (rec && canFwd)?0:MF_GRAYED), 10111, "Forward");
    AppendMenuA(m, MF_SEPARATOR, 0, NULL);
    AppendMenuA(m, MF_STRING | (rec?0:MF_GRAYED), 10120, "Find on page...");
    AppendMenuA(m, MF_SEPARATOR, 0, NULL);
    AppendMenuA(m, MF_STRING | (inDock?MF_CHECKED:0), 10001, inDock ? "Undock window" : "Dock window in Docker");
    // Removed extra separator before Close per UX refinement
    AppendMenuA(m, MF_STRING, 10099, "Close");
  }

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
  else if (cmd == 10110) { WebViewInstanceRecord* r = GetInstanceByHwnd(hwnd); InstanceGoBack(r); }
  else if (cmd == 10111) { WebViewInstanceRecord* r = GetInstanceByHwnd(hwnd); InstanceGoForward(r); }
  else if (cmd == 10112) { WebViewInstanceRecord* r = GetInstanceByHwnd(hwnd); InstanceReload(r); }
  else if (cmd == 10120) { WebViewInstanceRecord* r = GetInstanceByHwnd(hwnd); if (r) { ShowSearchPanelUnified(r, true); }
  }
  else if (cmd == 10099) SendMessage(hwnd, WM_CLOSE, 0, 0);
}

// ============================== dlg proc ==============================
static INT_PTR WINAPI WebViewDlgProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
  switch (msg)
  {
    case WM_COMMAND:
    {
#ifdef _WIN32
      WebViewInstanceRecord* rec = GetInstanceByHwnd(hwnd);
      if (!rec) break;
      HWND src = (HWND)lp;
      if (!src) break;
      // Identify control by comparing handles
      if (src == rec->searchEdit && HIWORD(wp) == EN_CHANGE) {
        wchar_t buf[512]; GetWindowTextW(rec->searchEdit, buf, 512);
        rec->searchQuery = Narrow(std::wstring(buf));
        rec->searchMatchIndex = 0;
        InstanceSearchApply(rec, rec->searchQuery, rec->searchMatchIndex, rec->searchHighlightAll, rec->searchCaseSensitive);
        UpdateSearchCounterUnified(rec);
        return 0;
      }
      if (src == rec->searchBtnPrev) {
        if (rec->searchMatchCount>0) {
          rec->searchMatchIndex = (rec->searchMatchIndex<=0)? (rec->searchMatchCount-1) : (rec->searchMatchIndex-1);
          InstanceSearchApply(rec, rec->searchQuery, rec->searchMatchIndex, rec->searchHighlightAll, rec->searchCaseSensitive);
          UpdateSearchCounterUnified(rec);
        }
        return 0;
      }
      if (src == rec->searchBtnNext) {
        if (rec->searchMatchCount>0) {
          rec->searchMatchIndex = (rec->searchMatchIndex+1) % rec->searchMatchCount;
          InstanceSearchApply(rec, rec->searchQuery, rec->searchMatchIndex, rec->searchHighlightAll, rec->searchCaseSensitive);
          UpdateSearchCounterUnified(rec);
        }
        return 0;
      }
      if (src == rec->searchChkCase) {
        rec->searchCaseSensitive = (SendMessage(rec->searchChkCase, BM_GETCHECK,0,0)==BST_CHECKED);
        rec->searchMatchIndex = 0;
        InstanceSearchApply(rec, rec->searchQuery, rec->searchMatchIndex, rec->searchHighlightAll, rec->searchCaseSensitive);
        UpdateSearchCounterUnified(rec);
        return 0;
      }
      if (src == rec->searchChkAll) {
        rec->searchHighlightAll = (SendMessage(rec->searchChkAll, BM_GETCHECK,0,0)==BST_CHECKED);
        InstanceSearchApply(rec, rec->searchQuery, rec->searchMatchIndex<0?0:rec->searchMatchIndex, rec->searchHighlightAll, rec->searchCaseSensitive);
        UpdateSearchCounterUnified(rec);
        return 0;
      }
      if (src == rec->searchCloseBtn) {
        InstanceSearchClear(rec);
        ShowSearchPanelUnified(rec, false);
        rec->searchQuery.clear(); rec->searchMatchCount=0; rec->searchMatchIndex=-1;
        return 0;
      }
#endif
      break;
    }
    case WM_KEYDOWN:
      if ((int)wp == 'F' && (GetKeyState(VK_CONTROL) & 0x8000)) {
        // Swallow Ctrl+F so built-in WebView2 search UI never appears; user assigns their own shortcut to FRZZ_WEBVIEW_SEARCH command.
        return 0; // Do NOT open prompt here (panel command driven)
      }
      break;
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

#ifdef _WIN32
    case WM_CTLCOLORSTATIC: {
      WebViewInstanceRecord* rec = GetInstanceByHwnd(hwnd);
      if (rec && rec->titleBar && (HWND)lp == rec->titleBar) {
        HDC hdc = (HDC)wp;
        SetBkColor(hdc, rec->titleBkColor);
        SetTextColor(hdc, rec->titleTextColor);
        if (!rec->titleBrush) rec->titleBrush = CreateSolidBrush(rec->titleBkColor);
        return (INT_PTR)rec->titleBrush;
      }
      break; }
#endif

    case WM_SIZE:
      SizeWebViewToClient(hwnd);
#ifdef _WIN32
      if (WebViewInstanceRecord* rec = GetInstanceByHwnd(hwnd)) {
        LayoutSearchPanel(rec);
      }
#endif
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
    case WM_MBUTTONUP:
    {
      // Close on middle-click (dock tab area will route message to child window in most cases)
      SendMessage(hwnd, WM_CLOSE, 0, 0);
      return 0;
    }

    // (Second WM_COMMAND case removed; consolidated earlier for search panel controls)

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

static bool Act_SearchActive(int /*flag*/)
{
  // Pick active instance, ensure window is valid & visible
  std::string id = g_instanceId.empty()?std::string("wv_default"):g_instanceId;
  WebViewInstanceRecord* rec = GetInstanceById(id);
  if (!rec || !rec->hwnd || !IsWindow(rec->hwnd) || !IsWindowVisible(rec->hwnd)) {
    LogRaw("[SearchGuard] No active visible WebView instance to search");
#ifdef _WIN32
    MessageBoxW(g_hwndParent?g_hwndParent:nullptr, L"Нет активного WebView для поиска", L"WebView Search", MB_OK|MB_ICONINFORMATION);
#else
    // macOS message box via Cocoa
    NSAlert* alert = [[NSAlert alloc] init];
    [alert setMessageText:@"Нет активного WebView для поиска"]; [alert addButtonWithTitle:@"OK"]; [alert runModal];
#endif
    return false;
  }
  // Show panel if hidden
  if (!rec->searchPanelVisible) {
    ShowSearchPanelUnified(rec, true);
  }
  // Focus edit
#ifdef _WIN32
  if (rec->searchEdit && IsWindow(rec->searchEdit)) SetFocus(rec->searchEdit);
#else
  if (rec->searchField) [rec->searchField becomeFirstResponder];
#endif
  // Initial apply if query already present
  if (!rec->searchQuery.empty()) {
    InstanceSearchApply(rec, rec->searchQuery, rec->searchMatchIndex<0?0:rec->searchMatchIndex, rec->searchHighlightAll, rec->searchCaseSensitive);
  }
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
  { "FRZZ_WEBVIEW_SEARCH", "WebView: Find in active WebView", &Act_SearchActive },
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
