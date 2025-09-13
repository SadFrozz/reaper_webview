// Reaper WebView Plugin
// (c) Andrew "SadFrozz" Brodsky
// 2025 and later
// main.mm

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

// ======================== Title panel (dock) =========================
#ifdef _WIN32
static void DestroyTitleGdi()
{
  if (g_titleFont) { DeleteObject(g_titleFont); g_titleFont=nullptr; }
  if (g_titleBrush){ DeleteObject(g_titleBrush); g_titleBrush=nullptr; }
}
static void EnsureTitleBarCreated(HWND hwnd)
{
  if (g_titleBar && !IsWindow(g_titleBar)) g_titleBar = nullptr;
  if (g_titleBar) return;
  LOGFONT lf{}; SystemParametersInfo(SPI_GETICONTITLELOGFONT, sizeof(lf), &lf, 0);
  lf.lfHeight = -12; lf.lfWeight = FW_SEMIBOLD;
  g_titleFont = CreateFontIndirect(&lf);
  g_titleBkColor   = GetSysColor(COLOR_BTNFACE);
  g_titleTextColor = GetSysColor(COLOR_BTNTEXT);
  g_titleBrush = CreateSolidBrush(g_titleBkColor);

  g_titleBar = CreateWindowExA(0, "STATIC","", WS_CHILD|SS_LEFT|SS_NOPREFIX,
                               g_titlePadX, 0, 10, g_titleBarH, hwnd, (HMENU)(INT_PTR)IDC_TITLEBAR,
                               (HINSTANCE)g_hInst, NULL);
  if (g_titleBar && g_titleFont) SendMessage(g_titleBar, WM_SETFONT, (WPARAM)g_titleFont, TRUE);
}
void LayoutTitleBarAndWebView(HWND hwnd, bool titleVisible)
{
  RECT rc; GetClientRect(hwnd, &rc);
  int top = 0;
  if (titleVisible && g_titleBar)
  {
    MoveWindow(g_titleBar, g_titlePadX, 0, (rc.right-rc.left) - 2*g_titlePadX, g_titleBarH, TRUE);
    ShowWindow(g_titleBar, SW_SHOWNA);
    top = g_titleBarH;
  }
  else if (g_titleBar) ShowWindow(g_titleBar, SW_HIDE);

  RECT brc = rc; brc.top += top;
  if (g_controller) g_controller->put_Bounds(brc);
}
static void SetTitleBarText(const std::string& s){ if (g_titleBar) SetWindowTextA(g_titleBar, s.c_str()); }
#else
static void EnsureTitleBarCreated(HWND hwnd)
{
  if (g_titleBarView) return;
  NSView* host = (NSView*)hwnd; if (!host) return;
  g_titleBarView = [[NSView alloc] initWithFrame:NSMakeRect(0,0, host.bounds.size.width, g_titleBarH)];
  g_titleLabel   = [[NSTextField alloc] initWithFrame:NSMakeRect(g_titlePadX, 2, host.bounds.size.width-2*g_titlePadX, g_titleBarH-4)];
  [g_titleLabel setEditable:NO]; [g_titleLabel setBordered:NO]; [g_titleLabel setBezeled:NO];
  [g_titleLabel setDrawsBackground:YES];
  [g_titleLabel setBackgroundColor:[NSColor controlBackgroundColor]];
  [g_titleLabel setTextColor:[NSColor controlTextColor]];
  [g_titleLabel setFont:[NSFont systemFontOfSize:[NSFont systemFontSize]]];
  [g_titleBarView addSubview:g_titleLabel]; [host addSubview:g_titleBarView];
  [g_titleBarView setHidden:YES];
}
void LayoutTitleBarAndWebView(HWND hwnd, bool titleVisible)
{
  NSView* host = (NSView*)hwnd; if (!host) return;
  CGFloat top = 0;
  if (titleVisible && g_titleBarView)
  {
    [g_titleBarView setFrame:NSMakeRect(0,0, host.bounds.size.width, g_titleBarH)];
    [g_titleLabel   setFrame:NSMakeRect(g_titlePadX,2, host.bounds.size.width-2*g_titlePadX, g_titleBarH-4)];
    [g_titleBarView setHidden:NO];
    top = g_titleBarH;
  } else if (g_titleBarView) [g_titleBarView setHidden:YES];

  if (g_webView)
  {
    NSRect b = NSMakeRect(0, top, host.bounds.size.width, host.bounds.size.height - top);
    [g_webView setFrame:b];
  }
}
static void SetTitleBarText(const std::string& s)
{
  if (!g_titleLabel) return;
  NSString* t = [NSString stringWithUTF8String:s.c_str()];
  [g_titleLabel setStringValue:t ? t : @""];
}
#endif

