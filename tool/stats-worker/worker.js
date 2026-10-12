// Anonymous usage counter for STL Вага.
// POST /ping  {id, v, lang}  — an install says "I am here" (random id, no personal data).
// GET  /stats (header x-admin-key) — numbers for the author only.
const JSON_HDR = { "content-type": "application/json; charset=utf-8" };
const MIN = 60_000, DAY = 86_400_000;

function json(obj, status = 200) {
  return new Response(JSON.stringify(obj), { status, headers: JSON_HDR });
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);

    if (url.pathname === "/ping" && req.method === "POST") {
      let b;
      try { b = await req.json(); } catch { return json({ error: "bad json" }, 400); }
      const id = String(b.id || "");
      if (!/^[A-Za-z0-9-]{8,64}$/.test(id)) return json({ error: "bad id" }, 400);
      const now = Date.now();
      const v = String(b.v || "").slice(0, 32);
      const lang = String(b.lang || "").slice(0, 8);
      const country = String((req.cf && req.cf.country) || "").slice(0, 4);
      const day = new Date(now).toISOString().slice(0, 10);
      await env.DB.batch([
        env.DB.prepare(
          `INSERT INTO users (id, first_seen, last_seen, version, lang, country, pings)
           VALUES (?1, ?2, ?2, ?3, ?4, ?5, 1)
           ON CONFLICT(id) DO UPDATE SET last_seen = ?2, version = ?3, lang = ?4, country = ?5, pings = pings + 1`
        ).bind(id, now, v, lang, country),
        env.DB.prepare(`INSERT OR IGNORE INTO days (day, id) VALUES (?1, ?2)`).bind(day, id),
      ]);
      return json({ ok: true });
    }

    if (url.pathname === "/stats") {
      const key = req.headers.get("x-admin-key") || "";
      if (!env.ADMIN_KEY || key !== env.ADMIN_KEY) return json({ error: "forbidden" }, 403);
      const now = Date.now();
      const count = (sql, ...a) => env.DB.prepare(sql).bind(...a).first("n");
      const [online, day, week, month, total, newWeek] = await Promise.all([
        count("SELECT COUNT(*) AS n FROM users WHERE last_seen > ?1", now - 10 * MIN),
        count("SELECT COUNT(*) AS n FROM users WHERE last_seen > ?1", now - DAY),
        count("SELECT COUNT(*) AS n FROM users WHERE last_seen > ?1", now - 7 * DAY),
        count("SELECT COUNT(*) AS n FROM users WHERE last_seen > ?1", now - 30 * DAY),
        count("SELECT COUNT(*) AS n FROM users"),
        count("SELECT COUNT(*) AS n FROM users WHERE first_seen > ?1", now - 7 * DAY),
      ]);
      const since = new Date(now - 13 * DAY).toISOString().slice(0, 10);
      const daily = (await env.DB.prepare(
        "SELECT day, COUNT(*) AS n FROM days WHERE day >= ?1 GROUP BY day ORDER BY day").bind(since).all()).results;
      const versions = (await env.DB.prepare(
        "SELECT version AS v, COUNT(*) AS n FROM users WHERE last_seen > ?1 GROUP BY version ORDER BY n DESC LIMIT 8")
        .bind(now - 30 * DAY).all()).results;
      const countries = (await env.DB.prepare(
        "SELECT country AS c, COUNT(*) AS n FROM users WHERE last_seen > ?1 GROUP BY country ORDER BY n DESC LIMIT 8")
        .bind(now - 30 * DAY).all()).results;
      return json({ online, day, week, month, total, newWeek, daily, versions, countries, at: now });
    }

    return new Response("STL Vaga stats", { headers: { "content-type": "text/plain" } });
  },
};
