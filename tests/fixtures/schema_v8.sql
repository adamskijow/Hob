-- Released by Hob v0.4.0.
CREATE TABLE items (
    id TEXT PRIMARY KEY, raw_text TEXT NOT NULL, task TEXT NOT NULL,
    due_date TEXT, due_time TEXT, status TEXT NOT NULL, source TEXT NOT NULL,
    created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
    reminded INTEGER NOT NULL DEFAULT 0, repeat TEXT,
    priority TEXT NOT NULL DEFAULT 'normal', tag TEXT, snooze_until TEXT,
    note TEXT, waiting_since TEXT
);
CREATE TABLE action_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT, batch_id TEXT NOT NULL, ts TEXT NOT NULL,
    action_type TEXT NOT NULL, item_id TEXT NOT NULL, before_json TEXT,
    after_json TEXT, inbound_message_id TEXT
);
CREATE INDEX idx_action_log_batch ON action_log(batch_id);
CREATE TABLE digests (
    id INTEGER PRIMARY KEY AUTOINCREMENT, sent_at TEXT NOT NULL,
    items_json TEXT NOT NULL
);
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE sent_refs (tg_message_id INTEGER PRIMARY KEY, item_id TEXT NOT NULL);
CREATE TABLE inbox (
    key TEXT PRIMARY KEY, update_id INTEGER NOT NULL, kind TEXT NOT NULL,
    payload_json TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
    attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT,
    created_at TEXT NOT NULL, completed_at TEXT
);
CREATE INDEX idx_inbox_pending ON inbox(status, update_id);
CREATE TABLE outbox (
    id INTEGER PRIMARY KEY AUTOINCREMENT, dedupe_key TEXT NOT NULL UNIQUE,
    chat_id INTEGER NOT NULL, kind TEXT NOT NULL, text TEXT NOT NULL,
    item_id TEXT, markup_json TEXT, status TEXT NOT NULL DEFAULT 'pending',
    attempts INTEGER NOT NULL DEFAULT 0, last_error TEXT, created_at TEXT NOT NULL,
    sent_at TEXT, telegram_message_id INTEGER
);
CREATE INDEX idx_outbox_pending ON outbox(status, id);
INSERT INTO items VALUES (
    'a1', 'water plants every 2 weeks', 'water plants', '2026-07-13', '09:00',
    'open', 'capture', '2026-06-29T09:00:00', '2026-06-29T09:00:00',
    0, 'every:2:week', 'normal', NULL, NULL, NULL, NULL
);
INSERT INTO meta VALUES ('item_seq', '1');
PRAGMA user_version = 8;
