ALTER TABLE firmwares
  ADD COLUMN firmware_type ENUM('ota', 'factory') NOT NULL DEFAULT 'ota' AFTER is_active;

ALTER TABLE firmwares
  DROP INDEX model,
  ADD UNIQUE KEY uq_firmware_version_type (model, hardware_version, version, firmware_type);
