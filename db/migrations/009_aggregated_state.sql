CREATE TABLE IF NOT EXISTS monitoring_states (
  source_id CHAR(36) NOT NULL,
  crop VARCHAR(64) NOT NULL,
  current_stage VARCHAR(64) NULL,
  episode_seq INT UNSIGNED NOT NULL DEFAULT 0,
  consecutive_stage VARCHAR(64) NULL,
  consecutive_count INT UNSIGNED NOT NULL DEFAULT 0,
  last_occurred_at DATETIME(3) NULL,
  last_confidence DECIMAL(6,4) NULL,
  updated_at DATETIME(3) NOT NULL,
  PRIMARY KEY (source_id, crop),
  CONSTRAINT fk_monitoring_states_source
    FOREIGN KEY (source_id) REFERENCES monitoring_sources (source_id)
) ENGINE=InnoDB;

INSERT IGNORE INTO schema_migrations (version)
VALUES ("009_aggregated_state");
