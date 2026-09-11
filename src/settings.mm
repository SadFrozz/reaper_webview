#include "predef.h"
#include "globals.h"
#include "helpers.h"
#include "log.h"
#include "resource.h"
#include "settings.h"
#include "webview.h"

#ifndef _WIN32
SWELL_DEFINE_DIALOG_RESOURCE_BEGIN(
  IDD_RWV_PREFERENCES,
  SWELL_DLG_WS_CHILD | SWELL_DLG_WS_FLIPPED | SWELL_DLG_WS_NOAUTOSIZE,
  "WebView",
  300, 164, 1.7
)
  { nullptr, 0, nullptr, 0, 0, 0, 0, 0, 0 },
  { "Input and shortcuts", IDC_RWV_INPUT_GROUP, "button", WS_CHILD | WS_VISIBLE | BS_GROUPBOX, 8, 4, 284, 38, 0 },
  { "Forward REAPER shortcuts while WebView is focused", IDC_RWV_FORWARD_HOTKEYS, "button", WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX | WS_TABSTOP, 18, 15, 264, 12, 0 },
  { "Show Copy, Cut and Paste in the custom context menu", IDC_RWV_CLIPBOARD_MENU, "button", WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX | WS_TABSTOP, 18, 28, 264, 12, 0 },
  { "New WebView instances", IDC_RWV_INSTANCES_GROUP, "button", WS_CHILD | WS_VISIBLE | BS_GROUPBOX, 8, 48, 284, 44, 0 },
  { "Dock newly created instances by default", IDC_RWV_START_DOCKED, "button", WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX | WS_TABSTOP, 18, 59, 264, 12, 0 },
  { "Home page:", IDC_RWV_HOME_LABEL, "static", WS_CHILD | WS_VISIBLE, 18, 76, 40, 10, 0 },
  { "", IDC_RWV_HOME_PAGE, "edit", WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL, 60, 73, 222, 14, 0 },
  { "Startup restoration", IDC_RWV_RESTORE_GROUP, "button", WS_CHILD | WS_VISIBLE | BS_GROUPBOX, 8, 98, 284, 42, 0 },
  { "Restore open instances on startup", IDC_RWV_RESTORE_INSTANCES, "button", WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX | WS_TABSTOP, 18, 109, 264, 12, 0 },
  { "Restore named instances only", IDC_RWV_RESTORE_NAMED, "button", WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX | WS_TABSTOP, 28, 122, 254, 12, 0 },
  { "Instance-specific API options override the global defaults above.", IDC_RWV_NOTE, "static", WS_CHILD | WS_VISIBLE, 18, 146, 270, 12, 0 }
SWELL_DEFINE_DIALOG_RESOURCE_END(IDD_RWV_PREFERENCES)
#endif

WebViewSettings g_webViewSettings;

