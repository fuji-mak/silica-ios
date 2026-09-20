CREATE TABLE notion_pending_connections (
  completion_hash TEXT PRIMARY KEY,
  installation_id TEXT NOT NULL,
  access_token_ciphertext TEXT NOT NULL,
  workspace_id TEXT,
  workspace_name TEXT,
  workspace_icon TEXT,
  bot_id TEXT,
  owner_user_id TEXT,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  FOREIGN KEY (installation_id) REFERENCES installations(installation_id) ON DELETE CASCADE
);

CREATE INDEX notion_pending_expiry_idx ON notion_pending_connections(expires_at);
