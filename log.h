// Reaper WebView Plugin
// log.h — единый кроссплатформенный логгер (header-only)
#pragma once

#include "predef.h"

#ifdef ENABLE_LOG

static inline void frz_log_write_line(const char* s)
{
  if (!s) return;

  // Build timestamp prefix: YYYY-MM-DD HH:MM:SS.mmm
  char linebuf[4600];
  linebuf[0] = '\0';
#ifdef _WIN32
  SYSTEMTIME st; GetLocalTime(&st);
  int n = _snprintf_s(linebuf, sizeof(linebuf), _TRUNCATE,
                      "%04d-%02d-%02d %02d:%02d:%02d.%03d %s",
                      (int)st.wYear,(int)st.wMonth,(int)st.wDay,
                      (int)st.wHour,(int)st.wMinute,(int)st.wSecond,(int)st.wMilliseconds,
                      s);
  if (n < 0) return;
#else
  struct timeval tv; gettimeofday(&tv, NULL);
  struct tm tmv; localtime_r(&tv.tv_sec, &tmv);
  int n = snprintf(linebuf, sizeof(linebuf),
                   "%04d-%02d-%02d %02d:%02d:%02d.%03ld %s",
                   tmv.tm_year+1900, tmv.tm_mon+1, tmv.tm_mday,
                   tmv.tm_hour, tmv.tm_min, tmv.tm_sec, (long)(tv.tv_usec/1000), s);
  if (n < 0) return;
#endif
  const char* out = linebuf;

#ifdef _WIN32
  ::OutputDebugStringA(out);
  ::OutputDebugStringA("\r\n");
#else
  std::fputs(out, stderr);
  std::fputc('\n', stderr);
#endif

  if (ShowConsoleMsg) { ShowConsoleMsg(out); ShowConsoleMsg("\n"); }

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
  if (f) { std::fputs(out, f); std::fputc('\n', f); std::fclose(f); }
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