cmake_minimum_required(VERSION 3.10)
project(reaper_webview)

set(CMAKE_MODULE_PATH ${CMAKE_MODULE_PATH} "${CMAKE_CURRENT_SOURCE_DIR}/cmake")

set(CMAKE_SHARED_LIBRARY_SUFFIX ".dylib")

set(CMAKE_CXX_STANDARD 11)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(reaper_webview MODULE main.mm)

target_include_directories(reaper_webview PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/sdk/sdk
    ${CMAKE_CURRENT_SOURCE_DIR}/sdk/WDL
    ${CMAKE_CURRENT_SOURCE_DIR}/sdk/WDL/swell
)

set_target_properties(reaper_webview PROPERTIES
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}
    PREFIX ""
)

if(APPLE)
    target_link_libraries(reaper_webview
        "-framework Cocoa"
        "-framework WebKit"
    )
    set_target_properties(reaper_webview PROPERTIES
        INSTALL_NAME_DIR "@rpath"
    )
endif()