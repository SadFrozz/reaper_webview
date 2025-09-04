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
    find_library(COCOA_LIBRARY Cocoa)
    find_library(WEBKIT_LIBRARY WebKit)
    target_link_libraries(reaper_webview ${COCOA_LIBRARY} ${WEBKIT_LIBRARY})
elseif(WIN32)
    # Настройки для Windows
    set_target_properties(reaper_webview PROPERTIES SUFFIX ".dll")
    
    # Добавляем пути к зависимостям WebView2 и WIL
    include_directories(${CMAKE_CURRENT_SOURCE_DIR}/deps)
    
    target_compile_definitions(reaper_webview PRIVATE 
        _WIN32_WINNT=0x0601
        NOMINMAX
        WIN32_LEAN_AND_MEAN)
    target_link_libraries(reaper_webview 
        comctl32 
        ole32 
        version 
        shlwapi
        user32)
endif()

# Установка выходного директория
set_target_properties(reaper_webview PROPERTIES 
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})