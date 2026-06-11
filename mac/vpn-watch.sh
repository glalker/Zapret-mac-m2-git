#!/bin/bash
# vpn-watch.sh — автопауза zapret при включении VPN.
#
# Запускается launchd-демоном zapret.vpnwatch (см. install.sh): при каждом
# изменении сетевой конфигурации + раз в 30 секунд как страховка.
#
# Логика:
#   * VPN включился, tpws работает  -> останавливаем zapret, ставим флаг паузы.
#   * VPN выключился, флаг стоит    -> поднимаем zapret обратно, флаг снимаем.
#   * Ручной start/stop через GUI снимает флаг — пользовательское решение
#     всегда главнее автоматики.
#
# Отключить автопаузу насовсем: sudo touch /opt/zapret/mac/vpn-watch.disabled

INSTALL_DIR="/opt/zapret"
ZAPRET_BIN="$INSTALL_DIR/init.d/macos/zapret"
PAUSE_FLAG="/var/run/zapret.paused-by-vpn"
OVERRIDE_FLAG="/var/run/zapret.manual-override"
USEROFF_FLAG="/var/run/zapret.user-off"
LOG="/tmp/zapret-vpnwatch.log"

[ -f "$INSTALL_DIR/mac/vpn-watch.disabled" ] && exit 0
[ -x "$ZAPRET_BIN" ] || exit 0

# Пользователь выключил обход вручную (stop.sh) — НЕ трогаем ничего: ни
# паузу, ни возобновление. Обход остаётся выключенным до ручного «Включить».
[ -f "$USEROFF_FLAG" ] && exit 0

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >>"$LOG"; }

vpn_active() {
    # 1. Системные VPN-профили (IKEv2, L2TP, приложения с профилем в системе).
    if scutil --nc list 2>/dev/null | grep -q '(Connected)'; then
        return 0
    fi
    # 2. Дефолтный маршрут через туннельный интерфейс
    #    (WireGuard, OpenVPN, Outline, Amnezia и т.п.).
    local ifc
    ifc=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
    case "$ifc" in
        utun*|ipsec*|ppp*|tun*|tap*|wg*) return 0 ;;
    esac
    return 1
}

if vpn_active; then
    # Пользователь сам включил обход при активном VPN — не трогаем.
    if [ -f "$OVERRIDE_FLAG" ]; then
        exit 0
    fi
    # Идемпотентно: убиваем tpws каждый раз когда VPN активен, даже если
    # pause_flag уже стоит (защита от перезапуска tpws через launchd или GUI).
    if pgrep -x tpws >/dev/null 2>&1; then
        if [ ! -f "$PAUSE_FLAG" ]; then
            log "VPN обнаружен — ставлю zapret на паузу."
        else
            log "VPN активен, tpws ожил снова — принудительно останавливаю."
        fi
        "$ZAPRET_BIN" stop >>"$LOG" 2>&1 || true
        pkill -x tpws 2>/dev/null || true
        touch "$PAUSE_FLAG"
        log "zapret на паузе (tpws остановлен, PF-якоря сняты)."
    elif [ ! -f "$PAUSE_FLAG" ]; then
        touch "$PAUSE_FLAG"
    fi
else
    # VPN выключен — override (если был) больше не нужен: при следующем
    # включении VPN снова сработает автопауза.
    rm -f "$OVERRIDE_FLAG"
    if [ -f "$PAUSE_FLAG" ]; then
        log "VPN выключен — возобновляю zapret."
        rm -f "$PAUSE_FLAG"
        "$ZAPRET_BIN" start >>"$LOG" 2>&1 || true
        if pgrep -x tpws >/dev/null 2>&1; then
            log "zapret снова работает."
        else
            log "[!] tpws не поднялся после возобновления — проверь вручную."
        fi
    fi
fi

exit 0
