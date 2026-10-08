// ============================================================
// protomaps-map.js — BiyaHERO vector base map (Protomaps + Leaflet)
// ============================================================
// ONE module owns everything about the base map:
//
//   archive store   where laguna.pmtiles lives on this device
//                     native (Capacitor)  -> SQLite chunks (RoutingDatabase.js)
//                     web / PWA           -> Cache Storage (whole file), or
//                                            HTTP Range requests while not saved
//   PMTiles reader  one PMTiles instance per archive, validated on open
//   Leaflet layer   protomaps-leaflet layer, built from that instance
//   lifecycle       start / stop / reload / setFlavor / refresh
//   diagnostics     window.biyaMapDiag() says exactly which step is failing
//
// Why this exists (what was wrong with the scattered version in BiyaHERO.js):
//   * PMTiles reached the app through a `window.PMTiles` global that a
//     separate inline <script type="module"> had to set first. Any ordering
//     or bundling hiccup left it undefined and the base layer was skipped.
//     This file imports ./pmtiles.js directly instead.
//   * The archive URL was the absolute path '/maps/laguna.pmtiles'. That 404s
//     as soon as the app is hosted under a sub-path (GitHub Pages, any
//     reverse-proxy prefix). URLs are now resolved against document.baseURI.
//   * pmtiles' own FetchSource throws when a server answers a Range request
//     with HTTP 200 (python -m http.server, many static hosts, some
//     emulator/dev proxies). WebArchiveSource below copes with that.
//   * On the web nothing was ever stored, so "offline" did not work there and
//     sw.js (which cannot cache 206 responses) could not help. The web store
//     now keeps the whole archive in Cache Storage and serves byte ranges
//     from it.
//   * Calling start twice concurrently, or after a delete, could race. All
//     lifecycle calls are serialised and generation-checked.
// ============================================================

import { PMTiles } from './pmtiles.js';

export const ARCHIVE_PATH = 'maps/laguna.pmtiles';
export const WEB_CACHE_NAME = 'biyahero-pmtiles-v1';   // keep in sync with MAP_CACHE in sw.js
const LEGACY_RASTER_CACHE = 'biyahero-tiles-v1';
const ATTRIBUTION =
  '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors';
const LOG = '[BiyaHERO map]';

/* ---------- platform + URL helpers ---------- */

export function isNativeApp() {
  const c = window.Capacitor;
  if (!c) return false;
  if (typeof c.isNativePlatform === 'function') return !!c.isNativePlatform();
  return typeof c.getPlatform === 'function' && c.getPlatform() !== 'web';
}

// Resolved against the document, never against the origin root, so it works
// at https://localhost/ (Capacitor), http://localhost:5173/ (Vite) and
// https://user.github.io/BiyaHERO/ alike.
export function archiveUrl() {
  return new URL(ARCHIVE_PATH, document.baseURI).href;
}

async function looksLikePmtiles(blob) {
  const head = await blob.slice(0, 7).arrayBuffer();
  return String.fromCharCode(...new Uint8Array(head)) === 'PMTiles';
}

/* ---------- update helpers ---------- */

// Metadata about the saved copy travels WITH the cached Response, so reading
// "what version do I have?" never needs to load the 37 MB body.
const META_ETAG = 'X-Biya-ETag';
const META_MODIFIED = 'X-Biya-Last-Modified';
const META_SHA = 'X-Biya-SHA256';
const META_SAVED = 'X-Biya-Saved-At';
const META_SIZE = 'X-Biya-Size';
// No bytes for this long = the download is dead. (window.__BIYA_STALL_MS exists for tests only.)
const STALL_MS = (typeof window !== 'undefined' && window.__BIYA_STALL_MS) || 30000;

function codedError(code, message, cause) {
  const e = new Error(message);
  e.code = code;
  if (cause) e.cause = cause;
  return e;
}

// A URL no service worker / HTTP cache / CDN edge can have stored an answer for.
// Without this an Update can be answered by sw.js from its OWN cached copy and
// "update" to the very same old file forever.
function busted(url) {
  return url + (url.indexOf('?') >= 0 ? '&' : '?') + 'v=' + Date.now();
}

async function sha256Hex(blob) {
  try {
    if (!(globalThis.crypto && crypto.subtle)) return '';
    const d = await crypto.subtle.digest('SHA-256', await blob.arrayBuffer());
    return Array.from(new Uint8Array(d)).map(b => b.toString(16).padStart(2, '0')).join('');
  } catch (e) { return ''; }   // insecure origin: no SubtleCrypto, hash is optional
}

