ALTER TABLE devices
  MODIFY COLUMN device_type ENUM('relay','switch','sensor','other','switch_temp','switch_power','switch_temp_power','power_meter') NOT NULL DEFAULT 'relay',
  ADD COLUMN pzem_rx_pin TINYINT UNSIGNED NULL AFTER dht11_pin,
  ADD COLUMN pzem_tx_pin TINYINT UNSIGNED NULL AFTER pzem_rx_pin;

CREATE TABLE IF NOT EXISTS power_readings (
  id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  device_id CHAR(36) NOT NULL,
  voltage_v DECIMAL(6,2) NOT NULL,
  current_a DECIMAL(6,3) NOT NULL,
  power_w DECIMAL(8,2) NOT NULL,
  energy_kwh DECIMAL(10,3) NOT NULL,
  frequency_hz DECIMAL(5,2) NULL,
  power_factor DECIMAL(3,2) NULL,
  recorded_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  FOREIGN KEY (device_id) REFERENCES devices(id),
  INDEX (device_id, recorded_at)
) ENGINE=InnoDB;
