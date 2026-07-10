-- Conversation log for the JamboFlow Diagnostic.
-- One row per exchange (user message + assistant reply), plus rows for
-- rate-limit rejections so real demand hitting the caps is visible.

CREATE TABLE IF NOT EXISTS turns (
  id            INTEGER PRIMARY KEY AUTOINCREMENT,
  convo_id      TEXT    NOT NULL,
  ts            TEXT    NOT NULL DEFAULT (datetime('now')),
  country       TEXT,
  kind          TEXT    NOT NULL DEFAULT 'exchange',  -- exchange | rate_limited | upstream_error
  user_msg      TEXT,
  assistant_msg TEXT,
  msg_count     INTEGER,                              -- conversation length at this point
  diagnosis     INTEGER NOT NULL DEFAULT 0            -- 1 when the structured diagnosis was delivered
);

CREATE INDEX IF NOT EXISTS idx_turns_convo ON turns(convo_id);
CREATE INDEX IF NOT EXISTS idx_turns_ts    ON turns(ts);
