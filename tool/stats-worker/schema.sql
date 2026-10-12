CREATE TABLE IF NOT EXISTS users (
  id TEXT PRIMARY KEY,
  first_seen INTEGER NOT NULL,
  last_seen INTEGER NOT NULL,
  version TEXT,
  lang TEXT,
  country TEXT,
  pings INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS users_last ON users (last_seen);
CREATE TABLE IF NOT EXISTS days (
  day TEXT NOT NULL,
  id TEXT NOT NULL,
  PRIMARY KEY (day, id)
);
