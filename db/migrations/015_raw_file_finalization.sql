-- Compatible with API 0.1.x; jobs may run only after the raw file is finalized.
ALTER TABLE raw_files
  ADD COLUMN state ENUM('staged', 'ready') NOT NULL DEFAULT 'ready',
  ADD COLUMN staged_path VARCHAR(255) NULL;

INSERT IGNORE INTO schema_migrations (version)
VALUES ("015_raw_file_finalization");
