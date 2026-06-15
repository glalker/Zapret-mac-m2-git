#!/bin/bash
#
# build-app.sh — собирает нативное Zapret.app из app/main.swift (Swift + AppKit).
# Запускать БЕЗ sudo. После выполнения появится Zapret.app рядом с этим скриптом.
#
# Результат — настоящее приложение: окно с кнопками-светофором + иконка в
# меню-баре (трей). Старый ZapretControl.applescript больше не используется.
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

[ -f "app/main.swift" ] || die "Не нашёл app/main.swift в $SCRIPT_DIR"
command -v swiftc >/dev/null || die "swiftc не найден. Поставь Command Line Tools: xcode-select --install"

APP="Zapret.app"
BIN_NAME="Zapret"

info "Удаляю старую сборку, если есть..."
rm -rf "$APP"

info "Компилирую Swift (universal arm64 + x86_64)..."
# Универсальный бинарник, чтобы работал и на Apple Silicon, и на Intel.
swiftc -O -parse-as-library -swift-version 5 \
    -target arm64-apple-macos13 \
    app/main.swift -o "/tmp/zapret-arm64" \
    -framework SwiftUI -framework AppKit 2>/tmp/zapret-build.log || {
        cat /tmp/zapret-build.log; die "Ошибка компиляции (arm64)."
    }

# x86_64 собираем, только если доступен (на Intel-маках или с нужными SDK).
ARCHS_OK="/tmp/zapret-arm64"
if swiftc -O -parse-as-library -swift-version 5 \
    -target x86_64-apple-macos13 \
    app/main.swift -o "/tmp/zapret-x86_64" \
    -framework SwiftUI -framework AppKit 2>>/tmp/zapret-build.log; then
    info "Собираю universal binary (arm64 + x86_64)..."
    lipo -create /tmp/zapret-arm64 /tmp/zapret-x86_64 -output /tmp/zapret-universal 2>/dev/null \
        && ARCHS_OK="/tmp/zapret-universal"
else
    info "x86_64 SDK недоступен — собираю только под arm64 (Apple Silicon)."
fi

info "Собираю бандл $APP..."
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ARCHS_OK" "$APP/Contents/MacOS/$BIN_NAME"
chmod +x "$APP/Contents/MacOS/$BIN_NAME"
rm -f /tmp/zapret-arm64 /tmp/zapret-x86_64 /tmp/zapret-universal

cat >"$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>$BIN_NAME</string>
    <key>CFBundleIdentifier</key><string>su.glalker.zapret</string>
    <key>CFBundleName</key><string>Zapret</string>
    <key>CFBundleDisplayName</key><string>Zapret</string>
    <key>CFBundleShortVersionString</key><string>2.0.1</string>
    <key>CFBundleVersion</key><string>2.0.1</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict></plist>
PLIST

cp "$SCRIPT_DIR/update-app.sh" "$APP/Contents/Resources/update-app.sh" 2>/dev/null && chmod +x "$APP/Contents/Resources/update-app.sh"
echo "APPL????" >"$APP/Contents/PkgInfo"

# Ad-hoc подпись — иначе macOS может ругаться на неподписанное приложение.
info "Подписываю (ad-hoc)..."
codesign --force --deep -s - "$APP" 2>/dev/null || true
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

info "Готово!"
echo
echo "  Папка:  $SCRIPT_DIR/$APP"
echo
echo "  Что дальше:"
echo "    1. Двойной клик по Zapret.app (или открой из /Applications после установки)"
echo "    2. В окне нажми «Переустановить» и введи пароль — один раз"
echo "    3. Дальше всё управление — кнопкой питания и меню-баром, без пароля"
