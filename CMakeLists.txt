cmake_minimum_required(VERSION 3.10)
project(reaper_webview)

# --- ОБЩИЕ НАСТРОЙКИ И ИСХОДНЫЕ ФАЙЛЫ ---
set(SDK_PATH ${CMAKE_CURRENT_SOURCE_DIR}/sdk)
set(WDL_PATH ${CMAKE_CURRENT_SOURCE_DIR}/WDL)

include_directories(${SDK_PATH} ${WDL_PATH})
set(SOURCES main.mm)

# --- ПЛАТФОРМО-ЗАВИСИМЫЕ НАСТРОЙКИ ---
if(APPLE)
    # --- Настройки для macOS ---
    file(GLOB SWELL_SOURCES
        "${WDL_PATH}/swell/swell-dlggen-generic.cpp"
        "${WDL_PATH}/swell/swell-menugen-generic.cpp"
        "${WDL_PATH}/swell/swell-miscdlg-generic.cpp"
        "${WDL_PATH}/swell/swell-wnd-generic.cpp"
        "${WDL_PATH}/swell/swell-gdi-generic.cpp"
        "${WDL_PATH}/swell/swell-OSX.m"
    )
    list(APPEND SOURCES ${SWELL_SOURCES})
    add_definitions(-DSWELL_PROVIDED_BY_APP -DSWELL_TARGET_OSX)

elseif(WIN32)
    # --- Настройки для Windows ---
    file(GLOB SWELL_SOURCES
        "${WDL_PATH}/swell/swell-gdi-windows.cpp"
        "${WDL_PATH}/swell/swell-menu-windows.cpp"
        "${WDL_PATH}/swell/swell-wnd-windows.cpp"
    )
    list(APPEND SOURCES ${SWELL_SOURCES})
    add_definitions(-DSWELL_PROVIDED_BY_APP -DNOMINMAX -D_CRT_SECURE_NO_WARNINGS)
    include_directories(${CMAKE_CURRENT_SOURCE_DIR}/deps)
endif()

# --- СОЗДАНИЕ И ЛИНКОВКА БИБЛИОТЕКИ ---
add_library(reaper_webview MODULE ${SOURCES})

# --- ФИНАЛЬНАЯ ЛИНКОВКА ---
if(APPLE)
    target_link_libraries(reaper_webview "-framework Cocoa" "-framework WebKit")
    set_target_properties(reaper_webview PROPERTIES SUFFIX ".dylib")
elseif(WIN32)
    target_link_libraries(reaper_webview gdi32 user32 comctl32 ole32)
    find_library(WEBVIEW2_LOADER_LIB WebView2Loader.lib HINTS "${CMAKE_CURRENT_SOURCE_DIR}/webview2-sdk/build/native/x64")
    if(WEBVIEW2_LOADER_LIB)
        target_link_libraries(reaper_webview ${WEBVIEW2_LOADER_LIB})
    endif()
    set_target_properties(reaper_webview PROPERTIES SUFFIX ".dll")
endif()