namespace {

constexpr const char* kSettingsSection = "reaper_webview";
constexpr int kPreferencesApplyButtonId = 0x478;
constexpr UINT kPreferencesApplyMessage = WM_USER * 2;

std::string InstanceKey(const char* prefix, const std::string& instanceId)
{
  static const char* digits = "0123456789abcdef";
  std::string key = prefix;
  key.reserve(key.size() + instanceId.size() * 2);
  for (unsigned char ch : instanceId) {
    key.push_back(digits[ch >> 4]);
    key.push_back(digits[ch & 0x0f]);
  }
  return key;
}

std::string HexEncode(const std::string& value)
{
  static const char* digits = "0123456789abcdef";
  std::string encoded;
  encoded.reserve(value.size() * 2);
  for (unsigned char ch : value) {
    encoded.push_back(digits[ch >> 4]);
    encoded.push_back(digits[ch & 0x0f]);
  }
  return encoded;
}

int HexDigit(char ch)
{
  if (ch >= '0' && ch <= '9') return ch - '0';
  if (ch >= 'a' && ch <= 'f') return ch - 'a' + 10;
  if (ch >= 'A' && ch <= 'F') return ch - 'A' + 10;
  return -1;
}

bool HexDecode(const std::string& encoded, std::string* value)
{
  if (!value || (encoded.size() & 1) != 0) return false;
  std::string decoded;
  decoded.reserve(encoded.size() / 2);
  for (size_t i = 0; i < encoded.size(); i += 2) {
    const int hi = HexDigit(encoded[i]);
    const int lo = HexDigit(encoded[i + 1]);
    if (hi < 0 || lo < 0) return false;
    decoded.push_back(static_cast<char>((hi << 4) | lo));
  }
  *value = std::move(decoded);
  return true;
}

const char* SettingsFile()
{
  return get_ini_file ? get_ini_file() : nullptr;
}

int ReadProfileInt(const char* key, int defaultValue, const char* file)
{
#ifdef _WIN32
  return GetPrivateProfileIntA(kSettingsSection, key, defaultValue, file);
#else
  return GetPrivateProfileInt(kSettingsSection, key, defaultValue, file);
#endif
}

void WriteProfileString(const char* key, const char* value, const char* file)
{
#ifdef _WIN32
  WritePrivateProfileStringA(kSettingsSection, key, value, file);
#else
  WritePrivateProfileString(kSettingsSection, key, value, file);
#endif
}

std::string ReadProfileString(const char* key, const char* file)
{
  std::vector<char> buffer(65536);
#ifdef _WIN32
  GetPrivateProfileStringA(kSettingsSection, key, "", buffer.data(), static_cast<DWORD>(buffer.size()), file);
#else
  GetPrivateProfileString(kSettingsSection, key, "", buffer.data(), static_cast<int>(buffer.size()), file);
#endif
  return buffer.data();
}

std::string RestoreKey(size_t index, const char* field)
{
  return "restore_instance_" + std::to_string(index) + "_" + field;
}

void SetCheckbox(HWND dialog, int id, bool checked)
{
  CheckDlgButton(dialog, id, checked ? BST_CHECKED : BST_UNCHECKED);
}

bool ReadCheckbox(HWND dialog, int id)
{
  return IsDlgButtonChecked(dialog, id) == BST_CHECKED;
}

void SetTextValue(HWND dialog, int id, const std::string& value)
{
#ifdef _WIN32
  const std::wstring wide = Widen(value);
  SetDlgItemTextW(dialog, id, wide.c_str());
#else
  SetDlgItemText(dialog, id, value.c_str());
#endif
}

std::string ReadTextValue(HWND dialog, int id)
{
#ifdef _WIN32
  HWND control = GetDlgItem(dialog, id);
  const int length = control ? GetWindowTextLengthW(control) : 0;
  std::vector<wchar_t> buffer(static_cast<size_t>(length) + 1);
  if (control) GetWindowTextW(control, buffer.data(), static_cast<int>(buffer.size()));
  return Narrow(buffer.data());
#else
  char buffer[4096]{};
  GetDlgItemText(dialog, id, buffer, sizeof(buffer));
  return buffer;
#endif
}

void ResizeControlToRightMargin(HWND dialog, int id, int rightMargin)
{
  HWND control = GetDlgItem(dialog, id);
  if (!control) return;
  RECT bounds{};
  GetWindowRect(control, &bounds);
  POINT topLeft{bounds.left, bounds.top};
  ScreenToClient(dialog, &topLeft);
  RECT client{};
  GetClientRect(dialog, &client);
  const int availableWidth = static_cast<int>(client.right - topLeft.x) - rightMargin;
  const int width = availableWidth > 1 ? availableWidth : 1;
  SetWindowPos(control, nullptr, topLeft.x, topLeft.y, width,
               bounds.bottom - bounds.top, SWP_NOZORDER | SWP_NOACTIVATE);
}

void LayoutPreferencesPage(HWND dialog)
{
  HWND firstGroup = GetDlgItem(dialog, IDC_RWV_INPUT_GROUP);
  if (!firstGroup) return;
  RECT groupBounds{};
  GetWindowRect(firstGroup, &groupBounds);
  POINT groupLeft{groupBounds.left, groupBounds.top};
  ScreenToClient(dialog, &groupLeft);
  const int groupLeftX = static_cast<int>(groupLeft.x);
  const int pageMargin = groupLeftX > 6 ? groupLeftX : 6;

  ResizeControlToRightMargin(dialog, IDC_RWV_INPUT_GROUP, pageMargin);
  ResizeControlToRightMargin(dialog, IDC_RWV_INSTANCES_GROUP, pageMargin);
  ResizeControlToRightMargin(dialog, IDC_RWV_RESTORE_GROUP, pageMargin);
  ResizeControlToRightMargin(dialog, IDC_RWV_FORWARD_HOTKEYS, pageMargin + 4);
  ResizeControlToRightMargin(dialog, IDC_RWV_CLIPBOARD_MENU, pageMargin + 4);
  ResizeControlToRightMargin(dialog, IDC_RWV_START_DOCKED, pageMargin + 4);
  ResizeControlToRightMargin(dialog, IDC_RWV_HOME_PAGE, pageMargin + 10);
  ResizeControlToRightMargin(dialog, IDC_RWV_RESTORE_INSTANCES, pageMargin + 4);
  ResizeControlToRightMargin(dialog, IDC_RWV_RESTORE_NAMED, pageMargin + 4);
  ResizeControlToRightMargin(dialog, IDC_RWV_NOTE, pageMargin + 4);
}

INT_PTR CALLBACK PreferencesDialogProc(HWND dialog, UINT message, WPARAM wParam, LPARAM)
{
  switch (message) {
    case WM_INITDIALOG:
      SetCheckbox(dialog, IDC_RWV_FORWARD_HOTKEYS, g_webViewSettings.forwardReaperHotkeys);
      SetCheckbox(dialog, IDC_RWV_CLIPBOARD_MENU, g_webViewSettings.showClipboardCommands);
      SetCheckbox(dialog, IDC_RWV_START_DOCKED, g_webViewSettings.startDocked);
      SetCheckbox(dialog, IDC_RWV_RESTORE_INSTANCES, g_webViewSettings.restoreInstancesOnStartup);
      SetCheckbox(dialog, IDC_RWV_RESTORE_NAMED, g_webViewSettings.restoreNamedInstancesOnly);
      SetTextValue(dialog, IDC_RWV_HOME_PAGE, g_webViewSettings.homePage);
      EnableWindow(GetDlgItem(dialog, IDC_RWV_RESTORE_NAMED), g_webViewSettings.restoreInstancesOnStartup);
      LayoutPreferencesPage(dialog);
      LogF("[Preferences] init dialog=%p parent=%p", dialog, GetParent(dialog));
      return 1;

    case WM_COMMAND:
      if (HIWORD(wParam) == BN_CLICKED) {
        switch (LOWORD(wParam)) {
          case IDC_RWV_FORWARD_HOTKEYS:
          case IDC_RWV_CLIPBOARD_MENU:
          case IDC_RWV_START_DOCKED:
          case IDC_RWV_RESTORE_NAMED:
            EnableWindow(GetDlgItem(GetParent(dialog), kPreferencesApplyButtonId), true);
            return 1;
          case IDC_RWV_RESTORE_INSTANCES:
            EnableWindow(GetDlgItem(dialog, IDC_RWV_RESTORE_NAMED),
                         ReadCheckbox(dialog, IDC_RWV_RESTORE_INSTANCES));
            EnableWindow(GetDlgItem(GetParent(dialog), kPreferencesApplyButtonId), true);
            return 1;
        }
      } else if (LOWORD(wParam) == IDC_RWV_HOME_PAGE && HIWORD(wParam) == EN_CHANGE) {
        EnableWindow(GetDlgItem(GetParent(dialog), kPreferencesApplyButtonId), true);
        return 1;
      }
      break;

    case WM_SIZE:
      LayoutPreferencesPage(dialog);
      return 1;

    case kPreferencesApplyMessage:
      g_webViewSettings.forwardReaperHotkeys = ReadCheckbox(dialog, IDC_RWV_FORWARD_HOTKEYS);
      g_webViewSettings.showClipboardCommands = ReadCheckbox(dialog, IDC_RWV_CLIPBOARD_MENU);
      g_webViewSettings.startDocked = ReadCheckbox(dialog, IDC_RWV_START_DOCKED);
      g_webViewSettings.restoreInstancesOnStartup = ReadCheckbox(dialog, IDC_RWV_RESTORE_INSTANCES);
      g_webViewSettings.restoreNamedInstancesOnly = ReadCheckbox(dialog, IDC_RWV_RESTORE_NAMED);
      {
        const std::string requested = ReadTextValue(dialog, IDC_RWV_HOME_PAGE);
        std::string normalized, external, reason;
        if (NormalizeOrDispatchURL(requested, normalized, external, reason) && !normalized.empty())
          g_webViewSettings.homePage = normalized;
        else
          g_webViewSettings.homePage = kDefaultURL;
        SetTextValue(dialog, IDC_RWV_HOME_PAGE, g_webViewSettings.homePage);
      }
      SaveWebViewSettings();
#ifdef _WIN32
      for (auto& entry : g_instances)
        if (entry.second) WinUpdateShortcutForwarding(entry.second.get());
#endif
      return 1;
  }
  return 0;
}

HWND CreatePreferencesPage(HWND parent)
{
  HWND page = CreateDialogParam((HINSTANCE)g_hInst, MAKEINTRESOURCE(IDD_RWV_PREFERENCES),
                                parent, PreferencesDialogProc, 0);
  LogF("[Preferences] create parent=%p page=%p actual_parent=%p style=0x%llx",
       parent, page, page ? GetParent(page) : nullptr,
       static_cast<unsigned long long>(page ? GetWindowLongPtr(page, GWL_STYLE) : 0));
  return page;
}

prefs_page_register_t g_preferencesPage{
  "reaper_webview",
  "WebView",
  &CreatePreferencesPage,
  0x9a,
  "",
  0,
  nullptr,
  nullptr,
  {},
};

bool g_preferencesRegistered = false;

} // namespace

