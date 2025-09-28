# Reaper WebView Extension

Embed modern web content (Edge WebView2 on Windows / WKWebView on macOS) inside REAPER as a dockable / floating panel with multi‑instance support and a scriptable API.

---

## Language / Язык

* [**Информация на русском**](#информация-на-русском)
* [**Information in English**](#information-in-english)

---

## Оглавление / Contents
* [Информация на русском](#информация-на-русском)
  * [Возможности](#возможности)
  * [Быстрая-установка](#быстрая-установка)
  * [API](#api)
  * [Сборка](#сборка)
  * [Зависимости](#зависимости)
  * [Поиск](#поиск)
  * [Структура-файлов](#структура-файлов)
  * [Roadmap (RU)](#roadmap-ru)
  * [Лицензия](#лицензия)
  * [Статус](#статус)
* [Information in English](#information-in-english)
  * [Features](#features)
  * [Quick-Install](#quick-install)
  * [API (English)](#api-english)
  * [Building](#building)
  * [Dependencies](#dependencies)
  * [Find-In-Page](#find-in-page)
  * [File-Layout](#file-layout)
  * [Roadmap](#roadmap)
  * [License](#license)
  * [Status](#status)

---

## Информация на русском

# Расширение WebView для REAPER

Встраивает браузер (WebView2 / WKWebView) в REAPER: докируемая или плавающая панель, несколько независимых инстансов, управляемый через ReaScript API.

### Возможности
* Windows (WebView2) и macOS (WKWebView)
* Несколько инстансов: `wv_default`, `random`, свои `wv_*`
* Переопределение заголовка вкладки / окна
* Док / плавающее окно, минимальное контекстное меню
* Поиск по странице (Ctrl+F / Cmd+F) с подсветкой всех совпадений, счётчиком и циклической навигацией
* Ограничение 5000 подсветок (macOS) + fallback-подсчёт
* Логирование (debug таргет)

### Быстрая установка
1. Скачать последний релиз: https://github.com/SadFrozz/reaper_webview/releases
2. Скопировать бинарник:
   * Windows: `%AppData%/REAPER/UserPlugins/reaper_webview.dll` (или `reaper_webview_debug.dll` для отладки и сбора логов работы плагина)
   * macOS: `~/Library/Application Support/REAPER/UserPlugins/reaper_webview.dylib` (или `reaper_webview_debug.dylib` для отладки и сбора логов работы плагина)
3. Перезапустить REAPER.
4. Использовать через ReaScript.
5. Смотреть изменения между версиями: `CHANGELOG.md`.

### API
Функция: `WEBVIEW_Navigate(url, optsJSON)`

Ключи в JSON: `SetTitle`, `InstanceId`, `ShowPanel`, `BasicCtxMenu`.

Пример (Lua):
```lua
reaper.WEBVIEW_Navigate("https://reaper.fm", '{"SetTitle":"Reaper Site"}')
```
Особенности:
* `InstanceId:"random"` создаёт последовательные `wv_N`.
* Идентификаторы без префикса `wv_` сворачиваются к `wv_default`.
* `url="0"` — не менять текущую страницу, только применить опции.

### Сборка
Windows (Debug):
```powershell
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build --config Debug --target reaper_webview_debug
copy build\Debug\reaper_webview_debug.dll "$env:APPDATA\REAPER\UserPlugins\reaper_webview_debug.dll"
```
macOS (Debug):
```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build --config Debug --target reaper_webview_debug
cp build/reaper_webview_debug.dylib "~/Library/Application Support/REAPER/UserPlugins/"
```
Таргеты: `reaper_webview` (Release), `reaper_webview_debug` (логирование).

### Зависимости
Минимум для Windows в `deps/`:
```
WebView2.h
WebView2EnvironmentOptions.h
wil/ (опционально)
```
Прочее:
```
sdk/  (REAPER Extension SDK)
WDL/  (WDL + SWELL + LICE)
```
Определите `RWV_WITH_WEBVIEW2` в исходнике, который действительно требует WebView2.

### Поиск
Windows: нативный API WebView2.  
macOS: JS helper `window.__rwvFind` (ограничение 5000, fallback подсчёт, повторное построение только при устаревании кэша).

### Структура файлов
| Слой | Файлы | Назначение |
|------|-------|-----------|
| Точка входа | `main.mm` | Регистрация, жизненный цикл |
| API | `api.*` | Реализация `WEBVIEW_Navigate` |
| Глобалы | `globals.*` | Инстансы, фокус |
| Хелперы | `helpers.*` | Парсинг опций, утилиты |
| Windows | `webview_win.cpp` | WebView2 + поиск |
| macOS | `webview_darwin.mm` | WKWebView + JS поиск |
| Include hub | `predef.h` | Централизация инклюдов |
| Логирование | `log.h` | Debug логгер |

### Roadmap (RU)
* Добавление настроек WebView в GUI-окно настроек REAPER
* Добавление возможности использования ReaRoute
* Реализация в контекстном меню функций "копировать", "вырезать" и "вставить"

### Лицензия
MIT (см. `LICENSE`).

### Статус
Активная разработка (ядро и поиск стабильны).

Приветствуются issue c сообщениями об ошибках, идеями улучшений или для уточнения непонятных моментов.

---

## Information in English

# Reaper WebView Extension

Embeds a modern web engine (WebView2 / WKWebView) into REAPER: dockable / floating panel, multiple instances, simple scriptable API.

### Features
* Windows (WebView2) + macOS (WKWebView)
* Multiple instances: `wv_default`, `random`, custom `wv_*`
* Title override per instance & focus tracking
* Dock / floating integration with REAPER docker
* Minimal optional context menu
* Unified find (Ctrl+F / Cmd+F) highlight‑all + counter + wrap
* 5000 highlight cap (macOS) + fallback counting
* Debug logging build target

### Quick Install
1. Download latest release: https://github.com/SadFrozz/reaper_webview/releases
2. Copy the binary:
  * Windows: `%AppData%/REAPER/UserPlugins/reaper_webview.dll` (or `reaper_webview_debug.dll` for debugging & log collection)
  * macOS: `~/Library/Application Support/REAPER/UserPlugins/reaper_webview.dylib` (or `reaper_webview_debug.dylib` for debugging & log collection)
3. Restart REAPER.
4. Use via ReaScript (`WEBVIEW_Navigate`).
5. See version changes in `CHANGELOG.md`.

### API (English)
Function: `WEBVIEW_Navigate(url, optsJSON)`

JSON keys: `SetTitle`, `InstanceId`, `ShowPanel`, `BasicCtxMenu`.

Example (Lua):
```lua
reaper.WEBVIEW_Navigate("https://reaper.fm", '{"SetTitle":"Reaper Site"}')
```
Notes:
* `InstanceId:"random"` -> sequential `wv_N`
* Non `wv_` ids fold into `wv_default`
* `url="0"` keeps current page, applies options

### Building
Windows (Debug):
```powershell
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build --config Debug --target reaper_webview_debug
copy build\Debug\reaper_webview_debug.dll "$env:APPDATA\REAPER\UserPlugins\reaper_webview_debug.dll"
```
macOS (Debug):
```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Debug
cmake --build build --config Debug --target reaper_webview_debug
cp build/reaper_webview_debug.dylib "~/Library/Application Support/REAPER/UserPlugins/"
```
Targets: `reaper_webview` (Release), `reaper_webview_debug` (logging).

### Dependencies
Minimum (Windows) in `deps/`:
```
WebView2.h
WebView2EnvironmentOptions.h
wil/ (optional)
```
Other trees:
```
sdk/  (REAPER SDK)
WDL/  (WDL + SWELL + LICE)
```
Define `RWV_WITH_WEBVIEW2` before including `predef.h` only where WebView2/WIL needed.

### Find-In-Page
| Aspect | Windows | macOS |
|--------|---------|-------|
| Highlight | Native WebView2 | JS range walker (`__rwvFind`) |
| Limit | Native | 5000 + fallback count |
| Navigation | Native wrap | Local index + JS spans |

### File-Layout
| Layer | Files | Purpose |
|-------|-------|---------|
| Entry | `main.mm` | Plugin entry / lifecycle |
| API | `api.*` | `WEBVIEW_Navigate` export |
| Globals | `globals.*` | Instance registry / focus |
| Helpers | `helpers.*` | Option parsing & utils |
| Windows | `webview_win.cpp` | WebView2 + native find |
| macOS | `webview_darwin.mm` | WKWebView + JS find |
| Include Hub | `predef.h` | Aggregated includes |
| Logging | `log.h` | Debug logger |

### Roadmap
* Expose WebView-specific settings inside REAPER's preferences dialog
* Support using ReaRoute within embedded webview contexts
* Implement context menu actions: Copy, Cut, Paste

### License
MIT (see `LICENSE`). Third‑party components keep original licenses.

### Status
Active (core + find stable). API surface expanding.

Feel free to open issues for bugs, enhancement ideas, or clarifications.