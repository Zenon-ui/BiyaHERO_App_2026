/* 
   BIYAHERO SERVICE WORKER
   - Caches map tiles so the map genuinely renders with no signal
     (not just the hazard/report data, which was already stored in
     localStorage before this change).
   - Caches the app shell (HTML/CSS/JS/Leaflet/fonts) so the app itself
     still loads with no signal, not just a blank tab.
   Bump SW_VERSION any time you change this file or the shell asset
   list — that's what triggers old caches to be cleaned up.
    */

const SW_VERSION   = "v16";
const SHELL_CACHE  = `biyahero-shell-${SW_VERSION}`;
// NOT derived from SW_VERSION, on purpose. BiyaHERO.js's bulk "Download
// Offline Map" flow writes tiles into a cache it opens itself
// (TILE_CACHE_NAME, currently 'biyahero-tiles-v1') independently of this
// file. If TILE_CACHE here were `biyahero-tiles-${SW_VERSION}`, bumping
// SW_VERSION for an ordinary shell/CSS deploy would silently point this
// file at a cache the user's already-downloaded tiles were never written
// to — they'd look "gone" until re-cached tile-by-tile while browsing.
// Shell assets are cheap to refetch, so those should roll over on every
// version bump; a user's multi-hundred-tile offline download should not.
// If the tile *format* itself ever needs a breaking change, bump this
// constant and BiyaHERO.js's TILE_CACHE_NAME together, deliberately.
const TILE_CACHE    = "biyahero-tiles-v1";

// Whole laguna.pmtiles archive for the WEB build (written by protomaps-map.js,
// WEB_CACHE_NAME there must match). Like TILE_CACHE it must survive
// SW_VERSION bumps and is exempt from the cleanup in "activate" below —
// otherwise every shell deploy would silently delete the offline map.
// Never intercepted in "fetch": the Cache API cannot store 206 range
// responses, and protomaps-map.js serves byte ranges from the stored blob.
const MAP_CACHE     = "biyahero-pmtiles-v1";

// Runtime cache counter for the "X tiles cached this session" readout in
// Settings. This only counts tiles newly written to TILE_CACHE while
// browsing (mostly zoom 15-17 — 10-14 is already pre-cached by the bulk
// "Download Offline Map" flow, so those come back as cache hits and don't
// increment this). It lives in SW memory, so it resets whenever the SW
// itself restarts (browser reclaims idle workers after ~30s of no
// activity) — an approximation of "this session," not a persisted total.
let sessionTilesCached = 0;

async function broadcastTileCount() {
  const clients = await self.clients.matchAll({ includeUncontrolled: true });
  clients.forEach((client) =>
    client.postMessage({ type: "TILE_CACHED", sessionTotal: sessionTilesCached })
  );
}

// Everything needed to render the app itself with zero network.
// Relative paths resolve against this file's own location.
const SHELL_ASSETS = [
  "./index.html",
  "./BiyaHERO.css",
  "./BiyaHERO.js",
  "./RoutingDatabase.js",
  "./AStarRouter.js",
  "./pmtiles.js",
  "./protomaps-map.js",
  "./manifest.json",
  "./icons/icon-192.png",
  "./icons/icon-512.png",
  "./icons/icon-512-maskable.png",
  "./supabase-config.js",
  "./traffic-config.js",
  // index.html now loads these three from ./vendor/ FIRST (see
  // copy-vendor.mjs) and only falls back to the unpkg copies below if that
  // local file 404s. Caching only the unpkg fallbacks — which is all this
  // list used to do — meant a repeat *offline* visit still tried to fetch
  // the vendor/ paths fresh over the network (not in SHELL_CACHE), failed,
  // fell back to unpkg, and failed there too with no connection: the exact
  // same "base map silently never draws" failure the vendor/ files exist to
  // prevent, just moved from first-load to every-load-after-reconnect.
  "./vendor/leaflet/leaflet.js",
  "./vendor/leaflet/leaflet.css",
  "./vendor/supabase/supabase.js",
  "./vendor/protomaps/protomaps-leaflet.js",
  "https://unpkg.com/@supabase/supabase-js@2/dist/umd/supabase.js",
  "https://unpkg.com/leaflet@1.9.4/dist/leaflet.css",
  "https://unpkg.com/leaflet@1.9.4/dist/leaflet.js",
  "https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@500;600;700&family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;500;600&display=swap"
];

// Must match the tile URL template used by L.tileLayer(...) in BiyaHERO.js.
function isTileRequest(url) {
  return url.hostname === "tile.openstreetmap.org";
}

