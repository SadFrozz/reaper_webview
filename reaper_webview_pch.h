// reaper_webview_pch.h
#pragma once

// --- Системные заголовки для платформы
#ifdef _WIN32
  #define WIN32_LEAN_AND_MEAN
  #include <windows.h>
  #include <shlwapi.h>
  #pragma comment(lib, "shlwapi.lib")
  #include <windowsx.h>
#else
  #include <sys/stat.h> // Для C-функций
#endif

// --- Базовые C-совместимые заголовки
#include <cstdio>
#include <cstdlib>

// --- WDL/REAPER/SWELL (C-совместимая часть)
#include "WDL/wdltypes.h"
#include "sdk/reaper_plugin.h"

#ifdef _WIN32
  #include "WDL/swell/swell-win32.h"
#else
  #define SWELL_TARGET_COCOA
  #include "WDL/swell/swell.h"
#endif