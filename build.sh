#!/bin/bash
#
# システムモニタ.app をビルドする。
#
#   ./build.sh              ユニバーサル (arm64 + x86_64) でビルド
#   ./build.sh --native     実行中のマシンのアーキテクチャだけでビルド (速い)
#   ./build.sh --install    ビルド後 /Applications にインストールして起動
#   ./build.sh --run        ビルド後 build/ から直接起動
#
set -euo pipefail
cd "$(dirname "$0")"

CONFIGURATION="release"
PRODUCT="MenuMetrics"
BUNDLE_ID="dev.local.MenuMetrics"
DISPLAY_NAME="システムモニタ"
VERSION="1.0.1"
MIN_MACOS="14.0"

BUILD_DIR="build"
APP="$BUILD_DIR/$PRODUCT.app"
UNIVERSAL=1
INSTALL=0
RUN=0

for argument in "$@"; do
  case "$argument" in
    --native)  UNIVERSAL=0 ;;
    --install) INSTALL=1 ;;
    --run)     RUN=1 ;;
    -h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "不明なオプション: $argument" >&2; exit 1 ;;
  esac
done

# 起動中の古いプロセスがあると .app を差し替えても反映されない
pkill -x "$PRODUCT" 2>/dev/null || true

echo "==> ネイティブ ($(uname -m)) をビルド"
swift build -c "$CONFIGURATION"
NATIVE_BINARY="$(swift build -c "$CONFIGURATION" --show-bin-path)/$PRODUCT"

BINARIES=("$NATIVE_BINARY")
if [ "$UNIVERSAL" = 1 ]; then
  if [ "$(uname -m)" = "arm64" ]; then
    OTHER_ARCH="x86_64"
  else
    OTHER_ARCH="arm64"
  fi
  echo "==> $OTHER_ARCH をビルド"
  if swift build -c "$CONFIGURATION" \
       --triple "$OTHER_ARCH-apple-macosx$MIN_MACOS" \
       --scratch-path ".build-$OTHER_ARCH" >/dev/null 2>&1; then
    BINARIES+=(".build-$OTHER_ARCH/$OTHER_ARCH-apple-macosx/$CONFIGURATION/$PRODUCT")
  else
    echo "    $OTHER_ARCH のビルドに失敗したのでネイティブのみで続行します" >&2
  fi
fi

echo "==> .app を組み立て"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

if [ "${#BINARIES[@]}" -gt 1 ]; then
  lipo -create "${BINARIES[@]}" -output "$APP/Contents/MacOS/$PRODUCT"
else
  cp "$NATIVE_BINARY" "$APP/Contents/MacOS/$PRODUCT"
fi
chmod +x "$APP/Contents/MacOS/$PRODUCT"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$PRODUCT</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleName</key><string>$PRODUCT</string>
    <key>CFBundleDisplayName</key><string>$DISPLAY_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
    <!-- Dock にも Cmd+Tab にも出さず、メニューバーだけに常駐する -->
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>ローカルビルド</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> アイコンを生成"
mkdir -p "$BUILD_DIR/tools"
swiftc -O Tools/make-icon.swift -o "$BUILD_DIR/tools/make-icon" 2>/dev/null
"$BUILD_DIR/tools/make-icon" "$APP/Contents/Resources/AppIcon.icns"

# Apple Silicon では署名の無いバイナリは起動できない。配布用の証明書は無いので ad-hoc 署名にする
echo "==> ad-hoc 署名"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1

echo "==> 完成: $APP  ($(lipo -archs "$APP/Contents/MacOS/$PRODUCT"))"

if [ "$INSTALL" = 1 ]; then
  echo "==> /Applications にインストール"
  rm -rf "/Applications/$PRODUCT.app"
  cp -R "$APP" "/Applications/$PRODUCT.app"
  open "/Applications/$PRODUCT.app"
elif [ "$RUN" = 1 ]; then
  open "$APP"
fi
