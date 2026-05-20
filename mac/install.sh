#!/bin/bash
#
# install.sh — установщик zapret для macOS (Apple Silicon / Intel).
# Запускай так:
#   cd "/Users/kereytovgleb/cloudeP/Claude/Projects/zapret-v72.12/mac"
#   sudo ./install.sh
#
# Делает следующее:
#   1. Проверяет, что мы на маке.
#   2. Копирует zapret в /opt/zapret.
#   3. Раскладывает бинарники (универсальные mac64: arm64 + x86_64).
#   4. Подкладывает наш конфиг и список доменов.
#   5. Патчит /etc/pf.conf (добавляет якоря zapret).
#   6. Регистрирует launchd-сервис /Library/LaunchDaemons/zapret.plist.
#   7. Запускает сервис.
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
cp "$SCRIPT_DIR/zapret-hosts.txt" "$INSTALL_DIR/ipset/zapret-hosts-user.txt"

# Создаём пустой файл исключений (если его нет).
[ -f "$INSTALL_DIR/ipset/zapret-hosts-user-exclude.txt" ] || \
    cp "$INSTALL_DIR/ipset/zapret-hosts-user-exclude.txt.default" \
       "$INSTALL_DIR/ipset/zapret-hosts-user-exclude.txt" 2>/dev/null || \
    touch "$INSTALL_DIR/ipset/zapret-hosts-user-exclude.txt"

# Делаем список доменов user-writable (чтобы можно было править через GUI без sudo).
chmod 666 "$INSTALL_DIR/ipset/zapret-hosts-user.txt" 2>/dev/null || true

# Копируем мак-скрипты в стандартное место /opt/zapret/mac.
# Это нужно для GUI-приложения Zapret.app, чтобы оно могло работать из /Applications.
info "Копирую mac-скрипты в $INSTALL_DIR/mac ..."
mkdir -p "$INSTALL_DIR/mac"
cp "$SCRIPT_DIR"/*.sh "$INSTALL_DIR/mac/"
cp "$SCRIPT_DIR/config.macos" "$INSTALL_DIR/mac/" 2>/dev/null || true
cp "$SCRIPT_DIR/zapret-hosts.txt" "$INSTALL_DIR/mac/" 2>/dev/null || true
chmod +x "$INSTALL_DIR/mac/"*.sh

# ----- 9. Регистрируем launchd-сервис -----
info "Регистрирую launchd-сервис..."
ln -fs "$INSTALL_DIR/init.d/macos/zapret.plist" /Library/LaunchDaemons/zapret.plist
# launchd хочет owner=root и определённые права
chown root:wheel "$INSTALL_DIR/init.d/macos/zapret.plist" 2>/dev/null || true
chmod 644 "$INSTALL_DIR/init.d/macos/zapret.plist" 2>/dev/null || true

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
