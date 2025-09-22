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

// ======================== Title + Find bar (unified cross-platform logic) =========================
#include "resource.h"

#ifdef _WIN32
  #include <wincodec.h>
#else
 // macOS: Cocoa & CoreGraphics for PNG decoding from embedded arrays
 #import <Cocoa/Cocoa.h>
 #include <CoreGraphics/CoreGraphics.h>
 #include <ImageIO/ImageIO.h>
 #include <dlfcn.h>
 // --- mac shim for certain Win32 symbols used in unified code ---
  #ifndef BI_BITFIELDS
    #define BI_BITFIELDS 3
  #endif
  #ifndef DIB_RGB_COLORS
    #define DIB_RGB_COLORS 0
  #endif
  // Dialog codes (best-effort approximation; SWELL treats them generically)
  #ifndef DLGC_WANTALLKEYS
    #define DLGC_WANTALLKEYS 0x0004
  #endif
  #ifndef DLGC_WANTCHARS
    #define DLGC_WANTCHARS 0x0080
  #endif
  #ifndef DLGC_WANTMESSAGE
    #define DLGC_WANTMESSAGE 0x0004 /* reuse */
  #endif
  #ifndef WM_APP
    #define WM_APP 0x8000
  #endif
  // TrackMouseEvent emulation: SWELL gives basic mouse leave via WM_MOUSEMOVE/out-of-rect, but we define stubs.
  typedef struct tagTRACKMOUSEEVENT { unsigned int cbSize; unsigned int dwFlags; void* hwndTrack; unsigned int dwHoverTime; } TRACKMOUSEEVENT; 
  #ifndef TME_LEAVE
    #define TME_LEAVE 0x00000002
  #endif
  inline bool TrackMouseEvent(TRACKMOUSEEVENT* /*t*/){ return true; }
  // Provide GWLP_ID for GetWindowLongPtr indexing via GWL_ID fallback
  #ifndef GWLP_ID
    #define GWLP_ID GWL_ID
  #endif
  // AlphaBlend: provided by SWELL emulation layer.
#endif // _WIN32 (mac shim end)

#ifndef _WIN32
  // Extra message / control / key shims missing in CI log
  #ifndef WM_MOUSELEAVE
    #define WM_MOUSELEAVE 0x02A3
  #endif
  #ifndef WM_NCCREATE
    #define WM_NCCREATE 0x0081
  #endif
  #ifndef WM_GETDLGCODE
    #define WM_GETDLGCODE 0x0087
  #endif
  #ifndef EM_SETSEL
    #define EM_SETSEL 0x00B1
  #endif
  #ifndef BN_CLICKED
    #define BN_CLICKED 0
  #endif
  #ifndef BM_CLICK
    #define BM_CLICK 0x00F5
  #endif
  #ifndef VK_SHIFT
    #define VK_SHIFT 0x10
  #endif
  #ifndef COLOR_WINDOWTEXT
    #define COLOR_WINDOWTEXT 8
  #endif
  #ifndef HOLLOW_BRUSH
    #define HOLLOW_BRUSH NULL_BRUSH
  #endif
  // Wide API fallbacks -> ANSI SWELL versions
  #define GetWindowTextW GetWindowText
  #define DrawTextW DrawText
  #define CallWindowProcW CallWindowProc
  // Map wide-char variants to ANSI versions in unified code for SWELL
  #define SendMessageW SendMessage
  #define DefWindowProcW DefWindowProc
  #define SetWindowTextW SetWindowText
  // GetKeyState shim (fallback to GetAsyncKeyState if present)
  #ifndef GetKeyState
    #define GetKeyState(k) GetAsyncKeyState(k)
  #endif
    // NOTE: SWELL implements CreateWindowEx directly. Do NOT remap it to CreateWindow (which
    // may be undefined in SWELL builds) — prior remap caused mac build failures.
#endif

static HBITMAP LoadPngStripFromResource(int resId, int* outW, int* outH){
#ifdef _WIN32
  // Windows: decode from RT_RCDATA resource via WIC
  *outW=0; *outH=0; HRSRC hr = FindResource((HINSTANCE)g_hInst, MAKEINTRESOURCE(resId), RT_RCDATA); if(!hr) return nullptr; HGLOBAL hg = LoadResource((HINSTANCE)g_hInst, hr); if(!hg) return nullptr; DWORD sz = SizeofResource((HINSTANCE)g_hInst, hr); void* data = LockResource(hg); if(!data || !sz) return nullptr; IWICImagingFactory* fac=nullptr; if (FAILED(CoCreateInstance(CLSID_WICImagingFactory,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&fac)))) return nullptr; IWICStream* stream=nullptr; if (FAILED(fac->CreateStream(&stream))){ fac->Release(); return nullptr; } if (FAILED(stream->InitializeFromMemory((BYTE*)data, sz))){ stream->Release(); fac->Release(); return nullptr; } if(!sz){ stream->Release(); fac->Release(); return nullptr; } IWICBitmapDecoder* dec=nullptr; if (FAILED(fac->CreateDecoderFromStream(stream,nullptr,WICDecodeMetadataCacheOnLoad,&dec))){ stream->Release(); fac->Release(); return nullptr; } IWICBitmapFrameDecode* frame=nullptr; dec->GetFrame(0,&frame); IWICFormatConverter* conv=nullptr; fac->CreateFormatConverter(&conv); conv->Initialize(frame, GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone,nullptr,0.0, WICBitmapPaletteTypeCustom); UINT w=0,h=0; frame->GetSize(&w,&h); *outW=(int)w; *outH=(int)h; BITMAPV5HEADER bi{}; bi.bV5Size=sizeof(bi); bi.bV5Width=w; bi.bV5Height=-(int)h; bi.bV5Planes=1; bi.bV5BitCount=32; bi.bV5Compression=BI_BITFIELDS; bi.bV5RedMask=0x00FF0000; bi.bV5GreenMask=0x0000FF00; bi.bV5BlueMask=0x000000FF; bi.bV5AlphaMask=0xFF000000; void* bits=nullptr; HDC hdc=GetDC(nullptr); HBITMAP hbmp=CreateDIBSection(hdc,(BITMAPINFO*)&bi,DIB_RGB_COLORS,&bits,nullptr,0); ReleaseDC(nullptr,hdc); if(hbmp && bits){ conv->CopyPixels(nullptr,w*4,(UINT)(w*h*4),(BYTE*)bits); } if(conv) conv->Release(); if(frame) frame->Release(); if(dec) dec->Release(); if(stream) stream->Release(); if(fac) fac->Release(); return hbmp; 
 #else
  // macOS: decode from embedded resource arrays (generated by compile_resources.py)
  *outW=0; *outH=0;
  const char* name=nullptr;
  switch(resId){
    case IDR_PNG_SEARCH_PREV: name="search_prev.png"; break;
    case IDR_PNG_SEARCH_NEXT: name="search_next.png"; break;
    default: return nullptr;
  }
  #ifdef __has_include
  #if __has_include("embedded_resources.h")
    #include "embedded_resources.h"
  #endif
  #endif
  #ifdef EmbeddedResId_Count
    const EmbeddedResource* er = GetEmbeddedResourceByName(name);
    if(!er || ! er->data || er->size==0) return nullptr;
    CFDataRef cfdata = CFDataCreate(kCFAllocatorDefault, (const UInt8*)er->data, (CFIndex)er->size);
    if(!cfdata) return nullptr;
    CGImageSourceRef src = CGImageSourceCreateWithData(cfdata, nullptr);
    if(!src){ CFRelease(cfdata); return nullptr; }
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, nullptr);
    CFRelease(src);
    if(!img){ CFRelease(cfdata); return nullptr; }
    size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
    if(!w || !h){ CGImageRelease(img); CFRelease(cfdata); return nullptr; }
    *outW=(int)w; *outH=(int)h;
    // Create 32-bit premultiplied BGRA buffer matching Windows expectation
    BITMAPINFO bi{}; bi.bmiHeader.biSize=sizeof(BITMAPINFOHEADER); bi.bmiHeader.biWidth=(LONG)w; bi.bmiHeader.biHeight=-(LONG)h; bi.bmiHeader.biPlanes=1; bi.bmiHeader.biBitCount=32; bi.bmiHeader.biCompression=BI_RGB; void* bits=nullptr;
    HDC hdc = GetDC(nullptr); HBITMAP hbmp = CreateDIBSection(hdc,&bi,DIB_RGB_COLORS,&bits,nullptr,0); ReleaseDC(nullptr,hdc);
    if(!hbmp || !bits){ if(hbmp) DeleteObject(hbmp); CGImageRelease(img); CFRelease(cfdata); return nullptr; }
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(bits, w, h, 8, w*4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
    CGColorSpaceRelease(cs);
    if(!ctx){ DeleteObject(hbmp); CGImageRelease(img); CFRelease(cfdata); return nullptr; }
    CGRect rect = CGRectMake(0,0,(CGFloat)w,(CGFloat)h);
    CGContextDrawImage(ctx, rect, img);
    CGContextRelease(ctx);
    CGImageRelease(img); CFRelease(cfdata);
    return hbmp;
  #else
    return nullptr; // embedded headers not present
  #endif
 #endif
  }

