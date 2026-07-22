# 無限キャンバスノート (iPad)

Goodnotes / フリーボード / Obsidian 風の手書きノートアプリ。
無限キャンバスと通常ノート(A4ページ制)の両方に対応し、ノート同士をリンクして
グラフビューで俯瞰できる。

- **スタック**: SwiftUI / PencilKit / PDFKit / Core Data / WebKit(グラフ描画)/ iPadOS 17+
  (CloudKit 同期は有料 Developer アカウント取得後に有効化。現在はローカル保存のみ)
- **入力モデル**: Apple Pencil = 描画 / 指 = 選択・移動・スクロール(Pencil Only)
- **ワークフロー**: Mac で開発・ビルド・実機確認

## 主な機能

### ファイル・フォルダ管理
- サイドバーの無限階層ツリー(再帰 DisclosureGroup)/ サムネイルグリッド
- ドラッグ&ドロップでのフォルダ移動・並び替え
- ゴミ箱(復元 / 完全削除)/ タブによる複数ノートの同時オープン

### キャンバス / ノート種別
- **無限キャンバス**: 100,000×100,000pt・ズーム 0.1〜5.0 の疑似無限キャンバス
- **通常ノート(paged)**: A4 固定ページ。見開き2ページ表示・横スクロール(ページめくり)・
  末尾のオーバースクロールでページ自動追加
- **ページマネージャー**: 全ページをサムネイル格子で一覧し、並び替え / 複製 / 削除
- **しおり(ブックマーク)/ 目次(アウトライン)**: 一覧からページへジャンプ
- **背景テンプレート**: 白紙 / 方眼 / ドット / 横線
- **用紙色**: 白 / 黒(罫線・テキスト・サムネイルが連動反転)

### ペン・描画
- カスタムペンツールバー(PKToolPicker 不使用): ペン / マーカー(蛍光ペン)/ 消しゴム
- 太さスロット・カラーパレット・**カスタムペンホルダー(お気に入りペンを登録)**
- 蛍光ペンは PencilKit 標準マーカーとして描画
- なぞって消える消しゴム(`PKEraserTool(.bitmap)`)
- 図形認識(手書きストローク → 直線 / 矩形 / 円などへ整形)

### オブジェクト(`CanvasObject`)
テキスト / 画像 / PDF / **図形**(矩形・楕円・三角・直線・矢印・星)/ **表**(Excel 風・
可変列幅 / 行高)/ **Todo リスト(チェックリスト)** / **ノートリンク**(他ノートへのカード)
- 挿入は選択後に自動編集開始。テキストはフォントサイズ変更(12〜72pt)
- スナップ(他オブジェクトの端・中心 + 背景グリッドへ吸着、ガイド線表示)
- **ロック**(南京錠・解除可)/ **グループ化**
- 投げ縄(lasso)選択したインク領域と連動してオブジェクトを移動 / 削除

### ノートリンク & グラフビュー
- ノート内にリンク先ノートのカードを配置 → ダブルタップでタブを開く / 切替
- Obsidian 風の力学ネットワーク・グラフビュー(d3.js を WebView で描画)で
  ノート間のリンク関係を俯瞰。ノードタップで該当ノートを開く

### その他
- 2画面分割(アプリ内スプリットビュー・比率可変)
- Undo / Redo(描画とオブジェクト操作を 1 本のスタックに統合)
- ビューポート永続化(タブごとのスクロール位置・ズームを再起動後も復元)
- 自動保存(描画変更を 0.8 秒デバウンス)+ ライブラリ用サムネイル生成
- アプリアイコン(芽のロゴ・ライト / ダーク / ティント対応)

## ディレクトリ構成

Xcode プロジェクトは `InfiniteCanvasApp/InfiniteCanvasApp.xcodeproj`。
ソースは新形式の「フォルダ同期グループ」で組み込まれているため、
**フォルダに追加した Swift ファイルは自動でターゲットに含まれる**(手動追加は不要)。

