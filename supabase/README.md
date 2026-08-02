# Supabase セットアップ手順（Phase 1 / タスク #3）

外部脳ノートアプリの同期ハブ。無料枠（Free Tier）で iPad / Web / MCP から共有する。
このディレクトリの構成:

- `schema.sql` … テーブル・RLS・updated_at トリガ・Storage バケット/ポリシー（タスク #1・#2）
- `storage.md` … Storage の配置規約・圧縮・削除・容量試算（タスク #2）
- `README.md` … 本書（プロジェクト作成・環境変数・スキーマ適用・動作確認）

---

## 1. 無料 Supabase プロジェクト作成

1. https://supabase.com で GitHub 等でサインイン（無料）。
2. **New project** を作成（Region は日本近傍 = Tokyo 推奨、DB パスワードは控える）。
3. プロジェクトの **Settings → API** から以下を取得:
   - **Project URL**（`https://xxxx.supabase.co`）→ `SUPABASE_URL`
   - **anon public** key → `SUPABASE_ANON_KEY`（iPad/Web のクライアント用。RLS 前提で公開可）
   - **service_role** key → `SUPABASE_SERVICE_ROLE_KEY`（**RLS を貫通する強権限**。MCP/サーバー専用。
     クライアントや Git に置かない）

---

## 2. 環境変数

リポジトリ直下の `.env.example` をコピーして値を埋める（実ファイルはコミットしない）:

```bash
cp .env.example .env      # ローカル開発用（.gitignore 済み）
```

- iPad（InfiniteCanvasApp）: URL / anon key は **`.xcconfig` もしくは Info.plist 差し込み**で注入し、
  ソースにハードコードしない（実装は #4 SupabaseClientProvider）。
- Web（`web/`）: `.env.local` に `NEXT_PUBLIC_SUPABASE_URL` / `NEXT_PUBLIC_SUPABASE_ANON_KEY`（#11）。
- MCP（`mcp/`）: `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY` を環境変数で（#26）。

> `.env` / service_role key / auth トークンは **Git にも Obsidian Vault にもコミットしない**。
> `.gitignore` に `.env` 系が含まれていることを確認済み（`.env.example` はテンプレなのでコミット可）。

---

## 3. スキーマ適用

### 方法A: Supabase SQL エディタ（CLI 不要・推奨）

1. ダッシュボード → **SQL Editor** → **New query**。
2. `schema.sql` の全文を貼り付けて **Run**。
3. エラーが出なければ完了。**Table Editor** に `folders` / `notes` / `canvas_objects` /
   `note_outlines` が、**Storage** に `canvas-blobs` バケットが現れる。

### 方法B: Supabase CLI（ローカル or リモート）

```bash
# ローカルスタックで検証する場合
supabase start
supabase db reset          # supabase/migrations があれば適用。schema.sql を直接流すなら↓
psql "$DATABASE_URL" -f supabase/schema.sql

# リモートプロジェクトへ直接流す場合（接続文字列は Settings → Database）
psql "$SUPABASE_DB_URL" -f supabase/schema.sql
```

> このリポジトリの開発機には現状 `supabase` / `psql` が未インストール。CLI を使わない場合は方法A で適用する。

---

## 4. 認証（Magic Link）の下ごしらえ

実装は iPad #5 / Web #12 だが、プロジェクト側で先に有効化しておける:

1. **Authentication → Providers → Email** を有効化し、**Magic Link** を ON。
2. **Authentication → URL Configuration** に、iPad のディープリンク用リダイレクト URL
   （例: `infinitecanvas://auth-callback`）と Web のコールバック URL を **Redirect URLs** に追加。
3. 無料枠のメール送信はレート制限があるため、本番運用時は SMTP 設定を検討（将来拡張）。

---

## 5. 動作確認

### RLS 分離の確認（SQL エディタ）

テストユーザー 2 名（`Authentication → Users` で作成、または既存 UUID）を用意し、
セッションを偽装して別ユーザー行が見えないことを確認する:

```sql
-- ユーザーA になりすます
select set_config('request.jwt.claim.sub', '<USER_A_UUID>', true);
insert into public.folders (id, user_id, name) values (gen_random_uuid(), '<USER_A_UUID>', 'A のフォルダ');

-- ユーザーB になりすます → A の行は 0 件であるべき
select set_config('request.jwt.claim.sub', '<USER_B_UUID>', true);
select count(*) from public.folders;   -- => 0
```

> 注: `auth.uid()` は JWT の `sub` を読む。SQL エディタは通常 service_role で動くため RLS を貫通する。
> 上記は `set_config` で `request.jwt.claim.sub` を差し替えた擬似検証。厳密な RLS テストは
> anon key + 実セッションのクライアント（iPad/Web）または #10 の自動テストで担保する。

### updated_at 後勝ちトリガの確認

```sql
-- 明示指定した過去/未来の updated_at は保持される（クライアントの後勝ち判定を壊さない）
update public.folders set name = 'renamed', updated_at = '2999-01-01' where id = '<ID>';
select updated_at from public.folders where id = '<ID>';   -- => 2999-01-01（now() で潰されない）

-- updated_at 未指定の直接編集では now() が刻まれる
update public.folders set name = 'renamed2' where id = '<ID>';
select updated_at from public.folders where id = '<ID>';   -- => 現在時刻付近
```

### Storage の確認

`storage.md` の「検証」節を参照（認証ユーザーが自分の `{user_id}/...` にのみ up/download 可）。

---

## 6. スコープ外（次バッチ）

iPad SDK 導入 #4 / Magic Link 認証 #5 / Core Data マイグレーション #6 / SyncService #7 /
Blob 同期 #8 / UI #9 / テスト #10。詳細は `tasks/brainaddtask.md`。
