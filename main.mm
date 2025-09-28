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

#include <algorithm>

#ifdef __APPLE__
// Forward declarations for mac native find functions (WKWebView find API)
extern "C" void MacFindStartOrUpdate(struct WebViewInstanceRecord* rec);
extern "C" void MacFindNavigate(struct WebViewInstanceRecord* rec, bool forward);
extern "C" void MacFindClose(struct WebViewInstanceRecord* rec);
#ifdef __OBJC__
#include <objc/runtime.h>
#import <Cocoa/Cocoa.h>
@interface RWVUrlDlgHandler : NSObject
@property(assign) NSPanel* panel;
@property(assign) NSTextField* edit;
@property(assign) NSButton* btn1;
@property(assign) NSButton* btn2;
@property(assign) NSButton* btnCancel;
@property(assign) int mode;
@property(assign) BOOL accepted;
@property(retain) NSString* token;
- (void)onClick:(id)sender;
@end
@implementation RWVUrlDlgHandler
- (void)onClick:(id)sender {
  if(sender==_btnCancel){ _accepted=NO; [_panel orderOut:nil]; [NSApp stopModal]; return; }
  if(_mode==1){ _token = (sender==_btn1)?@"current":@"random"; }
  else if(_mode==2){ _token = (sender==_btn1)?@"last":@"random"; }
  else { _token=@"random"; }
  _accepted=YES; [_panel orderOut:nil]; [NSApp stopModal];
}
@end
#endif
#endif

// API navigation function declared in api.h

// ======================== Title panel (creation + logic stays here) =========================
#ifndef IDC_FIND_EDIT
#define IDC_FIND_EDIT     2101
#define IDC_FIND_PREV     2102
#define IDC_FIND_NEXT     2103
#define IDC_FIND_CASE     2104
#define IDC_FIND_HILITE   2105 // deprecated (UI removed)
#define IDC_FIND_COUNTER  2106
#define IDC_FIND_CLOSE    2107
#endif

#ifdef _WIN32
// Forward declarations (creation logic in this TU; layout needs external linkage)
#include <wincodec.h>
#include "resource.h"
static HBITMAP LoadPngStripToBitmap(const wchar_t* path, int* outW, int* outH){
  *outW=0; *outH=0; HBITMAP hbmp=nullptr; IWICImagingFactory* fac=nullptr; if (FAILED(CoCreateInstance(CLSID_WICImagingFactory,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&fac)))) return nullptr; IWICBitmapDecoder* dec=nullptr; if (FAILED(fac->CreateDecoderFromFilename(path,nullptr,GENERIC_READ,WICDecodeMetadataCacheOnLoad,&dec))){ fac->Release(); return nullptr; } IWICBitmapFrameDecode* frame=nullptr; dec->GetFrame(0,&frame); IWICFormatConverter* conv=nullptr; fac->CreateFormatConverter(&conv); conv->Initialize(frame, GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone,nullptr,0.0, WICBitmapPaletteTypeCustom); UINT w=0,h=0; frame->GetSize(&w,&h); *outW=(int)w; *outH=(int)h; BITMAPV5HEADER bi{}; bi.bV5Size=sizeof(bi); bi.bV5Width=w; bi.bV5Height=-(int)h; bi.bV5Planes=1; bi.bV5BitCount=32; bi.bV5Compression=BI_BITFIELDS; bi.bV5RedMask=0x00FF0000; bi.bV5GreenMask=0x0000FF00; bi.bV5BlueMask=0x000000FF; bi.bV5AlphaMask=0xFF000000; void* bits=nullptr; HDC hdc=GetDC(nullptr); hbmp=CreateDIBSection(hdc,(BITMAPINFO*)&bi,DIB_RGB_COLORS,&bits,nullptr,0); ReleaseDC(nullptr,hdc); if (hbmp && bits){ conv->CopyPixels(nullptr,w*4,(UINT)(w*h*4),(BYTE*)bits); }
  if(conv) conv->Release(); if(frame) frame->Release(); if(dec) dec->Release(); if(fac) fac->Release(); return hbmp; }
static HBITMAP LoadPngStripFromResource(int resId, int* outW, int* outH){
  *outW=0; *outH=0; HRSRC hr = FindResource((HINSTANCE)g_hInst, MAKEINTRESOURCE(resId), RT_RCDATA); if(!hr) return nullptr; HGLOBAL hg = LoadResource((HINSTANCE)g_hInst, hr); if(!hg) return nullptr; DWORD sz = SizeofResource((HINSTANCE)g_hInst, hr); void* data = LockResource(hg); if(!data || !sz) return nullptr; IWICImagingFactory* fac=nullptr; if (FAILED(CoCreateInstance(CLSID_WICImagingFactory,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&fac)))) return nullptr; IWICStream* stream=nullptr; if (FAILED(fac->CreateStream(&stream))){ fac->Release(); return nullptr; } if (FAILED(stream->InitializeFromMemory((BYTE*)data, sz))){ stream->Release(); fac->Release(); return nullptr; } IWICBitmapDecoder* dec=nullptr; if (FAILED(fac->CreateDecoderFromStream(stream,nullptr,WICDecodeMetadataCacheOnLoad,&dec))){ stream->Release(); fac->Release(); return nullptr; } IWICBitmapFrameDecode* frame=nullptr; dec->GetFrame(0,&frame); IWICFormatConverter* conv=nullptr; fac->CreateFormatConverter(&conv); conv->Initialize(frame, GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone,nullptr,0.0, WICBitmapPaletteTypeCustom); UINT w=0,h=0; frame->GetSize(&w,&h); *outW=(int)w; *outH=(int)h; BITMAPV5HEADER bi{}; bi.bV5Size=sizeof(bi); bi.bV5Width=w; bi.bV5Height=-(int)h; bi.bV5Planes=1; bi.bV5BitCount=32; bi.bV5Compression=BI_BITFIELDS; bi.bV5RedMask=0x00FF0000; bi.bV5GreenMask=0x0000FF00; bi.bV5BlueMask=0x000000FF; bi.bV5AlphaMask=0xFF000000; void* bits=nullptr; HDC hdc=GetDC(nullptr); HBITMAP hbmp=CreateDIBSection(hdc,(BITMAPINFO*)&bi,DIB_RGB_COLORS,&bits,nullptr,0); ReleaseDC(nullptr,hdc); if(hbmp && bits){ conv->CopyPixels(nullptr,w*4,(UINT)(w*h*4),(BYTE*)bits); } if(conv) conv->Release(); if(frame) frame->Release(); if(dec) dec->Release(); if(stream) stream->Release(); if(fac) fac->Release(); return hbmp; }
static void DestroyTitleBarResources(WebViewInstanceRecord* rec);
static void EnsureTitleBarCreated(HWND hwnd);
void LayoutTitleBarAndWebView(HWND hwnd, bool titleVisible); // exported across TUs
static void SetTitleBarText(HWND hwnd, const std::string& s);
static LRESULT CALLBACK RWVTitleBarProc(HWND h, UINT m, WPARAM w, LPARAM l);
// Find bar (Windows) forward declarations
static void EnsureFindBarCreated(HWND hwnd);
void UpdateFindCounter(WebViewInstanceRecord* rec);

// Control IDs now defined globally above for both platforms

static LRESULT CALLBACK RWVFindBarProc(HWND h, UINT m, WPARAM w, LPARAM l);
static WNDPROC s_origFindEditProc = nullptr;
static WNDPROC s_origPrevBtnProc = nullptr;
static WNDPROC s_origNextBtnProc = nullptr;

// Subclass for navigation buttons to ensure we always get mouse hover/leave even if parent logic misses it
static LRESULT CALLBACK RWVNavBtnProc(HWND h, UINT m, WPARAM w, LPARAM l)
{
  int cid = (int)GetWindowLongPtr(h, GWLP_ID);
  bool isPrev = (cid == IDC_FIND_PREV);
  WebViewInstanceRecord* rec = GetInstanceByHwnd(GetParent(h));
  auto callOrig = [&](){ WNDPROC orig = isPrev? s_origPrevBtnProc : s_origNextBtnProc; return CallWindowProc(orig?orig:DefWindowProc, h, m, w, l); };
  if(!rec) return callOrig();
  bool &hot = isPrev? rec->prevHot : rec->nextHot;
  bool &down = isPrev? rec->prevDown : rec->nextDown;
  switch(m){
    case WM_MOUSEMOVE:
    {
      LogF("[FindNavBtn] WM_MOUSEMOVE cid=%d hot=%d down=%d", cid, (int)hot, (int)down);
      if(!hot){ hot=true; InvalidateRect(h,nullptr,TRUE);} TRACKMOUSEEVENT t{sizeof(t),TME_LEAVE,h,0}; TrackMouseEvent(&t); break;
    }
    case WM_MOUSELEAVE:
      LogF("[FindNavBtn] WM_MOUSELEAVE cid=%d hot->0", cid);
      if(hot){ hot=false; InvalidateRect(h,nullptr,TRUE);} break;
    case WM_LBUTTONDOWN:
      LogF("[FindNavBtn] WM_LBUTTONDOWN cid=%d", cid);
      SetCapture(h); if(!down){ down=true; InvalidateRect(h,nullptr,TRUE);} return 0;
    case WM_LBUTTONUP:
    {
      LogF("[FindNavBtn] WM_LBUTTONUP cid=%d", cid);
      if(GetCapture()==h) ReleaseCapture(); bool wasDown=down; if(down){ down=false; InvalidateRect(h,nullptr,TRUE);} POINT pt{(SHORT)LOWORD(l),(SHORT)HIWORD(l)}; RECT rc; GetClientRect(h,&rc); if(wasDown && PtInRect(&rc,pt)){
        HWND host = GetParent(GetParent(h)); if(host) SendMessageW(host, WM_COMMAND, MAKEWPARAM(cid, BN_CLICKED), (LPARAM)h);
      } return 0;
    }
  }
  return callOrig();
}
DWORD g_findLastEnterTick = 0; // timestamp of last Enter press in find edit (exported for accel handler)
bool  g_findEnterActive = false; // true while we suppress focus changes (exported)
// Custom message for deferred refocus after handling Enter inside find edit
static const UINT WM_RWV_FIND_REFOCUS = WM_APP + 0x452;
static HHOOK g_rwvMsgHook = nullptr; // message hook to pre-swallow VK_RETURN
static HWND  g_lastFindEdit = nullptr; // last known find edit hwnd
// Simple inline navigation (placeholder for real search logic) to avoid button focus side-effects
// Inline navigate helper removed: now directly call native WinFindNavigate
#ifdef _WIN32
extern void WinFindNavigate(struct WebViewInstanceRecord* rec, bool forward);
#endif
// Forward declare focus chain updater (defined later)
// forward now provided in globals.h; keep for local compiler units that included only main.mm prior
// (no static, exported)
void UpdateFocusChain(const std::string& inst);
static LRESULT CALLBACK RWVFindEditProc(HWND h, UINT m, WPARAM w, LPARAM l)
{
  switch(m){
    case WM_GETDLGCODE: return DLGC_WANTALLKEYS | DLGC_WANTCHARS | DLGC_WANTMESSAGE;
    case WM_SETFOCUS: {
      LogRaw("[FindFocus] edit WM_SETFOCUS"); g_lastFindEdit = h; HWND host = GetParent(GetParent(h)); WebViewInstanceRecord* rec = GetInstanceByHwnd(host); if (rec) UpdateFocusChain(rec->id); break; }
    case WM_KEYDOWN:
      if (w==VK_RETURN){
        HWND host = GetParent(GetParent(h)); WebViewInstanceRecord* rec = GetInstanceByHwnd(host); bool shift = (GetKeyState(VK_SHIFT)&0x8000)!=0;
  if (rec){ bool fwd = !shift; g_findEnterActive = true; g_findLastEnterTick = GetTickCount(); WinFindNavigate(rec, fwd); SetFocus(h); SendMessageW(h, EM_SETSEL, (WPARAM)-1, (LPARAM)-1); HWND findBar = GetParent(h); if (findBar && IsWindow(findBar)) PostMessage(findBar, WM_RWV_FIND_REFOCUS, (WPARAM)h, 0); return 0; }
      }
      break;
    case WM_CHAR: if (w=='\r') return 0; break;
    case WM_KEYUP: if (w==VK_RETURN) g_findEnterActive=false; break;
    case WM_KILLFOCUS:
      LogRaw("[FindFocus] edit WM_KILLFOCUS");
      if (g_findEnterActive && GetTickCount()-g_findLastEnterTick < 250){ SetFocus(h); SendMessageW(h, EM_SETSEL, (WPARAM)-1, (LPARAM)-1); return 0; }
      break;
  }
  return CallWindowProcW(s_origFindEditProc,h,m,w,l);
}

#ifdef _WIN32
// Host window subclass to capture focus transitions even when WebView holds internal focus
static LRESULT CALLBACK RWVHostSubclassProc(HWND h, UINT m, WPARAM w, LPARAM l)
{
  WebViewInstanceRecord* rec = GetInstanceByHwnd(h);
  switch(m){
    case WM_MOUSEACTIVATE:
    case WM_LBUTTONDOWN:
    case WM_RBUTTONDOWN:
    case WM_MBUTTONDOWN:
    case WM_SETFOCUS:
    case WM_ACTIVATE:
    case WM_SHOWWINDOW:
    case WM_NCLBUTTONDOWN:
    case WM_NCRBUTTONDOWN:
    case WM_WINDOWPOSCHANGED: // 0x0047 - layout/visibility changes (docker tab activation)
    {
      if(rec){
        UpdateFocusChain(rec->id);
        if (g_activeInstanceId != rec->id){ if(!g_activeInstanceId.empty()) g_lastFocusedInstanceId = g_activeInstanceId; g_activeInstanceId = rec->id; }
        LogF("[FocusTick] hostMsg=%u id='%s' tick=%lu", (unsigned)m, rec->id.c_str(), (unsigned long)rec->lastFocusTick);
      }
      break;
    }
  }
  if(rec && rec->origHostWndProc) return CallWindowProc(rec->origHostWndProc,h,m,w,l);
  return DefWindowProc(h,m,w,l);
}
#endif


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
  HFONT oldF = nullptr; if (rec && rec->titleFont) oldF = (HFONT)SelectObject(dc, rec->titleFont);
      WCHAR buf[512]; GetWindowTextW(h,buf,512); RECT tr=r; tr.left+=g_titlePadX; DrawTextW(dc,buf,-1,&tr,DT_SINGLELINE|DT_VCENTER|DT_LEFT|DT_NOPREFIX|DT_END_ELLIPSIS);
  if (oldF) SelectObject(dc, oldF);
      EndPaint(h,&ps);
      // invalidate find bar to sync colors
      if (rec && rec->findBarWnd) {
        InvalidateRect(rec->findBarWnd,nullptr,TRUE);
  HWND kids[7] = { rec->findEdit, rec->findBtnPrev, rec->findBtnNext, rec->findChkCase, rec->findLblCase, rec->findCounterStatic, rec->findBtnClose };
  for (int i=0;i<7;++i) if (kids[i]) InvalidateRect(kids[i],nullptr,TRUE);
      }
      return 0;
    }
  }
  return DefWindowProcW(h,m,w,l);
}

