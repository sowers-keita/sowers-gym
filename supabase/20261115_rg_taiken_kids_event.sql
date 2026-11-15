-- 2026-11-15 男子新体操 体験会（11/22 小松島高校）
-- ・子どもの人数で先着15名（超えたらキャンセル待ち → 空きが出たら古い順に自動で繰り上げ）
-- ・申込は子どもの名前と年齢だけ（保護者・大人は書かない／無料）
-- ・前日に「参加します」の出欠確認
-- ・体操教室アプリ（徳島の教室の家庭）だけに表示。クラブ・サークルアプリには出さない（gym_only・published=false）
-- 何度実行しても同じ結果になるように書いています。

-- 1) 列の追加
alter table public.gym_events add column if not exists cap_unit text not null default 'group';  -- 'group'＝組で数える（従来） / 'kids'＝子どもの人数で数える
alter table public.gym_events add column if not exists gym_only boolean not null default false; -- true＝体操教室アプリだけに出す
alter table public.gym_event_entries add column if not exists waitlist boolean not null default false; -- キャンセル待ち
alter table public.gym_event_entries add column if not exists promoted_at timestamptz;              -- キャンセル待ちから繰り上がった時刻
alter table public.gym_event_entries add column if not exists attend text;                          -- 前日の出欠確認 'yes'
alter table public.gym_event_entries add column if not exists attend_at timestamptz;

-- 2) gym_only のイベントはログイン中の利用者が読める（published=false のままでも体操教室アプリに出す）
drop policy if exists gym_events_gym_only_read on public.gym_events;
create policy gym_events_gym_only_read on public.gym_events for select to authenticated using (gym_only);

-- 3) 申し込み・変更（子どもの人数で先着／超えたらキャンセル待ち）
create or replace function public.gym_event_apply_kids_v1(p_event_id text, p_kids jsonb, p_guests jsonb, p_note text)
returns public.gym_event_entries language plpgsql security definer set search_path to 'public' as $$
declare ev public.gym_events; mine public.gym_event_entries; r public.gym_event_entries; c public.children; k jsonb;
  v_kids jsonb := '[]'::jsonb; v_guests jsonb := '[]'::jsonb; v_age int; v_n int; v_used int; v_wait boolean; v_name text; v_today date;
