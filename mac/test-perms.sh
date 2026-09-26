#!/bin/bash
# test-perms.sh — регрессионные тесты раскладки пользовательских данных.
#
# Проверяет функцию setup_userdata() из install.sh на временном дереве:
# раскладка, переезд со старой схемы, идемпотентность, сохранность данных.
# Ничего не трогает в /opt/zapret. Запуск: ./test-perms.sh

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_DIR="$REPO_DIR"
PASS=0
FAIL=0

# Заглушки логгеров install.sh — функция их использует, а сами они не нужны.
info() { printf '  .. %s\n' "$*"; }
warn() { printf '  !! %s\n' "$*"; }

ok()   { PASS=$((PASS+1)); printf '  [ok] %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$1"; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (ожидалось '$3', получено '$2')"; fi; }

# Вытаскиваем setup_userdata() из install.sh, чтобы тест работал с реальным
# кодом, а не с его копией.
setup_fn="$(awk '/^setup_userdata\(\) \{/,/^\}/' "$SCRIPT_DIR/install.sh")"
[ -n "$setup_fn" ] || { echo "Не нашёл setup_userdata() в install.sh"; exit 1; }

# Готовит фикстуру: $1 — корень установки, $2 — режим (0 — с нуля, 1 — на месте).
# Внутри SCRIPT_DIR переопределяется на фикстуру — setup_userdata() копирует
# списки оттуда, как это делает install.sh из папки репозитория.
fixture() {
    ROOT="$1"
    IN_PLACE="$2"
    rm -rf "$ROOT"
    mkdir -p "$ROOT"
    printf 'user.example\n' >"$ROOT/zapret-hosts.txt"          # «исходник» в репозитории
    SCRIPT_DIR="$ROOT"
    INSTALL_DIR="$ROOT/install"
    IPSET_DIR="$INSTALL_DIR/ipset"
    MAC_DIR="$INSTALL_DIR/mac"
    USERDATA_DIR="$INSTALL_DIR/userdata"
    HOSTS_USER="$USERDATA_DIR/zapret-hosts-user.txt"
    HOSTS_MASTER="$USERDATA_DIR/zapret-hosts.txt"
    GUI_USER="$(id -un)"
    mkdir -p "$IPSET_DIR" "$MAC_DIR"
    # Заглушки root-исполняемого кода — check-perms.sh проверяет, что он защищён.
    for f in "$IPSET_DIR/def.sh" "$IPSET_DIR/antifilter.helper" "$IPSET_DIR/create_ipset.sh" \
             "$MAC_DIR/start.sh"; do
        printf '#!/bin/sh\n' >"$f"; chmod 755 "$f"
    done
    # Отдельная фикстура sudoers, чтобы тест не зависел от состояния машины.
    printf 'x ALL=(root) NOPASSWD: /bin/true\n' >"$ROOT/sudoers"; chmod 440 "$ROOT/sudoers"
    eval "$setup_fn"
}

# Прогоняет check-perms.sh против фикстуры.
permcheck() {
    ZAPRET_INSTALL_DIR="$1/install" ZAPRET_SUDOERS="$1/sudoers" \
        bash "$REPO_DIR/check-perms.sh" 2>/dev/null
}

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

echo "== 1. Свежая установка: списки в userdata, симлинки на месте =="
fixture "$T/fresh" 0
setup_userdata
check "userdata/zapret-hosts-user.txt создан" "$([ -f "$HOSTS_USER" ] && echo y)" "y"
check "userdata/zapret-hosts.txt создан"     "$([ -f "$HOSTS_MASTER" ] && echo y)" "y"
check "ipset/zapret-hosts-user.txt — симлинк" "$([ -L "$IPSET_DIR/zapret-hosts-user.txt" ] && echo y)" "y"
check "ipset/zapret-hosts.txt — симлинк"      "$([ -L "$IPSET_DIR/zapret-hosts.txt" ] && echo y)" "y"
check "mac/zapret-hosts.txt — симлинк"        "$([ -L "$MAC_DIR/zapret-hosts.txt" ] && echo y)" "y"
check "симлинк ipset/user ведёт в userdata" \
    "$(cd "$IPSET_DIR" && readlink zapret-hosts-user.txt)" "$HOSTS_USER"
check "симлинк разрешается в реальный файл" "$([ -f "$IPSET_DIR/zapret-hosts-user.txt" ] && echo y)" "y"
check "содержимое списка на месте" "$(cat "$IPSET_DIR/zapret-hosts-user.txt")" "user.example"

echo
echo "== 2. Переезд со старой схемы: файл из ipset/ сохраняется =="
fixture "$T/legacy" 1
printf 'my.legacy.site\n' >"$T/legacy/install/ipset/zapret-hosts-user.txt"
setup_userdata
check "прежнее содержимое сохранено" "$(cat "$HOSTS_USER")" "my.legacy.site"
check "старый файл заменён симлинком" "$([ -L "$IPSET_DIR/zapret-hosts-user.txt" ] && echo y)" "y"

echo
echo "== 3. Переезд не затирает уже существующие данные =="
fixture "$T/both" 0
printf 'my.legacy.site\n' >"$T/both/install/ipset/zapret-hosts-user.txt"
mkdir -p "$T/both/install/userdata"
printf 'already.mine\n' >"$T/both/install/userdata/zapret-hosts-user.txt"
setup_userdata
check "данные userdata приоритетнее" "$(cat "$HOSTS_USER")" "already.mine"

echo
echo "== 4. Обновление на месте не трогает данные пользователя =="
fixture "$T/inplace" 1
mkdir -p "$T/inplace/install/userdata"
printf 'my.own.domains\n' >"$T/inplace/install/userdata/zapret-hosts-user.txt"
setup_userdata
check "личный список сохранён" "$(cat "$HOSTS_USER")" "my.own.domains"
check "мастер-список создан из исходника" "$([ -f "$HOSTS_MASTER" ] && echo y)" "y"

echo
echo "== 5. Идемпотентность: повторный запуск не ломает =="
fixture "$T/twice" 0
setup_userdata
printf 'edited.by.user\n' >"$HOSTS_USER"
setup_userdata
check "данные пережили второй запуск" "$(cat "$HOSTS_USER")" "edited.by.user"
check "симлинки на месте" "$([ -L "$IPSET_DIR/zapret-hosts-user.txt" ] && echo y)" "y"
check "check-perms.sh доволен результатом" "$(permcheck "$T/twice" >/dev/null && echo y)" "y"

echo
echo "== 6. Безопасность: root-код в ipset/ остаётся закрытым =="
fixture "$T/sec" 0
setup_userdata
group_or_other_write() { [ $(( 8#$(stat -f '%Lp' "$1") & 0022 )) -ne 0 ] && echo y || echo n; }
check "ipset/ не получила group/other-записи" "$(group_or_other_write "$IPSET_DIR")" "n"
check "mac/ не получила group/other-записи"   "$(group_or_other_write "$MAC_DIR")" "n"
check "check-perms.sh доволен" "$(permcheck "$T/sec" >/dev/null && echo y)" "y"
check "check-perms.sh ловит group-запись на ipset/" \
    "$(chmod 775 "$T/sec/install/ipset"; permcheck "$T/sec" | grep -c 'есть group-запись')" "1"

echo
echo "== 7. Переустановка не съедает списки пользователя =="
fixture "$T/reinstall" 0
setup_userdata
printf 'my.precious.domains\n' >"$HOSTS_USER"
printf 'master.list\n' >"$HOSTS_MASTER"
# Ровно то, что делает install.sh перед rm -rf: откладывает списки в сторону.
stash="$(mktemp -d)"
cp "$HOSTS_USER" "$HOSTS_MASTER" "$stash/"
fixture "$T/reinstall" 0          # пересоздали дерево — списков в нём уже нет
USERDATA_STASH="$stash"
setup_userdata
check "личный список пережил переустановку" "$(cat "$HOSTS_USER")" "my.precious.domains"
check "мастер-список пережил переустановку" "$(cat "$HOSTS_MASTER")" "master.list"
check "отложенная копия удалена" "$([ -d "$stash" ] && echo n || echo y)" "y"

echo
echo "== 8. Синтаксис =="
for f in install.sh update.sh check-perms.sh; do
    if bash -n "$REPO_DIR/$f" 2>/dev/null; then ok "bash -n $f"; else bad "bash -n $f"; fi
done
if command -v swiftc >/dev/null; then
    if swiftc -swift-version 5 -typecheck "$REPO_DIR/app/main.swift" 2>/dev/null; then
        ok "swiftc -typecheck app/main.swift"
    else
        bad "swiftc -typecheck app/main.swift"
    fi
else
    echo "  [skip] swiftc не найден"
fi

echo
echo "Итог: $PASS прошло, $FAIL провалено."
[ "$FAIL" -eq 0 ]