static void EnsureTitleBarCreated(HWND hwnd)
{
  WebViewInstanceRecord* rec = GetInstanceByHwnd(hwnd); if(!rec) return; if (rec->titleBar && !IsWindow(rec->titleBar)) rec->titleBar=nullptr; if(rec->titleBar) return;
  static bool s_reg=false; if(!s_reg){ WNDCLASSW wc{}; wc.lpfnWndProc=RWVTitleBarProc; wc.hInstance=(HINSTANCE)g_hInst; wc.lpszClassName=L"RWVTitleBar"; wc.hCursor=LoadCursor(nullptr,IDC_ARROW); wc.hbrBackground=NULL; RegisterClassW(&wc); s_reg=true; }
  LOGFONTW lf{}; SystemParametersInfoW(SPI_GETICONTITLELOGFONT,sizeof(lf),&lf,0); // используем системный логфонт без модификаций
  rec->titleFont=CreateFontIndirectW(&lf);
  rec->titleBar = CreateWindowExW(0,L"RWVTitleBar",L"",WS_CHILD,0,0,10,g_titleBarH,hwnd,(HMENU)(INT_PTR)IDC_TITLEBAR,(HINSTANCE)g_hInst,nullptr);
  if(rec->titleBar && rec->titleFont) SendMessageW(rec->titleBar,WM_SETFONT,(WPARAM)rec->titleFont,TRUE);
}

// Ensure creation of the find bar and its child controls (Windows only)
static void EnsureFindBarCreated(HWND hwnd)
{
  WebViewInstanceRecord* rec = GetInstanceByHwnd(hwnd); if(!rec) return;
  if (rec->findBarWnd && !IsWindow(rec->findBarWnd)) rec->findBarWnd = nullptr;
  if (rec->findBarWnd) return;

  static bool s_reg=false; if(!s_reg){ WNDCLASSW wc{}; wc.lpfnWndProc=RWVFindBarProc; wc.hInstance=(HINSTANCE)g_hInst; wc.lpszClassName=L"RWVFindBar"; wc.hCursor=LoadCursor(nullptr,IDC_ARROW); wc.hbrBackground=NULL; RegisterClassW(&wc); s_reg=true; }
  rec->findBarWnd = CreateWindowExW(0, L"RWVFindBar", L"", WS_CHILD|WS_CLIPCHILDREN|WS_CLIPSIBLINGS,
                                   0,0,10,g_findBarH, hwnd, (HMENU)(INT_PTR)3002, (HINSTANCE)g_hInst, nullptr);
  if (!rec->findBarWnd) return;
  rec->findHighlightAll = true; // force always-highlight on Windows

  int h=g_findBarH-8; if (h<16) h=16; int y=4;
  // Создаём в порядке логики (edit слева, навигация, опции, счётчик; close будет позиционироваться справа в layout)
  rec->findEdit = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"", WS_CHILD|WS_TABSTOP|ES_AUTOHSCROLL, 0,y,180,h, rec->findBarWnd,(HMENU)(INT_PTR)IDC_FIND_EDIT,(HINSTANCE)g_hInst,nullptr);
  int btnSize = h; // square clickable area
  // Register custom nav button class once
  static bool s_navReg=false; if(!s_navReg){ WNDCLASSW wc{}; wc.lpfnWndProc=[](HWND h, UINT m, WPARAM w, LPARAM l)->LRESULT{
        int cid = (int)GetWindowLongPtr(h,GWLP_ID); bool isPrev = (cid==IDC_FIND_PREV);
        WebViewInstanceRecord* recLocal = GetInstanceByHwnd(GetParent(GetParent(h)));
        if(!recLocal) return DefWindowProcW(h,m,w,l);
        bool &hot = isPrev? recLocal->prevHot : recLocal->nextHot;
        bool &down = isPrev? recLocal->prevDown : recLocal->nextDown;
        switch(m){
          case WM_MOUSEMOVE:{ if(!hot){ hot=true; InvalidateRect(h,nullptr,FALSE);} TRACKMOUSEEVENT t{sizeof(t),TME_LEAVE,h,0}; TrackMouseEvent(&t); return 0; }
          case WM_MOUSELEAVE:{ if(hot){ hot=false; InvalidateRect(h,nullptr,FALSE);} return 0; }
          case WM_LBUTTONDOWN:{ SetCapture(h); if(!down){ down=true; InvalidateRect(h,nullptr,FALSE);} return 0; }
          case WM_LBUTTONUP:{ if(GetCapture()==h) ReleaseCapture(); bool wasDown=down; if(down){ down=false; InvalidateRect(h,nullptr,FALSE);} POINT pt{(SHORT)LOWORD(l),(SHORT)HIWORD(l)}; RECT rc; GetClientRect(h,&rc); if(wasDown && PtInRect(&rc,pt)){ HWND host = GetParent(GetParent(h)); if(host) SendMessageW(host, WM_COMMAND, MAKEWPARAM(cid, BN_CLICKED), (LPARAM)h);} return 0; }
          case WM_ERASEBKGND: return 1; // avoid default white fill
          case WM_PAINT:{ PAINTSTRUCT ps; HDC dc=BeginPaint(h,&ps); RECT rc; GetClientRect(h,&rc); int box=24; RECT r=rc; int wC=rc.right-rc.left; int hC=rc.bottom-rc.top; if(wC>box){ int dx=(wC-box)/2; r.left+=dx; r.right=r.left+box; } if(hC>box){ int dy=(hC-box)/2; r.top+=dy; r.bottom=r.top+box; }
            // Determine panel color robustly (query if not cached)
            COLORREF panelCol = recLocal->titleBkColor ? recLocal->titleBkColor : GetSysColor(COLOR_BTNFACE);
            if(!recLocal->titleBkColor){ COLORREF bkTmp, txTmp; GetPanelThemeColors(GetParent(h), dc, &bkTmp, &txTmp); panelCol=bkTmp; recLocal->titleBkColor=bkTmp; recLocal->titleTextColor=txTmp; }
            // Double buffer
            HDC memDC = CreateCompatibleDC(dc); HBITMAP memBmp = CreateCompatibleBitmap(dc, rc.right-rc.left, rc.bottom-rc.top); HGDIOBJ oldBmp = SelectObject(memDC, memBmp);
            HBRUSH br = CreateSolidBrush(panelCol); FillRect(memDC,&rc,br); DeleteObject(br);
            HBITMAP bmp = isPrev? recLocal->bmpPrev : recLocal->bmpNext; int bw = isPrev? recLocal->bmpPrevW : recLocal->bmpNextW; int bh = isPrev? recLocal->bmpPrevH : recLocal->bmpNextH;
            int frames = (bw>0 && bh>0 && (bw%3)==0)?3:1; int frameW=(frames==3)?bw/3:bw; int frameH=bh; int stateIndex=0; if(down) stateIndex=2; else if(hot) stateIndex=1; bool drew=false;
            if(frames==3 && bmp){ HDC mem=CreateCompatibleDC(memDC); HGDIOBJ old=SelectObject(mem,bmp); int dx=r.left+((r.right-r.left)-frameW)/2; int dy=r.top+((r.bottom-r.top)-frameH)/2; if(down){ dx++; dy++; } BLENDFUNCTION bf{AC_SRC_OVER,0,255,AC_SRC_ALPHA}; AlphaBlend(memDC,dx,dy,frameW,frameH,mem,stateIndex*frameW,0,frameW,frameH,bf); SelectObject(mem,old); DeleteDC(mem); drew=true; }
            if(!drew){ // vector fallback
              auto clampC=[](int v){ return v<0?0:(v>255?255:v); }; auto shade=[&](COLORREF c,int d){ int R=clampC(GetRValue(c)+d),G=clampC(GetGValue(c)+d),B=clampC(GetBValue(c)+d); return RGB(R,G,B); };
              COLORREF base=RGB(180,180,180); if(hot) base=shade(base,+40); if(down) base=shade(base,-50); POINT tri[3]; int cx=(r.left+r.right)/2; int cy=(r.top+r.bottom)/2; int sz=8; if(isPrev){ tri[0]={cx,cy-sz}; tri[1]={cx-sz,cy+sz}; tri[2]={cx+sz,cy+sz}; } else { tri[0]={cx-sz,cy-sz}; tri[1]={cx+sz,cy}; tri[2]={cx-sz,cy+sz}; } HBRUSH bA=CreateSolidBrush(base); HPEN pA=CreatePen(PS_SOLID,1,shade(base,-60)); HGDIOBJ oP=SelectObject(memDC,pA); HGDIOBJ oB=SelectObject(memDC,bA); Polygon(memDC,tri,3); SelectObject(memDC,oB); SelectObject(memDC,oP); DeleteObject(bA); DeleteObject(pA); }
            if(hot||down){ HPEN penO=CreatePen(PS_SOLID,1,RGB(128,128,128)); HGDIOBJ oP=SelectObject(memDC,penO); HGDIOBJ oB=SelectObject(memDC,GetStockObject(HOLLOW_BRUSH)); RoundRect(memDC,r.left,r.top,r.right-1,r.bottom-1,4,4); SelectObject(memDC,oB); SelectObject(memDC,oP); DeleteObject(penO);} 
            BitBlt(dc,0,0,rc.right-rc.left,rc.bottom-rc.top,memDC,0,0,SRCCOPY);
            SelectObject(memDC,oldBmp); DeleteObject(memBmp); DeleteDC(memDC);
            EndPaint(h,&ps); return 0; }
        }
        return DefWindowProcW(h,m,w,l);
      }; wc.hInstance=(HINSTANCE)g_hInst; wc.lpszClassName=L"RWVNavBtn"; wc.hCursor=LoadCursor(nullptr,IDC_ARROW); wc.hbrBackground=NULL; RegisterClassW(&wc); s_navReg=true; }
  rec->findBtnPrev = CreateWindowExW(0,L"RWVNavBtn",L"",WS_CHILD,0,y,btnSize,h, rec->findBarWnd,(HMENU)(INT_PTR)IDC_FIND_PREV,(HINSTANCE)g_hInst,nullptr);
  rec->findBtnNext = CreateWindowExW(0,L"RWVNavBtn",L"",WS_CHILD,0,y,btnSize,h, rec->findBarWnd,(HMENU)(INT_PTR)IDC_FIND_NEXT,(HINSTANCE)g_hInst,nullptr);
  // Load PNG strips (3 states horizontally) from embedded resources
  // Ensure COM for WIC (separate from WebView2 COM which may have initialized STA already)
  HRESULT coHr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED); (void)coHr; // ignore failure (likely already initialized)
  rec->bmpPrev = LoadPngStripFromResource(IDR_PNG_SEARCH_PREV, &rec->bmpPrevW, &rec->bmpPrevH);
  if(!rec->bmpPrev) LogRaw("[FindNavImg] FAILED resource PREV"); else LogF("[FindNavImg] OK resource PREV w=%d h=%d", rec->bmpPrevW, rec->bmpPrevH);
  rec->bmpNext = LoadPngStripFromResource(IDR_PNG_SEARCH_NEXT, &rec->bmpNextW, &rec->bmpNextH);
  if(!rec->bmpNext) LogRaw("[FindNavImg] FAILED resource NEXT"); else LogF("[FindNavImg] OK resource NEXT w=%d h=%d", rec->bmpNextW, rec->bmpNextH);
  // Width оставляем квадратной; если спрайт шире (3 кадра) — просто центрируем кадр.
  // Create checkboxes without text; labels will be separate STATIC controls for consistent themed text color
  rec->findChkCase = CreateWindowExW(0,L"BUTTON",L"",WS_CHILD|BS_AUTOCHECKBOX,0,y,18,h, rec->findBarWnd,(HMENU)(INT_PTR)IDC_FIND_CASE,(HINSTANCE)g_hInst,nullptr);
  rec->findLblCase = CreateWindowExW(0,L"STATIC",L"Case Sensitive",WS_CHILD|SS_CENTERIMAGE,0,y,110,h, rec->findBarWnd,nullptr,(HINSTANCE)g_hInst,nullptr);
  rec->findChkHighlight = nullptr; // removed UI
  rec->findLblHighlight = nullptr; // removed UI
  rec->findCounterStatic = CreateWindowExW(0,L"STATIC",L"0/0",WS_CHILD|SS_CENTERIMAGE,0,y,60,h, rec->findBarWnd,(HMENU)(INT_PTR)IDC_FIND_COUNTER,(HINSTANCE)g_hInst,nullptr);
  rec->findBtnClose = CreateWindowExW(0,L"BUTTON",L"X",WS_CHILD|WS_TABSTOP|BS_PUSHBUTTON,0,y,24,h, rec->findBarWnd,(HMENU)(INT_PTR)IDC_FIND_CLOSE,(HINSTANCE)g_hInst,nullptr);

  HFONT useFont = rec->titleFont ? rec->titleFont : (HFONT)SendMessage(hwnd, WM_GETFONT,0,0);
  HWND ctrls[] = { rec->findEdit, rec->findBtnPrev, rec->findBtnNext, rec->findChkCase, rec->findLblCase, rec->findCounterStatic, rec->findBtnClose };
  for (HWND c : ctrls) if (c && useFont) SendMessage(c, WM_SETFONT, (WPARAM)useFont, TRUE);
  // Create overlay statics over checkboxes to capture clicks without moving focus
  if (rec->findChkCase) {
    RECT rc; GetWindowRect(rec->findChkCase,&rc); POINT pt{rc.left,rc.top}; ScreenToClient(rec->findBarWnd,&pt); int w=rc.right-rc.left, h2=rc.bottom-rc.top;
    HWND ov = CreateWindowExW(0,L"STATIC",L"",WS_CHILD|SS_NOTIFY,pt.x,pt.y,w,h2,rec->findBarWnd,(HMENU)(INT_PTR)(IDC_FIND_CASE+1000),(HINSTANCE)g_hInst,nullptr);
    if(ov) ShowWindow(ov,SW_SHOWNA);
  }
  // highlight overlay removed
  // NOTE: Optionally could disable visual themes via SetWindowTheme, but we avoid extra deps.
  if (rec->findEdit && !s_origFindEditProc) s_origFindEditProc = (WNDPROC)SetWindowLongPtr(rec->findEdit, GWLP_WNDPROC, (LONG_PTR)RWVFindEditProc);
  if (rec->findBtnPrev && !s_origPrevBtnProc){ s_origPrevBtnProc = (WNDPROC)SetWindowLongPtr(rec->findBtnPrev, GWLP_WNDPROC, (LONG_PTR)RWVNavBtnProc); LogRaw("[FindNavBtn] subclass prev"); }
  if (rec->findBtnNext && !s_origNextBtnProc){ s_origNextBtnProc = (WNDPROC)SetWindowLongPtr(rec->findBtnNext, GWLP_WNDPROC, (LONG_PTR)RWVNavBtnProc); LogRaw("[FindNavBtn] subclass next"); }
  if (rec->findBtnPrev && !s_origPrevBtnProc) s_origPrevBtnProc = (WNDPROC)SetWindowLongPtr(rec->findBtnPrev, GWLP_WNDPROC, (LONG_PTR)RWVNavBtnProc);
  if (rec->findBtnNext && !s_origNextBtnProc) s_origNextBtnProc = (WNDPROC)SetWindowLongPtr(rec->findBtnNext, GWLP_WNDPROC, (LONG_PTR)RWVNavBtnProc);

  ShowWindow(rec->findBarWnd, SW_HIDE); for (HWND c: ctrls) if(c) ShowWindow(c,SW_HIDE);
  LogRaw("[Find] Created Windows find bar controls (custom class)");
}