begin
  if auth.uid() is null then raise exception 'ログインし直してください'; end if;
  select * into ev from public.gym_events where id = p_event_id and (published or gym_only) and cap_unit = 'kids' for update;
  if ev.id is null then raise exception 'イベントが見つかりません'; end if;
  if (now() at time zone 'Asia/Tokyo') >= (ev.date::date + ev.start_time::time) then raise exception '受付は終了しました'; end if;
  if not exists (select 1 from public.children where parent_id = auth.uid() and region = ev.region and coalesce(status,'active') <> 'withdrawn') then
    raise exception 'このイベントは%の教室に在籍しているご家庭が対象です', ev.region; end if;
  v_today := (now() at time zone 'Asia/Tokyo')::date;
  for k in select * from jsonb_array_elements(coalesce(p_kids,'[]'::jsonb)) loop
    select * into c from public.children where id = (k->>'id')::uuid and parent_id = auth.uid();
    if c.id is null then continue; end if;
    v_age := case when c.birth is not null then date_part('year', age(v_today, c.birth::date))::int else nullif(k->>'age','')::int end;
    if v_age is null or v_age < 0 or v_age > 99 then raise exception '%さんの年齢を選んでください', c.name; end if;
    v_kids := v_kids || jsonb_build_array(jsonb_build_object('id',c.id,'name',c.name,'classroom',c.classroom,'class_name',c.class_name,'age',v_age));
  end loop;
  for k in select * from jsonb_array_elements(coalesce(p_guests,'[]'::jsonb)) loop
    if btrim(coalesce(k->>'name','')) = '' then raise exception '追加したお子さまの名前を入れてください'; end if;
    v_age := nullif(k->>'age','')::int;
    if v_age is null or v_age < 0 or v_age > 99 then raise exception '%さんの年齢を選んでください', btrim(k->>'name'); end if;
    v_guests := v_guests || jsonb_build_array(jsonb_build_object('name',left(btrim(k->>'name'),30),'age',v_age));
  end loop;
  if jsonb_array_length(v_guests) > 6 then raise exception '追加できるお子さまは6人までです'; end if;
  v_n := jsonb_array_length(v_kids) + jsonb_array_length(v_guests);
  if v_n < 1 then raise exception '参加するお子さまを選んでください'; end if;

  -- このご家庭の行（取り消し済みも含めて最新の1行を使い回す）
  select * into mine from public.gym_event_entries where event_id = ev.id and parent_id = auth.uid() order by (status = 'active') desc, created_at desc limit 1;
  select coalesce(sum(jsonb_array_length(kids) + jsonb_array_length(guests)),0) into v_used
    from public.gym_event_entries where event_id = ev.id and status = 'active' and not waitlist and id is distinct from mine.id;
  v_wait := v_used + v_n > ev.capacity;
  if mine.id is not null and mine.status = 'active' and not mine.waitlist and v_wait then
    raise exception '残りの枠が%名のため、この人数には変更できません', greatest(ev.capacity - v_used, 0); end if;
  select parent_name into v_name from public.profiles where id = auth.uid();

  if mine.id is null then
    insert into public.gym_event_entries(event_id, source, ext_user, parent_id, parent_name, kids, adults, guests, note, people, fee, pay_method, pay_status, status, waitlist)
    values (ev.id, 'gym', auth.uid()::text, auth.uid(), coalesce(v_name,''), v_kids, 0, v_guests, left(coalesce(p_note,''),300), v_n, 0, 'cash', 'unpaid', 'active', v_wait)
    returning * into r;
  elsif mine.status = 'active' then
    update public.gym_event_entries set kids = v_kids, guests = v_guests, note = left(coalesce(p_note,''),300), people = v_n, adults = 0,
      waitlist = case when mine.waitlist then v_wait else false end,
      promoted_at = case when mine.waitlist and not v_wait then now() else promoted_at end, updated_at = now()
      where id = mine.id returning * into r;
  else -- 取り消した後の申し込み直し＝最後尾に並び直す
    update public.gym_event_entries set status = 'active', cancelled_at = null, kids = v_kids, guests = v_guests, note = left(coalesce(p_note,''),300),
      people = v_n, adults = 0, fee = 0, waitlist = v_wait, promoted_at = null, attend = null, attend_at = null, parent_name = coalesce(v_name,''),
      created_at = now(), updated_at = now()
      where id = mine.id returning * into r;
  end if;
  return r;
end $$;

-- 4) 空きが出たらキャンセル待ちを古い順に繰り上げ（入りきらない人が出たらそこで止める＝順番を守る）
create or replace function public.gym_event_promote(p_event_id text) returns void language plpgsql security definer set search_path to 'public' as $$
declare ev public.gym_events; v_used int; e record;
begin
  select * into ev from public.gym_events where id = p_event_id for update;
  if ev.id is null or ev.cap_unit <> 'kids' then return; end if;
  select coalesce(sum(jsonb_array_length(kids) + jsonb_array_length(guests)),0) into v_used
    from public.gym_event_entries where event_id = p_event_id and status = 'active' and not waitlist;
  for e in select id, jsonb_array_length(kids) + jsonb_array_length(guests) as n from public.gym_event_entries
           where event_id = p_event_id and status = 'active' and waitlist order by created_at loop
    exit when v_used + e.n > ev.capacity;
    update public.gym_event_entries set waitlist = false, promoted_at = now(), updated_at = now() where id = e.id;
    v_used := v_used + e.n;
  end loop;
end $$;

create or replace function public.gym_event_entries_promote_trg() returns trigger language plpgsql security definer set search_path to 'public' as $$
begin
  if not old.waitlist and old.status = 'active' and (
       new.status <> 'active'
    or jsonb_array_length(new.kids) + jsonb_array_length(new.guests) < jsonb_array_length(old.kids) + jsonb_array_length(old.guests)) then
    perform public.gym_event_promote(new.event_id);
  end if;
  return null;
