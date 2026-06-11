#!/bin/bash
# Запуск zapret. Требует sudo.
# Намеренно БЕЗ "set -e": при включённом VPN отдельные PF-команды могут вернуть
# ненулевой код, но это не повод валить весь запуск. Успех определяем по факту —
# поднялся ли процесс tpws.

if [ "$EUID" -ne 0 ]; then
    exec sudo -E "$0" "$@"
fi

INSTALL_DIR="/opt/zapret"
ZAPRET_BIN="$INSTALL_DIR/init.d/macos/zapret"

if [ ! -x "$ZAPRET_BIN" ]; then
    echo "[x] zapret не установлен. Сначала нажми «Установить / Переустановить»." >&2
    exit 1
fi

# Ручной запуск = пользователь хочет обход включённым: снимаем флаг автопаузы
# и флаг «выключено вручную», чтобы vpn-watch снова управлял состоянием.
rm -f /var/run/zapret.paused-by-vpn /var/run/zapret.user-off

# Если запускаемся при уже активном VPN — это осознанный выбор «хочу оба сразу».
# Ставим override, чтобы vpn-watch не погасил обход. Override снимается, когда
# VPN отключится (vpn-watch) или при ручной остановке (stop.sh).
if scutil --nc list 2>/dev/null | grep -q '(Connected)' || \
   route -n get default 2>/dev/null | awk '/interface:/{print $2}' | grep -qE '^(utun|ipsec|ppp|tun|tap|wg)'; then
    touch /var/run/zapret.manual-override
fi

# 1. Чистый рестарт: глушим возможные старые процессы, чтобы не плодить инстансы
#    и не ловить рассинхрон pid-файлов (из-за него статус «врал»).
"$ZAPRET_BIN" stop 2>/dev/null || true
for pf in /var/run/tpws*.pid; do
    [ -f "$pf" ] || continue
    pid=""
    read -r pid <"$pf" 2>/dev/null || true
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
    rm -f "$pf"
done
pkill -x tpws 2>/dev/null || true
sleep 1

# 2. Запускаем. Если PF-часть споткнётся о правила VPN — продолжаем,
#    tpws всё равно поднимется, а предупреждения уйдут в вывод.
"$ZAPRET_BIN" start || echo "[!] init-скрипт вернул ошибку (часто из-за активного VPN) — проверяю процесс ниже."

# 3. Регистрируем демон для автозапуска (idempotent).
launchctl load -w /Library/LaunchDaemons/zapret.plist 2>/dev/null || true

# 4. Успех определяем по факту работы tpws.
sleep 1
if pgrep -x tpws >/dev/null 2>&1; then
    echo "[+] zapret запущен. tpws PID: $(pgrep -x tpws | tr '\n' ' ')"
    echo "    Если рядом работает VPN и какой-то сайт не открывается — попробуй"
    echo "    «Остановить» → «Запустить» уже при включённом VPN."
    exit 0
else
    echo "[x] tpws не поднялся." >&2
    echo "    Подсказка: если включён VPN, который сам управляет фаерволом (PF)," >&2
    echo "    запусти zapret ОДИН раз при выключенном VPN — он пропишет PF-якоря," >&2
    echo "    после этого их можно включать вместе." >&2
    exit 1
fi
