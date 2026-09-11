// Reaper WebView Plugin
// (c) Andrew "SadFrozz" Brodsky
// 2025 and later
// globals.mm

#define RWV_WITH_WEBVIEW2 1
#include "predef.h"
#include "globals.h"
#include "helpers.h"
#include "log.h"
#include "settings.h"

#include <algorithm>

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
std::string g_activeInstanceId; // explicit current active window instance
std::string g_lastFocusedInstanceId; // previous active instance
std::string g_focusPrimaryInstanceId; // last instance that actually owned focus

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

namespace {

std::vector<PersistedInstanceState> g_pendingInstanceRestore;
size_t g_pendingInstanceRestoreIndex = 0;
bool g_instanceRestoreTimerRegistered = false;

void RestoreNextInstance();

void StopInstanceRestoreTimer()
{
	if (g_instanceRestoreTimerRegistered && plugin_register)
		plugin_register("-timer", (void*)&RestoreNextInstance);
	g_instanceRestoreTimerRegistered = false;
	g_pendingInstanceRestore.clear();
	g_pendingInstanceRestoreIndex = 0;
}

void RestoreNextInstance()
{
	if (g_pendingInstanceRestoreIndex >= g_pendingInstanceRestore.size()) {
		LogRaw("[Restore] startup instance restoration complete");
		StopInstanceRestoreTimer();
		return;
	}

	const PersistedInstanceState state = g_pendingInstanceRestore[g_pendingInstanceRestoreIndex++];
	WebViewInstanceRecord* rec = EnsureInstanceAndMaybeNavigate(
		state.id, state.url, false, state.title, static_cast<ShowPanelMode>(state.panelMode));
	if (rec) {
		rec->basicCtxMenu = state.basicCtxMenu;
		rec->isRandomInstance = state.isRandomInstance;
		rec->wantDockOnCreate = state.docked ? 1 : 0;
		rec->windowX = state.windowX;
		rec->windowY = state.windowY;
		rec->windowWidth = state.windowWidth;
		rec->windowHeight = state.windowHeight;
		rec->hasWindowPlacement = state.hasWindowPlacement;
		if (state.isRandomInstance && state.id.rfind("wv_", 0) == 0) {
			const char* suffix = state.id.c_str() + 3;
			char* end = nullptr;
			const long restoredNumber = strtol(suffix, &end, 10);
			if (end && *end == '\0' && restoredNumber > g_randomInstanceCounter)
				g_randomInstanceCounter = static_cast<int>(restoredNumber);
		}
		LogF("[Restore] opening id='%s' random=%d docked=%d url='%s'",
			state.id.c_str(), (int)state.isRandomInstance, (int)state.docked, state.url.c_str());
		OpenOrActivateInstance(state.id, state.url);
	}
}

} // namespace

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
		std::string generated;
		do {
			++g_randomInstanceCounter;
			char buf[64]; snprintf(buf, sizeof(buf), "wv_%d", g_randomInstanceCounter);
			generated = buf;
		} while (GetInstanceById(generated));
		return generated;
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
		ptr->basicCtxMenu = false;
		ptr->forwardReaperHotkeys = LoadInstanceHotkeyForwarding(id);
		ptr->wantDockOnCreate = g_webViewSettings.startDocked ? 1 : 0;
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
		bool persistedDocked = false;
		if (LoadInstanceDocked(id, &persistedDocked))
			ptr->wantDockOnCreate = persistedDocked ? 1 : 0;
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
	// Instance records also own reopen state (URL, title, dock choice and floating
	// geometry), so closing a window must not erase them. Runtime handles are
	// released by the platform window procedure. Records are cleared naturally
	// when the plug-in unloads.
}

