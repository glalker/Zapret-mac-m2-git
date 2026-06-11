#!/bin/bash
#
# install.sh — установщик zapret для macOS (Apple Silicon / Intel).
# Запускай из папки mac/ внутри проекта:
#   sudo ./install.sh
#
# Делает следующее:
#   1. Проверяет, что мы на маке.
#   2. Копирует zapret в /opt/zapret.
#   3. Раскладывает бинарники (универсальные mac64: arm64 + x86_64).
#   4. Подкладывает наш конфиг и список доменов.
#   5. Патчит /etc/pf.conf (добавляет якоря zapret).
#   6. Регистрирует launchd-сервис /Library/LaunchDaemons/zapret.plist.
#   7. Разрешает управление из GUI без пароля (/etc/sudoers.d/zapret).
#   8. Ставит vpn-watch: автопауза zapret при включении VPN.
#   9. Ставит LaunchAgent: при входе в систему открывает окно Zapret.app,
#      если обход работает — чтобы про него не забывать.
#  10. Запускает сервис.
#
# После этого YouTube должен открываться сам по себе.

set -e

# ----- Цвета для логов -----
RED='\033[0;31m'
GRN='\033[0;32m'
YLW='\033[1;33m'
CLR='\033[0m'

info()  { printf "${GRN}[+] %s${CLR}\n" "$*"; }
warn()  { printf "${YLW}[!] %s${CLR}\n" "$*"; }
die()   { printf "${RED}[x] %s${CLR}\n" "$*" >&2; exit 1; }

# ----- 1. Проверка платформы -----
[ "$(uname)" = "Darwin" ] || die "Этот скрипт только для macOS."

# ----- 2. Проверка прав root -----
if [ "$EUID" -ne 0 ]; then
    info "Нужны права администратора. Перезапускаюсь через sudo..."
    exec sudo -E "$0" "$@"
fi

# ----- 3. Определяем корень исходников (папка zapret-v72.12) -----
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

[ -d "$SRC_DIR/init.d/macos" ] || die "Не нашёл $SRC_DIR/init.d/macos. Положи install.sh в подпапку mac внутри zapret-v72.12."
[ -d "$SRC_DIR/binaries/mac64" ] || die "Не нашёл $SRC_DIR/binaries/mac64."

INSTALL_DIR="/opt/zapret"

# Пользователь, которому даём управление GUI без пароля и агент автооткрытия.
# Несколько fallback'ов: SUDO_USER (sudo из терминала), консольный владелец
# (нормальный запуск), SCDynamicStore (надёжно при эскалации из AppleScript).
GUI_USER="${SUDO_USER:-}"
if [ -z "$GUI_USER" ] || [ "$GUI_USER" = "root" ]; then
    GUI_USER="$(stat -f%Su /dev/console 2>/dev/null)"
fi
if [ -z "$GUI_USER" ] || [ "$GUI_USER" = "root" ]; then
    GUI_USER="$(scutil <<< "show State:/Users/ConsoleUser" 2>/dev/null | awk '/Name :/{print $3}')"
fi
if [ -z "$GUI_USER" ] || [ "$GUI_USER" = "root" ]; then
    GUI_USER="$(who | awk '/console/{print $1; exit}')"
fi

# Если install.sh запущен из самой установки (/opt/zapret/mac) — например,
# через «Переустановить» в GUI из /Applications — то копировать нечего и
# удалять /opt/zapret нельзя (снесли бы сами себя). Работаем в режиме
# «обновить на месте»: только конфиг, сервисы и права.
IN_PLACE=0
[ "$SRC_DIR" = "$INSTALL_DIR" ] && IN_PLACE=1

if [ "$IN_PLACE" = "0" ]; then
    # ----- 4. Останавливаем старую установку, если есть -----
    if [ -f "$INSTALL_DIR/init.d/macos/zapret" ]; then
        warn "Найдена предыдущая установка в $INSTALL_DIR — останавливаю и удаляю..."
        "$INSTALL_DIR/init.d/macos/zapret" stop 2>/dev/null || true
        launchctl unload /Library/LaunchDaemons/zapret.plist 2>/dev/null || true
        rm -f /Library/LaunchDaemons/zapret.plist
        rm -rf "$INSTALL_DIR"
    fi

    # ----- 5. Копируем zapret в /opt/zapret -----
    info "Копирую zapret в $INSTALL_DIR ..."
    mkdir -p "$INSTALL_DIR"
    # rsync проще для частичных копий, но cp -R работает везде
    ( cd "$SRC_DIR" && tar cf - . ) | ( cd "$INSTALL_DIR" && tar xf - )
