-- 2026-11-17 男子新体操 体験会をクラブアプリ（サワーズスポーツクラブ）にも出す
-- 定員は体操教室アプリと合算で15名。クラブからの申し込みは Edge Function「gym-event-kids」経由（service_role だけが実行できる関数）
-- 何度実行しても同じ結果になるように書いています。

-- 1) どのアプリに出すか（既定は体操教室アプリだけ）
alter table public.gym_events add column if not exists apps text[] not null default '{gym}';
update public.gym_events set apps = '{gym,club}' where id = 'rg-taiken-20261122';

-- 2) クラブ（外部アプリ）からの申し込み・変更
create or replace function public.gym_event_apply_kids_ext(p_event_id text, p_source text, p_ext_user text, p_parent_name text, p_kids jsonb, p_guests jsonb, p_note text)
returns public.gym_event_entries language plpgsql security definer set search_path to 'public' as $$
declare ev public.gym_events; mine public.gym_event_entries; r public.gym_event_entries; k jsonb;
  v_kids jsonb := '[]'::jsonb; v_guests jsonb := '[]'::jsonb; v_age int; v_n int; v_used int; v_wait boolean;
begin
  if coalesce(p_source,'') = '' or coalesce(p_ext_user,'') = '' then raise exception 'ログインし直してください'; end if;
  select * into ev from public.gym_events where id = p_event_id and cap_unit = 'kids' and p_source = any(apps) for update;
  if ev.id is null then raise exception 'イベントが見つかりません'; end if;
  if (now() at time zone 'Asia/Tokyo') >= (ev.date::date + ev.start_time::time) then raise exception '受付は終了しました'; end if;
  for k in select * from jsonb_array_elements(coalesce(p_kids,'[]'::jsonb)) loop
    v_age := nullif(k->>'age','')::int;
    if v_age is null or v_age < 0 or v_age > 99 then raise exception '%さんの年齢を選んでください', k->>'name'; end if;
    v_kids := v_kids || jsonb_build_array(jsonb_build_object('id',k->>'id','name',left(coalesce(k->>'name',''),30),'classroom',coalesce(nullif(k->>'classroom',''),'クラブ'),'class_name',coalesce(k->>'class_name',''),'age',v_age));
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

  select * into mine from public.gym_event_entries where event_id = ev.id and source = p_source and ext_user = p_ext_user
   order by (status = 'active') desc, created_at desc limit 1;
  select coalesce(sum(jsonb_array_length(kids) + jsonb_array_length(guests)),0) into v_used
    from public.gym_event_entries where event_id = ev.id and status = 'active' and not waitlist and id is distinct from mine.id;
  v_wait := v_used + v_n > ev.capacity;
  if mine.id is not null and mine.status = 'active' and not mine.waitlist and v_wait then
    raise exception '残りの枠が%名のため、この人数には変更できません', greatest(ev.capacity - v_used, 0); end if;

  if mine.id is null then
    insert into public.gym_event_entries(event_id, source, ext_user, parent_id, parent_name, kids, adults, guests, note, people, fee, pay_method, pay_status, status, waitlist)
    values (ev.id, p_source, p_ext_user, null, left(coalesce(p_parent_name,''),40), v_kids, 0, v_guests, left(coalesce(p_note,''),300), v_n, 0, 'cash', 'unpaid', 'active', v_wait)
    returning * into r;
  elsif mine.status = 'active' then
    update public.gym_event_entries set kids = v_kids, guests = v_guests, note = left(coalesce(p_note,''),300), people = v_n, adults = 0,
      parent_name = left(coalesce(p_parent_name,''),40),
      waitlist = case when mine.waitlist then v_wait else false end,
      promoted_at = case when mine.waitlist and not v_wait then now() else promoted_at end, updated_at = now()
      where id = mine.id returning * into r;
  else
    update public.gym_event_entries set status = 'active', cancelled_at = null, kids = v_kids, guests = v_guests, note = left(coalesce(p_note,''),300),
      people = v_n, adults = 0, fee = 0, waitlist = v_wait, promoted_at = null, attend = null, attend_at = null, parent_name = left(coalesce(p_parent_name,''),40),
      created_at = now(), updated_at = now()
      where id = mine.id returning * into r;
  end if;
  return r;
end $$;

create or replace function public.gym_event_cancel_kids_ext(p_event_id text, p_source text, p_ext_user text) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  update public.gym_event_entries set status = 'cancelled', cancelled_at = now(), updated_at = now()
   where event_id = p_event_id and source = p_source and ext_user = p_ext_user and status = 'active';
end $$;

create or replace function public.gym_event_attend_kids_ext(p_event_id text, p_source text, p_ext_user text) returns void
language plpgsql security definer set search_path to 'public' as $$
begin
  update public.gym_event_entries set attend = 'yes', attend_at = now(), updated_at = now()
   where event_id = p_event_id and source = p_source and ext_user = p_ext_user and status = 'active' and not waitlist;
end $$;

revoke all on function public.gym_event_apply_kids_ext(text,text,text,text,jsonb,jsonb,text), public.gym_event_cancel_kids_ext(text,text,text),
  public.gym_event_attend_kids_ext(text,text,text) from public, anon, authenticated;
grant execute on function public.gym_event_apply_kids_ext(text,text,text,text,jsonb,jsonb,text), public.gym_event_cancel_kids_ext(text,text,text),
  public.gym_event_attend_kids_ext(text,text,text) to service_role;

-- 確認用（1行出ればOK）
select id, apps, capacity from public.gym_events where id = 'rg-taiken-20261122';