// показать/скрыть панель + текст
static void UpdateTitleBarUI(HWND hwnd, const std::string& domain, const std::string& pageTitle, bool inDock, bool usePanel)
{
  EnsureTitleBarCreated(hwnd);
  const bool wantVisible = inDock && usePanel;
  std::string panelText = domain.empty() ? "…" : domain;
  if (!pageTitle.empty()) panelText += " - " + pageTitle;
  SetTitleBarText(panelText);
  LayoutTitleBarAndWebView(hwnd, wantVisible);
}

// ============================== Titles (common) ==============================
void UpdateTitlesExtractAndApply(HWND hwnd)
{
  std::string domain, pageTitle;

  #ifdef _WIN32
    if (g_webview)
    {
      wil::unique_cotaskmem_string wsrc, wtitle;
      if (SUCCEEDED(g_webview->get_Source(&wsrc))  && wsrc)  domain    = ExtractDomainFromUrl(Narrow(std::wstring(wsrc.get())));
      if (SUCCEEDED(g_webview->get_DocumentTitle(&wtitle)) && wtitle) pageTitle = Narrow(std::wstring(wtitle.get()));
    }
  #else
    if (g_webView)
    {
      NSURL* u = g_webView.URL; if (u) domain = ExtractDomainFromUrl([[u absoluteString] UTF8String]);
      NSString* t = g_webView.title; if (t) pageTitle = [t UTF8String];
    }
  #endif

  SaveDockState(hwnd);
  const bool inDock = (g_last_dock_idx >= 0);

  const bool defaultMode = (g_titleOverride.empty() || g_titleOverride == kTitleBase);

  if (defaultMode)
  {
    if (inDock)
    {
      const std::string tabCaption = kTitleBase;
      if (tabCaption != g_lastTabTitle)
      {
        LogF("[TabTitle] in-dock (idx=%d float=%d) -> '%s'", g_last_dock_idx, (int)g_last_dock_float, tabCaption.c_str());
        g_lastTabTitle = tabCaption;
      }
      SetTabTitleInplace(hwnd, tabCaption);
      UpdateTitleBarUI(hwnd, domain, pageTitle, true, true);
    }
    else
    {
      std::string wndCaption = domain.empty() ? "…" : domain;
      if (!pageTitle.empty()) wndCaption += " - " + pageTitle;
      SetWndText(hwnd, wndCaption);
      UpdateTitleBarUI(hwnd, domain, pageTitle, false, true);
      LogF("[TitleUpdate] undock caption='%s'", wndCaption.c_str());
    }
  }
  else
  {
    if (inDock)
    {
      if (g_titleOverride != g_lastTabTitle)
      {
        LogF("[TabTitle] in-dock custom -> '%s'", g_titleOverride.c_str());
        g_lastTabTitle = g_titleOverride;
      }
      SetTabTitleInplace(hwnd, g_titleOverride);
      UpdateTitleBarUI(hwnd, domain, pageTitle, true, false);
    }
    else
    {
      SetWndText(hwnd, g_titleOverride);
      UpdateTitleBarUI(hwnd, domain, pageTitle, false, false);
      LogF("[TitleUpdate] undock custom='%s'", g_titleOverride.c_str());
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
  const bool wantPanel = inDock && (g_titleOverride == kTitleBase);
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
  bool isFloat=false; int idx=-1;
  bool inDock = DockIsChildOfDock ? (DockIsChildOfDock(hwnd, &isFloat) >= 0) : false;
  g_want_dock_on_create = inDock ? 1 : 0;
  LogF("[DockRemember] last=%s (float=%d, idx=%d)", inDock?"DOCK":"UNDOCK", (int)isFloat, idx);
}

static void ShowLocalDockMenu(HWND hwnd, int x, int y)
{
  HMENU m = CreatePopupMenu(); if (!m) return;
  bool f=false; int idx=-1; bool inDock = QueryDockState(hwnd,&f,&idx);
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
      if (DockWindowAddEx) DockWindowAddEx(hwnd, kTitleBase, kDockIdent, true);
      if (DockWindowActivate) DockWindowActivate(hwnd);
    }
    UpdateTitlesExtractAndApply(hwnd);
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
      g_dlg = hwnd;
      char* initial = (char*)lp;
      std::string url = (initial && *initial) ? std::string(initial) : std::string(kDefaultURL);
      if (initial) free(initial);

      EnsureTitleBarCreated(hwnd);
      LayoutTitleBarAndWebView(hwnd, false);

      bool isFloat=false; int idx=-1; (void)QueryDockState(hwnd, &isFloat, &idx);

      const bool wantDock = (g_want_dock_on_create == 1) || (g_want_dock_on_create < 0);
      if (wantDock && DockWindowAddEx) {
        DockWindowAddEx(hwnd, kTitleBase, kDockIdent, true);
        if (DockWindowActivate) DockWindowActivate(hwnd);
        if (DockWindowRefreshForHWND) DockWindowRefreshForHWND(hwnd);
        if (DockWindowRefresh) DockWindowRefresh();
      } else {
        PlatformMakeTopLevel(hwnd);
      }

      SaveDockState(hwnd);

      StartWebView(hwnd, url);
      UpdateTitlesExtractAndApply(hwnd);
      return 1;
    }

#ifdef _WIN32
    case WM_CTLCOLORSTATIC:
      if ((HWND)lp == g_titleBar)
      {
        HDC hdc = (HDC)wp;
        SetBkColor(hdc, g_titleBkColor);
        SetTextColor(hdc, g_titleTextColor);
        if (!g_titleBrush) g_titleBrush = CreateSolidBrush(g_titleBkColor);
        return (INT_PTR)g_titleBrush;
      }
      break;
#endif

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
      break;

    case WM_CLOSE:
      LogRaw("[WM_CLOSE]");
      RememberWantDock(hwnd);

      { bool f=false; int idx=-1;
        bool id = DockIsChildOfDock ? (DockIsChildOfDock(hwnd,&f) >= 0) : false;
        if (id && DockWindowRemove) DockWindowRemove(hwnd);
      }
    #ifdef _WIN32
      g_controller = nullptr; g_webview = nullptr;
    #endif
      DestroyWindow(hwnd);
      g_dlg = nullptr;
      return 0;

    case WM_DESTROY:
      LogRaw("[WM_DESTROY]");
    #ifdef _WIN32
      g_titleBar = nullptr;
      DestroyTitleGdi();
      if (g_hWebView2Loader) { FreeLibrary(g_hWebView2Loader); g_hWebView2Loader = nullptr; }
      if (g_com_initialized) { CoUninitialize(); g_com_initialized = false; }
    #else
      g_webView = nil;
      g_titleBarView = nil; g_titleLabel = nil;
    #endif
      return 0;
  }
  return 0;
}

