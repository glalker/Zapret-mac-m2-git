#!/bin/bash
# check-perms.sh — read-only диагностика прав zapret.
#
# Ничего не меняет: только читает метаданные и печатает вердикт по каждой
# проверке. Можно запускать без sudo из GUI и из терминала.
#
# Вывод — построчный, формат стабильный (его парсит Zapret.app):
#   <путь>: OK - <пояснение>
#   <путь>: FAIL - <причина>
# Код возврата: 0 если все OK, 1 если есть хотя бы один FAIL.

INSTALL_DIR="${ZAPRET_INSTALL_DIR:-/opt/zapret}"
SUDOERS="${ZAPRET_SUDOERS:-/etc/sudoers.d/zapret}"
IPSET_DIR="$INSTALL_DIR/ipset"
MAC_DIR="$INSTALL_DIR/mac"
USERDATA_DIR="$INSTALL_DIR/userdata"

FAILED=0

ok()   { printf '%s: OK - %s\n' "$1" "$2"; }
bad()  { printf '%s: FAIL - %s\n' "$1" "$2"; FAILED=1; }

# Права/владелец одной строкой — для отчёта.
facts() { stat -f '%Sp %Su:%Sg' "$1" 2>/dev/null || echo "нет"; }

# Режим в восьмеричном виде, из которого считаем биты записи.
mode_of() { printf '%s' "$(stat -f '%Lp' "$1" 2>/dev/null)"; }
has_group_write() { [ $(( 8#$(mode_of "$1") & 0020 )) -ne 0 ]; }
has_other_write() { [ $(( 8#$(mode_of "$1") & 0002 )) -ne 0 ]; }

# Файлы, которые root выполняет: у них НЕ должно быть group/other-записи.
# Если такие биты появятся, любой из соответствующей группы может подменить
# код, который launchd запустит от root (zapret.plist), — это эскалация.
check_root_managed() {
    p="$1"
    if [ ! -e "$p" ]; then bad "$p" "не существует"; return; fi
    reason="$(facts "$p")"
    problem=""
    # Владельца проверяем только когда скрипт сам идёт от root: из-под обычного
    # пользователя это всё равно недостоверно, а GUI зовёт его без sudo.
    if [ "$EUID" -eq 0 ] && [ "$(stat -f '%Su' "$p")" != "root" ]; then
        problem="владелец $(stat -f '%Su' "$p"), ожидался root"
    fi
    if has_group_write "$p"; then
        problem="${problem:+$problem, }есть group-запись"
    fi
    if has_other_write "$p"; then
        problem="${problem:+$problem, }есть world-запись"
    fi
    if ls -ldO "$p" 2>/dev/null | grep -qE '(uchg|schg|restricted)'; then
        problem="${problem:+$problem, }флаг uchg/schg"
    fi
    if [ -n "$problem" ]; then
        bad "$p" "$problem ($reason)"
    else
        ok "$p" "защищён от подмены ($reason)"
    fi
}

# Пользовательские данные: должны быть доступны текущему пользователю.
# -w/-r/-x идут через access(2) и учитывают ACL, чего не делает арифметика над битами.
check_user_data() {
    p="$1"
    need_dir="$2"
    if [ -L "$p" ]; then
        ok "$p" "симлинк -> $(readlink "$p")"
        return
    fi
    if [ ! -e "$p" ]; then bad "$p" "не существует"; return; fi
    if [ "$need_dir" = "dir" ] && [ ! -d "$p" ]; then
        bad "$p" "ожидалась папка, а это $(facts "$p")"
        return
    fi
    if [ ! -w "$p" ]; then
        bad "$p" "нет права записи для текущего пользователя ($(facts "$p"))"
        return
    fi
    if [ "$need_dir" = "dir" ] && [ ! -x "$p" ]; then
        bad "$p" "нет права обхода каталога — атомарное сохранение не сработает ($(facts "$p"))"
        return
    fi
    ok "$p" "доступен для записи ($(facts "$p"))"
}

echo "== Проверка прав zapret =="
echo

# --- Пользовательские данные: то, что нужно редактировать ---
check_user_data "$USERDATA_DIR" dir
check_user_data "$USERDATA_DIR/zapret-hosts-user.txt" file
check_user_data "$USERDATA_DIR/zapret-hosts.txt" file

# --- Точки входа zapret должны вести в userdata ---
for link in "$IPSET_DIR/zapret-hosts-user.txt" "$IPSET_DIR/zapret-hosts.txt" "$MAC_DIR/zapret-hosts.txt"; do
    if [ ! -L "$link" ]; then
        bad "$link" "ожидался симлинк в $USERDATA_DIR (сейчас: $(facts "$link"))"
    elif [ ! -e "$link" ]; then
        bad "$link" "симлинк битый -> $(readlink "$link")"
    else
        ok "$link" "симлинк -> $(readlink "$link")"
    fi
done

# --- Безопасность: root-исполняемый код должен остаться неприкосновенным ---
check_root_managed "$IPSET_DIR"
check_root_managed "$IPSET_DIR/def.sh"
check_root_managed "$IPSET_DIR/antifilter.helper"
check_root_managed "$IPSET_DIR/create_ipset.sh"
check_root_managed "$MAC_DIR"
check_root_managed "$MAC_DIR/start.sh"

# --- sudoers ---
if [ ! -e "$SUDOERS" ]; then
    bad "$SUDOERS" "не существует — GUI будет спрашивать пароль"
else
    su="$(stat -f '%Su' "$SUDOERS")"
    problem=""
    if [ "$EUID" -eq 0 ] && [ "$su" != "root" ]; then
        problem="владелец $su, ожидался root"
    fi
    if has_group_write "$SUDOERS" || has_other_write "$SUDOERS"; then
        problem="${problem:+$problem, }есть group/other-запись"
    fi
    if [ -n "$problem" ]; then
        bad "$SUDOERS" "$problem ($(facts "$SUDOERS"))"
    else
        ok "$SUDOERS" "защищён ($(facts "$SUDOERS"))"
    fi
fi

echo
if [ "$FAILED" -ne 0 ]; then
    if [ "$INSTALL_DIR" = "/opt/zapret" ]; then
        echo "Итог: есть проблемы. Переустанови: sudo ./install.sh"
    else
        echo "Итог: есть проблемы."
    fi
    exit 1
fi
echo "Итог: всё в порядке."
exit 0
