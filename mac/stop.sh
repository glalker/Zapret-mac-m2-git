#!/bin/bash
# Остановка zapret. Гарантированно убивает tpws и снимает PF-якоря. Требует sudo.
# Намеренно БЕЗ "set -e": нам нужно пройти все шаги до конца, даже если
# отдельные команды вернут ошибку (например, демон уже выгружен).

if [ "$EUID" -ne 0 ]; then
    exec sudo -E "$0" "$@"
fi

INSTALL_DIR="/opt/zapret"
LOG="${ZAPRET_LOG:-/tmp/zapret-gui.log}"

log() { echo "$*"; }

# 0. Ручная остановка = пользователь хочет «выключить совсем».
#    stop.sh запускается ТОЛЬКО пользователем (GUI/терминал); автопауза
#    использует init-скрипт напрямую, не этот файл. Поэтому:
#    - снимаем флаги автопаузы/override;
#    - ставим флаг user-off, чтобы vpn-watch НЕ воскресил обход после
#      выключения VPN. Снимется только при ручном «Включить» (start.sh).
rm -f /var/run/zapret.paused-by-vpn /var/run/zapret.manual-override
touch /var/run/zapret.user-off

# 1. Выгружаем launchd-демон, чтобы он не поднял tpws заново.
#    Пробуем и современный (bootout), и старый (unload) синтаксис.
launchctl bootout system/zapret 2>/dev/null || true
launchctl unload /Library/LaunchDaemons/zapret.plist 2>/dev/null || true

# 2. Штатно снимаем PF-якоря и останавливаем демоны через init-скрипт.
if [ -x "$INSTALL_DIR/init.d/macos/zapret" ]; then
    "$INSTALL_DIR/init.d/macos/zapret" stop 2>/dev/null || true
fi

# 3. Добиваем процессы tpws по их pid-файлам.
for pf in /var/run/tpws*.pid; do
    [ -f "$pf" ] || continue
    pid=""
    read -r pid <"$pf" 2>/dev/null || true
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pf"
done

# 4. И по имени процесса — на случай осиротевших инстансов.
pkill -x tpws 2>/dev/null || true

# 5. Ждём до 5 секунд штатного завершения.
i=0
while [ "$i" -lt 5 ]; do
    pgrep -x tpws >/dev/null 2>&1 || break
    sleep 1
    i=$((i + 1))
done

# 6. Если всё ещё жив — бьём SIGKILL.
if pgrep -x tpws >/dev/null 2>&1; then
    pkill -9 -x tpws 2>/dev/null || true
    sleep 1
fi

# 7. Честная проверка результата.
if pgrep -x tpws >/dev/null 2>&1; then
    log "[x] Не удалось полностью остановить tpws (PID: $(pgrep -x tpws | tr '\n' ' '))."
    exit 1
fi

log "[+] zapret остановлен: tpws убит, PF-якоря сняты, демон выгружен."
exit 0
