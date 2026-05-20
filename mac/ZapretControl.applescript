-- ZapretControl.applescript
-- GUI-обёртка над install/start/stop/status/uninstall.
-- Собирается в .app командой: osacompile -o Zapret.app ZapretControl.applescript
--
-- Ключевые принципы (чтобы приложение не зависало):
--   * В диалогах НИКОГДА не показываем длинный вывод — он делает кнопку OK
--     неактивной и подвешивает приложение. Полный вывод пишем в лог-файл,
--     в окне — только короткое резюме + кнопка «Открыть лог».
--   * После «Запустить»/«Остановить» статус перепроверяем по факту (pgrep),
--     поэтому индикатор больше не врёт.

property appTitle : "Zapret"
property logFile : "/tmp/zapret-gui.log"
property exitFile : "/tmp/zapret-gui.exit"

on run
	mainLoop()
end run

on mainLoop()
	repeat
		try
			set statusInfo to getQuickStatus()
			set installInfo to getInstallInfo()
			set theChoice to choose from list ¬
				{"▶ Запустить", "⏹ Остановить", "📊 Подробный статус", "🔄 Установить / Переустановить", "📝 Изменить список сайтов", "🗑 Удалить из системы"} ¬
				with prompt installInfo & return & statusInfo & return & return & "Что делаем?" ¬
				default items {"▶ Запустить"} ¬
				with title appTitle ¬
				OK button name "Выполнить" ¬
				cancel button name "Закрыть"
			if theChoice is false then exit repeat

			set theAction to item 1 of theChoice

			if theAction starts with "▶" then
				runAction("start.sh", "Запуск zapret")
			else if theAction starts with "⏹" then
				runAction("stop.sh", "Остановка zapret")
			else if theAction starts with "📊" then
				showStatus()
			else if theAction starts with "🔄" then
				runAction("install.sh", "Установка zapret")
			else if theAction starts with "📝" then
				openHostsList()
			else if theAction starts with "🗑" then
				confirmUninstall()
			end if
		on error errMsg number errNum
			if errNum is -128 then exit repeat -- закрыли окно
			shortAlert("Ошибка: " & errMsg, true)
		end try
	end repeat
end mainLoop

-- === Хелперы ===

on getScriptDir()
	-- Сначала ищем скрипты рядом с .app (до установки или если .app остался в mac/)
	set selfDir to do shell script "dirname " & quoted form of (POSIX path of (path to me))
	try
		do shell script "test -f " & quoted form of (selfDir & "/start.sh")
		return selfDir
	end try
	-- Запасной вариант — стандартное место установки (.app можно переносить в /Applications)
	try
		do shell script "test -f /opt/zapret/mac/start.sh"
		return "/opt/zapret/mac"
	end try
	error "Не нашёл шелл-скрипты ни рядом с приложением, ни в /opt/zapret/mac. Положи Zapret.app в папку mac/ внутри zapret-v72.12 (или сначала установи zapret оттуда)."
end getScriptDir

on getQuickStatus()
	try
		set tpwsPid to do shell script "pgrep -x tpws 2>/dev/null | tr '\\n' ' ' | xargs echo -n"
		if tpwsPid is "" then
			return "Статус: ⚪ остановлен"
		else
			return "Статус: 🟢 работает (tpws PID: " & tpwsPid & ")"
		end if
	on error
		return "Статус: неизвестен"
	end try
end getQuickStatus

on getInstallInfo()
	try
		do shell script "test -d /opt/zapret"
		return "Установка: ✅ /opt/zapret"
	on error
		return "Установка: ❌ не установлен (нажми «Установить»)"
	end try
end getInstallInfo

-- Короткое уведомление без риска подвесить приложение длинным текстом.
on shortAlert(msg, isError)
	-- обрезаем на всякий случай
	if (length of msg) > 600 then set msg to (text 1 thru 600 of msg) & "…"
	if isError then
		display dialog msg buttons {"OK"} default button 1 with title appTitle with icon caution
	else
		display dialog msg buttons {"OK"} default button 1 with title appTitle
	end if
end shortAlert

on openLog()
	try
		do shell script "open -e " & quoted form of logFile
	on error
		try
			do shell script "open -a Console " & quoted form of logFile
		end try
	end try
