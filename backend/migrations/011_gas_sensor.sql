ALTER TABLE devices
  MODIFY COLUMN device_type ENUM('relay','switch','sensor','other','switch_temp','switch_power','switch_temp_power','power_meter','switch_gas','sensor_gas','switch_temp_gas') NOT NULL DEFAULT 'relay',
  ADD COLUMN gas_pin TINYINT UNSIGNED NULL AFTER pzem_tx_pin;

CREATE TABLE IF NOT EXISTS gas_readings (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  device_id CHAR(36) NOT NULL,
  gas_detected BOOLEAN NOT NULL DEFAULT FALSE,
  gas_ppm DECIMAL(8,2) NULL,
  recorded_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  FOREIGN KEY (device_id) REFERENCES devices(id),
  INDEX (device_id, recorded_at)
) ENGINE=InnoDB;
