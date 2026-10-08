// ============================================================
// BiyaHERO offline routing + map database
// ============================================================
// Two SQLite databases, one connection manager:
//   laguna_routing.db  — bundled road graph (read-only)
//   biyahero_maps.db   — runtime, holds maps/laguna.pmtiles as a BLOB
//
// PMTiles archive lives in SQLite because Capacitor's webview does not
// honour HTTP Range requests, which is what the PMTiles format needs.
// substr() on a BLOB gives the same byte-range primitive natively.

let db = null;
let mapsDb = null;
let mapsDbPromise = null;
let sqliteRef = null;
let initPromise = null;

// Folder + filename as stored in public/. Vite serves public/ at the
// root URL, so the fetch path is '/maps/laguna.pmtiles'.
const PMTILES_FILENAME = 'maps/laguna.pmtiles';

function isNativePlatform() {
  return !!(
    window.Capacitor &&
    typeof window.Capacitor.isNativePlatform === 'function' &&
    window.Capacitor.isNativePlatform()
  );
}

// Idempotent — safe to call from multiple places, only the first call
// actually opens the connection. Returns the same db object every time.
function initDb() {
  if (initPromise) return initPromise;

  initPromise = (async () => {
    if (!isNativePlatform()) {
      console.info('[BiyaHERO] Not native — SQLite + PMTiles disabled.');
      return null;
    }

    try {
      const { CapacitorSQLite, SQLiteConnection } = await import('@capacitor-community/sqlite');
      const sqlite = new SQLiteConnection(CapacitorSQLite);
      sqliteRef = sqlite;

      await sqlite.copyFromAssets();

      // The connection may already exist from a previous page session
      // (the plugin persists across hot reloads / app resumes).
      // Retrieve instead of trying to create it again.
      let connection;
      try {
        const check = await sqlite.isConnection('laguna_routing', false);
        connection = (check && check.result)
          ? await sqlite.retrieveConnection('laguna_routing', false)
          : await sqlite.createConnection('laguna_routing', false, 'no-encryption', 1, false);
      } catch (err) {
        if (/already exists/i.test(err.message || '')) {
          connection = await sqlite.retrieveConnection('laguna_routing', false);
        } else {
          throw err;
        }
      }

      db = connection;
      const routingOpen = await db.isDBOpen().catch(() => ({ result: false }));
      if (!(routingOpen && routingOpen.result)) await db.open();

      const result = await db.query('SELECT COUNT(*) as count FROM edges');
      console.log('[BiyaHERO] Routing database loaded:', result.values);
      return db;
    } catch (err) {
      console.error('[BiyaHERO] Failed to initialize routing database:', err);
      db = null;
      initPromise = null; // allow a retry on next call
      return null;
    }
  })();

  return initPromise;
}

// Reuses the same SQLiteConnection instance that initDb() set up.
// Lazily opens biyahero_maps.db and creates its tables on first call.
// NOTE: this deliberately does NOT depend on the routing database having
// opened successfully — initDb() only has to have created the SQLite
// connection manager (sqliteRef). A missing/corrupt laguna_routing.db must
// not also take the base map down with it.
async function getMapsDb() {
  if (mapsDb) return mapsDb;
  if (mapsDbPromise) return mapsDbPromise;

  mapsDbPromise = (async () => {
    // Make sure initDb() has run at least once so sqliteRef exists.
    await initDb();
    if (!sqliteRef) throw new Error('SQLite not available');

    let connection;
    try {
      const check = await sqliteRef.isConnection('biyahero_maps', false);
      connection = (check && check.result)
        ? await sqliteRef.retrieveConnection('biyahero_maps', false)
        : await sqliteRef.createConnection('biyahero_maps', false, 'no-encryption', 1, false);
    } catch (err) {
      if (/already exists/i.test(err.message || '')) {
        connection = await sqliteRef.retrieveConnection('biyahero_maps', false);
      } else {
        throw err;
      }
    }

    mapsDb = connection;
    // After a WebView reload the native side may still hold the connection open.
    const mapsOpen = await mapsDb.isDBOpen().catch(() => ({ result: false }));
    if (!(mapsOpen && mapsOpen.result)) await mapsDb.open();

    // The archive is stored as many ~0.7 MB rows (base64 text), NOT as one
    // 30+ MB row. Android reads query results through a CursorWindow that
    // is only ~2 MB, so a single huge row can be written fine but can never
    // be read back ("Row too big to fit into CursorWindow"). Small rows also
    // mean a tile lookup only pulls the few chunks it touches instead of
    // decoding the entire archive into memory.
    // pmtiles_meta is written LAST, so its presence proves every chunk made
    // it in (an app kill mid-copy leaves no meta row and is redone).
    await mapsDb.execute(`
      CREATE TABLE IF NOT EXISTS pmtiles_chunks (
        filename TEXT NOT NULL,
        idx      INTEGER NOT NULL,
        data     TEXT NOT NULL,
        PRIMARY KEY (filename, idx)
      );
      CREATE TABLE IF NOT EXISTS pmtiles_meta (
        filename    TEXT PRIMARY KEY,
        total_bytes INTEGER NOT NULL,
        chunk_bytes INTEGER NOT NULL,
        chunk_count INTEGER NOT NULL
      );
    `);

    return mapsDb;
  })();

  // A failed attempt must not be cached forever.
  mapsDbPromise.catch(() => { mapsDbPromise = null; });
  return mapsDbPromise;
}

