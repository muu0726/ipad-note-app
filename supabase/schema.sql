-- =============================================================================
-- 外部脳ノートアプリ Supabase スキーマ (Phase 1 / タスク #1・#2)
-- 出典: tasks/brainaddtask.md
--
-- 設計前提:
--   * 認証        : Supabase Auth Magic Link
--   * 同期        : Core Data 正本のローカルファースト + updated_at 後勝ち
--   * ユーザー分離: 全テーブルに user_id + RLS (auth.uid() = user_id)
--   * バイナリ    : blob 本体は列に入れず Storage パス参照のみ保持
--                   (実体は Storage バケット canvas-blobs。詳細は storage.md)
--
-- 主キー(id uuid)は Core Data の id をそのまま採用し、iPad <-> Web で同一 UUID。
-- kind / note_type は列挙型にせず自由 text で保持し、将来の種別追加に耐える。
--
-- 適用方法: Supabase SQL エディタに貼り付けて実行、または `supabase db reset`。
--           冪等に作り直せるよう、必要に応じて先頭で DROP してから流す。
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 共通: updated_at 自動刻印トリガ関数
--   後勝ち同期(#7)と両立させるため、クライアントが updated_at を明示指定した
--   update ではその値を尊重し、未指定(= OLD と同値)の直接編集のときだけ now() を刻む。
--   単純な NEW.updated_at = now() はクライアントの新しいタイムスタンプを潰し、
--   updated_at 後勝ち判定を壊すため使わない。
-- -----------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  if new.updated_at is not distinct from old.updated_at then
    new.updated_at := now();
  end if;
  return new;
end;
$$;

-- =============================================================================
-- folders  (Core Data: Folder / 自己参照ツリー)
-- =============================================================================
create table if not exists public.folders (
  id          uuid primary key,
  user_id     uuid not null references auth.users (id) on delete cascade,
  name        text,
  parent_id   uuid references public.folders (id) on delete cascade,
  sort_order  bigint      not null default 0,
  is_trashed  boolean     not null default false,
  trashed_at  timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists folders_user_id_idx   on public.folders (user_id);
create index if not exists folders_parent_id_idx on public.folders (parent_id);

-- =============================================================================
-- notes  (Core Data: NoteFile)
--   canvas_data_path / thumbnail_path / preview_png_path は Storage 参照。
--   canvasData(PKDrawing) / thumbnailData(JPEG) / Web 閲覧用 PNG に対応 (#8 で実装)。
-- =============================================================================
create table if not exists public.notes (
  id                   uuid primary key,
  user_id              uuid not null references auth.users (id) on delete cascade,
  folder_id            uuid references public.folders (id) on delete cascade,
  title                text,
  note_type            text        not null default 'infinite',  -- infinite / paged (自由text)
  page_color           text        not null default 'white',
  background_style     text        not null default 'blank',
  page_count           integer     not null default 1,
  bookmarked_pages     text,                                      -- JSON 文字列
  is_two_page_layout   boolean     not null default false,
  is_horizontal_scroll boolean     not null default false,
  hide_adjacent_pages  boolean     not null default false,
  is_trashed           boolean     not null default false,
  trashed_at           timestamptz,
  -- Storage パス参照 (blob 本体は入れない)
  canvas_data_path     text,
  thumbnail_path       text,
  preview_png_path     text,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

create index if not exists notes_user_id_idx   on public.notes (user_id);
create index if not exists notes_folder_id_idx on public.notes (folder_id);

-- =============================================================================
-- canvas_objects  (Core Data: CanvasObject)
--   kind は 9 種 (text/image/pdf/noteLink/todo/shape/table/stickyNote/connector)。
--   payload は kind により画像バイナリ or JSON。DB には payload_path のみ持ち、
--   実体判別・up/download は同期側(#8)で行う。
-- =============================================================================
create table if not exists public.canvas_objects (
  id               uuid primary key,
  user_id          uuid not null references auth.users (id) on delete cascade,
  note_id          uuid not null references public.notes (id) on delete cascade,
  kind             text             not null default 'text',   -- 自由text (9種)
  x                double precision not null default 0,
  y                double precision not null default 0,
  width            double precision not null default 0,
  height           double precision not null default 0,
  rotation         double precision not null default 0,
  font_size        double precision not null default 24,
  text             text,
  linked_note_uuid text,
  parent_group_id  uuid,
  z_order          bigint           not null default 0,
  is_locked        boolean          not null default false,   -- システムロック
  is_user_locked   boolean          not null default false,   -- ユーザーロック(南京錠)
  payload_path     text,                                       -- Storage 参照
  is_trashed       boolean          not null default false,    -- トゥームストーン統一のため付与
  created_at       timestamptz      not null default now(),
  updated_at       timestamptz      not null default now()
);

create index if not exists canvas_objects_user_id_idx on public.canvas_objects (user_id);
create index if not exists canvas_objects_note_id_idx on public.canvas_objects (note_id);

-- =============================================================================
-- note_outlines  (Core Data: NoteOutline / 目次)
--   Core Data 側に updatedAt は無いが、同期の後勝ち判定を統一するため updated_at を付与。
-- =============================================================================
create table if not exists public.note_outlines (
  id          uuid primary key,
  user_id     uuid not null references auth.users (id) on delete cascade,
  note_id     uuid not null references public.notes (id) on delete cascade,
  page_index  integer     not null default 0,
  title       text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists note_outlines_user_id_idx on public.note_outlines (user_id);
create index if not exists note_outlines_note_id_idx on public.note_outlines (note_id);

-- -----------------------------------------------------------------------------
-- updated_at トリガを 4 テーブルにアタッチ
-- -----------------------------------------------------------------------------
drop trigger if exists set_updated_at on public.folders;
create trigger set_updated_at before update on public.folders
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.notes;
create trigger set_updated_at before update on public.notes
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.canvas_objects;
create trigger set_updated_at before update on public.canvas_objects
  for each row execute function public.set_updated_at();

drop trigger if exists set_updated_at on public.note_outlines;
create trigger set_updated_at before update on public.note_outlines
  for each row execute function public.set_updated_at();

-- =============================================================================
-- Row Level Security: 自分の行だけ CRUD 可能 (auth.uid() = user_id)
-- =============================================================================
alter table public.folders        enable row level security;
alter table public.notes          enable row level security;
alter table public.canvas_objects enable row level security;
alter table public.note_outlines  enable row level security;

-- folders
drop policy if exists folders_select on public.folders;
create policy folders_select on public.folders
  for select using (auth.uid() = user_id);
drop policy if exists folders_insert on public.folders;
create policy folders_insert on public.folders
  for insert with check (auth.uid() = user_id);
drop policy if exists folders_update on public.folders;
create policy folders_update on public.folders
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists folders_delete on public.folders;
create policy folders_delete on public.folders
  for delete using (auth.uid() = user_id);

-- notes
drop policy if exists notes_select on public.notes;
create policy notes_select on public.notes
  for select using (auth.uid() = user_id);
drop policy if exists notes_insert on public.notes;
create policy notes_insert on public.notes
  for insert with check (auth.uid() = user_id);
drop policy if exists notes_update on public.notes;
create policy notes_update on public.notes
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists notes_delete on public.notes;
create policy notes_delete on public.notes
  for delete using (auth.uid() = user_id);

-- canvas_objects
drop policy if exists canvas_objects_select on public.canvas_objects;
create policy canvas_objects_select on public.canvas_objects
  for select using (auth.uid() = user_id);
drop policy if exists canvas_objects_insert on public.canvas_objects;
create policy canvas_objects_insert on public.canvas_objects
  for insert with check (auth.uid() = user_id);
drop policy if exists canvas_objects_update on public.canvas_objects;
create policy canvas_objects_update on public.canvas_objects
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists canvas_objects_delete on public.canvas_objects;
create policy canvas_objects_delete on public.canvas_objects
  for delete using (auth.uid() = user_id);

-- note_outlines
drop policy if exists note_outlines_select on public.note_outlines;
create policy note_outlines_select on public.note_outlines
  for select using (auth.uid() = user_id);
drop policy if exists note_outlines_insert on public.note_outlines;
create policy note_outlines_insert on public.note_outlines
  for insert with check (auth.uid() = user_id);
drop policy if exists note_outlines_update on public.note_outlines;
create policy note_outlines_update on public.note_outlines
  for update using (auth.uid() = user_id) with check (auth.uid() = user_id);
drop policy if exists note_outlines_delete on public.note_outlines;
create policy note_outlines_delete on public.note_outlines
  for delete using (auth.uid() = user_id);

-- =============================================================================
-- Storage: プライベートバケット canvas-blobs (タスク #2)
--   パス規約: {user_id}/{note_id}/{kind}
--   例: 3f..a1/9c..77/canvasData.bin, .../previewPng/1.png
--   RLS はパス先頭セグメント(= user_id)と auth.uid() を突き合わせてユーザー分離。
--   容量/圧縮/削除の運用方針は storage.md を参照。
-- =============================================================================
insert into storage.buckets (id, name, public)
values ('canvas-blobs', 'canvas-blobs', false)
on conflict (id) do nothing;

drop policy if exists canvas_blobs_select on storage.objects;
create policy canvas_blobs_select on storage.objects
  for select using (
    bucket_id = 'canvas-blobs'
    and auth.uid()::text = (storage.foldername(name))[1]
  );
drop policy if exists canvas_blobs_insert on storage.objects;
create policy canvas_blobs_insert on storage.objects
  for insert with check (
    bucket_id = 'canvas-blobs'
    and auth.uid()::text = (storage.foldername(name))[1]
  );
drop policy if exists canvas_blobs_update on storage.objects;
create policy canvas_blobs_update on storage.objects
  for update using (
    bucket_id = 'canvas-blobs'
    and auth.uid()::text = (storage.foldername(name))[1]
  );
drop policy if exists canvas_blobs_delete on storage.objects;
create policy canvas_blobs_delete on storage.objects
  for delete using (
    bucket_id = 'canvas-blobs'
    and auth.uid()::text = (storage.foldername(name))[1]
  );
