# Supabase Storage 設計・運用方針（タスク #2）

対象バケット: **`canvas-blobs`**（プライベート）。作成・RLS ポリシーは `schema.sql` 末尾に定義。
本書は「何を・どのパスに・どの解像度で置き、いつ消すか」の運用規約を定める。
実際の up/download と PNG 生成の実装は **#8（BlobSyncService）** で行う。

---

## 1. バケットとパス規約

- バケット: `canvas-blobs` / `public = false`（署名 URL or 認証セッション経由でのみアクセス）。
- パス規約: **`{user_id}/{note_id}/{kind}[/{index}].{ext}`**
  - 先頭セグメントが `user_id` であることを RLS が要求する
    （`auth.uid()::text = (storage.foldername(name))[1]`）。ここがユーザー分離の要。
- DB 側の参照カラム（`notes.canvas_data_path` / `notes.thumbnail_path` / `notes.preview_png_path` /
  `canvas_objects.payload_path`）にはこのフルパスを保存する。

### 種別ごとの配置

| 用途 | 由来（Core Data） | パス例 | 形式 |
|------|-------------------|--------|------|
| 手書き正本 | `NoteFile.canvasData`（PKDrawing） | `{u}/{n}/canvasData.bin` | PKDrawing dataRepresentation |
| 一覧サムネ | `NoteFile.thumbnailData` | `{u}/{n}/thumbnail.jpg` | JPEG(q=0.7) |
| Web 閲覧 PNG | 保存時に合成生成 | `{u}/{n}/previewPng/{page}.png` | PNG（ページ単位） |
| オブジェクト payload | `CanvasObject.payload` | `{u}/{n}/objects/{objectId}.bin` | 画像 or JSON（kind 依存） |

> `payload` は kind により中身が異なる（image/pdf=画像バイナリ、todo/shape/table/stickyNote/connector=JSON）。
> 拡張子や content-type は kind から決定し、判別ロジックは #8 に置く。

---

## 2. 圧縮方針（Free 枠 Storage 1GB を圧迫しない）

- **サムネイル**（`thumbnail.jpg`）: 既存 `NoteCanvasView.makeThumbnail()` に準拠（長辺 480pt、JPEG q=0.7）。
- **Web 閲覧 PNG**（`previewPng/*.png`）: 長辺上限 **2048px** にクランプ。
  既存 `PageThumbnailRenderer`（`UIGraphicsImageRenderer`）を流用し `.pngData()` 化して生成。
  透明背景が不要なら用紙色で塗りつぶした不透明 PNG にしてサイズを抑える。
- **payload 画像**（image/pdf 由来）: 保存前に長辺上限（例 2048px）へダウンスケール。
  PDF ページ背景は既存 `LibraryService.renderPageImage()` が `scale=2` の JPEG(q=0.8) を生成しており、
  Storage 転送時はこの圧縮済みバイナリをそのまま使う。
- 差分アップロード: blob はハッシュ or 更新時刻で差分判定し、変化が無ければ再アップロードしない（#8）。

---

## 3. 不要データ削除（クリーンアップ規約）

blob は DB 行とライフサイクルを合わせ、孤児 blob を残さない。実行は #7/#8 の同期処理内。

- **ノート削除（物理）/ ゴミ箱完全削除**: `{user_id}/{note_id}/` 配下を prefix 一括削除。
- **ページ削除 / オブジェクト削除**: 対応する `previewPng/{page}.png` / `objects/{objectId}.bin` を個別削除。
- **オブジェクト種別変更・payload 変更**: 旧 payload を上書き or 削除し、参照カラムを更新。
- ゴミ箱（`is_trashed = true`）の間は blob を残し、完全削除で初めて Storage からも消す
  （復元可能性を担保）。

---

## 4. 容量試算（Free 枠: DB 500MB / Storage 1GB）

概算前提（圧縮方針適用後）:

| 種別 | 1件あたり目安 |
|------|---------------|
| canvasData（PKDrawing） | 数十〜数百 KB（描画量依存、平均 ~150KB と仮定） |
| thumbnail.jpg（長辺480, q0.7） | ~40KB |
| previewPng（長辺2048, 不透明） | ~400KB / ページ |
| payload 画像（長辺2048） | ~300KB / 画像 |

- **通常ノート（paged, 10ページ, 画像少なめ）**: canvas ~150KB + thumb 40KB + PNG 400KB×10 ≒ **約 4.2MB**。
- Storage 1GB ÷ 4.2MB ≒ **約 240 ノート**が目安（画像多用ノートはさらに減る）。
- DB 行は 1 ノートあたり数百バイト〜数 KB（テキスト量依存）で、500MB は blob を Storage に逃がす限り当面問題になりにくい。

**運用示唆**: previewPng がストレージ支配項。ページ数が多い/画像が多いノートを多数作る運用になったら、
(a) PNG をタイル化して可視範囲のみ生成、(b) 長辺上限を 1536px へ下げる、(c) 古いプレビューの再生成を遅延、
などで調整する（将来拡張、#8 以降で検討）。

---

## 5. 検証（このバッチ範囲）

- `schema.sql` 適用後、`storage.buckets` に `canvas-blobs` が存在し `public=false` であること。
- 認証ユーザー A のセッションで `A/{note}/x.png` を upload/download できること。
- 同セッションから `B/...`（別 user_id 先頭パス）へは upload/select できないこと（RLS 分離）。
  手順は `README.md` の「RLS 動作確認」を参照。自動テストは #10 で整備。