const CHUNK_BYTES = 512 * 1024;   // raw bytes per row (~683 KB as base64)
const READ_CACHE_CHUNKS = 24;     // decoded chunks kept in memory (~12 MB)

async function readStoredMeta(mdb, filename) {
  const res = await mdb.query(
    'SELECT total_bytes, chunk_bytes, chunk_count FROM pmtiles_meta WHERE filename = ?',
    [filename]
  );
  if (!res.values || !res.values.length) return null;
  const row = res.values[0];
  return {
    total_bytes: Number(row.total_bytes),
    chunk_bytes: Number(row.chunk_bytes),
    chunk_count: Number(row.chunk_count)
  };
}

async function isArchiveComplete(mdb, filename) {
  const meta = await readStoredMeta(mdb, filename);
  if (!meta || !meta.chunk_count) return false;
  const res = await mdb.query(
    'SELECT COUNT(*) AS n FROM pmtiles_chunks WHERE filename = ?',
    [filename]
  );
  const n = res.values && res.values[0] ? Number(res.values[0].n) : 0;
  return n === meta.chunk_count;
}

// Staging name used while an update is being copied in next to the live archive.
const PMTILES_STAGING = PMTILES_FILENAME + '.new';

// Meta row goes first so an archive is never "complete" while its chunks are
// only half removed.
async function clearArchiveRows(mdb, filename) {
  await mdb.run('DELETE FROM pmtiles_meta WHERE filename = ?;', [filename]);
  await mdb.run('DELETE FROM pmtiles_chunks WHERE filename = ?;', [filename]);
}

// The previous version kept the whole archive in one unreadable row.
// Reclaim that space once a chunked copy exists; non-fatal either way.
async function dropLegacyArchiveTable(mdb) {
  try { await mdb.execute('DROP TABLE IF EXISTS pmtiles_archive;'); } catch (e) { /* non-fatal */ }
}

// Copies the bundled archive into SQLite under `target`: chunks first, meta
// LAST, then verifies the count. Returns the archive size in bytes.
async function copyBundledArchive(mdb, target, onProgress) {
  await clearArchiveRows(mdb, target);

  // Resolved against the document, not the origin root: '/maps/...' 404s when
  // the app is hosted under a sub-path, while this also gives
  // https://localhost/maps/laguna.pmtiles inside Capacitor.
  const url = new URL(PMTILES_FILENAME, document.baseURI).href;
  console.log('[BiyaHERO] Fetching ' + url + '…');
  const resp = await fetch(url, { cache: 'no-store' });
  if (!resp.ok) throw new Error('PMTiles fetch failed: HTTP ' + resp.status + ' for ' + url);

  const bytes = new Uint8Array(await resp.arrayBuffer());

  // A PMTiles v3 archive always starts with the ASCII magic "PMTiles". If the
  // dev/web server answers a missing file with its index.html fallback
  // (HTTP 200), the copy would "succeed" and the map would then fail
  // mysteriously later — fail here, with a clear reason, instead.
  const magic = String.fromCharCode.apply(null, bytes.subarray(0, 7));
  if (magic !== 'PMTiles') {
    throw new Error('Fetched ' + url + ' is not a PMTiles archive (' + bytes.length + " bytes) — is maps/laguna.pmtiles in the app's web assets?");
  }

  const chunkCount = Math.ceil(bytes.length / CHUNK_BYTES);
  console.log('[BiyaHERO] Got', bytes.length, 'bytes. Writing', chunkCount, 'chunks to SQLite…');

  for (let i = 0; i < chunkCount; i++) {
    const slice = bytes.subarray(i * CHUNK_BYTES, Math.min((i + 1) * CHUNK_BYTES, bytes.length));
    await mdb.run(
      'INSERT INTO pmtiles_chunks (filename, idx, data) VALUES (?, ?, ?);',
      [target, i, uint8ToBase64(slice)]
    );
    if (typeof onProgress === 'function') onProgress({ done: i + 1, total: chunkCount });
  }

  // Meta last: its presence means the copy is whole.
  await mdb.run(
    'INSERT INTO pmtiles_meta (filename, total_bytes, chunk_bytes, chunk_count) VALUES (?, ?, ?, ?);',
    [target, bytes.length, CHUNK_BYTES, chunkCount]
  );

  if (!(await isArchiveComplete(mdb, target))) {
    throw new Error('PMTiles write incomplete — chunk count does not match.');
  }
  return bytes.length;
}

