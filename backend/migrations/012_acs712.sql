ALTER TABLE devices
  MODIFY COLUMN device_type ENUM('relay','switch','sensor','other','switch_temp','switch_power','switch_temp_power','power_meter','switch_gas','sensor_gas','switch_temp_gas','current_meter','switch_current','switch_temp_current','switch_gas_current','switch_temp_gas_current','switch_temp_power_current') NOT NULL DEFAULT 'relay',
  ADD COLUMN acs712_pin TINYINT UNSIGNED NULL AFTER gas_pin,
  ADD COLUMN acs712_sensitivity_mv_per_a DECIMAL(7,2) NOT NULL DEFAULT 185 AFTER acs712_pin,
  ADD COLUMN acs712_zero_mv DECIMAL(7,2) NULL AFTER acs712_sensitivity_mv_per_a;
