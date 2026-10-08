(function () {
  'use strict';

  const EARTH_RADIUS_M = 6371000;

  function toRad(deg) { return (deg * Math.PI) / 180; }

  function haversineM(lat1, lng1, lat2, lng2) {
    const dLat = toRad(lat2 - lat1);
    const dLng = toRad(lng2 - lng1);
    const a =
      Math.sin(dLat / 2) ** 2 +
      Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
    return 2 * EARTH_RADIUS_M * Math.asin(Math.min(1, Math.sqrt(a)));
  }

  function pointToSegmentM(p, a, b) {
    const latRad = toRad(p.lat);
    const kx = 111320 * Math.cos(latRad);
    const ky = 110540;
    const ax = (a.lng - p.lng) * kx, ay = (a.lat - p.lat) * ky;
    const bx = (b.lng - p.lng) * kx, by = (b.lat - p.lat) * ky;
    const dx = bx - ax, dy = by - ay;
    const lenSq = dx * dx + dy * dy;
    let t = lenSq > 0 ? (-ax * dx + -ay * dy) / lenSq : 0;
    t = Math.max(0, Math.min(1, t));
    const cx = ax + t * dx, cy = ay + t * dy;
    return Math.hypot(cx, cy);
  }

  class MinHeap {
    constructor() { this._items = []; }
    get size() { return this._items.length; }
    push(id, score) {
      this._items.push({ id, score });
      let i = this._items.length - 1;
      while (i > 0) {
        const parent = (i - 1) >> 1;
        if (this._items[parent].score <= this._items[i].score) break;
        [this._items[parent], this._items[i]] = [this._items[i], this._items[parent]];
        i = parent;
      }
    }
    pop() {
      if (!this._items.length) return undefined;
      const top = this._items[0];
      const last = this._items.pop();
      if (this._items.length) {
        this._items[0] = last;
        let i = 0;
        const n = this._items.length;
        for (;;) {
          let smallest = i;
          const l = i * 2 + 1, r = i * 2 + 2;
          if (l < n && this._items[l].score < this._items[smallest].score) smallest = l;
          if (r < n && this._items[r].score < this._items[smallest].score) smallest = r;
          if (smallest === i) break;
          [this._items[smallest], this._items[i]] = [this._items[i], this._items[smallest]];
          i = smallest;
        }
      }
      return top.id;
    }
  }

  async function runQuery(db, sql, params) {
    const res = await db.query(sql, params || []);
    return (res && res.values) || [];
  }

  function readCount(rows) {
    if (!rows || !rows.length) return 0;
    const row = rows[0];
    if (row == null) return 0;
    if (row.c != null) return Number(row.c) || 0;
    const firstKey = Object.keys(row)[0];
    return Number(row[firstKey]) || 0;
  }

  // ---- Bounding-box edge + node index ----
  let edgeIndex = null;
  let nodeIndex = null;
  const INDEX_TTL_MS = 5 * 60 * 1000;
  const BBOX_PADDING_DEG = 0.05;

  function bboxFor(origin, dest, paddingDeg) {
    const pad = paddingDeg != null ? paddingDeg : BBOX_PADDING_DEG;
    return {
      minLat: Math.min(origin.lat, dest.lat) - pad,
      maxLat: Math.max(origin.lat, dest.lat) + pad,
      minLng: Math.min(origin.lng, dest.lng) - pad,
      maxLng: Math.max(origin.lng, dest.lng) + pad
    };
  }

  // ---- FIXED: two-parameter containment test ----
  // "Does outerBbox fully contain innerBbox?" Both call sites pass exactly
  // two arguments; the previous three-parameter version read an undefined
  // third arg and threw "Cannot read properties of undefined (minLat)".
  function bboxContains(outerBbox, innerBbox) {
    if (!outerBbox || !innerBbox) return false;
    return innerBbox.minLat >= outerBbox.minLat &&
           innerBbox.maxLat <= outerBbox.maxLat &&
           innerBbox.minLng >= outerBbox.minLng &&
           innerBbox.maxLng <= outerBbox.maxLng;
  }

  async function ensureEdgeIndexForBbox(db, bbox) {
    if (edgeIndex && bboxContains(edgeIndex.bbox, bbox) &&
        (Date.now() - edgeIndex.loadedAt) < INDEX_TTL_MS) {
      return edgeIndex;
    }

    const t0 = performance.now();

    const rows = await runQuery(
      db,
      `SELECT e.* FROM edges e
         JOIN nodes nf ON nf.id = e.from_id
         JOIN nodes nt ON nt.id = e.to_id
        WHERE nf.lat BETWEEN ? AND ?
          AND nf.lng BETWEEN ? AND ?
          AND nt.lat BETWEEN ? AND ?
          AND nt.lng BETWEEN ? AND ?`,
      [
        bbox.minLat, bbox.maxLat, bbox.minLng, bbox.maxLng,
        bbox.minLat, bbox.maxLat, bbox.minLng, bbox.maxLng
      ]
    );

    

    const byFrom = new Map();
    const byTo = new Map();
    for (const e of rows) {
      if (!byFrom.has(e.from_id)) byFrom.set(e.from_id, []);
      byFrom.get(e.from_id).push(e);
      if (!byTo.has(e.to_id)) byTo.set(e.to_id, []);
      byTo.get(e.to_id).push(e);
    }
    edgeIndex = { bbox, byFrom, byTo, loadedAt: Date.now() };
    return edgeIndex;
  }

  async function ensureNodeIndexForBbox(db, bbox) {
    if (nodeIndex && bboxContains(nodeIndex.bbox, bbox) &&
        (Date.now() - nodeIndex.loadedAt) < INDEX_TTL_MS) {
      return nodeIndex;
    }
    const t0 = performance.now();
    const rows = await runQuery(
      db,
      'SELECT id, lat, lng FROM nodes WHERE lat BETWEEN ? AND ? AND lng BETWEEN ? AND ?',
      [bbox.minLat, bbox.maxLat, bbox.minLng, bbox.maxLng]
    );
    
    const coords = new Map();
    for (const n of rows) coords.set(n.id, { id: n.id, lat: n.lat, lng: n.lng });
    nodeIndex = { bbox, coords, loadedAt: Date.now() };
    return nodeIndex;
  }

  function edgeAllowsMode(edge, mode) {
    if (!edge) return false;
    const access = edge.access;
    if (access === 'no' || access === 'private' || access === false || access === 0) return false;

    if (mode === 'walking') {
      if (edge.foot === 'no' || edge.foot === false || edge.foot === 0) return false;
      if (typeof edge.highway === 'string' && /^(motorway|trunk)(_link)?$/i.test(edge.highway)) return false;
    } else {
      if (edge.motor_vehicle === 'no' || edge.motor_vehicle === false || edge.motor_vehicle === 0) return false;
      if (edge.vehicle === 'no' || edge.vehicle === false || edge.vehicle === 0) return false;
      if (typeof edge.highway === 'string' && /^(footway|path|pedestrian|steps)$/i.test(edge.highway)) return false;
    }
    return true;
  }

  function edgeAllowsReverse(edge) {
    const oneway = edge.oneway;
    if (oneway === 1 || oneway === true || oneway === 'yes' || oneway === '1') return false;
    if (oneway === -1 || oneway === '-1') return false;
    return true;
  }

  async function findNearestNode(db, lat, lng, requireConnected) {
    const boxDegrees = [0.01, 0.03, 0.08, 0.2];
    let bestAnywhere = null;
    let bestAnywhereDist = Infinity;

    for (const d of boxDegrees) {
      const rows = await runQuery(
        db,
        'SELECT id, lat, lng FROM nodes WHERE lat BETWEEN ? AND ? AND lng BETWEEN ? AND ?',
        [lat - d, lat + d, lng - d, lng + d]
      );
      if (!rows.length) continue;

      let best = null, bestDist = Infinity;
      for (const row of rows) {
        const dist = haversineM(lat, lng, row.lat, row.lng);
        if (!Number.isFinite(dist)) continue;
        if (dist >= bestDist) continue;

        if (dist < bestAnywhereDist) {
          bestAnywhereDist = dist;
          bestAnywhere = row;
        }

        if (requireConnected) {
          const check = await runQuery(
            db,
            'SELECT COUNT(*) as c FROM edges WHERE from_id = ? OR to_id = ?',
            [row.id, row.id]
          );
          const edgeCount = readCount(check);
          if (edgeCount < 2) continue;
        }

        best = row;
        bestDist = dist;
      }

      if (best) return best;
    }

    if (bestAnywhere) {
      console.warn('[A*] No connected node found near', { lat, lng, fallbackDistM: Math.round(bestAnywhereDist) });
    } else {
      console.warn('[A*] No node found near at all', { lat, lng });
    }
    return bestAnywhere;
  }

  async function findNearestEdge(db, lat, lng, maxDistanceM) {
    const node = await findNearestNode(db, lat, lng);
    if (!node) return null;

    const [outgoing, incoming] = await Promise.all([
      runQuery(db, 'SELECT * FROM edges WHERE from_id = ?', [node.id]),
      runQuery(db, 'SELECT * FROM edges WHERE to_id = ?', [node.id])
    ]);
    const candidates = outgoing.concat(incoming);
    if (!candidates.length) return null;

    const nodeCache = new Map([[node.id, node]]);
    async function coordsFor(id) {
      if (nodeCache.has(id)) return nodeCache.get(id);
      const rows = await runQuery(db, 'SELECT id, lat, lng FROM nodes WHERE id = ?', [id]);
      const row = rows[0] || null;
      if (row) nodeCache.set(id, row);
      return row;
    }

    let best = null, bestDist = Infinity;
    for (const edge of candidates) {
      const a = await coordsFor(edge.from_id);
      const b = await coordsFor(edge.to_id);
      if (!a || !b) continue;

      let dist = Infinity;
      let geom = null;
      try { geom = edge.geometry ? JSON.parse(edge.geometry) : null; } catch (e) { geom = null; }

      if (Array.isArray(geom) && geom.length >= 2) {
        for (let i = 0; i < geom.length - 1; i++) {
          const p1 = { lat: geom[i][0], lng: geom[i][1] };
          const p2 = { lat: geom[i + 1][0], lng: geom[i + 1][1] };
          dist = Math.min(dist, pointToSegmentM({ lat, lng }, p1, p2));
        }
      } else {
        dist = pointToSegmentM({ lat, lng }, a, b);
      }

      if (dist < bestDist) { bestDist = dist; best = edge; }
    }

    if (!best) return null;
    if (maxDistanceM != null && bestDist > maxDistanceM) return null;
    return best.id;
  }

  async function matchHazardToEdge(db, lat, lng) {
    if (!db || lat == null || lng == null) return null;
    try {
      return await findNearestEdge(db, lat, lng, 80);
    } catch (err) {
      console.warn('[BiyaHERO] A* hazard-edge matching failed:', err.message || err);
      return null;
    }
  }

  function edgeGeometryPoints(edge, fromNode, toNode) {
    let geom = null;
    try { geom = edge.geometry ? JSON.parse(edge.geometry) : null; } catch (e) { geom = null; }
    if (Array.isArray(geom) && geom.length) {
      // Edge geometry is a packed [a, b] pair per point, not named fields
      // like nodes.lat/nodes.lng above — and route-graph exports (this
      // bundled laguna_routing.db included, built the same way OSRM/
      // GeoJSON tooling does) near-universally store that pair as
      // [lng, lat], not [lat, lng]. Reading it as [lat, lng] was exactly
      // this bug: for anywhere in Laguna (~14°N, 121°E), that put ~121
      // in the "latitude" slot — outside the valid ±90° range entirely —
      // so Leaflet had a real polyline object (routing math, distance,
      // and ETA all still came out looking plausible) that plotted
      // nowhere sane on the actual map. Straight-line edges (no stored
      // geometry, just the two endpoint nodes below) were never affected,
      // since those already come from nodes.lat/nodes.lng by name — which
      // is why the route looked like it "sort of" worked rather than
      // failing outright.
      // Rather than assume one convention and risk being wrong about
      // THIS bundled file, check: a real Laguna latitude is always under
      // 90; if the first coordinate isn't, the pair is [lng, lat] and
      // needs swapping. Self-correcting regardless of which way the
      // source data actually was.
      const first = geom[0];
      const swapped = Array.isArray(first) && Math.abs(first[0]) > 90;
      return geom.map(([a, b]) => swapped ? { lat: b, lng: a } : { lat: a, lng: b });
    }
    const pts = [];
    if (fromNode) pts.push({ lat: fromNode.lat, lng: fromNode.lng });
    if (toNode) pts.push({ lat: toNode.lat, lng: toNode.lng });
    return pts;
  }

  // ---------------------------------------------------------------------
  // Planar helpers (meters, local equirectangular around a point)
  // ---------------------------------------------------------------------
  const KY = 110540;
  function kxFor(lat) { return 111320 * Math.cos(toRad(lat)); }

  function angDiffDeg(a, b) {
    const d = Math.abs(a - b) % 360;
    return d > 180 ? 360 - d : d;
  }

  // Projects `point` onto a polyline of {lat,lng}. Returns the closest
  // position, its distance (m), how far along the polyline it sits (m),
  // and the local travel bearing of the segment it landed on.
  function projectOnPolyline(pts, point) {
    const kx = kxFor(point.lat);
    let best = null;
    let cum = 0;
    for (let i = 0; i < pts.length - 1; i++) {
      const ax = (pts[i].lng - point.lng) * kx, ay = (pts[i].lat - point.lat) * KY;
      const bx = (pts[i + 1].lng - point.lng) * kx, by = (pts[i + 1].lat - point.lat) * KY;
      const dx = bx - ax, dy = by - ay;
      const len2 = dx * dx + dy * dy;
      const segLen = Math.sqrt(len2);
      let t = len2 > 0 ? (-ax * dx - ay * dy) / len2 : 0;
      t = Math.max(0, Math.min(1, t));
      const cx = ax + t * dx, cy = ay + t * dy;
      const dist = Math.hypot(cx, cy);
      if (!best || dist < best.distM) {
        best = {
          distM: dist,
          segIdx: i,
          alongStartM: cum + segLen * t,
          lat: point.lat + cy / KY,
          lng: point.lng + cx / kx,
          bearingDeg: (Math.atan2(dx, dy) * 180 / Math.PI + 360) % 360
        };
      }
      cum += segLen;
    }
    if (best) best.totalM = cum;
    return best;
  }

  function polylineLengthM(pts) {
    let total = 0;
    for (let i = 1; i < pts.length; i++) {
      total += haversineM(pts[i - 1].lat, pts[i - 1].lng, pts[i].lat, pts[i].lng);
    }
    return total;
  }

  // Edge geometry as {lat,lng}[] oriented from_id -> to_id, parsed once and
  // cached on the edge row (the edge index itself is cached for minutes).
  function orientedEdgePoints(edge) {
    if (edge._pts) return edge._pts;
    const nodes = nodeIndex && nodeIndex.coords;
    const pts = edgeGeometryPoints(
      edge,
      nodes && nodes.get(edge.from_id),
      nodes && nodes.get(edge.to_id)
    );
    edge._pts = pts;
    return pts;
  }

  // ---------------------------------------------------------------------
  // START SNAP: nearest ROAD (edge), never a far-away one.
  //
  // The old code snapped the start to the nearest graph NODE with search
  // boxes growing up to ~0.2 degrees (~22 km) and no distance limit, so a
  // recalculation from a GPS fix that was a bit off could happily start on
  // a completely different road. Now:
  //   * snapping is to the nearest point on the nearest edge's real
  //     geometry, within `maxDistM` (derived from GPS accuracy);
  //   * nothing within that distance => return null (caller keeps its
  //     current route / uses another tier) instead of teleporting;
  //   * when the device heading is known, roads running against the
  //     direction of travel are penalised, so a parallel road or the
  //     opposite carriageway doesn't win over the one being driven.
  // ---------------------------------------------------------------------
  function snapToNearestEdge(point, maxDistM, mode, headingDeg) {
    const nodes = nodeIndex.coords;
    const kx = kxFor(point.lat);
    let best = null;

    for (const list of edgeIndex.byFrom.values()) {
      for (const edge of list) {
        if (!edgeAllowsMode(edge, mode)) continue;
        const a = nodes.get(edge.from_id), b = nodes.get(edge.to_id);
        if (!a || !b) continue;

        // Cheap prefilter on the straight chord (slack for curvy edges).
        const slack = Math.min(250, (edge.length_m || 0) * 0.5);
        const ax = (a.lng - point.lng) * kx, ay = (a.lat - point.lat) * KY;
        const bx = (b.lng - point.lng) * kx, by = (b.lat - point.lat) * KY;
        const dx = bx - ax, dy = by - ay;
        const len2 = dx * dx + dy * dy;
        let t = len2 > 0 ? (-ax * dx - ay * dy) / len2 : 0;
        t = t < 0 ? 0 : (t > 1 ? 1 : t);
        if (Math.hypot(ax + t * dx, ay + t * dy) > maxDistM + slack) continue;

        const pts = orientedEdgePoints(edge);
        if (!pts || pts.length < 2) continue;
        const proj = projectOnPolyline(pts, point);
        if (!proj || proj.distM > maxDistM) continue;

        let score = proj.distM;
        if (headingDeg != null) {
          const d = angDiffDeg(proj.bearingDeg, headingDeg);
          const mis = edgeAllowsReverse(edge) ? Math.min(d, 180 - d) : d;
          if (mis > 90) score += 40;
          else if (mis > 60) score += 15;
          else if (mis > 35) score += 5;
        }
        if (!best || score < best.score) best = { edge, pts, proj, score };
      }
    }
    return best;
  }

  // The route may start by travelling from the snapped point to either end
  // of the snapped edge. Offer both (as search sources with their true
  // starting cost) so A* picks the better one, unless the heading clearly
  // says which way we are going / one-way rules forbid a direction.
  function startCandidatesFromSnap(snap, headingDeg) {
    const { edge, pts, proj } = snap;
    const here = { lat: proj.lat, lng: proj.lng };
    const forwardPts = [here].concat(pts.slice(proj.segIdx + 1));
    const backwardPts = [here].concat(pts.slice(0, proj.segIdx + 1).reverse());

    const out = [{
      nodeId: edge.to_id,
      cost: Math.max(0, proj.totalM - proj.alongStartM),
      pts: forwardPts
    }];
    if (edgeAllowsReverse(edge)) {
      out.push({ nodeId: edge.from_id, cost: Math.max(0, proj.alongStartM), pts: backwardPts });
    }

    if (headingDeg != null && out.length === 2) {
      const dFwd = angDiffDeg(proj.bearingDeg, headingDeg);
      if (dFwd < 70) out.pop();            // clearly heading from -> to
      else if (dFwd > 110) out.shift();    // clearly heading to -> from
    }
    return out;
  }

  // Goal: nearest CONNECTED node within a cap (destinations are often a
  // building / barangay centre, so this is generous, but not unlimited).
  function nearestConnectedNode(point, maxDistM) {
    const kx = kxFor(point.lat);
    let best = null, bestD = Infinity;
    for (const n of nodeIndex.coords.values()) {
      const d = Math.hypot((n.lng - point.lng) * kx, (n.lat - point.lat) * KY);
      if (d >= bestD || d > maxDistM) continue;
      const count = (edgeIndex.byFrom.get(n.id) || []).length +
                    (edgeIndex.byTo.get(n.id) || []).length;
      if (count < 2) continue;
      best = n; bestD = d;
    }
    return best ? { node: best, distM: bestD } : null;
  }

  // ---------------------------------------------------------------------
  // HAZARDS: matched to edges geometrically, right here, every route.
  //
  // `hazards` = [{ lat, lng, mult, penaltyM, block, radiusM }]. Every edge
  // passing within radiusM of a hazard gets cost = length * mult + penaltyM.
  // Doing the matching per request (instead of relying on an async,
  // fire-and-forget "graphEdgeid" computed once per hazard) means a hazard
  // added a second ago already affects the very next route, and hazards
  // that never matched before (mid-edge, or restored from storage) count.
  // ---------------------------------------------------------------------
  function buildHazardCostMap(hazardList) {
    const costs = new Map();
    if (!hazardList || !hazardList.length) return costs;
    const nodes = nodeIndex.coords;

    for (const h of hazardList) {
      if (!Number.isFinite(h.lat) || !Number.isFinite(h.lng)) continue;
      const kx = kxFor(h.lat);
      const dLat = 700 / KY, dLng = 700 / kx;
      const radius = h.radiusM || 40;
      const seen = new Set();

      for (const n of nodes.values()) {
        if (Math.abs(n.lat - h.lat) > dLat || Math.abs(n.lng - h.lng) > dLng) continue;
        const incident = (edgeIndex.byFrom.get(n.id) || []).concat(edgeIndex.byTo.get(n.id) || []);
        for (const edge of incident) {
          if (seen.has(edge.id)) continue;
          seen.add(edge.id);
          const pts = orientedEdgePoints(edge);
          if (!pts || pts.length < 2) continue;
          const proj = projectOnPolyline(pts, h);
          if (!proj || proj.distM > radius) continue;

          const mult = h.mult || 1, penaltyM = h.penaltyM || 0;
          const prev = costs.get(edge.id);
          if (!prev) {
            costs.set(edge.id, { mult, penaltyM, block: !!h.block });
          } else {
            prev.mult = Math.max(prev.mult, mult);
            prev.penaltyM = Math.max(prev.penaltyM, penaltyM);
            prev.block = prev.block || !!h.block;
          }
        }
      }
    }
    return costs;
  }

  async function findRoute(db, origin, dest, options) {
    const opts = options || {};
    const hazardWeightForEdge = opts.hazardWeightForEdge;
    const maxExpansions = opts.maxExpansions || 25000;
    const maxMs = opts.maxMs || 3000;
    const mode = opts.mode || 'car';
    const headingDeg = Number.isFinite(opts.startHeadingDeg) ? opts.startHeadingDeg : null;
    // How far from the GPS fix a road may be and still count as "the road
    // we're on". Grows with reported GPS error, but is always capped.
    const startSnapMaxM = opts.startSnapMaxM ||
      Math.max(80, Math.min(250, (opts.originAccuracyM || 0) * 1.5 + 40));
    const goalSnapMaxM = opts.goalSnapMaxM || 2000;

    if (!db) {
      console.warn('[A*] EXIT: no db handle');
      return null;
    }

    const bbox = bboxFor(origin, dest);

    try {
      await ensureEdgeIndexForBbox(db, bbox);
      await ensureNodeIndexForBbox(db, bbox);
    } catch (err) {
      console.warn('[A*] EXIT: index build failed', err.message || err);
      return null;
    }

    const startSnap = snapToNearestEdge(origin, startSnapMaxM, mode, headingDeg);
    if (!startSnap) {
      console.warn('[A*] EXIT: no road within', Math.round(startSnapMaxM),
        'm of the start - refusing to snap to a far-away road');
      return null;
    }
    const startCands = startCandidatesFromSnap(startSnap, headingDeg);
    const startByNode = new Map(startCands.map(c => [c.nodeId, c]));

    const goalHit = nearestConnectedNode(dest, goalSnapMaxM);
    if (!goalHit) {
      console.warn('[A*] EXIT: no connected road within', goalSnapMaxM, 'm of the destination');
      return null;
    }
    const goalNode = goalHit.node;

    const hazardCosts = buildHazardCostMap(opts.hazards);

    const nodeCoords = nodeIndex.coords;
    const gScore = new Map();
    const cameFrom = new Map();
    const closed = new Set();
    const open = new MinHeap();

    for (const c of startCands) {
      const nn = nodeCoords.get(c.nodeId);
      if (!nn) continue;
      gScore.set(c.nodeId, c.cost);
      open.push(c.nodeId, c.cost + haversineM(nn.lat, nn.lng, goalNode.lat, goalNode.lng));
    }
    if (!open.size) {
      console.warn('[A*] EXIT: start edge endpoints missing from node index');
      return null;
    }

    let expansions = 0;
    const startTime = performance.now();

    while (open.size && expansions < maxExpansions) {
      if ((expansions & 0x3f) === 0 && performance.now() - startTime > maxMs) {
        return null;
      }

      const currentId = open.pop();
      if (closed.has(currentId)) continue;
      closed.add(currentId);
      expansions++;

      if (currentId === goalNode.id) {
        const result = reconstructPath(cameFrom, currentId, gScore.get(currentId), startByNode, hazardCosts);
        if (result) {
          result.startSnapM = startSnap.proj.distM;
          result.goalSnapM = goalHit.distM;
        }
        return result;
      }

      const outgoing = edgeIndex.byFrom.get(currentId) || [];
      const incoming = edgeIndex.byTo.get(currentId) || [];

      const candidates = [];
      for (const edge of outgoing) candidates.push({ edge, neighborId: edge.to_id, forward: true });
      for (const edge of incoming) {
        if (edge.from_id === currentId) continue;
        if (!edgeAllowsReverse(edge)) continue;
        candidates.push({ edge, neighborId: edge.from_id, forward: false });
      }

      for (const { edge, neighborId, forward } of candidates) {
        if (closed.has(neighborId)) continue;
        if (!edgeAllowsMode(edge, mode)) continue;

        let mult = 1, penaltyM = 0;
        const hz = hazardCosts.get(edge.id);
        if (hz) { mult = hz.mult; penaltyM = hz.penaltyM; }
        if (hazardWeightForEdge) mult *= (hazardWeightForEdge(edge) || 1);

        const baseCost = edge.length_m != null ? edge.length_m
          : (edge.weight != null ? edge.weight
          : (edge.base_weight != null ? edge.base_weight : 1));
        const stepCost = baseCost * mult + penaltyM;

        const tentativeG = gScore.get(currentId) + stepCost;
        const knownG = gScore.has(neighborId) ? gScore.get(neighborId) : Infinity;
        if (tentativeG < knownG) {
          cameFrom.set(neighborId, { from: currentId, edge, forward });
          gScore.set(neighborId, tentativeG);

          const neighborNode = nodeCoords.get(neighborId);
          const h = neighborNode
            ? haversineM(neighborNode.lat, neighborNode.lng, goalNode.lat, goalNode.lng)
            : 0;
          open.push(neighborId, tentativeG + h);
        }
      }
    }

    return null;
  }

  function reconstructPath(cameFrom, goalId, totalWeight, startByNode, hazardCosts) {
    const edgesUsed = [];
    let cur = goalId;
    while (cameFrom.has(cur)) {
      const step = cameFrom.get(cur);
      edgesUsed.push({ edge: step.edge, forward: step.forward !== false });
      cur = step.from;
    }
    const rootId = cur;
    edgesUsed.reverse();

    const pts = [];
    function pushPt(p) {
      const last = pts[pts.length - 1];
      if (!last || last.lat !== p.lat || last.lng !== p.lng) pts.push(p);
    }

    // Begin exactly where the device was snapped onto the road, then run
    // along the start edge to the node the search left from.
    const startCand = startByNode && startByNode.get(rootId);
    if (startCand) startCand.pts.forEach(pushPt);

    let blockedEdgesUsed = 0;
    edgesUsed.forEach(({ edge, forward }) => {
      let segPts = orientedEdgePoints(edge);
      if (!forward) segPts = segPts.slice().reverse();
      segPts.forEach(pushPt);
      const hz = hazardCosts && hazardCosts.get(edge.id);
      if (hz && hz.block) blockedEdgesUsed++;
    });

    if (pts.length < 2) return null;
    return {
      pts,
      distanceM: polylineLengthM(pts),
      weight: totalWeight,
      blockedEdgesUsed
    };
  }

  window.AStarRouter = {
    findRoute,
    matchHazardToEdge,
    findNearestNode,
    findNearestEdge,
    invalidateIndexes() { edgeIndex = null; nodeIndex = null; }
  };
})();