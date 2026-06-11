#!/bin/bash
# gui-login.sh — запускается LaunchAgent'ом при входе пользователя в систему.
# Если zapret стартовал в фоне (автозапуск), открывает окно Zapret.app —
# чтобы было видно, что обход включён, и его можно было выключить в один клик.

sleep 6

# Автозапуск выключен или zapret удалён — ничего не показываем.
[ -f /Library/LaunchDaemons/zapret.plist ] || exit 0

# Показываем окно только когда обход реально работает.
pgrep -x tpws >/dev/null 2>&1 || exit 0

for app in "/Applications/Zapret.app" "/opt/zapret/mac/Zapret.app"; do
    if [ -d "$app" ]; then
        open "$app"
        exit 0
    fi
done
exit 0