// opts.force      true = "Update Map": re-copy the bundled archive even though a
//                 complete one is stored. The new copy is built beside the live
//                 one and swapped in atomically, so a failed update (app killed,
//                 bad asset, storage full) leaves the existing map untouched.
// opts.onProgress ({done, total}) per chunk written.
// Resolves { updated, total_bytes }.
// Download button, Update button and the map's own start-up repair can all
// ask for the archive at once. Two overlapping copies would collide on the
// (filename, idx) primary key, so every request waits for the previous one.
let pmtilesQueue = Promise.resolve();
function ensurePmtilesStored(opts) {
  const run = pmtilesQueue.then(() => ensurePmtilesStoredNow(opts));
  pmtilesQueue = run.catch(() => {});
  return run;
}

async function ensurePmtilesStoredNow(opts) {
  const force = !!(opts && opts.force);
  const onProgress = opts && opts.onProgress;
  const mdb = await getMapsDb();

  // Anything under the staging name is left over from an interrupted update.
  await clearArchiveRows(mdb, PMTILES_STAGING);

  if (!force && await isArchiveComplete(mdb, PMTILES_FILENAME)) {
    console.log('[BiyaHERO] PMTiles already stored.');
    const meta = await readStoredMeta(mdb, PMTILES_FILENAME);
    return { updated: false, total_bytes: meta.total_bytes };
  }

  if (!force) {
    // First copy, or repair of a partial one: nothing good to protect, so
    // write straight into place.
    const total = await copyBundledArchive(mdb, PMTILES_FILENAME, onProgress);
    console.log('[BiyaHERO] PMTiles stored.');
    await dropLegacyArchiveTable(mdb);
    return { updated: true, total_bytes: total };
  }

  let total;
  try {
    total = await copyBundledArchive(mdb, PMTILES_STAGING, onProgress);
    // One transaction: the live archive is either the old one or the new one.
    await mdb.executeSet([
      { statement: 'DELETE FROM pmtiles_meta WHERE filename = ?;',   values: [PMTILES_FILENAME] },
      { statement: 'DELETE FROM pmtiles_chunks WHERE filename = ?;', values: [PMTILES_FILENAME] },
      { statement: 'UPDATE pmtiles_chunks SET filename = ? WHERE filename = ?;', values: [PMTILES_FILENAME, PMTILES_STAGING] },
      { statement: 'UPDATE pmtiles_meta SET filename = ? WHERE filename = ?;',   values: [PMTILES_FILENAME, PMTILES_STAGING] }
    ], true);
  } catch (err) {
    try { await clearArchiveRows(mdb, PMTILES_STAGING); } catch (e) { /* best effort */ }
    throw err;
  }
  console.log('[BiyaHERO] PMTiles updated.');
  await dropLegacyArchiveTable(mdb);
  return { updated: true, total_bytes: total };
}

// "Delete" in Settings. Removes the stored archive (and any half-finished
// update) so it is really gone from the device, not just forgotten by the UI.
// It can always be re-copied from the bundled asset.
function deletePmtiles() {
  const run = pmtilesQueue.then(() => deletePmtilesNow());
  pmtilesQueue = run.catch(() => {});
  return run;
}