class BlobSource {
  constructor(blob, key) { this.blob = blob; this.key = key; }
  getKey() { return this.key; }
  async getBytes(offset, length) {
    const end = Math.min(offset + length, this.blob.size);
    return { data: await this.blob.slice(offset, end).arrayBuffer() };
  }
}

// Opens the downloaded bytes with the REAL reader before they are allowed to
// replace the working copy. Catches: HTML error pages served as 200, truncated
// downloads, raster archives, damaged headers / metadata.
async function verifyArchive(blob, where) {
  if (blob.size < 127 || !(await looksLikePmtiles(blob))) {
    throw codedError('bad-archive', 'Downloaded file from ' + where + ' is not a PMTiles archive (' + blob.size + ' bytes).');
  }
  const pm = new PMTiles(new BlobSource(blob, 'candidate:' + Date.now()));
  let header;
  try { header = await pm.getHeader(); }
  catch (e) { throw codedError('bad-archive', 'Downloaded map has an unreadable header: ' + (e && e.message ? e.message : e), e); }
  if (header.tileType >= 2) {
    throw codedError('bad-archive', 'Downloaded map holds raster tiles; a vector (MVT) PMTiles file is required.');
  }
  const needed = Math.max(
    header.rootDirectoryOffset + header.rootDirectoryLength,
    header.jsonMetadataOffset + header.jsonMetadataLength,
    header.tileDataOffset + header.tileDataLength
  );
  if (needed > blob.size) {
    throw codedError('truncated', 'Downloaded map is incomplete (' + blob.size + ' of ' + needed + ' bytes). The old map was kept.');
  }
  try { await pm.getMetadata(); }
  catch (e) { throw codedError('bad-archive', 'Downloaded map has damaged metadata: ' + (e && e.message ? e.message : e), e); }
  return header;
}

// fetch() with a stall watchdog and a friendly offline error.
async function fetchGuarded(url, init, onController) {
  const ctl = new AbortController();
  let stalled = false, timer = null;
  const arm = () => { clearTimeout(timer); timer = setTimeout(() => { stalled = true; ctl.abort(); }, STALL_MS); };
  arm();
  const guard = {
    poke: arm,
    done: () => clearTimeout(timer),
    wrap: (e) => stalled
      ? codedError('stalled', 'The map download stalled — check your connection and try again.', e)
      : codedError('offline', 'Cannot reach the map server — check your connection and try again.', e)
  };
  try {
    const resp = await fetch(url, Object.assign({}, init, { signal: ctl.signal }));
    return { resp, guard };
  } catch (e) { guard.done(); throw guard.wrap(e); }
}

/* ---------- web byte source ---------- */
// getBytes(offset, length) for the PMTiles reader. Order of preference:
//   1. the copy saved in Cache Storage (works with no network at all)
//   2. an in-memory copy, if the server ignored Range once (HTTP 200)
//   3. a normal HTTP Range request

export class WebArchiveSource {
  constructor(url, cacheName = WEB_CACHE_NAME, onVersion = null) {
    this.url = url;
    this.cacheName = cacheName;
    this.onVersion = onVersion;   // called once with {etag, modified, size} of the server file this reader streams
    this._blob = null;   // Blob (from Cache Storage or from a full 200 response)
  }
  getKey() { return this.url; }

  async _cachedBlob() {
    if (this._blob) return this._blob;
    if (typeof caches === 'undefined') return null;
    try {
      const cache = await caches.open(this.cacheName);
      const hit = await cache.match(this.url);
      if (hit) this._blob = await hit.blob();
    } catch (e) { /* Cache Storage unavailable (private mode / insecure origin) */ }
    return this._blob;
  }

  _reportVersion(resp) {
    if (!this.onVersion || this._reported) return;
    this._reported = true;
    const cr = /\/(\d+)\s*$/.exec(resp.headers.get('Content-Range') || '');
    try {
      this.onVersion({
        etag: resp.headers.get('etag') || '',
        modified: resp.headers.get('last-modified') || '',
        size: cr ? Number(cr[1]) : Number(resp.headers.get('content-length')) || 0
      });
    } catch (e) { /* observer must never break tile loading */ }
  }