static LRESULT CALLBACK RWVFindBarProc(HWND h, UINT m, WPARAM w, LPARAM l)
{
  switch(m){
    case WM_NCCREATE: return 1;
    case WM_PAINT:
    {
      PAINTSTRUCT ps; HDC dc=BeginPaint(h,&ps); RECT r; GetClientRect(h,&r);
      WebViewInstanceRecord* rec = GetInstanceByHwnd(GetParent(h));
      COLORREF bk = GetSysColor(COLOR_BTNFACE), tx = GetSysColor(COLOR_WINDOWTEXT);
      if (rec && rec->titleBrush){ // reuse title bar colors if available
        bk = rec->titleBkColor; tx = rec->titleTextColor;
      } else {
        // Pull fresh panel colors (same heuristic) to keep unified theme
        GetPanelThemeColors(h, dc, &bk, &tx);
        if (rec) {
          rec->titleBkColor = bk; rec->titleTextColor = tx;
          if (!rec->titleBrush) rec->titleBrush = CreateSolidBrush(bk);
        }
      }
      HBRUSH br = CreateSolidBrush(bk);
      FillRect(dc,&r,br); DeleteObject(br);
      // force children redraw for color sync
  if (rec){ HWND kids[5]={rec->findChkCase,rec->findLblCase,rec->findBtnPrev,rec->findBtnNext,rec->findCounterStatic}; for (HWND c: kids) if (c) InvalidateRect(c,nullptr,TRUE);}      
      EndPaint(h,&ps); return 0;
    }
    case WM_COMMAND:
    {
      HWND host = GetParent(h);
      int cid = LOWORD(w);
      WebViewInstanceRecord* rec = GetInstanceByHwnd(host);
      // Overlay statics map to underlying checkboxes
      if (cid==IDC_FIND_CASE+1000 && rec && rec->findChkCase){ SendMessage(rec->findChkCase,BM_CLICK,0,0); if(rec->findEdit) PostMessage(h, WM_RWV_FIND_REFOCUS,(WPARAM)rec->findEdit,0); return 0; }
  // highlight overlay command removed
      if (host) return (LRESULT)SendMessageW(host, m, w, l);
      break;
    }
    case WM_DRAWITEM:
    {
    DRAWITEMSTRUCT* dis = (DRAWITEMSTRUCT*)l; if (!dis) break; WebViewInstanceRecord* rec = GetInstanceByHwnd(GetParent(h)); if(!rec) break; int id = (int)w; if (id==IDC_FIND_PREV || id==IDC_FIND_NEXT){
  // Debug diagnostics for button draw states
  LogF("[FindNavImg] draw id=%d hot(prev=%d,next=%d) down(prev=%d,next=%d)", id, (int)rec->prevHot, (int)rec->nextHot, (int)rec->prevDown, (int)rec->nextDown);
  HBITMAP bmp = (id==IDC_FIND_PREV)? rec->bmpPrev : rec->bmpNext; int bw = (id==IDC_FIND_PREV)? rec->bmpPrevW : rec->bmpNextW; int bh = (id==IDC_FIND_PREV)? rec->bmpPrevH : rec->bmpNextH; RECT fullR = dis->rcItem; RECT r = fullR; // working rect (28x28 centered vertically and horizontally inside control size if bigger)
  int box=24; int wCtrl = fullR.right-fullR.left; int hCtrl = fullR.bottom-fullR.top; if (wCtrl>box){ int dx=(wCtrl-box)/2; r.left+=dx; r.right=r.left+box; } if (hCtrl>box){ int dy=(hCtrl-box)/2; r.top+=dy; r.bottom=r.top+box; }
  int stateIndex=0; bool hot = (id==IDC_FIND_PREV)? rec->prevHot : rec->nextHot; bool down = (id==IDC_FIND_PREV)? rec->prevDown : rec->nextDown; if (down) stateIndex=2; else if (hot) stateIndex=1;
  // background = panel color; fill entire control to eliminate white strips
  WebViewInstanceRecord* rrec = rec; COLORREF panelCol = GetSysColor(COLOR_BTNFACE); if (rrec) panelCol = rrec->titleBkColor? rrec->titleBkColor : panelCol; HBRUSH br = CreateSolidBrush(panelCol); FillRect(dis->hDC,&fullR,br); DeleteObject(br);
  int frames = (bw>0 && bh>0 && (bw % 3)==0)?3:1; int frameW = (frames==3)? bw/3 : bw; int frameH = bh; LogF("[FindNavImg] bmp=%p bw=%d bh=%d frames=%d stateIndex=%d hot=%d down=%d", bmp, bw, bh, frames, stateIndex, (int)hot, (int)down);
        bool drewBitmap=false;
        if (frames==3 && bmp && frameW>0 && frameH>0){
          int useIndex = stateIndex; HDC mem = CreateCompatibleDC(dis->hDC); HGDIOBJ old = SelectObject(mem,bmp);
          int dx = r.left + ((r.right-r.left)-frameW)/2; int dy = r.top + ((r.bottom-r.top)-frameH)/2;
          // subtle press offset for tactile feel
          if (down) { dx+=1; dy+=1; }
          BLENDFUNCTION bf{AC_SRC_OVER,0,255,AC_SRC_ALPHA};
          AlphaBlend(dis->hDC, dx, dy, frameW, frameH, mem, useIndex*frameW, 0, frameW, frameH, bf);
          SelectObject(mem,old); DeleteDC(mem); drewBitmap=true;
        }
        if(!drewBitmap){
          // Vector arrow with fill and pen showing explicit state coloring
          auto clampC=[](int v){ if(v<0) return 0; if(v>255) return 255; return v; };
          auto shade=[&](COLORREF c,int d){ int rC=GetRValue(c),gC=GetGValue(c),bC=GetBValue(c); rC=clampC(rC+d); gC=clampC(gC+d); bC=clampC(bC+d); return RGB(rC,gC,bC); };
          COLORREF baseArrow = RGB(180,180,180); if (hot) baseArrow = shade(baseArrow,+40); if (down) baseArrow = shade(baseArrow,-50);
          POINT tri[3]; int cx=(r.left+r.right)/2; int cy=(r.top+r.bottom)/2; int sz=8; if(id==IDC_FIND_PREV){ tri[0]={cx,cy-sz}; tri[1]={cx-sz,cy+sz}; tri[2]={cx+sz,cy+sz}; } else { tri[0]={cx-sz,cy-sz}; tri[1]={cx+sz,cy}; tri[2]={cx-sz,cy+sz}; }
          HBRUSH brA = CreateSolidBrush(baseArrow); HPEN penA = CreatePen(PS_SOLID,1, shade(baseArrow,-60)); HGDIOBJ oldP=SelectObject(dis->hDC,penA); HGDIOBJ oldB=SelectObject(dis->hDC,brA); Polygon(dis->hDC,tri,3); SelectObject(dis->hDC,oldB); SelectObject(dis->hDC,oldP); DeleteObject(brA); DeleteObject(penA);
        }
        // Hover/press feedback background overlay (semi-transparent tint)
        if (hot || down){
          COLORREF edge = RGB(128,128,128);
          int alpha = down ? 60 : 30; // stronger when pressed
          // Create a DIB section for overlay (avoid messing with global alpha)
          int ow = r.right-r.left, oh = r.bottom-r.top; BITMAPINFO bi{}; bi.bmiHeader.biSize=sizeof(BITMAPINFOHEADER); bi.bmiHeader.biWidth=ow; bi.bmiHeader.biHeight=-oh; bi.bmiHeader.biPlanes=1; bi.bmiHeader.biBitCount=32; bi.bmiHeader.biCompression=BI_RGB; void* bits=nullptr; HBITMAP hbmp=CreateDIBSection(dis->hDC,&bi,DIB_RGB_COLORS,&bits,nullptr,0);
          if (hbmp && bits){
            // fill with panel color copy then darken/lighten
            BYTE* p=(BYTE*)bits; for(int y=0;y<oh;y++){ for(int x=0;x<ow;x++){ p[0]=GetBValue(panelCol); p[1]=GetGValue(panelCol); p[2]=GetRValue(panelCol); p[3]=0; p+=4; } }
            // apply overlay tint (darken)
            int dark = down ? -40 : -15; auto clampC2=[](int v){ return v<0?0:(v>255?255:v); };
            p=(BYTE*)bits; for(int y=0;y<oh;y++){ for(int x=0;x<ow;x++){ int B=p[0],G=p[1],R=p[2]; R=clampC2(R+dark); G=clampC2(G+dark); B=clampC2(B+dark); p[0]=B; p[1]=G; p[2]=R; p[3]=(BYTE)alpha; p+=4; } }
            HDC mem=CreateCompatibleDC(dis->hDC); HGDIOBJ old=SelectObject(mem,hbmp); BLENDFUNCTION bf{AC_SRC_OVER,0,(BYTE)255,AC_SRC_ALPHA}; AlphaBlend(dis->hDC,r.left,r.top,ow,oh,mem,0,0,ow,oh,bf); SelectObject(mem,old); DeleteDC(mem);
          }
          if(hbmp) DeleteObject(hbmp);
          // Edge
          HPEN penO = CreatePen(PS_SOLID,1, edge); HGDIOBJ oldP = SelectObject(dis->hDC, penO); HGDIOBJ oldB=SelectObject(dis->hDC, GetStockObject(HOLLOW_BRUSH)); RoundRect(dis->hDC,r.left,r.top,r.right-1,r.bottom-1,4,4); SelectObject(dis->hDC,oldB); SelectObject(dis->hDC,oldP); DeleteObject(penO);
        }
        return TRUE; }
      break;
    }
    case WM_LBUTTONDOWN:
    {
      WebViewInstanceRecord* rec = GetInstanceByHwnd(GetParent(h));
      POINT pt{ (SHORT)LOWORD(l), (SHORT)HIWORD(l) }; HWND child = ChildWindowFromPointEx(h, pt, CWP_SKIPTRANSPARENT|CWP_SKIPINVISIBLE|CWP_SKIPDISABLED);
      if (rec){
  auto hitInBox=[&](HWND btn){ if(!btn) return false; RECT rc; GetClientRect(btn,&rc); int box=24; int w=rc.right-rc.left; int h2=rc.bottom-rc.top; RECT inner=rc; if(w>box){ int dx=(w-box)/2; inner.left+=dx; inner.right=inner.left+box; } if(h2>box){ int dy=(h2-box)/2; inner.top+=dy; inner.bottom=inner.top+box; } POINT local=pt; MapWindowPoints(h,btn,&local,1); return PtInRect(&inner,local)!=0; };
        if(child==rec->findBtnPrev && hitInBox(rec->findBtnPrev)){ rec->prevDown=true; InvalidateRect(rec->findBtnPrev,nullptr,TRUE); }
        else if(child==rec->findBtnNext && hitInBox(rec->findBtnNext)){ rec->nextDown=true; InvalidateRect(rec->findBtnNext,nullptr,TRUE); }
  if (child == rec->findLblCase && rec->findChkCase){ SendMessage(rec->findChkCase, BM_CLICK, 0, 0); if(rec->findEdit) SetFocus(rec->findEdit); return 0; }
  // highlight label removed
      }
      break;
    }
    case WM_MOUSEMOVE:
    {
  WebViewInstanceRecord* rec = GetInstanceByHwnd(GetParent(h)); if(!rec) break; POINT pt{ (SHORT)LOWORD(l), (SHORT)HIWORD(l) }; HWND child = ChildWindowFromPointEx(h, pt, CWP_SKIPTRANSPARENT); bool anyHot=false; auto hoverIn=[&](HWND btn){ if(!btn||child!=btn) return false; RECT rc; GetClientRect(btn,&rc); int box=24; int w=rc.right-rc.left; int h2=rc.bottom-rc.top; RECT inner=rc; if(w>box){ int dx=(w-box)/2; inner.left+=dx; inner.right=inner.left+box; } if(h2>box){ int dy=(h2-box)/2; inner.top+=dy; inner.bottom=inner.top+box; } POINT local=pt; MapWindowPoints(h,btn,&local,1); return PtInRect(&inner,local)!=0; };
      if (rec->findBtnPrev){ bool hov = hoverIn(rec->findBtnPrev); if(hov && !rec->prevHot){ rec->prevHot=true; InvalidateRect(rec->findBtnPrev,nullptr,TRUE);} else if(!hov && rec->prevHot){ rec->prevHot=false; InvalidateRect(rec->findBtnPrev,nullptr,TRUE);} if(hov) anyHot=true; }
      if (rec->findBtnNext){ bool hov = hoverIn(rec->findBtnNext); if(hov && !rec->nextHot){ rec->nextHot=true; InvalidateRect(rec->findBtnNext,nullptr,TRUE);} else if(!hov && rec->nextHot){ rec->nextHot=false; InvalidateRect(rec->findBtnNext,nullptr,TRUE);} if(hov) anyHot=true; }
      if(anyHot){ TRACKMOUSEEVENT t{sizeof(t),TME_LEAVE,h,0}; TrackMouseEvent(&t);} break;
    }
    case WM_MOUSELEAVE:
    {
      WebViewInstanceRecord* rec = GetInstanceByHwnd(GetParent(h)); if(!rec) break; if(rec->prevHot){ rec->prevHot=false; InvalidateRect(rec->findBtnPrev,nullptr,TRUE);} if(rec->nextHot){ rec->nextHot=false; InvalidateRect(rec->findBtnNext,nullptr,TRUE);} break;
    }
    case WM_LBUTTONUP:
    {
      WebViewInstanceRecord* rec = GetInstanceByHwnd(GetParent(h)); if(rec){
        POINT pt{ (SHORT)LOWORD(l), (SHORT)HIWORD(l) }; HWND child = ChildWindowFromPointEx(h, pt, CWP_SKIPTRANSPARENT|CWP_SKIPINVISIBLE|CWP_SKIPDISABLED);
        bool prevWasDown = rec->prevDown; bool nextWasDown = rec->nextDown;
        if(rec->prevDown){ rec->prevDown=false; InvalidateRect(rec->findBtnPrev,nullptr,TRUE);} 
        if(rec->nextDown){ rec->nextDown=false; InvalidateRect(rec->findBtnNext,nullptr,TRUE);} 
  auto hitInBox=[&](HWND btn){ if(!btn) return false; RECT rc; GetClientRect(btn,&rc); int box=24; int w=rc.right-rc.left; int h2=rc.bottom-rc.top; RECT inner=rc; if(w>box){ int dx=(w-box)/2; inner.left+=dx; inner.right=inner.left+box; } if(h2>box){ int dy=(h2-box)/2; inner.top+=dy; inner.bottom=inner.top+box; } POINT local=pt; MapWindowPoints(h,btn,&local,1); return PtInRect(&inner,local)!=0; };
        if(prevWasDown && child==rec->findBtnPrev && hitInBox(rec->findBtnPrev)){ // emulate button command
          HWND host = GetParent(h); if(host) SendMessageW(host, WM_COMMAND, MAKEWPARAM(IDC_FIND_PREV, BN_CLICKED), (LPARAM)rec->findBtnPrev); }
        if(nextWasDown && child==rec->findBtnNext && hitInBox(rec->findBtnNext)){ HWND host = GetParent(h); if(host) SendMessageW(host, WM_COMMAND, MAKEWPARAM(IDC_FIND_NEXT, BN_CLICKED), (LPARAM)rec->findBtnNext); }
      }
      break;
    }
    case WM_NEXTDLGCTL:
      // Block dialog navigation focus changes triggered implicitly after Enter
      if (g_findEnterActive && GetTickCount()-g_findLastEnterTick < 250) return 0;
      break;
    case WM_CTLCOLORSTATIC:
    case WM_CTLCOLOREDIT:
    case WM_CTLCOLORBTN:
    {
      HDC dc=(HDC)w; WebViewInstanceRecord* rec = GetInstanceByHwnd(GetParent(h));
      COLORREF bkCol = GetSysColor(COLOR_BTNFACE), txCol = GetSysColor(COLOR_WINDOWTEXT);
      if (rec) {
        if (!rec->titleBrush) {
          COLORREF bk, tx; GetPanelThemeColors(GetParent(h), dc, &bk, &tx);
          rec->titleBkColor=bk; rec->titleTextColor=tx; rec->titleBrush=CreateSolidBrush(bk);
        }
        bkCol = rec->titleBkColor; txCol = rec->titleTextColor;
      }
      SetBkMode(dc, TRANSPARENT); SetTextColor(dc, txCol);
      static HBRUSH s_tmp=nullptr; if (!rec || !rec->titleBrush) {
        if (s_tmp) DeleteObject(s_tmp); s_tmp = CreateSolidBrush(bkCol);
        return (LRESULT)s_tmp;
      }
      return (LRESULT)rec->titleBrush;
    }
    case WM_RWV_FIND_REFOCUS:
    {
      WebViewInstanceRecord* rec = GetInstanceByHwnd(GetParent(h));
      if (rec && rec->findEdit && IsWindow(rec->findEdit)) {
        LogRaw("[FindFocus] deferred refocus");
        SetFocus(rec->findEdit);
        SendMessage(rec->findEdit, EM_SETSEL, (WPARAM)-1, (LPARAM)-1);
      }
      g_findEnterActive = false; // end suppression window
      return 0;
    }
  }
  return DefWindowProcW(h,m,w,l);
}

