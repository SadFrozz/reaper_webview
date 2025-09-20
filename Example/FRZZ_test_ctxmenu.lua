-- FRZZ_test_ctxmenu.lua
-- Тест сценарий для проверки контекстного меню WebView плагина
-- 1. Открывает default инстанс (полное меню)
-- 2. Открывает второй инстанс с BasicCtxMenu=true
-- 3. Нажимает навигацию по нескольким URL (чтобы активировать Back/Forward)
-- Запусти, затем вручную вызывай контекстное меню ПКМ внутри обеих вкладок.

local function navigate(id, url, opts)
  local json = '{' .. table.concat(opts, ',') .. '}'
  reaper.API_WEBVIEW_Navigate(url, json)
end

-- 1. Полный инстанс
reaper.API_WEBVIEW_Navigate("https://www.reaper.fm/", '{"InstanceId":"wv_default"}')

-- 2. BasicCtxMenu инстанс
reaper.API_WEBVIEW_Navigate("https://example.org/", '{"InstanceId":"wv_basic","BasicCtxMenu":true,"SetTitle":"BasicCtx"}')

-- Навигация в default чтобы создать историю
reaper.defer(function()
  navigate("wv_default", "https://httpbin.org/", { '"InstanceId":"wv_default"' })
  reaper.defer(function()
    navigate("wv_default", "https://www.lua.org/", { '"InstanceId":"wv_default"' })
  end)
end)

reaper.ShowConsoleMsg("[FRZZ_test_ctxmenu] Запущено. Проверь ПКМ в обоих окнах.\n")
