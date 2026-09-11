if reaper.WEBVIEW_Navigate then
    reaper.WEBVIEW_Navigate("https://duckduckgo.com/")
    reaper.Sleep(3000)
    reaper.WEBVIEW_Navigate("https://www.reaper.fm/sdk/reascript/reascripthelp.html")
else
    reaper.ShowMessageBox(
        "Функция WEBVIEW_Navigate не найдена!",
        "Ошибка", 0)
end