CREATE TABLE IF NOT EXISTS sensor_readings (
 id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
 device_id CHAR(36) NOT NULL,
 temperature_c DECIMAL(5,2) NOT NULL,
 humidity_percent DECIMAL(5,2) NULL,
 recorded_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
 FOREIGN KEY(device_id) REFERENCES devices(id),
 INDEX(device_id, recorded_at)
) ENGINE=InnoDB;