end $$;
drop trigger if exists gym_event_entries_promote on public.gym_event_entries;
create trigger gym_event_entries_promote after update on public.gym_event_entries for each row execute function public.gym_event_entries_promote_trg();

-- 5) 取り消し（保護者本人／管理者・スタッフ）
create or replace function public.gym_event_cancel_kids_v1(p_event_id text) returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is null then raise exception 'ログインし直してください'; end if;
  update public.gym_event_entries set status = 'cancelled', cancelled_at = now(), updated_at = now()
   where event_id = p_event_id and parent_id = auth.uid() and status = 'active';
end $$;
create or replace function public.gym_event_cancel_entry_v1(p_entry_id uuid) returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if not public.is_staff_or_admin() then raise exception '権限がありません'; end if;
  update public.gym_event_entries set status = 'cancelled', cancelled_at = now(), updated_at = now() where id = p_entry_id and status = 'active';
end $$;

-- 6) 前日の出欠確認「参加します」
create or replace function public.gym_event_attend_v1(p_event_id text) returns void language plpgsql security definer set search_path to 'public' as $$
begin
  if auth.uid() is null then raise exception 'ログインし直してください'; end if;
  update public.gym_event_entries set attend = 'yes', attend_at = now(), updated_at = now()
   where event_id = p_event_id and parent_id = auth.uid() and status = 'active' and not waitlist;
end $$;

-- 7) 子どもの人数（参加確定／キャンセル待ち）。人数そのものは画面で10名を超えるまで出さない
create or replace function public.gym_event_kid_counts() returns table(event_id text, kids int, waiting int)
language sql stable security definer set search_path to 'public' as $$
  select e.event_id,
         coalesce(sum(case when not e.waitlist then jsonb_array_length(e.kids) + jsonb_array_length(e.guests) end),0)::int,
         coalesce(sum(case when e.waitlist then jsonb_array_length(e.kids) + jsonb_array_length(e.guests) end),0)::int
    from public.gym_event_entries e join public.gym_events g on g.id = e.event_id
   where g.cap_unit = 'kids' and e.status = 'active' group by e.event_id $$;

revoke all on function public.gym_event_apply_kids_v1(text,jsonb,jsonb,text), public.gym_event_promote(text), public.gym_event_cancel_kids_v1(text),
  public.gym_event_cancel_entry_v1(uuid), public.gym_event_attend_v1(text), public.gym_event_kid_counts() from public, anon;
grant execute on function public.gym_event_apply_kids_v1(text,jsonb,jsonb,text), public.gym_event_cancel_kids_v1(text),
  public.gym_event_cancel_entry_v1(uuid), public.gym_event_attend_v1(text), public.gym_event_kid_counts() to authenticated;

-- 8) イベント本体
insert into public.gym_events (id, title, emoji, date, start_time, end_time, place, target, fee_base, fee_add, capacity, bring, body, region, published, gym_only, cap_unit)
values ('rg-taiken-20261122', '男子新体操 体験会', '🤸', '2026-11-22', '11:00', '12:00', '小松島高校 多目的ホール',
        '男女どなたでも（小学生からがおすすめ）', 0, 0, 15, '動きやすい服装・飲み物',
        '柔軟や手具操作、マット運動などを体験できます。小松島高校の男子新体操（小松島RG）の体験会です。時間は11時ごろ〜12時ごろの予定です。',
        '徳島', false, true, 'kids')
on conflict (id) do update set title = excluded.title, emoji = excluded.emoji, date = excluded.date, start_time = excluded.start_time,
  end_time = excluded.end_time, place = excluded.place, target = excluded.target, fee_base = 0, fee_add = 0, capacity = excluded.capacity,
  bring = excluded.bring, body = excluded.body, region = excluded.region, published = false, gym_only = true, cap_unit = 'kids';

-- 確認用（1行出ればOK）
select id, title, date, capacity, gym_only, cap_unit from public.gym_events where id = 'rg-taiken-20261122';