void LoadWebViewSettings()
{
  const char* file = SettingsFile();
  if (!file) return;
  g_webViewSettings.forwardReaperHotkeys = ReadProfileInt("forward_reaper_hotkeys", 1, file) != 0;
  g_webViewSettings.showClipboardCommands = ReadProfileInt("show_clipboard_commands", 1, file) != 0;
  g_webViewSettings.startDocked = ReadProfileInt("start_docked", 0, file) != 0;
  g_webViewSettings.restoreInstancesOnStartup = ReadProfileInt("restore_instances_on_startup", 0, file) != 0;
  g_webViewSettings.restoreNamedInstancesOnly = ReadProfileInt("restore_named_instances_only", 1, file) != 0;
  g_webViewSettings.homePage = ReadProfileString("home_page", file);
  if (g_webViewSettings.homePage.empty()) g_webViewSettings.homePage = kDefaultURL;
  std::string normalizedHome, externalHome, homeReason;
  if (NormalizeOrDispatchURL(g_webViewSettings.homePage, normalizedHome,
                             externalHome, homeReason) && !normalizedHome.empty())
    g_webViewSettings.homePage = normalizedHome;
  else
    g_webViewSettings.homePage = kDefaultURL;
}

void SaveWebViewSettings()
{
  const char* file = SettingsFile();
  if (!file) return;
  WriteProfileString("forward_reaper_hotkeys", g_webViewSettings.forwardReaperHotkeys ? "1" : "0", file);
  WriteProfileString("show_clipboard_commands", g_webViewSettings.showClipboardCommands ? "1" : "0", file);
  WriteProfileString("start_docked", g_webViewSettings.startDocked ? "1" : "0", file);
  WriteProfileString("restore_instances_on_startup", g_webViewSettings.restoreInstancesOnStartup ? "1" : "0", file);
  WriteProfileString("restore_named_instances_only", g_webViewSettings.restoreNamedInstancesOnly ? "1" : "0", file);
  WriteProfileString("home_page", g_webViewSettings.homePage.c_str(), file);
}

