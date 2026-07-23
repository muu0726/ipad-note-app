#!/bin/bash
# InfiniteCanvasApp 全機能・連動テストランナー (デバッグ・エラー調査機能＆タスク自動生成強化版)
#
# UIテストはクラス単位で個別の xcodebuild 実行に分ける。理由:
# iOS シミュレータ + XCUITest の入力アーティファクトで、キャンバスのテキスト
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
APP_ID=com.muu0726.InfiniteCanvasApp

# -------------------------------------------------------------
# コマンドラインオプション引数解析
# -------------------------------------------------------------
ONLY_TARGET=""
KEEP_APP=false
SCREENSHOT_ON_FAIL=false

show_help() {
  echo "Usage: $0 [options]"
  echo "Options:"
  echo "  --only <TargetName>     指定したテストターゲットのみを実行（部分一致可能。例: --only FontSizeUITests）"
  echo "  --keep                  テスト終了時にアプリをアンインストールせずに残す (手動での状態確認用)"
  echo "  --screenshot-on-fail    テスト失敗時に自動でシミュレータのスクリーンショットを撮影する"
  echo "  -h, --help              このヘルプを表示"
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --only)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --only にはターゲット名を指定してください。"
        exit 1
      fi
      ONLY_TARGET="$2"
      shift 2
      ;;
    --keep)
      KEEP_APP=true
      shift
      ;;
    --screenshot-on-fail)
      SCREENSHOT_ON_FAIL=true
      shift
      ;;
    -h|--help)
      show_help
      ;;
    *)
      echo "Unknown option: $1"
      show_help
      ;;
  esac
done

# -------------------------------------------------------------
# テスト結果保存用のディレクトリ準備
# -------------------------------------------------------------
RESULTS_DIR="TestResults"
SCREENSHOT_DIR="$RESULTS_DIR/Screenshots"
XCRESULT_DIR="$RESULTS_DIR/xcresults"
CRASH_DIR="$RESULTS_DIR/CrashReports"
LOG_DIR="$RESULTS_DIR/logs"

mkdir -p "$SCREENSHOT_DIR"
mkdir -p "$XCRESULT_DIR"
mkdir -p "$CRASH_DIR"
mkdir -p "$LOG_DIR"

# タスク自動生成用の一時ファイル
TASK_TEMP=$(mktemp)

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
  "InfiniteCanvasAppUITests/UnifiedSelectionUITests"
  "InfiniteCanvasAppUITests/LassoSelectionUITests"
  "InfiniteCanvasAppUITests/StickyNoteUITests"
  "InfiniteCanvasAppUITests/ConnectorUITests"
  "InfiniteCanvasAppUITests/FontSizeUITests"
  "InfiniteCanvasAppUITests/DragDropUITests"
  "InfiniteCanvasAppUITests/ShapeAssistUITests"
  "InfiniteCanvasAppUITests/TodoUITests"
)

