// Reaper WebView Plugin
// (c) Andrew "SadFrozz" Brodsky
// 2025 and later
// api.mm
#include "predef.h"
#include "api.h"      // Public plugin API header
#include "globals.h"  // Struct declarations / extern globals
#include "helpers.h"  // Utilities (strings, domain, tabs)
#include "log.h"      // Logging

// ------------------------------------------------------------------
// Registration helper without repeatedly typing the function name
// ------------------------------------------------------------------
// APIdef_ string format per reaper_plugin.h:
//  returnType '\0' argTypesCSV '\0' argNamesCSV '\0' helpText '\0'
// The string must remain valid for the entire plugin lifetime.
// For Lua/EEL2/Python we also register APIvararg_* stubs:
//   void *vararg(void **arglist, int numparms)
// Arguments are extracted directly from arglist; the return value is packed
// as described in the SDK header.

struct ApiRegistrationInfo {
  const char* name;          // Name without prefix: WEBVIEW_Navigate
  const char* retType;       // "void"
  const char* argTypesCSV;   // "const char*,const char*"
  const char* argNamesCSV;   // "url,opts"
  const char* helpText;      // Multiline help text (ASCII/UTF-8 safe)
  void (*cFunc)(const char*, const char*); // C-интерфейс (API_*)
  void* (*varargFunc)(void**, int);        // ReaScript implementation (APIvararg_*)
  const char* defCString;    // Ready null-delimited definition string (generated)
};

static bool g_api_registered = false;
static std::vector<std::unique_ptr<std::string>> g_api_def_storage; // Own storage to keep strings alive

// Forward vararg stubs
static void* Vararg_WEBVIEW_Navigate(void** arglist, int numparms);

// ------------------------------------------------------------------
// Actual API function implementations
// ------------------------------------------------------------------

// Single entry point: url + JSON options or "0"
void API_WEBVIEW_Navigate(const char* url, const char* opts)
{
  // Parse options (without immediate application to globals)
  std::string newTitle;
  std::string newInstance;
  ShowPanelMode newShow = ShowPanelMode::Unset;
  bool newBasicCtx = false;
  if (is_truthy(opts)) {
    newTitle    = GetJsonString(opts, "SetTitle");
    newInstance = GetJsonString(opts, "InstanceId");
    newShow     = ParseShowPanel(GetJsonString(opts, "ShowPanel"));
    // BasicCtxMenu: any truthy => enable basic context menu
    std::string bcm = GetJsonString(opts, "BasicCtxMenu");
    if (!bcm.empty()) newBasicCtx = is_truthy(bcm.c_str());
  }

  // --- Multi-instance resolution ---
  // InstanceId rules:
  //   "" (missing) -> wv_default
  //   "random"     -> wv_<N>
  //   starts with wv_ -> accepted verbatim
  //   anything else -> treated as wv_default
  bool wasRandom=false;
  std::string requestedId = newInstance;
  // Support virtual tokens: "current" and "last" BEFORE NormalizeInstanceId.
  if (requestedId == "current") {
    if (!g_activeInstanceId.empty()) requestedId = g_activeInstanceId; else requestedId = "random"; // fallback -> random per требованию
  } else if (requestedId == "last") {
    if (!g_lastFocusedInstanceId.empty()) requestedId = g_lastFocusedInstanceId; else if(!g_activeInstanceId.empty()) requestedId = g_activeInstanceId; else requestedId = "random"; // fallback -> random
  }
  const std::string normalizedId = NormalizeInstanceId(requestedId, &wasRandom);
  // Capture old title (if present) to detect/log changes
  WebViewInstanceRecord* before = GetInstanceById(normalizedId);
  std::string oldTitle = before ? before->titleOverride : std::string();
  auto* rec = EnsureInstanceAndMaybeNavigate(normalizedId, url?url:std::string(), (url&&*url), newTitle, newShow);
  if (rec && newBasicCtx) rec->basicCtxMenu = true;
  g_instanceId = normalizedId; // active id

  // Global fields no longer authoritative (kept for legacy docker code paths)
  if (rec && rec->wantDockOnCreate >= 0) g_want_dock_on_create = rec->wantDockOnCreate;

  // Log call parameters
  LogF("[API] WEBVIEW_Navigate url='%s' opts='%s' SetTitle='%s' InstanceIdRaw='%s' norm='%s' wasRandom=%d ShowPanel=%d", 
    url?url:"", opts?opts:"", newTitle.c_str(), newInstance.c_str(), normalizedId.c_str(), (int)wasRandom, (int)newShow);

  // Proceed to per-instance open (may reuse single window for now)
  OpenOrActivateInstance(g_instanceId, url?std::string(url):std::string());

  // Update titles (using hwnd of matched instance)
  if (rec && rec->hwnd) {
    if (!newTitle.empty() && newTitle != oldTitle) {
      LogF("[TitleChange] instance='%s' '%s' -> '%s' (updating docker tab)", normalizedId.c_str(), oldTitle.c_str(), rec->titleOverride.c_str());
    }
    UpdateTitlesExtractAndApply(rec->hwnd);
  }
}

