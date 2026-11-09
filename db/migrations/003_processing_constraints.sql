ALTER TABLE jobs
  ADD UNIQUE KEY uq_jobs_event_id (event_id);

INSERT IGNORE INTO schema_migrations (version)
VALUES ("003_processing_constraints");
