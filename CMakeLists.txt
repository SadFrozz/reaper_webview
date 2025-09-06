cmake_minimum_required(VERSION 3.10)
project(reaper_webview)

# Подключаем стандартные модули
include(CheckIncludeFile)
include(CheckFunctionExists)

# Настройка путей
set(SDK_PATH ${CMAKE_CURRENT_SOURCE_DIR}/sdk)
set(WDL_PATH ${CMAKE_CURRENT_SOURCE_DIR}/WDL)

# Добавляем include директории
include_directories(${SDK_PATH})
include_directories(${WDL_PATH})
include_directories(${WDL_PATH}/swell)
include_directories(${CMAKE_CURRENT_SOURCE_DIR}/deps) # Для WebView2 и WIL

# Добавляем исходники
set(SOURCES main.mm)

# Создаем библиотеку
add_library(reaper_webview MODULE ${SOURCES})

# Настройки для разных платформ
if(APPLE)
    # Настройки для macOS
    set_target_properties(reaper_webview PROPERTIES
        OUTPUT_NAME "reaper_webview"
        SUFFIX ".dylib"
        BUNDLE FALSE)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "10.13")
    set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")

    # Добавляем список исходных файлов SWELL
    set(SWELL_SOURCES
        # Общие (generic) файлы SWELL
        
        ${WDL_PATH}/swell/swell.cpp
        ${WDL_PATH}/swell/swell-ini.cpp
        ${WDL_PATH}/swell/swell-misc-generic.cpp
        ${WDL_PATH}/swell/swell-gdi-generic.cpp
        ${WDL_PATH}/swell/swell-dlg-generic.cpp
        ${WDL_PATH}/swell/swell-menu-generic.cpp
        ${WDL_PATH}/swell/swell-kb-generic.cpp
        ${WDL_PATH}/swell/swell-wnd-generic.cpp

        # Специфичные для macOS реализации (Objective-C++)
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
    target_sources(reaper_webview PRIVATE ${SWELL_SOURCES})

    # Линкуем необходимые фреймворки
    
    target_link_libraries(reaper_webview PRIVATE
        "-framework Cocoa"
        "-framework WebKit"
        "-framework AppKit"
        "-framework Carbon"
    )

elseif(WIN32)
    # Настройки для Windows
    set_target_properties(reaper_webview PROPERTIES SUFFIX ".dll")

    target_compile_definitions(reaper_webview PRIVATE
        _WIN32_WINNT=0x0601
        
        NOMINMAX
        WIN32_LEAN_AND_MEAN
        _CRT_SECURE_NO_WARNINGS
        SWELL_TARGET_WIN32 # <--- ИЗМЕНЕНИЕ: Явно указываем таргет SWELL
    )
    
    # Добавляем линковку с Win32 API и WebView2
    target_link_libraries(reaper_webview
        comctl32
        ole32
        version
        shlwapi
        user32
        oleaut32
        advapi32)
    

    # Динамическая линковка через LoadLibrary в коде уже используется,
    # поэтому дополнительная линковка здесь не требуется.
    

endif()

# Установка выходного директория
set_target_properties(reaper_webview PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})