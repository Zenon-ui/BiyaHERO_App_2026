// offline-tiles.js  (v5: no global-L dependency, network circuit breaker, fast timeouts)
// ---------------------------------------------------------------------------
// Offline map tiles for BiyaHERO inside Capacitor (Android / iOS).
//
// WHY THIS EXISTS
//   The web build serves cached tiles through a service worker (sw.js).
//   Capacitor builds disable the service worker, so tiles saved in Cache
//   Storage were never served and the offline map came up blank.
//   Reading cached tiles from the page itself also fails for "no-cors"
//   (opaque) responses, because their bytes can't be read.
//
// HOW IT WORKS
//   * Tiles are downloaded as real bytes using the native HTTP stack
//     (CapacitorHttp), which is not subject to CORS, and stored as Blobs in
//     IndexedDB (database "biyahero_tiles").
//   * A Leaflet TileLayer subclass reads tiles from that store first. If a
//     tile is missing it tries the network (and caches the result), and if
//     that fails it builds a stretched tile from a lower-zoom cached
//     ancestor so the map never goes completely blank offline.
//   * On plain web (not native) nothing changes: `enabled` is false and
//     createTileLayer() returns a normal L.tileLayer, so sw.js keeps working.
//
// USAGE (see BiyaHERO-fix-list.md, Part D)
//   import './offline-tiles.js';            // top of BiyaHERO.js
//   BiyaOfflineTiles.createTileLayer(url, opts).addTo(map);
//   await BiyaOfflineTiles.download(urls, onProgress);
//   await BiyaOfflineTiles.clear();
// ---------------------------------------------------------------------------
(function () {
  'use strict';

  const DB_NAME = 'biyahero_tiles';
  const DB_VERSION = 1;
  const STORE = 'tiles';

  const MIN_CACHED_ZOOM = 10;   // keep equal to OFFLINE_ZOOM_MIN in BiyaHERO.js
  const MAX_OVERZOOM = 4;       // how many zoom levels to stretch a parent tile
  const USER_AGENT = 'BiyaHERO/1.0 (offline tile cache)';
  const BLANK_GIF =
    'data:image/gif;base64,R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw==';

  /* ---------- platform detection ---------- */

  function isNativePlatform() {
    const c = window.Capacitor;
    if (!c) return false;
    if (typeof c.isNativePlatform === 'function') return c.isNativePlatform();
    return typeof c.getPlatform === 'function' && c.getPlatform() !== 'web';
  }

  const state = {
    // Set window.BIYA_FORCE_IDB_TILES = true before this file loads to test
    // the IndexedDB path in a desktop browser (needs CORS-friendly tiles).
    enabled: isNativePlatform() || window.BIYA_FORCE_IDB_TILES === true
  };

  /* ---------- IndexedDB tile store ---------- */

  let dbPromise = null;

  function openDb() {
    if (dbPromise) return dbPromise;
    dbPromise = new Promise((resolve, reject) => {
      if (!window.indexedDB) {
        reject(new Error('IndexedDB is not available.'));
        return;
      }
      const req = indexedDB.open(DB_NAME, DB_VERSION);
      req.onupgradeneeded = () => {
        if (!req.result.objectStoreNames.contains(STORE)) {
          req.result.createObjectStore(STORE); // key = tile URL
        }
      };
      req.onsuccess = () => resolve(req.result);
      req.onerror = () => reject(req.error);
    });
    dbPromise.catch(() => { dbPromise = null; }); // allow a retry next call
    return dbPromise;
  }

  // Runs fn(store) inside one transaction and resolves with the IDBRequest
  // result once the transaction has fully committed.
  function withStore(mode, fn) {
    return openDb().then(db => new Promise((resolve, reject) => {
      const tx = db.transaction(STORE, mode);
      let request;
      try {
        request = fn(tx.objectStore(STORE));
      } catch (err) {
        reject(err);
        return;
      }
      tx.oncomplete = () => {
        resolve(request && request.readyState === 'done' ? request.result : undefined);
      };
      tx.onerror = () => reject(tx.error);
      tx.onabort = () => reject(tx.error);
    }));
  }

  const store = {
    async get(url) {
      const rec = await withStore('readonly', s => s.get(url));
      return rec ? rec.blob : null;
    },
    async has(url) {
      const n = await withStore('readonly', s => s.count(url));
      return n > 0;
    },
    async put(url, blob) {
      await withStore('readwrite', s => s.put({ blob, savedAt: Date.now() }, url));
    },
    async clear() {
      await withStore('readwrite', s => s.clear());
    },
    // Real tile count and byte size (replaces the AVG_TILE_BYTES guess).
    stats() {
      return openDb().then(db => new Promise((resolve, reject) => {
        let count = 0;
        let bytes = 0;
        const req = db.transaction(STORE, 'readonly').objectStore(STORE).openCursor();
        req.onsuccess = () => {
          const cursor = req.result;
          if (!cursor) { resolve({ count, bytes }); return; }
          count++;
          bytes += (cursor.value && cursor.value.blob && cursor.value.blob.size) || 0;
          cursor.continue();
        };
        req.onerror = () => reject(req.error);
      }));
    }
  };

  /* ---------- fetching tile bytes ---------- */

  let httpPluginPromise = null;

  // CapacitorHttp is a core plugin. Prefer the global the native runtime
  // injects; fall back to the bundled package.
  //
  // IMPORTANT: this resolves to a WRAPPER ({ plugin }), never to the plugin
  // itself. Capacitor plugin objects are proxies that throw
  // '"X.then()" is not implemented on android' when a Promise tries to
  // resolve with them (Promises probe every value for a .then method).
  function getHttpPlugin() {
    if (!isNativePlatform()) return Promise.resolve({ plugin: null });
    if (httpPluginPromise) return httpPluginPromise;
    httpPluginPromise = (async () => {
      const direct = window.Capacitor && window.Capacitor.Plugins &&
        window.Capacitor.Plugins.CapacitorHttp;
      if (direct) return { plugin: direct };
      try {
        const mod = await import('@capacitor/core');
        return { plugin: mod.CapacitorHttp || null };
      } catch (err) {
        return { plugin: null };
      }
    })();
    return httpPluginPromise;
  }

  function base64ToBlob(b64, type) {
    const clean = String(b64).replace(/^data:[^;]+;base64,/, '');
    const bin = atob(clean);
    const bytes = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    return new Blob([bytes], { type: type || 'image/png' });
  }

  // ---- network circuit breaker --------------------------------------
  // navigator.onLine is unreliable on Android: on Wi-Fi with no internet it
  // still says "online", and every tile request then waits out a long
  // timeout, leaving the map blank for ages. After a few consecutive
  // failures we treat the network as down for a short while: cached tiles
  // (and stretched parent tiles) show instantly and nothing waits on a dead
  // connection. Any success, or the browser's "online" event, resets it.
  const net = { failures: 0, offlineUntil: 0 };

  function networkLikelyUp() {
    return navigator.onLine !== false && Date.now() >= net.offlineUntil;
  }
  function noteNetworkResult(ok) {
    if (ok) {
      net.failures = 0;
      net.offlineUntil = 0;
    } else if (++net.failures >= 3) {
      net.failures = 0;
      net.offlineUntil = Date.now() + 20000;
    }
  }
  if (typeof window.addEventListener === 'function') {
    window.addEventListener('online', () => { net.failures = 0; net.offlineUntil = 0; });
  }

  // opts.fast = true for on-demand tiles while panning (short timeouts);
  // bulk downloads use the longer defaults.
  async function fetchTileBlob(url, opts) {
    const fast = !!(opts && opts.fast);

    // 1) Native HTTP: no CORS, returns binary as a base64 string.
    const { plugin: http } = await getHttpPlugin();
    if (http && typeof http.get === 'function') {
      const res = await http.get({
        url,
        responseType: 'blob',
        headers: { 'User-Agent': USER_AGENT, Accept: 'image/png,image/*;q=0.8' },
        connectTimeout: fast ? 4000 : 10000,
        readTimeout: fast ? 6000 : 15000
      });
      if (res.status !== 200 || typeof res.data !== 'string' || !res.data.length) {
        throw new Error('Tile request failed (HTTP ' + res.status + ')');
      }
      const headers = res.headers || {};
      const type = headers['Content-Type'] || headers['content-type'] || 'image/png';
      return base64ToBlob(res.data, type);
    }

    // 2) Ordinary CORS fetch (works only if the tile server allows it).
    const controller = typeof AbortController === 'function' ? new AbortController() : null;
    const timer = controller ? setTimeout(() => controller.abort(), fast ? 6000 : 15000) : null;
    try {
      const resp = await fetch(url, {
        mode: 'cors',
        cache: 'no-store',
        signal: controller ? controller.signal : undefined
      });
      if (!resp.ok) throw new Error('Tile request failed (HTTP ' + resp.status + ')');
      if (resp.type === 'opaque') throw new Error('Tile response is opaque (blocked by CORS).');
      const blob = await resp.blob();
      if (!blob.size) throw new Error('Tile response was empty.');
      return blob;
    } finally {
      if (timer) clearTimeout(timer);
    }
  }

  async function fetchTileBlobWithRetry(url) {
    try {
      return await fetchTileBlob(url);
    } catch (firstErr) {
      await new Promise(r => setTimeout(r, 400));
      return fetchTileBlob(url); // one retry, then let the error surface
    }
  }

  /* ---------- bulk download (same signature as downloadTilesWithProgress) ---------- */

  async function download(urls, onProgress, opts) {
    const concurrency = (opts && opts.concurrency) || 6;
    const total = urls.length;
    let done = 0;
    let failed = 0;
    let cachedAlready = 0;
    let idx = 0;
    let firstError = null;

    function report() {
      if (typeof onProgress === 'function') {
        onProgress({ done, total, failed, cachedAlready });
      }
    }

    async function worker() {
      while (idx < total) {
        const url = urls[idx++];
        try {
          if (await store.has(url)) {
            cachedAlready++;
          } else {
            const blob = await fetchTileBlobWithRetry(url);
            await store.put(url, blob);
          }
        } catch (err) {
          failed++;
          if (!firstError) firstError = err;
        }
        done++;
        report();
      }
    }

    // Ask the OS not to evict our storage under pressure (best effort).
    if (navigator.storage && typeof navigator.storage.persist === 'function') {
      navigator.storage.persist().catch(() => {});
    }

    await Promise.all(
      Array.from({ length: Math.min(concurrency, total) }, worker)
    );

    // If literally nothing downloaded, surface why instead of pretending success.
    if (total > 0 && failed === total) {
      throw new Error(
        'No tiles could be downloaded: ' +
        (firstError && firstError.message ? firstError.message : 'unknown error')
      );
    }
    return { done, total, failed, cachedAlready };
  }

  /* ---------- overzoom: stretch a cached parent tile ---------- */

  function loadImageFromBlob(blob) {
    return new Promise((resolve, reject) => {
      const objUrl = URL.createObjectURL(blob);
      const img = new Image();
      img.onload = () => { URL.revokeObjectURL(objUrl); resolve(img); };
      img.onerror = () => { URL.revokeObjectURL(objUrl); reject(new Error('decode failed')); };
      img.src = objUrl;
    });
  }

  // Returns a data: URL for a tile built from the nearest cached ancestor,
  // or null if none of the parent tiles are stored.
  async function overzoomTile(layer, coords) {
    const size = layer.getTileSize().x;
    for (let dz = 1; dz <= MAX_OVERZOOM; dz++) {
      const az = coords.z - dz;
      if (az < MIN_CACHED_ZOOM) break;

      const scale = Math.pow(2, dz);
      const ax = Math.floor(coords.x / scale);
      const ay = Math.floor(coords.y / scale);

      let blob = null;
      try { blob = await store.get(layer._tileUrlFor(az, ax, ay)); } catch (e) { /* try next */ }
      if (!blob) continue;

      try {
        const img = await loadImageFromBlob(blob);
        const sw = size / scale;                 // source square inside the parent
        const sx = (coords.x - ax * scale) * sw;
        const sy = (coords.y - ay * scale) * sw;
        const canvas = document.createElement('canvas');
        canvas.width = size;
        canvas.height = size;
        const ctx = canvas.getContext('2d');
        ctx.imageSmoothingEnabled = true;
        ctx.drawImage(img, sx, sy, sw, sw, 0, 0, size, size);
        return canvas.toDataURL('image/png');
      } catch (err) {
        /* try the next ancestor */
      }
    }
    return null;
  }

  /* ---------- Leaflet layer ---------- */

  let LayerClass = null;
  let LayerClassFor = null;

  // Built lazily so this file can be imported before Leaflet's global `L`
  // exists, and so it never touches `L` at all on plain web.
  function getLayerClass(Lf) {
    if (LayerClass) return LayerClass;

    LayerClass = Lf.TileLayer.extend({
      // Same URL Leaflet would request, for any z/x/y (used for ancestors).
      _tileUrlFor(z, x, y) {
        return Lf.Util.template(
          this._url,
          Lf.extend({ r: '', s: this._getSubdomain({ x, y }), x, y, z }, this.options)
        );
      },

      createTile(coords, done) {
        const layer = this;
        const tile = document.createElement('img');
        tile.alt = '';
        tile.setAttribute('role', 'presentation');

        const url = this.getTileUrl(coords);
        let finished = false;

        function finish(err) {
          if (finished) return;
          finished = true;
          done(err || null, tile);
        }

        function showBlank() {
          tile.onload = () => finish();
          tile.onerror = () => finish();
          tile.src = BLANK_GIF;
        }

        function showBlob(blob) {
          const objUrl = URL.createObjectURL(blob);
          tile.onload = () => { URL.revokeObjectURL(objUrl); finish(); };
          tile.onerror = () => { URL.revokeObjectURL(objUrl); showBlank(); };
          tile.src = objUrl;
        }

        async function showOverzoomOrBlank() {
          let dataUrl = null;
          try { dataUrl = await overzoomTile(layer, coords); } catch (e) { /* blank */ }
          if (!dataUrl) { showBlank(); return; }
          tile.onload = () => finish();
          tile.onerror = () => showBlank();
          tile.src = dataUrl;
        }

        (async () => {
          // 1) Exact tile from the offline store.
          try {
            const cached = await store.get(url);
            if (cached) { showBlob(cached); return; }
          } catch (err) { /* fall through to network */ }

          // 2) Network (and keep the result for next time). Skipped entirely
          //    while the circuit breaker says the connection is dead.
          if (networkLikelyUp()) {
            try {
              const blob = await fetchTileBlob(url, { fast: true });
              noteNetworkResult(true);
              store.put(url, blob).catch(() => {});
              showBlob(blob);
              return;
            } catch (err) {
              noteNetworkResult(false);
              // Plain <img> retry only makes sense on web (where fetch can
              // fail purely because of CORS). On native, if the native HTTP
              // request failed the network itself is the problem, and an
              // <img> on a dead connection could hang for a long time, so go
              // straight to the offline path instead.
              if (!isNativePlatform() && networkLikelyUp()) {
                // Last online resort: a plain <img> load needs no CORS.
                tile.onload = () => finish();
                tile.onerror = () => { showOverzoomOrBlank(); };
                tile.src = url;
                return;
              }
              // breaker just opened: fall through to the offline path
            }
          }

          // 3) Offline and not cached: stretch a parent tile, or leave blank.
          showOverzoomOrBlank();
        })();

        return tile;
      }
    });

    return LayerClass;
  }

  // `leaflet` is optional: pass your Leaflet object as the 3rd argument when
  // it is not a browser global (e.g. imported from the 'leaflet' package).
  // Pass Leaflet explicitly as the 3rd argument from BiyaHERO.js (where `L`
  // is definitely in scope). Falls back to window.L. This file never touches
  // a bare `L` identifier, so it can't throw "L is not defined" by itself.
  function createTileLayer(urlTemplate, options, LeafletRef) {
    const Lf = LeafletRef || window.L;
    if (!Lf) {
      throw new Error('Leaflet is not loaded. Call createTileLayer(url, options, L).');
    }
    if (!state.enabled) return Lf.tileLayer(urlTemplate, options);
    const Cls = getLayerClass(Lf);
    return new Cls(urlTemplate, options);
  }

  /* ---------- public API ---------- */

  window.BiyaOfflineTiles = {
    get enabled() { return state.enabled; },
    isNative: isNativePlatform,
    createTileLayer,
    download,
    clear: () => store.clear(),
    has: url => store.has(url),
    stats: () => store.stats(),
    networkLikelyUp,

    // Aliases using the same names as the helper functions in BiyaHERO.js,
    // so BiyaOfflineTiles.clearTileCache() / .downloadTilesWithProgress()
    // work too.
    clearTileCache: () => store.clear(),
    downloadTilesWithProgress: (urls, onProgress, opts) => download(urls, onProgress, opts)
  };
})();