void UpdateFindCounter(WebViewInstanceRecord* rec)
{
  if (!rec || !rec->findCounterStatic) return;
  int cur = rec->findCurrentIndex; int tot = rec->findTotalMatches;
  if (cur < 0) cur = 0; if (tot < 0) tot = 0; if (cur > tot) cur = tot;
    char buf[64]; snprintf(buf,sizeof(buf), "%d/%d", cur, tot);
  SetWindowTextA(rec->findCounterStatic, buf);
}

void LayoutTitleBarAndWebView(HWND hwnd, bool titleVisible)
{
  RECT rc; GetClientRect(hwnd,&rc); WebViewInstanceRecord* rec=GetInstanceByHwnd(hwnd);
  int top=0; int bottom=0;
  // Title bar at top
  if(titleVisible && rec && rec->titleBar){ MoveWindow(rec->titleBar,0,0,(rc.right-rc.left),g_titleBarH,TRUE); ShowWindow(rec->titleBar,SW_SHOWNA); top=g_titleBarH; }
  else if(rec && rec->titleBar) ShowWindow(rec->titleBar,SW_HIDE);
  // Find bar at bottom
  if (rec && rec->showFindBar) {
    EnsureFindBarCreated(hwnd);
    if (rec->findBarWnd) {
      int w = rc.right-rc.left; int h = g_findBarH; int y = (rc.bottom-rc.top) - h;
      MoveWindow(rec->findBarWnd, 0, y, w, h, TRUE);
      ShowWindow(rec->findBarWnd, SW_SHOWNA);
      // Layout: фиксированная ширина edit (180), остальное как раньше. Паддинг 20 по краям.
      int pad=20; int curX=pad; int innerH=h-8; if(innerH<16) innerH=16; int yC=(h-innerH)/2;
      int btnBox=24; int btnVisual=24; 
      auto showCtrl=[&](HWND ctrl){ if(ctrl) ShowWindow(ctrl,SW_SHOWNA); };
      int editW=180; if (rec->findEdit) { MoveWindow(rec->findEdit,curX,yC,editW,innerH,TRUE); showCtrl(rec->findEdit); curX+=editW+8; }
      int closeW=24; int rightX = w - pad - closeW; // для кнопки закрытия (позиционируем в конце)
      if (rec->findBtnPrev){
        MoveWindow(rec->findBtnPrev,curX,(h-btnVisual)/2,btnBox,btnVisual,TRUE);
        showCtrl(rec->findBtnPrev);
        curX+=btnBox+8; // gap после prev
      }
      if (rec->findBtnNext){ MoveWindow(rec->findBtnNext,curX,(h-btnVisual)/2,btnBox,btnVisual,TRUE); showCtrl(rec->findBtnNext); curX+=btnBox+10; }
      if (rec->findChkCase){ MoveWindow(rec->findChkCase,curX,yC,18,innerH,TRUE); showCtrl(rec->findChkCase); curX+=18; }
      if (rec->findLblCase){ MoveWindow(rec->findLblCase,curX,yC,98,innerH,TRUE); showCtrl(rec->findLblCase); curX+=98+8; }
      if (curX < pad) curX = pad;
      if (rec->findCounterStatic){ MoveWindow(rec->findCounterStatic,curX,yC,60,innerH,TRUE); showCtrl(rec->findCounterStatic); curX+=60+6; }
      // Кнопка закрытия справа с паддингом
      if (rec->findBtnClose){ MoveWindow(rec->findBtnClose,rightX,yC,closeW,innerH,TRUE); SetWindowPos(rec->findBtnClose,HWND_TOP,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE); showCtrl(rec->findBtnClose); }
      bottom = g_findBarH;
      UpdateFindCounter(rec);
      LogF("[FindBarLayout] inst=%s w=%d editW=%d pad=%d curXend=%d", rec->id.c_str(), w, editW, pad, curX);
    }
  } else if (rec && rec->findBarWnd) {
    ShowWindow(rec->findBarWnd, SW_HIDE);
  }
  // WebView occupies remaining client area
  RECT brc=rc; brc.top+=top; brc.bottom -= bottom; if (brc.bottom < brc.top) brc.bottom = brc.top;
  if(rec && rec->controller) rec->controller->put_Bounds(brc);
}
static void SetTitleBarText(HWND hwnd, const std::string& s){ WebViewInstanceRecord* rec=GetInstanceByHwnd(hwnd); if(rec && rec->titleBar) SetWindowTextW(rec->titleBar,Widen(s).c_str()); }
#else
static void DestroyTitleBarResources(WebViewInstanceRecord* rec)
{ if(!rec) return; if(rec->titleBarView){ [rec->titleBarView removeFromSuperview]; rec->titleBarView=nil;} }

@interface FRZTitleBarView : NSView
@property (nonatomic, assign) int rwvBgColor;
@property (nonatomic, assign) int rwvTxColor;
@property (nonatomic, assign) HWND rwvHostHWND;
@end
@implementation FRZTitleBarView
- (BOOL)isFlipped { return NO; }
- (void)drawRect:(NSRect)dirtyRect
{
  [super drawRect:dirtyRect];
  int viewBg = self.rwvBgColor; int viewTx = self.rwvTxColor;
  NSColor* bgCol = (viewBg>=0)? [NSColor colorWithCalibratedRed:((viewBg>>16)&0xFF)/255.0 green:((viewBg>>8)&0xFF)/255.0 blue:(viewBg&0xFF)/255.0 alpha:1.0] : [NSColor controlBackgroundColor];
  [bgCol setFill]; NSRectFill(dirtyRect);
  WebViewInstanceRecord* rec = GetInstanceByHwnd(self.rwvHostHWND); if(!rec) return;
  NSString* text = rec->panelTitleString.empty()?@"" : [NSString stringWithUTF8String:rec->panelTitleString.c_str()]; if(!text) return;
  NSColor* txCol = (viewTx>=0)? [NSColor colorWithCalibratedRed:((viewTx>>16)&0xFF)/255.0 green:((viewTx>>8)&0xFF)/255.0 blue:(viewTx&0xFF)/255.0 alpha:1.0] : [NSColor textColor];
  NSMutableParagraphStyle* ps = [[NSMutableParagraphStyle alloc] init]; [ps setLineBreakMode:NSLineBreakByTruncatingTail]; [ps setAlignment:NSTextAlignmentLeft];
  NSDictionary* attrs = @{ NSFontAttributeName: [NSFont systemFontOfSize:[NSFont systemFontSize]], NSForegroundColorAttributeName: txCol, NSParagraphStyleAttributeName: ps };
  CGFloat padX = g_titlePadX; NSRect tr = NSMakeRect(padX, 0, dirtyRect.size.width - padX*2, dirtyRect.size.height);
  [text drawInRect:tr withAttributes:attrs];
  if (rec && (rec->titleBkColor!=viewBg || rec->titleTextColor!=viewTx)) {
    LogF("[MacDrawRectDiag] inst=%s viewColors(bg=0x%06X tx=0x%06X) recColors(bg=0x%06X tx=0x%06X)", rec->id.c_str(), viewBg, viewTx, rec->titleBkColor, rec->titleTextColor);
  }
}
@end

// Convert 24-bit int (RGB) -> NSColor
static inline NSColor* RWVColorFromInt(int v)
{
  if (v < 0) return nil;
  CGFloat r = ((v >> 16) & 0xFF) / 255.0;
  CGFloat g = ((v >> 8)  & 0xFF) / 255.0;
  CGFloat b = (v & 0xFF) / 255.0;
  return [NSColor colorWithCalibratedRed:r green:g blue:b alpha:1.0];
}

static void MacInitOrRefreshPanelColors(WebViewInstanceRecord* rec)
{
  if (!rec) return; int prevBg=rec->titleBkColor, prevTx=rec->titleTextColor; int bg=-1, tx=-1; GetPanelThemeColorsMac(&bg,&tx);
  rec->titleBkColor=bg; rec->titleTextColor=tx;
  if (prevBg!=bg || prevTx!=tx) {
    LogF("[MacPanelColorApply] inst=%s bg=0x%06X tx=0x%06X (prev bg=0x%06X tx=0x%06X)", rec->id.c_str(), bg, tx, prevBg, prevTx);
  }
  if (rec->titleBarView && [rec->titleBarView isKindOfClass:[FRZTitleBarView class]]) {
    FRZTitleBarView* v=(FRZTitleBarView*)rec->titleBarView; v.rwvBgColor=rec->titleBkColor; v.rwvTxColor=rec->titleTextColor; [v setNeedsDisplay:YES];
  }
}

static void EnsureTitleBarCreated(HWND hwnd)
{
  WebViewInstanceRecord* rec = GetInstanceByHwnd(hwnd); if(!rec) return; NSView* host=(NSView*)hwnd; if(!host) return;
  if (rec->titleBarView && [rec->titleBarView superview] != host) { [rec->titleBarView removeFromSuperview]; rec->titleBarView=nil; }
  if (rec->titleBarView) return;
  CGFloat hostH = host.bounds.size.height;
  rec->titleBarView = [[FRZTitleBarView alloc] initWithFrame:NSMakeRect(0, hostH - g_titleBarH, host.bounds.size.width, g_titleBarH)];
  [rec->titleBarView setAutoresizingMask:(NSViewWidthSizable | NSViewMinYMargin)];
  ((FRZTitleBarView*)rec->titleBarView).rwvHostHWND = hwnd;
  MacInitOrRefreshPanelColors(rec);
  if (rec->webView)
    [host addSubview:rec->titleBarView positioned:NSWindowAbove relativeTo:rec->webView];
  else
    [host addSubview:rec->titleBarView];
  [rec->titleBarView setHidden:YES];
}

#ifndef _WIN32
// Forward declarations for mac find bar helpers used before their definitions
static void EnsureFindBarCreated(HWND hwnd);
static void MacUpdateFindCounter(WebViewInstanceRecord* rec);
static void MacLayoutFindBar(WebViewInstanceRecord* rec);
#endif