self.addEventListener("install", (event) => {
  self.skipWaiting();
  event.waitUntil(
    caches.open(SHELL_CACHE).then((cache) =>
      // Cache each shell asset independently so one flaky CDN request
      // (e.g. Google Fonts on a slow connection) can't fail the whole
      // install and leave the app with nothing cached at all.
      Promise.all(
        SHELL_ASSETS.map(async (url) => {
          try {
            const resp = await fetch(url, { mode: "cors", cache: "reload" });
            // Skip anything cache.put will reject: non-2xx, redirects
            // (GitHub Pages / CDN rewrites), and 206 partial responses.
            if (!resp.ok || resp.redirected || resp.status === 206) {
              console.warn(
                "[BiyaHERO SW] Skipping shell asset:",
                url,
                "status=" + resp.status,
                resp.redirected ? "(redirected)" : ""
              );
              return;
            }
            await cache.put(url, resp);
          } catch (err) {
            console.warn(
              "[BiyaHERO SW] Failed to cache shell asset:",
              url,
              err.message
            );
          }
        })
      )
    )
  );
});
self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) =>
        Promise.all(
          keys
            .filter((k) => k !== SHELL_CACHE && k !== TILE_CACHE && k !== MAP_CACHE)
            .map((k) => caches.delete(k))
        )
      )
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (event) => {
  const req = event.request;
  const url = new URL(req.url);

  // ---- Map tiles: cache-first, then network, then cache the result ----
  if (isTileRequest(url)) {
    event.respondWith(
      (async () => {
        const cache = await caches.open(TILE_CACHE);
        const cached = await cache.match(req);
        if (cached) return cached;

        try {
          const resp = await fetch(req);
          // Standard OSM tiles don't send CORS headers, so cross-origin
          // <img> tile requests come back "opaque" (status/body hidden
          // from JS) — that's normal, and opaque responses are cacheable.
          if (resp && (resp.ok || resp.type === "opaque")) {
            // Clone BEFORE anything can consume the body, and await the
            // put so a failed write is caught here instead of surfacing
            // as an uncaught "Response body is already used" rejection.
            const toCache = resp.clone();
            try {
              await cache.put(req, toCache);
              sessionTilesCached++;
              broadcastTileCount();
            } catch (putErr) {
              console.warn("[BiyaHERO SW] Tile cache put failed:", putErr);
            }
          }
          return resp;
        } catch (err) {
          // Truly offline and this tile was never cached/downloaded —
          // nothing we can serve. Leaflet will just show a blank tile.
          return Response.error();
        }
      })()
    );
    return;
  }

  //  App shell: cache-first, refresh cache in the background 
  if (
    req.mode === "navigate" ||
    SHELL_ASSETS.some((a) => req.url === a || req.url.endsWith(a.replace("./", "")))
  ) {
    // Navigations can arrive with a query string we've never seen before -
    // manifest "shortcuts" (?shortcut=report) and "share_target" shares
    // (?share-title=...) both land on index.html this way. ignoreSearch
    // lets those still hit the single cached document instead of missing
    // the cache purely because of the query string.
    const isNav = req.mode === "navigate";
    const matchOpts = isNav ? { ignoreSearch: true } : undefined;
    event.respondWith(
      (async () => {
        let cached = await caches.match(req, matchOpts);
        // A navigation to the folder root ("/" or "/BiyaHERO/") has no cache
        // entry of its own - only "./index.html" was stored - so offline it
        // used to fail outright. Fall back to the cached app document.
        if (!cached && isNav) {
          cached = await caches.match(
            new URL("./index.html", self.registration.scope).href,
            { ignoreSearch: true }
          );
        }
        // cache:"reload" bypasses the browser's HTTP cache for this
        // background revalidation so a deployed fix actually reaches
        // SHELL_CACHE instead of the same stale response being re-stored.
        const network = fetch(req, { cache: "reload" })
          .then(async (resp) => {
            // Same guard as install: only cache what put() will accept.
            if (resp && resp.ok && !resp.redirected && resp.status !== 206) {
              try {
                const cache = await caches.open(SHELL_CACHE);
                await cache.put(req, resp.clone());
              } catch (err) {
                console.warn("[BiyaHERO SW] Shell cache put failed:", req.url, err.message);
              }
            }
            return resp;
          })
          .catch(() => cached || Response.error());
        if (cached) {
          // Serve instantly; let the refresh finish in the background.
          event.waitUntil(network.catch(() => {}));
          return cached;
        }
        return network;
      })()
    );
  }
});

self.addEventListener("message", (event) => {
  if (event.data && event.data.type === "SKIP_WAITING") self.skipWaiting();
});
