ALTER TABLE raw_files
  MODIFY storage_path VARCHAR(255) NULL;

INSERT IGNORE INTO schema_migrations (version)
VALUES ("008_raw_tombstones");
