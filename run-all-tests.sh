#!/bin/bash
# InfiniteCanvasApp 全機能・連動テストランナー
#
# UIテストはクラス単位で個別の xcodebuild 実行に分ける。理由:
# iOS シミュレータ + XCUITest の入力アーティファクトで、キャンバスのテキスト
# オブジェクトを typeText 編集したテストの直後に別テストが「新規ノート作成ダイアログ」を
# 開くと、そのダイアログの「作成」ボタンが自動 activate されて入力前に閉じてしまう
# (GraphView/NoteLink が FontSize の直後だけ落ちる)。1クラス=1実行に分ければ
# クラス間の汚染が起きず、全クラスが安定して合格する。
# （詳細はメモリ uitest-typetext-create-dialog-flake 参照）
#
# また、本スクリプトは機能ごとのつながりや連動性を考慮し、
# 「基本ロジック → 基本UI操作 → 応用・連動機能」の順にテストを組み立てています。

set -u
cd "$(dirname "$0")"

DEVDIR=/Applications/Xcode.app/Contents/Developer
PROJECT=InfiniteCanvasApp/InfiniteCanvasApp.xcodeproj
SCHEME=InfiniteCanvasApp
APP_ID=com.muu0726.InfiniteCanvasApp

echo "=== 1. テスト環境・シミュレータの確認 ==="

# デバイス名の第1候補
PREFERRED_DEVICE="iPad Pro 13-inch (M5)"

# 指定デバイスのUDIDを取得
UDID=$(DEVELOPER_DIR=$DEVDIR xcrun simctl list devices available \
  | grep "$PREFERRED_DEVICE" | grep -oE '[0-9A-F-]{36}' | head -1)

