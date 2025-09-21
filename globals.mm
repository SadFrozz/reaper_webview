// Reaper WebView Plugin
// (c) Andrew "SadFrozz" Brodsky
// 2025 and later
// globals.mm

#define RWV_WITH_WEBVIEW2 1
#include "predef.h"
#include "globals.h"
#include "helpers.h"
#include "log.h"

REAPER_PLUGIN_HINSTANCE g_hInst = nullptr;
HWND   g_hwndParent = nullptr;
int    g_command_id = 0;

const char* kDockIdent  = "reaper_webview";
const char* kDefaultURL = "https://www.reaper.fm/";
const char* kTitleBase  = "WebView";

#ifdef _WIN32
HMODULE g_hWebView2Loader = nullptr;
bool    g_com_initialized = false;
#else
#endif

// Per-instance caching now inside WebViewInstanceRecord (lastTabTitle/lastWndText)

std::string g_instanceId;

int  g_last_dock_idx        = -1;
bool g_last_dock_float      = false;
int  g_want_dock_on_create  = -1;

#ifdef _WIN32
int      g_titleBarH       = 24;  // фикс, без привязки к DPI
int      g_titlePadX       = 8;
int      g_findBarH        = 30;  // find bar height (Windows)
#else
CGFloat      g_titleBarH    = 24.0;
CGFloat      g_titlePadX    = 8.0;
CGFloat      g_findBarH     = 30.0; // find bar height (macOS)
#endif

std::unordered_map<std::string,int>      g_registered_commands;
std::unordered_map<int, CommandHandler>  g_cmd_handlers;
std::vector<std::unique_ptr<gaccel_register_t>> g_gaccels;

// ================= Multi-instance runtime storage =================
std::unordered_map<std::string, std::unique_ptr<WebViewInstanceRecord>> g_instances;
int g_randomInstanceCounter = 0;

WebViewInstanceRecord* GetInstanceById(const std::string& id)
{
	auto it = g_instances.find(id);
	return it == g_instances.end() ? nullptr : it->second.get();
}

WebViewInstanceRecord* GetInstanceByHwnd(HWND hwnd)
{
	if (!hwnd) return nullptr;
	for (auto &kv : g_instances) {
		if (kv.second && kv.second->hwnd == hwnd) return kv.second.get();
	}
	return nullptr;
}

std::string NormalizeInstanceId(const std::string& raw, bool* outWasRandom)
{
	if (outWasRandom) *outWasRandom = false;
	if (raw.empty()) return "wv_default";

	if (raw == "random") {
		if (outWasRandom) *outWasRandom = true;
		++g_randomInstanceCounter;
		char buf[64]; snprintf(buf, sizeof(buf), "wv_%d", g_randomInstanceCounter);
		return buf;
	}

	// Правило: пользователь обязан передать id, начинающийся с wv_. Если не так — игнор и default.
	if (raw.rfind("wv_", 0) != 0) return "wv_default";
	return raw;
}

WebViewInstanceRecord* EnsureInstanceAndMaybeNavigate(const std::string& id, const std::string& url, bool navigate, const std::string& newTitle, ShowPanelMode newMode)
{
	WebViewInstanceRecord* rec = GetInstanceById(id);
	if (!rec) {
		auto ptr = std::make_unique<WebViewInstanceRecord>();
		ptr->id = id;
		// Наследуем состояние от wv_default при первом создании НЕ default инстанса
		if (id != "wv_default") {
			WebViewInstanceRecord* def = GetInstanceById("wv_default");
			if (def) {
				ptr->titleOverride = def->titleOverride.empty()? kTitleBase : def->titleOverride;
				ptr->panelMode     = def->panelMode;
				ptr->lastUrl       = def->lastUrl; // стартовая навигация может унаследовать
				ptr->basicCtxMenu  = def->basicCtxMenu;
				ptr->wantDockOnCreate = def->wantDockOnCreate;
				ptr->lastDockIdx      = def->lastDockIdx;
				ptr->lastDockFloat    = def->lastDockFloat;
			} else {
				ptr->titleOverride = kTitleBase;
			}
		} else {
			ptr->titleOverride = kTitleBase;
		}
		rec = ptr.get();
		g_instances[id] = std::move(ptr);
	}
	// Apply changes
	// Не сбрасываем кастомный заголовок обратно на kTitleBase если SetTitle не пришёл.
	if (!newTitle.empty()) rec->titleOverride = newTitle;
	if (newMode != ShowPanelMode::Unset) rec->panelMode = newMode;
	if (navigate && !url.empty()) rec->lastUrl = url; // actual navigation performed elsewhere for now
	return rec;
}

void PurgeDeadInstances()
{
	for (auto it = g_instances.begin(); it != g_instances.end(); ) {
		WebViewInstanceRecord* r = it->second.get();
#ifdef _WIN32
		const bool dead = (!r->hwnd || !IsWindow(r->hwnd)) && r->controller==nullptr && r->webview==nullptr;
#else
		const bool dead = (!r->hwnd) && r->webView==nil;
#endif
		if (dead) {
			LogF("[InstancePurge] removing dead record id='%s'", it->first.c_str());
#ifndef _WIN32
			// Снятие KVO наблюдателя теперь инкапсулировано
			if (r->webView) FRZ_RemoveTitleObserverFor(r->webView);
#endif
			it = g_instances.erase(it);
		} else ++it;
	}
}

void SaveInstanceStateAll()
{
	LogRaw("[PersistStub] SaveInstanceStateAll begin");
	for (auto &kv : g_instances) {
		WebViewInstanceRecord* r = kv.second.get();
		if (!r) continue;
		LogF("[PersistStub] id='%s' hwnd=%p title='%s' panelMode=%d wantDock=%d lastUrl='%s' dockIdx=%d float=%d",
			kv.first.c_str(), (void*)r->hwnd, r->titleOverride.c_str(), (int)r->panelMode, r->wantDockOnCreate,
			r->lastUrl.c_str(), r->lastDockIdx, (int)r->lastDockFloat);
	}
	LogRaw("[PersistStub] SaveInstanceStateAll end");
}

void LoadInstanceStateAll()
{
	LogRaw("[PersistStub] LoadInstanceStateAll (noop stub)");
}