  async getBytes(offset, length, signal) {
    // A reader must keep reading the SAME bytes it read its header from. If its
    // first read came from the network, never silently switch to a copy that an
    // Update saved later: its cached header/directory offsets would not match.
    const blob = this._netOnly ? this._blob : await this._cachedBlob();
    if (!blob && this._netOnly === undefined) this._netOnly = true;
    if (blob) {
      this._netOnly = this._netOnly || false;
      const end = Math.min(offset + length, blob.size);
      return { data: await blob.slice(offset, end).arrayBuffer() };
    }

    const resp = await fetch(this.url, {
      signal,
      headers: { Range: `bytes=${offset}-${offset + length - 1}` }
    });
    if (resp.status === 206 || resp.status === 200) this._reportVersion(resp);
    if (resp.status === 206) {
      const data = await resp.arrayBuffer();

      // Never trust a 206 blindly. Capacitor's Android WebViewLocalServer answers
      // every Range request with "206" + a Content-Range header built from the
      // REQUESTED numbers, but streams the WHOLE file from byte 0. Taking that
      // body as the requested bytes silently yields garbage tiles (blank map,
      // no error) and re-downloads the entire archive for every single tile.
      const cr = /bytes\s+\d+-\d+\/(\d+|\*)/i.exec(resp.headers.get('Content-Range') || '');
      const total = cr && cr[1] !== '*' ? Number(cr[1]) : null;
      const expected = total != null ? Math.max(0, Math.min(length, total - offset)) : length;
      if (data.byteLength === expected) return { data };

      const whole = new Blob([data]);
      if (data.byteLength > expected && (total == null || data.byteLength === total) && (await looksLikePmtiles(whole))) {
        // Whole archive mislabelled as a partial one: keep it once, slice locally.
        this._blob = whole;
        const end = Math.min(offset + length, whole.size);
        return { data: await whole.slice(offset, end).arrayBuffer() };
      }
      throw new Error(
        'Range request ' + offset + '+' + length + ' on ' + this.url + ' returned ' + data.byteLength +
        ' bytes (expected ' + expected + ') — the server does not honour Range correctly.'
      );
    }

    if (resp.status === 200) {
      // The server ignored Range and sent the whole file. Keep it once and
      // slice locally instead of re-downloading it for every tile.
      const whole = await resp.blob();
      if (!(await looksLikePmtiles(whole))) {
        throw new Error(
          'Server answered ' + this.url + ' with something that is not a PMTiles archive ' +
          '(' + whole.size + ' bytes) — is maps/laguna.pmtiles deployed next to index.html?'
        );
      }
      this._blob = whole;
      const end = Math.min(offset + length, whole.size);
      return { data: await whole.slice(offset, end).arrayBuffer() };
    }
    throw new Error('HTTP ' + resp.status + ' for ' + this.url);
  }
}

/* ---------- archive stores (install / remove / open) ---------- */

function nativeStore() {
  const RD = () => {
    if (!window.RoutingDatabase) throw new Error('RoutingDatabase module missing');
    return window.RoutingDatabase;
  };
  return {
    kind: 'native-sqlite',
    // Native needs the bundled archive copied into SQLite before it can be read.
    prepare: () => RD().ensurePmtilesStored(),
    install: (opts) => RD().ensurePmtilesStored(opts),
    // Native has no version probe of its own: Update = re-copy the archive that
    // ships/streams with the app into SQLite (RoutingDatabase.js owns the details).
    update: async (opts) => {
      const r = (await RD().ensurePmtilesStored(Object.assign({}, opts, { force: true }))) || {};
      return Object.assign({ updated: true }, r);
    },
    status: async () => (typeof RD().pmtilesStatus === 'function' ? RD().pmtilesStatus() : null),
    uninstall: () => RD().deletePmtiles(),
    openSource: () => new (RD().SqlitePMTilesSource)(RD().PMTILES_FILENAME || ARCHIVE_PATH)
  };
}