void SaveInstanceStateAll()
{
	LogRaw("[Persist] SaveInstanceStateAll begin");
	std::vector<PersistedInstanceState> openStates;
	for (auto &kv : g_instances) {
		WebViewInstanceRecord* r = kv.second.get();
		if (!r) continue;
		const bool isOpen = r->hwnd && IsWindow(r->hwnd);
		bool docked = r->wantDockOnCreate == 1;
		if (isOpen) {
			HWND candidates[3] = {r->hwnd, GetParent(r->hwnd), GetAncestor(r->hwnd, GA_ROOT)};
			docked = false;
			for (HWND candidate : candidates) {
				if (!candidate || !DockIsChildOfDock) continue;
				bool floating = false;
				const int dockIndex = DockIsChildOfDock(candidate, &floating);
				if (dockIndex >= 0) {
					docked = true;
					r->lastDockIdx = dockIndex;
					r->lastDockFloat = floating;
					break;
				}
			}
			r->wantDockOnCreate = docked ? 1 : 0;
			if (!docked) {
				RECT placement{};
				bool havePlacement = false;
#ifdef _WIN32
				if (IsIconic(r->hwnd)) {
					WINDOWPLACEMENT windowPlacement{};
					windowPlacement.length = sizeof(windowPlacement);
					if (GetWindowPlacement(r->hwnd, &windowPlacement)) {
						placement = windowPlacement.rcNormalPosition;
						havePlacement = true;
					}
				}
#endif
				if (!havePlacement) havePlacement = GetWindowRect(r->hwnd, &placement) != 0;
				if (havePlacement) {
					r->windowX = placement.left;
					r->windowY = placement.top;
					r->windowWidth = placement.right - placement.left;
					r->windowHeight = placement.bottom - placement.top;
					r->hasWindowPlacement = r->windowWidth > 0 && r->windowHeight > 0;
				}
			}
		}
		if (!r->isRandomInstance)
			SaveInstanceDocked(r->id, r->wantDockOnCreate == 1);
		if (isOpen) {
			PersistedInstanceState state;
			state.id = r->id;
			state.url = r->lastUrl;
			state.title = r->titleOverride;
			state.panelMode = static_cast<int>(r->panelMode);
			state.basicCtxMenu = r->basicCtxMenu;
			state.isRandomInstance = r->isRandomInstance;
			state.docked = docked;
			state.windowX = r->windowX;
			state.windowY = r->windowY;
			state.windowWidth = r->windowWidth;
			state.windowHeight = r->windowHeight;
			state.hasWindowPlacement = r->hasWindowPlacement;
			openStates.push_back(std::move(state));
		}
		LogF("[Persist] id='%s' hwnd=%p title='%s' panelMode=%d wantDock=%d lastUrl='%s' dockIdx=%d float=%d",
			kv.first.c_str(), (void*)r->hwnd, r->titleOverride.c_str(), (int)r->panelMode, r->wantDockOnCreate,
			r->lastUrl.c_str(), r->lastDockIdx, (int)r->lastDockFloat);
	}
	std::sort(openStates.begin(), openStates.end(), [](const auto& lhs, const auto& rhs) {
		return lhs.id < rhs.id;
	});
	SaveOpenInstanceStates(openStates);
	LogF("[Persist] saved %d open instance(s)", static_cast<int>(openStates.size()));
	LogRaw("[Persist] SaveInstanceStateAll end");
}

void LoadInstanceStateAll()
{
	StopInstanceRestoreTimer();
	if (!g_webViewSettings.restoreInstancesOnStartup) {
		LogRaw("[Restore] disabled; startup restoration is a no-op");
		return;
	}

	g_pendingInstanceRestore = LoadOpenInstanceStates();
	if (g_webViewSettings.restoreNamedInstancesOnly) {
		g_pendingInstanceRestore.erase(
			std::remove_if(g_pendingInstanceRestore.begin(), g_pendingInstanceRestore.end(),
				[](const PersistedInstanceState& state) { return state.isRandomInstance; }),
			g_pendingInstanceRestore.end());
	}
	if (g_pendingInstanceRestore.empty()) {
		LogRaw("[Restore] no matching open instances were saved");
		return;
	}

	g_pendingInstanceRestoreIndex = 0;
	g_instanceRestoreTimerRegistered = plugin_register &&
		plugin_register("timer", (void*)&RestoreNextInstance) != 0;
	LogF("[Restore] queued %d instance(s), namedOnly=%d timer=%d",
		static_cast<int>(g_pendingInstanceRestore.size()),
		(int)g_webViewSettings.restoreNamedInstancesOnly,
		(int)g_instanceRestoreTimerRegistered);
	if (!g_instanceRestoreTimerRegistered) {
		g_pendingInstanceRestore.clear();
		g_pendingInstanceRestoreIndex = 0;
	}
}

void CancelInstanceStateRestore()
{
	StopInstanceRestoreTimer();
}
