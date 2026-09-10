-- 管理者から特定のスタッフに氏名確認を依頼する。回答で表示名は変更しない。
begin;
create table if not exists public.staff_identity_checks (
 user_id uuid primary key references public.profiles(id),
 proposed_name text not null,
 status text not null default 'pending' check(status in ('pending','confirmed','rejected')),
 answered_at timestamptz,
 created_at timestamptz not null default now()
);
alter table public.staff_identity_checks enable row level security;
revoke all on public.staff_identity_checks from anon,authenticated;
grant select on public.staff_identity_checks to authenticated;
create policy staff_identity_read on public.staff_identity_checks for select to authenticated
 using(user_id=auth.uid() or public.is_admin());
create or replace function public.respond_staff_identity_check(p_confirm boolean)
returns void language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null or p_confirm is null then raise exception 'Authentication and answer required'; end if;
 update public.staff_identity_checks
 set status=case when p_confirm then 'confirmed' else 'rejected' end,answered_at=now()
 where user_id=auth.uid() and status='pending';
end;
$$;
revoke all on function public.respond_staff_identity_check(boolean) from public;
grant execute on function public.respond_staff_identity_check(boolean) to authenticated;
commit;
