ALTER TABLE devices
  MODIFY COLUMN device_type ENUM('relay','switch','sensor','other') NOT NULL DEFAULT 'relay',
  ADD COLUMN dht11_pin TINYINT UNSIGNED NULL AFTER relay_type;
