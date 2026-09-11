#pragma once

#include <string>
#include <vector>

struct WebViewSettings {
  bool forwardReaperHotkeys = true;
  bool showClipboardCommands = true;
  bool startDocked = false;
  bool restoreInstancesOnStartup = false;
  bool restoreNamedInstancesOnly = true;
  std::string homePage = "https://www.reaper.fm/";
};

struct PersistedInstanceState {
  std::string id;
  std::string url;
  std::string title;
  int panelMode = 0;
  bool basicCtxMenu = false;
  bool isRandomInstance = false;
  bool docked = false;
  int windowX = 0;
  int windowY = 0;
  int windowWidth = 900;
  int windowHeight = 600;
  bool hasWindowPlacement = false;
};

extern WebViewSettings g_webViewSettings;

void LoadWebViewSettings();
void SaveWebViewSettings();
bool LoadInstanceHotkeyForwarding(const std::string& instanceId);
void SaveInstanceHotkeyForwarding(const std::string& instanceId, bool enabled);
bool LoadInstanceDocked(const std::string& instanceId, bool* docked);
void SaveInstanceDocked(const std::string& instanceId, bool docked);
std::vector<PersistedInstanceState> LoadOpenInstanceStates();
void SaveOpenInstanceStates(const std::vector<PersistedInstanceState>& states);
void RegisterPreferencesPage();
void UnregisterPreferencesPage();
