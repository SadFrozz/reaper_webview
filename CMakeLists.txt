cmake_minimum_required(VERSION 3.10)
project(reaper_webview)

# Настройка путей
set(SDK_PATH ${CMAKE_CURRENT_SOURCE_DIR}/sdk)
set(WDL_PATH ${CMAKE_CURRENT_SOURCE_DIR}/WDL)

# Добавляем include директории
include_directories(${SDK_PATH} ${WDL_PATH} ${CMAKE_CURRENT_SOURCE_DIR}/deps)

# ИСПРАВЛЕНО: Вместо всех файлов SWELL, мы используем только один файл-заглушку,
# который соединяет наш плагин с SWELL, встроенным в REAPER.
set(SOURCES
    main.mm
    "${WDL_PATH}/swell/swell-modstub-generic.cpp"
)

add_library(reaper_webview MODULE ${SOURCES})

# ИСПРАВЛЕНО: Добавляем глобальное определение, которое говорит SWELL
# не компилировать себя, а использовать функции из REAPER.
target_compile_definitions(reaper_webview PRIVATE SWELL_PROVIDED_BY_APP)


if(APPLE)
    set_target_properties(reaper_webview PROPERTIES OUTPUT_NAME "reaper_webview" SUFFIX ".dylib" BUNDLE FALSE)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "10.13")
    set(CMAKE_OSX_ARCHITECTURES "arm64;x86_64")

    # Больше не нужно перечислять исходники SWELL
    # target_sources(...) БОЛЬШЕ НЕ НУЖЕН

    target_link_libraries(reaper_webview PRIVATE "-framework Cocoa" "-framework WebKit" "-framework AppKit" "-framework Carbon")

elseif(WIN32)
    set_target_properties(reaper_webview PROPERTIES SUFFIX ".dll")

    target_compile_definitions(reaper_webview PRIVATE _WIN32_WINNT=0x0601 NOMINMAX WIN32_LEAN_AND_MEAN _CRT_SECURE_NO_WARNINGS)
    
    target_link_libraries(reaper_webview comctl32 ole32 version shlwapi user32 oleaut32 advapi32)
endif()

set_target_properties(reaper_webview PROPERTIES LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}" RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}")