// (Убрано: отдельная Mac Objective-C реализация панелей; теперь единая Windows-стиль логика через SWELL.)
static void DestroyTitleBarResources(WebViewInstanceRecord* rec);
static void EnsureTitleBarCreated(HWND hwnd);
void LayoutTitleBarAndWebView(HWND hwnd, bool titleVisible); // exported across TUs
static void SetTitleBarText(HWND hwnd, const std::string& s);
static LRESULT CALLBACK RWVTitleBarProc(HWND h, UINT m, WPARAM w, LPARAM l);
// Find bar (Windows) forward declarations
static void EnsureFindBarCreated(HWND hwnd);
static void UpdateFindCounter(WebViewInstanceRecord* rec);

// Control IDs (child controls for find bar) MUST be defined before any usage
#ifndef IDC_FIND_EDIT
#define IDC_FIND_EDIT     2101
#define IDC_FIND_PREV     2102
#define IDC_FIND_NEXT     2103
#define IDC_FIND_CASE     2104
#define IDC_FIND_HILITE   2105
#define IDC_FIND_COUNTER  2106
#define IDC_FIND_CLOSE    2107
#endif

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
static DWORD g_findLastEnterTick = 0; // timestamp of last Enter press in find edit
static bool  g_findEnterActive = false; // true while we suppress focus changes
// Custom message for deferred refocus after handling Enter inside find edit
static const UINT WM_RWV_FIND_REFOCUS = WM_APP + 0x452;
#ifdef _WIN32
static HHOOK g_rwvMsgHook = nullptr; // message hook to pre-swallow VK_RETURN (Win only)
#endif
static HWND  g_lastFindEdit = nullptr; // last known find edit hwnd
// Simple inline navigation (placeholder for real search logic) to avoid button focus side-effects
static void RWV_FindNavigateInline(WebViewInstanceRecord* rec, bool fwd)
{
  if (!rec) return;
  LogF("[Find] nav %s (inline) query='%s'", fwd?"next":"prev", rec->findQuery.c_str());
  // Future: update indices and call UpdateFindCounter(rec) after search results
}
static LRESULT CALLBACK RWVFindEditProc(HWND h, UINT m, WPARAM w, LPARAM l)
{
  switch(m){
    case WM_GETDLGCODE:
      return DLGC_WANTALLKEYS | DLGC_WANTCHARS | DLGC_WANTMESSAGE;
    case WM_SETFOCUS:
      LogRaw("[FindFocus] edit WM_SETFOCUS");
      g_lastFindEdit = h;
      break;
    case WM_KEYDOWN:
      if (w==VK_RETURN){
        HWND host = GetParent(GetParent(h));
        WebViewInstanceRecord* rec = GetInstanceByHwnd(host);
        bool shift = (GetKeyState(VK_SHIFT)&0x8000)!=0;
        if (rec){
          bool fwd = !shift;
          g_findEnterActive = true; g_findLastEnterTick = GetTickCount();
          RWV_FindNavigateInline(rec, fwd);
          SetFocus(h);
          SendMessageW(h, EM_SETSEL, (WPARAM)-1, (LPARAM)-1);
          HWND findBar = GetParent(h);
          if (findBar && IsWindow(findBar)) PostMessage(findBar, WM_RWV_FIND_REFOCUS, (WPARAM)h, 0);
          return 0;
        }
      }
      break;
    case WM_CHAR:
      if (w=='\r') return 0; // swallow CR so no default button processing
      break;
    case WM_KEYUP:
      if (w==VK_RETURN) g_findEnterActive=false;
      break;
    case WM_KILLFOCUS:
      LogRaw("[FindFocus] edit WM_KILLFOCUS");
      if (g_findEnterActive && GetTickCount()-g_findLastEnterTick < 250){
        SetFocus(h);
        SendMessageW(h, EM_SETSEL, (WPARAM)-1, (LPARAM)-1);
        return 0;
      }
      break;
  }
#ifdef _WIN32
  return CallWindowProcW(s_origFindEditProc,h,m,w,l);
#else
  return CallWindowProc(s_origFindEditProc? s_origFindEditProc : DefWindowProc, h,m,w,l);
#endif
}

