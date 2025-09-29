# Changelog

All notable changes to this project will be documented in this file.

Format:
- Each version starts with a heading `## vX.Y.Z` (optionally suffixed with status like Alpha/Beta).
- Newest entries on top.
- Keep entries concise; detailed implementation notes go to commits/PRs.

## v0.1.1 Beta
### Changed
- macOS find bar: removed ad-hoc pixel shift constants; unified intrinsic vertical centering for controls.
- Checkbox label vertical alignment refined via baseline offset (improved optical centering, no frame hacks).
- Navigation arrow buttons now inherit theme text color (consistent with text field / counter / checkbox).

### Fixed
- Slight misalignment of macOS find bar checkbox text relative to other controls.

### Planned (Roadmap Snapshot)
- (unchanged) WebView settings exposure inside REAPER preferences.
- (unchanged) ReaRoute usage support.
- (unchanged) Copy/Cut/Paste in custom context menu.

## v0.1.0 Beta
### Added
- macOS find-in-page implementation achieving parity with Windows (highlight-all, counter, navigation, case handling).
- Multi-instance webview management (`wv_default`, `random`, custom prefixed IDs).
- ReaScript API function `WEBVIEW_Navigate` with options: `SetTitle`, `InstanceId`, `ShowPanel`, `BasicCtxMenu`.
- Title override system with per-instance persistence.
- Basic/minimal context menu mode.
- Debug logging target (`reaper_webview_debug`) with scoped tags ([Find], [FocusTick], etc.).
- Bilingual README (RU/EN) with structured TOC and dependency clarification.
- MIT license file.
- GitHub Actions CI: cross-platform build + tag-based release packaging.

### Changed
- Unified comment language (removed Russian comments in code, now English only in source).
- Optimized macOS JS highlight engine (`window.__rwvFind`) with caching & fallback counting.

### Planned (Roadmap Snapshot)
- WebView settings exposure inside REAPER preferences.
- ReaRoute usage support.
- Copy/Cut/Paste in custom context menu.

## v0.0.1 Alpha
### Added
- Initial project bootstrap: CMake configuration (Windows/macOS targets).
- Basic WebView2 (Windows) and WKWebView (macOS) embedding.
- Simple navigation handling and panel docking.
- Initial helpers, globals, and API scaffolding.

---

(End of file)
