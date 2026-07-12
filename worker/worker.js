// Listener analytics worker. Routes (same origin as the player):
//   POST /api/beat   heartbeat from the player while audio is playing
//   GET  /api/stats  aggregate "who's listening now" for analytics.html
//
// Privacy: stores a random per-pageload id, event type, chosen delay,
// playback position, and the country code Cloudflare supplies at the edge
// (request.cf.country). IP addresses are never read or stored.

const EVENTS = ['start', 'hb', 'stop'];
const STALE_MS = 150000; // heartbeats are 60s; 2.5 min without one = gone

export default {
  async fetch(req, env) {
    const url = new URL(req.url);

    if (url.pathname === '/api/beat' && req.method === 'POST') {
      let b;
      try { b = await req.json(); } catch { return new Response('bad json', { status: 400 }); }
      if (typeof b.sid !== 'string' || b.sid.length < 8 || b.sid.length > 64) {
        return new Response('bad sid', { status: 400 });
      }
      env.LISTENS.writeDataPoint({
        blobs: [
          b.sid,
          (req.cf && req.cf.country) || '??',
          EVENTS.includes(b.event) ? b.event : 'hb',
        ],
        doubles: [Number(b.delayMin) || 0, Number(b.posUtc) || 0],
        indexes: [b.sid],
      });
      return new Response(null, { status: 204 });
    }

    if (url.pathname === '/api/stats' && req.method === 'GET') {
      const sql = `
        SELECT blob1 AS sid, blob2 AS country, blob3 AS event,
               double1 AS delayMin, double2 AS posUtc,
               toUnixTimestamp(timestamp) AS ts
        FROM radio_listens
        WHERE timestamp > NOW() - INTERVAL '10' MINUTE
        FORMAT JSON`;
      const r = await fetch(
        `https://api.cloudflare.com/client/v4/accounts/${env.ACCOUNT_ID}/analytics_engine/sql`,
        { method: 'POST', headers: { Authorization: `Bearer ${env.ANALYTICS_TOKEN}` }, body: sql },
      );
      if (!r.ok) return new Response('query failed: ' + r.status, { status: 502 });
      const { data } = await r.json();

      // newest event per session id; sessions count as listening unless
      // their last word was "stop" or they've gone quiet
      const bySid = new Map();
      for (const row of data || []) {
        const t = Number(row.ts) * 1000;
        const cur = bySid.get(row.sid);
        if (!cur || t > cur.t) bySid.set(row.sid, { t, row });
      }
      const now = Date.now();
      const listeners = [];
      for (const { t, row } of bySid.values()) {
        if (row.event !== 'stop' && now - t < STALE_MS) {
          listeners.push({
            country: row.country,
            delayMin: Number(row.delayMin),
            posUtc: Number(row.posUtc),
          });
        }
      }
      return Response.json(
        { now: listeners.length, listeners, generated: new Date().toISOString() },
        { headers: { 'cache-control': 'public, max-age=15' } },
      );
    }

    if (url.pathname === '/api/history' && req.method === 'GET') {
      // Distinct (hour, session) pairs for 90 days; both views derive
      // from this one result. Days are bucketed in NZ time.
      const sql = `
        SELECT DISTINCT intDiv(toUnixTimestamp(timestamp), 3600) AS hr,
               blob1 AS sid
        FROM radio_listens
        WHERE timestamp > NOW() - INTERVAL '90' DAY
        FORMAT JSON`;
      const r = await fetch(
        `https://api.cloudflare.com/client/v4/accounts/${env.ACCOUNT_ID}/analytics_engine/sql`,
        { method: 'POST', headers: { Authorization: `Bearer ${env.ANALYTICS_TOKEN}` }, body: sql },
      );
      if (!r.ok) return new Response('query failed: ' + r.status, { status: 502 });
      const { data } = await r.json();

      const nzDay = new Intl.DateTimeFormat('en-CA', {
        timeZone: 'Pacific/Auckland', year: 'numeric', month: '2-digit', day: '2-digit',
      });
      const weekAgoHr = Math.floor(Date.now() / 3600000) - 7 * 24;
      const hourly = new Map();          // epoch-hour -> listeners
      const daily = new Map();           // NZ date -> Set of sids
      for (const row of data || []) {
        const hr = Number(row.hr);
        if (hr >= weekAgoHr) hourly.set(hr, (hourly.get(hr) || 0) + 1);
        const day = nzDay.format(new Date(hr * 3600000));
        if (!daily.has(day)) daily.set(day, new Set());
        daily.get(day).add(row.sid);
      }
      return Response.json({
        hourly: [...hourly].sort((a, b) => a[0] - b[0]),
        daily: [...daily].map(([d, s]) => [d, s.size]).sort(),
        generated: new Date().toISOString(),
      }, { headers: { 'cache-control': 'public, max-age=300' } });
    }

    return new Response('not found', { status: 404 });
  },
};