end openLog

-- Запускает шелл-скрипт с правами админа.
-- Весь вывод пишем в лог-файл, в окно показываем только короткий «хвост».
on runAction(scriptName, friendlyName)
	set scriptDir to getScriptDir()
	set scriptPath to scriptDir & "/" & scriptName

	try
		do shell script "test -f " & quoted form of scriptPath
	on error
		shortAlert("Не нашёл " & scriptName & " рядом с приложением." & return & return & "Zapret.app должен лежать в папке mac/ внутри zapret-v72.12 (рядом со скриптами), либо zapret должен быть установлен.", true)
		return
	end try

	set shCmd to "ZAPRET_LOG=" & quoted form of logFile & " /bin/bash " & quoted form of scriptPath & " > " & quoted form of logFile & " 2>&1; echo $? > " & quoted form of exitFile & "; tail -n 6 " & quoted form of logFile

	try
		set summary to do shell script shCmd with administrator privileges
	on error errMsg number errNum
		if errNum is -128 then return -- отменили ввод пароля
		set summary to "Не удалось запустить процесс." & return & errMsg
	end try

	set ec to "1"
	try
		set ec to do shell script "cat " & quoted form of exitFile
	end try

	-- Перепроверяем реальный статус (после stop.sh tpws уже гарантированно убит).
	set qs to getQuickStatus()

	if (length of summary) > 700 then set summary to (text 1 thru 700 of summary) & "…"

	if ec is "0" then
		set msg to friendlyName & " — готово." & return & return & qs & return & return & summary
		set chosen to button returned of (display dialog msg buttons {"Открыть лог", "OK"} default button "OK" with title appTitle)
	else
		set msg to friendlyName & " — не удалось." & return & return & qs & return & return & summary & return & return & "Подробности — в логе."
		set chosen to button returned of (display dialog msg buttons {"Открыть лог", "OK"} default button "OK" with title appTitle with icon caution)
	end if

	if chosen is "Открыть лог" then openLog()
end runAction

on showStatus()
	set scriptDir to getScriptDir()
	set scriptPath to scriptDir & "/status.sh"
	try
		do shell script "test -f " & quoted form of scriptPath
	on error
		shortAlert("Не нашёл status.sh.", true)
		return
	end try

	set shCmd to "/bin/bash " & quoted form of scriptPath & " > " & quoted form of logFile & " 2>&1; tail -n 18 " & quoted form of logFile
	try
		set statusOutput to do shell script shCmd with administrator privileges
	on error errMsg number errNum
		if errNum is -128 then return
		shortAlert("Не удалось получить статус: " & errMsg, true)
		return
	end try

	if (length of statusOutput) > 900 then set statusOutput to (text 1 thru 900 of statusOutput) & "…"

	set chosen to button returned of (display dialog statusOutput buttons {"Открыть лог", "OK"} default button "OK" with title "Подробный статус")
	if chosen is "Открыть лог" then openLog()
end showStatus

on openHostsList()
	set hostsPath to "/opt/zapret/ipset/zapret-hosts-user.txt"
	try
		do shell script "test -f " & quoted form of hostsPath
	on error
		shortAlert("zapret пока не установлен. Сначала «Установить».", true)
		return
	end try

	try
		do shell script "open -a TextEdit " & quoted form of hostsPath
		shortAlert("Список открыт в TextEdit." & return & return & "Дополни/измени домены, сохрани (Cmd+S), потом нажми «Остановить» → «Запустить», чтобы изменения подхватились.", false)
	on error errMsg
		shortAlert("Не получилось открыть: " & errMsg, true)
	end try
end openHostsList

on confirmUninstall()
	try
		set yn to display dialog ¬
			"Удалить zapret полностью?" & return & return & ¬
			"Будут отменены PF-правила, удалён launchd-юнит и снесена папка /opt/zapret." ¬
			buttons {"Отмена", "Удалить"} default button "Отмена" cancel button "Отмена" ¬
			with title appTitle with icon caution
		if button returned of yn is "Удалить" then
			runAction("uninstall.sh", "Удаление zapret")
		end if
	on error
		return -- отменили — ничего не делаем
	end try
end confirmUninstall
