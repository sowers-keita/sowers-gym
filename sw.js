function gymNotificationUrl(value){try{const u=new URL(value||'/sowers-gym/',self.location.origin);return u.origin===self.location.origin&&u.pathname.startsWith('/sowers-gym/')?u.href:self.location.origin+'/sowers-gym/';}catch(e){return self.location.origin+'/sowers-gym/';}}
// sowers-gym（教室出席管理アプリ）通知専用 Service Worker
// fetchハンドラは持たない＝キャッシュ事故を起こさない（サークルアプリのsw.jsと同じ方針）

self.addEventListener('install', (e) => { self.skipWaiting(); });
self.addEventListener('activate', (e) => { e.waitUntil(self.clients.claim()); });

self.addEventListener('push', (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (e) { data = {}; }
  const title = data.title || 'お知らせ';
  const body = data.body || '';
  const url = gymNotificationUrl(data.url);
  const unread = data.unread || 1;

  const options = {
    body,
    icon: '/sowers-gym/icon-192.png',
    badge: '/sowers-gym/icon-192.png',
    data: { url },
    tag: data.tag || undefined,
  };

  event.waitUntil((async () => {
    try { if ('setAppBadge' in self.navigator) await self.navigator.setAppBadge(unread); } catch (e) {}
    await self.registration.showNotification(title, options);
  })());
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  const url = gymNotificationUrl(event.notification.data && event.notification.data.url);
  event.waitUntil((async () => {
    try { if ('clearAppBadge' in self.navigator) await self.navigator.clearAppBadge(); } catch (e) {}
    const allClients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of allClients) {
      if ('focus' in c && new URL(c.url).pathname.startsWith('/sowers-gym/')) { await c.focus(); return; }
    }
    if (self.clients.openWindow) await self.clients.openWindow(url);
  })());
});
