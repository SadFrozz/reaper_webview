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
* Док / плавающее окно с восстановлением размера и позиции
* Расширенное контекстное меню с Copy / Cut / Paste и минимальный режим
* Передача хоткеев в главную таблицу действий REAPER без перехвата ввода в HTML-полях
* Глобальное управление пробросом в Preferences и сохраняемый toggle для каждого именованного instance в контекстном меню
* Настраиваемая домашняя страница и опциональное восстановление открытых (в том числе docked) инстансов при запуске
  * Если протокол домашней страницы не указан, автоматически используется `https://`.
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
WDL, REAPER Extension SDK и WIL подключены как git submodules по схеме референсного проекта. WebView2 SDK распространяется Microsoft через NuGet и автоматически загружается CMake в `deps/webview2-sdk/` при конфигурации Windows:
```
deps/reaper-sdk/     (git submodule: REAPER Extension SDK)
deps/WDL/            (git submodule: WDL + SWELL + LICE)
deps/wil/            (git submodule: Windows Implementation Library)
deps/webview2-sdk/   (Microsoft WebView2 SDK NuGet package, downloaded by CMake)
```
Определите `RWV_WITH_WEBVIEW2` в исходнике, который действительно требует WebView2.

### Поиск
Windows: нативный API WebView2.  
macOS: JS helper `window.__rwvFind` (ограничение 5000, fallback подсчёт, повторное построение только при устаревании кэша).

### Структура файлов
```
src/                    исходники расширения
  platform/windows/     реализация WebView2
  platform/macos/       реализация WKWebView
include/reaper_webview/ заголовки расширения
resources/images/       общие изображения
resources/windows/      Windows RC-ресурсы
cmake/                  вспомогательные скрипты конфигурации/генерации
examples/               примеры ReaScript
deps/                   сторонние SDK и исходники
```

| Слой | Файлы | Назначение |
|------|-------|-----------|
| Точка входа | `src/main.mm` | Регистрация, жизненный цикл |
| API | `src/api.mm` | Реализация `WEBVIEW_Navigate` |
| Состояние | `src/globals.mm` | Инстансы, фокус |
| Хелперы | `src/helpers.mm` | Парсинг опций, утилиты |
| Настройки | `src/settings.mm` | Страница Preferences и сохранение параметров |
| Хоткеи | `src/hotkeys.mm` | Передача сочетаний клавиш в REAPER |
| Windows | `src/platform/windows/` | WebView2 + поиск |
| macOS | `src/platform/macos/` | WKWebView + JS поиск |
| Заголовки | `include/reaper_webview/` | Внутренние интерфейсы расширения |

### Roadmap (RU)
* Маршрутизация аудио WebView в аудиограф REAPER/ReaRoute. Требует отдельного захвата PCM на каждой платформе; WebView2 и WKWebView не предоставляют прямой PCM-output API.

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
* Dock / floating integration with placement restoration
* Extended context menu with Copy / Cut / Paste and an optional minimal mode
* REAPER shortcut forwarding without stealing input from HTML editors
* Global forwarding control in Preferences plus a persisted context-menu toggle for each named instance
* Configurable home page and optional startup restoration for open instances, including docked instances
  * Home-page addresses without a protocol automatically use `https://`.
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
WDL, the REAPER Extension SDK, and WIL are git submodules, following the reference project's dependency layout. Microsoft distributes the WebView2 SDK through NuGet, so CMake downloads it automatically into `deps/webview2-sdk/` when configuring Windows:
```
deps/reaper-sdk/     (git submodule: REAPER Extension SDK)
deps/WDL/            (git submodule: WDL + SWELL + LICE)
deps/wil/            (git submodule: Windows Implementation Library)
deps/webview2-sdk/   (Microsoft WebView2 SDK NuGet package, downloaded by CMake)
```
Define `RWV_WITH_WEBVIEW2` before including `predef.h` only where WebView2/WIL needed.

### Find-In-Page
| Aspect | Windows | macOS |
|--------|---------|-------|
| Highlight | Native WebView2 | JS range walker (`__rwvFind`) |
| Limit | Native | 5000 + fallback count |
| Navigation | Native wrap | Local index + JS spans |

### File-Layout
```
src/                    extension sources
  platform/windows/     WebView2 implementation
  platform/macos/       WKWebView implementation
include/reaper_webview/ extension headers
resources/images/       shared images
resources/windows/      Windows RC resources
cmake/                  configure-time and generation helpers
examples/               ReaScript examples
deps/                   third-party SDKs and sources
```

| Layer | Files | Purpose |
|-------|-------|---------|
| Entry | `src/main.mm` | Plugin entry / lifecycle |
| API | `src/api.mm` | `WEBVIEW_Navigate` export |
| State | `src/globals.mm` | Instance registry / focus |
| Helpers | `src/helpers.mm` | Option parsing and utilities |
| Settings | `src/settings.mm` | Preferences page and persisted options |
| Hotkeys | `src/hotkeys.mm` | REAPER shortcut forwarding |
| Windows | `src/platform/windows/` | WebView2 and native find |
| macOS | `src/platform/macos/` | WKWebView and JS find |
| Headers | `include/reaper_webview/` | Internal extension interfaces |

### Roadmap
* Route WebView audio into REAPER/ReaRoute. This requires platform-specific PCM capture because WebView2 and WKWebView don't expose a direct PCM-output API.

### License
MIT (see `LICENSE`). Third‑party components keep original licenses.

### Status
Active (core + find stable). API surface expanding.

Feel free to open issues for bugs, enhancement ideas, or clarifications.
