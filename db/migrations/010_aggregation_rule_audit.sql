ALTER TABLE monitoring_states
  ADD COLUMN aggregation_rule_version VARCHAR(32) NOT NULL DEFAULT "1",
  ADD COLUMN aggregation_config JSON NULL;

UPDATE monitoring_states
   SET aggregation_config = JSON_OBJECT(
     "confidenceThreshold", 0.8,
     "consecutiveEvents", 3,
     "maximumAgeMs", 604800000,
     "ruleVersion", "1"
   )
 WHERE aggregation_config IS NULL;

CREATE TABLE IF NOT EXISTS aggregation_rule_versions (
  rule_version VARCHAR(32) NOT NULL,
  configuration JSON NOT NULL,
  created_at DATETIME(3) NOT NULL,
  PRIMARY KEY (rule_version)
) ENGINE=InnoDB;

INSERT IGNORE INTO schema_migrations (version)
VALUES ("010_aggregation_rule_audit");
