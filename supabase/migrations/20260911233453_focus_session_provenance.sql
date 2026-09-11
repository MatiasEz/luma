alter table public.focus_sessions add column if not exists origin text check (origin in ('focus','manual','rest'));
alter table public.focus_sessions add column if not exists updated_at timestamptz;
