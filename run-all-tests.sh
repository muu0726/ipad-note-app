#!/bin/bash
# InfiniteCanvasApp 全テストランナー。
#
# UIテストはクラス単位で個別の xcodebuild 実行に分ける。理由:
# iOS 26.5 シミュレータ + XCUITest の入力アーティファクトで、キャンバスのテキスト
# オブジェクトを typeText 編集したテストの直後に別テストが「新規ノート作成ダイアログ」を
# 開くと、そのダイアログの「作成」ボタンが自動 activate されて入力前に閉じてしまう
# (GraphView/NoteLink が FontSize の直後だけ落ちる)。1クラス=1実行に分ければ
# クラス間の汚染が起きず、全クラスが安定して合格する。
# （詳細はメモリ uitest-typetext-create-dialog-flake 参照）

set -u
cd "$(dirname "$0")"

DEVDIR=/Applications/Xcode.app/Contents/Developer
PROJECT=InfiniteCanvasApp/InfiniteCanvasApp.xcodeproj
SCHEME=InfiniteCanvasApp
DEST='platform=iOS Simulator,name=iPad Pro 13-inch (M5)'
APP_ID=com.muu0726.InfiniteCanvasApp

# ベース機の udid（simctl list devices で確認）
UDID=$(DEVELOPER_DIR=$DEVDIR xcrun simctl list devices available \
  | grep 'iPad Pro 13-inch (M5)' | grep -oE '[0-9A-F-]{36}' | head -1)

# 個別実行するテスト対象（ユニットは1バンドル、UIはクラス単位）
TARGETS=(
  "InfiniteCanvasAppTests"
  "InfiniteCanvasAppUITests/DragDropUITests"
  "InfiniteCanvasAppUITests/FontSizeUITests"
  "InfiniteCanvasAppUITests/GraphViewUITests"
  "InfiniteCanvasAppUITests/NoteLinkUITests"
  "InfiniteCanvasAppUITests/ObjectInteractionUITests"
  "InfiniteCanvasAppUITests/ObjectUndoUITests"
  "InfiniteCanvasAppUITests/PagedLayoutUITests"
  "InfiniteCanvasAppUITests/PagedNoteUITests"
  "InfiniteCanvasAppUITests/ScrollSyncUITests"
  "InfiniteCanvasAppUITests/ShapeAssistUITests"
  "InfiniteCanvasAppUITests/SplitViewUITests"
  "InfiniteCanvasAppUITests/TodoUITests"
)

# 事前に一度ビルドしておく（毎回のビルドを省く）
echo "== building for testing =="
DEVELOPER_DIR=$DEVDIR xcodebuild build-for-testing \
  -project "$PROJECT" -scheme "$SCHEME" -destination "$DEST" \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  >/dev/null 2>&1 || { echo "BUILD FAILED"; exit 1; }

PASS=(); FAIL=()
LOGDIR=$(mktemp -d)
for T in "${TARGETS[@]}"; do
  echo "== $T =="
  # 各実行前に Core Data / 入力状態をまっさらにする（蓄積・汚染防止）
  DEVELOPER_DIR=$DEVDIR xcrun simctl uninstall "$UDID" "$APP_ID" >/dev/null 2>&1
  LOG="$LOGDIR/$(echo "$T" | tr '/' '_').log"
  DEVELOPER_DIR=$DEVDIR xcodebuild test-without-building \
      -project "$PROJECT" -scheme "$SCHEME" -destination "$DEST" \
      -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
      -only-testing:"$T" >"$LOG" 2>&1
  # xcodebuild の終了コードで判定（成功=0）
  if [ $? -eq 0 ]; then
    echo "  PASS: $T"; PASS+=("$T")
  else
    echo "  FAIL: $T  (log: $LOG)"; FAIL+=("$T")
  fi
done

echo
echo "================ SUMMARY ================"
echo "PASS: ${#PASS[@]} / $((${#PASS[@]}+${#FAIL[@]}))"
if [ ${#FAIL[@]} -eq 0 ]; then
  echo "ALL GREEN"; exit 0
else
  for f in "${FAIL[@]}"; do echo "  FAILED: $f"; done
  exit 1
fi
