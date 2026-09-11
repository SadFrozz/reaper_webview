#include "predef.h"
#include "globals.h"
#include "log.h"
#include "settings.h"
#include "webview.h"

#ifdef __APPLE__
#import <AppKit/AppKit.h>
#endif

namespace {

#ifdef __APPLE__
// Hardware key codes for the ANSI letter positions used by editing commands.
// Unlike charactersIgnoringModifiers/message.wParam, these do not change when
// the user switches between Latin and Cyrillic keyboard layouts.
WPARAM MacPhysicalCommandKey()
{
  NSEvent* event = [NSApp currentEvent];
  if (!event || event.type != NSEventTypeKeyDown) return 0;

  switch (event.keyCode) {
    case 0:  return 'A';
    case 3:  return 'F';
    case 6:  return 'Z';
    case 7:  return 'X';
    case 8:  return 'C';
    case 9:  return 'V';
    case 16: return 'Y';
    default: return 0;
  }
}
#endif

bool IsWebViewTarget(HWND target)
{
  if (!target) target = GetFocus();
  if (!target) return false;

  for (const auto& entry : g_instances) {
    const WebViewInstanceRecord* rec = entry.second.get();
    if (!rec || !rec->hwnd || !IsWindow(rec->hwnd)) continue;
    if (target == rec->hwnd || IsChild(rec->hwnd, target)) return true;
  }
  return false;
}

WebViewInstanceRecord* FindInstanceForTarget(HWND target)
{
  if (!target) target = GetFocus();
  for (const auto& entry : g_instances) {
    WebViewInstanceRecord* rec = entry.second.get();
    if (!rec || !rec->hwnd || !IsWindow(rec->hwnd)) continue;
    if (target == rec->hwnd || IsChild(rec->hwnd, target)) return rec;
  }
  return nullptr;
}

WebViewInstanceRecord* ResolveFocusedInstance(HWND target)
{
  if (WebViewInstanceRecord* direct = FindInstanceForTarget(target)) return direct;

  WebViewInstanceRecord* focused = nullptr;
  for (const auto& entry : g_instances) {
    WebViewInstanceRecord* rec = entry.second.get();
    if (!rec || !rec->hwnd || !IsWindow(rec->hwnd)) continue;
    if (!rec->browserHasFocus && !rec->findFieldFocused) continue;
    if (!focused || rec->lastFocusTick > focused->lastFocusTick) focused = rec;
  }
  return focused;
}

bool IsFindFieldTarget(const MSG& message)
{
  const WebViewInstanceRecord* rec = FindInstanceForTarget(message.hwnd);
  return rec && rec->showFindBar && rec->findFieldFocused;
}

bool IsPluginEditingShortcut(const MSG& message)
{
#ifdef _WIN32
  const bool primaryModifier = (GetKeyState(VK_CONTROL) & 0x8000) != 0;
#else
  const bool primaryModifier = ([NSEvent modifierFlags] & NSEventModifierFlagCommand) != 0;
#endif
  if (!primaryModifier) return false;

  WPARAM key = message.wParam;
#ifdef __APPLE__
  if (const WPARAM physicalKey = MacPhysicalCommandKey()) key = physicalKey;
#endif
  if (key >= 'a' && key <= 'z') key -= ('a' - 'A');
  // Keep browser and find-field editing local. Besides the required commands,
  // preserve undo/redo so enabling REAPER shortcut forwarding cannot degrade
  // ordinary text editing inside the embedded page.
  return key == 'A' || key == 'C' || key == 'F' || key == 'V' ||
         key == 'X' || key == 'Y' || key == 'Z';
}

#ifdef __APPLE__
bool DispatchMacEditingShortcut(WebViewInstanceRecord* rec, const MSG& message)
{
  if (!rec || !rec->webView || !IsPluginEditingShortcut(message)) return false;

  WPARAM key = MacPhysicalCommandKey();
  if (!key) key = message.wParam;
  if (key >= 'a' && key <= 'z') key -= ('a' - 'A');
  SEL action = nullptr;
  switch (key) {
    case 'A': action = @selector(selectAll:); break;
    case 'C': action = @selector(copy:); break;
    case 'X': action = @selector(cut:); break;
    case 'V': action = @selector(paste:); break;
    case 'Y': action = @selector(redo:); break;
    case 'Z':
      action = ([NSEvent modifierFlags] & NSEventModifierFlagShift)
                   ? @selector(redo:)
                   : @selector(undo:);
      break;
    default: return false; // Cmd+F is owned by the find monitor.
  }

  NSWindow* window = [(WKWebView*)rec->webView window];
  NSResponder* responder = window ? [window firstResponder] : nil;
  const BOOL handled = responder && [NSApp sendAction:action to:responder from:rec->webView];
  LogF("[Hotkeys][mac-edit] key=%c action=%s handled=%d responder=%s",
       (char)key, sel_getName(action), (int)handled,
       responder ? object_getClassName(responder) : "<none>");
  return handled == YES;
}
#endif

bool IsPluginOwnedKey(const MSG& message)
{
  WebViewInstanceRecord* rec = FindInstanceForTarget(message.hwnd);
  // Ordinary typing and editing shortcuts must stay in the page while an HTML
  // editor owns focus. The injected focus bridge maintains this state for each
  // WebView instance, including contenteditable elements.
  if (rec && rec->webContentEditing) return true;
  // The accelerator callback can report the WebView host instead of the native
  // field on macOS, so use focus state maintained by the field delegate.
  if (IsFindFieldTarget(message)) return true;
  if (IsPluginEditingShortcut(message)) return true;
  return false;
}

#ifdef _WIN32
bool RouteWindowsWebViewKeyToReaperImpl(MSG* message)
{
  if (!message ||
      (message->message != WM_KEYDOWN && message->message != WM_SYSKEYDOWN))
    return false;

  WebViewInstanceRecord* rec = ResolveFocusedInstance(message->hwnd);
  if (!rec) return false;
  switch (message->wParam) {
    case VK_SHIFT:
    case VK_CONTROL:
    case VK_MENU:
    case VK_LWIN:
    case VK_RWIN:
    case VK_CAPITAL:
    case VK_NUMLOCK:
    case VK_SCROLL:
      return false;
  }
  if (IsPluginOwnedKey(*message)) return false;
  if (!g_webViewSettings.forwardReaperHotkeys || !rec->forwardReaperHotkeys)
    return false;
  if (!g_hwndParent || !IsWindow(g_hwndParent)) return false;
  if (message->hwnd == g_hwndParent) return false;

  LogF("[Hotkeys][route] id='%s' key=%llu source=%p target=%p",
       rec->id.c_str(), (unsigned long long)message->wParam,
       (void*)message->hwnd, (void*)g_hwndParent);
  message->hwnd = g_hwndParent;
  return true;
}
#endif

int TranslateWebViewAccelerator(MSG* message, accelerator_register_t*)
{
  if (!message) return 0;
  WebViewInstanceRecord* targetRec = ResolveFocusedInstance(message->hwnd);
  const bool webViewTarget = targetRec != nullptr || IsWebViewTarget(message->hwnd);
  if (message->message == WM_KEYDOWN || message->message == WM_SYSKEYDOWN) {
    LogF("[Hotkeys][bridge] key=%llu hwnd=%p target=%d instance='%s' global=%d instanceGate=%d editing=%d find=%d",
         (unsigned long long)message->wParam, (void*)message->hwnd, (int)webViewTarget,
         targetRec ? targetRec->id.c_str() : "", (int)g_webViewSettings.forwardReaperHotkeys,
         targetRec ? (int)targetRec->forwardReaperHotkeys : -1,
         targetRec ? (int)targetRec->webContentEditing : -1,
         targetRec ? (int)targetRec->findFieldFocused : -1);
  }
  if (!webViewTarget) return 0;
  if (message->message != WM_KEYDOWN && message->message != WM_SYSKEYDOWN)
    return -1;

#ifdef __APPLE__
  WebViewInstanceRecord* rec = targetRec;
  if (rec && rec->showFindBar && rec->findFieldFocused &&
      message->wParam == VK_ESCAPE) {
    rec->findFieldFocused = false;
    rec->showFindBar = false;
    if (rec->findBarView) [rec->findBarView setHidden:YES];
    LayoutTitleBarAndWebView(rec->hwnd,
                            rec->titleBarView && ![rec->titleBarView isHidden]);
    NSWindow* window = rec->webView ? [rec->webView window] : nil;
    if (window && rec->webView) {
      [window makeFirstResponder:rec->webView];
      MacRestorePageFocus(rec);
    }
    LogRaw("[Find] close via Escape (macOS accelerator)");
    return 1;
  }
#endif

#ifdef __APPLE__
  // Cocoa edit commands must start at WKWebView's internal first responder.
  // Sending them explicitly avoids SWELL becoming the head of the responder
  // chain when REAPER's accelerator hook owns the key event.
  if (targetRec && DispatchMacEditingShortcut(targetRec, *message)) return 1;
#endif

  // Plug-in commands take priority over REAPER's action table.
  if (IsPluginOwnedKey(*message)) {
#ifdef __APPLE__
    // REAPER's -1 route targets the SWELL host window. WKWebView editing
    // commands (selectAll:, copy:, cut:, paste:, undo:) need the original
    // Cocoa event so AppKit can dispatch them through the responder chain.
    return -10;
#else
    return -1;
#endif
  }

  // The global preference is the master switch; named-instance toggles can
  // further restrict forwarding but never override a disabled global switch.
  if (!g_webViewSettings.forwardReaperHotkeys) return -1;
  if (targetRec && !targetRec->forwardReaperHotkeys) return -1;

  // REAPER 5.24+: process the event through the main action section even when
  // focus is inside WebView's internal text field.
  return -667;
}

accelerator_register_t g_hotkeyBridge{
    &TranslateWebViewAccelerator,
    true,
    nullptr,
};
bool g_registered = false;

} // namespace

#ifdef _WIN32
bool RouteWindowsWebViewKeyToReaper(MSG* message)
{
  return RouteWindowsWebViewKeyToReaperImpl(message);
}
#endif

void RegisterHotkeyBridge()
{
  if (g_registered || !plugin_register) return;
  g_registered = plugin_register("accelerator", &g_hotkeyBridge) != 0;
  LogF("[Hotkeys] accelerator bridge registered=%d", (int)g_registered);
}

void UnregisterHotkeyBridge()
{
  if (!g_registered || !plugin_register) return;
  plugin_register("-accelerator", &g_hotkeyBridge);
  g_registered = false;
  LogRaw("[Hotkeys] accelerator bridge unregistered");
}