function webStore() {
  const url = archiveUrl();
  const hasCache = typeof caches !== 'undefined';
  let lastSeenRemote = null;   // web-http mode only: what the server looked like last time

  // Version info of the saved copy, read from the cached Response's headers.
  async function localMeta() {
    if (!hasCache) return null;
    try {
      const hit = await (await caches.open(WEB_CACHE_NAME)).match(url);
      if (!hit) return null;
      const h = hit.headers;
      let size = Number(h.get(META_SIZE)) || Number(h.get('content-length')) || 0;
      if (!size) size = (await hit.blob()).size;
      return {
        size,
        etag: h.get(META_ETAG) || '',
        modified: h.get(META_MODIFIED) || '',
        sha: h.get(META_SHA) || '',
        savedAt: Number(h.get(META_SAVED)) || 0
      };
    } catch (e) { return null; }
  }

  // HEAD the server. null = server cannot answer HEAD (caller falls back to GET).
  async function remoteInfo() {
    const { resp, guard } = await fetchGuarded(busted(url), { method: 'HEAD', cache: 'no-store' });
    guard.done();
    if (resp.status === 404) throw codedError('missing', 'The map file was not found on the server (' + url + ').');
    if (!resp.ok) return null;
    return {
      etag: resp.headers.get('etag') || '',
      modified: resp.headers.get('last-modified') || '',
      size: Number(resp.headers.get('content-length')) || 0
    };
  }

  // true only when a validator proves both are the same file. No validators
  // (Capacitor's local server, some dev proxies) = unknown = download + compare hash.
  function sameVersion(local, remote) {
    if (!local || !remote) return false;
    if (local.etag && remote.etag) return local.etag === remote.etag;
    if (local.modified && remote.modified) {
      return local.modified === remote.modified && (!local.size || !remote.size || local.size === remote.size);
    }
    return false;
  }

  async function download(onProgress) {
    const { resp, guard } = await fetchGuarded(busted(url), { cache: 'no-store' });
    try {
      if (!resp.ok) throw codedError(resp.status === 404 ? 'missing' : 'http',
        'PMTiles download failed: HTTP ' + resp.status + ' for ' + url);
      const total = Number(resp.headers.get('content-length')) || 0;
      // Content-Length of a compressed response is the COMPRESSED size; only
      // trust it as the expected body size when no Content-Encoding is applied.
      const exact = total > 0 && !resp.headers.get('content-encoding');
      let blob;
      if (resp.body && typeof resp.body.getReader === 'function') {
        const reader = resp.body.getReader();
        const parts = [];
        let got = 0;
        try {
          for (;;) {
            guard.poke();
            const { done, value } = await reader.read();
            if (done) break;
            parts.push(value);
            got += value.byteLength;
            if (typeof onProgress === 'function') onProgress({ done: got, total: total || got });
          }
        } catch (e) { throw guard.wrap(e); }
        blob = new Blob(parts);
      } else {
        blob = await resp.blob();
      }
      if (exact && blob.size !== total) {
        throw codedError('truncated', 'Map download ended early (' + blob.size + ' of ' + total + ' bytes). The old map was kept.');
      }
      return {
        blob,
        etag: resp.headers.get('etag') || '',
        modified: resp.headers.get('last-modified') || ''
      };
    } finally { guard.done(); }
  }

  async function save(blob, v, sha) {
    const cache = await caches.open(WEB_CACHE_NAME);
    const headers = {
      'Content-Type': 'application/octet-stream',
      'Content-Length': String(blob.size),
      [META_SIZE]: String(blob.size),
      [META_SAVED]: String(Date.now())
    };
    if (v.etag) headers[META_ETAG] = v.etag;
    if (v.modified) headers[META_MODIFIED] = v.modified;
    if (sha) headers[META_SHA] = sha;
    try {
      // Cache.put is all-or-nothing: if it throws, the previous copy is untouched.
      await cache.put(url, new Response(blob, { status: 200, headers }));
    } catch (e) {
      if (e && (e.name === 'QuotaExceededError' || /quota/i.test(String(e.message)))) {
        throw codedError('storage-full', 'Not enough free storage to save the map (' +
          (blob.size / 1048576).toFixed(1) + ' MB needed). The old map was kept.', e);
      }
      throw e;
    }
    // Read it back: a map that "saved" but cannot be read is worse than none.
    const back = await cache.match(url);
    if (!back || (await back.blob()).size !== blob.size) {
      throw codedError('save-failed', 'The map could not be saved on this device. Try again.');
    }
  }

  // Download + verify + (maybe) replace.  force:true replaces unconditionally.
  async function sync({ force = false, onProgress } = {}) {
    if (!hasCache) {
      // No Cache Storage (insecure origin): the archive is streamed on demand, so
      // "updating" = re-open the reader when the server file differs from the one
      // this reader started on. Re-opening downloads nothing, so when a validator
      // cannot PROVE the file is the same we simply reload (cheap and safe).
      const remote = await remoteInfo();
      const baseline = lastSeenRemote;
      lastSeenRemote = remote;
      const changed = force || (!!baseline && !sameVersion(baseline, remote));
      return { updated: changed, upToDate: !changed, streaming: true, total_bytes: remote ? remote.size : 0 };
    }

    const local = await localMeta();
    if (local && !force) {
      const remote = await remoteInfo();
      if (remote && sameVersion(local, remote)) {
        return { updated: false, upToDate: true, total_bytes: local.size, savedAt: local.savedAt };
      }
    }

    const got = await download(onProgress);
    await verifyArchive(got.blob, url);
    const sha = await sha256Hex(got.blob);

    const identical = !!(local && sha && local.sha && local.sha === sha);
    if (identical && !force) {
      // Server validators changed but the bytes did not (re-uploaded / re-deployed
      // file). Keep the copy, refresh its validators so we stop re-downloading.
      if (got.etag !== local.etag || got.modified !== local.modified) await save(got.blob, got, sha);
      return { updated: false, upToDate: true, total_bytes: got.blob.size };
    }
    await save(got.blob, got, sha);
    return { updated: true, upToDate: false, total_bytes: got.blob.size, replaced: !!local };
  }

  return {
    kind: hasCache ? 'web-cache' : 'web-http',
    prepare: async () => {},
    // Download Map (keeps an existing copy) / force:true = unconditional re-download.
    async install({ force = false, onProgress } = {}) {
      if (!hasCache) return sync({ force, onProgress });
      const have = force ? null : await localMeta();
      if (have) return { updated: false, total_bytes: have.size };
      return sync({ force: true, onProgress });
    },
    // Update Map: only replaces the saved copy when the server has a different one.
    update: (o) => sync({ force: false, onProgress: o && o.onProgress }),
    status: async () => {
      const m = await localMeta();
      return m ? { installed: true, bytes: m.size, savedAt: m.savedAt, etag: m.etag, modified: m.modified }
               : { installed: false, bytes: 0, savedAt: 0 };
    },
    async uninstall() {
      if (!hasCache) return { removed: false };
      await caches.delete(WEB_CACHE_NAME);
      try { await caches.delete(LEGACY_RASTER_CACHE); } catch (e) { /* none */ }
      return { removed: true };
    },
    openSource: () => new WebArchiveSource(url, WEB_CACHE_NAME, v => { lastSeenRemote = v; })
  };
}