static void DestroyTitleBarResources(WebViewInstanceRecord* rec)
{
  if (!rec) return;
#ifdef _WIN32
  if (rec->titleFont){ DeleteObject(rec->titleFont); rec->titleFont=nullptr; }
  if (rec->titleBrush){ DeleteObject(rec->titleBrush); rec->titleBrush=nullptr; }
  if (rec->titleBar && IsWindow(rec->titleBar)){ DestroyWindow(rec->titleBar); rec->titleBar=nullptr; }
#else
  // macOS: title bar handled differently (no GDI resources to destroy)
#endif
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
#ifdef _WIN32
      COLORREF bk, tx; GetPanelThemeColors(h, dc, &bk, &tx);
      if (rec){ if (rec->titleBkColor!=bk){ rec->titleBkColor=bk; if(rec->titleBrush){ DeleteObject(rec->titleBrush); rec->titleBrush=nullptr; }} rec->titleTextColor=tx; if(!rec->titleBrush) rec->titleBrush=CreateSolidBrush(bk);} 
      HBRUSH fill = (rec && rec->titleBrush)?rec->titleBrush:(HBRUSH)(COLOR_BTNFACE+1);
      FillRect(dc,&r,fill); SetBkMode(dc,TRANSPARENT); SetTextColor(dc,tx);
      HFONT oldF = nullptr; if (rec && rec->titleFont) oldF = (HFONT)SelectObject(dc, rec->titleFont);
#else
      // mac: reuse cached colors or fetch once
      COLORREF bk = GetSysColor(COLOR_BTNFACE);
      COLORREF tx = GetSysColor(COLOR_WINDOWTEXT);
      if (rec){ if (rec->titleBkColor<0 || rec->titleTextColor<0){ int bgi=-1,txi=-1; GetPanelThemeColorsMac(&bgi,&txi); if(bgi>=0) rec->titleBkColor=bgi; if(txi>=0) rec->titleTextColor=txi; }
        if (rec->titleBkColor>=0) bk=(COLORREF)rec->titleBkColor; if(rec->titleTextColor>=0) tx=(COLORREF)rec->titleTextColor; }
      HBRUSH fill = CreateSolidBrush(bk);
      FillRect(dc,&r,fill); DeleteObject(fill); SetBkMode(dc,TRANSPARENT); SetTextColor(dc,tx);
      HFONT oldF = nullptr; // no custom font on mac path
#endif
      #ifdef _WIN32
        WCHAR buf[512]; GetWindowTextW(h,buf,512); RECT tr=r; tr.left+=g_titlePadX; DrawTextW(dc,buf,-1,&tr,DT_SINGLELINE|DT_VCENTER|DT_LEFT|DT_NOPREFIX|DT_END_ELLIPSIS);
      #else
        char buf[512]; GetWindowText(h,buf,512); RECT tr=r; tr.left+=g_titlePadX; DrawText(dc,buf,-1,&tr,DT_SINGLELINE|DT_VCENTER|DT_LEFT|DT_NOPREFIX|DT_END_ELLIPSIS);
      #endif
      if (oldF) SelectObject(dc, oldF);
      EndPaint(h,&ps);
      if (rec && rec->findBarWnd) { // sync children colors
        InvalidateRect(rec->findBarWnd,nullptr,TRUE);
        HWND kids[9] = { rec->findEdit, rec->findBtnPrev, rec->findBtnNext, rec->findChkCase, rec->findLblCase, rec->findChkHighlight, rec->findLblHighlight, rec->findCounterStatic, rec->findBtnClose };
        for (int i=0;i<9;++i) if (kids[i]) InvalidateRect(kids[i],nullptr,TRUE);
      }
      return 0;
    }
  }
  return DefWindowProcW(h,m,w,l);
}

static LRESULT CALLBACK RWVTitleBarSubclassProc(HWND h, UINT m, WPARAM w, LPARAM l){ return RWVTitleBarProc(h,m,w,l); }
static void EnsureTitleBarCreated(HWND hwnd)
{
  WebViewInstanceRecord* rec = GetInstanceByHwnd(hwnd); if(!rec) return; if (rec->titleBar && !IsWindow(rec->titleBar)) rec->titleBar=nullptr; if(rec->titleBar) return;
#ifdef _WIN32
  static bool s_reg=false; if(!s_reg){ WNDCLASSW wc{}; memset(&wc,0,sizeof(wc)); wc.lpfnWndProc=RWVTitleBarProc; wc.hInstance=(HINSTANCE)g_hInst; wc.lpszClassName=L"RWVTitleBar"; wc.hCursor=LoadCursor(nullptr,IDC_ARROW); wc.hbrBackground=NULL; RegisterClassW(&wc); s_reg=true; }
  LOGFONTW lf{}; SystemParametersInfoW(SPI_GETICONTITLELOGFONT,sizeof(lf),&lf,0); rec->titleFont=CreateFontIndirectW(&lf);
  rec->titleBar = CreateWindowExW(0,L"RWVTitleBar",L"",WS_CHILD,0,0,10,g_titleBarH,hwnd,(HMENU)(INT_PTR)IDC_TITLEBAR,(HINSTANCE)g_hInst,nullptr);
  if(rec->titleBar && rec->titleFont) SendMessageW(rec->titleBar,WM_SETFONT,(WPARAM)rec->titleFont,TRUE);
#else
  rec->titleBar = CreateWindowEx(0,"static","",WS_CHILD,0,0,10,(int)g_titleBarH,hwnd,(HMENU)(INT_PTR)IDC_TITLEBAR,(HINSTANCE)g_hInst,nullptr);
  if(rec->titleBar){ SetWindowLongPtr(rec->titleBar,GWLP_WNDPROC,(LONG_PTR)RWVTitleBarSubclassProc); }
#endif
}

// Ensure creation of the find bar and its child controls (Windows only)
static LRESULT CALLBACK RWVFindBarSubclassProc(HWND h, UINT m, WPARAM w, LPARAM l){ return RWVFindBarProc(h,m,w,l); }
static void EnsureFindBarCreated(HWND hwnd)
{
  WebViewInstanceRecord* rec = GetInstanceByHwnd(hwnd); if(!rec) return;
  if (rec->findBarWnd && !IsWindow(rec->findBarWnd)) rec->findBarWnd = nullptr;
  if (rec->findBarWnd) return;
#ifdef _WIN32
  static bool s_reg=false; if(!s_reg){ WNDCLASSW wc{}; memset(&wc,0,sizeof(wc)); wc.lpfnWndProc=RWVFindBarProc; wc.hInstance=(HINSTANCE)g_hInst; wc.lpszClassName=L"RWVFindBar"; wc.hCursor=LoadCursor(nullptr,IDC_ARROW); wc.hbrBackground=NULL; RegisterClassW(&wc); s_reg=true; }
  rec->findBarWnd = CreateWindowExW(0, L"RWVFindBar", L"", WS_CHILD|WS_CLIPCHILDREN|WS_CLIPSIBLINGS,
                                   0,0,10,g_findBarH, hwnd, (HMENU)(INT_PTR)3002, (HINSTANCE)g_hInst, nullptr);
#else
  rec->findBarWnd = CreateWindowEx(0, "static", "", WS_CHILD|WS_CLIPCHILDREN|WS_CLIPSIBLINGS,
                                   0,0,10,(int)g_findBarH, hwnd, (HMENU)(INT_PTR)3002, (HINSTANCE)g_hInst, nullptr);
  if (rec->findBarWnd) SetWindowLongPtr(rec->findBarWnd,GWLP_WNDPROC,(LONG_PTR)RWVFindBarSubclassProc);
#endif
  if (!rec->findBarWnd) return;

  int h=g_findBarH-8; if (h<16) h=16; int y=4;
  rec->findEdit =
#ifdef _WIN32
    CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"", WS_CHILD|WS_TABSTOP|ES_AUTOHSCROLL, 0,y,180,h, rec->findBarWnd,(HMENU)(INT_PTR)IDC_FIND_EDIT,(HINSTANCE)g_hInst,nullptr);
