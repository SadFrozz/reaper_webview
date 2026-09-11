// Reaper WebView Plugin
// (c) Andrew "SadFrozz" Brodsky
// 2025 and later
// api.h

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Регистрирует все экспортируемые API-функции плагина в REAPER.
// Вызывать один раз на инициализации плагина.
void RegisterAPI(void);
// Отменяет регистрацию (вызвать при выгрузке плагина)
void UnregisterAPI(void);

// Internal C API (used across translation units). Not part of stable external SDK yet.
void API_WEBVIEW_Navigate(const char* url, const char* opts);

#ifdef __cplusplus
} // extern "C"
#endif
