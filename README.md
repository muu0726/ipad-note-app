# 無限キャンバスノート (iPad)

Goodnotes / フリーボード風の無限キャンバス・ノートアプリ。

- **スタック**: SwiftUI / PencilKit / Core Data / iPadOS 17+
  (CloudKit 同期は有料 Developer アカウント取得後に有効化。現在はローカル保存のみ)
- **ワークフロー**: Windows で開発 → GitHub → MacBook (Xcode) でビルド・実機確認

## 進捗

- [x] ① ファイル・フォルダ管理(サイドバー無限階層 / グリッド / ゴミ箱 / タブ骨格)
- [x] ② 無限キャンバス(PencilKit + ズーム / スクロール / 自動保存 / サムネイル生成)
- [x] ③ カスタムペンツールバー(ペン / マーカー / 消しゴム・太さ3スロット・カラーパレット)
- [x] ④ 背景テンプレート(白紙 / 方眼 / ドット)
- [ ] ③ オブジェクト配置(テキスト / 画像 / PDF)← 次: UI/UX設計案の承認から
- [ ] ④ オブジェクトのスナップ(吸着)← オブジェクト配置とセットで実装

## ディレクトリ構成

```
Sources/
├── App/
│   └── InfiniteCanvasNoteApp.swift      # エントリポイント
├── Persistence/
│   ├── PersistenceController.swift      # Core Data スタック(ローカル保存)
│   └── InfiniteCanvas.xcdatamodeld/     # データモデル (Folder / NoteFile)
├── Models/
│   ├── Folder+Helpers.swift             # 階層取得・循環参照チェック
│   ├── NoteFile+Helpers.swift
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

## Mac (Xcode) での組み込み手順

1. **クローン**: Xcode 起動 → Welcome 画面の「Clone Git Repository…」
   (またはメニュー Integrate → Clone…)→ `https://github.com/muu0726/ipad-note-app.git` を入力
   → 保存先(例: `~/Developer`)を選択。クローン後にフォルダが開いたらいったん閉じる
2. **プロジェクト作成**: File → New → Project… → **iOS App**
   - Product Name: `InfiniteCanvasApp` / Interface: SwiftUI / Language: Swift
   - Testing System: None / Storage: **None**(Core Data は選ばない。自前実装済み)
   - 保存先にクローンした `ipad-note-app` フォルダを指定
     (リポジトリ直下に `InfiniteCanvasApp/` プロジェクトフォルダが作られる)
   - 「Create Git repository」のチェックが出た場合はオフ
3. Xcode が生成した `InfiniteCanvasAppApp.swift` と `ContentView.swift` を削除(Move to Trash)
4. Finder でリポジトリ直下の `Sources/` フォルダをプロジェクトナビゲータへドラッグ
   - 「Copy items if needed」は **オフ**(リポジトリ内のファイルをそのまま参照)
   - 「Create groups」を選択し、ターゲット `InfiniteCanvasApp` に追加
   - `InfiniteCanvas.xcdatamodeld` がターゲットに含まれていることを確認
5. ~~Signing & Capabilities で iCloud / Background Modes を追加~~
   → **無料アカウント(Personal Team)では不要・不可。** 有料アカウント取得後に
   iCloud (CloudKit) + Background Modes (Remote notifications) を追加し、
   `PersistenceController` の `NSPersistentContainer` を `NSPersistentCloudKitContainer` に戻す
6. Deployment Target を **iOS 17.0** に設定
7. iPad シミュレーターで実行
8. ビルドが通ったら Integrate → Commit… で `.xcodeproj` をコミット & プッシュ
   (以後 Windows 側の変更は Xcode の Integrate → Pull だけで取り込める)

## Pull 後に Xcode 側で必要な作業(重要)

Xcode に「グループ」として追加したフォルダは、**Windows 側で後から増えたファイルを自動では取り込まない**。
Pull 後、以下の新規ファイルを Finder から `Views/Canvas` グループへドラッグしてターゲットに追加すること:

- `Sources/Views/Canvas/PenToolState.swift`
- `Sources/Views/Canvas/PenToolbarView.swift`
- `Sources/Views/Canvas/CanvasRepresentable.swift`
- `Sources/Views/Canvas/NoteCanvasView.swift`

データモデル(`NoteFile` に `canvasData` / `backgroundStyle` を追加)は軽量マイグレーションで
自動移行されるため、シミュレーターのデータ削除は不要。

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
