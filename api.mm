// Reaper WebView Plugin
// (c) Andrew "SadFrozz" Brodsky
// 2025 and later
// api.mm
#include "predef.h"
#include "api.h"      // собственный публичный интерфейс
#include "globals.h"  // объявления структур/extern
#include "helpers.h"  // утилиты (строки, домен, табы)
#include "log.h"      // логирование

// ------------------------------------------------------------------
// Регистрация без повторного набора имени функции
// ------------------------------------------------------------------
// Формат строки для APIdef_ согласно reaper_plugin.h:
//  returnType '\0' argTypesCSV '\0' argNamesCSV '\0' helpText '\0'
// Строка должна жить в памяти всё время жизни плагина.
// Также для Lua/EEL2/Python нужна регистрация APIvararg_* — функция-обёртка:
//   void *vararg(void **arglist, int numparms)
// аргументы достаются напрямую из arglist, возвращаемое значение
// упаковывается как описано в заголовке SDK.

struct ApiRegistrationInfo {
  const char* name;          // Имя без префикса: WEBVIEW_Navigate
  const char* retType;       // "void"
  const char* argTypesCSV;   // "const char*,const char*"
  const char* argNamesCSV;   // "url,opts"
  const char* helpText;      // Multiline help text (ASCII/UTF-8 safe)
  void (*cFunc)(const char*, const char*); // C-интерфейс (API_*)
  void* (*varargFunc)(void**, int);        // Реализация для ReaScript (APIvararg_*)
  const char* defCString;    // готовая нуль-разделённая строка (генерируется)
};

static bool g_api_registered = false;
static std::vector<std::unique_ptr<std::string>> g_api_def_storage; // держим строки в памяти

// Forward vararg stubs
static void* Vararg_WEBVIEW_Navigate(void** arglist, int numparms);

// ------------------------------------------------------------------
// Собственно API-функции (реализация)
// ------------------------------------------------------------------

// Единая точка входа: url + JSON-опции или "0"
static void API_WEBVIEW_Navigate(const char* url, const char* opts)
{
  // Считываем опции (без немедленного применения к глобалам)
  std::string newTitle;
  std::string newInstance;
  ShowPanelMode newShow = ShowPanelMode::Unset;
  if (is_truthy(opts)) {
    newTitle    = GetJsonString(opts, "SetTitle");
    newInstance = GetJsonString(opts, "InstanceId");
    newShow     = ParseShowPanel(GetJsonString(opts, "ShowPanel"));
  }

  // --- Multi-instance resolve ---
  // InstanceId правила:
  //   "" (отсутствует) -> wv_default
  //   "random" -> wv_<N>
  //   строка, начинающаяся на wv_ -> принимается как есть
  //   любое иное значение -> трактуется как wv_default
  bool wasRandom=false;
  const std::string normalizedId = NormalizeInstanceId(newInstance, &wasRandom);
  // Захват старого заголовка (если есть) для отслеживания изменения
  WebViewInstanceRecord* before = GetInstanceById(normalizedId);
  std::string oldTitle = before ? before->titleOverride : std::string();
  auto* rec = EnsureInstanceAndMaybeNavigate(normalizedId, url?url:std::string(), (url&&*url), newTitle, newShow);
  g_instanceId = normalizedId; // активный id

  // Глобальные поля больше не используются как источник истинного состояния (оставлены для legacy участков докера)
  if (rec && rec->wantDockOnCreate >= 0) g_want_dock_on_create = rec->wantDockOnCreate;

  // Лог параметров вызова
  LogF("[API] WEBVIEW_Navigate url='%s' opts='%s' SetTitle='%s' InstanceIdRaw='%s' norm='%s' wasRandom=%d ShowPanel=%d", 
    url?url:"", opts?opts:"", newTitle.c_str(), newInstance.c_str(), normalizedId.c_str(), (int)wasRandom, (int)newShow);

  // Переход к per-instance открытию (пока может переиспользовать одно окно)
  OpenOrActivateInstance(g_instanceId, url?std::string(url):std::string());

  // Обновить титулы (по hwnd найденного инстанса)
  if (rec && rec->hwnd) {
    if (!newTitle.empty() && newTitle != oldTitle) {
      LogF("[TitleChange] instance='%s' '%s' -> '%s' (updating docker tab)", normalizedId.c_str(), oldTitle.c_str(), rec->titleOverride.c_str());
    }
    UpdateTitlesExtractAndApply(rec->hwnd);
  }
}

// ----- Пример заготовки под будущие API -----
// static int API_WEBVIEW_GetSomething(const char* opts) { return 123; }

// ------------------------------------------------------------------
// Список API
// ------------------------------------------------------------------

// -------------------- Vararg wrappers --------------------
// Преобразуют универсальный вызов ReaScript к нашему C API.
static void* Vararg_WEBVIEW_Navigate(void** arglist, int numparms)
{
  const char* url  = (numparms > 0 && arglist[0]) ? (const char*)arglist[0] : nullptr;
  const char* opts = (numparms > 1 && arglist[1]) ? (const char*)arglist[1] : nullptr;
  API_WEBVIEW_Navigate(url, opts);
  return nullptr; // void
}

// -------------------- Определение списка API --------------------

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
"  Behavior notes:\n" \
"    - First call creates instance window if needed.\n" \
"    - Title override persists per-instance until another SetTitle or plugin unload.\n" \
"    - Panel caption always shows fallback derived from domain/page, not SetTitle.\n" \
"    - Docker tab uses SetTitle when provided, otherwise fallback.\n" \
"    - Unknown JSON keys are ignored silently.\n" \
"    - Pass opts='0' (or NULL) for no options.\n"

static ApiRegistrationInfo g_api_list[] = {
  { "WEBVIEW_Navigate", "void", "const char*,const char*", "url,opts", HELP_NAV, &API_WEBVIEW_Navigate, &Vararg_WEBVIEW_Navigate, nullptr },
  // Добавлять новые API здесь
};

static void BuildDefString(ApiRegistrationInfo& api)
{
  if (api.defCString) return; // уже собрали
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

    std::string base = api.name; // без префикса
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
