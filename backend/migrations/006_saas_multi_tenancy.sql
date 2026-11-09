CREATE TABLE IF NOT EXISTS tenants (
  id CHAR(36) PRIMARY KEY,
  name VARCHAR(100) NOT NULL,
  slug VARCHAR(100) NOT NULL UNIQUE,
  status ENUM('active','suspended') NOT NULL DEFAULT 'active',
  max_devices INT UNSIGNED NOT NULL DEFAULT 50,
  created_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3),
  updated_at DATETIME(3) NOT NULL DEFAULT CURRENT_TIMESTAMP(3) ON UPDATE CURRENT_TIMESTAMP(3)
) ENGINE=InnoDB;

ALTER TABLE users
  MODIFY COLUMN role ENUM('superadmin','tenant_admin','user','admin') NOT NULL DEFAULT 'user',
  ADD COLUMN tenant_id CHAR(36) NULL AFTER role,
  ADD CONSTRAINT fk_users_tenant FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE SET NULL,
  ADD INDEX idx_users_tenant (tenant_id);

ALTER TABLE devices
  ADD COLUMN tenant_id CHAR(36) NULL AFTER owner_user_id,
  ADD CONSTRAINT fk_devices_tenant FOREIGN KEY (tenant_id) REFERENCES tenants(id) ON DELETE SET NULL,
  ADD INDEX idx_devices_tenant (tenant_id);