else
    warn "Запуск из $INSTALL_DIR — обновляю установку на месте (без копирования)."
    "$INSTALL_DIR/init.d/macos/zapret" stop 2>/dev/null || true
fi

# ----- 6. Снимаем карантин с бинарников -----
info "Снимаю карантин Apple Gatekeeper..."
find "$INSTALL_DIR/binaries/mac64" -type f -exec xattr -d com.apple.quarantine {} \; 2>/dev/null || true
find "$INSTALL_DIR/binaries/mac64" -type f -exec chmod +x {} \; || true

# ----- 7. Разворачиваем бинарники: install_bin.sh поставит симлинки -----
info "Раскладываю бинарники (mac64 universal: arm64 + x86_64)..."
( cd "$INSTALL_DIR" && /bin/sh ./install_bin.sh ) || die "Не удалось установить бинарники."

# ----- 8. Подкладываем наш конфиг и список доменов -----
info "Подкладываю конфигурацию и список доменов..."
cp "$SCRIPT_DIR/config.macos"     "$INSTALL_DIR/config"
# При обновлении на месте список доменов пользователя не трогаем.
if [ "$IN_PLACE" = "0" ] || [ ! -f "$INSTALL_DIR/ipset/zapret-hosts-user.txt" ]; then
    cp "$SCRIPT_DIR/zapret-hosts.txt" "$INSTALL_DIR/ipset/zapret-hosts-user.txt"
fi

# Создаём пустой файл исключений (если его нет).
[ -f "$INSTALL_DIR/ipset/zapret-hosts-user-exclude.txt" ] || \
    cp "$INSTALL_DIR/ipset/zapret-hosts-user-exclude.txt.default" \
       "$INSTALL_DIR/ipset/zapret-hosts-user-exclude.txt" 2>/dev/null || \
    touch "$INSTALL_DIR/ipset/zapret-hosts-user-exclude.txt"

# Делаем список доменов user-writable (чтобы можно было править через GUI без sudo).
chmod 666 "$INSTALL_DIR/ipset/zapret-hosts-user.txt" 2>/dev/null || true

