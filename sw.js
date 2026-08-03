// sowers-gym（教室出席管理アプリ）通知専用 Service Worker
// fetchハンドラは持たない＝キャッシュ事故を起こさない（サークルアプリのsw.jsと同じ方針）

self.addEventListener('install', (e) => { self.skipWaiting(); });
self.addEventListener('activate', (e) => { e.waitUntil(self.clients.claim()); });

self.addEventListener('push', (event) => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; } catch (e) { data = {}; }
  const title = data.title || 'お知らせ';
  const body = data.body || '';
  const url = data.url || '/';
  const unread = data.unread || 1;

  const options = {
    body,
    icon: '/icon-192.png',
    badge: '/icon-192.png',
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
  const url = (event.notification.data && event.notification.data.url) || '/';
  event.waitUntil((async () => {
    try { if ('clearAppBadge' in self.navigator) await self.navigator.clearAppBadge(); } catch (e) {}
    const allClients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of allClients) {
      if ('focus' in c) { await c.focus(); return; }
    }
    if (self.clients.openWindow) await self.clients.openWindow(url);
  })());
});
