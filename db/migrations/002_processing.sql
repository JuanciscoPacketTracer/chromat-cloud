ALTER TABLE jobs
  ADD COLUMN lease_owner VARCHAR(128) NULL,
  ADD COLUMN lease_expires_at DATETIME(3) NULL,
  ADD COLUMN last_error VARCHAR(255) NULL,
  ADD COLUMN updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3);

ALTER TABLE jobs
  ADD UNIQUE KEY uq_jobs_event_id (event_id);

CREATE TABLE IF NOT EXISTS analysis_runs (
  run_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  source_id CHAR(36) NOT NULL,
  event_id CHAR(36) NOT NULL,
  algorithm VARCHAR(32) NOT NULL,
  algorithm_version VARCHAR(32) NOT NULL,
  model_version VARCHAR(32) NULL,
  model_sha256 CHAR(64) NULL,
  started_at DATETIME(3) NOT NULL,
  completed_at DATETIME(3) NULL,
  status ENUM('running', 'completed', 'failed') NOT NULL,
  result JSON NULL,
  error_message VARCHAR(255) NULL,
  CONSTRAINT fk_analysis_runs_event
    FOREIGN KEY (source_id, event_id)
    REFERENCES monitoring_events (source_id, event_id),
  INDEX idx_analysis_runs_event (source_id, event_id, run_id)
) ENGINE=InnoDB;

ALTER TABLE monitoring_events
  ADD COLUMN current_result_run_id BIGINT UNSIGNED NULL;

INSERT IGNORE INTO schema_migrations (version)
VALUES ("002_processing");
