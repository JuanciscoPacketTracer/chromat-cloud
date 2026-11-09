CREATE TABLE IF NOT EXISTS monitoring_state_history (
  history_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  source_id CHAR(36) NOT NULL,
  crop VARCHAR(64) NOT NULL,
  event_id CHAR(36) NOT NULL,
  occurred_at DATETIME(3) NOT NULL,
  classification VARCHAR(64) NOT NULL,
  confidence DECIMAL(6,4) NOT NULL,
  consecutive_stage VARCHAR(64) NOT NULL,
  consecutive_count INT UNSIGNED NOT NULL,
  current_stage VARCHAR(64) NULL,
  episode_seq INT UNSIGNED NOT NULL,
  transition JSON NULL,
  created_at DATETIME(3) NOT NULL,
  CONSTRAINT fk_state_history_source
    FOREIGN KEY (source_id) REFERENCES monitoring_sources (source_id),
  CONSTRAINT fk_state_history_event
    FOREIGN KEY (source_id, event_id)
    REFERENCES monitoring_events (source_id, event_id),
  INDEX idx_state_history_source_crop_occurred
    (source_id, crop, occurred_at, history_id)
) ENGINE=InnoDB;

INSERT IGNORE INTO schema_migrations (version)
VALUES ("011_aggregated_state_history");
