// Reaper WebView Plugin
// (c) Andrew "SadFrozz" Brodsky
// 2025 and later
// helpers.mm

#include "predef.h"
#include "helpers.h"

#ifdef _WIN32
// --- UTF-8 <-> UTF-16 ---
std::wstring Widen(const std::string& s)
{
  if (s.empty()) return std::wstring();
  const int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
  std::wstring w; w.resize(n ? (n - 1) : 0);
  if (n > 1) MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, &w[0], n);
  return w;
}
std::string Narrow(const std::wstring& w)
{
  if (w.empty()) return std::string();
  const int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, nullptr, 0, nullptr, nullptr);
  std::string s; s.resize(n ? (n - 1) : 0);
  if (n > 1) WideCharToMultiByte(CP_UTF8, 0, w.c_str(), -1, &s[0], n, nullptr, nullptr);
  return s;
}

// strcasecmp/strcasestr для Windows
#define strcasecmp _stricmp
static const char* strcasestr(const char* haystack, const char* needle)
{
  if (!haystack || !needle) return nullptr;
  if (!*needle) return haystack;
  const size_t nlen = std::strlen(needle);
  for (const char* p = haystack; *p; ++p) {
    size_t i = 0;
    while (i < nlen && p[i] &&
           std::tolower((unsigned char)p[i]) == std::tolower((unsigned char)needle[i])) {
      ++i;
    }
    if (i == nlen) return p;
  }
  return nullptr;
}
#else
  // macOS/Linux: есть в стандартной библиотеке
  #include <strings.h>
#endif

static inline std::string ToLower(std::string s)
{
  for (auto& c : s) c = (char)std::tolower((unsigned char)c);
  return s;
}

// host[:port] (порт скрыть если http:80 / https:443)
std::string ExtractDomainFromUrl(const std::string& url)
{
  if (url.empty()) return {};
  size_t scheme_end = url.find("://");
  std::string scheme; size_t host_start = 0;
  if (scheme_end != std::string::npos) { scheme = url.substr(0, scheme_end); host_start = scheme_end + 3; }
  std::string scheme_l = ToLower(scheme);

  size_t end = url.find_first_of("/?#", host_start);
  std::string hostport = url.substr(host_start, (end == std::string::npos) ? std::string::npos : (end - host_start));

  size_t at = hostport.rfind('@');
  if (at != std::string::npos) hostport = hostport.substr(at + 1);

  std::string host = hostport, port_str;
  if (!hostport.empty() && hostport[0] == '[') {
    size_t rb = hostport.find(']');
    if (rb != std::string::npos) {
      host = hostport.substr(0, rb + 1);
      if (rb + 1 < hostport.size() && hostport[rb + 1] == ':') port_str = hostport.substr(rb + 2);
    }
  } else {
    size_t colon = hostport.rfind(':');
    if (colon != std::string::npos) { host = hostport.substr(0, colon); port_str = hostport.substr(colon + 1); }
  }
  if (!host.empty() && host[0] != '[' && host.rfind("www.", 0) == 0) host = host.substr(4);

  bool drop_port = false;
  if (!port_str.empty()) {
    int p = 0; for (char c : port_str) { if (c < '0' || c > '9') { p = -1; break; } p = p * 10 + (c - '0'); }
    if (p > 0 && ((scheme_l == "http" && p == 80) || (scheme_l == "https" && p == 443))) drop_port = true;
  }
  return drop_port || port_str.empty() ? host : (host + ":" + port_str);
}

void SetWndText(HWND hwnd, const std::string& s)
{
  if (g_lastWndText == s) return;
#ifdef _WIN32
  SetWindowTextA(hwnd, s.c_str());
#else
  SetWindowText(hwnd, s.c_str()); // SWELL
#endif
  g_lastWndText = s;
}

void SaveDockState(HWND hwnd)
{
  bool ff = false; int ii = -1;
  HWND cand[3] = { hwnd, GetParent(hwnd), GetAncestor(hwnd, GA_ROOT) };
  for (int k = 0; k < 3; ++k) {
    HWND h = cand[k]; if (!h) continue;
    bool f = false;
    int i = DockIsChildOfDock ? DockIsChildOfDock(h, &f) : -1;
    if (i >= 0) { g_last_dock_idx = i; g_last_dock_float = f; return; }
  }
  g_last_dock_idx = -1; g_last_dock_float = false;
}

void SetTabTitleInplace(HWND hwnd, const std::string& tabCaption)
{
  SetWndText(hwnd, tabCaption);
  if (DockWindowRefreshForHWND) DockWindowRefreshForHWND(hwnd);
  if (DockWindowRefresh)        DockWindowRefresh();
}

