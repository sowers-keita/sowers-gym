-- 対象: sowers-gym / ihdrkukgeqqktzxmlrzy
-- メッセージ本文・送信者・請求情報・既存RLSは変更しない。
-- 先にこのSQLを適用し、その後 index.html を公開する。
begin;
set local lock_timeout = '5s';
alter table public.messages
  add column if not exists resolved_at timestamptz,
  add column if not exists resolved_by uuid;

-- 保護者の新規投稿には対応済み情報を持ち込ませない。
create or replace function public.gym_clear_new_message_resolution()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.resolved_at := null;
  new.resolved_by := null;
  return new;
end;
$$;
do $$
begin
  if not exists(select 1 from pg_trigger where tgname='gym_new_message_unresolved' and tgrelid='public.messages'::regclass) then
    create trigger gym_new_message_unresolved before insert on public.messages
      for each row execute function public.gym_clear_new_message_resolution();
  end if;
end;
$$;

create or replace function public.gym_set_message_resolved(p_message_id uuid,p_resolved boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_message public.messages%rowtype;
  v_actor public.profiles%rowtype;
  v_latest uuid;
begin
  if auth.uid() is null or p_resolved is null then
    raise exception 'ログイン状態を確認してください' using errcode='42501';
  end if;
  select * into v_actor from public.profiles where id=auth.uid();
  if v_actor.role is null or v_actor.role not in ('admin','staff') then
    raise exception '操作権限がありません' using errcode='42501';
  end if;
  select * into v_message from public.messages where id=p_message_id for update;
  if not found then raise exception '対象の連絡が見つかりません'; end if;
  if v_actor.role<>'admin' and not exists(
    select 1 from public.children c where c.parent_id=v_message.parent_id
      and c.program=v_actor.staff_program and c.region=v_actor.staff_region
  ) then raise exception '担当エリア外の連絡です' using errcode='42501'; end if;
  select id into v_latest from public.messages where parent_id=v_message.parent_id
    order by created_at desc nulls last,id desc limit 1;
  if v_message.sender<>'parent' or v_latest is distinct from p_message_id then
    raise exception '新しい連絡があります。画面を更新して確認してください';
  end if;
  update public.messages set
    resolved_at=case when p_resolved then coalesce(resolved_at,now()) else null end,
    resolved_by=case when p_resolved then coalesce(resolved_by,auth.uid()) else null end
    where id=p_message_id;
end;
$$;
revoke all on function public.gym_set_message_resolved(uuid,boolean) from public, anon;
grant execute on function public.gym_set_message_resolved(uuid,boolean) to authenticated;
commit;
-- 戻し方: 旧 index.html を再公開。追加列と関数は残しても既存処理に影響しない。
-- 既存の対応済み情報は消さずに保全する。
