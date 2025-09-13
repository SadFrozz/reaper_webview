// Reaper WebView Plugin
// log.h — единый кроссплатформенный логгер (header-only)
#pragma once

#include "predef.h"

#ifdef ENABLE_LOG

static inline void frz_log_write_line(const char* s)
{
  if (!s) return;

#ifdef _WIN32
  ::OutputDebugStringA(s);
  ::OutputDebugStringA("\r\n");
#else
  std::fputs(s, stderr);
  std::fputc('\n', stderr);
#endif

  if (ShowConsoleMsg) { ShowConsoleMsg(s); ShowConsoleMsg("\n"); }

  const char* res = GetResourcePath ? GetResourcePath() : nullptr;
  std::string path;
#ifdef _WIN32
  path = (res && *res) ? (std::string(res) + "\\reaper_webview_log.txt")
                       : std::string("reaper_webview_log.txt");
#else
  path = (res && *res) ? (std::string(res) + "/reaper_webview_log.txt")
                       : std::string("reaper_webview_log.txt");
#endif

  FILE* f = nullptr;
#ifdef _WIN32
  fopen_s(&f, path.c_str(), "ab");
#else
  f = std::fopen(path.c_str(), "ab");
#endif
  if (f) { std::fputs(s, f); std::fputc('\n', f); std::fclose(f); }
}

static inline void LogRaw(const char* s) { frz_log_write_line(s); }

static inline void LogF(const char* fmt, ...)
{
  if (!fmt) return;
  char buf[4096]; buf[0] = '\0';
  va_list ap; va_start(ap, fmt);
#ifdef _WIN32
  _vsnprintf(buf, sizeof(buf)-1, fmt, ap);
#else
  vsnprintf(buf, sizeof(buf)-1, fmt, ap);
#endif
  va_end(ap);
  buf[sizeof(buf)-1] = '\0';
  frz_log_write_line(buf);
}

#else
// Без ENABLE_LOG — no-op
static inline void LogRaw(const char*) {}
static inline void LogF(const char*, ...) {}
#endif