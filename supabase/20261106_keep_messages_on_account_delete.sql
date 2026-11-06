-- 2026-11-06 保護者が「アカウントを削除（退会）」しても、事務局がメッセージ・記録を確認できるようにする（木原指示）
-- これまで：delete_my_account が messages・children・profiles・auth.users を完全削除していた
-- これから：データは消さずに「退会済み」として残し、ログインだけできなくする
--   ・お子様は退会済み（withdrawn）に、保護者に deleted_at を記録
--   ・事務局の連絡一覧に【自動】の退会メッセージが「未返信」で届く
--   ・アプリ決済の契約が続いている場合は、先にマイページの「退会する」をしてもらう（Stripeの請求が残らないように）
begin;
alter table public.profiles add column if not exists deleted_at timestamptz;

create or replace function public.delete_my_account()
returns void language plpgsql security definer set search_path to 'public' as $$
declare
  uid uuid := auth.uid();
  n integer;
begin
  if uid is null then raise exception 'ログインが必要です'; end if;
  select count(*) into n from public.pay_subscriptions
   where parent_id = uid and status in ('active','past_due','trialing','incomplete');
  if n > 0 then
    raise exception 'お月謝のアプリ決済が続いています。先にマイページの「退会する」から退会のお手続きをしてください';
  end if;
  update public.children
     set status = 'withdrawn',
         withdrawn_at = coalesce(withdrawn_at, now()),
         last_month = coalesce(last_month, to_char(now() at time zone 'Asia/Tokyo', 'YYYY-MM'))
   where parent_id = uid and coalesce(status,'') <> 'withdrawn';
  update public.profiles set deleted_at = now() where id = uid;
  insert into public.messages(parent_id, sender, body)
  values (uid, 'parent', '【自動】保護者がアプリからアカウントを削除しました（退会のお申し出）。');
  -- ユーザーは消さずにログインだけ止める（消すと記録が連鎖して削除されるため）
  update auth.users set banned_until = 'infinity' where id = uid;
  delete from auth.sessions where user_id = uid;
  delete from auth.refresh_tokens where user_id = uid::text;
end $$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
commit;
