cmake_minimum_required(VERSION 3.10)
project(reaper_webview)

set(SDK_PATH ${CMAKE_CURRENT_SOURCE_DIR}/sdk)
set(WDL_PATH ${CMAKE_CURRENT_SOURCE_DIR}/WDL)

include_directories(${SDK_PATH} ${WDL_PATH} ${CMAKE_CURRENT_SOURCE_DIR}/deps)

# Исходники теперь включают только необходимые модули
set(SOURCES
    main.cpp
)

if(WIN32)
    list(APPEND SOURCES webview_win.cpp main.rc)
elseif(APPLE)
    list(APPEND SOURCES webview_mac.mm "${WDL_PATH}/swell/swell-modstub.mm")
endif()

add_library(reaper_webview MODULE ${SOURCES})

target_compile_definitions(reaper_webview PRIVATE SWELL_PROVIDED_BY_APP)

if(APPLE)
    set_target_properties(reaper_webview PROPERTIES OUTPUT_NAME "reaper_webview" SUFFIX ".dylib" BUNDLE FALSE)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "10.13")
    set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")
    target_link_libraries(reaper_webview PRIVATE "-framework Cocoa" "-framework WebKit" "-framework AppKit" "-framework Carbon")

elseif(WIN32)
    set_target_properties(reaper_webview PROPERTIES SUFFIX ".dll")
    target_compile_definitions(reaper_webview PRIVATE _WIN32_WINNT=0x0601 NOMINMAX)
    target_link_libraries(reaper_webview comctl32 ole32 version shlwapi user32 oleaut32 advapi32)
endif()

set_target_properties(reaper_webview PROPERTIES LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}" RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")