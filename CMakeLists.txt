cmake_minimum_required(VERSION 3.10)
project(reaper_webview)

set(SDK_PATH ${CMAKE_CURRENT_SOURCE_DIR}/sdk)
set(WDL_PATH ${CMAKE_CURRENT_SOURCE_DIR}/WDL)

include_directories(${SDK_PATH} ${WDL_PATH} ${CMAKE_CURRENT_SOURCE_DIR}/deps)

set(SOURCES main.mm)

# Для Windows включаем файл ресурсов
if(WIN32)
    list(APPEND SOURCES main.rc)
endif()

# Для macOS включаем все необходимые исходники SWELL
if(APPLE)
    set(SWELL_SOURCES
        "${WDL_PATH}/swell/swell.cpp"
        "${WDL_PATH}/swell/swell-ini.cpp"
        "${WDL_PATH}/swell/swell-misc-generic.cpp"
        "${WDL_PATH}/swell/swell-gdi-generic.cpp"
        "${WDL_PATH}/swell/swell-dlg-generic.cpp"
        "${WDL_PATH}/swell/swell-menu-generic.cpp"
        "${WDL_PATH}/swell/swell-kb-generic.cpp"
        "${WDL_PATH}/swell/swell-wnd-generic.cpp"
        "${WDL_PATH}/swell/swell-dlg.mm"
        "${WDL_PATH}/swell/swell-gdi.mm"
        "${WDL_PATH}/swell/swell-kb.mm"
        "${WDL_PATH}/swell/swell-menu.mm"
        "${WDL_PATH}/swell/swell-misc.mm"
        "${WDL_PATH}/swell/swell-miscdlg.mm"
        "${WDL_PATH}/swell/swell-wnd.mm"
        "${WDL_PATH}/swell/swell-appstub.mm"
        "${WDL_PATH}/swell/swell-modstub.mm"
    )
    list(APPEND SOURCES ${SWELL_SOURCES})
endif()

add_library(reaper_webview MODULE ${SOURCES})

if(APPLE)
    set_target_properties(reaper_webview PROPERTIES OUTPUT_NAME "reaper_webview" SUFFIX ".dylib" BUNDLE FALSE)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "10.13")
    set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")
    target_link_libraries(reaper_webview PRIVATE "-framework Cocoa" "-framework WebKit" "-framework AppKit" "-framework Carbon")

elseif(WIN32)
    set_target_properties(reaper_webview PROPERTIES SUFFIX ".dll")
    target_compile_definitions(reaper_webview PRIVATE _WIN32_WINNT=0x0601 NOMINMAX _CRT_SECURE_NO_WARNINGS)
    target_link_libraries(reaper_webview comctl32 ole32 version shlwapi user32 oleaut32 advapi32)
endif()

set_target_properties(reaper_webview PROPERTIES LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}" RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")