# 4. 通常ノート（Paged） UI テスト (疑似ページレイアウトと削除連動・完全独立表示モード)
GROUP_4_DESC="[Group 4: 通常ノート UI テスト] ページ制レイアウト (A4縦並び表示、ページ追加・削除とオブジェクトの一括削除連動、描画境界制御、隣のページを隠す/完全独立表示モード)"
GROUP_4_TARGETS=(
  "InfiniteCanvasAppUITests/PagedNoteUITests"
  "InfiniteCanvasAppUITests/PagedLayoutUITests"
  "InfiniteCanvasAppUITests/PagedDrawingBoundsUITests"
  "InfiniteCanvasAppUITests/HideAdjacentPagesUITests"
  "InfiniteCanvasAppUITests/PagedScrollDirectionUITests"
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

# 8. 図形・表・カスタムペン UI テスト (追加機能)
GROUP_8_DESC="[Group 8: 図形/表/カスタムペン UI テスト] 拡張オブジェクト操作 (図形配置/編集、表セル編集/幅調整、お気に入りペン管理)"
GROUP_8_TARGETS=(
  "InfiniteCanvasAppUITests/ShapeObjectUITests"
  "InfiniteCanvasAppUITests/TableObjectUITests"
  "InfiniteCanvasAppUITests/CustomPenUITests"
)

# 9. フリーフォーム・システム UI テスト (全般ウォークスルー)
GROUP_9_DESC="[Group 9: フリーフォーム/システム UI テスト] キャンバスパン・ズーム、ストアリセット、全体ウォークスルー"
GROUP_9_TARGETS=(
  "InfiniteCanvasAppUITests/InfiniteCanvasFreeformUITests"
  "InfiniteCanvasAppUITests/ZoomToFitUITests"
  "InfiniteCanvasAppUITests/StoreResetUITests"
  "InfiniteCanvasAppUITests/AppWalkthroughUITests"
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
  "$GROUP_8_DESC"
  "$GROUP_9_DESC"
)

# -------------------------------------------------------------
# 実行対象判定ヘルパー
# -------------------------------------------------------------
should_run() {
  local target="$1"
  if [[ -z "$ONLY_TARGET" ]]; then
    return 0
  fi
  if [[ "$target" == *"$ONLY_TARGET"* ]]; then
    return 0
  fi
  return 1
}

# ログファイルから具体的な失敗テストメソッドを抽出する関数
extract_failing_tests() {
  local log_file="$1"
  # Failing tests: から次の空行または境界行までを切り出す
  sed -n '/Failing tests:/,/^\s*$/p' "$log_file" | grep -v "Failing tests:" | sed -E 's/^[[:space:]]+//'
}

# テスト失敗時のタスク詳細書き出し関数
append_fail_task() {
  local target="$1"
  local log_file="$2"
  local xcresult_path="$3"
  local start_marker="$4"
  
  local ss_info=""
  # 1. スクリーンショットの撮影 (UIテストのみ)
  if $SCREENSHOT_ON_FAIL && [[ "$target" == *"UITests"* ]]; then
    local ss_path="$SCREENSHOT_DIR/$(echo "$target" | tr '/' '_')_fail.png"
    DEVELOPER_DIR=$DEVDIR xcrun simctl screenshot "$UDID" "$ss_path" >/dev/null 2>&1
    if [ $? -eq 0 ]; then
      echo "    Screenshot captured to: $ss_path"
      ss_info="  - **スクリーンショット**: [画面キャプチャ](file://$(pwd)/$ss_path)"
    fi
  fi
  
  # 2. クラッシュレポートの検索・収集
  local crash_info=""
  find "$HOME/Library/Logs/DiagnosticReports" \( -name "InfiniteCanvasApp*.crash" -o -name "InfiniteCanvasApp*.ips" -o -name "InfiniteCanvasAppUITests*.crash" -o -name "InfiniteCanvasAppUITests*.ips" \) -nt "$start_marker" 2>/dev/null | while read -r crash_file; do
    cp "$crash_file" "$CRASH_DIR/"
    echo "    [CRASH DETECTED] Saved crash report: $CRASH_DIR/$(basename "$crash_file")"
    crash_info="  - **クラッシュレポート**: [$(basename "$crash_file")](file://$(pwd)/$CRASH_DIR/$(basename "$crash_file"))"
  done
  
  # 3. 自動バグタスク情報の蓄積
  {
    echo "- [ ] **[FAIL] $target**"
    echo "  - **発生日時**: $(date '+%Y-%m-%d %H:%M:%S')"
    
    local failed_methods=$(extract_failing_tests "$log_file")
    if [[ -n "$failed_methods" ]]; then
      echo "  - **失敗メソッド**:"
      echo "$failed_methods" | while read -r method; do
        echo "    - \`$method\`"
      done
    else
      echo "  - **ログの抜粋 (末尾)**:"
      tail -n 8 "$log_file" | while read -r line; do
        echo "    - \`$line\`"
      done
    fi
    
    echo "  - **ログファイル**: [${target##*/}.log](file://$(pwd)/$LOG_DIR/$(basename "$log_file"))"
    echo "  - **詳細結果 (.xcresult)**: [${target##*/}.xcresult](file://$(pwd)/$XCRESULT_PATH)"
    if [[ -n "$ss_info" ]]; then
      echo "$ss_info"
    fi
    if [[ -n "$crash_info" ]]; then
      echo "$crash_info"
    fi
    echo ""
  } >> "$TASK_TEMP"
}

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
RUN_COUNT=0

# 各グループ順に実行
for GI in {0..8}; do
  DESC="${GROUPS_DESC[$GI]}"
  
  # グループ内に対象ターゲットがあるか事前に確認
  case $GI in
    0) TARGETS=("${GROUP_1_TARGETS[@]}") ;;
    1) TARGETS=("${GROUP_2_TARGETS[@]}") ;;
    2) TARGETS=("${GROUP_3_TARGETS[@]}") ;;
    3) TARGETS=("${GROUP_4_TARGETS[@]}") ;;
    4) TARGETS=("${GROUP_5_TARGETS[@]}") ;;
    5) TARGETS=("${GROUP_6_TARGETS[@]}") ;;
    6) TARGETS=("${GROUP_7_TARGETS[@]}") ;;
    7) TARGETS=("${GROUP_8_TARGETS[@]}") ;;
    8) TARGETS=("${GROUP_9_TARGETS[@]}") ;;
  esac

  ANY_RUN=false
  for T in "${TARGETS[@]}"; do
    if should_run "$T"; then
      ANY_RUN=true
      break
    fi
  done

  if ! $ANY_RUN; then
    continue
  fi

  echo
  echo "=============================================================="
  echo "$DESC"
  echo "=============================================================="

  for T in "${TARGETS[@]}"; do
    if ! should_run "$T"; then
      continue
    fi

    RUN_COUNT=$((RUN_COUNT + 1))
    echo "--> Running: $T"
    
    # UIテストのフリーズや前テストの状態汚染を防ぐため、毎回アプリをアンインストールして状態をクリーンにする
    DEVELOPER_DIR=$DEVDIR xcrun simctl uninstall "$UDID" "$APP_ID" >/dev/null 2>&1
    
    LOG="$LOG_DIR/$(echo "$T" | tr '/' '_').log"
    XCRESULT_PATH="$XCRESULT_DIR/$(echo "$T" | tr '/' '_').xcresult"
    
    # 古い結果ファイルの削除
    rm -rf "$XCRESULT_PATH"
    
    # テスト開始時間のマーカーを作成（クラッシュレポート検知用）
    START_MARKER="/tmp/test_start_marker_${T//\//_}"
    touch "$START_MARKER"
    
    # 個別テストの実行
    DEVELOPER_DIR=$DEVDIR xcodebuild test-without-building \
        -project "$PROJECT" -scheme "$SCHEME" -destination "$DEST" \
        -parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1 \
        -resultBundlePath "$XCRESULT_PATH" \
        -only-testing:"$T" >"$LOG" 2>&1
    
    XCODE_STATUS=$?
        
    if [ $XCODE_STATUS -eq 0 ]; then
      echo "  [PASS] $T"
      PASS+=("$T")
      
      # 成功時は不要であればアプリをアンインストール
      if ! $KEEP_APP; then
        DEVELOPER_DIR=$DEVDIR xcrun simctl uninstall "$UDID" "$APP_ID" >/dev/null 2>&1
      fi
    else
      echo "  [FAIL] $T"
      echo "    Log saved to: $LOG"
      echo "    Result bundle: $XCRESULT_PATH"
      
      append_fail_task "$T" "$LOG" "$XCRESULT_PATH" "$START_MARKER"
      
      # エラーが起きた場合は、ログの最後の数行を表示して原因特定をサポート
      echo "    --- LOG TAIL ---"
      tail -n 10 "$LOG" | sed 's/^/      /'
      echo "    ----------------"
      FAIL+=("$T")
    fi

    
    rm -f "$START_MARKER"
  done
