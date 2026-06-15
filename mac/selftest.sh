#!/bin/bash
# selftest.sh — автоподбор стратегии обхода DPI.
#
# Для каждого пресета из strategy.sh:
#   1. применяет стратегию (перезапуская tpws),
#   2. курлит набор заблокированных в РФ сайтов через систему (tpws их
#      прозрачно перехватывает по PF),
#   3. считает сколько открылось и среднее время.
# В конце выбирает стратегию с наибольшим числом успехов (при равенстве —
# самую быструю) и применяет её.
#
# Запускается из GUI через `sudo -n` (правило sudoers). Требует root.

if [ "$EUID" -ne 0 ]; then
    exec sudo -E "$0" "$@"
fi

INSTALL_DIR="/opt/zapret"
MAC="$INSTALL_DIR/mac"
STRATEGIES="default split-only midsld oob hostcase"

# Сайты для проверки — известные жертвы DPI в РФ. Все они есть в списке
# itdoginfo (его кладёт update.sh), поэтому tpws на них реально влияет.
TEST_DOMAINS="www.youtube.com youtube.com www.instagram.com x.com discord.com rutracker.org"

[ -x "$MAC/strategy.sh" ] || { echo "[x] zapret не установлен."; exit 1; }

# Предупреждаем про VPN — он исказит результаты (весь трафик идёт мимо tpws).
if scutil --nc list 2>/dev/null | grep -q '(Connected)'; then
    echo "[!] ВНИМАНИЕ: активен VPN — результаты теста будут недостоверны."
    echo "    Для честного теста выключи VPN и запусти подбор заново."
    echo
fi

# Проверка одного домена. Успех = получили валидный HTTP-ответ (>=200, <500).
# Сброс соединения/таймаут от DPI → curl вернёт 000 → провал.
test_domain() {
    local dom="$1"
    local res code time
    res=$(curl -s -o /dev/null -m 8 -w "%{http_code} %{time_total}" \
          --retry 0 "https://$dom/" 2>/dev/null)
    code="${res%% *}"
    time="${res##* }"
    if [ -n "$code" ] && [ "$code" -ge 200 ] 2>/dev/null && [ "$code" -lt 500 ]; then
        printf "    %-22s ✅ %s  %ss\n" "$dom" "$code" "$time"
        echo "$time" >>"$TMP_TIMES"
        return 0
    else
        printf "    %-22s ❌ нет ответа\n" "$dom"
        return 1
    fi
}

BEST_NAME=""
BEST_OK=-1
BEST_TIME=99999

for strat in $STRATEGIES; do
    echo "[*] Проверяю стратегию: $strat"
    # Применяем стратегию тихо (вывод перезапуска нам не нужен).
    "$MAC/strategy.sh" set "$strat" >/dev/null 2>&1
    sleep 2

    if ! pgrep -x tpws >/dev/null 2>&1; then
        echo "    (tpws не поднялся — пропускаю; возможно мешает VPN/фаервол)"
        echo
        continue
    fi

    TMP_TIMES=$(mktemp)
    ok=0; total=0
    for dom in $TEST_DOMAINS; do
        total=$((total + 1))
        test_domain "$dom" && ok=$((ok + 1))
    done

    # Среднее время по успешным.
    avg="—"
    if [ -s "$TMP_TIMES" ]; then
        avg=$(awk '{s+=$1; n++} END{if(n>0) printf "%.2f", s/n; else print "0"}' "$TMP_TIMES")
    fi
    rm -f "$TMP_TIMES"

    echo "[=] $strat: $ok/$total открылось, среднее ${avg}s"
    echo

    # Выбор лучшей: больше успехов, при равенстве — меньше время.
    better=0
    if [ "$ok" -gt "$BEST_OK" ]; then
        better=1
    elif [ "$ok" -eq "$BEST_OK" ] && [ "$avg" != "—" ]; then
        if awk "BEGIN{exit !($avg < $BEST_TIME)}"; then better=1; fi
    fi
    if [ "$better" = "1" ]; then
        BEST_NAME="$strat"; BEST_OK="$ok"
        [ "$avg" != "—" ] && BEST_TIME="$avg"
    fi
done

echo "=================================="
if [ -n "$BEST_NAME" ] && [ "$BEST_OK" -gt 0 ]; then
    echo "[★] Лучшая стратегия: $BEST_NAME ($BEST_OK успехов). Применяю."
    "$MAC/strategy.sh" set "$BEST_NAME" >/dev/null 2>&1
    echo "[+] Готово. Активна стратегия: $BEST_NAME"
else
    echo "[x] Ни одна стратегия не открыла сайты."
    echo "    Возможные причины: выключи VPN; обнови списки сайтов;"
    echo "    либо провайдер режет жёстко — попробуй /opt/zapret/blockcheck.sh."
fi
