CREATE TABLE IF NOT EXISTS users (
 id CHAR(36) PRIMARY KEY, email VARCHAR(254) NOT NULL UNIQUE, password_hash VARCHAR(255) NOT NULL,
 name VARCHAR(100) NOT NULL, role ENUM('user','admin') NOT NULL DEFAULT 'user',
 status ENUM('active','disabled') NOT NULL DEFAULT 'active',
 created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3), updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3)
) ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS refresh_tokens (
 token_hash CHAR(64) PRIMARY KEY, user_id CHAR(36) NOT NULL, family_id CHAR(36) NOT NULL,
 expires_at DATETIME(3) NOT NULL, revoked_at DATETIME(3) NULL,
 FOREIGN KEY(user_id) REFERENCES users(id), INDEX(family_id), INDEX(expires_at)
) ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS devices (
 id CHAR(36) PRIMARY KEY, sn VARCHAR(64) NOT NULL UNIQUE, device_key_encrypted TEXT NOT NULL,
 claim_code_hash CHAR(64) NULL, owner_user_id CHAR(36) NULL, name VARCHAR(100) NOT NULL,
 model VARCHAR(64) NOT NULL, hardware_version VARCHAR(32) NOT NULL, firmware_version VARCHAR(32) NOT NULL DEFAULT 'unknown',
 capabilities JSON NOT NULL, channels JSON NOT NULL, disabled BOOLEAN NOT NULL DEFAULT FALSE, online BOOLEAN NOT NULL DEFAULT FALSE,
 last_seen DATETIME(3) NULL, created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
 updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
 FOREIGN KEY(owner_user_id) REFERENCES users(id), INDEX(owner_user_id), INDEX(online), INDEX(disabled)
) ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS device_states (
 device_id CHAR(36) PRIMARY KEY, state JSON NOT NULL,
 updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
 FOREIGN KEY(device_id) REFERENCES devices(id)
) ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS firmwares (
 id CHAR(36) PRIMARY KEY, model VARCHAR(64) NOT NULL, hardware_version VARCHAR(32) NOT NULL,
 version VARCHAR(32) NOT NULL, url VARCHAR(2048) NOT NULL, checksum CHAR(64) NOT NULL,
 file_size BIGINT UNSIGNED NOT NULL, release_notes TEXT NOT NULL, is_active BOOLEAN NOT NULL DEFAULT TRUE,
 created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3), UNIQUE(model,hardware_version,version)
) ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS device_commands (
 request_id CHAR(36) PRIMARY KEY, device_id CHAR(36) NOT NULL, user_id CHAR(36) NOT NULL,
 command VARCHAR(64) NOT NULL, payload JSON NOT NULL,
 status ENUM('pending','sent','success','failed','timeout') NOT NULL DEFAULT 'pending',
 error VARCHAR(255) NULL, created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
 sent_at DATETIME(3) NULL, ack_at DATETIME(3) NULL, expires_at DATETIME(3) NOT NULL,
 FOREIGN KEY(device_id) REFERENCES devices(id), FOREIGN KEY(user_id) REFERENCES users(id), INDEX(device_id,created_at), INDEX(status,expires_at)
) ENGINE=InnoDB;
CREATE TABLE IF NOT EXISTS device_logs (
 id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY, device_id CHAR(36) NULL, user_id CHAR(36) NULL,
 event_type VARCHAR(64) NOT NULL, payload JSON NOT NULL, created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
 INDEX(device_id,created_at), INDEX(created_at)
) ENGINE=InnoDB;