static inline void SafePluginRegister(const char* name, void* p)
{
  if (!plugin_register || !name || !*name) return;
  plugin_register(name, p);
}
static inline void SafePluginRegister(const char* name, const char* sig)
{
  SafePluginRegister(name, (void*)sig);
}

// удобный helper для снятия регистрации
static inline void SafePluginRegisterNull(const char* name)
{
  SafePluginRegister(name, (void*)NULL);
}

void PlatformMakeTopLevel(HWND hwnd)
{
#ifdef _WIN32
  LONG_PTR st  = GetWindowLongPtr(hwnd, GWL_STYLE);
  LONG_PTR exs = GetWindowLongPtr(hwnd, GWL_EXSTYLE);
  st &= ~WS_CHILD; st |= WS_OVERLAPPEDWINDOW;
  SetWindowLongPtr(hwnd, GWL_STYLE, st);
  SetWindowLongPtr(hwnd, GWL_EXSTYLE, exs & ~WS_EX_TOOLWINDOW);
  SetParent(hwnd, NULL);
  RECT rr{}; GetWindowRect(hwnd, &rr);
  int w = rr.right - rr.left, h = rr.bottom - rr.top;
  if (w < 200 || h < 120) { w = 900; h = 600; }
  SetWindowPos(hwnd, NULL, rr.left, rr.top, w, h,
               SWP_NOZORDER | SWP_FRAMECHANGED | SWP_SHOWWINDOW);
  ShowWindow(hwnd, SW_SHOWNORMAL);
  SetForegroundWindow(hwnd);
#else
  // ШАГ 1: отстыковать от дока
  SetParent(hwnd, NULL);
  // ШАГ 2: размеры/позиция
  RECT r; GetWindowRect(hwnd, &r);
  int w = r.right - r.left, h = r.bottom - r.top;
  if (w < 200 || h < 120) { w = 900; h = 600; }

  RECT reaper_r; GetWindowRect(g_hwndParent, &reaper_r);
  int x = reaper_r.left + (reaper_r.right - reaper_r.left - w) / 2;
  int y = reaper_r.top  + (reaper_r.bottom - reaper_r.top - h) / 2;

  SetWindowPos(hwnd, NULL, x, y, w, h, SWP_NOZORDER | SWP_SHOWWINDOW);
  ShowWindow(hwnd, SW_SHOW);
  SetForegroundWindow(hwnd);

  // ШАГ 3: пост-фикс стиля (см. обработчик WM_SWELL_POST_UNDOCK_FIXSTYLE)
  PostMessage(hwnd, WM_SWELL_POST_UNDOCK_FIXSTYLE, 0, 0);
#endif
}

// --- tiny helpers for JSON-ish opts (string values only)
bool is_truthy(const char* s) { return s && *s && !(s[0] == '0' && s[1] == '\0'); }

// Extracts "Key":"Value" from a flat JSON object string, tolerant to spaces.
// Returns empty string if key not found.
std::string GetJsonString(const char* json, const char* key)
{
  if (!json || !*json) return {};
  const char* p = json;
  std::string pat = "\""; pat += key; pat += "\"";
  const char* k = strcasestr(p, pat.c_str());
  if (!k) return {};
  const char* c = std::strchr(k, ':'); if (!c) return {};
  while (*c && (*c == ':' || *c == ' ' || *c == '\t')) ++c;

  std::string out;
  if (*c == '\"') {
    ++c;
    while (*c && *c != '\"') { out.push_back(*c); ++c; }
  } else {
    while (*c && *c != ',' && *c != '}') { out.push_back(*c); ++c; }
    while (!out.empty() && std::isspace((unsigned char)out.back())) out.pop_back();
  }
  size_t i = 0; while (i < out.size() && std::isspace((unsigned char)out[i])) ++i;
  return out.substr(i);
}

ShowPanelMode ParseShowPanel(const std::string& v)
{
  if (v.empty()) return ShowPanelMode::Unset;
  #ifdef _WIN32
    if (!_stricmp(v.c_str(), "hide"))   return ShowPanelMode::Hide;
    if (!_stricmp(v.c_str(), "docker")) return ShowPanelMode::Docker;
    if (!_stricmp(v.c_str(), "always")) return ShowPanelMode::Always;
  #else
    if (!strcasecmp(v.c_str(), "hide"))   return ShowPanelMode::Hide;
    if (!strcasecmp(v.c_str(), "docker")) return ShowPanelMode::Docker;
    if (!strcasecmp(v.c_str(), "always")) return ShowPanelMode::Always;
  #endif
  return ShowPanelMode::Unset;
}
