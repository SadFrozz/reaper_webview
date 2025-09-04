-- Проверяем наличие новой функции
if reaper.WEBVIEW_Navigate then

  -- Открываем окно с одной страницей
  reaper.WEBVIEW_Navigate("https://duckduckgo.com/")

  -- Ждем 3 секунды
  reaper.Sleep(3000)

  -- В этом же окне открываем другую страницу
  reaper.WEBVIEW_Navigate("https://www.reaper.fm/sdk/reascript/reascripthelp.html")

else
  reaper.ShowMessageBox("Функция WEBVIEW_Navigate не найдена! Убедитесь, что плагин обновлен и установлен корректно.", "Ошибка", 0)
end