#else
  CreateWindowEx(0, "EDIT", "", WS_CHILD|WS_TABSTOP|ES_AUTOHSCROLL, 0,y,180,h, rec->findBarWnd,(HMENU)(INT_PTR)IDC_FIND_EDIT,(HINSTANCE)g_hInst,nullptr);
#endif
  int btnSize = h;
  static bool s_navReg=false; if(!s_navReg){
#ifdef _WIN32
      WNDCLASSW wc{}; wc.lpfnWndProc=[](HWND hWnd, UINT m, WPARAM w, LPARAM l)->LRESULT{
        int cid = (int)GetWindowLongPtr(hWnd,GWLP_ID); bool isPrev = (cid==IDC_FIND_PREV);
        WebViewInstanceRecord* recLocal = GetInstanceByHwnd(GetParent(GetParent(hWnd)));
        if(!recLocal) return DefWindowProcW(hWnd,m,w,l);
        bool &hot = isPrev? recLocal->prevHot : recLocal->nextHot;
        bool &down = isPrev? recLocal->prevDown : recLocal->nextDown;
        switch(m){
          case WM_MOUSEMOVE:{ if(!hot){ hot=true; InvalidateRect(hWnd,nullptr,FALSE);} TRACKMOUSEEVENT t{sizeof(t),TME_LEAVE,hWnd,0}; TrackMouseEvent(&t); return 0; }
          case WM_MOUSELEAVE:{ if(hot){ hot=false; InvalidateRect(hWnd,nullptr,FALSE);} return 0; }
          case WM_LBUTTONDOWN:{ SetCapture(hWnd); if(!down){ down=true; InvalidateRect(hWnd,nullptr,FALSE);} return 0; }
          case WM_LBUTTONUP:{ if(GetCapture()==hWnd) ReleaseCapture(); bool wasDown=down; if(down){ down=false; InvalidateRect(hWnd,nullptr,FALSE);} POINT pt{(SHORT)LOWORD(l),(SHORT)HIWORD(l)}; RECT rc; GetClientRect(hWnd,&rc); if(wasDown && PtInRect(&rc,pt)){ HWND host = GetParent(GetParent(hWnd)); if(host) SendMessageW(host, WM_COMMAND, MAKEWPARAM(cid, BN_CLICKED), (LPARAM)hWnd);} return 0; }
          case WM_ERASEBKGND: return 1;
          case WM_PAINT:{ PAINTSTRUCT ps; HDC dc=BeginPaint(hWnd,&ps); RECT rc; GetClientRect(hWnd,&rc); int box=24; RECT r=rc; int wC=rc.right-rc.left; int hC=rc.bottom-rc.top; if(wC>box){ int dx=(wC-box)/2; r.left+=dx; r.right=r.left+box; } if(hC>box){ int dy=(hC-box)/2; r.top+=dy; r.bottom=r.top+box; }
            COLORREF panelCol = recLocal->titleBkColor ? recLocal->titleBkColor : GetSysColor(COLOR_BTNFACE);
            if(!recLocal->titleBkColor){ COLORREF bkTmp, txTmp; GetPanelThemeColors(GetParent(hWnd), dc, &bkTmp, &txTmp); panelCol=bkTmp; recLocal->titleBkColor=bkTmp; recLocal->titleTextColor=txTmp; }
            HDC memDC = CreateCompatibleDC(dc); HBITMAP memBmp = CreateCompatibleBitmap(dc, rc.right-rc.left, rc.bottom-rc.top); HGDIOBJ oldBmp = SelectObject(memDC, memBmp);
            HBRUSH br = CreateSolidBrush(panelCol); FillRect(memDC,&rc,br); DeleteObject(br);
            HBITMAP bmp = isPrev? recLocal->bmpPrev : recLocal->bmpNext; int bw = isPrev? recLocal->bmpPrevW : recLocal->bmpNextW; int bh = isPrev? recLocal->bmpPrevH : recLocal->bmpNextH;
            int frames = (bw>0 && bh>0 && (bw%3)==0)?3:1; int frameW=(frames==3)?bw/3:bw; int frameH=bh; int stateIndex=0; if(down) stateIndex=2; else if(hot) stateIndex=1; bool drew=false;
#ifdef _WIN32
            if(frames==3 && bmp){ HDC mem=CreateCompatibleDC(memDC); HGDIOBJ old=SelectObject(mem,bmp); int dx=r.left+((r.right-r.left)-frameW)/2; int dy=r.top+((r.bottom-r.top)-frameH)/2; if(down){ dx++; dy++; } BLENDFUNCTION bf{AC_SRC_OVER,0,255,AC_SRC_ALPHA}; AlphaBlend(memDC,dx,dy,frameW,frameH,mem,stateIndex*frameW,0,frameW,frameH,bf); SelectObject(mem,old); DeleteDC(mem); drew=true; }
#endif
            if(!drew){ auto clampC=[](int v){ return v<0?0:(v>255?255:v); }; auto shade=[&](COLORREF c,int d){ int R=clampC(GetRValue(c)+d),G=clampC(GetGValue(c)+d),B=clampC(GetBValue(c)+d); return RGB(R,G,B); }; COLORREF base=RGB(180,180,180); if(hot) base=shade(base,+40); if(down) base=shade(base,-50); POINT tri[3]; int cx=(r.left+r.right)/2; int cy=(r.top+r.bottom)/2; int sz=8; if(isPrev){ tri[0]={cx,cy-sz}; tri[1]={cx-sz,cy+sz}; tri[2]={cx+sz,cy+sz}; } else { tri[0]={cx-sz,cy-sz}; tri[1]={cx+sz,cy}; tri[2]={cx-sz,cy+sz}; } HBRUSH bA=CreateSolidBrush(base); HPEN pA=CreatePen(PS_SOLID,1,shade(base,-60)); HGDIOBJ oP=SelectObject(memDC,pA); HGDIOBJ oB=SelectObject(memDC,bA); Polygon(memDC,tri,3); SelectObject(memDC,oB); SelectObject(memDC,oP); DeleteObject(bA); DeleteObject(pA); }
            if(hot||down){ HPEN penO=CreatePen(PS_SOLID,1,RGB(128,128,128)); HGDIOBJ oP=SelectObject(memDC,penO); HGDIOBJ oB=SelectObject(memDC,GetStockObject(HOLLOW_BRUSH)); RoundRect(memDC,r.left,r.top,r.right-1,r.bottom-1,4,4); SelectObject(memDC,oB); SelectObject(memDC,oP); DeleteObject(penO);} BitBlt(dc,0,0,rc.right-rc.left,rc.bottom-rc.top,memDC,0,0,SRCCOPY); SelectObject(memDC,oldBmp); DeleteObject(memBmp); DeleteDC(memDC); EndPaint(hWnd,&ps); return 0; }
        }
        return DefWindowProcW(hWnd,m,w,l);
      }; wc.hInstance=(HINSTANCE)g_hInst; wc.lpszClassName=L"RWVNavBtn"; wc.hCursor=LoadCursor(nullptr,IDC_ARROW); wc.hbrBackground=NULL; RegisterClassW(&wc); s_navReg=true;
#endif
  }