// ----- Example placeholder for future API -----
// static int API_WEBVIEW_GetSomething(const char* opts) { return 123; }

// ------------------------------------------------------------------
// API list
// ------------------------------------------------------------------

// -------------------- Vararg wrappers --------------------
// Convert generic ReaScript call to our C API.
static void* Vararg_WEBVIEW_Navigate(void** arglist, int numparms)
{
  const char* url  = (numparms > 0 && arglist[0]) ? (const char*)arglist[0] : nullptr;
  const char* opts = (numparms > 1 && arglist[1]) ? (const char*)arglist[1] : nullptr;
  API_WEBVIEW_Navigate(url, opts);
  return nullptr; // void
}

// -------------------- API list definition --------------------

#define HELP_NAV \
"WEBVIEW_Navigate(url, opts)\n" \
"  Navigate/open a webview instance and optionally configure it.\n" \
"  url: const char*  (http/https/file etc). Use '0' or empty to keep current URL.\n" \
"  opts: JSON string or '0'. Supported keys (all optional):\n" \
"    SetTitle   : string  -> override custom tab/window title (does NOT affect panel fallback)\n" \
"    InstanceId : string  -> 'wv_default' (implicit), 'random', or custom starting with 'wv_'.\n" \
"                  'random' auto-generates sequential wv_N. Any other not starting with 'wv_' maps to wv_default.\n" \
"    ShowPanel  : string  -> visibility mode: 'hide' | 'docker' | 'always'.\n" \
"                  hide   : do not show panel (window stays hidden until navigation/activation)\n" \
"                  docker : ensure docked (if REAPER docking available)\n" \
"                  always : force visible (floating or docked depending on previous state)\n" \
"    BasicCtxMenu : bool   -> when true show only minimal context menu (Dock/Undock + Close).\n" \
"  Behavior notes:\n" \
"    - First call creates instance window if needed.\n" \
"    - Title override persists per-instance until another SetTitle or plugin unload.\n" \
"    - Panel caption always shows fallback derived from domain/page, not SetTitle.\n" \
"    - Docker tab uses SetTitle when provided, otherwise fallback.\n" \
"    - Unknown JSON keys are ignored silently.\n" \
"    - Pass opts='0' (or NULL) for no options.\n"

static ApiRegistrationInfo g_api_list[] = {
  { "WEBVIEW_Navigate", "void", "const char*,const char*", "url,opts", HELP_NAV, &API_WEBVIEW_Navigate, &Vararg_WEBVIEW_Navigate, nullptr },
  // Add new API entries here
};

static void BuildDefString(ApiRegistrationInfo& api)
{
  if (api.defCString) return; // already built
  auto holder = std::make_unique<std::string>();
  holder->append(api.retType);           holder->push_back('\0');
  holder->append(api.argTypesCSV);       holder->push_back('\0');
  holder->append(api.argNamesCSV);       holder->push_back('\0');
  holder->append(api.helpText ? api.helpText : ""); holder->push_back('\0');
  api.defCString = holder->c_str();
  g_api_def_storage.push_back(std::move(holder));
}

void RegisterAPI()
{
  if (g_api_registered) return;

  const size_t count = sizeof(g_api_list)/sizeof(g_api_list[0]);
  for (size_t i=0; i<count; ++i)
  {
    auto& api = g_api_list[i];
    BuildDefString(api);

  std::string base = api.name; // without prefix
    std::string key_func   = "API_"        + base;
    std::string key_def    = "APIdef_"     + base;
    std::string key_vararg = "APIvararg_"  + base;

    plugin_register(key_func.c_str(),   (void*)api.cFunc);
    plugin_register(key_def.c_str(),    (void*)api.defCString);
    plugin_register(key_vararg.c_str(), (void*)api.varargFunc);
  }
  g_api_registered = true;
}

void UnregisterAPI()
{
  if (!g_api_registered) return;
  const size_t count = sizeof(g_api_list)/sizeof(g_api_list[0]);
  for (size_t i=0; i<count; ++i)
  {
    auto& api = g_api_list[i];
    std::string base = api.name;
    plugin_register(("-API_"       + base).c_str(), (void*)api.cFunc);
    plugin_register(("-APIdef_"    + base).c_str(), (void*)api.defCString);
    plugin_register(("-APIvararg_" + base).c_str(), (void*)api.varargFunc);
  }
  g_api_registered = false;
  g_api_def_storage.clear();
}
