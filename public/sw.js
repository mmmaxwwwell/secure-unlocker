const CACHE_VERSION = 'v2';

self.addEventListener('install', () => {
  self.skipWaiting();
});

self.addEventListener('activate', () => {
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  // No caching - always fetch from network
  event.respondWith(fetch(event.request));
});
