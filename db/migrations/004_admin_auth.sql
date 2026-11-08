CREATE TABLE IF NOT EXISTS operators (
  operator_id CHAR(36) NOT NULL PRIMARY KEY,
  username VARCHAR(120) NOT NULL UNIQUE,
  password_hash VARCHAR(255) NOT NULL,
  status ENUM('active', 'revoked') NOT NULL DEFAULT 'active',
  created_at DATETIME(3) NOT NULL,
  last_login_at DATETIME(3) NULL
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS admin_sessions (
  session_id CHAR(36) NOT NULL PRIMARY KEY,
  operator_id CHAR(36) NOT NULL,
  token_hash BINARY(32) NOT NULL UNIQUE,
  csrf_hash BINARY(32) NOT NULL,
  expires_at DATETIME(3) NOT NULL,
  created_at DATETIME(3) NOT NULL,
  revoked_at DATETIME(3) NULL,
  CONSTRAINT fk_admin_sessions_operator
    FOREIGN KEY (operator_id) REFERENCES operators (operator_id)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS audit_log (
  audit_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY,
  occurred_at DATETIME(3) NOT NULL,
  action VARCHAR(64) NOT NULL,
  operator_id CHAR(36) NULL,
  source_id CHAR(36) NULL,
  request_ip VARCHAR(64) NULL,
  metadata JSON NULL,
  CONSTRAINT fk_audit_operator
    FOREIGN KEY (operator_id) REFERENCES operators (operator_id),
  INDEX idx_audit_occurred (occurred_at),
  INDEX idx_audit_action (action)
) ENGINE=InnoDB;

INSERT IGNORE INTO schema_migrations (version)
VALUES ("004_admin_auth");
