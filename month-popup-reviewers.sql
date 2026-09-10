-- 教室ごとの確認担当者と翌月案内の確定権限。既存の予定・確定記録を保持する。
begin;
create table if not exists public.month_popup_reviewers (
 room text primary key check (room in ('論田','北島','吉野川','阿南','上板','小松島','上八万','八万中央')),
 user_id uuid not null references public.profiles(id),
 assigned_by uuid references public.profiles(id),
 updated_at timestamptz not null default now()
);
alter table public.month_popup_reviewers enable row level security;
revoke all on public.month_popup_reviewers from anon;
grant select,insert,update,delete on public.month_popup_reviewers to authenticated;
create policy month_reviewers_read on public.month_popup_reviewers for select to authenticated
 using (user_id=auth.uid() or public.is_admin());
create policy month_reviewers_manage on public.month_popup_reviewers for all to authenticated
 using (public.is_admin())
 with check (public.is_admin() and exists(select 1 from public.profiles p where p.id=user_id and p.role in ('admin','staff')));
create or replace function public.can_confirm_month_popup(p_room text,p_ym text)
returns boolean language sql stable security invoker set search_path=public as $$
 select auth.uid() is not null
 and exists(select 1 from public.profiles p where p.id=auth.uid() and p.role in ('admin','staff'))
 and exists(select 1 from public.month_popup_reviewers r where r.room=p_room and r.user_id=auth.uid())
 and extract(day from now() at time zone 'Asia/Tokyo')>=20
 and p_ym=to_char(date_trunc('month',now() at time zone 'Asia/Tokyo')+interval '1 month','YYYY-MM');
$$;
revoke all on function public.can_confirm_month_popup(text,text) from public;
grant execute on function public.can_confirm_month_popup(text,text) to authenticated;
-- 既存ポリシーを担当者と確認期間に限定する。SELECTのmc_selは変更しない。
alter policy mc_write on public.month_confirms
 using(public.can_confirm_month_popup(room,ym))
 with check(public.can_confirm_month_popup(room,ym) and confirmed_by=auth.uid());
commit;
