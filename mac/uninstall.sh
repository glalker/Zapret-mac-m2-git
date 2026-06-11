#!/bin/bash
# Полное удаление zapret. Требует sudo.

set -e

if [ "$EUID" -ne 0 ]; then
    exec sudo -E "$0" "$@"
fi

INSTALL_DIR="/opt/zapret"

echo "[+] Останавливаю и снимаю PF-якоря..."
launchctl bootout system/zapret.vpnwatch 2>/dev/null || true
launchctl unload /Library/LaunchDaemons/zapret.vpnwatch.plist 2>/dev/null || true
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
rm -f /Library/LaunchDaemons/zapret.vpnwatch.plist
rm -f /etc/sudoers.d/zapret
rm -f /var/run/zapret.paused-by-vpn /var/run/zapret.manual-override /var/run/zapret.user-off
rm -f /etc/pf.anchors/zapret /etc/pf.anchors/zapret-v4 /etc/pf.anchors/zapret-v6
rm -rf "$INSTALL_DIR"

# Агент автооткрытия и приложение у пользователя.
GUI_USER="${SUDO_USER:-$(stat -f%Su /dev/console 2>/dev/null)}"
if [ -n "$GUI_USER" ]; then
    rm -f "/Users/$GUI_USER/Library/LaunchAgents/zapret.gui.plist"
fi
rm -rf /Applications/Zapret.app

echo "[+] Готово. zapret полностью удалён с системы."