bool LoadInstanceHotkeyForwarding(const std::string& instanceId)
{
  const char* file = SettingsFile();
  if (!file) return true;
  const std::string key = InstanceKey("instance_forward_hotkeys_", instanceId);
  return ReadProfileInt(key.c_str(), 1, file) != 0;
}

void SaveInstanceHotkeyForwarding(const std::string& instanceId, bool enabled)
{
  const char* file = SettingsFile();
  if (!file) return;
  const std::string key = InstanceKey("instance_forward_hotkeys_", instanceId);
  WriteProfileString(key.c_str(), enabled ? "1" : "0", file);
}

bool LoadInstanceDocked(const std::string& instanceId, bool* docked)
{
  if (!docked) return false;
  const char* file = SettingsFile();
  if (!file) return false;
  const std::string key = InstanceKey("instance_docked_", instanceId);
  const int value = ReadProfileInt(key.c_str(), -1, file);
  if (value < 0) return false;
  *docked = value != 0;
  return true;
}

void SaveInstanceDocked(const std::string& instanceId, bool docked)
{
  const char* file = SettingsFile();
  if (!file) return;
  const std::string key = InstanceKey("instance_docked_", instanceId);
  WriteProfileString(key.c_str(), docked ? "1" : "0", file);
}

std::vector<PersistedInstanceState> LoadOpenInstanceStates()
{
  std::vector<PersistedInstanceState> states;
  const char* file = SettingsFile();
  if (!file) return states;

  const int count = ReadProfileInt("restore_instance_count", 0, file);
  if (count <= 0 || count > 256) return states;
  states.reserve(static_cast<size_t>(count));
  for (int i = 0; i < count; ++i) {
    PersistedInstanceState state;
    const auto readEncoded = [&](const char* field, std::string* output) {
      const std::string key = RestoreKey(static_cast<size_t>(i), field);
      return HexDecode(ReadProfileString(key.c_str(), file), output);
    };
    if (!readEncoded("id", &state.id) || state.id.rfind("wv_", 0) != 0) continue;
    if (!readEncoded("url", &state.url) || !readEncoded("title", &state.title)) continue;

    const auto readInt = [&](const char* field, int fallback) {
      const std::string key = RestoreKey(static_cast<size_t>(i), field);
      return ReadProfileInt(key.c_str(), fallback, file);
    };
    state.panelMode = readInt("panel_mode", 0);
    if (state.panelMode < 0 || state.panelMode > 3) state.panelMode = 0;
    state.basicCtxMenu = readInt("basic_context_menu", 0) != 0;
    state.isRandomInstance = readInt("random", 0) != 0;
    state.docked = readInt("docked", 0) != 0;
    state.windowX = readInt("window_x", 0);
    state.windowY = readInt("window_y", 0);
    state.windowWidth = readInt("window_width", 900);
    state.windowHeight = readInt("window_height", 600);
    state.hasWindowPlacement = readInt("has_window_placement", 0) != 0 &&
                               state.windowWidth > 0 && state.windowHeight > 0;
    states.push_back(std::move(state));
  }
  return states;
}

