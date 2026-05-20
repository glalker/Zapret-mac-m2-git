#!/bin/bash
# Полное удаление zapret. Требует sudo.

set -e

if [ "$EUID" -ne 0 ]; then
    exec sudo -E "$0" "$@"
fi

INSTALL_DIR="/opt/zapret"

echo "[+] Останавливаю и снимаю PF-якоря..."
launchctl unload /Library/LaunchDaemons/zapret.plist 2>/dev/null || true
if [ -x "$INSTALL_DIR/init.d/macos/zapret" ]; then
    "$INSTALL_DIR/init.d/macos/zapret" stop 2>/dev/null || true
    "$INSTALL_DIR/init.d/macos/zapret" stop-fw 2>/dev/null || true
fi
pkill -x tpws 2>/dev/null || true

echo "[+] Чищу /etc/pf.conf..."
if [ -f /etc/pf.conf ]; then
    sed -i '' \
        -e '/^anchor "zapret"$/d' \
        -e '/^rdr-anchor "zapret"$/d' \
        -e '/^set limit table-entries/d' \
        /etc/pf.conf 2>/dev/null || true
    pfctl -qf /etc/pf.conf 2>/dev/null || true
fi

echo "[+] Удаляю файлы..."
rm -f /Library/LaunchDaemons/zapret.plist
rm -f /etc/pf.anchors/zapret /etc/pf.anchors/zapret-v4 /etc/pf.anchors/zapret-v6
rm -rf "$INSTALL_DIR"

echo "[+] Готово. zapret полностью удалён с системы."
