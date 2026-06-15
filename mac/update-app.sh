#!/bin/bash
# update-app.sh — самообновление приложения из релизов GitHub.
#
# Скачивает архив указанного (или последнего) релиза glalker/Zapret-mac-m2-git,
# распаковывает и запускает его install.sh — тот обновит /opt/zapret, скрипты,
# правило sudoers и сам Zapret.app в /Applications.
#
# Запускается из GUI через osascript с правами администратора (нужен пароль —
# обновление трогает /opt, /Library и /etc, это законно требует root).
#
#   update-app.sh [vX.Y.Z]   — конкретный тег; без аргумента берётся latest.

set -e

REPO="glalker/Zapret-mac-m2-git"
TAG="${1:-}"

GRN='\033[0;32m'; RED='\033[0;31m'; CLR='\033[0m'
info() { printf "${GRN}[+] %s${CLR}\n" "$*"; }
die()  { printf "${RED}[x] %s${CLR}\n" "$*" >&2; exit 1; }

if [ -z "$TAG" ]; then
    info "Узнаю последнюю версию на GitHub…"
    TAG=$(curl -fsSL -m 20 "https://api.github.com/repos/$REPO/releases/latest" \
          | sed -nE 's/.*"tag_name" *: *"([^"]+)".*/\1/p' | head -1)
fi
[ -n "$TAG" ] || die "Не удалось определить версию для обновления."

info "Скачиваю релиз $TAG …"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
URL="https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz"
curl -fsSL -m 120 "$URL" -o "$TMP/src.tar.gz" || die "Не удалось скачать $URL"
tar xzf "$TMP/src.tar.gz" -C "$TMP" || die "Архив повреждён."

DIR=$(find "$TMP" -maxdepth 1 -type d -name 'Zapret-mac-m2-git-*' | head -1)
[ -d "$DIR/mac" ] || die "В архиве нет папки mac/."
cd "$DIR/mac"

# Если есть swiftc — пересобираем приложение из исходников (свежее).
# Иначе используем уже собранный Zapret.app, лежащий в архиве.
if command -v swiftc >/dev/null 2>&1 && [ -f app/main.swift ]; then
    info "Пересобираю Zapret.app из исходников…"
    ./build-app.sh >/dev/null 2>&1 || info "Сборка не удалась — ставлю готовый Zapret.app из архива."
fi

[ -d "Zapret.app" ] || die "Нет Zapret.app для установки."

info "Запускаю установщик $TAG …"
bash ./install.sh

info "Обновление до $TAG завершено."