```
InfiniteCanvasApp/InfiniteCanvasApp/Sources/
├── App/
│   └── InfiniteCanvasNoteApp.swift      # エントリポイント
├── Persistence/
│   ├── PersistenceController.swift      # Core Data スタック(ローカル保存)
│   └── InfiniteCanvas.xcdatamodeld/     # Folder / NoteFile / CanvasObject / NoteOutline
├── Models/
│   ├── Folder+Helpers.swift             # 階層取得・循環参照チェック
│   ├── NoteFile+Helpers.swift           # ノート種別 / 用紙色 / しおり / 目次
│   ├── CanvasObject+Helpers.swift       # オブジェクト種別・図形/表ペイロード・ロック判定
│   └── LibraryItem.swift                # フォルダ / ノート共通ラッパー
├── Extensions/
│   └── UIColor+Hex.swift                # カラー Hex 変換(カスタムペンの永続化に使用)
├── Services/
│   ├── LibraryService.swift             # 作成 / 名前変更 / 移動 / ゴミ箱・PDF→通常ノート生成
│   ├── LibraryActionCoordinator.swift   # ダイアログ状態の一元管理
│   ├── ShapeRecognizer.swift            # 手書きストロークの図形認識
│   ├── LassoObjectSync.swift            # 投げ縄選択とオブジェクトの連動移動 / 削除
│   ├── NoteGraphBuilder.swift           # ノートリンク関係を d3.js 用グラフ構造へ変換
│   ├── PagePlanner.swift                # ページ並び替え / 複製 / 削除の座標再割り当て計画
│   ├── PageThumbnailRenderer.swift      # ページ単位のサムネイル生成
│   ├── PagedDrawingStore.swift          # 通常ノートのページローカルなインク保存
│   └── InfiniteScrollLimiter.swift      # 無限キャンバスのスクロール範囲制御
├── Session/
│   └── OpenNotesSession.swift           # タブ / 選択 / ビューポート / 2画面分割の管理と永続化
└── Views/
    ├── RootView.swift                   # NavigationSplitView(サイドバー / キャンバス / グラフ)
    ├── Sidebar/                         # 再帰ツリー・ノート行
    ├── Library/                         # サムネイルグリッド
    ├── Trash/                           # ゴミ箱(復元 / 完全削除)
    ├── Graph/                           # グラフビュー(SwiftUI + WebView / d3.js)
    ├── Canvas/                          # ペンツールバー・タブバー・オブジェクトレイヤー等
    │   └── Paged/                       # 通常ノート(ページ制)の描画・レイアウト
    └── Common/                          # ダイアログ / 移動先ピッカー / ドラッグ&ドロップ
```

## ビルド・実行