#ifdef _WIN32
  rec->findBtnPrev = CreateWindowExW(0,L"RWVNavBtn",L"",WS_CHILD,0,y,btnSize,h, rec->findBarWnd,(HMENU)(INT_PTR)IDC_FIND_PREV,(HINSTANCE)g_hInst,nullptr);
  rec->findBtnNext = CreateWindowExW(0,L"RWVNavBtn",L"",WS_CHILD,0,y,btnSize,h, rec->findBarWnd,(HMENU)(INT_PTR)IDC_FIND_NEXT,(HINSTANCE)g_hInst,nullptr);
#else
  rec->findBtnPrev = CreateWindowEx(0, "BUTTON", "<", WS_CHILD|WS_TABSTOP, 0,y,btnSize,h, rec->findBarWnd,(HMENU)(INT_PTR)IDC_FIND_PREV,(HINSTANCE)g_hInst,nullptr);
  rec->findBtnNext = CreateWindowEx(0, "BUTTON", ">", WS_CHILD|WS_TABSTOP, 0,y,btnSize,h, rec->findBarWnd,(HMENU)(INT_PTR)IDC_FIND_NEXT,(HINSTANCE)g_hInst,nullptr);
#endif

#ifdef _WIN32
  HRESULT coHr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED); (void)coHr;
#endif
  // Load PNG strips (Windows: from .rc, mac: from embedded arrays)
  rec->bmpPrev = LoadPngStripFromResource(IDR_PNG_SEARCH_PREV, &rec->bmpPrevW, &rec->bmpPrevH);
  if(!rec->bmpPrev) LogRaw("[FindNavImg] FAILED PREV strip"); else LogF("[FindNavImg] OK PREV w=%d h=%d", rec->bmpPrevW, rec->bmpPrevH);
  rec->bmpNext = LoadPngStripFromResource(IDR_PNG_SEARCH_NEXT, &rec->bmpNextW, &rec->bmpNextH);
  if(!rec->bmpNext) LogRaw("[FindNavImg] FAILED NEXT strip"); else LogF("[FindNavImg] OK NEXT w=%d h=%d", rec->bmpNextW, rec->bmpNextH);

#ifdef _WIN32
  rec->findChkCase = CreateWindowExW(0,L"BUTTON",L"",WS_CHILD|BS_AUTOCHECKBOX,0,y,18,h, rec->findBarWnd,(HMENU)(INT_PTR)IDC_FIND_CASE,(HINSTANCE)g_hInst,nullptr);
  rec->findLblCase = CreateWindowExW(0,L"STATIC",L"Case Sensitive",WS_CHILD|SS_CENTERIMAGE,0,y,110,h, rec->findBarWnd,nullptr,(HINSTANCE)g_hInst,nullptr);
  rec->findChkHighlight = CreateWindowExW(0,L"BUTTON",L"",WS_CHILD|BS_AUTOCHECKBOX,0,y,18,h, rec->findBarWnd,(HMENU)(INT_PTR)IDC_FIND_HILITE,(HINSTANCE)g_hInst,nullptr);
  rec->findLblHighlight = CreateWindowExW(0,L"STATIC",L"Highlight All",WS_CHILD|SS_CENTERIMAGE,0,y,100,h, rec->findBarWnd,nullptr,(HINSTANCE)g_hInst,nullptr);
  rec->findCounterStatic = CreateWindowExW(0,L"STATIC",L"0/0",WS_CHILD|SS_CENTERIMAGE,0,y,60,h, rec->findBarWnd,(HMENU)(INT_PTR)IDC_FIND_COUNTER,(HINSTANCE)g_hInst,nullptr);
  rec->findBtnClose = CreateWindowExW(0,L"BUTTON",L"X",WS_CHILD|WS_TABSTOP|BS_PUSHBUTTON,0,y,24,h, rec->findBarWnd,(HMENU)(INT_PTR)IDC_FIND_CLOSE,(HINSTANCE)g_hInst,nullptr);
#else
  rec->findChkCase = CreateWindowEx(0,"BUTTON","",WS_CHILD|BS_AUTOCHECKBOX,0,y,18,h, rec->findBarWnd,(HMENU)(INT_PTR)IDC_FIND_CASE,(HINSTANCE)g_hInst,nullptr);
  rec->findLblCase = CreateWindowEx(0,"STATIC","Case Sensitive",WS_CHILD|SS_CENTERIMAGE,0,y,110,h, rec->findBarWnd,nullptr,(HINSTANCE)g_hInst,nullptr);
  rec->findChkHighlight = CreateWindowEx(0,"BUTTON","",WS_CHILD|BS_AUTOCHECKBOX,0,y,18,h, rec->findBarWnd,(HMENU)(INT_PTR)IDC_FIND_HILITE,(HINSTANCE)g_hInst,nullptr);
  rec->findLblHighlight = CreateWindowEx(0,"STATIC","Highlight All",WS_CHILD|SS_CENTERIMAGE,0,y,100,h, rec->findBarWnd,nullptr,(HINSTANCE)g_hInst,nullptr);
  rec->findCounterStatic = CreateWindowEx(0,"STATIC","0/0",WS_CHILD|SS_CENTERIMAGE,0,y,60,h, rec->findBarWnd,(HMENU)(INT_PTR)IDC_FIND_COUNTER,(HINSTANCE)g_hInst,nullptr);
  rec->findBtnClose = CreateWindowEx(0,"BUTTON","X",WS_CHILD|WS_TABSTOP|BS_PUSHBUTTON,0,y,24,h, rec->findBarWnd,(HMENU)(INT_PTR)IDC_FIND_CLOSE,(HINSTANCE)g_hInst,nullptr);
#endif

  HFONT useFont = nullptr;
#ifdef _WIN32
  useFont = rec->titleFont ? rec->titleFont : (HFONT)SendMessage(hwnd, WM_GETFONT,0,0);
