-- Compatible with API 0.1.x; additive migration for the previous worker.
CREATE TABLE IF NOT EXISTS monitoring_alerts (
  alert_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  source_id CHAR(36) NOT NULL,
  crop VARCHAR(64) NOT NULL,
  event_id CHAR(36) NOT NULL,
  from_stage VARCHAR(64) NULL,
  to_stage VARCHAR(64) NOT NULL,
  episode_seq INT UNSIGNED NOT NULL,
  chat_id VARCHAR(128) NULL,
  status ENUM('pending', 'sent', 'failed') NOT NULL DEFAULT 'pending',
  attempts TINYINT UNSIGNED NOT NULL DEFAULT 0,
  available_at DATETIME(3) NOT NULL,
  lease_owner VARCHAR(128) NULL,
  lease_expires_at DATETIME(3) NULL,
  last_error VARCHAR(255) NULL,
  created_at DATETIME(3) NOT NULL,
  sent_at DATETIME(3) NULL,
  UNIQUE KEY uq_monitoring_alert_identity
    (source_id, crop, to_stage, episode_seq),
  CONSTRAINT fk_monitoring_alert_source
    FOREIGN KEY (source_id) REFERENCES monitoring_sources (source_id),
  CONSTRAINT fk_monitoring_alert_event
    FOREIGN KEY (source_id, event_id)
    REFERENCES monitoring_events (source_id, event_id),
  INDEX idx_monitoring_alert_delivery
    (status, available_at, lease_expires_at)
) ENGINE=InnoDB;

INSERT IGNORE INTO schema_migrations (version)
VALUES ("012_alerts");
