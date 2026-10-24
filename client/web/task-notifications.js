// This worker handles notification clicks only. Its separate scope leaves the
// Flutter app's asset/cache worker untouched; an open page receives task events.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('notificationclick', event => {
  event.notification.close();
  const data = event.notification.data;
  if (!data || typeof data.threadId !== 'string' || typeof data.session !== 'string') return;
  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({type: 'window', includeUncontrolled: true});
    const client = windows.find(window => new URL(window.url).origin === self.location.origin);
    if (client) {
      client.postMessage({type: 'open-task', threadId: data.threadId, session: data.session});
      await client.focus();
    } else {
      await self.clients.openWindow('/#notice=' + encodeURIComponent(data.threadId) + '&session=' + encodeURIComponent(data.session));
    }
  })());
});