void LayoutTitleBarAndWebView(HWND hwnd, bool titleVisible)
{
  NSView* host = (NSView*)hwnd; if(!host) return; WebViewInstanceRecord* rec = GetInstanceByHwnd(hwnd);
  if (!rec) return;
  if (!rec->titleBarView) EnsureTitleBarCreated(hwnd);

  CGFloat hostW = host.bounds.size.width;
  CGFloat hostH = host.bounds.size.height;
  CGFloat panelH = (titleVisible && rec->titleBarView)? g_titleBarH : 0;
  CGFloat findH = (rec->showFindBar ? g_findBarH : 0);

  if (rec->titleBarView) {
    if (titleVisible) {
      [rec->titleBarView setFrame:NSMakeRect(0, hostH - g_titleBarH, hostW, g_titleBarH)];
      MacInitOrRefreshPanelColors(rec);
      [rec->titleBarView setHidden:NO];
      if (rec->webView && [rec->titleBarView superview] == host) {
        NSArray<NSView*>* subs = [host subviews];
        if ([subs containsObject:rec->webView] && [subs containsObject:rec->titleBarView]) {
          if ([subs indexOfObject:rec->titleBarView] < [subs indexOfObject:rec->webView]) {
            [rec->titleBarView removeFromSuperviewWithoutNeedingDisplay];
            [host addSubview:rec->titleBarView positioned:NSWindowAbove relativeTo:rec->webView];
          }
        }
      }
    } else {
      [rec->titleBarView setHidden:YES];
    }
  }

  // Ensure find bar
  if (rec->showFindBar) {
    EnsureFindBarCreated(hwnd);
    if (rec->findBarView) {
      [rec->findBarView setFrame:NSMakeRect(0, 0, hostW, g_findBarH)];
      [rec->findBarView setHidden:NO];
      MacUpdateFindCounter(rec);
      MacLayoutFindBar(rec);
      LogF("[Find][mac] show hostW=%g", (double)hostW);
    }
  } else if (rec->findBarView) {
    [rec->findBarView setHidden:YES];
    LogRaw("[Find][mac] hide");
  }

  if (rec->webView) {
    // WebView occupies remaining area between find bar (bottom) and panel (top)
    NSRect webF = NSMakeRect(0, findH, hostW, hostH - panelH - findH);
    if (webF.size.height < 0) webF.size.height = 0;
    [rec->webView setFrame:webF];
  }
}
static void SetTitleBarText(HWND hwnd, const std::string& s){ WebViewInstanceRecord* rec=GetInstanceByHwnd(hwnd); if(!rec) return; if(rec->panelTitleString==s) return; rec->panelTitleString=s; if(rec->titleBarView) [rec->titleBarView setNeedsDisplay:YES]; }

// ============================= macOS Find Bar =============================
@interface FRZFindBarView : NSView <NSTextFieldDelegate>
@property (nonatomic, assign) HWND rwvHostHWND;
@property (nonatomic, strong) NSTextField* txtField;
@property (nonatomic, strong) NSButton*   btnPrev;
@property (nonatomic, strong) NSButton*   btnNext;
@property (nonatomic, strong) NSButton*   chkCase;
@property (nonatomic, strong) NSTextField* lblCounter;
@property (nonatomic, strong) NSButton*   btnClose;
@end

// We will intercept Enter via delegate method instead of subclassing.

@implementation FRZFindBarView
- (BOOL)isFlipped { return NO; }
- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector
{
  if (commandSelector == @selector(insertNewline:) || commandSelector == @selector(insertLineBreak:)) {
    bool shift = (([NSEvent modifierFlags] & NSEventModifierFlagShift) != 0);
  WebViewInstanceRecord* rec = GetInstanceByHwnd(self.rwvHostHWND); if(rec){ bool fwd = !shift; LogF("[Find][mac] nav %s via Enter query='%s'", fwd?"next":"prev", rec->findQuery.c_str()); MacFindNavigate(rec, fwd); MacUpdateFindCounter(rec);}    
    return YES; // swallow
  }
  return NO;
}
- (void)controlTextDidChange:(NSNotification *)note
{
  WebViewInstanceRecord* rec = GetInstanceByHwnd(self.rwvHostHWND); if(!rec) return;
  rec->findQuery = self.txtField.stringValue ? [self.txtField.stringValue UTF8String] : "";
  rec->findCurrentIndex = 0; rec->findTotalMatches = 0;
  LogF("[Find] query change '%s' (mac)", rec->findQuery.c_str());
  MacFindStartOrUpdate(rec);
  int cur=rec->findCurrentIndex, tot=rec->findTotalMatches; self.lblCounter.stringValue=[NSString stringWithFormat:@"%d/%d",cur,tot];
}
- (void)updateCounter
{
  WebViewInstanceRecord* rec = GetInstanceByHwnd(self.rwvHostHWND); if(!rec) return;
  int cur=rec->findCurrentIndex, tot=rec->findTotalMatches; if(cur<0) cur=0; if(tot<0) tot=0; if(cur>tot) cur=tot;
  self.lblCounter.stringValue = [NSString stringWithFormat:@"%d/%d", cur, tot];
}
- (void)commonButtonAction:(NSButton*)sender
{
  WebViewInstanceRecord* rec = GetInstanceByHwnd(self.rwvHostHWND); if(!rec) return;
  if (sender == self.btnClose) {
    rec->showFindBar = false; LogRaw("[Find] close (mac)");
    [self setHidden:YES];
    LayoutTitleBarAndWebView(self.rwvHostHWND, rec->titleBarView && ![rec->titleBarView isHidden]);
  } else if (sender == self.btnPrev || sender == self.btnNext) {
  bool fwd = (sender == self.btnNext); LogF("[Find] nav %s (mac) query='%s'", fwd?"next":"prev", rec->findQuery.c_str()); MacFindNavigate(rec, fwd);
  } else if (sender == self.chkCase) {
  rec->findCaseSensitive = (self.chkCase.state == NSControlStateValueOn); LogF("[Find] case=%d (mac)", (int)rec->findCaseSensitive); MacFindStartOrUpdate(rec);
  }
  [self updateCounter];
}
@end

static void MacUpdateFindCounter(WebViewInstanceRecord* rec)
{
  if (!rec || !rec->findCounterLabel) return; int cur=rec->findCurrentIndex, tot=rec->findTotalMatches; if(cur<0)cur=0; if(tot<0)tot=0; if(cur>tot)cur=tot;
  rec->findCounterLabel.stringValue = [NSString stringWithFormat:@"%d/%d",cur,tot];
}

static int g_macFindCounterShift = 2; // optical downward shift (positive -> visually down)
static void EnsureFindBarCreated(HWND hwnd)
{
  WebViewInstanceRecord* rec = GetInstanceByHwnd(hwnd); if(!rec) return; NSView* host=(NSView*)hwnd; if(!host) return;
  if (rec->findBarView && [rec->findBarView superview] != host) { [rec->findBarView removeFromSuperview]; rec->findBarView=nil; }
  if (rec->findBarView) return;
  NSRect frame = NSMakeRect(0,0, host.bounds.size.width, g_findBarH);
  FRZFindBarView* fb = [[FRZFindBarView alloc] initWithFrame:frame];
  fb.rwvHostHWND = hwnd;
  [fb setAutoresizingMask:(NSViewWidthSizable | NSViewMaxYMargin)];
  // Replicate Windows ordering & spacing semantics
  CGFloat pad=20; CGFloat curX=pad; CGFloat barH=g_findBarH; CGFloat innerH=barH-8; if(innerH<16) innerH=16; CGFloat centerY = barH * 0.5f;
  // Edit (fixed width 180)
  fb.txtField = [[NSTextField alloc] initWithFrame:NSMakeRect(curX, centerY - innerH/2, 180, innerH)];
  [fb.txtField setAutoresizingMask:NSViewMaxXMargin]; fb.txtField.delegate=fb; curX += 180 + 8;
  // Prev / Next (24x24 square buttons). Using arrows as temporary visual until sprite parity.
  CGFloat navSize=24; fb.btnPrev = [[NSButton alloc] initWithFrame:NSMakeRect(curX, centerY - navSize/2, navSize, navSize)]; [fb.btnPrev setTitle:@"▲"]; [fb.btnPrev setBezelStyle:NSBezelStyleTexturedRounded]; [fb.btnPrev setTarget:fb]; [fb.btnPrev setAction:@selector(commonButtonAction:)]; curX += navSize + 8;
  fb.btnNext = [[NSButton alloc] initWithFrame:NSMakeRect(curX, centerY - navSize/2, navSize, navSize)]; [fb.btnNext setTitle:@"▼"]; [fb.btnNext setBezelStyle:NSBezelStyleTexturedRounded]; [fb.btnNext setTarget:fb]; [fb.btnNext setAction:@selector(commonButtonAction:)]; curX += navSize + 10;
  // Case Sensitive checkbox
  fb.chkCase = [[NSButton alloc] initWithFrame:NSMakeRect(curX, centerY - innerH/2, 120, innerH)]; [fb.chkCase setButtonType:NSButtonTypeSwitch]; [fb.chkCase setTitle:@"Case Sensitive"]; [fb.chkCase setTarget:fb]; [fb.chkCase setAction:@selector(commonButtonAction:)]; curX += 120 + 8;
  // Highlight All (shift left 10 like Windows before placing)
  curX -= 10; if(curX<pad) curX=pad;
  // Highlight All control removed (always-on highlight semantics)
  // Additional left shift 10 before counter
  curX -= 10; if(curX<pad) curX=pad;
  // Counter label: unified creation; apply global optical shift (positive = down)
  NSFont* fnt = [NSFont systemFontOfSize:[NSFont systemFontSize]];
  CGFloat baseY = centerY - innerH/2; // strict center baseline
  CGFloat finalY = baseY - g_macFindCounterShift;
  fb.lblCounter = [[NSTextField alloc] initWithFrame:NSMakeRect(curX, finalY, 60, innerH)];
  LogF("[Find][mac] counter create baseY=%g finalY=%g shift=%d", (double)baseY, (double)finalY, g_macFindCounterShift);
  [fb.lblCounter setBezeled:NO]; [fb.lblCounter setEditable:NO]; [fb.lblCounter setDrawsBackground:NO]; [fb.lblCounter setAlignment:NSTextAlignmentCenter]; [fb.lblCounter setFont:fnt]; fb.lblCounter.stringValue=@"0/0"; curX += 60 + 6;
  // Close (temp position; will be right-aligned in layout pass)
  fb.btnClose = [[NSButton alloc] initWithFrame:NSMakeRect(curX, centerY - innerH/2, 24, innerH)]; [fb.btnClose setBezelStyle:NSBezelStyleRegularSquare]; [fb.btnClose setTitle:@"X"]; [fb.btnClose setTarget:fb]; [fb.btnClose setAction:@selector(commonButtonAction:)];
  LogF("[Find][mac] create curX=%g", (double)curX);

  [fb addSubview:fb.txtField];
  [fb addSubview:fb.btnPrev];
  [fb addSubview:fb.btnNext];
  [fb addSubview:fb.chkCase];
  // highlight removed
  [fb addSubview:fb.lblCounter];
  [fb addSubview:fb.btnClose];

  rec->findBarView = fb;
  rec->findEdit = fb.txtField;
  rec->findBtnPrev = fb.btnPrev;
  rec->findBtnNext = fb.btnNext;
  rec->findChkCase = fb.chkCase;
  rec->findChkHighlight = nil; // removed
  rec->findCounterLabel = fb.lblCounter;
  rec->findBtnClose = fb.btnClose;
  rec->findHighlightAll = true; // force always-highlight (macOS)

  [host addSubview:fb positioned:NSWindowBelow relativeTo:nil];
  [fb setHidden:YES];
  LogRaw("[Find][mac] created (initial hidden)");
}

// Perform layout of mac find bar controls each time bar/frame changes (mirror Windows logic)
static void MacLayoutFindBar(WebViewInstanceRecord* rec)
{
  if(!rec || !rec->findBarView) return; NSView* fb = rec->findBarView; CGFloat w = fb.frame.size.width; CGFloat h = g_findBarH;
  CGFloat pad=20; CGFloat curX=pad; CGFloat barH=h; CGFloat innerH=barH-8; if(innerH<16) innerH=16; CGFloat centerY = barH*0.5f;
  // All controls share identical vertical centering; counter uses global optical shift
  CGFloat baseY = centerY-innerH/2; // strict center for all controls
  // Edit
  if(rec->findEdit){ [(NSView*)rec->findEdit setFrame:NSMakeRect(curX, centerY-innerH/2,180,innerH)]; curX+=180+8; }
  // Prev
  CGFloat navSize=24; if(rec->findBtnPrev){ [(NSView*)rec->findBtnPrev setFrame:NSMakeRect(curX, centerY-navSize/2,navSize,navSize)]; curX+=navSize+8; }
  // Next
  if(rec->findBtnNext){ [(NSView*)rec->findBtnNext setFrame:NSMakeRect(curX, centerY-navSize/2,navSize,navSize)]; curX+=navSize+10; }
  // Case
  if(rec->findChkCase){ [(NSView*)rec->findChkCase setFrame:NSMakeRect(curX, centerY-innerH/2,120,innerH)]; curX+=120+8; }
  // Highlight group shift
  curX-=10; if(curX<pad) curX=pad;
  // highlight removed
  // Counter shift
  curX-=10; if(curX<pad) curX=pad;
  if(rec->findCounterLabel){ CGFloat finalY = baseY - g_macFindCounterShift; NSRect fr = NSMakeRect(curX, finalY,60,innerH); [rec->findCounterLabel setFrame:fr]; curX+=60+6; LogF("[Find][mac] counter layout baseY=%g finalY=%g shift=%d", (double)baseY, (double)finalY, g_macFindCounterShift); }
  // Close right aligned
  CGFloat closeW=24; CGFloat rightX = w - pad - closeW;
  if(rec->findBtnClose){ [(NSView*)rec->findBtnClose setFrame:NSMakeRect(rightX, centerY-innerH/2,closeW,innerH)]; }
  LogF("[Find][mac] layout w=%g curX_end=%g rightX=%g", (double)w, (double)curX, (double)rightX);
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
  // Avoid recursion: UpdateTitlesExtractAndApply -> Layout -> WM_SIZE -> SizeWebViewToClient
  static thread_local bool s_inSizing = false;
  if (s_inSizing) return;
  s_inSizing = true;

  bool isFloat=false; int idx=-1;
  bool inDock = DockIsChildOfDock ? (DockIsChildOfDock(hwnd, &isFloat) >= 0) : false;
  WebViewInstanceRecord* rec = GetInstanceByHwnd(hwnd);
  const std::string effectiveTitle = (rec && !rec->titleOverride.empty()) ? rec->titleOverride : kTitleBase;
  const ShowPanelMode effectivePanelMode = rec ? rec->panelMode : ShowPanelMode::Unset;
  const bool defaultMode = (effectiveTitle.empty() || effectiveTitle == kTitleBase);

  auto panelVisible = [&](bool inDockLocal, bool defaultTitle){
    switch (effectivePanelMode) {
      case ShowPanelMode::Hide:   return false;
      case ShowPanelMode::Docker: return inDockLocal;
      case ShowPanelMode::Always: return true;
      case ShowPanelMode::Unset: default: return defaultTitle && inDockLocal; }
  };

  bool wantPanel = panelVisible(inDock, defaultMode);
  LayoutTitleBarAndWebView(hwnd, wantPanel);
  s_inSizing = false;
}

