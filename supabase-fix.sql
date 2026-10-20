-- Run once in Supabase: SQL Editor > New query > paste all > Run. Safe to re-run.

-- 1) votes table (matches whatever type submissions.id is)
do $$
declare t text;
begin
  select format_type(atttypid, atttypmod) into t
  from pg_attribute
  where attrelid = 'public.submissions'::regclass and attname = 'id' and not attisdropped;
  execute format($f$
    create table if not exists public.votes (
      id bigint generated always as identity primary key,
      submission_id %s not null references public.submissions(id) on delete cascade,
      voter_id text not null,
      created_at timestamptz default now(),
      unique (submission_id, voter_id)
    )$f$, t);
end $$;

-- 2) counter column
alter table public.submissions add column if not exists votes integer not null default 0;

-- 3) trigger keeps the counter in sync
create or replace function public.bump_votes() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    update public.submissions set votes = votes + 1 where id = new.submission_id;
  elsif tg_op = 'DELETE' then
    update public.submissions set votes = greatest(votes - 1, 0) where id = old.submission_id;
  end if;
  return null;
end $$;

drop trigger if exists votes_count on public.votes;
create trigger votes_count after insert or delete on public.votes
for each row execute function public.bump_votes();

update public.submissions s
set votes = (select count(*) from public.votes v where v.submission_id = s.id);

-- 4) permissions
alter table public.votes enable row level security;
drop policy if exists "anyone can vote" on public.votes;
create policy "anyone can vote" on public.votes for insert to anon, authenticated with check (true);
drop policy if exists "anyone can read votes" on public.votes;
create policy "anyone can read votes" on public.votes for select to anon, authenticated using (true);

-- 5) unlimited submissions: remove any unique rules on submissions (except the primary key)
do $$
declare r record;
begin
  for r in select conname from pg_constraint
           where conrelid = 'public.submissions'::regclass and contype = 'u' loop
    execute format('alter table public.submissions drop constraint %I', r.conname);
  end loop;
  for r in select indexname from pg_indexes
           where schemaname = 'public' and tablename = 'submissions'
             and indexdef ilike 'create unique index%' and indexname not like '%pkey' loop
    execute format('drop index public.%I', r.indexname);
  end loop;
end $$;

-- 6) students can delete their own case
alter table public.submissions add column if not exists owner_hash text;

drop function if exists public.delete_my_case(uuid, text);
create or replace function public.delete_my_case(p_id text, p_token text) returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from public.submissions
  where id::text = p_id
    and owner_hash is not null
    and owner_hash = encode(sha256(convert_to(p_token, 'utf8')), 'hex');
  if not found then
    raise exception 'Not allowed to delete this case';
  end if;
end $$;
grant execute on function public.delete_my_case(text, text) to anon, authenticated;

-- 7) refresh Supabase's cache so the new table is seen straight away
notify pgrst, 'reload schema';

-- 8) UNDO A VOTE
create or replace function public.remove_my_vote(p_sub text, p_voter text) returns void
language plpgsql security definer set search_path = public as $$
begin
  delete from public.votes where submission_id::text = p_sub and voter_id = p_voter;
end $$;
grant execute on function public.remove_my_vote(text, text) to anon, authenticated;

-- keep voter ids private (the site does not need to read the votes table)
drop policy if exists "anyone can read votes" on public.votes;
notify pgrst, 'reload schema';

-- 9) STUDENT ID NUMBERS (visible to faculty only)
do $$
declare t text;
begin
  select format_type(atttypid, atttypmod) into t
  from pg_attribute
  where attrelid = 'public.submissions'::regclass and attname = 'id' and not attisdropped;
  execute format($f$
    create table if not exists public.case_ids (
      submission_id %s primary key references public.submissions(id) on delete cascade,
      student_id text not null,
      created_at timestamptz default now()
    )$f$, t);
end $$;

alter table public.case_ids enable row level security;
drop policy if exists "anyone can add id" on public.case_ids;
create policy "anyone can add id" on public.case_ids for insert to anon, authenticated with check (true);
drop policy if exists "faculty read ids" on public.case_ids;
create policy "faculty read ids" on public.case_ids for select to authenticated using (true);
notify pgrst, 'reload schema';
