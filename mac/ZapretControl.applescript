-- ZapretControl.applescript
-- GUI-обёртка над install/start/stop/status/strategy/uninstall.
-- Собирается в .app командой: osacompile -o Zapret.app ZapretControl.applescript
--
-- Ключевые принципы (чтобы приложение не зависало):
--   * В диалогах НИКОГДА не показываем длинный вывод — он делает кнопку OK
--     неактивной и подвешивает приложение. Полный вывод пишем в лог-файл,
--     в окне — только короткое резюме + кнопка «Открыть лог».
--   * После «Включить»/«Выключить» статус перепроверяем по факту (pgrep),
--     поэтому индикатор больше не врёт.
--   * Тумблер: первый пункт меню — включить/выключить, без пароля.
--     install.sh кладёт правило в /etc/sudoers.d/zapret, поэтому
--     start/stop/status/strategy выполняются через `sudo -n` молча.
--     Если правила нет (старая установка) — откатываемся на запрос пароля.

property appTitle : "Zapret"
property logFile : "/tmp/zapret-gui.log"
property exitFile : "/tmp/zapret-gui.exit"

on run
	mainLoop()
end run

on mainLoop()
	repeat
		try
			set isRunning to zapretRunning()
			set isPaused to zapretPaused()
			-- «Активным» считаем и работающий, и поставленный на автопаузу обход:
			-- в обоих случаях намерение пользователя — «включено», поэтому кнопка
			-- предлагает «Выключить». Так нажатие на паузе ВЫКЛЮЧАЕТ (а не включает).
			set isActive to (isRunning or isPaused)
			set statusInfo to getQuickStatus(isRunning)
			set installInfo to getInstallInfo()
			if isActive then
				set toggleItem to "⏻ Выключить обход"
			else
				set toggleItem to "⏻ Включить обход"
			end if
			set theChoice to choose from list ¬
				{toggleItem, "📊 Подробный статус", "🧪 Стратегия обхода", "📝 Изменить список сайтов", "🔄 Установить / Переустановить", "🗑 Удалить из системы"} ¬
				with prompt installInfo & return & statusInfo & return & return & "Что делаем?" ¬
				default items {toggleItem} ¬
				with title appTitle ¬
				OK button name "Выполнить" ¬
				cancel button name "Закрыть"
			if theChoice is false then exit repeat

			set theAction to item 1 of theChoice

			if theAction starts with "⏻" then
				if isActive then
					runAction("stop.sh", "", "Выключение обхода")
				else
					runAction("start.sh", "", "Включение обхода")
				end if
			else if theAction starts with "📊" then
				showStatus()
			else if theAction starts with "🧪" then
				chooseStrategy()
			else if theAction starts with "📝" then
				openHostsList()
			else if theAction starts with "🔄" then
				runAction("install.sh", "", "Установка zapret")
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
	-- Сначала проверяем стандартное место установки /opt/zapret/mac.
	-- Там скрипты принадлежат root и покрыты sudoers → кнопки без пароля
	-- независимо от того, где физически лежит Zapret.app.
	try
		do shell script "test -f /opt/zapret/mac/start.sh"
		return "/opt/zapret/mac"
	end try
	-- Запасной вариант — скрипты рядом с .app (до первой установки).
	set selfDir to do shell script "dirname " & quoted form of (POSIX path of (path to me))
	try
		do shell script "test -f " & quoted form of (selfDir & "/start.sh")
		return selfDir
	end try
	error "Не нашёл шелл-скрипты. Сначала установи zapret: открой папку mac/ из архива и запусти install.command."
end getScriptDir

on zapretRunning()
	try
		do shell script "pgrep -x tpws >/dev/null 2>&1 && echo yes || echo no"
		if result is "yes" then return true
	end try
	return false
end zapretRunning

-- Обход на автопаузе: tpws не работает, но стоит флаг паузы из-за VPN.
-- Это значит «намерение — включено», просто временно приглушено.
on zapretPaused()
	try
		do shell script "if [ -f /var/run/zapret.paused-by-vpn ] && ! pgrep -x tpws >/dev/null 2>&1; then echo yes; else echo no; fi"
		if result is "yes" then return true
	end try
	return false
end zapretPaused

on getQuickStatus(isRunning)
	if isRunning then
		return "Статус: 🟢 обход работает"
	end if
	try
		do shell script "test -f /var/run/zapret.paused-by-vpn && echo paused || echo no"
		if result is "paused" then return "Статус: ⏸ на паузе — обнаружен VPN (возобновится сам)"
	end try
	return "Статус: ⚪ выключен"
end getQuickStatus

on getInstallInfo()
	try
		do shell script "test -d /opt/zapret"
		set info to "Установка: ✅ /opt/zapret"
		try
			set strat to do shell script "cat /opt/zapret/mac/.strategy 2>/dev/null"
			if strat is not "" then set info to info & "   Стратегия: " & strat
		end try
		return info
	on error
		return "Установка: ❌ не установлен (нажми «Установить»)"
	end try
end getInstallInfo

-- Разрешён ли скрипт в sudoers без пароля (правило ставит install.sh).
on canSudoQuiet(scriptPath)
	try
		do shell script "sudo -n -l " & quoted form of scriptPath & " >/dev/null 2>&1 && echo yes || echo no"
		if result is "yes" then return true
	end try
	return false
end canSudoQuiet

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

