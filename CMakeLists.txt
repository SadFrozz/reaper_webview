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
set(SOURCES
    main.mm
    api.mm
    helpers.mm
    webview_win.cpp
    webview_darwin.mm
    globals.mm
    resources.rc
)

# Создаем библиотеку
add_library(reaper_webview MODULE ${SOURCES})

# Второй таргет: всегда с логами
add_library(reaper_webview_debug MODULE ${SOURCES})
target_compile_definitions(reaper_webview_debug PRIVATE ENABLE_LOG)

# Настройки для разных платформ
if(APPLE)
    # --- Embed PNG resources into code (mac only). Windows keeps .rc resource loading path.
    find_package(Python3 COMPONENTS Interpreter REQUIRED)
    set(EMBED_INPUT_DIR ${CMAKE_SOURCE_DIR}/res)
    set(EMBED_OUT_DIR ${CMAKE_BINARY_DIR}/generated)
    set(EMBED_H ${EMBED_OUT_DIR}/embedded_resources.h)
    set(EMBED_CPP ${EMBED_OUT_DIR}/embedded_resources.cpp)
    add_custom_command(
        OUTPUT ${EMBED_H} ${EMBED_CPP}
        COMMAND ${Python3_EXECUTABLE} ${CMAKE_SOURCE_DIR}/tools/compile_resources.py ${EMBED_INPUT_DIR} ${EMBED_H} ${EMBED_CPP}
        DEPENDS ${CMAKE_SOURCE_DIR}/tools/compile_resources.py
        WORKING_DIRECTORY ${CMAKE_SOURCE_DIR}
        COMMENT "Embedding PNG resources into C++ (macOS)"
        VERBATIM
    )
    # Собираем список PNG чтобы триггерить реген при изменении
    file(GLOB EMBED_PNGS RELATIVE ${CMAKE_SOURCE_DIR} res/*.png)
    foreach(png ${EMBED_PNGS})
        set(png_full ${CMAKE_SOURCE_DIR}/${png})
        set_property(SOURCE ${EMBED_CPP} APPEND PROPERTY OBJECT_DEPENDS ${png_full})
        set_property(SOURCE ${EMBED_H} APPEND PROPERTY OBJECT_DEPENDS ${png_full})
        list(APPEND EMBED_EXTRA_DEPS ${png_full})
    endforeach()

    add_library(embedded_res OBJECT ${EMBED_CPP} ${EMBED_H})
    add_dependencies(embedded_res reaper_webview reaper_webview_debug)
    target_include_directories(embedded_res PUBLIC ${EMBED_OUT_DIR})
    target_sources(reaper_webview PRIVATE $<TARGET_OBJECTS:embedded_res>)
    target_sources(reaper_webview_debug PRIVATE $<TARGET_OBJECTS:embedded_res>)
    target_include_directories(reaper_webview PRIVATE ${EMBED_OUT_DIR})
    target_include_directories(reaper_webview_debug PRIVATE ${EMBED_OUT_DIR})
    add_dependencies(reaper_webview embedded_res)
    add_dependencies(reaper_webview_debug embedded_res)
    
    set(SWELL_STUB ${CMAKE_SOURCE_DIR}/WDL/swell/swell-modstub.mm)
    target_sources(reaper_webview PRIVATE ${SWELL_STUB})
    target_sources(reaper_webview_debug PRIVATE ${SWELL_STUB})
    target_compile_definitions(reaper_webview PRIVATE SWELL_PROVIDED_BY_APP)
    target_compile_definitions(reaper_webview_debug PRIVATE SWELL_PROVIDED_BY_APP)
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
    #target_link_options(reaper_webview PRIVATE "-Wl,-undefined,dynamic_lookup")
    target_compile_definitions(reaper_webview PRIVATE GA_PARENT=1)
    target_compile_definitions(reaper_webview PRIVATE GA_ROOT=2)
    target_compile_definitions(reaper_webview PRIVATE GA_ROOTOWNER=3)

    # debug-вариант (та же конфигурация, другое имя)
    set_target_properties(reaper_webview_debug PROPERTIES 
        OUTPUT_NAME "reaper_webview_debug"
        SUFFIX ".dylib"
        BUNDLE FALSE)
    target_link_libraries(reaper_webview_debug ${COCOA_LIBRARY} ${WEBKIT_LIBRARY})
    #target_link_options(reaper_webview_debug PRIVATE "-Wl,-undefined,dynamic_lookup")
    target_compile_definitions(reaper_webview_debug PRIVATE GA_PARENT=1)
    target_compile_definitions(reaper_webview_debug PRIVATE GA_ROOT=2)
    target_compile_definitions(reaper_webview_debug PRIVATE GA_ROOTOWNER=3)
elseif(WIN32)
    # Настройки для Windows
    set_target_properties(reaper_webview PROPERTIES
        SUFFIX ".dll"
        CXX_STANDARD 20
        CXX_STANDARD_REQUIRED YES
        CXX_EXTENSIONS NO)
    
    # Добавляем пути к зависимостям WebView2 и WIL
    include_directories(${CMAKE_CURRENT_SOURCE_DIR}/deps)
    
    target_compile_definitions(reaper_webview PRIVATE 
        _WIN32_WINNT=0x0601
        NOMINMAX
        WIN32_LEAN_AND_MEAN
        _CRT_SECURE_NO_WARNINGS
        UNICODE
        _UNICODE)
    
    # Добавляем линковку с WebView2
    target_link_libraries(reaper_webview 
        comctl32 
        ole32 
        version 
        shlwapi
        user32
        msimg32
        oleaut32
        advapi32)
    
    # Копируем WebView2Loader.dll или используем статическую линковку
    # Для начала попробуем найти статическую библиотеку
    find_library(WEBVIEW2_LIB 
        NAMES WebView2LoaderStatic.lib WebView2Loader.lib
        PATHS ${CMAKE_CURRENT_SOURCE_DIR}/webview2-sdk/build/native)
    
    if(WEBVIEW2_LIB)
        message(STATUS "Found WebView2 library: ${WEBVIEW2_LIB}")
        target_link_libraries(reaper_webview ${WEBVIEW2_LIB})
    else()
        message(WARNING "WebView2 library not found, trying to link dynamically")
        # Динамическая линковка через LoadLibrary
        target_compile_definitions(reaper_webview PRIVATE USE_WEBVIEW2_LOADER_DYNAMIC)
    endif()

    # debug-вариант (идентичные дефайны/линковка + .dll суффикс)
    set_target_properties(reaper_webview_debug PROPERTIES
        SUFFIX ".dll"
        CXX_STANDARD 20
        CXX_STANDARD_REQUIRED YES
        CXX_EXTENSIONS NO)
    target_compile_definitions(reaper_webview_debug PRIVATE 
        _WIN32_WINNT=0x0601
        NOMINMAX
        WIN32_LEAN_AND_MEAN
        _CRT_SECURE_NO_WARNINGS
        UNICODE
        _UNICODE)
    target_link_libraries(reaper_webview_debug 
        comctl32 
        ole32 
        version 
        shlwapi
        user32
        msimg32
        oleaut32
        advapi32)
    if(WEBVIEW2_LIB)
        target_link_libraries(reaper_webview_debug ${WEBVIEW2_LIB})
    else()
        target_compile_definitions(reaper_webview_debug PRIVATE USE_WEBVIEW2_LOADER_DYNAMIC)
    endif()
endif()

# Установка выходного директория
set_target_properties(reaper_webview PROPERTIES 
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})
set_target_properties(reaper_webview_debug PROPERTIES 
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR})