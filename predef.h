// Reaper WebView Plugin
// (c) Andrew "SadFrozz" Brodsky
// 2025 and later
// predef.h
#pragma once

// ===== platform =====
#ifdef _WIN32
  #ifndef WIN32_LEAN_AND_MEAN
  #define WIN32_LEAN_AND_MEAN
  #endif
  #ifndef NOMINMAX
  #define NOMINMAX
  #endif

  // Базовые Win-заголовки (без тяжёлых библиотек)
  #include <winsock2.h>
  #include <windows.h>
  #include <objbase.h>

  // ВАЖНО: WIL / WebView2 подключаем ТОЛЬКО если TU действительно их использует.
  // Перед #include "predef.h" в таком TU нужно определить RWV_WITH_WEBVIEW2.
  #if defined(RWV_WITH_WEBVIEW2)
    #include <wrl.h>
    #include "deps/wil/com.h"
    #include "deps/WebView2.h"
  #else
    // Лёгкие форварды, чтобы заголовки с extern-ссылками компилировались без WIL
    struct ICoreWebView2;
    struct ICoreWebView2Controller;
    namespace wil { template <class T> class com_ptr; }
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
  HWND GetAncestor(HWND hwnd, UINT gaFlags)
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
#include "WDL/wdltypes.h"           // <- про это спрашивали: подключаем тут
#include "sdk/reaper_plugin.h"

// ВНИМАНИЕ: reaper_plugin_functions.h подключаем здесь,
// но определение указателей произойдёт только в том TU,
// где ПЕРЕД ЭТИМ заголовком задан REAPERAPI_IMPLEMENT.
#include "sdk/reaper_plugin_functions.h"