done

# -------------------------------------------------------------
# タスク管理ファイル (tasks/バグ修正タスク.md) への自動書き込み
# -------------------------------------------------------------
if [ ${#FAIL[@]} -gt 0 ]; then
  TASK_FILE="tasks/バグ修正タスク.md"
  mkdir -p "$(dirname "$TASK_FILE")"
  
  if [ ! -f "$TASK_FILE" ]; then
    echo "# InfiniteCanvasApp バグ修正タスク" > "$TASK_FILE"
    echo "" >> "$TASK_FILE"
  fi
  
  # タイムスタンプセクションを追記
  current_time=$(date "+%Y-%m-%d %H:%M:%S")
  echo "" >> "$TASK_FILE"
  echo "---" >> "$TASK_FILE"
  echo "" >> "$TASK_FILE"
  echo "## 自動検出されたバグ・エラー ($current_time)" >> "$TASK_FILE"
  echo "" >> "$TASK_FILE"
  
  # 収集したタスクの書き込み
  cat "$TASK_TEMP" >> "$TASK_FILE"
  echo "  [INFO] tasks/バグ修正タスク.md に新規バグタスクを追加しました。"
fi

rm -f "$TASK_TEMP"

# -------------------------------------------------------------
# 結果サマリー表示
# -------------------------------------------------------------

echo
echo "=============================================================="
echo "                         TEST SUMMARY                         "
echo "=============================================================="
echo "RUN: $RUN_COUNT"
echo "PASS: ${#PASS[@]} / $RUN_COUNT"
echo "--------------------------------------------------------------"

if [ $RUN_COUNT -eq 0 ]; then
  echo "RESULT: No tests were run."
  exit 0
fi

if [ ${#FAIL[@]} -eq 0 ]; then
  echo "RESULT: ALL GREEN (すべてのテストに合格しました)"
  exit 0
else
  echo "RESULT: SOME TESTS FAILED"
  for f in "${FAIL[@]}"; do
    echo "  FAILED: $f"
  done
  echo "--------------------------------------------------------------"
  echo "Diagnose artifacts stored in: $RESULTS_DIR/"
  if [ "$(ls -A "$SCREENSHOT_DIR")" ]; then
    echo "  - Screenshots: $SCREENSHOT_DIR/"
  fi
  if [ "$(ls -A "$CRASH_DIR")" ]; then
    echo "  - Crash Reports: $CRASH_DIR/"
  fi
  echo "  - Detailed Results (.xcresult): $XCRESULT_DIR/"
  echo "  - Task file updated: $TASK_FILE"
  exit 1
fi