-- Запускает шелл-скрипт с правами root: через sudo -n (без пароля), если
-- install.sh прописал правило в sudoers; иначе — со штатным запросом пароля.
-- Весь вывод пишем в лог-файл, в окно показываем только короткий «хвост».
on runAction(scriptName, scriptArgs, friendlyName)
	set scriptDir to getScriptDir()
	set scriptPath to scriptDir & "/" & scriptName

	try
		do shell script "test -f " & quoted form of scriptPath
	on error
		shortAlert("Не нашёл " & scriptName & " рядом с приложением." & return & return & "Zapret.app должен лежать в папке mac/ внутри исходников (рядом со скриптами), либо zapret должен быть установлен.", true)
		return
	end try

	set argsPart to ""
	if scriptArgs is not "" then set argsPart to " " & scriptArgs

	if canSudoQuiet(scriptPath) then
		set shCmd to "sudo -n " & quoted form of scriptPath & argsPart & " > " & quoted form of logFile & " 2>&1; echo $? > " & quoted form of exitFile & "; tail -n 6 " & quoted form of logFile
		try
			set summary to do shell script shCmd
		on error errMsg number errNum
			if errNum is -128 then return
			set summary to "Не удалось запустить процесс." & return & errMsg
		end try
	else
		set shCmd to "/bin/bash " & quoted form of scriptPath & argsPart & " > " & quoted form of logFile & " 2>&1; echo $? > " & quoted form of exitFile & "; tail -n 6 " & quoted form of logFile
		try
			set summary to do shell script shCmd with administrator privileges
		on error errMsg number errNum
			if errNum is -128 then return -- отменили ввод пароля
			set summary to "Не удалось запустить процесс." & return & errMsg
		end try
	end if

	set ec to "1"
	try
		set ec to do shell script "cat " & quoted form of exitFile
	end try

	-- Перепроверяем реальный статус (после stop.sh tpws уже гарантированно убит).
	set qs to getQuickStatus(zapretRunning())

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

	if canSudoQuiet(scriptPath) then
		set shCmd to "sudo -n " & quoted form of scriptPath & " > " & quoted form of logFile & " 2>&1; tail -n 18 " & quoted form of logFile
		try
			set statusOutput to do shell script shCmd
		on error errMsg number errNum
			if errNum is -128 then return
			shortAlert("Не удалось получить статус: " & errMsg, true)
			return
		end try
	else
		set shCmd to "/bin/bash " & quoted form of scriptPath & " > " & quoted form of logFile & " 2>&1; tail -n 18 " & quoted form of logFile
		try
			set statusOutput to do shell script shCmd with administrator privileges
		on error errMsg number errNum
			if errNum is -128 then return
			shortAlert("Не удалось получить статус: " & errMsg, true)
			return
		end try
	end if

	if (length of statusOutput) > 900 then set statusOutput to (text 1 thru 900 of statusOutput) & "…"

	set chosen to button returned of (display dialog statusOutput buttons {"Открыть лог", "OK"} default button "OK" with title "Подробный статус")
	if chosen is "Открыть лог" then openLog()
end showStatus

on chooseStrategy()
	-- Список синхронизирован с пресетами в strategy.sh.
	set strategyItems to {¬
		"default — сплит SNI (1,midsld) + disorder, рекомендуется", ¬
		"split-only — только сплит, если default рвёт соединения", ¬
		"midsld — сплит по середине домена + disorder", ¬
		"oob — сплит + out-of-band байт, против въедливых DPI", ¬
		"hostcase — искажение Host + сплит, запасной вариант"}

	set curStrat to "default"
	try
		set curStrat to do shell script "cat /opt/zapret/mac/.strategy 2>/dev/null"
	end try
	if curStrat is "" then set curStrat to "default"

	set defaultItem to item 1 of strategyItems
	repeat with anItem in strategyItems
		if (anItem as text) starts with curStrat then set defaultItem to (anItem as text)
	end repeat

	set theChoice to choose from list strategyItems ¬
		with prompt "Сейчас: " & curStrat & return & return & "Если какой-то сайт перестал открываться или соединения рвутся — попробуй другую стратегию. После выбора zapret перезапустится сам." ¬
		default items {defaultItem} ¬
		with title "Стратегия обхода DPI" ¬
		OK button name "Применить" ¬
		cancel button name "Назад"
	if theChoice is false then return

	set chosenLine to item 1 of theChoice
	-- имя = текст до первого пробела ("first word" не годится: режет по дефису)
	set stratName to text 1 thru ((offset of " " in chosenLine) - 1) of chosenLine

	runAction("strategy.sh", "set " & stratName, "Смена стратегии на «" & stratName & "»")
end chooseStrategy

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
		shortAlert("Список открыт в TextEdit." & return & return & "Дополни/измени домены, сохрани (Cmd+S), потом «Выключить» → «Включить», чтобы изменения подхватились.", false)
	on error errMsg
		shortAlert("Не получилось открыть: " & errMsg, true)
	end try
end openHostsList

on confirmUninstall()
	try
		set yn to display dialog ¬
			"Удалить zapret полностью?" & return & return & ¬
			"Будут отменены PF-правила, удалены launchd-юниты (zapret, vpn-watch), правило sudoers, агент автооткрытия и папка /opt/zapret." ¬
			buttons {"Отмена", "Удалить"} default button "Отмена" cancel button "Отмена" ¬
			with title appTitle with icon caution
		if button returned of yn is "Удалить" then
			runAction("uninstall.sh", "", "Удаление zapret")
		end if
	on error
		return -- отменили — ничего не делаем
	end try
end confirmUninstall
