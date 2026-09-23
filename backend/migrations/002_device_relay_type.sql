ALTER TABLE devices
  ADD COLUMN device_type ENUM('relay','switch','other') NOT NULL DEFAULT 'relay' AFTER name,
  ADD COLUMN relay_type ENUM('relay_1ch','relay_2ch','relay_4ch','relay_8ch') NULL AFTER device_type;
