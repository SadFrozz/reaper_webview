cmake_minimum_required(VERSION 3.15)
project(ReaperWebViewPlugin)

# --- Настройки для Windows ---
if(WIN32)
    find_package(NuGet REQUIRED)
    nuget_install(PACKAGE Microsoft.Web.WebView2 VERSION 1.0.2210.55)
    add_library(reaper_webview SHARED main.mm)
    
    target_include_directories(reaper_webview PRIVATE 
        ${CMAKE_CURRENT_BINARY_DIR}/packages/Microsoft.Web.WebView2.1.0.2210.55/build/native/include
        ${CMAKE_CURRENT_SOURCE_DIR}/dependencies
        ${CMAKE_CURRENT_SOURCE_DIR}/dependencies/sdk/sdk
        ${CMAKE_CURRENT_SOURCE_DIR}/dependencies/WDL
    )
    
    target_link_libraries(reaper_webview PRIVATE User32.lib Gdi32.lib)

# --- Настройки для macOS ---
elseif(APPLE)
    # Добавляем необходимые флаги для Objective-C++
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -x objective-c++ -std=c++11")
    set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fobjc-arc")
    
    add_library(reaper_webview MODULE main.mm)

    target_include_directories(reaper_webview PRIVATE 
        ${CMAKE_CURRENT_SOURCE_DIR}/dependencies
        ${CMAKE_CURRENT_SOURCE_DIR}/dependencies/sdk/sdk
        ${CMAKE_CURRENT_SOURCE_DIR}/dependencies/WDL
        ${CMAKE_CURRENT_SOURCE_DIR}/dependencies/WDL/swell
    )

    target_link_libraries(reaper_webview PRIVATE 
        "-framework Cocoa" 
        "-framework WebKit" 
        "-framework Foundation"
    )
    set_target_properties(reaper_webview PROPERTIES 
        SUFFIX .dylib
        BUNDLE FALSE
        MACOSX_BUNDLE FALSE
    )
endif()

# --- Общие настройки ---
set_target_properties(reaper_webview PROPERTIES PREFIX "")