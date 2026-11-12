-- Compatible with API 0.1.x; one event can produce only one job.
ALTER TABLE jobs
  ADD UNIQUE KEY uq_jobs_event_id (event_id);

INSERT IGNORE INTO schema_migrations (version)
VALUES ("016_job_event_uniqueness");
