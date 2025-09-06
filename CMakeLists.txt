cmake_minimum_required(VERSION 3.16)
project(reaper_webview)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Настройка путей
set(SDK_PATH ${CMAKE_CURRENT_SOURCE_DIR}/sdk)
set(WDL_PATH ${CMAKE_CURRENT_SOURCE_DIR}/WDL)

# Добавляем include директории
include_directories(${SDK_PATH} ${WDL_PATH} ${WDL_PATH}/swell)

# Исходный файл плагина
set(SOURCES main.mm)

add_library(reaper_webview MODULE ${SOURCES})

# --- Настройки для macOS ---
if(APPLE)
    set_target_properties(reaper_webview PROPERTIES
        OUTPUT_NAME "reaper_webview"
        SUFFIX ".dylib"
        BUNDLE FALSE)

    # Исходники SWELL для macOS (общие + специфичные)
    target_sources(reaper_webview PRIVATE
        # Общие (generic) файлы
        ${WDL_PATH}/swell/swell.cpp
        ${WDL_PATH}/swell/swell-ini.cpp
        ${WDL_PATH}/swell/swell-misc-generic.cpp
        ${WDL_PATH}/swell/swell-gdi-generic.cpp
        ${WDL_PATH}/swell/swell-dlg-generic.cpp
        ${WDL_PATH}/swell/swell-menu-generic.cpp
        ${WDL_PATH}/swell/swell-kb-generic.cpp
        ${WDL_PATH}/swell/swell-wnd-generic.cpp
        # Специфичные для macOS
        ${WDL_PATH}/swell/swell-dlg.mm
        ${WDL_PATH}/swell/swell-gdi.mm
        ${WDL_PATH}/swell/swell-kb.mm
        ${WDL_PATH}/swell/swell-menu.mm
        ${WDL_PATH}/swell/swell-misc.mm
        ${WDL_PATH}/swell/swell-miscdlg.mm
        ${WDL_PATH}/swell/swell-wnd.mm
        ${WDL_PATH}/swell/swell-appstub.mm
        ${WDL_PATH}/swell/swell-modstub.mm
    )

    # Линкуем фреймворки
    target_link_libraries(reaper_webview PRIVATE
        "-framework Cocoa"
        "-framework WebKit"
    )

# --- Настройки для Windows ---
elseif(WIN32)
    set_target_properties(reaper_webview PROPERTIES SUFFIX ".dll")

    # На Windows SWELL - это в основном заголовочные файлы,
    # компилировать его исходники не нужно, так как они конфликтуют с WinAPI.
    # Достаточно только include_directories.

    # Добавляем пути к зависимостям WebView2 и WIL
    include_directories(${CMAKE_CURRENT_SOURCE_DIR}/deps)

    target_compile_definitions(reaper_webview PRIVATE
        _WIN32_WINNT=0x0601
        NOMINMAX
        WIN32_LEAN_AND_MEAN
        _CRT_SECURE_NO_WARNINGS)

    # Линковка с системными библиотеками
    target_link_libraries(reaper_webview PRIVATE
        user32 gdi32 shell32 ole32 oleaut32 comctl32 shlwapi version)

    # Линковка с WebView2
    add_library(WebView2LoaderStatic STATIC IMPORTED)
    set_target_properties(WebView2LoaderStatic PROPERTIES
        IMPORTED_LOCATION "${CMAKE_CURRENT_SOURCE_DIR}/webview2-sdk/build/native/x64/WebView2LoaderStatic.lib")
    target_link_libraries(reaper_webview PRIVATE WebView2LoaderStatic)

endif()