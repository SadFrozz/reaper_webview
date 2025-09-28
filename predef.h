// Reaper WebView Plugin
// (c) Andrew "SadFrozz" Brodsky
// 2025 and later
// predef.h
// Common predefines and includes for all translation units

#pragma once

// ===== platform =====
#ifdef _WIN32
  #ifndef WIN32_LEAN_AND_MEAN
  #define WIN32_LEAN_AND_MEAN
  #endif
  #ifndef NOMINMAX
  #define NOMINMAX
  #endif

  // Basic Win32 headers (avoid pulling in heavy libraries)
  #include <winsock2.h>
  #include <windows.h>
  #include <objbase.h>

  // IMPORTANT: Include WIL / WebView2 ONLY if this translation unit actually uses them.
  // Before including "predef.h" define RWV_WITH_WEBVIEW2 in that TU.
  #if defined(RWV_WITH_WEBVIEW2)
    #include <wrl.h>
    #include "deps/wil/com.h"
    #include "deps/WebView2.h"
  #endif
#else
  #include "WDL/swell/swell.h"
  #include "WDL/swell/swell-dlggen.h"
  #include "WDL/swell/swell-menugen.h"
  #import <Cocoa/Cocoa.h>
  #import <WebKit/WebKit.h>
  #ifndef AppendMenuA
  #define AppendMenuA(hMenu, uFlags, uIDNewItem, lpNewItem) InsertMenu(hMenu, -1, MF_BYPOSITION | (uFlags), uIDNewItem, lpNewItem)
  #endif
  static inline HWND GetAncestor(HWND hwnd, UINT gaFlags)
  {
      if (!hwnd) return NULL;

      if (gaFlags == GA_PARENT)
      {
          return GetParent(hwnd);
      }

      if (gaFlags == GA_ROOT || gaFlags == GA_ROOTOWNER)
      {
          HWND last_hwnd = hwnd;
          HWND current_hwnd = hwnd;
          while ((current_hwnd = GetParent(current_hwnd)) != NULL)
          {
              last_hwnd = current_hwnd;
          }
          return last_hwnd;
      }

      return NULL;
  }
#endif


// ====== common headers =====
#include <vector>
#include <string>
#include <map>
#include <mutex>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <ctype.h>
#include <unordered_map>
#include <memory>

// ===== WDL / REAPER SDK =====
#include "WDL/wdltypes.h"           // Asked about this earlier: include here globally
#include "sdk/reaper_plugin.h"

// NOTE: reaper_plugin_functions.h is included here, but pointer definitions
// happen only in the translation unit that defines REAPERAPI_IMPLEMENT
// before including this header.
#include "sdk/reaper_plugin_functions.h"
