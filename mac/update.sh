#!/bin/bash
# update.sh — обновление списка заблокированных доменов.
#
# Источник: itdoginfo/allow-domains (самый популярный курируемый список
# доменов, заблокированных в РФ по DPI). Качаем «inside-raw.lst».
#
# Личные домены пользователя НЕ затираются: файл zapret-hosts-user.txt
# делится на две части —
#   * всё ДО строки «# >>> AUTO» — личное, редактируется через GUI;
#   * блок между «# >>> AUTO» и «# <<< AUTO» — авто-список, перезаписывается.
#
# Запускается из GUI через `sudo -n`. Требует root.

if [ "$EUID" -ne 0 ]; then
    exec sudo -E "$0" "$@"
fi

INSTALL_DIR="/opt/zapret"
HOSTS="$INSTALL_DIR/ipset/zapret-hosts-user.txt"
URL="https://raw.githubusercontent.com/itdoginfo/allow-domains/main/Russia/inside-raw.lst"
BEGIN="# >>> AUTO (itdoginfo/allow-domains) — не редактировать, перезаписывается"
END="# <<< AUTO"

echo "[*] Скачиваю список доменов с itdoginfo/allow-domains…"
TMP=$(mktemp)
if ! curl -fsSL -m 30 "$URL" -o "$TMP"; then
    echo "[x] Не удалось скачать список (нет интернета? включён DPI без обхода?)."
    echo "    Если zapret выключен — включи обход и попробуй снова."
    rm -f "$TMP"
    exit 1
fi

# Чистим: убираем CR, пустые строки и комментарии источника.
CLEAN=$(mktemp)
tr -d '\r' <"$TMP" | grep -vE '^\s*#' | grep -vE '^\s*$' | sort -u >"$CLEAN"
COUNT=$(grep -c . "$CLEAN")
rm -f "$TMP"

if [ "$COUNT" -lt 100 ]; then
    echo "[x] Скачался подозрительно короткий список ($COUNT строк) — отменяю, чтобы не сломать."
    rm -f "$CLEAN"
    exit 1
fi
echo "[+] Получено доменов: $COUNT"

# Сохраняем личную часть (всё до маркера AUTO). Если файла нет — создаём шапку.
PERSONAL=$(mktemp)
if [ -f "$HOSTS" ]; then
    awk -v b="$BEGIN" 'index($0,b)==1{exit} {print}' "$HOSTS" >"$PERSONAL"
fi
if ! grep -qE '[^[:space:]]' "$PERSONAL"; then
    cat >"$PERSONAL" <<'HDR'
# Личные домены — добавляй свои сюда, над блоком AUTO. Пример:
# example.com
# mysite.org

HDR
fi

# Собираем итоговый файл: личное + авто-блок.
{
    cat "$PERSONAL"
    echo "$BEGIN $(date '+%Y-%m-%d %H:%M')"
    cat "$CLEAN"
    echo "$END"
} >"$HOSTS"
rm -f "$PERSONAL" "$CLEAN"

# Список должен быть редактируемым из GUI без sudo.
chmod 666 "$HOSTS" 2>/dev/null || true
TOTAL=$(grep -vcE '^\s*#|^\s*$' "$HOSTS")
echo "[+] Список обновлён: всего активных доменов $TOTAL."

# Если обход работает — перезапускаем, чтобы tpws подхватил новый список.
if pgrep -x tpws >/dev/null 2>&1; then
    echo "[*] Перезапускаю zapret, чтобы применить новый список…"
    "$INSTALL_DIR/mac/start.sh" >/dev/null 2>&1
    pgrep -x tpws >/dev/null 2>&1 && echo "[+] Готово, обход снова работает." \
                                  || echo "[!] tpws не поднялся — проверь вручную."
else
    echo "[i] Обход сейчас выключен — список применится при следующем включении."
fi