# Копируем мак-скрипты в стандартное место /opt/zapret/mac.
# Это нужно для GUI-приложения Zapret.app, чтобы оно могло работать из /Applications.
if [ "$IN_PLACE" = "0" ]; then
    info "Копирую mac-скрипты в $INSTALL_DIR/mac ..."
    mkdir -p "$INSTALL_DIR/mac"
    cp "$SCRIPT_DIR"/*.sh "$INSTALL_DIR/mac/"
    cp "$SCRIPT_DIR/config.macos" "$INSTALL_DIR/mac/" 2>/dev/null || true
    cp "$SCRIPT_DIR/zapret-hosts.txt" "$INSTALL_DIR/mac/" 2>/dev/null || true
fi
chmod +x "$INSTALL_DIR/mac/"*.sh

# Копируем приложение в /Applications, чтобы оно было под рукой в Spotlight
# и его мог найти агент автооткрытия при входе в систему.
if [ -d "$SCRIPT_DIR/Zapret.app" ] && [ "$IN_PLACE" = "0" ]; then
    info "Копирую Zapret.app в /Applications ..."
    rm -rf /Applications/Zapret.app
    cp -R "$SCRIPT_DIR/Zapret.app" /Applications/Zapret.app
    if [ -n "$GUI_USER" ]; then
        chown -R "$GUI_USER" /Applications/Zapret.app 2>/dev/null || true
    fi
    xattr -dr com.apple.quarantine /Applications/Zapret.app 2>/dev/null || true
fi

# Вся установка принадлежит root: это обязательное условие безопасности для
# sudoers NOPASSWD ниже (иначе скрипты мог бы подменить кто угодно).
info "Выставляю владельца root на $INSTALL_DIR ..."
chown -R root:wheel "$INSTALL_DIR" 2>/dev/null || true
# Список доменов оставляем редактируемым из GUI без sudo.
chmod 666 "$INSTALL_DIR/ipset/zapret-hosts-user.txt" 2>/dev/null || true

# ----- 9. Регистрируем launchd-сервис -----
info "Регистрирую launchd-сервис..."
ln -fs "$INSTALL_DIR/init.d/macos/zapret.plist" /Library/LaunchDaemons/zapret.plist
# launchd хочет owner=root и определённые права
chown root:wheel "$INSTALL_DIR/init.d/macos/zapret.plist" 2>/dev/null || true
chmod 644 "$INSTALL_DIR/init.d/macos/zapret.plist" 2>/dev/null || true

# ----- 9a. Тумблер без пароля: sudoers-правило для GUI -----
# Разрешаем конкретному пользователю запускать только наши управляющие
# скрипты (root-owned, права 755) без пароля. Установка/удаление пароль
# по-прежнему спрашивают.
if [ -n "$GUI_USER" ]; then
    info "Разрешаю управление без пароля для пользователя $GUI_USER ..."
    SUDOERS_TMP=$(mktemp)
    cat >"$SUDOERS_TMP" <<EOF
# Создано zapret install.sh: управление обходом из Zapret.app без пароля.
# Скрипты принадлежат root и не доступны на запись пользователю.
$GUI_USER ALL=(root) NOPASSWD: $INSTALL_DIR/mac/start.sh, $INSTALL_DIR/mac/stop.sh, $INSTALL_DIR/mac/status.sh, $INSTALL_DIR/mac/strategy.sh
EOF
    VISUDO_ERR=$(visudo -cf "$SUDOERS_TMP" 2>&1)
    if [ $? -eq 0 ]; then
        install -m 0440 -o root -g wheel "$SUDOERS_TMP" /etc/sudoers.d/zapret
        info "Готово: «Включить/Выключить» в GUI больше не просят пароль."
    else
        warn "visudo забраковал sudoers-правило: $VISUDO_ERR"
        warn "GUI будет спрашивать пароль. Исправь вручную: sudo visudo -f /etc/sudoers.d/zapret"
    fi
    rm -f "$SUDOERS_TMP"
else
    warn "Не смог определить пользователя GUI — пропускаю настройку sudoers."
fi

# ----- 9b. Автопауза при VPN: демон vpn-watch -----
info "Ставлю vpn-watch (автопауза zapret при включении VPN)..."
cat >/Library/LaunchDaemons/zapret.vpnwatch.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>zapret.vpnwatch</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$INSTALL_DIR/mac/vpn-watch.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>WatchPaths</key>
    <array>
        <string>/Library/Preferences/SystemConfiguration</string>
    </array>
    <key>StartInterval</key>
    <integer>30</integer>
    <key>ThrottleInterval</key>
    <integer>10</integer>
</dict>
</plist>
EOF
chown root:wheel /Library/LaunchDaemons/zapret.vpnwatch.plist
chmod 644 /Library/LaunchDaemons/zapret.vpnwatch.plist
launchctl bootout system/zapret.vpnwatch 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/zapret.vpnwatch.plist 2>/dev/null || \
    launchctl load -w /Library/LaunchDaemons/zapret.vpnwatch.plist 2>/dev/null || true

# ----- 9c. Автооткрытие окна при входе в систему -----
# Если zapret стартовал в фоне, при логине открываем Zapret.app — чтобы было
# видно, что обход включён, и его можно было выключить одним кликом.
if [ -n "$GUI_USER" ] && [ -d "/Users/$GUI_USER" ]; then
    info "Ставлю автооткрытие Zapret.app при входе (пользователь $GUI_USER)..."
    AGENT_DIR="/Users/$GUI_USER/Library/LaunchAgents"
    mkdir -p "$AGENT_DIR"
    cat >"$AGENT_DIR/zapret.gui.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>zapret.gui</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$INSTALL_DIR/mac/gui-login.sh</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF
    chown "$GUI_USER" "$AGENT_DIR/zapret.gui.plist"
    chmod 644 "$AGENT_DIR/zapret.gui.plist"
fi

# ----- 10. Стартуем zapret (это патчит /etc/pf.conf и запускает tpws) -----
info "Запускаю zapret (патчу /etc/pf.conf, поднимаю tpws)..."
"$INSTALL_DIR/init.d/macos/zapret" start

# ----- 11. Загружаем launchd-юнит (на случай если он ещё не загружен) -----
launchctl load -w /Library/LaunchDaemons/zapret.plist 2>/dev/null || true

# ----- 12. Финальная проверка -----
sleep 1
if pgrep -x tpws >/dev/null; then
    info "Готово! tpws работает (PID $(pgrep -x tpws | tr '\n' ' '))."
    info "Открывай YouTube — должен заработать."
    echo
    echo "  Управление:"
    echo "    Старт:    sudo $SCRIPT_DIR/start.sh"
    echo "    Стоп:     sudo $SCRIPT_DIR/stop.sh"
    echo "    Статус:   sudo $SCRIPT_DIR/status.sh"
    echo "    Удалить:  sudo $SCRIPT_DIR/uninstall.sh"
    echo
    echo "  Список сайтов:  $INSTALL_DIR/ipset/zapret-hosts-user.txt"
    echo "  Конфиг:         $INSTALL_DIR/config"
    echo "  Лог tpws:       консоль (Console.app, фильтр 'tpws')"
else
    die "tpws не поднялся. Запусти 'sudo $INSTALL_DIR/init.d/macos/zapret start' руками и посмотри вывод."
fi
