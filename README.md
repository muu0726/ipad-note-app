# 無限キャンバスノート (iPad)

Goodnotes / フリーボード風の無限キャンバス・ノートアプリ。

- **スタック**: SwiftUI / PencilKit / Core Data + CloudKit / iPadOS 17+
- **ワークフロー**: Windows で開発 → GitHub → MacBook (Xcode) でビルド・実機確認

## 進捗

- [x] ① ファイル・フォルダ管理(サイドバー無限階層 / グリッド / ゴミ箱 / タブ骨格)
- [ ] ② 無限キャンバス(PencilKit + ズーム / スクロール / 自動保存)
- [ ] ③ オブジェクト配置(テキスト / 画像 / PDF)+ カスタムペンツールバー
- [ ] ④ スナップ機能 / 背景テンプレート

## ディレクトリ構成

```
InfiniteCanvasApp/
├── App/
│   └── InfiniteCanvasNoteApp.swift      # エントリポイント
├── Persistence/
│   ├── PersistenceController.swift      # Core Data + CloudKit スタック
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
    ├── Canvas/                          # タブバー + キャンバス(②で実装)
    └── Common/                          # ダイアログ / 移動先ピッカー
```

## Mac (Xcode) での組み込み手順

1. Xcode → **New Project → iOS App**
   - Product Name: `InfiniteCanvasApp` / Interface: SwiftUI / Language: Swift
   - 「Use Core Data」「Host in CloudKit」のチェックは **不要**(自前実装済み)
2. Xcode が生成した `InfiniteCanvasAppApp.swift` と `ContentView.swift` を削除
3. このリポジトリの `InfiniteCanvasApp/` 配下のフォルダ一式をプロジェクトナビゲータへドラッグ
   - 「Copy items if needed」は **オフ**(リポジトリ内のファイルをそのまま参照)
   - 「Create groups」を選択し、ターゲットに追加
   - `InfiniteCanvas.xcdatamodeld` がターゲットに含まれていることを確認
4. **Signing & Capabilities** で以下を追加:
   - `iCloud` → CloudKit にチェック → コンテナ `iCloud.<バンドルID>` を作成
   - `Background Modes` → Remote notifications にチェック
5. Deployment Target を **iOS 17.0** に設定
6. iPad シミュレーターで実行(CloudKit 同期の確認は iCloud サインイン済みの実機推奨)

## 設計メモ (①)

- **無限階層**: `Folder` の自己参照リレーション `parent` / `children` で実現
- **ゴミ箱**: 物理削除せず `isTrashed` フラグをサブツリーへ再帰設定。
  復元はフラグ解除(親が消えていればルートへ)。完全削除は Cascade ルールで中身ごと削除
- **CloudKit 制約対応**: 全属性 optional / デフォルト値あり、全リレーションに inverse 設定済み
- **タブ**: `OpenNotesSession` が開いているノート配列と選択状態を保持。
  レイアウトは「ナビバー → ペンツールバー → タブバー → キャンバス」の順(承認済み)

## Mac での動作確認ポイント(Windows 側ではビルド未検証)

- [ ] ビルドが通ること(コード生成: xcdatamodeld の codeGenerationType=class に依存)
- [ ] サイドバーの DisclosureGroup ラベルへの `.tag()` によるフォルダ選択が効くこと
      (効かない場合はラベルを Button 化して手動選択に切り替える)
- [ ] iCloud 同期(実機 2 台または実機+シミュレーター)
