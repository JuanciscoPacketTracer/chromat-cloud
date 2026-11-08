ALTER TABLE monitoring_sources
  MODIFY status ENUM('active', 'paused', 'revoked') NOT NULL DEFAULT 'active',
  ADD COLUMN crop VARCHAR(64) NOT NULL DEFAULT 'unknown',
  ADD COLUMN is_test BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN alert_chat_id VARCHAR(128) NULL;

CREATE TABLE IF NOT EXISTS monitoring_source_keys (
  key_id CHAR(36) NOT NULL PRIMARY KEY,
  source_id CHAR(36) NOT NULL,
  api_key_prefix VARCHAR(32) NOT NULL UNIQUE,
  api_key_hash BINARY(32) NOT NULL,
  created_at DATETIME(3) NOT NULL,
  expires_at DATETIME(3) NULL,
  revoked_at DATETIME(3) NULL,
  CONSTRAINT fk_source_keys_source
    FOREIGN KEY (source_id) REFERENCES monitoring_sources (source_id),
  INDEX idx_source_keys_source (source_id)
) ENGINE=InnoDB;

INSERT IGNORE INTO monitoring_source_keys
  (key_id, source_id, api_key_prefix, api_key_hash, created_at)
SELECT UUID(), source_id, api_key_prefix, api_key_hash, created_at
  FROM monitoring_sources;

ALTER TABLE monitoring_events
  ADD COLUMN crop VARCHAR(64) NOT NULL DEFAULT 'unknown';

CREATE TABLE IF NOT EXISTS producer_accounts (
  producer_id CHAR(36) NOT NULL PRIMARY KEY,
  username VARCHAR(120) NOT NULL UNIQUE,
  password_hash VARCHAR(255) NOT NULL,
  status ENUM('active', 'revoked') NOT NULL DEFAULT 'active',
  created_at DATETIME(3) NOT NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS producer_source_assignments (
  producer_id CHAR(36) NOT NULL,
  source_id CHAR(36) NOT NULL,
  permission ENUM('read') NOT NULL DEFAULT 'read',
  created_at DATETIME(3) NOT NULL,
  PRIMARY KEY (producer_id, source_id),
  CONSTRAINT fk_assignments_producer
    FOREIGN KEY (producer_id) REFERENCES producer_accounts (producer_id),
  CONSTRAINT fk_assignments_source
    FOREIGN KEY (source_id) REFERENCES monitoring_sources (source_id)
) ENGINE=InnoDB;

INSERT IGNORE INTO schema_migrations (version)
VALUES ("005_source_management");
