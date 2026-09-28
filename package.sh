#!/bin/bash
#
# 配布用の .dmg をデスクトップに作る。
#
#   ./package.sh            ビルドし直してから .dmg を作る
#   ./package.sh --no-build 既存の build/MenuMetrics.app からだけ作る
#
set -euo pipefail
cd "$(dirname "$0")"

PRODUCT="MenuMetrics"
VERSION="1.0"
VOLUME_NAME="システムモニタ $VERSION"
DMG_NAME="MACメニューバーシステムモニタアプリver $VERSION"
OUTPUT="$HOME/Desktop/$DMG_NAME.dmg"
APP="build/$PRODUCT.app"

if [ "${1:-}" != "--no-build" ]; then
  ./build.sh
fi

[ -d "$APP" ] || { echo "$APP がありません。先に ./build.sh を実行してください" >&2; exit 1; }

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

cp -R "$APP" "$STAGING/"
# ドラッグ＆ドロップでインストールできるようにする
ln -s /Applications "$STAGING/Applications"
cp README.md "$STAGING/README.md"

cat > "$STAGING/はじめにお読みください.txt" <<'NOTICE'
システムモニタ 1.0
==================

macOS のメニューバーに CPU / メモリ / GPU の使用率と温度を表示するアプリです。
クリックすると内訳とプロセス一覧のパネルが開きます。


インストール
------------
このウインドウの中の「システムモニタ」を、右にある Applications フォルダへ
ドラッグしてください。


初回起動について（重要）
------------------------
このアプリは Apple の配布用証明書で署名していないため、そのままダブルクリック
すると「開発元を検証できないため開けません」あるいは「壊れているため開けません」
と表示されます。次のどちらかの方法で開いてください。

方法1: 右クリックで開く
  1. アプリケーションフォルダの「システムモニタ」を右クリック（control + クリック）
  2. 「開く」を選ぶ
  3. 確認ダイアログでもう一度「開く」を押す
  ※ 2 回目以降は普通にダブルクリックで起動できます。

方法2: 方法1で開けない場合（ターミナルを使う）
  ターミナル.app を開いて、次の 1 行を貼り付けて実行してください。

    xattr -dr com.apple.quarantine /Applications/MenuMetrics.app

  そのあとダブルクリックで起動できます。


使い方
------
・メニューバーの数値をクリック  … 詳細パネルを開く
・メニューバーの数値を右クリック … 表示スタイルの切り替えなどのメニュー
・パネル下部の「設定」          … 更新間隔、表示項目、ログイン時に起動

Dock には表示されません。終了はパネル右下の「終了」からです。


動作環境
--------
macOS 14 以降 / Apple Silicon・Intel 両対応（ユニバーサルバイナリ）


知っておいていただきたいこと
----------------------------
・温度センサーは macOS が公開していない API から読んでいます。管理者権限は
  不要ですが、将来の macOS で読めなくなる可能性があります。その場合は温度の
  表示だけが自動的に消えます。
・プロセス一覧には、他のユーザー（root など）が所有するプロセスは表示されません。
  権限昇格をしていないためで、アクティビティモニタとの差はここです。
・GPU の温度は CPU と同じチップ上のセンサーから推定した値です。「推定」と
  明示して表示しています。
NOTICE

echo "==> .dmg を作成"
rm -f "$OUTPUT"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$OUTPUT" >/dev/null

echo "==> 完成: $OUTPUT"
ls -lh "$OUTPUT" | awk '{printf "    サイズ: %s\n", $5}'