#endif
  HWND ctrls[] = { rec->findEdit, rec->findBtnPrev, rec->findBtnNext, rec->findChkCase, rec->findLblCase, rec->findChkHighlight, rec->findLblHighlight, rec->findCounterStatic, rec->findBtnClose };
  for (HWND c : ctrls) if (c && useFont) SendMessage(c, WM_SETFONT, (WPARAM)useFont, TRUE);
  if (rec->findChkCase) {
#ifdef _WIN32
    RECT rc; GetWindowRect(rec->findChkCase,&rc); POINT pt{rc.left,rc.top}; ScreenToClient(rec->findBarWnd,&pt); int w=rc.right-rc.left, h2=rc.bottom-rc.top;
    HWND ov = CreateWindowExW(0,L"STATIC",L"",WS_CHILD|SS_NOTIFY,pt.x,pt.y,w,h2,rec->findBarWnd,(HMENU)(INT_PTR)(IDC_FIND_CASE+1000),(HINSTANCE)g_hInst,nullptr); if(ov) ShowWindow(ov,SW_SHOWNA);
#endif
  }
  if (rec->findChkHighlight) {
#ifdef _WIN32
    RECT rc; GetWindowRect(rec->findChkHighlight,&rc); POINT pt{rc.left,rc.top}; ScreenToClient(rec->findBarWnd,&pt); int w=rc.right-rc.left, h2=rc.bottom-rc.top;
    HWND ov = CreateWindowExW(0,L"STATIC",L"",WS_CHILD|SS_NOTIFY,pt.x,pt.y,w,h2,rec->findBarWnd,(HMENU)(INT_PTR)(IDC_FIND_HILITE+1000),(HINSTANCE)g_hInst,nullptr); if(ov) ShowWindow(ov,SW_SHOWNA);
#endif
  }
  if (rec->findEdit && !s_origFindEditProc) s_origFindEditProc = (WNDPROC)SetWindowLongPtr(rec->findEdit, GWLP_WNDPROC, (LONG_PTR)RWVFindEditProc);
#ifdef _WIN32
  if (rec->findBtnPrev && !s_origPrevBtnProc) s_origPrevBtnProc = (WNDPROC)SetWindowLongPtr(rec->findBtnPrev, GWLP_WNDPROC, (LONG_PTR)RWVNavBtnProc);
  if (rec->findBtnNext && !s_origNextBtnProc) s_origNextBtnProc = (WNDPROC)SetWindowLongPtr(rec->findBtnNext, GWLP_WNDPROC, (LONG_PTR)RWVNavBtnProc);
#endif
  ShowWindow(rec->findBarWnd, SW_HIDE); for (HWND c: ctrls) if(c) ShowWindow(c,SW_HIDE);
  LogRaw("[Find] Created unified find bar controls");
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
#ifdef _WIN32
      if (rec && rec->titleBrush){ bk = rec->titleBkColor; tx = rec->titleTextColor; }
      else { GetPanelThemeColors(h, dc, &bk, &tx); if (rec){ rec->titleBkColor=bk; rec->titleTextColor=tx; if(!rec->titleBrush) rec->titleBrush=CreateSolidBrush(bk);} }
      HBRUSH br = CreateSolidBrush(bk); FillRect(dc,&r,br); DeleteObject(br);
#else
      if (rec){ if(rec->titleBkColor<0 || rec->titleTextColor<0){ int bgi=-1,txi=-1; GetPanelThemeColorsMac(&bgi,&txi); if(bgi>=0) rec->titleBkColor=bgi; if(txi>=0) rec->titleTextColor=txi; } if(rec->titleBkColor>=0) bk=(COLORREF)rec->titleBkColor; if(rec->titleTextColor>=0) tx=(COLORREF)rec->titleTextColor; }
      HBRUSH br = CreateSolidBrush(bk); FillRect(dc,&r,br); DeleteObject(br);