# 見つからない場合は利用可能な他のiPadシミュレータを検索してフォールバック
if [ -z "$UDID" ]; then
  echo "WARNING: '$PREFERRED_DEVICE' のシミュレータが見つかりません。代替のiPadを探しています..."
  UDID=$(DEVELOPER_DIR=$DEVDIR xcrun simctl list devices available \
    | grep "iPad" | grep -oE '[0-9A-F-]{36}' | head -1)
  
  if [ -z "$UDID" ]; then
    echo "ERROR: 利用可能な iPad シミュレータが見つかりませんでした。"
    exit 1
  fi
  # デバイス名を取得
  DEVICE_NAME=$(DEVELOPER_DIR=$DEVDIR xcrun simctl list devices available \
    | grep "$UDID" | awk -F'(' '{print $1}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  echo "Found alternative simulator: $DEVICE_NAME (UDID: $UDID)"
else
  DEVICE_NAME="$PREFERRED_DEVICE"
  echo "Selected simulator: $DEVICE_NAME (UDID: $UDID)"
fi

# xcodebuild用デスティネーション
DEST="platform=iOS Simulator,id=$UDID"

# -------------------------------------------------------------
# テストターゲット定義（機能の依存・連動関係順）
# -------------------------------------------------------------

# 1. ユニットテスト (コアロジック)
GROUP_1_DESC="[Group 1: ユニットテスト] コアロジック (インメモリのセッション管理、差分検知、レイアウト計算、図形認識等)"
GROUP_1_TARGETS=(
  "InfiniteCanvasAppTests"
)

# 2. 基本操作 UI テスト (サイドバー、背景、入力基本)
GROUP_2_DESC="[Group 2: 基本 UI テスト] 基本操作 (フォルダ内ノート作成、背景罫線・テンプレート表示、Apple Pencil入力制限)"
GROUP_2_TARGETS=(
  "InfiniteCanvasAppUITests/SidebarCreateInFolderUITests"
  "InfiniteCanvasAppUITests/BackgroundLinesUITests"
  "InfiniteCanvasAppUITests/PencilOnlyUITests"
)

# 3. キャンバスオブジェクト操作 UI テスト (オブジェクト編集・レイアウト)
GROUP_3_DESC="[Group 3: オブジェクト UI テスト] オブジェクト操作 (挿入/選択/リサイズ/削除、フォントサイズ変更と再起動復元、ドラッグ移動、図形自動整形、Todo)"
GROUP_3_TARGETS=(
  "InfiniteCanvasAppUITests/ObjectInteractionUITests"
  "InfiniteCanvasAppUITests/FontSizeUITests"
  "InfiniteCanvasAppUITests/DragDropUITests"
  "InfiniteCanvasAppUITests/ShapeAssistUITests"
  "InfiniteCanvasAppUITests/TodoUITests"
)

# 4. 通常ノート（Paged） UI テスト (疑似ページレイアウトと削除連動)
GROUP_4_DESC="[Group 4: 通常ノート UI テスト] ページ制レイアウト (A4縦並び表示、ページ追加・削除とオブジェクトの一括削除連動、描画境界制御)"
GROUP_4_TARGETS=(
  "InfiniteCanvasAppUITests/PagedNoteUITests"
  "InfiniteCanvasAppUITests/PagedLayoutUITests"
  "InfiniteCanvasAppUITests/PagedDrawingBoundsUITests"
)

# 5. 履歴管理とアンドゥ UI テスト
GROUP_5_DESC="[Group 5: 履歴操作 UI テスト] Undo/Redo 連動 (オブジェクト挿入/移動/削除/ページ操作のUndo/Redoの一体型スタック検証)"
GROUP_5_TARGETS=(
  "InfiniteCanvasAppUITests/ObjectUndoUITests"
)

# 6. ノートリンクとグラフビュー UI テスト (ノート間の連動)
GROUP_6_DESC="[Group 6: ノートリンク/グラフ UI テスト] ノート間連動 (ショートカットカード挿入、ダブルタップ遷移、フォルダ/ノート移動追従、関係図表示)"
GROUP_6_TARGETS=(
  "InfiniteCanvasAppUITests/NoteLinkUITests"
  "InfiniteCanvasAppUITests/NoteLinkOpenButtonUITests"
  "InfiniteCanvasAppUITests/NoteLinkSourceMoveUITests"
  "InfiniteCanvasAppUITests/NoteLinkFolderMoveUITests"
  "InfiniteCanvasAppUITests/GraphViewUITests"
)

# 7. 画面分割（Split View） UI テスト (複数ノートの同時閲覧・操作連動)
GROUP_7_DESC="[Group 7: 分割画面 UI テスト] 複数ノート同時操作 (2画面スプリット表示、アクティブ面切替、スクロール・ズーム同期、復元)"
GROUP_7_TARGETS=(
  "InfiniteCanvasAppUITests/SplitViewUITests"
  "InfiniteCanvasAppUITests/ScrollSyncUITests"
)

# 全グループをまとめる
GROUPS_DESC=(
  "$GROUP_1_DESC"
  "$GROUP_2_DESC"
  "$GROUP_3_DESC"
  "$GROUP_4_DESC"
  "$GROUP_5_DESC"
  "$GROUP_6_DESC"
  "$GROUP_7_DESC"
)

# -------------------------------------------------------------
# ビルドプロセス
# -------------------------------------------------------------

echo "=== 2. テスト用ビルドの実行 ==="
echo "Building targets for destination: $DEST"

DEVELOPER_DIR=$DEVDIR xcodebuild build-for-testing \
  -project "$PROJECT" -scheme "$SCHEME" -destination "$DEST" \
  -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
  >/dev/null 2>&1

if [ $? -ne 0 ]; then
  echo "BUILD FAILED: ビルドに失敗しました。"
  exit 1
fi
echo "Build succeeded. テスト実行を開始します。"

# -------------------------------------------------------------
# テスト実行プロセス
# -------------------------------------------------------------

PASS=(); FAIL=()
LOGDIR=$(mktemp -d)

# 各グループ順に実行
for GI in {0..6}; do
  DESC="${GROUPS_DESC[$GI]}"
  echo
  echo "=============================================================="
  echo "$DESC"
  echo "=============================================================="
  
  # グループごとにターゲットリストを展開
  case $GI in
    0) TARGETS=("${GROUP_1_TARGETS[@]}") ;;
    1) TARGETS=("${GROUP_2_TARGETS[@]}") ;;
    2) TARGETS=("${GROUP_3_TARGETS[@]}") ;;
    3) TARGETS=("${GROUP_4_TARGETS[@]}") ;;
    4) TARGETS=("${GROUP_5_TARGETS[@]}") ;;
    5) TARGETS=("${GROUP_6_TARGETS[@]}") ;;
    6) TARGETS=("${GROUP_7_TARGETS[@]}") ;;
  esac

  for T in "${TARGETS[@]}"; do
    echo "--> Running: $T"
    
    # UIテストのフリーズや前テストの状態汚染を防ぐため、毎回アプリをアンインストールして状態をクリーンにする
    DEVELOPER_DIR=$DEVDIR xcrun simctl uninstall "$UDID" "$APP_ID" >/dev/null 2>&1
    
    LOG="$LOGDIR/$(echo "$T" | tr '/' '_').log"
    
    # 個別テストの実行
    DEVELOPER_DIR=$DEVDIR xcodebuild test-without-building \
        -project "$PROJECT" -scheme "$SCHEME" -destination "$DEST" \
        -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
        -only-testing:"$T" >"$LOG" 2>&1
        
    if [ $? -eq 0 ]; then
      echo "  [PASS] $T"
      PASS+=("$T")
    else
      echo "  [FAIL] $T"
      echo "    Log saved to: $LOG"
      # エラーが起きた場合は、ログの最後の数行を表示して原因特定をサポート
      echo "    --- LOG TAIL ---"
      tail -n 10 "$LOG" | sed 's/^/      /'
      echo "    ----------------"
      FAIL+=("$T")
    fi
  done
done

# -------------------------------------------------------------
# 結果サマリー表示
# -------------------------------------------------------------

echo
echo "=============================================================="
echo "                         TEST SUMMARY                         "
echo "=============================================================="
echo "PASS: ${#PASS[@]} / $((${#PASS[@]}+${#FAIL[@]}))"
echo "--------------------------------------------------------------"

if [ ${#FAIL[@]} -eq 0 ]; then
  echo "RESULT: ALL GREEN (すべてのテストに合格しました)"
  exit 0
else
  echo "RESULT: SOME TESTS FAILED"
  for f in "${FAIL[@]}"; do
    echo "  FAILED: $f"
  done
  exit 1
fi

