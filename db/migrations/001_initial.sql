CREATE TABLE IF NOT EXISTS schema_migrations (
  version VARCHAR(64) NOT NULL PRIMARY KEY,
  applied_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3)
) ENGINE=InnoDB;

INSERT IGNORE INTO schema_migrations (version)
VALUES ("001_initial");

CREATE TABLE IF NOT EXISTS monitoring_sources (
  source_id CHAR(36) NOT NULL PRIMARY KEY,
  name VARCHAR(120) NOT NULL,
  api_key_prefix VARCHAR(32) NOT NULL UNIQUE,
  api_key_hash BINARY(32) NOT NULL,
  status ENUM('active', 'revoked') NOT NULL DEFAULT 'active',
  created_at DATETIME(3) NOT NULL,
  revoked_at DATETIME(3) NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS monitoring_events (
  source_id CHAR(36) NOT NULL,
  event_id CHAR(36) NOT NULL,
  occurred_at DATETIME(3) NOT NULL,
  received_at DATETIME(3) NOT NULL,
  clock_suspect BOOLEAN NOT NULL DEFAULT FALSE,
  status ENUM('pending', 'processing', 'completed', 'failed') NOT NULL DEFAULT 'pending',
  temperature_c DECIMAL(6,2) NULL,
  humidity_rh DECIMAL(6,2) NULL,
  image_sha256 CHAR(64) NOT NULL,
  created_at DATETIME(3) NOT NULL,
  PRIMARY KEY (source_id, event_id),
  CONSTRAINT fk_events_source
    FOREIGN KEY (source_id) REFERENCES monitoring_sources (source_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS raw_files (
  source_id CHAR(36) NOT NULL,
  event_id CHAR(36) NOT NULL,
  storage_path VARCHAR(255) NOT NULL,
  media_type VARCHAR(32) NOT NULL,
  byte_size BIGINT UNSIGNED NOT NULL,
  sha256 CHAR(64) NOT NULL,
  created_at DATETIME(3) NOT NULL,
  PRIMARY KEY (source_id, event_id),
  CONSTRAINT fk_raw_files_event
    FOREIGN KEY (source_id, event_id)
    REFERENCES monitoring_events (source_id, event_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS jobs (
  source_id CHAR(36) NOT NULL,
  event_id CHAR(36) NOT NULL,
  state ENUM('queued', 'leased', 'done', 'failed') NOT NULL DEFAULT 'queued',
  attempts TINYINT UNSIGNED NOT NULL DEFAULT 0,
  available_at DATETIME(3) NOT NULL,
  created_at DATETIME(3) NOT NULL,
  PRIMARY KEY (source_id, event_id),
  CONSTRAINT fk_jobs_event
    FOREIGN KEY (source_id, event_id)
    REFERENCES monitoring_events (source_id, event_id)
) ENGINE=InnoDB;
