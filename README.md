# 無限キャンバスノート (iPad)

Goodnotes / フリーボード風の無限キャンバス・ノートアプリ。

- **スタック**: SwiftUI / PencilKit / Core Data / iPadOS 17+
  (CloudKit 同期は有料 Developer アカウント取得後に有効化。現在はローカル保存のみ)
- **ワークフロー**: Mac で開発・ビルド・実機確認(旧: Windows → GitHub → Mac)

## 進捗

- [x] ① ファイル・フォルダ管理(サイドバー無限階層 / グリッド / ゴミ箱 / タブ骨格)
- [x] ② 無限キャンバス(PencilKit + ズーム / スクロール / 自動保存 / サムネイル生成)
- [x] ③ カスタムペンツールバー(ペン / マーカー / 消しゴム・太さ3スロット・カラーパレット)
- [x] ④ 背景テンプレート(白紙 / 方眼 / ドット)
- [x] ③ オブジェクト配置(テキスト / 画像 / PDF・選択 / 移動 / リサイズ / 削除)
- [x] ④ オブジェクトのスナップ(他オブジェクトの端・中心 + グリッドへ吸着、ガイド線表示)
- [x] ⑤ 自由ノート風ツールバー改善(戻る / やり直し・なぞって消える消しゴム・
      オブジェクトの長押し削除・ノート作成時の用紙色選択 白 / 黒)

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
│   └── InfiniteCanvas.xcdatamodeld/     # データモデル (Folder / NoteFile)
├── Models/
│   ├── Folder+Helpers.swift             # 階層取得・循環参照チェック
│   ├── NoteFile+Helpers.swift
│   ├── CanvasObject+Helpers.swift       # オブジェクト種別 / フレーム / PDF レンダリング
│   └── LibraryItem.swift                # フォルダ/ノート共通ラッパー
├── Services/
│   ├── LibraryService.swift             # 作成/名前変更/移動/ゴミ箱/削除
│   └── LibraryActionCoordinator.swift   # ダイアログ状態の一元管理
├── Session/
│   └── OpenNotesSession.swift           # 開いているタブの管理
└── Views/
    ├── RootView.swift                   # NavigationSplitView (2カラム)
    ├── Sidebar/                         # 再帰ツリー (DisclosureGroup)
    ├── Library/                         # サムネイルグリッド
    ├── Trash/                           # ゴミ箱 (復元 / 完全削除)
    ├── Canvas/                          # 無限キャンバス / ペンツールバー / タブバー
    └── Common/                          # ダイアログ / 移動先ピッカー
```

## ビルド・実行

- Xcode で `InfiniteCanvasApp/InfiniteCanvasApp.xcodeproj` を開き、iPad シミュレーターを選んで ⌘R
- CLI: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project InfiniteCanvasApp/InfiniteCanvasApp.xcodeproj -scheme InfiniteCanvasApp -destination 'generic/platform=iOS Simulator' build`
- 新しい Xcode は「定義モジュールの明示 import」を厳格に要求する
  (例: `@Published` を使うファイルは `import Combine` が必須)
- データモデルの変更は軽量マイグレーションで自動移行されるため、シミュレーターのデータ削除は不要
- **iCloud (CloudKit)**: 無料アカウント(Personal Team)では不可。有料 Developer アカウント取得後に
  Signing & Capabilities で iCloud (CloudKit) + Background Modes (Remote notifications) を追加し、
  `PersistenceController` の `NSPersistentContainer` を `NSPersistentCloudKitContainer` に戻す

## 設計メモ (③ オブジェクト配置 / ④ スナップ)

- **レイヤー構成**: `背景パターン → ObjectLayerUIView → PKCanvasView(透明)` の3層。
  オブジェクトレイヤーも背景と同じスクリーン空間ビューで contentOffset / zoomScale に追従(KVO)。
  インクは常にオブジェクトの上に描かれる(画像・PDF の上に手書き注釈できる)
- **選択モード**: ツールバー先頭の手のひらツール。PKCanvasView の drawingGestureRecognizer を
  無効化し、`CanvasContainerUIView.hitTest` がオブジェクトへのタッチを下層レイヤーへ転送する。
  描画モード中はオブジェクトに一切タッチが渡らない(誤操作防止)
