ALTER TABLE devices
  ADD COLUMN temperature_offset_c DECIMAL(5,2) NOT NULL DEFAULT 0 AFTER dht11_pin;
