CREATE TABLE IF NOT EXISTS app_releases (
  id CHAR(36) PRIMARY KEY,
  platform VARCHAR(32) NOT NULL DEFAULT 'android',
  app_name VARCHAR(64) NOT NULL DEFAULT 'RizIO Smart Controller',
  version VARCHAR(32) NOT NULL,
  version_code INT UNSIGNED NOT NULL DEFAULT 1,
  filename VARCHAR(255) NOT NULL,
  url VARCHAR(2048) NOT NULL,
  checksum CHAR(64) NOT NULL,
  file_size BIGINT UNSIGNED NOT NULL,
  release_notes TEXT NOT NULL,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  INDEX (platform, is_active, created_at)
) ENGINE=InnoDB;
