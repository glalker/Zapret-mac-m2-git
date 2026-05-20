#!/bin/bash
# Проверка статуса zapret. Лаконичный вывод (помещается в окно GUI).

if [ "$EUID" -ne 0 ]; then
    exec sudo -E "$0" "$@"
fi

INSTALL_DIR="/opt/zapret"

if [ -d "$INSTALL_DIR" ]; then
    echo "Установка   : ✅ /opt/zapret"
else
    echo "Установка   : ❌ не установлен (запусти install.sh)"
    exit 0
fi

if [ -f /Library/LaunchDaemons/zapret.plist ]; then
    echo "Автозапуск  : ✅ launchd зарегистрирован"
else
    echo "Автозапуск  : ⚪ launchd не зарегистрирован"
fi

if pgrep -x tpws >/dev/null 2>&1; then
    echo "Процесс tpws: 🟢 работает (PID: $(pgrep -x tpws | tr '\n' ' '))"
else
    echo "Процесс tpws: ⚪ не запущен"
fi

if pfctl -s info 2>/dev/null | head -1 | grep -q Enabled; then
    echo "PF (фаервол): 🟢 включён"
else
    echo "PF (фаервол): ⚪ выключен"
fi

if pfctl -a zapret-v4 -s nat 2>/dev/null | grep -q . ; then
    echo "PF-якоря    : ✅ правила zapret загружены"
else
    echo "PF-якоря    : ⚪ правил zapret нет"
fi

# Активные VPN-туннели — полезно при диагностике конфликтов.
VPN_IF=$(ifconfig 2>/dev/null | grep -Eo '^(utun|ipsec|tap|tun|wg)[0-9]+' | tr '\n' ' ')
if [ -n "$VPN_IF" ]; then
    echo "VPN-туннели : 🔌 активны ($VPN_IF)"
else
    echo "VPN-туннели : — не обнаружены"
fi

if [ -f "$INSTALL_DIR/ipset/zapret-hosts-user.txt" ]; then
    COUNT=$(grep -cvE '^\s*(#|$)' "$INSTALL_DIR/ipset/zapret-hosts-user.txt" 2>/dev/null)
    echo "Список сайтов: $COUNT доменов"
fi
exit 0