- Xcode で `InfiniteCanvasApp/InfiniteCanvasApp.xcodeproj` を開き、iPad シミュレーターを選んで ⌘R
- CLI: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project InfiniteCanvasApp/InfiniteCanvasApp.xcodeproj -scheme InfiniteCanvasApp -destination 'generic/platform=iOS Simulator' build`
- 新しい Xcode は「定義モジュールの明示 import」を厳格に要求する
  (例: `@Published` を使うファイルは `import Combine` が必須)
- データモデルの変更は軽量マイグレーションで自動移行されるため、通常はシミュレーターのデータ削除は不要
- **テスト**: シミュレーターは 1 台のみ(並列 / クローン禁止)。
  `-parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1` を付ける。
  UI テストはクラス単位で個別実行するとフレークが出にくい
- **iCloud (CloudKit)**: 無料アカウント(Personal Team)では不可。有料 Developer アカウント取得後に
  Signing & Capabilities で iCloud (CloudKit) + Background Modes を追加し、
  `PersistenceController` の `NSPersistentContainer` を `NSPersistentCloudKitContainer` に戻す

## 設計メモ

### レイヤー構成 / 入力モデル
- **3層構成**: `背景パターン → ObjectLayerUIView → PKCanvasView(透明)`。
  背景・オブジェクトレイヤーは PKCanvasView の contentOffset / zoomScale に KVO で追従。
  インクは常にオブジェクトの上に描かれる(画像・PDF の上に手書き注釈できる)
- **Pencil Only**: Apple Pencil のタッチだけを描画に使う。指のタッチは選択・移動・スクロール。
  指がインクを引かないのは `pencilOnly` と `DrawingTouchGate`(指 × オブジェクトの除外)が担う。
  かつての「手のひら選択ツール」は廃止し、指 = 選択 / ペン = 描画に統一

### オブジェクト / スナップ
- **モデル**: Core Data の `CanvasObject`(kind = text / image / pdf / noteLink / todo / shape / table、
  フレームはコンテンツ空間、payload に画像・PDF・図形・表データ)。
  `isLocked` = システムロック(PDF 背景など非対話)、`isUserLocked` = ユーザーロック(南京錠)。
  保護判定は `isMovementLocked`。`parentGroupID` でグループ化
- **スナップ**: ドラッグ中に `SnapEngine` が他オブジェクトの端・中心(オレンジのガイド線)と
  背景グリッド 40pt へ吸着。しきい値はスクリーン上で常に約 8pt(ズーム補正)
- **テキスト**: 選択済みを再タップでインライン編集(UITextView)。高さ自動拡張・フォントサイズ 12〜72pt
- **サムネイル**: 描画とオブジェクトを合成して生成(用紙色を反映)

### 図形 / 表 / Todo / 図形認識
- **図形**: `ShapeType`(矩形・楕円・三角・直線・矢印・星)。ツールバーの図形ボタンから
  タップ位置へ配置し、`ShapeEditPopover` で色・線幅などを編集
- **表**: `TableGridPickerView` で行 × 列を選んで配置。可変列幅 / 行高(ユニット担保 `TablePayloadTests`)
- **Todo**: チェックリストオブジェクト。項目の追加 / チェック切替
- **図形認識**: `ShapeRecognizer.recognize(points:)` が点列から図形へ整形。図形アシスト ON 時に
  手書きストロークを差し替える(幾何ロジックは `ShapeRecognizerTests` でユニット担保)

### 通常ノート(paged)/ PDF 背景インポート
- **ページ制**: `NoteFile.noteType = "paged"` / `pageCount`。横スクロール固定・見開き 2 ページ対応。
  インクはページローカルに保持(`PagedDrawingStore`)。末尾オーバースクロールでページ自動追加
- **ページ操作**: `PageManagerView` で並び替え / 複製 / 削除(座標再割り当ては `PagePlanner`)。
  最後のページ削除時はその Y 範囲のインク・オブジェクトも一括削除し 1 つの Undo グループに
- **しおり / 目次**: `NoteFile.bookmarkedPages` / `NoteOutline`。`PageNavigatorView` でジャンプ
- **PDF 背景インポート**: `LibraryService.createPagedNoteFromPDF` が全ページを `isLocked` 画像として
  背景に敷いた通常ノートを生成(その上に手書き注釈できる。ユニット担保 `PagedLayoutCalculatorTests` 等)

### ノートリンク / グラフビュー
- **モデル**: `CanvasObject.kind = "noteLink"` + `linkedNoteUUID`。`resolvedLinkedNote` が UUID から
  ノートを引き、ゴミ箱 / 削除済みなら nil(ダングリングリンクで壊れない)
- **カード**: 角丸カードにタイトル(サムネイルがあればプレビュー)。タイトルは同期のたびに引き直し、
  リネームに追従。選択モードでダブルタップ → `OpenNotesSession.open` でタブを開く / 切替
- **グラフビュー**: `NoteGraphBuilder` が全ノートのリンク関係を d3.js 用 JSON に変換し、
  `GraphWebView`(WebKit)が力学ネットワークで描画。検索・孤立ノート表示切替・ノードタップで開く

### 2画面分割 / セッション
- `OpenNotesSession` がタブ配列・選択・ビューポート・**2画面分割**(`isSplitActive` / 分割比率 /
  各タブの所属側)を保持。分割中は各ペインが自分の側のタブだけを表示し、閉じ切ると自動で 1 画面へ復帰
- ビューポート(スクロール位置・ズーム)はデバウンスして UserDefaults に永続化し、再起動後に復元

### Undo / 自動保存
- **Undo/Redo**: `CanvasUndoBridge` が PKCanvasView.undoManager を叩く。`CanvasObjectUndo` が
  挿入 / 移動 / テキスト / フォント / 削除 / ページ構造変更を同じ 1 本のスタックに積む
- **自動保存**: 描画変更を 0.8 秒デバウンスで `PKDrawing.dataRepresentation()` を保存 + サムネイル生成。
  タブ切替・ライブラリ復帰時は即時保存

### ファイル管理(①)
- **無限階層**: `Folder` の自己参照リレーション `parent` / `children`
- **ゴミ箱**: 物理削除せず `isTrashed` をサブツリーへ再帰設定。完全削除は Cascade で中身ごと削除
- **CloudKit 制約対応**: 全属性 optional / デフォルト値あり、全リレーションに inverse 設定済み
  (データモデルは CloudKit 対応のまま。コンテナだけローカル用 `NSPersistentContainer` に差し替え中)

## テスト

- **ユニット**(`InfiniteCanvasAppTests`): 図形認識・図形/表ペイロード・グラフ構築・
  ページレイアウト計算・ページインク保存・カスタムペン・分割セッション・タッチゲート等
- **UI**(`InfiniteCanvasAppUITests`): 全体ウォークスルー・ノートリンク・図形/表/Todo・
  通常ノート・分割ビュー・グラフ・ドラッグ&ドロップ・フォントサイズ・Pencil Only 等
- XCUITest はフリーハンド曲線を描けないため、幾何ロジックはユニットで担保する
