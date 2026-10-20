#!/bin/bash
# strategy.sh — переключение стратегии обхода DPI (tpws). Требует root.
#
#   strategy.sh list           — список доступных стратегий
#   strategy.sh names          — только имена (для автоподбора)
#   strategy.sh current        — какая стратегия активна
#   strategy.sh set <имя>      — записать стратегию в /opt/zapret/config и перезапустить
#   strategy.sh apply <имя>    — только записать в конфиг, без перезапуска
#                                (нужно установщику, чтобы вернуть выбор после обновления)
#
# Все пресеты проверены на macOS-сборке tpws v72.12. Что важно знать про мак:
#   * --mss и --fix-seg работают только в Linux — здесь их нет;
#   * --oob и --disorder вместе на macOS запрещены (tpws завершится);
#   * --tlsrec режет ClientHello на две TLS-записи — сильнейший приём против
#     ТСПУ, который доступен tpws на маке.
# Если ни одна не работает — точную стратегию под провайдера подбирает
# /opt/zapret/blockcheck.sh.

if [ "$EUID" -ne 0 ]; then
    exec sudo -E "$0" "$@"
fi

INSTALL_DIR="/opt/zapret"
CONFIG="$INSTALL_DIR/config"
STATE="$INSTALL_DIR/mac/.strategy"

# имя|описание|опции для 80 порта|опции для 443 порта
# Порядок важен: автоподбор (selftest.sh) при равенстве результатов
# предпочитает стратегию, стоящую выше.
PRESETS="
default|Сплит SNI (1,midsld) + disorder — рекомендуется|--methodeol|--split-pos=1,midsld --disorder
tlsrec|TLS-записи + сплит + disorder — сильнее против ТСПУ|--methodeol|--tlsrec=sniext --split-pos=1,midsld --disorder
tlsrec-multi|TLS-записи + мультисплит по домену — если tlsrec мало|--methodeol --hostcase --domcase|--tlsrec=sniext --split-pos=1,host+1,midsld,endhost-1 --disorder
tlsrec-mid|TLS-запись режется посреди домена + disorder|--methodeol|--tlsrec=midsld --split-pos=1,midsld --disorder
multisplit|Мультисплит по домену + disorder, без TLS-записей|--methodeol|--split-pos=1,host+1,midsld,endhost-1 --disorder
split-only|Только сплит, без disorder — если default рвёт соединения|--methodeol|--split-pos=1,midsld
midsld|Сплит по середине домена + disorder|--methodeol|--split-pos=midsld --disorder
hostcase|Искажение Host (регистр+точка) + сплит — запасной вариант|--methodeol --hostcase --hostdot|--split-pos=1 --disorder
oob|Сплит + out-of-band байт — экспериментально, ломается под VPN|--methodeol|--split-pos=1,midsld --oob
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

write_config() {
    local name="$1" opts o80 o443 new_block tmp
    [ -n "$name" ] || die "Укажи имя стратегии. Список: strategy.sh list"
    [ -f "$CONFIG" ] || die "Не нашёл $CONFIG — zapret не установлен?"
    opts=$(find_preset "$name")
    [ -n "$opts" ] || die "Нет такой стратегии: $name. Список: strategy.sh list"
    o80="${opts%%|*}"
    o443="${opts##*|}"

    new_block="TPWS_OPT=\"
--filter-tcp=80 $o80 <HOSTLIST> --new
--filter-tcp=443 $o443 <HOSTLIST>
\""
    tmp=$(mktemp)
    # BSD awk не принимает многострочные -v, поэтому блок передаём через окружение.
    NEW_BLOCK="$new_block" awk '
        /^TPWS_OPT="/ { print ENVIRON["NEW_BLOCK"]; skip=1; next }
        skip && /^"$/ { skip=0; next }
        !skip { print }
    ' "$CONFIG" >"$tmp" || { rm -f "$tmp"; die "Не смог обработать конфиг."; }
    grep -q '^TPWS_OPT="' "$tmp" || { rm -f "$tmp"; die "Конфиг после правки сломан — отмена."; }
    cat "$tmp" >"$CONFIG"
    rm -f "$tmp"
    echo "$name" >"$STATE"
    chmod 644 "$STATE" 2>/dev/null || true
}

case "$1" in
    list)
        list_presets
        ;;
    names)
        echo "$PRESETS" | while IFS='|' read -r name _; do
            [ -n "$name" ] && echo "$name"
        done
        ;;
    current)
        if [ -f "$STATE" ]; then cat "$STATE"; else echo "default"; fi
        ;;
    apply)
        write_config "$2"
        echo "[+] Стратегия «$2» записана в конфиг."
        ;;
    set)
        write_config "$2"
        echo "[+] Стратегия «$2» записана в конфиг. Перезапускаю zapret..."
        "$INSTALL_DIR/mac/start.sh"
        ;;
    *)
        echo "Использование: strategy.sh list | names | current | set <имя> | apply <имя>"
        exit 1
        ;;
esac
