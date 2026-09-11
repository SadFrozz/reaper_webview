#pragma once

void RegisterHotkeyBridge();
void UnregisterHotkeyBridge();

#ifdef _WIN32
// Retarget a key pulled from an embedded WebView to REAPER's main window when
// forwarding is enabled. The caller leaves the message in the normal REAPER
// message loop so its configured accelerator table performs the action.
bool RouteWindowsWebViewKeyToReaper(MSG* message);
#endif
