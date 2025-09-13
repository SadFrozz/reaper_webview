// Reaper WebView Plugin
// (c) Andrew "SadFrozz" Brodsky
// 2025 and later
// api.mm
#include "predef.h"
#include "api.h"
#include "globals.h"   // <— добавлено: прототипы и глобалы (OpenOrActivate, UpdateTitlesExtractAndApply, ShowPanelMode, g_dlg, kTitleBase)
#include "helpers.h"

// ------------------------------------------------------------------
// Регистрация без повторного набора имени функции
// ------------------------------------------------------------------
struct ApiRegistrationInfo {
  const char* name;        // "WEBVIEW_Navigate"
  const char* signature;   // "void,const char*,const char*"
  const char* hint;        // строка-подсказка (APIdef_out:)
  void*       functionPointer; // &API_WEBVIEW_Navigate
};

#define API_ENTRY(fname, csig, chint) \
  ApiRegistrationInfo{ #fname, csig, chint, (void*)&API_##fname }

static bool g_api_registered = false;

// ------------------------------------------------------------------
// Собственно API-функции (реализация)
// ------------------------------------------------------------------

// Единая точка входа: url + JSON-опции или "0"
static void API_WEBVIEW_Navigate(const char* url, const char* opts)
{
  // дефолты/сброс на вызов
  std::string newTitle;
  std::string newInstance;
  ShowPanelMode newShow = ShowPanelMode::Unset;

  if (is_truthy(opts)) {
    newTitle    = GetJsonString(opts, "SetTitle");
    newInstance = GetJsonString(opts, "InstanceId");
    newShow     = ParseShowPanel(GetJsonString(opts, "ShowPanel"));
  }

  // Применяем заголовок (SetTitle больше не экспортируется отдельно)
  if (!newTitle.empty()) {
    g_titleOverride = newTitle;
  } else {
    g_titleOverride = kTitleBase;
  }

  // Заглушки — просто запоминаем
  if (!newInstance.empty()) g_instanceId = newInstance;
  if (newShow != ShowPanelMode::Unset) g_showPanelMode = newShow;

  // Навигация/активация
  if (url && *url) OpenOrActivate(url);
  else             OpenOrActivate(std::string());

  // Обновить титулы
  if (g_dlg) UpdateTitlesExtractAndApply(g_dlg);
}

// ----- Пример заготовки под будущие API -----
// static int API_WEBVIEW_GetSomething(const char* opts) { return 123; }

// ------------------------------------------------------------------
// Список API
// ------------------------------------------------------------------

#define HINT_NAV \
"WEBVIEW_Navigate(url, opts)\n" \
"  url: string (http/https/file/etc)\n" \
"  opts: JSON string or '0'. Keys:\n" \
"    SetTitle: string — переопределить заголовок вкладки/панели\n" \
"    InstanceId: string — id инстанса (заглушка)\n" \
"    ShowPanel: 'hide'|'docker'|'always' — режим показа (заглушка)\n"

#define REAPER_WEBVIEW_APIS \
  X(WEBVIEW_Navigate, "void,const char*,const char*", HINT_NAV) \
  /*X(WEBVIEW_GetSomething, "int,const char*", "Пример")*/      \

void RegisterAPI()
{
  if (g_api_registered) return;

  std::vector<ApiRegistrationInfo> apis;
  #define X(name, sig, hint) apis.emplace_back(API_ENTRY(name, sig, hint));
  REAPER_WEBVIEW_APIS
  #undef X

  for (const auto& api : apis) {
    const std::string def_name = "APIdef_"     + std::string(api.name);
    const std::string out_name = "APIdef_out:" + std::string(api.name);
    const std::string api_name = "API_"        + std::string(api.name);

    plugin_register(def_name.c_str(), (void*)api.signature);
    plugin_register(out_name.c_str(), (void*)api.hint);
    plugin_register(api_name.c_str(),  api.functionPointer);
  }

  g_api_registered = true;
}