- **オブジェクト**: Core Data の `CanvasObject`(kind = text / image / pdf、フレームはコンテンツ空間、
  payload に画像 / PDF バイナリ)。PDF は1ページ目を PDFKit で画像化して表示(原本は保持)
- **挿入**: ツールバーの「＋」メニュー → 現在のビューポート中央に配置し、自動で選択モードへ。
  テキストはそのまま編集開始。画像はフォトライブラリ、PDF はファイルアプリから
- **スナップ(④)**: ドラッグ中に `SnapEngine` が他オブジェクトの端・中心(オレンジのガイド線表示)と
  背景グリッド 40pt(ガイドなし)へ吸着。しきい値はスクリーン上で常に約 8pt(ズーム補正)
- **テキスト**: 選択済みを再タップでインライン編集(UITextView)。入力に応じて高さ自動拡張。
  リサイズハンドル(右下)で自由リサイズ、画像 / PDF はアスペクト比固定
- **サムネイル**: 描画とオブジェクトを合成してライブラリ用サムネイルを生成(用紙色を反映)

## 設計メモ (⑤ 自由ノート風の操作系)

- **戻る / やり直し**: `CanvasUndoBridge` が PKCanvasView.undoManager を叩く。
  PencilKit が描画操作を自動登録するため、描画変更のたびに canUndo / canRedo を引き直すだけ
- **消しゴム**: `PKEraserTool(.bitmap)`(なぞった部分だけ消える)。旧 .vector はストローク丸ごと消し
- **オブジェクト削除**: 選択モードで長押し → 編集メニュー(UIEditMenuInteraction)の「削除」
- **用紙色**: `NoteFile.pageColor`(white / black、軽量マイグレーション)。作成シートで選択。
  白紙 = 黒い罫線・ドット / 黒紙 = 白い罫線・ドット。テキストオブジェクトとサムネイルも連動。
  用紙と同色のペンで開いた場合は自動で反転色に切り替え(黒紙で黒ペン → 白ペン)

## 設計メモ (②③④)

- **無限キャンバス**: PKCanvasView は UIScrollView のサブクラスであることを利用し、
  contentSize 100,000×100,000pt + zoomScale 0.1〜5.0 の疑似無限キャンバス。初期位置は中央
- **ペンツール**: PKToolPicker 不使用。`PenToolState` が太さ/色をツールごとに記憶し、
  `PKInkingTool` / `PKEraserTool` を生成して `PKCanvasView.tool` に反映
- **自動保存**: 描画変更から 0.8 秒デバウンスで `PKDrawing.dataRepresentation()` を
  `NoteFile.canvasData` に保存 + サムネイル生成。タブ切替・ライブラリ復帰時は即時保存
- **背景**: スクリーン空間で描画する `BackgroundPatternUIView` が contentOffset / zoomScale に
  追従(KVO)。ズームアウト時は格子間隔を自動で粗くする
- **ビューポート**: タブごとのスクロール位置・ズームを `OpenNotesSession.viewports` に保持
  (アプリ再起動後の復元は未実装)

## 設計メモ (①)

- **無限階層**: `Folder` の自己参照リレーション `parent` / `children` で実現
- **ゴミ箱**: 物理削除せず `isTrashed` フラグをサブツリーへ再帰設定。
  復元はフラグ解除(親が消えていればルートへ)。完全削除は Cascade ルールで中身ごと削除
- **CloudKit 制約対応**: 全属性 optional / デフォルト値あり、全リレーションに inverse 設定済み
  (データモデルは CloudKit 対応のまま。コンテナだけローカル用 `NSPersistentContainer` に差し替え中)
- **タブ**: `OpenNotesSession` が開いているノート配列と選択状態を保持。
  レイアウトは「ナビバー → ペンツールバー → タブバー → キャンバス」の順(承認済み)

## Mac での動作確認ポイント(Windows 側ではビルド未検証)

- [ ] ビルドが通ること(コード生成: xcdatamodeld の codeGenerationType=class に依存)
- [ ] サイドバーの DisclosureGroup ラベルへの `.tag()` によるフォルダ選択が効くこと
      (効かない場合はラベルを Button 化して手動選択に切り替える)
- [ ] iCloud 同期(有料 Developer アカウント取得後に実施)
