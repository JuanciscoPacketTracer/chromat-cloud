-- Compatible with API 0.1.x; additive migration for configurable alert spacing.
ALTER TABLE monitoring_states
  ADD COLUMN last_alert_at DATETIME(3) NULL;

UPDATE monitoring_states
   SET aggregation_config = JSON_SET(
     COALESCE(aggregation_config, JSON_OBJECT()),
     "$.minimumAlertIntervalMs",
     0
   )
 WHERE aggregation_config IS NOT NULL
   AND JSON_EXTRACT(aggregation_config, "$.minimumAlertIntervalMs") IS NULL;

INSERT IGNORE INTO schema_migrations (version)
VALUES ("013_alert_interval");