// ============================== WebView init ==============================
#ifndef WEBVIEWINITIALIZED
  #define WEBVIEWINITIALIZED
  #include "webview.h"
#endif

// ============================== контекстное меню дока ==============================
// Forward prototypes needed before menu code
static bool Act_OpenUrlDialog(int flag); // реализация ниже
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

  // Всегда первый пункт: Open URL + разделитель
  AppendMenuA(m, MF_STRING, 10105, "Open URL");
  AppendMenuA(m, MF_SEPARATOR, 0, NULL);

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
  AppendMenuA(m, MF_STRING, 10113, "Find on page");
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

  if (cmd == 10105) {
    // Вызов диалога Open URL. Используем прямой вызов handler.
    Act_OpenUrlDialog(0);
  } else if (cmd == 10001) {
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
    WebViewInstanceRecord* r = GetInstanceByHwnd(hwnd);
    if (r) {
  r->showFindBar = !r->showFindBar;
  LogF("[Find] toggle show=%d", (int)r->showFindBar);
#ifdef _WIN32
  bool titleVisible = (r->titleBar && IsWindow(r->titleBar) && IsWindowVisible(r->titleBar));
#else
  bool titleVisible = (r->titleBarView && ![r->titleBarView isHidden]);
#endif
  LayoutTitleBarAndWebView(hwnd, titleVisible);
#ifdef _WIN32
  if (r->showFindBar && r->findEdit) { SetFocus(r->findEdit); SendMessage(r->findEdit, EM_SETSEL, 0, -1); }
#else
  if (r->showFindBar && r->findEdit) { [((NSTextField*)r->findEdit) selectText:nil]; [[r->findEdit window] makeFirstResponder:((NSTextField*)r->findEdit)]; }
#endif
    } else { LogRaw("[Find] toggle requested but instance not found"); }
  }
  else if (cmd == 10099) SendMessage(hwnd, WM_CLOSE, 0, 0);
}

