#!/bin/bash
# strategy.sh — переключение стратегии обхода DPI (tpws). Требует root.
#
#   strategy.sh list           — список доступных стратегий
#   strategy.sh current        — какая стратегия активна
#   strategy.sh set <имя>      — записать стратегию в /opt/zapret/config и перезапустить
#
# Набор взят из проверенных на macOS пресетов (tpws v72.12). Если ни одна не
# работает — точную стратегию под провайдера подбирает /opt/zapret/blockcheck.sh.

if [ "$EUID" -ne 0 ]; then
    exec sudo -E "$0" "$@"
fi

INSTALL_DIR="/opt/zapret"
CONFIG="$INSTALL_DIR/config"
STATE="$INSTALL_DIR/mac/.strategy"

# имя|описание|опции для 80 порта|опции для 443 порта
PRESETS="
default|Сплит SNI (1,midsld) + disorder — рекомендуется|--methodeol|--split-pos=1,midsld --disorder
split-only|Только сплит, без disorder — если default рвёт соединения|--methodeol|--split-pos=1,midsld
midsld|Сплит по середине домена + disorder|--methodeol|--split-pos=midsld --disorder
oob|Сплит + out-of-band байт — против въедливых DPI|--methodeol|--split-pos=1,midsld --oob
hostcase|Искажение Host (регистр+точка) + сплит — запасной вариант|--methodeol --hostcase --hostdot|--split-pos=1 --disorder
"

die() { echo "[x] $*" >&2; exit 1; }

list_presets() {
    echo "$PRESETS" | while IFS='|' read -r name desc o80 o443; do
        [ -n "$name" ] || continue
        echo "$name — $desc"
    done
}

find_preset() {
    echo "$PRESETS" | while IFS='|' read -r name desc o80 o443; do
        [ "$name" = "$1" ] && echo "$o80|$o443"
    done
}

case "$1" in
    list)
        list_presets
        ;;
    current)
        if [ -f "$STATE" ]; then cat "$STATE"; else echo "default"; fi
        ;;
    set)
        NAME="$2"
        [ -n "$NAME" ] || die "Укажи имя стратегии. Список: strategy.sh list"
        [ -f "$CONFIG" ] || die "Не нашёл $CONFIG — zapret не установлен?"
        OPTS=$(find_preset "$NAME")
        [ -n "$OPTS" ] || die "Нет такой стратегии: $NAME. Список: strategy.sh list"
        O80="${OPTS%%|*}"
        O443="${OPTS##*|}"

        NEW_BLOCK="TPWS_OPT=\"
--filter-tcp=80 $O80 <HOSTLIST> --new
--filter-tcp=443 $O443 <HOSTLIST>
\""
        TMP=$(mktemp)
        # BSD awk не принимает многострочные -v, поэтому блок передаём через окружение.
        NEW_BLOCK="$NEW_BLOCK" awk '
            /^TPWS_OPT="/ { print ENVIRON["NEW_BLOCK"]; skip=1; next }
            skip && /^"$/ { skip=0; next }
            !skip { print }
        ' "$CONFIG" >"$TMP" || die "Не смог обработать конфиг."
        grep -q '^TPWS_OPT="' "$TMP" || die "Конфиг после правки сломан — отмена."
        cat "$TMP" >"$CONFIG"
        rm -f "$TMP"
        echo "$NAME" >"$STATE"
        chmod 644 "$STATE" 2>/dev/null || true

        echo "[+] Стратегия «$NAME» записана в конфиг. Перезапускаю zapret..."
        "$INSTALL_DIR/mac/start.sh"
        ;;
    *)
        echo "Использование: strategy.sh list | current | set <имя>"
        exit 1
        ;;
esac
