#!/bin/bash
#
# build-app.sh — собирает Zapret.app из ZapretControl.applescript.
# Запускать БЕЗ sudo. После выполнения появится Zapret.app рядом с этим скриптом,
# который можно двойным кликом запускать как обычное приложение.
#
# Запуск:
#   ./build-app.sh

set -e

GRN='\033[0;32m'
RED='\033[0;31m'
CLR='\033[0m'

info() { printf "${GRN}[+] %s${CLR}\n" "$*"; }
die()  { printf "${RED}[x] %s${CLR}\n" "$*" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || die "Только для macOS."

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

[ -f "ZapretControl.applescript" ] || die "Не нашёл ZapretControl.applescript в $SCRIPT_DIR"

command -v osacompile >/dev/null || die "osacompile не найден (должен быть в любой macOS)."

info "Удаляю старую сборку, если есть..."
rm -rf "Zapret.app"

info "Собираю Zapret.app через osacompile..."
osacompile -o "Zapret.app" "ZapretControl.applescript"

# Снимаем карантин (на всякий случай — обычно для локально собранных не нужно)
xattr -dr com.apple.quarantine "Zapret.app" 2>/dev/null || true

info "Готово!"
echo
echo "  Папка:  $SCRIPT_DIR/Zapret.app"
echo
echo "  Что дальше:"
echo "    1. Двойной клик по Zapret.app"
echo "    2. В появившемся окне нажми «🔄 Установить / Переустановить»"
echo "    3. Введи пароль администратора"
echo "    4. После установки используй ▶ Запустить / ⏹ Остановить когда нужно"
echo
echo "  После первой установки Zapret.app можно переместить куда угодно"
echo "  (например, в /Applications) — он будет искать скрипты в /opt/zapret/mac/."
echo "  До первой установки .app должен оставаться здесь, в папке mac/."
