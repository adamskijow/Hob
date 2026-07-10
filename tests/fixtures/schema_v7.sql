-- Released by Hob v0.1.0, v0.2.0, and v0.3.0.
CREATE TABLE items (
    id TEXT PRIMARY KEY,
    raw_text TEXT NOT NULL,
    task TEXT NOT NULL,
    due_date TEXT,
    due_time TEXT,
    status TEXT NOT NULL,
    source TEXT NOT NULL,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    reminded INTEGER NOT NULL DEFAULT 0,
    repeat TEXT,
    priority TEXT NOT NULL DEFAULT 'normal',
    tag TEXT,
    snooze_until TEXT,
    note TEXT,
    waiting_since TEXT
);
CREATE TABLE action_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    batch_id TEXT NOT NULL,
    ts TEXT NOT NULL,
    action_type TEXT NOT NULL,
    item_id TEXT NOT NULL,
    before_json TEXT,
    after_json TEXT,
    inbound_message_id TEXT
);
CREATE INDEX idx_action_log_batch ON action_log(batch_id);
CREATE TABLE digests (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sent_at TEXT NOT NULL,
    items_json TEXT NOT NULL
);
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE sent_refs (tg_message_id INTEGER PRIMARY KEY, item_id TEXT NOT NULL);
INSERT INTO items VALUES (
    'a1', 'call mum', 'call mum', '2026-07-10', '18:00', 'open', 'capture',
    '2026-07-10T08:00:00', '2026-07-10T08:00:00', 0, NULL, 'high',
    'family', NULL, 'ask about trip', NULL
);
INSERT INTO meta VALUES ('item_seq', '1');
PRAGMA user_version = 7;
