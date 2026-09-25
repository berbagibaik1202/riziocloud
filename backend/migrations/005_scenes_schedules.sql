CREATE TABLE IF NOT EXISTS scenes (
 id CHAR(36) PRIMARY KEY,
 user_id CHAR(36) NOT NULL,
 device_id CHAR(36) NOT NULL,
 name VARCHAR(100) NOT NULL,
 actions JSON NOT NULL,
 enabled BOOLEAN NOT NULL DEFAULT TRUE,
 created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
 updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
 FOREIGN KEY(user_id) REFERENCES users(id),
 FOREIGN KEY(device_id) REFERENCES devices(id),
 INDEX(user_id,created_at), INDEX(device_id,enabled)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS schedules (
 id CHAR(36) PRIMARY KEY,
 user_id CHAR(36) NOT NULL,
 device_id CHAR(36) NOT NULL,
 scene_id CHAR(36) NOT NULL,
 name VARCHAR(100) NOT NULL,
 time_local CHAR(5) NOT NULL,
 timezone VARCHAR(64) NOT NULL DEFAULT 'Asia/Jakarta',
 weekdays JSON NOT NULL,
 enabled BOOLEAN NOT NULL DEFAULT TRUE,
 version INT UNSIGNED NOT NULL DEFAULT 1,
 created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
 updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3),
 FOREIGN KEY(user_id) REFERENCES users(id),
 FOREIGN KEY(device_id) REFERENCES devices(id),
 FOREIGN KEY(scene_id) REFERENCES scenes(id),
 INDEX(user_id,enabled), INDEX(device_id,enabled)
) ENGINE=InnoDB;

CREATE TABLE IF NOT EXISTS schedule_runs (
 schedule_id CHAR(36) NOT NULL,
 run_key VARCHAR(96) NOT NULL,
 executed_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
 mode ENUM('backend','device') NOT NULL DEFAULT 'backend',
 status VARCHAR(32) NOT NULL DEFAULT 'dispatched',
 PRIMARY KEY(schedule_id,run_key),
 FOREIGN KEY(schedule_id) REFERENCES schedules(id),
 INDEX(executed_at)
) ENGINE=InnoDB;
