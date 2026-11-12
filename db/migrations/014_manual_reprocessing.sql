-- Compatible with API 0.1.x; marks jobs created by manual reprocessing.
ALTER TABLE jobs
  ADD COLUMN reprocessing BOOLEAN NOT NULL DEFAULT FALSE;

INSERT IGNORE INTO schema_migrations (version)
VALUES ("014_manual_reprocessing");
