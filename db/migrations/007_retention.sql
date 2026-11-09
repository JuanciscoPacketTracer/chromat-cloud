ALTER TABLE monitoring_events
  ADD COLUMN retention_hold BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN raw_deleted_at DATETIME(3) NULL,
  ADD COLUMN derived_deleted_at DATETIME(3) NULL;

INSERT IGNORE INTO schema_migrations (version)
VALUES ("007_retention");
