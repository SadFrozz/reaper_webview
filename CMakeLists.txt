cmake_minimum_required(VERSION 3.15)
project(ReaperWebViewPlugin)

# --- Настройки для Windows ---
if(WIN32)
    find_package(NuGet REQUIRED)
    nuget_install(PACKAGE Microsoft.Web.WebView2 VERSION 1.0.2210.55)
    add_library(reaper_webview SHARED main.mm)
    
    target_include_directories(reaper_webview PRIVATE 
        ${CMAKE_CURRENT_BINARY_DIR}/packages/Microsoft.Web.WebView2.1.0.2210.55/build/native/include
    )
    target_link_libraries(reaper_webview PRIVATE user32 gdi32)

# --- Настройки для macOS ---
elseif(APPLE)
    set_source_files_properties(main.mm PROPERTIES COMPILE_FLAGS "-x objective-c++")
    add_library(reaper_webview MODULE main.mm)

    target_link_libraries(reaper_webview PRIVATE "-framework Cocoa" "-framework WebKit")
    set_target_properties(reaper_webview PROPERTIES SUFFIX .dylib)
endif()

# --- Общие настройки ---
target_include_directories(reaper_webview PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/sdk)
set_target_properties(reaper_webview PROPERTIES PREFIX "")