/* ---------- small geometry helper for the "is there a tile here?" probe ---------- */

function lonLatToTile(lon, lat, z) {
  const n = Math.pow(2, z);
  const x = Math.floor(((lon + 180) / 360) * n);
  const rad = (lat * Math.PI) / 180;
  const y = Math.floor(((1 - Math.log(Math.tan(rad) + 1 / Math.cos(rad)) / Math.PI) / 2) * n);
  return { x: Math.min(n - 1, Math.max(0, x)), y: Math.min(n - 1, Math.max(0, y)) };
}

/* ---------- controller ---------- */

export function createProtomapsBasemap(opts) {
  const {
    map,
    containerId = 'leafletMap',
    getFlavor = () => 'light',
    isEnabled = () => true,
    notify = () => {},
    onState = () => {},          // 'attached' | 'failed' — lets the host show a fallback base layer
    store = isNativeApp() ? nativeStore() : webStore()
  } = opts;

  let layer = null;
  let archive = null;            // { pm, header, metadata }
  let startPromise = null;
  let generation = 0;            // bumped by stop(); in-flight starts compare against it
  let busy = false;              // install / uninstall in progress
  let lastError = null;
  let lastNotified = '';
  let retryTimer = null;         // bounded automatic retry after a failed start()
  let retryCount = 0;
  const RETRY_DELAYS_MS = [2000, 5000, 10000, 20000];

  const container = () => document.getElementById(containerId);

  function clearRetry() {
    if (retryTimer) { clearTimeout(retryTimer); retryTimer = null; }
  }

  // The message below promises a retry, so make it true: a few spaced attempts,
  // cancelled by stop(), never while a layer is already attached.
  function scheduleRetry() {
    if (retryTimer || retryCount >= RETRY_DELAYS_MS.length || !isEnabled() || isAttached()) return;
    const myGen = generation;
    retryTimer = setTimeout(() => {
      retryTimer = null;
      if (myGen !== generation || isAttached() || !isEnabled()) return;
      retryCount++;
      start();
    }, RETRY_DELAYS_MS[retryCount]);
  }

  function fail(msg, err) {
    lastError = err || new Error(msg);
    console.error(LOG, msg, err || '');
    if (lastNotified !== msg) { lastNotified = msg; notify('Base map could not load — it will retry.'); }
    try { onState('failed'); } catch (e) { /* host callback must never break the map */ }
    scheduleRetry();
    return false;
  }

  function requireLibs() {
    const P = window.protomapsL;
    if (!P || typeof P.leafletLayer !== 'function') {
      throw new Error(
        'protomapsL (protomaps-leaflet) is not loaded — expected ./vendor/protomaps/protomaps-leaflet.js ' +
        '(run: npm install && node copy-vendor.mjs, then rebuild/sync).'
      );
    }
    if (!window.L) throw new Error('Leaflet (window.L) is not loaded.');
    return P;
  }

  async function waitForSize(timeoutMs = 10000) {
    const t0 = Date.now();
    for (;;) {
      const el = container();
      if (el && el.offsetWidth > 0 && el.offsetHeight > 0) return true;
      if (Date.now() - t0 > timeoutMs) return false;
      await new Promise(r => setTimeout(r, 100));
    }
  }

  // Opens a FRESH reader (never reuses an old one, so a replaced archive can
  // not be served from stale header/directory caches) and validates it.
  async function openArchive() {
    const pm = new PMTiles(store.openSource());
    const header = await pm.getHeader();

    // 2..5 = PNG / JPEG / WEBP / AVIF. protomaps-leaflet only draws vector tiles.
    if (header.tileType >= 2) {
      throw new Error('Map archive holds raster tiles (tileType ' + header.tileType + '); a vector (MVT) PMTiles file is required.');
    }

    let metadata = null;
    try { metadata = await pm.getMetadata(); } catch (e) { /* optional */ }

    console.log(LOG, 'archive ok — source:', store.kind,
      '| zoom', header.minZoom + '-' + header.maxZoom,
      '| bounds [lat,lon]', [header.minLat, header.minLon, header.maxLat, header.maxLon].join(','),
      '| compression', header.tileCompression);

    // The built-in flavors paint the Protomaps basemap schema. Any other
    // schema (OpenMapTiles, Mapbox Streets…) draws only the flat background
    // colour — a "grey map" with no error anywhere. Say so loudly.
    const ids = ((metadata && metadata.vector_layers) || []).map(l => l.id);
    if (ids.length && !(ids.includes('earth') && ids.includes('water'))) {
      console.error(LOG, 'Archive layers (' + ids.join(', ') + ') are not the Protomaps basemap schema (earth, water, roads, …). The map will look blank.');
      notify('Map file is not in the Protomaps format — base map may look blank.');
    }
    return { pm, header, metadata };
  }

  // Tells you WHY a map is blank when the view and the archive disagree.
  // Resolves to { inBounds, centreTile } (centreTile null = could not tell).
  async function probeView(a) {
    const out = { inBounds: null, centreTile: null };
    try {
      const c = map.getCenter();
      const { header, pm } = a;
      if (c.lat < header.minLat || c.lat > header.maxLat || c.lng < header.minLon || c.lng > header.maxLon) {
        out.inBounds = false;
        console.warn(LOG, 'Map centre ' + c.lat.toFixed(4) + ',' + c.lng.toFixed(4) +
          ' is OUTSIDE the archive bounds — the view will be empty until you pan into the covered area.');
        return out;
      }
      out.inBounds = true;
      const z = Math.min(Math.max(Math.round(map.getZoom()), header.minZoom), header.maxZoom);
      const { x, y } = lonLatToTile(c.lng, c.lat, z);
      const tile = await pm.getZxy(z, x, y);
      out.centreTile = !!tile;
      if (!tile) console.warn(LOG, 'Archive has no tile at the map centre (z' + z + '/' + x + '/' + y + ').');
      else console.log(LOG, 'centre tile z' + z + '/' + x + '/' + y + ' present (' + tile.data.byteLength + ' bytes)');
    } catch (e) {
      console.warn(LOG, 'centre-tile probe failed:', e && e.message ? e.message : e);
    }
    return out;
  }

  // How many tile canvases exist and how many distinct colours they hold.
  // A drawn map has hundreds; a blank / background-only one has 1-2.
  function paintStats() {
    const el = container();
    const canv = el ? Array.prototype.slice.call(el.querySelectorAll('.leaflet-tile-pane canvas')) : [];
    const colors = new Set();
    for (const c of canv) {
      try {
        const d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data;
        for (let i = 0; i < d.length; i += 256) colors.add(d[i] + ',' + d[i + 1] + ',' + d[i + 2]);
      } catch (e) { /* tainted / not ready */ }
    }
    return { canvases: canv.length, colors: colors.size };
  }

  // Resolves once the layer reports its visible tiles loaded (or after timeoutMs).
  function whenLoaded(l, timeoutMs = 8000) {
    return new Promise(resolve => {
      let done = false;
      const fin = () => { if (!done) { done = true; resolve(); } };
      try { if (l && typeof l.once === 'function') l.once('load', fin); else fin(); } catch (e) { fin(); }
      setTimeout(fin, timeoutMs);
    });
  }

  function buildLayer(a) {
    const P = requireLibs();
    return P.leafletLayer({
      url: a.pm,                        // a PMTiles INSTANCE → reader uses getBytes(), not HTTP
      flavor: getFlavor(),
      lang: 'en',
      minZoom: map.getMinZoom(),
      maxZoom: map.getMaxZoom(),
      // Over-zoom from the archive's real deepest level (library assumes 14).
      maxDataZoom: a.header.maxZoom,
      attribution: ATTRIBUTION
    });
  }

  function attach(a) {
    const next = buildLayer(a);
    if (layer && map.hasLayer(layer)) map.removeLayer(layer);
    layer = next.addTo(map);
    window.protomapsLayer = layer;       // kept for console debugging
    try { onState('attached'); } catch (e) { /* see fail() */ }
    return layer;
  }

  function detach() {
    if (layer && map.hasLayer(layer)) map.removeLayer(layer);
    layer = null;
    window.protomapsLayer = null;
  }

  function afterAttach() {
    requestAnimationFrame(() => requestAnimationFrame(() => {
      map.invalidateSize();
      const el = container();
      const canvases = el ? el.querySelectorAll('.leaflet-tile-pane canvas').length : 0;
      console.log(LOG, 'ready — map', map.getSize().x + 'x' + map.getSize().y, '| tile canvases:', canvases);
    }));
  }

  /* ----- public lifecycle ----- */

  function isAttached() { return !!(layer && map.hasLayer(layer)); }

  function start() {
    if (isAttached()) return Promise.resolve(true);
    if (startPromise) return startPromise;
    if (!isEnabled()) return Promise.resolve(false);

    const myGen = generation;
    startPromise = (async () => {
      try {
        requireLibs();
        await store.prepare();                       // native: make sure the archive is in SQLite
        if (myGen !== generation || !isEnabled()) return false;

        if (!(await waitForSize())) return fail('Map container never got a real size');
        if (myGen !== generation || !isEnabled()) return false;

        const a = await openArchive();
        if (myGen !== generation || !isEnabled()) return false;   // deleted while we were opening

        archive = a;
        attach(a);
        lastError = null; lastNotified = '';
        retryCount = 0; clearRetry();
        afterAttach();
        probeView(a);
        return true;
      } catch (err) {
        return fail('Offline map init failed: ' + (err && err.message ? err.message : err), err);
      } finally {
        startPromise = null;
      }
    })();
    return startPromise;
  }

  // Stop drawing and forget the reader (before deleting the archive).
  function stop() {
    generation++;
    clearRetry(); retryCount = 0;
    startPromise = null;
    detach();
    archive = null;
  }

  // Swap in a layer over whatever archive is stored right now (after Update).
  async function reload() {
    if (!isEnabled()) return false;
    if (!isAttached() && !archive) return start();
    const myGen = generation;
    const a = await openArchive();
    if (myGen !== generation) return false;
    archive = a;
    attach(a);
    afterAttach();
    return true;
  }

  // Theme change. Rebuilding the layer is version-proof: not every
  // protomaps-leaflet build has setFlavor(), and this reuses the open reader.
  function setFlavor() {
    if (!archive || !isAttached()) return false;
    try { attach(archive); afterAttach(); return true; }
    catch (err) { return fail('Could not switch map theme: ' + err.message, err); }
  }

  // Container went from hidden to visible, or was resized.
  function onStageShown() {
    if (!isAttached()) { start(); return; }
    requestAnimationFrame(() => requestAnimationFrame(() => {
      map.invalidateSize();
      if (layer && typeof layer.redraw === 'function') layer.redraw();
    }));
  }

  /* ----- install / uninstall (Download, Update, Delete) ----- */

  async function exclusive(fn) {
    if (busy) throw new Error('map-busy');
    busy = true;
    try { return await fn(); } finally { busy = false; }
  }

  // Put the archive that is stored RIGHT NOW on screen, and prove it drew.
  // Never throws for "nothing to show" cases; throws if the new archive cannot be opened.
  async function swapIn() {
    if (!isEnabled()) return { displayed: false, reason: 'disabled' };
    const wasShowing = isAttached();
    const shown = await reload();
    if (shown !== true) return { displayed: false, reason: lastError ? String(lastError.message || lastError) : 'not-attached' };
    await whenLoaded(layer);
    // Give the first canvases a moment to finish painting after 'load'.
    await new Promise(r => setTimeout(r, 400));
    const probe = archive ? await probeView(archive) : { inBounds: null, centreTile: null };
    const paint = paintStats();
    const displayed = probe.centreTile === false || probe.inBounds === false
      ? null                                  // legitimately empty here: cannot judge from this view
      : paint.canvases > 0 && paint.colors > 3;
    return { displayed, wasShowing, paint, probe };
  }

  // Download Map. If a layer is already live and the file actually changed, show it.
  async function installOp(o) {
    return exclusive(async () => {
      const r = await store.install(o || {});
      if (r && r.updated && (isAttached() || archive)) {
        try { await reload(); } catch (e) { console.warn(LOG, 'reload after install failed:', e && e.message ? e.message : e); }
      }
      return r;
    });
  }

  // Update Map. Result: { updated, upToDate, total_bytes, displayed, paint, probe }.
  //   updated   the saved copy was replaced with a newer, verified one
  //   upToDate  the server's copy is the same as the saved one (nothing was replaced)
  //   displayed true  = the live map is drawing from the new archive
  //             null  = cannot judge (current view is outside the archive's coverage)
  //             false = replaced but NOT drawing — read `reason`
  // Throws (old map untouched) on: offline, 404, truncated / corrupt download, storage full.
  async function update(o) {
    return exclusive(async () => {
      if (startPromise) { try { await startPromise; } catch (e) { /* reported by start() */ } }
      const r = (await (store.update ? store.update(o || {}) : store.install(Object.assign({}, o, { force: true })))) || {};
      if (r.updated) {
        try {
          const d = await swapIn();
          return Object.assign({}, r, d);
        } catch (e) {
          throw codedError('display', 'Map updated, but it could not be displayed: ' + (e && e.message ? e.message : e), e);
        }
      }
      // Nothing changed: still make sure a map is showing (e.g. first run / after a failed start).
      if (!isAttached() && isEnabled()) start();
      return Object.assign({ displayed: isAttached() ? true : null }, r);
    });
  }

  const status = async () => (store.status ? store.status() : null);
  const install = installOp;
  const uninstall = () => exclusive(() => store.uninstall());

  /* ----- diagnostics ----- */

  async function diagnose() {
    const el = container();
    const h = archive && archive.header;
    const report = {
      platform: window.Capacitor && window.Capacitor.getPlatform ? window.Capacitor.getPlatform() : 'web',
      store: store.kind,
      archiveUrl: archiveUrl(),
      leaflet: !!window.L,
      protomapsL: !!(window.protomapsL && window.protomapsL.leafletLayer),
      enabled: !!isEnabled(),
      attached: isAttached(),
      starting: !!startPromise,
      container: el ? el.offsetWidth + 'x' + el.offsetHeight : 'missing',
      tileCanvases: el ? el.querySelectorAll('.leaflet-tile-pane canvas').length : 0,
      view: map.getCenter().lat.toFixed(4) + ',' + map.getCenter().lng.toFixed(4) + ' z' + map.getZoom(),
      archive: h ? { minZoom: h.minZoom, maxZoom: h.maxZoom, tileType: h.tileType,
                     bounds: [h.minLat, h.minLon, h.maxLat, h.maxLon],
                     layers: ((archive.metadata && archive.metadata.vector_layers) || []).map(l => l.id) } : null,
      lastError: lastError ? String(lastError.message || lastError) : null,
      paint: paintStats()
    };
    console.log(LOG, 'diagnostics', report);
    return report;
  }
  window.biyaMapDiag = diagnose;

  return { start, stop, reload, setFlavor, onStageShown, install, update, status, uninstall,
           isAttached, isBusy: () => busy, diagnose, store };
}