// ============================== dlg proc ==============================
static INT_PTR WINAPI WebViewDlgProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
  switch (msg)
  {
    case WM_SETFOCUS:
    {
      WebViewInstanceRecord* r = GetInstanceByHwnd(hwnd);
      if (r) UpdateFocusChain(r->id);
      break;
    }
    case WM_SHOWWINDOW:
    {
      if (wp) { // becoming visible
        WebViewInstanceRecord* r = GetInstanceByHwnd(hwnd);
        if (r) {
          // Не перезаписываем primary если пользователь недавно переключился на другой таб (primary-stable лог сохранит)
          if (g_focusPrimaryInstanceId != r->id) UpdateFocusChain(r->id);
        }
      }
      break;
    }
    case WM_INITDIALOG:
    {
    #ifdef _WIN32
      if (!g_rwvMsgHook) {
        g_rwvMsgHook = SetWindowsHookExW(WH_GETMESSAGE, [](int code, WPARAM wP, LPARAM lP)->LRESULT {
          if (code >= 0) {
            MSG* m = (MSG*)lP;
            if (m) {
              // Ctrl+F handling (show find bar or navigate like Enter). Shift+Ctrl+F navigates backward.
              if (m->message==WM_KEYDOWN && (m->wParam=='F' || m->wParam=='f') && (GetKeyState(VK_CONTROL)&0x8000)) {
                HWND foc = GetFocus(); HWND ctx = foc;
                HWND host=nullptr;
                if (ctx){
                  // Fast path: inside our find bar controls
                  int cid = (int)GetWindowLongPtr(ctx, GWLP_ID);
                  if (cid==IDC_FIND_EDIT || cid==IDC_FIND_PREV || cid==IDC_FIND_NEXT || cid==IDC_FIND_CASE){ HWND fb=GetParent(ctx); host = fb? GetParent(fb):nullptr; }
                  // Climb parent chain fully if not resolved
                  if (!host){ HWND p = ctx; for (int safety=0; safety<32 && p && !host; ++safety){ if (GetInstanceByHwnd(p)) { host=p; break; } p=GetParent(p); } }
                  // Fallback: brute scan child lists of known instance windows (in case focus in child reparented window)
                  if (!host){ for (auto &kv : g_instances){ if (kv.second && kv.second->hwnd && IsChild(kv.second->hwnd, ctx)){ host = kv.second->hwnd; break; } } }
                }
                if (!host){ LogRaw("[FindCtrlF] no host for Ctrl+F (ignored)"); }
                if (host){
                  WebViewInstanceRecord* rec = GetInstanceByHwnd(host);
                  if (rec){
                    bool shift = (GetKeyState(VK_SHIFT)&0x8000)!=0;
                    if (!rec->showFindBar){
                      rec->showFindBar = true; LogRaw("[FindCtrlF] show find bar (Ctrl+F)");
                      bool titleVisible = (rec->titleBar && IsWindow(rec->titleBar) && IsWindowVisible(rec->titleBar));
                      LayoutTitleBarAndWebView(host, titleVisible);
                      EnsureFindBarCreated(host); // ensure controls constructed before focusing
                      if (rec->findEdit && IsWindow(rec->findEdit)){ SetFocus(rec->findEdit); SendMessageW(rec->findEdit, EM_SETSEL, 0, -1); }
                    } else {
                      EnsureFindBarCreated(host);
                      if (rec->findEdit && IsWindow(rec->findEdit)) SetFocus(rec->findEdit);
                      g_findEnterActive = true; g_findLastEnterTick = GetTickCount();
                      WinFindNavigate(rec, !shift);
                      LogF("[FindCtrlF] nav %s query='%s'", shift?"prev":"next", rec->findQuery.c_str());
                      if (rec->findEdit && IsWindow(rec->findEdit)) SendMessageW(rec->findEdit, EM_SETSEL, (WPARAM)-1, (LPARAM)-1);
                    }
                    LogRaw("[FindHook] swallow Ctrl+F");
                    m->message = WM_NULL; m->wParam = 0; return 1; // eat
                  }
                }
              }
              if (m->message==WM_KEYDOWN && m->wParam==VK_RETURN) {
                HWND foc = GetFocus();
                if (foc) {
                  int cid = (int)GetWindowLongPtr(foc, GWLP_ID);
                  if (cid == IDC_FIND_EDIT) {
                    bool shift = (GetKeyState(VK_SHIFT)&0x8000)!=0;
                    HWND findBar = GetParent(foc);
                    HWND host = findBar ? GetParent(findBar) : nullptr;
                    WebViewInstanceRecord* rec = GetInstanceByHwnd(host);
                    if (rec) {
                      bool fwd = !shift;
                      g_findEnterActive = true; g_findLastEnterTick = GetTickCount();
                      WinFindNavigate(rec, fwd);
                      LogF("[Find] nav %s query='%s' (Enter hook)", fwd?"next":"prev", rec->findQuery.c_str());
                      SetFocus(foc); SendMessageW(foc, EM_SETSEL, (WPARAM)-1, (LPARAM)-1);
                    }
                    LogRaw("[FindHook] swallow VK_RETURN pre-translate");
                    m->message = WM_NULL; m->wParam = 0; return 1; // eat
                  }
                }
              }
            }
          }
          return CallNextHookEx(g_rwvMsgHook, code, wP, lP);
        }, nullptr, GetCurrentThreadId());
        LogRaw("[FindHook] installed WH_GETMESSAGE");
      }
    #endif
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
        case IDC_FIND_CLOSE:
        {
          WebViewInstanceRecord* r = GetInstanceByHwnd(hwnd); if (r && r->showFindBar){ r->showFindBar=false; LogRaw("[Find] close");
#ifdef _WIN32
            WinFindClose(r);
#endif
        #ifdef _WIN32
            bool titleVisible = (r->titleBar && IsWindow(r->titleBar) && IsWindowVisible(r->titleBar));
        #else
            bool titleVisible = (r->titleBarView && ![r->titleBarView isHidden]);
        #endif
            LayoutTitleBarAndWebView(hwnd, titleVisible);
          }
          return 0;
        }
        case IDC_FIND_PREV:
        case IDC_FIND_NEXT:
        {
          WebViewInstanceRecord* r = GetInstanceByHwnd(hwnd); if (r){ bool fwd = (LOWORD(wp)==IDC_FIND_NEXT); LogF("[Find] nav %s query='%s'", fwd?"next":"prev", r->findQuery.c_str());
#ifdef _WIN32
            WinFindNavigate(r, fwd);
#endif
          }
          return 0;
        }
        case IDC_FIND_CASE:
        case IDC_FIND_HILITE:
        {
          WebViewInstanceRecord* r = GetInstanceByHwnd(hwnd); if (r){ if (LOWORD(wp)==IDC_FIND_CASE){ r->findCaseSensitive = (SendMessage((HWND)lp, BM_GETCHECK,0,0)==BST_CHECKED); LogF("[Find] case=%d", (int)r->findCaseSensitive);} else { r->findHighlightAll = (SendMessage((HWND)lp, BM_GETCHECK,0,0)==BST_CHECKED); LogF("[Find] highlight=%d", (int)r->findHighlightAll);} 
#ifdef _WIN32
            WinFindStartOrUpdate(r);
#endif
          }
          return 0;
        }
        case 10105: // Open URL (context menu routed here only if dialog created as modeless in future; сейчас не должен попадать)
          Act_OpenUrlDialog(0); return 0;
        case IDC_FIND_EDIT:
        {
          if (HIWORD(wp)==EN_CHANGE) {
            WebViewInstanceRecord* r = GetInstanceByHwnd(hwnd);
            if (r && r->findEdit){
            #ifdef _WIN32
              // Read Unicode text from edit control and convert to UTF-8 (avoid mojibake for Cyrillic etc.)
              wchar_t wbuf[512]; wbuf[0]=0; GetWindowTextW(r->findEdit, wbuf, (int)(sizeof(wbuf)/sizeof(wbuf[0])));
              // Convert to UTF-8
              int need = WideCharToMultiByte(CP_UTF8,0,wbuf,-1,nullptr,0,nullptr,nullptr);
              std::string utf8;
              if (need>0){ utf8.resize(need-1); WideCharToMultiByte(CP_UTF8,0,wbuf,-1,(LPSTR)utf8.data(),need,nullptr,nullptr); }
              r->findQuery = utf8;
              r->findCurrentIndex=0; r->findTotalMatches=0; LogF("[Find] query change '%s'", r->findQuery.c_str()); UpdateFindCounter(r);
              WinFindStartOrUpdate(r);
            #else
              // NSTextField* stored in r->findEdit; safely bridge and read stringValue
              NSString* s = [(NSTextField*)r->findEdit stringValue];
              const char* cstr = s? [s UTF8String] : ""; r->findQuery = cstr? cstr : "";
              r->findCurrentIndex=0; r->findTotalMatches=0; LogF("[Find] query change '%s' (mac)", r->findQuery.c_str()); MacUpdateFindCounter(r);
            #endif
            }
          }
          return 0;
        }
        case IDOK:
        case IDCANCEL:
          SendMessage(hwnd, WM_CLOSE, 0, 0);
          return 0;
      }
      return 0; // other commands not handled

    case WM_CLOSE: {
      LogRaw("[WM_CLOSE]");
      RememberWantDock(hwnd);
      std::string closedId;
      bool closedWasPrimary=false, closedWasActive=false, closedWasLast=false;
      // Очистить ссылки в записи инстанса и зафиксировать идентификаторы до их обнуления
      for (auto &kv : g_instances) {
        if (kv.second && kv.second->hwnd == hwnd) {
          closedId = kv.first;
          closedWasPrimary = (g_focusPrimaryInstanceId == kv.first);
          closedWasActive  = (g_activeInstanceId == kv.first);
          closedWasLast    = (g_lastFocusedInstanceId == kv.first);
          if (closedWasPrimary) g_focusPrimaryInstanceId.clear();
          if (closedWasActive)  g_activeInstanceId.clear();
          if (closedWasLast)    g_lastFocusedInstanceId.clear();
          kv.second->hwnd = nullptr;
#ifdef _WIN32
          if (kv.second->bmpPrev){ DeleteObject(kv.second->bmpPrev); kv.second->bmpPrev=nullptr; }
          if (kv.second->bmpNext){ DeleteObject(kv.second->bmpNext); kv.second->bmpNext=nullptr; }
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
      struct TmpRec { std::string id; DWORD tick; };
      std::vector<TmpRec> live; live.reserve(g_instances.size());
      for (auto &kv: g_instances){ WebViewInstanceRecord* r=kv.second.get(); if(!r||!r->hwnd||!IsWindow(r->hwnd)) continue; DWORD t=r->lastFocusTick? (DWORD)r->lastFocusTick : 0; live.push_back({kv.first,t}); }
      std::sort(live.begin(),live.end(),[](const TmpRec&a,const TmpRec&b){ return (DWORD)(b.tick - a.tick) < 0x80000000UL; });
      auto containsId=[&](const std::string& id){ for(auto &t: live) if(t.id==id) return true; return false; };
      if (live.empty()) {
        g_focusPrimaryInstanceId.clear();
        g_activeInstanceId.clear();
        g_lastFocusedInstanceId.clear();
      } else {
        if (closedWasPrimary || closedWasActive) {
          // Новый режим: НЕ продвигаем автоматически новую primary.
          // Самая свежая оставшаяся вкладка уходит в last, primary/active остаются пустыми -> диалог покажет режим last.
          g_focusPrimaryInstanceId.clear();
          g_activeInstanceId.clear();
          g_lastFocusedInstanceId = live.front().id; // top fresh becomes last candidate
        } else {
          // Закрывалась не primary: сохраняем текущие ссылки если валидны
          if (!g_focusPrimaryInstanceId.empty() && !containsId(g_focusPrimaryInstanceId)) g_focusPrimaryInstanceId.clear();
          if (!g_activeInstanceId.empty() && !containsId(g_activeInstanceId)) g_activeInstanceId.clear();
          if (!g_lastFocusedInstanceId.empty() && !containsId(g_lastFocusedInstanceId)) g_lastFocusedInstanceId.clear();
          // Если active пуст, но primary есть – синхронизируем (старое поведение)
          if (g_activeInstanceId.empty() && !g_focusPrimaryInstanceId.empty()) g_activeInstanceId = g_focusPrimaryInstanceId;
          // Если last пуст и есть хотя бы 2 живых — выберем вторую по свежести (или первую если одна)
          if (g_lastFocusedInstanceId.empty()) {
            if (live.size()>1) {
              // Выбираем логически "предыдущую" не равную primary/active
              for (size_t i=0;i<live.size();++i){ const std::string &cand=live[i].id; if(cand!=g_focusPrimaryInstanceId && cand!=g_activeInstanceId){ g_lastFocusedInstanceId=cand; break; } }
              if (g_lastFocusedInstanceId.empty()) g_lastFocusedInstanceId = live.front().id; // fallback
            } else {
              // одна вкладка: last остаётся пустым
            }
          }
        }
      }
      LogF("[FocusChain] after-close (new policy) closed='%s' wasPrimary=%d wasActive=%d -> primary='%s' active='%s' last='%s'", closedId.c_str(), (int)closedWasPrimary, (int)closedWasActive, g_focusPrimaryInstanceId.c_str(), g_activeInstanceId.c_str(), g_lastFocusedInstanceId.c_str());
      { bool f=false; int idx=-1; bool id = DockIsChildOfDock ? (DockIsChildOfDock(hwnd,&f) >= 0) : false; if (id && DockWindowRemove) DockWindowRemove(hwnd); }
      DestroyWindow(hwnd);
      return 0; }

    case WM_DESTROY:
      LogRaw("[WM_DESTROY]");
    #ifdef _WIN32
      if (g_rwvMsgHook){ UnhookWindowsHookEx(g_rwvMsgHook); g_rwvMsgHook=nullptr; LogRaw("[FindHook] removed WH_GETMESSAGE"); }
    #endif
      break;
    case WM_TIMER:
      // (таймеры для повторного обновления заголовка удалены как лишняя нагрузка)
      break;
#ifdef _WIN32
      for (auto &kv : g_instances) {
        if (kv.second && kv.second->hwnd == hwnd) {
          kv.second->hwnd = nullptr; 
          if (kv.second->bmpPrev){ DeleteObject(kv.second->bmpPrev); kv.second->bmpPrev=nullptr; }
          if (kv.second->bmpNext){ DeleteObject(kv.second->bmpNext); kv.second->bmpNext=nullptr; }
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
    if (g_activeInstanceId != instanceId) { if (!g_activeInstanceId.empty()) g_lastFocusedInstanceId = g_activeInstanceId; g_activeInstanceId = instanceId; }
    // Обновляем цепочку фокуса (пользователь активировал окно через команду)
    UpdateFocusChain(instanceId);
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
#ifdef _WIN32
  if (rec->hwnd && IsWindow(rec->hwnd) && !rec->origHostWndProc){
    rec->origHostWndProc = (WNDPROC)SetWindowLongPtr(rec->hwnd, GWLP_WNDPROC, (LONG_PTR)RWVHostSubclassProc);
    LogF("[HostSubclass] installed for id='%s' hwnd=%p", rec->id.c_str(), (void*)rec->hwnd);
  }
#endif
  if (g_activeInstanceId != instanceId) { if (!g_activeInstanceId.empty()) g_lastFocusedInstanceId = g_activeInstanceId; g_activeInstanceId = instanceId; }
  UpdateFocusChain(instanceId);
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

// Forward declarations for new handlers
static bool Act_Search(int flag);
static bool Act_OpenUrlDialog(int flag); // forward (used also by context menu earlier in file)

// ============================ structures =============================
struct CommandSpec {
  const char* name;      // "FRZZ_WEBVIEW_OPEN"
  const char* desc;      // "WebView: Open (default url)"
  CommandHandler handler;
};

static const CommandSpec kCommandSpecs[] = {
  { "FRZZ_WEBVIEW_OPEN", "WebView: Open (default url)", &Act_OpenDefault },
  { "FRZZ_WEBVIEW_SEARCH", "WebView: Search (show or navigate)", &Act_Search },
  { "FRZZ_WEBVIEW_OPEN_URL", "WebView: Open URL", &Act_OpenUrlDialog },
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

// ================= Additional command handlers implementation (appended) =================
#ifdef _WIN32
extern void WinFindNavigate(struct WebViewInstanceRecord* rec, bool forward);
extern void WinFindClose(struct WebViewInstanceRecord* rec);
static void EnsureFindBarCreated(HWND hwnd); // forward
#endif
#ifdef __APPLE__
// (removed duplicate MacFind* forward declarations; defined near top)
#endif

static WebViewInstanceRecord* RWV_InternalGetActiveInstance()
{
  if (!g_activeInstanceId.empty()) {
    WebViewInstanceRecord* r = GetInstanceById(g_activeInstanceId);
    if (r && r->hwnd && IsWindow(r->hwnd)) return r;
  }
  if (g_instances.size()==1) return g_instances.begin()->second.get();
  return nullptr;
}

// Resolve real-time active instance for search (focus or visible window). Avoids false positives when
// another dock tab is selected.
static WebViewInstanceRecord* ResolveSearchTargetInstance()
{
  // 1) Direct focus chain via HWND ancestry
  HWND foc = GetFocus();
  if (foc){ HWND p=foc; for(int i=0;i<32 && p; ++i){ WebViewInstanceRecord* r=GetInstanceByHwnd(p); if(r) return r; p=GetParent(p);} }
  // 1.25) Pointer hover heuristic: window currently under cursor (if host or child of host)
  POINT pt; 
#ifdef _WIN32
  if (GetCursorPos(&pt))
#else
  GetCursorPos(&pt);
  if (true)
#endif
  {
    HWND hcur = WindowFromPoint(pt);
    if (hcur){ HWND p=hcur; for(int i=0;i<32 && p; ++i){ WebViewInstanceRecord* r=GetInstanceByHwnd(p); if(r && r->hwnd && IsWindow(r->hwnd) && IsWindowVisible(r->hwnd)) { LogF("[SearchDiag] underCursor id='%s' hwnd=%p", r->id.c_str(), (void*)r->hwnd); return r; } p=GetParent(p);} }
  }
  // 1.5) Explicit primary
  if(!g_focusPrimaryInstanceId.empty()){
    WebViewInstanceRecord* r=GetInstanceById(g_focusPrimaryInstanceId); if(r && r->hwnd && IsWindow(r->hwnd)) return r; }
  // 1.75) Last focused
  if(!g_lastFocusedInstanceId.empty()){
    WebViewInstanceRecord* r=GetInstanceById(g_lastFocusedInstanceId); if(r && r->hwnd && IsWindow(r->hwnd)) return r; }
  // 2) Among visible windows pick most recent by lastFocusTick
  WebViewInstanceRecord* best=nullptr; unsigned long bestTick=0; bool anyVisible=false;
  for(auto &kv: g_instances){ WebViewInstanceRecord* r=kv.second.get(); if(!r||!r->hwnd||!IsWindow(r->hwnd)||!IsWindowVisible(r->hwnd)) continue; anyVisible=true; if(r->lastFocusTick && (!best || (DWORD)(r->lastFocusTick - bestTick) < 0x80000000UL)){ best=r; bestTick=r->lastFocusTick; } }
  if(best) return best;
  // 3) Fallback: first visible even if timestamp missing
  if(anyVisible){ for(auto &kv: g_instances){ WebViewInstanceRecord* r=kv.second.get(); if(r&&r->hwnd&&IsWindow(r->hwnd)&&IsWindowVisible(r->hwnd)) return r; } }
  // 4) Any instance
  for(auto &kv: g_instances){ if(kv.second.get()) return kv.second.get(); }
  return nullptr;
}

void UpdateFocusChain(const std::string& inst)
{
  if (inst.empty()) return; 
  if (g_focusPrimaryInstanceId == inst) {
    // Refresh timestamp for stability (user refocused same instance component)
    WebViewInstanceRecord* rec = GetInstanceById(inst);
    if (rec) rec->lastFocusTick = GetTickCount();
    if (g_activeInstanceId != inst){ if(!g_activeInstanceId.empty()) g_lastFocusedInstanceId = g_activeInstanceId; g_activeInstanceId = inst; }
    if (rec) LogF("[FocusTick] stable id='%s' tick=%lu", rec->id.c_str(), (unsigned long)rec->lastFocusTick);
    LogF("[FocusChain] primary-stable='%s' last='%s'", inst.c_str(), g_lastFocusedInstanceId.c_str());
    return;
  }
  std::string prevPrimary = g_focusPrimaryInstanceId;
  if (!g_focusPrimaryInstanceId.empty() && g_focusPrimaryInstanceId != inst) {
    if (g_lastFocusedInstanceId != g_focusPrimaryInstanceId) {
      g_lastFocusedInstanceId = g_focusPrimaryInstanceId;
    }
  }
  g_focusPrimaryInstanceId = inst;
  // stamp focus time
  WebViewInstanceRecord* rec = GetInstanceById(inst); if (rec) rec->lastFocusTick = GetTickCount();
  if (g_activeInstanceId != inst){ if(!g_activeInstanceId.empty()) g_lastFocusedInstanceId = g_activeInstanceId; g_activeInstanceId = inst; }
  if (rec) LogF("[FocusTick] primary-switch id='%s' tick=%lu", rec->id.c_str(), (unsigned long)rec->lastFocusTick);
  LogF("[FocusChain] primary='%s' last='%s' (prevPrimary='%s')", g_focusPrimaryInstanceId.c_str(), g_lastFocusedInstanceId.c_str(), prevPrimary.c_str());
}
static bool Act_Search(int /*flag*/)
{
#ifdef _WIN32
  WebViewInstanceRecord* rec = ResolveSearchTargetInstance();
  POINT cpt{}; GetCursorPos(&cpt); HWND rawUnder = WindowFromPoint(cpt); LogF("[SearchDiag] primary='%s' last='%s' active='%s' focusHWND=%p cursor=(%ld,%ld) underHWND=%p", g_focusPrimaryInstanceId.c_str(), g_lastFocusedInstanceId.c_str(), g_activeInstanceId.c_str(), (void*)GetFocus(), (long)cpt.x,(long)cpt.y,(void*)rawUnder);
  // List candidates with visibility, focus path and lastFocusTick
  for (auto &kv : g_instances){ WebViewInstanceRecord* r = kv.second.get(); if(!r) continue; bool vis = r->hwnd && IsWindow(r->hwnd) && IsWindowVisible(r->hwnd); bool isFocus = false; HWND foc=GetFocus(); if(foc){ HWND p=foc; for(int i=0;i<32 && p; ++i){ if(p==r->hwnd){ isFocus=true; break;} p=GetParent(p);} } LogF("[SearchDiag] cand id='%s' hwnd=%p vis=%d isFocusPath=%d lastTick=%lu", r->id.c_str(), (void*)r->hwnd, (int)vis, (int)isFocus, (unsigned long)r->lastFocusTick); }
  if (rec) LogF("[Search] target instance='%s' hwnd=%p", rec->id.c_str(), (void*)rec->hwnd); else LogRaw("[Search] no target instance (null)");
  if (!rec) {
    MessageBoxA(g_hwndParent ? g_hwndParent : GetForegroundWindow(),
      "No active WebView instance. Launch or focus a WebView instance and try again.",
      "WebView Search", MB_OK|MB_ICONINFORMATION);
    return false;
  }
  UpdateFocusChain(rec->id); // ensure focus chain aligns with chosen instance
  if (!rec->showFindBar) {
    if (!rec->controller) {
      MessageBoxA(rec->hwnd ? rec->hwnd : (g_hwndParent?g_hwndParent:GetForegroundWindow()),
        "WebView not initialized yet.", "WebView Search", MB_OK|MB_ICONINFORMATION);
      return false;
    }
    rec->showFindBar = true; bool titleVisible = (rec->titleBar && IsWindow(rec->titleBar) && IsWindowVisible(rec->titleBar));
    LayoutTitleBarAndWebView(rec->hwnd, titleVisible);
    EnsureFindBarCreated(rec->hwnd);
    if (rec->findEdit && IsWindow(rec->findEdit)) { SetFocus(rec->findEdit); SendMessageW(rec->findEdit, EM_SETSEL, 0, -1); }
  } else {
    EnsureFindBarCreated(rec->hwnd);
    if (rec->findEdit && IsWindow(rec->findEdit)) SetFocus(rec->findEdit);
    g_findEnterActive = true; g_findLastEnterTick = GetTickCount();
    WinFindNavigate(rec, true); // navigate forward
    if (rec->findEdit && IsWindow(rec->findEdit)) SendMessageW(rec->findEdit, EM_SETSEL, (WPARAM)-1, (LPARAM)-1);
  }
  return true;
#else
  WebViewInstanceRecord* rec = RWV_InternalGetActiveInstance(); if (!rec) return false;
  if (!rec->showFindBar) {
    rec->showFindBar = true;
    LayoutTitleBarAndWebView(rec->hwnd, rec->titleBarView && ![rec->titleBarView isHidden]);
    EnsureFindBarCreated(rec->hwnd);
    if(rec->findEdit){ [(NSTextField*)rec->findEdit selectText:nil]; [[(NSTextField*)rec->findEdit window] makeFirstResponder:(NSTextField*)rec->findEdit]; }
    LogRaw("[FindAction][mac] show via action list");
  } else {
    EnsureFindBarCreated(rec->hwnd);
    if(rec->findEdit){ [[(NSTextField*)rec->findEdit window] makeFirstResponder:(NSTextField*)rec->findEdit]; }
    MacFindNavigate(rec, true); // forward navigation like Windows
    LogF("[FindAction][mac] nav next query='%s'", rec->findQuery.c_str());
  }
  return true;
#endif
}

#ifdef _WIN32
static INT_PTR CALLBACK RWVUrlDlgProc(HWND h, UINT m, WPARAM w, LPARAM l)
{
  switch(m){
    case WM_INITDIALOG:
    {
  const int pad=10; // горизонтальный и вертикальный внутренний отступ (требование пользователя)
  // Получаем фактическую клиентскую ширину (диалог создан из шаблона ~400, но берем реальную)
  RECT cli{}; GetClientRect(h,&cli); int dlgW = cli.right - cli.left; if(dlgW < 260) dlgW = 260; // защита от слишком узкого
      // Получаем системный логфонт (иконка) как базу для единообразия с title bar
      LOGFONTW lf{}; SystemParametersInfoW(SPI_GETICONTITLELOGFONT,sizeof(lf),&lf,0);
      HFONT font = CreateFontIndirectW(&lf);
      // Однострочный layout: "URL:" (узкая метка) + edit тянется до кнопок
  HWND hLbl = CreateWindowExW(0,L"STATIC",L"URL:",WS_CHILD|WS_VISIBLE,pad,pad+2,40,18,h,(HMENU)0,(HINSTANCE)g_hInst,nullptr);
  int labelW = 40; int gapAfterLabel = 6; int editX = pad + labelW + gapAfterLabel; int editH=22;
  int editWInit = dlgW - editX - pad; if (editWInit < 120) editWInit = 120;
  HWND hEdit = CreateWindowExW(WS_EX_CLIENTEDGE,L"EDIT",L"https://",WS_CHILD|WS_VISIBLE|ES_AUTOHSCROLL,editX,pad,editWInit,editH,h,(HMENU)1001,(HINSTANCE)g_hInst,nullptr);
      // Определяем живые *видимые* инстансы (для логики режима диалога важно что вкладка действительно отображается)
      struct LiveInfo { std::string id; DWORD tick; bool visible; };
      std::vector<LiveInfo> liveInfos; liveInfos.reserve(g_instances.size());
      for (auto &kv : g_instances){
        WebViewInstanceRecord* r=kv.second.get();
        if(!r||!r->hwnd||!IsWindow(r->hwnd)) continue;
        bool vis = IsWindowVisible(r->hwnd)!=0; // если вкладка в доке не активна — окно скрыто
        DWORD t = r->lastFocusTick? (DWORD)r->lastFocusTick : 0;
        liveInfos.push_back({kv.first, t, vis});
      }
      // Отдельный список id для прежнего использования
      std::vector<std::string> liveIds; for(auto &li: liveInfos) liveIds.push_back(li.id);
      auto isVisibleId=[&](const std::string& id){ for(auto &li: liveInfos) if(li.id==id && li.visible) return true; return false; };
      auto bestVisible=[&]()->std::string{ std::string best; DWORD bestT=0; for(auto &li: liveInfos){ if(!li.visible) continue; if(best.empty() || (DWORD)(li.tick - bestT) < 0x80000000UL){ best=li.id; bestT=li.tick; } } return best; };
      bool haveActive=false, haveLast=false; 
      if (!g_focusPrimaryInstanceId.empty()){
        WebViewInstanceRecord* a = GetInstanceById(g_focusPrimaryInstanceId); haveActive = (a && a->hwnd && IsWindow(a->hwnd) && isVisibleId(g_focusPrimaryInstanceId)); }
      if (!g_lastFocusedInstanceId.empty()){
        WebViewInstanceRecord* lr = GetInstanceById(g_lastFocusedInstanceId); haveLast = (lr && lr->hwnd && IsWindow(lr->hwnd) && isVisibleId(g_lastFocusedInstanceId)); }
      // Если нет active/last, но есть хотя бы один живой инстанс (даже если он не видим) — используем самый свежий как last
      if (!haveActive && !haveLast && !liveInfos.empty()) {
        // Возьмём самый свежий по lastFocusTick даже если он невидим — важно показать режим Last Tab вместо создания новой
        std::string bestAny; DWORD bestTick=0;
        for (auto &li: liveInfos){ if(bestAny.empty() || (DWORD)(li.tick - bestTick) < 0x80000000UL){ bestAny=li.id; bestTick=li.tick; } }
        if(!bestAny.empty()) { g_lastFocusedInstanceId = bestAny; haveLast = true; }
      } else if (!haveActive){
        // Нет active, но возможно есть видимый кандидат для last уже обработан выше
        if (!haveLast){ std::string cand = bestVisible(); if(!cand.empty()) { g_lastFocusedInstanceId = cand; haveLast=true; } }
      }
      if (haveActive && liveIds.empty()) haveActive=false; // защита
      // Определяем режим более строго:
      // mode 1: есть active (фокусный инстанс)
      // mode 2: нет active, но есть last
      // mode 3: нет вообще живых
      int mode=3; if (!liveIds.empty()) { if (haveActive) mode=1; else if (haveLast) mode=2; else mode=3; }
      SetWindowLongPtr(h,DWLP_USER, mode);
  int btnY = pad + editH + 10; // кнопки на следующей строке
  int leftX=pad; int btnH=22; int cancelW=80; int gap=8; int btnW=110;
      HWND bCurrent=nullptr,bLast=nullptr,bNew=nullptr,bCancel=nullptr;
      if (mode==1){
        bCurrent = CreateWindowExW(0,L"BUTTON",L"Current tab",WS_CHILD|WS_VISIBLE|BS_DEFPUSHBUTTON,leftX,btnY,btnW,btnH,h,(HMENU)IDOK,(HINSTANCE)g_hInst,nullptr); leftX+=btnW+gap;
        bNew = CreateWindowExW(0,L"BUTTON",L"New tab",WS_CHILD|WS_VISIBLE,leftX,btnY,btnW,btnH,h,(HMENU)1002,(HINSTANCE)g_hInst,nullptr); leftX+=btnW+gap;
      } else if (mode==2){
        bLast = CreateWindowExW(0,L"BUTTON",L"Last tab",WS_CHILD|WS_VISIBLE|BS_DEFPUSHBUTTON,leftX,btnY,btnW,btnH,h,(HMENU)1003,(HINSTANCE)g_hInst,nullptr); leftX+=btnW+gap;
        bNew = CreateWindowExW(0,L"BUTTON",L"New tab",WS_CHILD|WS_VISIBLE,leftX,btnY,btnW,btnH,h,(HMENU)1002,(HINSTANCE)g_hInst,nullptr); leftX+=btnW+gap;
      } else { // mode 3
        bNew = CreateWindowExW(0,L"BUTTON",L"Open URL",WS_CHILD|WS_VISIBLE|BS_DEFPUSHBUTTON,leftX,btnY,btnW,btnH,h,(HMENU)IDOK,(HINSTANCE)g_hInst,nullptr); leftX+=btnW+gap;
      }
  int cancelX = dlgW - pad - cancelW; bCancel = CreateWindowExW(0,L"BUTTON",L"Cancel",WS_CHILD|WS_VISIBLE,cancelX,btnY,cancelW,btnH,h,(HMENU)IDCANCEL,(HINSTANCE)g_hInst,nullptr);
  // Финально растянем edit до правого паддинга (не зависит от кнопок, они ниже)
  int newEditW = dlgW - editX - pad; if (newEditW < 120) newEditW = 120; if (hEdit) MoveWindow(hEdit, editX, pad, newEditW, editH, TRUE);
      // Итоговая высота по самой нижней кнопке
      int totalHClient = btnY + btnH + pad;
      // Текущая полная высота окна (включая non-client) и расчёт требуемой полной высоты для обеспечения totalHClient клиентской
      RECT wr{}; GetWindowRect(h,&wr); RECT cr{}; GetClientRect(h,&cr); int curClientH = cr.bottom-cr.top; int curFullH = wr.bottom-wr.top;
      if (curClientH != totalHClient){
        // Увеличиваем/уменьшаем окно сохраняя верхний левый угол
        int delta = totalHClient - curClientH; MoveWindow(h, wr.left, wr.top, wr.right-wr.left, curFullH + delta, TRUE);
      }
      // Применяем шрифт ко всем контролам
      HWND ctrls[] = { hLbl, hEdit, bCurrent, bLast, bNew, bCancel };
      for (HWND c : ctrls) if (c && font) SendMessageW(c, WM_SETFONT, (WPARAM)font, TRUE);
  LogF("[OpenURLDlgLayout] dlgW=%d editX=%d editW=%d pad=%d totalClientH=%d mode=%d", dlgW, editX, newEditW, pad, totalHClient, mode);
      SetWindowTextW(h, L"WebView: Open URL");
      LogF("[OpenURLDlg] init haveActive=%d haveLast=%d liveCount=%d mode=%d", (int)haveActive,(int)haveLast,(int)liveIds.size(),mode);
      if (hEdit) SendMessageW(hEdit, EM_SETSEL, 0, -1);
      // Центрирование относительно главного окна REAPER
      HWND hParent = g_hwndParent ? g_hwndParent : GetForegroundWindow();
      if (hParent) {
        RECT pr; GetWindowRect(hParent,&pr); RECT sr; GetWindowRect(h,&sr);
        int pw = pr.right-pr.left, ph = pr.bottom-pr.top; int sw = sr.right-sr.left, sh = sr.bottom-sr.top;
        int nx = pr.left + (pw - sw)/2; int ny = pr.top + (ph - sh)/2;
        // Без мерцания: только перемещение если вне
        SetWindowPos(h,nullptr,nx,ny,0,0,SWP_NOACTIVATE|SWP_NOSIZE|SWP_NOZORDER);
      }
      return TRUE;
    }
    case WM_COMMAND:
    {
      int id = LOWORD(w);
      if (id==IDOK || id==1002 || id==1003) {
        wchar_t buf[2048]; GetDlgItemTextW(h,1001,buf,2048); std::wstring wurl(buf); std::string url = Narrow(wurl);
        if (url.empty() || url=="https://") { MessageBoxA(h,"URL is empty","WebView",MB_OK|MB_ICONWARNING); return TRUE; }
        LONG_PTR mode = GetWindowLongPtr(h,DWLP_USER);
        std::string instToken;
        if (id==1002) instToken = "random"; // New tab
        else if (id==1003) instToken = "last"; // Last tab button
        else { // IDOK depends on mode
          if (mode==1) instToken = "current"; // haveActive
          else if (mode==2) instToken = "last"; // no active but have last
          else instToken = "random"; // open first when no instances -> random (создаём новый)
        }
        char json[512]; snprintf(json,sizeof(json),"{\"InstanceId\":\"%s\"}",instToken.c_str());
        LogF("[OpenURLDlg] submit mode=%ld btn=%d token='%s' url='%s'", (long)mode,id,instToken.c_str(),url.c_str());
        API_WEBVIEW_Navigate(url.c_str(), json);
        EndDialog(h,1); return TRUE; }
      if (id==IDCANCEL) { EndDialog(h,0); return TRUE; }
      break;
    }
    case WM_CTLCOLORDLG:
    case WM_CTLCOLORSTATIC:
    case WM_CTLCOLORBTN:
    case WM_CTLCOLOREDIT:
    {
      HDC dc = (HDC)w; COLORREF bk,tx; GetPanelThemeColors(h,dc,&bk,&tx); SetTextColor(dc,tx); SetBkColor(dc,bk);
      static HBRUSH hbr=0; if (hbr) DeleteObject(hbr); hbr=CreateSolidBrush(bk); return (INT_PTR)hbr;
    }
  }
  return FALSE;
}
#endif

static bool Act_OpenUrlDialog(int /*flag*/)
{
#ifdef _WIN32
  DLGTEMPLATE dt{}; dt.style=DS_SETFONT|WS_CAPTION|WS_SYSMENU|DS_MODALFRAME; dt.cx=400; dt.cy=85; dt.dwExtendedStyle=0;
  struct Pack { DLGTEMPLATE dt; WORD menu,cls,title,pt; WCHAR font[14]; } pack{}; pack.dt=dt; pack.menu=0; pack.cls=0; pack.title=0; pack.pt=8; lstrcpyW(pack.font,L"MS Shell Dlg");
  INT_PTR r = DialogBoxIndirectParamW((HINSTANCE)g_hInst, &pack.dt, g_hwndParent?g_hwndParent:GetForegroundWindow(), RWVUrlDlgProc, 0);
  LogF("[OpenUrl] dialog result=%lld", (long long)r);
  return r>0;
#else
  @autoreleasepool {
    bool haveActive = !g_activeInstanceId.empty(); bool haveLast = !g_lastFocusedInstanceId.empty();
    if (!haveActive && !haveLast && !g_instances.empty()) {
      WebViewInstanceRecord* best=nullptr; DWORD bestTick=0; for(auto &kv: g_instances){ WebViewInstanceRecord* r=kv.second.get(); if(!r) continue; if(!best || (DWORD)(r->lastFocusTick - bestTick) < 0x80000000UL){ best=r; bestTick=r->lastFocusTick; } } if(best){ g_lastFocusedInstanceId=best->id; haveLast=true; }
    }
    int mode=3; if(haveActive) mode=1; else if(haveLast) mode=2; else mode=3;
    NSRect rc = NSMakeRect(0,0,480,130);
    NSPanel* panel = [[NSPanel alloc] initWithContentRect:rc styleMask:(NSWindowStyleMaskTitled|NSWindowStyleMaskClosable) backing:NSBackingStoreBuffered defer:NO];
    [panel setTitle:@"WebView: Open URL"]; [panel setReleasedWhenClosed:NO]; [panel setLevel:NSModalPanelWindowLevel]; [panel setHidesOnDeactivate:NO];
    NSView* content = [panel contentView]; CGFloat pad=10;
    NSTextField* lbl = [[NSTextField alloc] initWithFrame:NSMakeRect(pad, rc.size.height-34, rc.size.width-2*pad, 20)]; [lbl setBezeled:NO]; [lbl setEditable:NO]; [lbl setDrawsBackground:NO]; [lbl setStringValue:@"Enter URL:"];
    NSTextField* edit = [[NSTextField alloc] initWithFrame:NSMakeRect(pad, rc.size.height-60, rc.size.width-2*pad, 24)]; [edit setStringValue:@"https://"];
    auto makeBtn=^NSButton*(NSString* t, CGFloat x){ NSButton* b=[[NSButton alloc] initWithFrame:NSMakeRect(x,12,120,28)]; [b setTitle:t]; [b setBezelStyle:NSBezelStyleRounded]; return b; };
    NSButton* btn1=nil; NSButton* btn2=nil; CGFloat x=pad; if(mode==1){ btn1=makeBtn(@"Current tab",x); x+=130; btn2=makeBtn(@"New tab",x); x+=130; } else if(mode==2){ btn1=makeBtn(@"Last tab",x); x+=130; btn2=makeBtn(@"New tab",x); x+=130; } else { btn1=makeBtn(@"Open URL",x); x+=130; }
    NSButton* btnCancel=makeBtn(@"Cancel", rc.size.width-pad-120);
    [btn1 setKeyEquivalent:@"\r"]; [btnCancel setKeyEquivalent:@"\e"]; // Enter / Escape
    [content addSubview:lbl]; [content addSubview:edit]; [content addSubview:btn1]; if(btn2)[content addSubview:btn2]; [content addSubview:btnCancel];
    RWVUrlDlgHandler* h = [[RWVUrlDlgHandler alloc] init]; h.panel=panel; h.mode=mode; h.edit=edit; h.btn1=btn1; h.btn2=btn2; h.btnCancel=btnCancel; h.accepted=NO; h.token=nil;
    [btn1 setTarget:h]; [btn1 setAction:@selector(onClick:)]; if(btn2){ [btn2 setTarget:h]; [btn2 setAction:@selector(onClick:)]; } [btnCancel setTarget:h]; [btnCancel setAction:@selector(onClick:)];
    [NSApp runModalForWindow:panel]; bool result=false; if(h.accepted){ NSString* s=[h.edit stringValue]; std::string url=s?[s UTF8String]:""; if(!url.empty() && url!="https://"){ std::string token = h.token? [h.token UTF8String] : "random"; char json[256]; snprintf(json,sizeof(json),"{\"InstanceId\":\"%s\"}", token.c_str()); LogF("[OpenURLDlg][mac] submit mode=%d token='%s' url='%s'", mode, token.c_str(), url.c_str()); API_WEBVIEW_Navigate(url.c_str(), json); result=true; } }
    return result;
  }
#endif
}