async function deletePmtilesNow() {
  if (!isNativePlatform()) return { removed: false };   // nothing is stored outside the native app
  const mdb = await getMapsDb();
  await clearArchiveRows(mdb, PMTILES_FILENAME);
  await clearArchiveRows(mdb, PMTILES_STAGING);
  await dropLegacyArchiveTable(mdb);
  // Hand the freed pages back to Android. VACUUM cannot run inside a
  // transaction, hence the `false`. The rows are already gone, so non-fatal.
  try { await mdb.execute('VACUUM;', false); } catch (e) { console.warn('[BiyaHERO] VACUUM after map delete failed (non-fatal):', e); }
  return { removed: true };
}

// Chunked base64 so a 512 KB Uint8Array never blows the argument limit
// on String.fromCharCode.apply().
function uint8ToBase64(bytes) {
  const CHUNK = 0x8000;
  let binary = '';
  for (let i = 0; i < bytes.length; i += CHUNK) {
    binary += String.fromCharCode.apply(
      null,
      bytes.subarray(i, Math.min(i + CHUNK, bytes.length))
    );
  }
  return btoa(binary);
}

function base64ToUint8(b64) {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

// PMTiles-compatible source: getBytes(offset, length) → { data: ArrayBuffer }
// Reads only the chunk rows that overlap the requested byte range.
class SqlitePMTilesSource {
  constructor(filename) {
    this.filename = filename || PMTILES_FILENAME;
    this._metaPromise = null;
    this._chunks = new Map();    // idx -> Uint8Array (insertion order = LRU order)
    this._inflight = new Map();  // idx -> Promise<Uint8Array>
  }
  getKey() {
    return this.filename;
  }
  _loadMeta() {
    if (!this._metaPromise) {
      this._metaPromise = (async () => {
        const mdb = await getMapsDb();
        const meta = await readStoredMeta(mdb, this.filename);
        if (!meta) throw new Error('No PMTiles archive stored for ' + this.filename);
        return meta;
      })();
      this._metaPromise.catch(() => { this._metaPromise = null; });
    }
    return this._metaPromise;
  }
  _getChunk(idx) {
    const hit = this._chunks.get(idx);
    if (hit) {
      this._chunks.delete(idx);
      this._chunks.set(idx, hit);   // refresh LRU position
      return Promise.resolve(hit);
    }
    if (this._inflight.has(idx)) return this._inflight.get(idx);

    const p = (async () => {
      const mdb = await getMapsDb();
      const res = await mdb.query(
        'SELECT data FROM pmtiles_chunks WHERE filename = ? AND idx = ?',
        [this.filename, idx]
      );
      if (!res.values || !res.values.length) {
        throw new Error('Missing PMTiles chunk ' + idx);
      }
      const raw = res.values[0].data;
      let bytes;
      if (typeof raw === 'string') bytes = base64ToUint8(raw);
      else if (raw instanceof Uint8Array) bytes = raw;
      else if (raw instanceof ArrayBuffer) bytes = new Uint8Array(raw);
      else throw new Error('Unexpected chunk type: ' + typeof raw);

      this._chunks.set(idx, bytes);
      while (this._chunks.size > READ_CACHE_CHUNKS) {
        this._chunks.delete(this._chunks.keys().next().value);
      }
      return bytes;
    })();

    this._inflight.set(idx, p);
    const done = () => this._inflight.delete(idx);
    p.then(done, done);
    return p;
  }
  async getBytes(offset, length) {
    if (!this._loggedFirstCall) {
      this._loggedFirstCall = true;
      console.log('Pmtiles first call:', offset, length);
    }
    const meta = await this._loadMeta();
    const start = Math.max(0, offset);
    const end = Math.min(offset + length, meta.total_bytes);
    if (start >= end) return { data: new ArrayBuffer(0) };

    const cb = meta.chunk_bytes;
    const first = Math.floor(start / cb);
    const last = Math.floor((end - 1) / cb);
    const out = new Uint8Array(end - start);

    for (let i = first; i <= last; i++) {
      const chunk = await this._getChunk(i);
      const chunkStart = i * cb;
      const from = Math.max(start, chunkStart) - chunkStart;
      const to = Math.min(end, chunkStart + chunk.length) - chunkStart;
      out.set(chunk.subarray(from, to), Math.max(start, chunkStart) - start);
    }
    return { data: out.buffer };
  }
}
window.RoutingDatabase = {
  initDb,
  getDb: () => db,
  getMapsDb,
  ensurePmtilesStored,
  deletePmtiles,
  SqlitePMTilesSource,
  PMTILES_FILENAME
};