void SaveOpenInstanceStates(const std::vector<PersistedInstanceState>& states)
{
  const char* file = SettingsFile();
  if (!file) return;
  WriteProfileString("restore_instance_count", std::to_string(states.size()).c_str(), file);
  for (size_t i = 0; i < states.size(); ++i) {
    const PersistedInstanceState& state = states[i];
    const auto write = [&](const char* field, const std::string& value) {
      const std::string key = RestoreKey(i, field);
      WriteProfileString(key.c_str(), value.c_str(), file);
    };
    const auto writeInt = [&](const char* field, int value) {
      write(field, std::to_string(value));
    };
    write("id", HexEncode(state.id));
    write("url", HexEncode(state.url));
    write("title", HexEncode(state.title));
    writeInt("panel_mode", state.panelMode);
    writeInt("basic_context_menu", state.basicCtxMenu ? 1 : 0);
    writeInt("random", state.isRandomInstance ? 1 : 0);
    writeInt("docked", state.docked ? 1 : 0);
    writeInt("window_x", state.windowX);
    writeInt("window_y", state.windowY);
    writeInt("window_width", state.windowWidth);
    writeInt("window_height", state.windowHeight);
    writeInt("has_window_placement", state.hasWindowPlacement ? 1 : 0);
  }
}

void RegisterPreferencesPage()
{
  if (g_preferencesRegistered || !plugin_register) return;
  g_preferencesRegistered = plugin_register("prefpage", &g_preferencesPage) != 0;
  LogF("[Preferences] registered=%d", (int)g_preferencesRegistered);
}

void UnregisterPreferencesPage()
{
  if (!g_preferencesRegistered || !plugin_register) return;
  plugin_register("-prefpage", &g_preferencesPage);
  g_preferencesRegistered = false;
}