// ============================== open/activate ==============================
void OpenOrActivate(const std::string& url)
{
  if (g_dlg && IsWindow(g_dlg))
  {
    bool floating=false;
    const int dockId = DockIsChildOfDock ? DockIsChildOfDock(g_dlg, &floating) : -1;
    if (dockId >= 0) {
      if (DockWindowActivate) DockWindowActivate(g_dlg);
    } else {
      PlatformMakeTopLevel(g_dlg);
    }
    return;
  }

#ifdef _WIN32
  struct MyDLGTEMPLATE : DLGTEMPLATE { WORD ext[3]; MyDLGTEMPLATE(){ memset(this,0,sizeof(*this)); } } t;
  t.style = DS_SETFONT | DS_FIXEDSYS | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | WS_CLIPCHILDREN;
  t.cx = 900; t.cy = 600; t.dwExtendedStyle = 0;
  char* urlParam = _strdup(url.c_str());
  g_dlg = CreateDialogIndirectParam((HINSTANCE)g_hInst, &t, g_hwndParent, (DLGPROC)WebViewDlgProc, (LPARAM)urlParam);
#else
  char* urlParam = strdup(url.c_str());
  g_dlg = CreateDialogParam((HINSTANCE)g_hInst, MAKEINTRESOURCE(IDD_WEBVIEW), g_hwndParent, WebViewDlgProc, (LPARAM)urlParam);
#endif

  if (g_dlg && IsWindow(g_dlg))
  {
    bool floating=false;
    const int dockId = DockIsChildOfDock ? DockIsChildOfDock(g_dlg, &floating) : -1;
    if (dockId >= 0) {
      if (DockWindowActivate) DockWindowActivate(g_dlg);
    } else {
      PlatformMakeTopLevel(g_dlg);
    }
  }
}

// ============================== Hook command ==============================
static bool HookCommandProc(int cmd, int flag)
{
  if (cmd == g_command_id) {
    OpenOrActivate(kDefaultURL);
    return true;
  }

  auto it = g_cmd_handlers.find(cmd);
  if (it != g_cmd_handlers.end() && it->second) {
    return it->second(flag);
  }
  return false;
}

// ============================== Handlers ===================================
static bool Act_OpenDefault(int /*flag*/)
{
  OpenOrActivate(kDefaultURL);
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

    if (g_dlg && IsWindow(g_dlg))
    {
      bool f=false; int idx=-1;
      bool id = DockIsChildOfDock ? (DockIsChildOfDock(g_dlg, &f) >= 0) : false;
      if (id && DockWindowRemove) DockWindowRemove(g_dlg);
      DestroyWindow(g_dlg);
      g_dlg = nullptr;
    }
#ifdef _WIN32
    DestroyTitleGdi();
    g_controller = nullptr; g_webview = nullptr;
    if (g_hWebView2Loader) { FreeLibrary(g_hWebView2Loader); g_hWebView2Loader = nullptr; }
    if (g_com_initialized) { CoUninitialize(); g_com_initialized = false; }
#else
    g_webView = nil;
    g_titleBarView = nil; g_titleLabel = nil;
#endif
  }
  return 0;
}
