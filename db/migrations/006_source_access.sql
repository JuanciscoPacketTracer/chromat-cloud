CREATE TABLE IF NOT EXISTS monitoring_source_alerts (
  source_id CHAR(36) NOT NULL,
  crop VARCHAR(64) NOT NULL,
  chat_id VARCHAR(128) NOT NULL,
  created_at DATETIME(3) NOT NULL,
  PRIMARY KEY (source_id, crop),
  CONSTRAINT fk_source_alerts_source
    FOREIGN KEY (source_id) REFERENCES monitoring_sources (source_id)
) ENGINE=InnoDB;

INSERT IGNORE INTO monitoring_source_alerts (source_id, crop, chat_id, created_at)
SELECT source_id, crop, alert_chat_id, created_at
  FROM monitoring_sources
 WHERE alert_chat_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS producer_sessions (
  session_id CHAR(36) NOT NULL PRIMARY KEY,
  producer_id CHAR(36) NOT NULL,
  token_hash BINARY(32) NOT NULL UNIQUE,
  expires_at DATETIME(3) NOT NULL,
  created_at DATETIME(3) NOT NULL,
  revoked_at DATETIME(3) NULL,
  CONSTRAINT fk_producer_sessions_producer
    FOREIGN KEY (producer_id) REFERENCES producer_accounts (producer_id)
) ENGINE=InnoDB;

INSERT IGNORE INTO schema_migrations (version)
VALUES ("006_source_access");
