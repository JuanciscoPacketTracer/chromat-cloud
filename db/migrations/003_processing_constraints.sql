SET @has_global_event_index = (
  SELECT COUNT(*)
    FROM information_schema.statistics
   WHERE table_schema = DATABASE()
     AND table_name = 'jobs'
     AND index_name = 'uq_jobs_event_id'
);
SET @drop_global_event_index = IF(
  @has_global_event_index > 0,
  'ALTER TABLE jobs DROP INDEX uq_jobs_event_id',
  'SELECT 1'
);
PREPARE drop_global_event_index FROM @drop_global_event_index;
EXECUTE drop_global_event_index;
DEALLOCATE PREPARE drop_global_event_index;

INSERT IGNORE INTO schema_migrations (version)
VALUES ("003_processing_constraints");