#endif
      // force children redraw for color sync
      if (rec){ HWND kids[7]={rec->findChkCase,rec->findLblCase,rec->findChkHighlight,rec->findLblHighlight,rec->findBtnPrev,rec->findBtnNext,rec->findCounterStatic}; for (HWND c: kids) if (c) InvalidateRect(c,nullptr,TRUE);}      
      EndPaint(h,&ps); return 0;
    }
    case WM_COMMAND:
    {
      HWND host = GetParent(h);
      int cid = LOWORD(w);
      WebViewInstanceRecord* rec = GetInstanceByHwnd(host);
      // Overlay statics map to underlying checkboxes
      if (cid==IDC_FIND_CASE+1000 && rec && rec->findChkCase){ SendMessage(rec->findChkCase,BM_CLICK,0,0); if(rec->findEdit) PostMessage(h, WM_RWV_FIND_REFOCUS,(WPARAM)rec->findEdit,0); return 0; }
      if (cid==IDC_FIND_HILITE+1000 && rec && rec->findChkHighlight){ SendMessage(rec->findChkHighlight,BM_CLICK,0,0); if(rec->findEdit) PostMessage(h, WM_RWV_FIND_REFOCUS,(WPARAM)rec->findEdit,0); return 0; }
      if (host) return (LRESULT)SendMessageW(host, m, w, l);
      break;
    }
  case WM_DRAWITEM:
  {
#ifdef _WIN32
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
#endif // _WIN32 owner-draw
      break;
    case WM_LBUTTONDOWN:
    {
  WebViewInstanceRecord* rec = GetInstanceByHwnd(GetParent(h));
#ifdef _WIN32
  POINT pt{ (SHORT)LOWORD(l), (SHORT)HIWORD(l) }; HWND child = ChildWindowFromPointEx(h, pt, CWP_SKIPTRANSPARENT|CWP_SKIPINVISIBLE|CWP_SKIPDISABLED);
  if (rec){
    auto hitInBox=[&](HWND btn){ if(!btn) return false; RECT rc; GetClientRect(btn,&rc); int box=24; int w=rc.right-rc.left; int h2=rc.bottom-rc.top; RECT inner=rc; if(w>box){ int dx=(w-box)/2; inner.left+=dx; inner.right=inner.left+box; } if(h2>box){ int dy=(h2-box)/2; inner.top+=dy; inner.bottom=inner.top+box; } POINT local=pt; MapWindowPoints(h,btn,&local,1); return PtInRect(&inner,local)!=0; };
    if(child==rec->findBtnPrev && hitInBox(rec->findBtnPrev)){ rec->prevDown=true; InvalidateRect(rec->findBtnPrev,nullptr,TRUE); }
    else if(child==rec->findBtnNext && hitInBox(rec->findBtnNext)){ rec->nextDown=true; InvalidateRect(rec->findBtnNext,nullptr,TRUE); }
    if (child == rec->findLblCase && rec->findChkCase){ SendMessage(rec->findChkCase, BM_CLICK, 0, 0); if(rec->findEdit) SetFocus(rec->findEdit); return 0; }
    if (child == rec->findLblHighlight && rec->findChkHighlight){ SendMessage(rec->findChkHighlight, BM_CLICK, 0, 0); if(rec->findEdit) SetFocus(rec->findEdit); return 0; }
  }
#else
  // mac/SWELL: rely on native button behavior; only handle label clicks -> toggle checkbox
  if (rec){
    HWND child = (HWND)w; // simplistic fallback (no precise hit test)
    if (child == rec->findLblCase && rec->findChkCase){ SendMessage(rec->findChkCase, BM_CLICK, 0, 0); if(rec->findEdit) SetFocus(rec->findEdit); return 0; }
    if (child == rec->findLblHighlight && rec->findChkHighlight){ SendMessage(rec->findChkHighlight, BM_CLICK, 0, 0); if(rec->findEdit) SetFocus(rec->findEdit); return 0; }
  }
#endif
      break;
    }
    case WM_MOUSEMOVE:
    {
#ifdef _WIN32
  WebViewInstanceRecord* recMove = GetInstanceByHwnd(GetParent(h)); if(!recMove) break; POINT pt{ (SHORT)LOWORD(l), (SHORT)HIWORD(l) }; HWND child = ChildWindowFromPointEx(h, pt, CWP_SKIPTRANSPARENT); bool anyHot=false; auto hoverIn=[&](HWND btn){ if(!btn||child!=btn) return false; RECT rc; GetClientRect(btn,&rc); int box=24; int w=rc.right-rc.left; int h2=rc.bottom-rc.top; RECT inner=rc; if(w>box){ int dx=(w-box)/2; inner.left+=dx; inner.right=inner.left+box; } if(h2>box){ int dy=(h2-box)/2; inner.top+=dy; inner.bottom=inner.top+box; } POINT local=pt; MapWindowPoints(h,btn,&local,1); return PtInRect(&inner,local)!=0; };
  if (recMove->findBtnPrev){ bool hov = hoverIn(recMove->findBtnPrev); if(hov && !recMove->prevHot){ recMove->prevHot=true; InvalidateRect(recMove->findBtnPrev,nullptr,TRUE);} else if(!hov && recMove->prevHot){ recMove->prevHot=false; InvalidateRect(recMove->findBtnPrev,nullptr,TRUE);} if(hov) anyHot=true; }
  if (recMove->findBtnNext){ bool hov = hoverIn(recMove->findBtnNext); if(hov && !recMove->nextHot){ recMove->nextHot=true; InvalidateRect(recMove->findBtnNext,nullptr,TRUE);} else if(!hov && recMove->nextHot){ recMove->nextHot=false; InvalidateRect(recMove->findBtnNext,nullptr,TRUE);} if(hov) anyHot=true; }
  if(anyHot){ TRACKMOUSEEVENT t{sizeof(t),TME_LEAVE,h,0}; TrackMouseEvent(&t);} break;
#else
  // mac: default system hover visuals; no custom hot tracking
  break;
#endif
    }
    case WM_MOUSELEAVE:
    {
#ifdef _WIN32
  WebViewInstanceRecord* recLeave = GetInstanceByHwnd(GetParent(h)); if(!recLeave) break; if(recLeave->prevHot){ recLeave->prevHot=false; InvalidateRect(recLeave->findBtnPrev,nullptr,TRUE);} if(recLeave->nextHot){ recLeave->nextHot=false; InvalidateRect(recLeave->findBtnNext,nullptr,TRUE);} break;
#else
  break; // no-op on mac
#endif
    }
    case WM_LBUTTONUP:
    {
#ifdef _WIN32
  WebViewInstanceRecord* recUp = GetInstanceByHwnd(GetParent(h)); if(recUp){
    POINT pt{ (SHORT)LOWORD(l), (SHORT)HIWORD(l) }; HWND child = ChildWindowFromPointEx(h, pt, CWP_SKIPTRANSPARENT|CWP_SKIPINVISIBLE|CWP_SKIPDISABLED);
    bool prevWasDown = recUp->prevDown; bool nextWasDown = recUp->nextDown;
    if(recUp->prevDown){ recUp->prevDown=false; InvalidateRect(recUp->findBtnPrev,nullptr,TRUE);} 
    if(recUp->nextDown){ recUp->nextDown=false; InvalidateRect(recUp->findBtnNext,nullptr,TRUE);} 
    auto hitInBox=[&](HWND btn){ if(!btn) return false; RECT rc; GetClientRect(btn,&rc); int box=24; int w=rc.right-rc.left; int h2=rc.bottom-rc.top; RECT inner=rc; if(w>box){ int dx=(w-box)/2; inner.left+=dx; inner.right=inner.left+box; } if(h2>box){ int dy=(h2-box)/2; inner.top+=dy; inner.bottom=inner.top+box; } POINT local=pt; MapWindowPoints(h,btn,&local,1); return PtInRect(&inner,local)!=0; };
    if(prevWasDown && child==recUp->findBtnPrev && hitInBox(recUp->findBtnPrev)){ HWND host = GetParent(h); if(host) SendMessageW(host, WM_COMMAND, MAKEWPARAM(IDC_FIND_PREV, BN_CLICKED), (LPARAM)recUp->findBtnPrev); }
    if(nextWasDown && child==recUp->findBtnNext && hitInBox(recUp->findBtnNext)){ HWND host = GetParent(h); if(host) SendMessageW(host, WM_COMMAND, MAKEWPARAM(IDC_FIND_NEXT, BN_CLICKED), (LPARAM)recUp->findBtnNext); }
  }
#else
  // mac: rely on native button click messages
#endif
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
#ifdef _WIN32
      if (rec){ if(!rec->titleBrush){ COLORREF bk,tx; GetPanelThemeColors(GetParent(h), dc, &bk,&tx); rec->titleBkColor=bk; rec->titleTextColor=tx; rec->titleBrush=CreateSolidBrush(bk);} bkCol=rec->titleBkColor; txCol=rec->titleTextColor; }
      SetBkMode(dc, TRANSPARENT); SetTextColor(dc, txCol);
      static HBRUSH s_tmp=nullptr; if(!rec || !rec->titleBrush){ if(s_tmp) DeleteObject(s_tmp); s_tmp=CreateSolidBrush(bkCol); return (LRESULT)s_tmp; }
      return (LRESULT)rec->titleBrush;
#else
      if (rec){ if(rec->titleBkColor<0 || rec->titleTextColor<0){ int bgi=-1,txi=-1; GetPanelThemeColorsMac(&bgi,&txi); if(bgi>=0) rec->titleBkColor=bgi; if(txi>=0) rec->titleTextColor=txi; } if(rec->titleBkColor>=0) bkCol=(COLORREF)rec->titleBkColor; if(rec->titleTextColor>=0) txCol=(COLORREF)rec->titleTextColor; }
      SetBkMode(dc, TRANSPARENT); SetTextColor(dc, txCol);
      static HBRUSH s_tmp=nullptr; if(s_tmp) DeleteObject(s_tmp); s_tmp=CreateSolidBrush(bkCol); return (LRESULT)s_tmp;
#endif
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

static void UpdateFindCounter(WebViewInstanceRecord* rec)
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
      // Layout: edit, prev, next, case, highlight, counter (всё слева), close закреплён справа
  int pad=0; int curX=pad; int innerH=h-8; if(innerH<16) innerH=16; int yC=(h-innerH)/2;
  int btnBox=24; // logical slot width now equals visual width (no extra spacing)
  int btnVisual=24; // visual box
      auto showCtrl=[&](HWND ctrl){ if(ctrl) ShowWindow(ctrl,SW_SHOWNA); };
  if (rec->findEdit) { MoveWindow(rec->findEdit,curX,yC,180,innerH,TRUE); showCtrl(rec->findEdit); curX+=180+8; }
  if (rec->findBtnPrev){
    MoveWindow(rec->findBtnPrev,curX,(h-btnVisual)/2,btnBox,btnVisual,TRUE);
    showCtrl(rec->findBtnPrev);
    // Increased gap between prev and next buttons by +4 (was +4, now +8) per user request
    curX+=btnBox+8;
  }
  if (rec->findBtnNext){ MoveWindow(rec->findBtnNext,curX,(h-btnVisual)/2,btnBox,btnVisual,TRUE); showCtrl(rec->findBtnNext); curX+=btnBox+10; }
  // Case checkbox + label
  if (rec->findChkCase){ MoveWindow(rec->findChkCase,curX,yC,18,innerH,TRUE); showCtrl(rec->findChkCase); curX+=18; }
  if (rec->findLblCase){ MoveWindow(rec->findLblCase,curX,yC,98,innerH,TRUE); showCtrl(rec->findLblCase); curX+=98+8; }
  // Highlight checkbox + label
  // Reintroduce highlight group left shift (10px), and extra 10px before counter
  int highlightShift = 10; curX -= highlightShift; if (curX < pad) curX = pad;
  if (rec->findChkHighlight){ MoveWindow(rec->findChkHighlight,curX,yC,18,innerH,TRUE); showCtrl(rec->findChkHighlight); curX+=18; }
  if (rec->findLblHighlight){ MoveWindow(rec->findLblHighlight,curX,yC,92,innerH,TRUE); showCtrl(rec->findLblHighlight); curX+=92+8; }
  curX -= 10; if (curX < pad) curX = pad; // additional 10px shift before counter
  if (rec->findCounterStatic){ MoveWindow(rec->findCounterStatic,curX,yC,60,innerH,TRUE); showCtrl(rec->findCounterStatic); curX+=60+6; }
      int closeW=24; int rightX = w - pad - closeW;
      if (rec->findBtnClose){ MoveWindow(rec->findBtnClose,rightX,yC,closeW,innerH,TRUE); SetWindowPos(rec->findBtnClose,HWND_TOP,0,0,0,0,SWP_NOMOVE|SWP_NOSIZE); showCtrl(rec->findBtnClose); }
      bottom = g_findBarH;
      UpdateFindCounter(rec);
    }
  } else if (rec && rec->findBarWnd) {
    ShowWindow(rec->findBarWnd, SW_HIDE);
  }
  // WebView occupies remaining client area
  RECT brc=rc; brc.top+=top; brc.bottom -= bottom; if (brc.bottom < brc.top) brc.bottom = brc.top;
  if(rec && rec->controller) rec->controller->put_Bounds(brc);
}
static void SetTitleBarText(HWND hwnd, const std::string& s){ WebViewInstanceRecord* rec=GetInstanceByHwnd(hwnd); if(rec && rec->titleBar) SetWindowTextW(rec->titleBar,Widen(s).c_str()); }

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
    case WM_INITDIALOG:
    {
      if (!g_rwvMsgHook) {
        g_rwvMsgHook = SetWindowsHookExW(WH_GETMESSAGE, [](int code, WPARAM wP, LPARAM lP)->LRESULT {
          if (code >= 0) {
            MSG* m = (MSG*)lP;
            if (m && m->message==WM_KEYDOWN && m->wParam==VK_RETURN) {
              HWND foc = GetFocus();
              if (foc && foc == g_lastFindEdit) {
                // Determine direction (Shift => prev)
                bool shift = (GetKeyState(VK_SHIFT)&0x8000)!=0;
                HWND findBar = GetParent(foc);
                HWND host = findBar ? GetParent(findBar) : nullptr;
                WebViewInstanceRecord* rec = GetInstanceByHwnd(host);
                if (rec) {
                  bool fwd = !shift;
                  g_findEnterActive = true; g_findLastEnterTick = GetTickCount();
                  RWV_FindNavigateInline(rec, fwd);
                  LogF("[Find] nav %s query='%s'", fwd?"next":"prev", rec->findQuery.c_str());
                  // maintain focus & caret
                  SetFocus(foc); SendMessage(foc, EM_SETSEL, (WPARAM)-1, (LPARAM)-1);
                }
                LogRaw("[FindHook] swallow VK_RETURN pre-translate");
                m->message = WM_NULL; m->wParam = 0; return 1; // eat
              }
            }
          }
          return CallNextHookEx(g_rwvMsgHook, code, wP, lP);
        }, nullptr, GetCurrentThreadId());
        LogRaw("[FindHook] installed WH_GETMESSAGE");
      }
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
          WebViewInstanceRecord* r = GetInstanceByHwnd(hwnd); if (r && r->showFindBar){ r->showFindBar=false; LogRaw("[Find] close"); LayoutTitleBarAndWebView(hwnd, r->titleBar && IsWindow(r->titleBar) && IsWindowVisible(r->titleBar)); }
          return 0;
        }
        case IDC_FIND_PREV:
        case IDC_FIND_NEXT:
        {
          WebViewInstanceRecord* r = GetInstanceByHwnd(hwnd); if (r){ bool fwd = (LOWORD(wp)==IDC_FIND_NEXT); LogF("[Find] nav %s query='%s'", fwd?"next":"prev", r->findQuery.c_str()); /* real search TBD */ }
          return 0;
        }
        case IDC_FIND_CASE:
        case IDC_FIND_HILITE:
        {
          WebViewInstanceRecord* r = GetInstanceByHwnd(hwnd); if (r){ if (LOWORD(wp)==IDC_FIND_CASE){ r->findCaseSensitive = (SendMessage((HWND)lp, BM_GETCHECK,0,0)==BST_CHECKED); LogF("[Find] case=%d", (int)r->findCaseSensitive);} else { r->findHighlightAll = (SendMessage((HWND)lp, BM_GETCHECK,0,0)==BST_CHECKED); LogF("[Find] highlight=%d", (int)r->findHighlightAll);} }
          return 0;
        }
        case IDC_FIND_EDIT:
        {
          if (HIWORD(wp)==EN_CHANGE) {
            WebViewInstanceRecord* r = GetInstanceByHwnd(hwnd); if (r && r->findEdit){ char buf[512]; GetWindowTextA(r->findEdit, buf, sizeof(buf)); r->findQuery=buf; r->findCurrentIndex=0; r->findTotalMatches=0; LogF("[Find] query change '%s'", r->findQuery.c_str()); UpdateFindCounter(r); }
          }
          return 0;
        }
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
      { bool f=false; int idx=-1; bool id = DockIsChildOfDock ? (DockIsChildOfDock(hwnd,&f) >= 0) : false; if (id && DockWindowRemove) DockWindowRemove(hwnd); }
      DestroyWindow(hwnd);
      return 0;

    case WM_DESTROY:
      LogRaw("[WM_DESTROY]");
      if (g_rwvMsgHook){ UnhookWindowsHookEx(g_rwvMsgHook); g_rwvMsgHook=nullptr; LogRaw("[FindHook] removed WH_GETMESSAGE"); }
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
