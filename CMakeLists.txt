cmake_minimum_required(VERSION 3.20)

project(reaper_webview VERSION 0.2.0 LANGUAGES C CXX)

if(NOT WIN32 AND NOT APPLE)
    message(FATAL_ERROR "reaper_webview currently supports Windows and macOS only")
endif()

if(APPLE)
    enable_language(OBJCXX)
endif()

set(RWV_DEPS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/deps")
set(RWV_REAPER_SDK_DIR "${RWV_DEPS_DIR}/reaper-sdk/sdk")
set(RWV_WDL_DIR "${RWV_DEPS_DIR}/WDL/WDL")
set(RWV_WIL_DIR "${RWV_DEPS_DIR}/wil/include")
set(RWV_WEBVIEW2_SDK_DIR "${RWV_DEPS_DIR}/webview2-sdk")

foreach(required_path IN ITEMS
        "${RWV_REAPER_SDK_DIR}/reaper_plugin.h"
        "${RWV_WDL_DIR}/wdltypes.h")
    if(NOT EXISTS "${required_path}")
        message(FATAL_ERROR "Missing required dependency: ${required_path}")
    endif()
endforeach()

if(WIN32)
    if(NOT EXISTS "${RWV_WEBVIEW2_SDK_DIR}/build/native/include/WebView2.h")
        set(RWV_WEBVIEW2_ARCHIVE "${CMAKE_CURRENT_BINARY_DIR}/Microsoft.Web.WebView2.zip")
        file(MAKE_DIRECTORY "${RWV_WEBVIEW2_SDK_DIR}")
        file(DOWNLOAD
            "https://www.nuget.org/api/v2/package/Microsoft.Web.WebView2"
            "${RWV_WEBVIEW2_ARCHIVE}"
            TLS_VERIFY ON
            STATUS RWV_WEBVIEW2_DOWNLOAD_STATUS
        )
        list(GET RWV_WEBVIEW2_DOWNLOAD_STATUS 0 RWV_WEBVIEW2_DOWNLOAD_CODE)
        list(GET RWV_WEBVIEW2_DOWNLOAD_STATUS 1 RWV_WEBVIEW2_DOWNLOAD_MESSAGE)
        if(NOT RWV_WEBVIEW2_DOWNLOAD_CODE EQUAL 0)
            message(FATAL_ERROR "Failed to download Microsoft.Web.WebView2: ${RWV_WEBVIEW2_DOWNLOAD_MESSAGE}")
        endif()
        file(ARCHIVE_EXTRACT
            INPUT "${RWV_WEBVIEW2_ARCHIVE}"
            DESTINATION "${RWV_WEBVIEW2_SDK_DIR}"
        )
    endif()

    foreach(required_path IN ITEMS
            "${RWV_WIL_DIR}/wil/com.h"
            "${RWV_WEBVIEW2_SDK_DIR}/build/native/include/WebView2.h"
            "${RWV_WEBVIEW2_SDK_DIR}/build/native/x64/WebView2Loader.dll")
        if(NOT EXISTS "${required_path}")
            message(FATAL_ERROR "Missing required Windows dependency: ${required_path}")
        endif()
    endforeach()
endif()

set(RWV_SOURCES
    src/main.mm
    src/api.mm
    src/helpers.mm
    src/globals.mm
    src/hotkeys.mm
    src/settings.mm
)

if(WIN32)
    list(APPEND RWV_SOURCES
        src/platform/windows/webview_win.cpp
        resources/windows/resources.rc
    )
    # These shared files contain Objective-C++ only in Apple-only branches.
    set_source_files_properties(
        src/main.mm
        src/api.mm
        src/helpers.mm
        src/globals.mm
        src/hotkeys.mm
        src/settings.mm
        PROPERTIES LANGUAGE CXX
    )
else()
    list(APPEND RWV_SOURCES src/platform/macos/webview_darwin.mm)

    find_package(Python3 COMPONENTS Interpreter REQUIRED)
    set(RWV_GENERATED_DIR "${CMAKE_CURRENT_BINARY_DIR}/generated")
    set(RWV_EMBEDDED_HEADER "${RWV_GENERATED_DIR}/embedded_resources.h")
    set(RWV_EMBEDDED_SOURCE "${RWV_GENERATED_DIR}/embedded_resources.cpp")
    add_custom_command(
        OUTPUT "${RWV_EMBEDDED_HEADER}" "${RWV_EMBEDDED_SOURCE}"
        COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/cmake/compile_resources.py"
                "${CMAKE_CURRENT_SOURCE_DIR}/resources/images" "${RWV_EMBEDDED_HEADER}" "${RWV_EMBEDDED_SOURCE}"
        DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/cmake/compile_resources.py"
                "${CMAKE_CURRENT_SOURCE_DIR}/resources/images/search_prev.png"
                "${CMAKE_CURRENT_SOURCE_DIR}/resources/images/search_next.png"
        COMMENT "Embedding macOS PNG resources"
        VERBATIM
    )
    list(APPEND RWV_SOURCES
        "${RWV_EMBEDDED_SOURCE}"
        "${RWV_WDL_DIR}/swell/swell-modstub.mm"
    )
endif()

function(rwv_configure_target target_name enable_logging)
    add_library(${target_name} MODULE ${RWV_SOURCES})

    target_compile_features(${target_name} PRIVATE cxx_std_20)
    target_include_directories(${target_name} PRIVATE
        "${CMAKE_CURRENT_SOURCE_DIR}/include/reaper_webview"
        "${CMAKE_CURRENT_SOURCE_DIR}/resources/windows"
        "${RWV_REAPER_SDK_DIR}"
        "${RWV_WDL_DIR}"
        "${RWV_WDL_DIR}/swell"
    )
    set_target_properties(${target_name} PROPERTIES
        PREFIX ""
        OUTPUT_NAME "${target_name}"
        CXX_EXTENSIONS OFF
        LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}"
        RUNTIME_OUTPUT_DIRECTORY "${CMAKE_CURRENT_BINARY_DIR}"
    )

    if(enable_logging)
        target_compile_definitions(${target_name} PRIVATE ENABLE_LOG)
    endif()

    if(APPLE)
        target_include_directories(${target_name} PRIVATE "${RWV_GENERATED_DIR}")
        target_compile_definitions(${target_name} PRIVATE
            SWELL_PROVIDED_BY_APP
            GA_PARENT=1
            GA_ROOT=2
            GA_ROOTOWNER=3
        )
        target_link_libraries(${target_name} PRIVATE
            "-framework Cocoa"
            "-framework WebKit"
        )
        set_target_properties(${target_name} PROPERTIES SUFFIX ".dylib" BUNDLE FALSE)
    else()
        set(webview2_include "${RWV_WEBVIEW2_SDK_DIR}/build/native/include")
        if(NOT EXISTS "${webview2_include}/WebView2.h")
            # Backward-compatible local layout used by older checkouts.
            set(webview2_include "${RWV_DEPS_DIR}")
        endif()
        target_include_directories(${target_name} PRIVATE
            "${webview2_include}"
            "${RWV_WIL_DIR}"
        )
        target_compile_definitions(${target_name} PRIVATE
            _WIN32_WINNT=0x0601
            NOMINMAX
            WIN32_LEAN_AND_MEAN
            _CRT_SECURE_NO_WARNINGS
            UNICODE
            _UNICODE
        )
        target_link_libraries(${target_name} PRIVATE
            comctl32 ole32 version shlwapi user32 msimg32 oleaut32 advapi32 windowscodecs
        )
        set_target_properties(${target_name} PROPERTIES SUFFIX ".dll")
    endif()
endfunction()

rwv_configure_target(reaper_webview FALSE)
rwv_configure_target(reaper_webview_debug TRUE)

if(WIN32)
    find_library(RWV_WEBVIEW2_LOADER_LIBRARY
        NAMES WebView2LoaderStatic WebView2Loader
        PATHS
            "${RWV_WEBVIEW2_SDK_DIR}/build/native"
            "${RWV_WEBVIEW2_SDK_DIR}/build/native/x64"
            "${RWV_WEBVIEW2_SDK_DIR}/build/native/x86"
        NO_DEFAULT_PATH
    )
    foreach(target_name IN ITEMS reaper_webview reaper_webview_debug)
        if(RWV_WEBVIEW2_LOADER_LIBRARY)
            target_link_libraries(${target_name} PRIVATE "${RWV_WEBVIEW2_LOADER_LIBRARY}")
        else()
            target_compile_definitions(${target_name} PRIVATE USE_WEBVIEW2_LOADER_DYNAMIC)
        endif()
    endforeach()
endif()

if(APPLE)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "10.13" CACHE STRING "Minimum macOS version")
    set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64" CACHE STRING "macOS architectures")
endif()
