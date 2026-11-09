import { randomUUID } from 'node:crypto';
import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';
import { z } from 'zod';
import type { Config } from './config.js';
import type { DB } from './db.js';
import { json } from './db.js';
import { ApiError, must } from './errors.js';
import { sha256, secret, encrypt, decrypt, equal, localToken, redact } from './security.js';

export interface User {
 id: string;
 email: string;
 name: string;
 role: 'user' | 'admin' | 'superadmin' | 'tenant_admin';
 tenant_id?: string | null;
 status: string;
 password_hash?: string;
}

export interface Tenant {
 id: string;
 name: string;
 slug: string;
 status: 'active' | 'suspended';
 max_devices: number;
 created_at?: string;
 updated_at?: string;
}

export interface Publisher {
 connected: boolean;
 publish(topic: string, payload: string): Promise<void>;
}

export const relayTypes = ['relay_1ch', 'relay_2ch', 'relay_4ch', 'relay_8ch'] as const;

export const channelSchema = z.object({
 id: z.number().int().positive(),
 pin: z.number().int().min(0).max(39),
 name: z.string().min(1).max(64),
 alias: z.string().trim().max(100).default(''),
 type: z.enum(['switch', 'pwm', 'sensor']),
 active_low: z.boolean()
}).strict();

export const inventorySchema = z.object({
 sn: z.string().regex(/^[A-Z0-9-]{3,64}$/),
 name: z.string().min(1).max(100),
 model: z.string().min(1).max(64),
 device_type: z.enum(['relay', 'switch', 'sensor', 'other']).default('relay'),
 relay_type: z.enum(relayTypes).nullable().optional(),
 dht11_pin: z.number().int().min(0).max(39).optional(),
 hardware_version: z.string().min(1).max(32),
 firmware_version: z.string().min(1).max(32).default('unknown'),
 capabilities: z.record(z.unknown()).default({}),
 channels: z.array(channelSchema).max(40).refine(v => new Set(v.map(c => c.pin)).size === v.length && new Set(v.map(c => c.id)).size === v.length, 'Duplicate channel pin/id'),
 device_key: z.string().regex(/^[a-f0-9]{64}$/).optional(),
 setup_code: z.string().min(16).max(63).optional()
}).strict().superRefine((v, ctx) => {
 if (v.device_type === 'relay' || v.device_type === 'switch') {
  const relayType = v.relay_type;
  if (!relayType) ctx.addIssue({ code: 'custom', path: ['relay_type'], message: 'relay_type is required' });
  else {
   const n = Number(relayType.split('_')[1]?.replace('ch', '') ?? 0);
   if (v.channels.length !== n) ctx.addIssue({ code: 'custom', path: ['channels'], message: `${relayType} requires ${n} channels` });
  }
 }
 if (v.device_type === 'sensor') {
  if (v.dht11_pin === undefined) ctx.addIssue({ code: 'custom', path: ['dht11_pin'], message: 'dht11_pin is required for sensor devices' });
  if (v.relay_type !== undefined && v.relay_type !== null) ctx.addIssue({ code: 'custom', path: ['relay_type'], message: 'relay_type is not valid for sensor devices' });
  if (v.channels.some(c => c.type !== 'sensor')) ctx.addIssue({ code: 'custom', path: ['channels'], message: 'Sensor devices require sensor channels' });
 }
});

export const firmwareSchema = z.object({
 model: z.string().min(1).max(64),
 hardware_version: z.string().min(1).max(32),
 version: z.string().regex(/^\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?$/).max(32),
 firmware_type: z.enum(['ota', 'factory']).default('ota'),
 url: z.string().url().max(1024).refine(v => {
  const u = new URL(v);
  return u.protocol === 'https:' && !u.username && !u.password && !u.hash;
 }, 'HTTPS URL without credentials required'),
 checksum: z.string().regex(/^[a-fA-F0-9]{64}$/).transform(v => v.toLowerCase()),
 file_size: z.number().int().positive().max(16 * 1024 * 1024),
 release_notes: z.string().max(10000).default('')
}).strict();

export const commandSchema = z.object({
 command: z.enum(['gpio.set', 'wifi.provision', 'system.reboot', 'system.factory_reset', 'firmware.update']),
 channel_id: z.number().int().positive().optional(),
 pin: z.number().int().min(0).max(39).optional(),
 state: z.boolean().optional(),
 ssid: z.string().min(1).max(32).optional(),
 password: z.string().max(63).optional(),
 firmware_id: z.string().uuid().optional(),
 request_id: z.string().uuid().optional()
}).strict();

export type CommandInput = z.infer<typeof commandSchema>;

export const tenantSchema = z.object({
 name: z.string().trim().min(1).max(100),
 slug: z.string().trim().toLowerCase().regex(/^[a-z0-9-]+$/).min(2).max(100),
 max_devices: z.number().int().positive().default(50),
 admin_email: z.string().email().max(254).transform(v => v.toLowerCase()),
 admin_name: z.string().trim().min(1).max(100),
 admin_password: z.string().min(12).max(72)
}).strict();

export const updateTenantSchema = z.object({
 name: z.string().trim().min(1).max(100).optional(),
 status: z.enum(['active', 'suspended']).optional(),
 max_devices: z.number().int().positive().optional()
}).strict().refine(v => Object.keys(v).length > 0, 'At least one field is required');

export const tenantUserSchema = z.object({
 email: z.string().email().max(254).transform(v => v.toLowerCase()),
 name: z.string().trim().min(1).max(100),
 password: z.string().min(12).max(72),
 role: z.enum(['tenant_admin', 'user']).default('user')
}).strict();

const sceneActionSchema = z.object({ channel_id: z.number().int().positive(), state: z.boolean() }).strict();
const sceneSchema = z.object({ name: z.string().trim().min(1).max(100), actions: z.array(sceneActionSchema).min(1).max(8) }).strict();
const scheduleSchema = z.object({
 name: z.string().trim().min(1).max(100),
 scene_id: z.string().uuid(),
 time_local: z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/),
 timezone: z.string().trim().min(3).max(64).default('Asia/Jakarta'),
 weekdays: z.array(z.number().int().min(0).max(6)).min(1).max(7),
 enabled: z.boolean().default(true)
}).strict();
const sceneUpdateSchema = sceneSchema.partial().refine(v => v.name !== undefined || v.actions !== undefined, 'At least one field is required');
const scheduleUpdateSchema = scheduleSchema.partial().refine(v => Object.keys(v).length > 0, 'At least one field is required');

export function publicUser(u: User) {
 return { id: u.id, email: u.email, name: u.name, role: u.role, tenant_id: u.tenant_id ?? null, status: u.status };
}

export function publicDevice(d: any) {
 return {
  sn: d.sn,
  name: d.name,
  model: d.model,
  device_type: d.device_type ?? 'relay',
  relay_type: d.relay_type ?? null,
  dht11_pin: d.dht11_pin ?? null,
  hardware_version: d.hardware_version,
  firmware_version: d.firmware_version,
  tenant_id: d.tenant_id ?? null,
  online: !!d.online && !d.disabled,
  disabled: !!d.disabled,
  last_seen: d.last_seen,
  capabilities: json(d.capabilities),
  channels: json(d.channels),
  state: json(d.state ?? {})
 };
}

function timezoneOffsetMinutes(timezone: string, now = new Date()) {
 const parts = new Intl.DateTimeFormat('en-US', { timeZone: timezone, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23' }).formatToParts(now);
 const get = (type: string) => Number(parts.find(p => p.type === type)?.value ?? 0);
 return Math.round((Date.UTC(get('year'), get('month') - 1, get('day'), get('hour'), get('minute'), get('second')) - now.getTime()) / 60000);
}

export class Service {
 constructor(public db: DB, public config: Config, public mqtt: Publisher) {}

 async audit(event: string, deviceId: string | null, userId: string | null, payload: unknown = {}) {
  await this.db.execute('INSERT INTO device_logs(device_id,user_id,event_type,payload) VALUES (?,?,?,?)', [deviceId, userId, event, JSON.stringify(redact(payload))]);
 }

 async tokens(u: User, db: DB = this.db, familyId = randomUUID()) {
  const refresh = secret();
  await db.execute('INSERT INTO refresh_tokens(token_hash,user_id,family_id,expires_at) VALUES (?,?,?,?)', [sha256(refresh), u.id, familyId, new Date(Date.now() + 30 * 86400000)]);
  return {
   user: publicUser(u),
   access_token: jwt.sign({ role: u.role, tenant_id: u.tenant_id ?? null }, this.config.JWT_SECRET, { subject: u.id, expiresIn: '15m', issuer: 'rizio', audience: 'rizio-api', algorithm: 'HS256' }),
   refresh_token: refresh
  };
 }

 async register(body: unknown) {
  const b = z.object({ email: z.string().email().max(254).transform(v => v.toLowerCase()), password: z.string().min(12).max(72), name: z.string().trim().min(1).max(100) }).strict().parse(body);
  const u: User = { id: randomUUID(), email: b.email, name: b.name, role: 'user', status: 'active' };
  await this.db.execute('INSERT INTO users(id,email,password_hash,name) VALUES (?,?,?,?)', [u.id, u.email, await bcrypt.hash(b.password, 12), u.name]);
  return this.tokens(u);
 }

 async login(body: unknown) {
  const b = z.object({ email: z.string().email().transform(v => v.toLowerCase()), password: z.string().min(1).max(72) }).strict().parse(body);
  const [u] = await this.db.query<User>('SELECT * FROM users WHERE email=?', [b.email]);
  const valid = await bcrypt.compare(b.password, u?.password_hash ?? '$2b$12$C6UzMDM.H6dfI/f/IKcEe.9V4xnBwRXf7oVHZ5.vF9FCOnSZR.ljW');
  must(u && valid && u.status === 'active', 401, 'AUTH_INVALID');
  if (u.tenant_id) {
   const [t] = await this.db.query<{ status: string }>('SELECT status FROM tenants WHERE id=?', [u.tenant_id]);
   must(t && t.status === 'active', 403, 'TENANT_SUSPENDED');
  }
  return this.tokens(u);
 }

 async refresh(token: string) {
  const result = await this.db.transaction(async tx => {
   const [r] = await tx.query('SELECT * FROM refresh_tokens WHERE token_hash=? FOR UPDATE', [sha256(token)]);
   if (!r) return null;
   if (r.revoked_at || new Date(r.expires_at).getTime() <= Date.now()) {
    await tx.execute('UPDATE refresh_tokens SET revoked_at=COALESCE(revoked_at,NOW(3)) WHERE family_id=?', [r.family_id]);
    return null;
   }
   const [u] = await tx.query<User>("SELECT * FROM users WHERE id=? AND status='active'", [r.user_id]);
   if (!u) return null;
   if (u.tenant_id) {
    const [t] = await tx.query<{ status: string }>('SELECT status FROM tenants WHERE id=?', [u.tenant_id]);
    if (!t || t.status !== 'active') return null;
   }
   await tx.execute('UPDATE refresh_tokens SET revoked_at=NOW(3) WHERE token_hash=?', [sha256(token)]);
   return this.tokens(u, tx, r.family_id);
  });
  must(result, 401, 'AUTH_INVALID');
  return result;
 }

 async logout(token: string) {
  await this.db.execute('UPDATE refresh_tokens SET revoked_at=COALESCE(revoked_at,NOW(3)) WHERE family_id IN (SELECT family_id FROM (SELECT family_id FROM refresh_tokens WHERE token_hash=?) AS family)', [sha256(token)]);
  return { logged_out: true };
 }

 async authenticate(token: string) {
  let sub: string;
  try {
   const p = jwt.verify(token, this.config.JWT_SECRET, { algorithms: ['HS256'], issuer: 'rizio', audience: 'rizio-api' });
   must(typeof p !== 'string' && typeof p.sub === 'string', 401, 'AUTH_INVALID');
   sub = p.sub;
  } catch {
   throw new ApiError(401, 'AUTH_INVALID');
  }
  const [u] = await this.db.query<User>("SELECT id,email,name,role,tenant_id,status FROM users WHERE id=? AND status='active'", [sub]);
  must(u, 401, 'AUTH_INVALID');
  if (u.tenant_id) {
   const [t] = await this.db.query<{ status: string }>('SELECT status FROM tenants WHERE id=?', [u.tenant_id]);
   must(t && t.status === 'active', 403, 'TENANT_SUSPENDED');
  }
  return u;
 }

 async getDevice(sn: string, db: DB = this.db) {
  const [d] = await db.query('SELECT d.*,s.state FROM devices d LEFT JOIN device_states s ON s.device_id=d.id WHERE d.sn=?', [sn]);
  must(d, 404, 'DEVICE_NOT_FOUND');
  return d;
 }

 async owned(sn: string, u: User, db: DB = this.db) {
  const d = await this.getDevice(sn, db);
  const isOwner = d.owner_user_id === u.id;
  const isTenantMember = !!(u.tenant_id && d.tenant_id && d.tenant_id === u.tenant_id);
  const isSuperAdmin = u.role === 'admin' || u.role === 'superadmin';
  must(isOwner || isTenantMember || isSuperAdmin, 403, 'DEVICE_NOT_OWNED');
  must(!d.disabled, 403, 'DEVICE_DISABLED');
  if (d.tenant_id) {
   const [t] = await db.query<{ status: string }>('SELECT status FROM tenants WHERE id=?', [d.tenant_id]);
   must(t && t.status === 'active', 403, 'TENANT_SUSPENDED');
  }
  return d;
 }

 async list(u: User) {
  if (u.tenant_id) {
   return (await this.db.query('SELECT d.*,s.state FROM devices d LEFT JOIN device_states s ON s.device_id=d.id WHERE d.tenant_id=? ORDER BY d.created_at DESC', [u.tenant_id])).map(publicDevice);
  }
  return (await this.db.query('SELECT d.*,s.state FROM devices d LEFT JOIN device_states s ON s.device_id=d.id WHERE d.owner_user_id=? ORDER BY d.created_at DESC', [u.id])).map(publicDevice);
 }

 async claim(sn: string, u: User) {
  return this.db.transaction(async tx => {
   const [d] = await tx.query('SELECT * FROM devices WHERE sn=? FOR UPDATE', [sn]);
   must(d, 404, 'DEVICE_NOT_FOUND');
   must(!d.disabled, 403, 'DEVICE_DISABLED');
   must(!d.owner_user_id && !d.tenant_id, 409, 'DEVICE_ALREADY_CLAIMED');
   if (u.tenant_id) {
    const [t] = await tx.query<{ status: string; max_devices: number }>('SELECT status, max_devices FROM tenants WHERE id=?', [u.tenant_id]);
    must(t && t.status === 'active', 403, 'TENANT_SUSPENDED');
    const [deviceCount] = await tx.query<{ count: number }>('SELECT COUNT(*) AS count FROM devices WHERE tenant_id=?', [u.tenant_id]);
    must(Number(deviceCount?.count ?? 0) < Number(t.max_devices), 400, 'TENANT_DEVICE_LIMIT_REACHED');
   }
   const tenantId = u.tenant_id ?? null;
   const r = await tx.execute('UPDATE devices SET owner_user_id=?, tenant_id=? WHERE id=? AND owner_user_id IS NULL AND tenant_id IS NULL', [u.id, tenantId, d.id]);
   must(r.affectedRows === 1, 409, 'DEVICE_ALREADY_CLAIMED');
   await tx.execute("INSERT INTO device_logs(device_id,user_id,event_type,payload) VALUES (?,?,'claim','{}')", [d.id, u.id]);
   return publicDevice({ ...d, owner_user_id: u.id, tenant_id: tenantId });
  });
 }

 async unclaim(sn: string, password: string, u: User) {
  const [account] = await this.db.query<User>('SELECT * FROM users WHERE id=?', [u.id]);
  must(account?.password_hash && await bcrypt.compare(password, account.password_hash), 401, 'AUTH_INVALID');
  return this.db.transaction(async tx => {
   const [d] = await tx.query('SELECT * FROM devices WHERE sn=? FOR UPDATE', [sn]);
   must(d, 404, 'DEVICE_NOT_FOUND');
   const isOwner = d.owner_user_id === u.id;
   const isTenantAdmin = u.role === 'tenant_admin' && !!u.tenant_id && d.tenant_id === u.tenant_id;
   const isSuperAdmin = u.role === 'admin' || u.role === 'superadmin';
   must(isOwner || isTenantAdmin || isSuperAdmin, 403, 'DEVICE_NOT_OWNED');
   await tx.execute('UPDATE devices SET owner_user_id=NULL, tenant_id=NULL WHERE id=?', [d.id]);
   await tx.execute("UPDATE device_commands SET status='failed',error='DEVICE_UNCLAIMED' WHERE device_id=? AND status IN ('pending','sent')", [d.id]);
   await tx.execute("INSERT INTO device_logs(device_id,user_id,event_type,payload) VALUES (?,?,'unclaim','{}')", [d.id, u.id]);
   return { sn, unclaimed: true };
  });
 }

 async createDevice(body: unknown, u: User) {
  const b = inventorySchema.parse(body);
  must(b.sn !== this.config.MQTT_USERNAME, 400, 'RESERVED_DEVICE_SN');
  const key = b.device_key ?? secret(), setup = b.setup_code ?? secret().slice(0, 48);
  must(key !== setup, 400, 'CREDENTIALS_MUST_DIFFER');
  const id = randomUUID();
  await this.db.execute('INSERT INTO devices(id,sn,device_key_encrypted,claim_code_hash,name,device_type,relay_type,dht11_pin,model,hardware_version,firmware_version,capabilities,channels) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)', [id, b.sn, encrypt(key, this.config.CREDENTIAL_ENCRYPTION_KEY), null, b.name, b.device_type, b.relay_type ?? null, b.dht11_pin ?? null, b.model, b.hardware_version, b.firmware_version, JSON.stringify(b.capabilities), JSON.stringify(b.channels)]);
  await this.audit('inventory.created', id, u.id, { sn: b.sn, device_type: b.device_type, relay_type: b.relay_type, dht11_pin: b.dht11_pin });
  return { device: publicDevice({ ...b, id, online: false, disabled: false }), production_credentials: { sn: b.sn, device_key: key, setup_code: setup } };
 }

 // SaaS Multi-Tenancy Methods
 async createTenant(body: unknown, u: User) {
  must(u.role === 'admin' || u.role === 'superadmin', 403, 'SUPERADMIN_REQUIRED');
  const b = tenantSchema.parse(body);
  const tenantId = randomUUID();
  const adminId = randomUUID();
  return this.db.transaction(async tx => {
   const [existSlug] = await tx.query('SELECT id FROM tenants WHERE slug=?', [b.slug]);
   must(!existSlug, 409, 'SLUG_ALREADY_EXISTS');
   const [existEmail] = await tx.query('SELECT id FROM users WHERE email=?', [b.admin_email]);
   must(!existEmail, 409, 'EMAIL_ALREADY_EXISTS');
   await tx.execute('INSERT INTO tenants(id,name,slug,max_devices) VALUES (?,?,?,?)', [tenantId, b.name, b.slug, b.max_devices]);
   await tx.execute('INSERT INTO users(id,email,password_hash,name,role,tenant_id) VALUES (?,?,?,?,?,?)', [adminId, b.admin_email, await bcrypt.hash(b.admin_password, 12), b.admin_name, 'tenant_admin', tenantId]);
   await this.audit('tenant.created', null, u.id, { tenant_id: tenantId, name: b.name, slug: b.slug });
   return {
    id: tenantId,
    name: b.name,
    slug: b.slug,
    status: 'active',
    max_devices: b.max_devices,
    admin: { id: adminId, email: b.admin_email, name: b.admin_name, role: 'tenant_admin' }
   };
  });
 }

 async listTenants(u: User) {
  must(u.role === 'admin' || u.role === 'superadmin', 403, 'SUPERADMIN_REQUIRED');
  return this.db.query(`
   SELECT t.id, t.name, t.slug, t.status, t.max_devices, t.created_at, t.updated_at,
    COUNT(DISTINCT d.id) AS total_devices,
    COALESCE(SUM(d.online = TRUE AND d.disabled = FALSE), 0) AS online_devices,
    COUNT(DISTINCT u.id) AS total_users
   FROM tenants t
   LEFT JOIN devices d ON d.tenant_id = t.id
   LEFT JOIN users u ON u.tenant_id = t.id
   GROUP BY t.id, t.name, t.slug, t.status, t.max_devices, t.created_at, t.updated_at
   ORDER BY t.created_at DESC
  `);
 }

 async getTenant(id: string, u: User) {
  must(u.role === 'admin' || u.role === 'superadmin' || u.tenant_id === id, 403, 'FORBIDDEN');
  const [t] = await this.db.query('SELECT * FROM tenants WHERE id=?', [id]);
  must(t, 404, 'TENANT_NOT_FOUND');
  const [devices] = await this.db.query('SELECT COUNT(*) AS total_devices FROM devices WHERE tenant_id=?', [id]);
  const [users] = await this.db.query('SELECT COUNT(*) AS total_users FROM users WHERE tenant_id=?', [id]);
  return { ...t, total_devices: Number(devices?.total_devices ?? 0), total_users: Number(users?.total_users ?? 0) };
 }

 async updateTenant(id: string, body: unknown, u: User) {
  must(u.role === 'admin' || u.role === 'superadmin', 403, 'SUPERADMIN_REQUIRED');
  const b = updateTenantSchema.parse(body);
  const [t] = await this.db.query('SELECT * FROM tenants WHERE id=?', [id]);
  must(t, 404, 'TENANT_NOT_FOUND');
  await this.db.transaction(async tx => {
   if (b.name !== undefined) await tx.execute('UPDATE tenants SET name=? WHERE id=?', [b.name, id]);
   if (b.status !== undefined) await tx.execute('UPDATE tenants SET status=? WHERE id=?', [b.status, id]);
   if (b.max_devices !== undefined) await tx.execute('UPDATE tenants SET max_devices=? WHERE id=?', [b.max_devices, id]);
  });
  await this.audit('tenant.updated', null, u.id, { tenant_id: id, ...b });
  return { id, ...t, ...b };
 }

 async createTenantUser(body: unknown, u: User) {
  must(u.role === 'tenant_admin' && !!u.tenant_id, 403, 'TENANT_ADMIN_REQUIRED');
  const b = tenantUserSchema.parse(body);
  const [existEmail] = await this.db.query('SELECT id FROM users WHERE email=?', [b.email]);
  must(!existEmail, 409, 'EMAIL_ALREADY_EXISTS');
  const id = randomUUID();
  await this.db.execute('INSERT INTO users(id,email,password_hash,name,role,tenant_id) VALUES (?,?,?,?,?,?)', [id, b.email, await bcrypt.hash(b.password, 12), b.name, b.role, u.tenant_id]);
  await this.audit('tenant_user.created', null, u.id, { user_id: id, email: b.email, role: b.role, tenant_id: u.tenant_id });
  return { id, email: b.email, name: b.name, role: b.role, tenant_id: u.tenant_id, status: 'active' };
 }

 async listTenantUsers(u: User) {
  must((u.role === 'tenant_admin' || u.role === 'admin' || u.role === 'superadmin') && !!u.tenant_id, 403, 'TENANT_ADMIN_REQUIRED');
  return this.db.query('SELECT id,email,name,role,tenant_id,status,created_at FROM users WHERE tenant_id=? ORDER BY created_at DESC', [u.tenant_id]);
 }

 async updateTenantUser(id: string, body: unknown, u: User) {
  must(u.role === 'tenant_admin' && !!u.tenant_id, 403, 'TENANT_ADMIN_REQUIRED');
  const b = z.object({ status: z.enum(['active', 'disabled']).optional(), role: z.enum(['tenant_admin', 'user']).optional() }).strict().refine(v => Object.keys(v).length > 0, 'At least one field is required').parse(body);
  const [target] = await this.db.query<User>('SELECT * FROM users WHERE id=? AND tenant_id=?', [id, u.tenant_id]);
  must(target, 404, 'USER_NOT_FOUND');
  await this.db.transaction(async tx => {
   if (b.status) await tx.execute('UPDATE users SET status=? WHERE id=?', [b.status, id]);
   if (b.role) await tx.execute('UPDATE users SET role=? WHERE id=?', [b.role, id]);
   if (b.status === 'disabled') await tx.execute('UPDATE refresh_tokens SET revoked_at=COALESCE(revoked_at,NOW(3)) WHERE user_id=?', [id]);
  });
  await this.audit('tenant_user.updated', null, u.id, { target_user_id: id, ...b });
  return { ...target, ...b, id };
 }

 async deleteTenantUser(id: string, u: User) {
  must(u.role === 'tenant_admin' && !!u.tenant_id, 403, 'TENANT_ADMIN_REQUIRED');
  const [target] = await this.db.query<User>('SELECT * FROM users WHERE id=? AND tenant_id=?', [id, u.tenant_id]);
  must(target, 404, 'USER_NOT_FOUND');
  await this.db.transaction(async tx => {
   await tx.execute('UPDATE devices SET owner_user_id=NULL WHERE owner_user_id=? AND tenant_id=?', [id, u.tenant_id]);
   await tx.execute('DELETE r FROM schedule_runs r JOIN schedules x ON x.id=r.schedule_id WHERE x.user_id=?', [id]);
   await tx.execute('DELETE FROM schedules WHERE user_id=?', [id]);
   await tx.execute('DELETE FROM scenes WHERE user_id=?', [id]);
   await tx.execute('DELETE FROM device_commands WHERE user_id=?', [id]);
   await tx.execute('DELETE FROM device_logs WHERE user_id=?', [id]);
   await tx.execute('DELETE FROM refresh_tokens WHERE user_id=?', [id]);
   const result = await tx.execute('DELETE FROM users WHERE id=?', [id]);
   must(result.affectedRows === 1, 404, 'USER_NOT_FOUND');
  });
  await this.audit('tenant_user.deleted', null, u.id, { target_user_id: id });
  return { id, deleted: true };
 }

 async createScene(sn: string, body: unknown, u: User) {
  const d = await this.owned(sn, u);
  const b = sceneSchema.parse(body);
  const channels = json<any[]>(d.channels);
  for (const a of b.actions) {
   const c = channels.find(v => v.id === a.channel_id && v.type === 'switch');
   must(c, 400, 'INVALID_SCENE_CHANNEL');
  }
  const id = randomUUID();
  await this.db.execute('INSERT INTO scenes(id,user_id,device_id,name,actions) VALUES (?,?,?,?,?)', [id, u.id, d.id, b.name, JSON.stringify(b.actions)]);
  await this.audit('scene.created', d.id, u.id, { scene_id: id });
  await this.syncSchedulesForDevice(d.sn);
  return { id, device_sn: d.sn, name: b.name, actions: b.actions, enabled: true };
 }

 async listScenes(u: User) {
  if (u.tenant_id) {
   return (await this.db.query('SELECT s.*,d.sn AS device_sn FROM scenes s JOIN devices d ON d.id=s.device_id WHERE d.tenant_id=? ORDER BY s.created_at DESC', [u.tenant_id])).map(s => ({ ...s, actions: json(s.actions) }));
  }
  return (await this.db.query('SELECT s.*,d.sn AS device_sn FROM scenes s JOIN devices d ON d.id=s.device_id WHERE s.user_id=? ORDER BY s.created_at DESC', [u.id])).map(s => ({ ...s, actions: json(s.actions) }));
 }

 async updateScene(id: string, body: unknown, u: User) {
  const b = sceneUpdateSchema.parse(body);
  const [s] = await this.db.query('SELECT s.*,d.sn,d.tenant_id FROM scenes s JOIN devices d ON d.id=s.device_id WHERE s.id=?', [id]);
  must(s, 404, 'SCENE_NOT_FOUND');
  const isOwner = s.user_id === u.id;
  const isTenantMember = !!(u.tenant_id && s.tenant_id && s.tenant_id === u.tenant_id);
  const isSuper = u.role === 'admin' || u.role === 'superadmin';
  must(isOwner || isTenantMember || isSuper, 403, 'FORBIDDEN');
  const actions = b.actions ?? json<any[]>(s.actions);
  const channels = json<any[]>(s.channels ?? (await this.db.query('SELECT channels FROM devices WHERE id=?', [s.device_id]))[0]?.channels);
  for (const a of actions) {
   const c = channels.find(v => v.id === a.channel_id && v.type === 'switch');
   must(c, 400, 'INVALID_SCENE_CHANNEL');
  }
  await this.db.execute('UPDATE scenes SET name=?,actions=? WHERE id=?', [b.name ?? s.name, JSON.stringify(actions), id]);
  await this.syncSchedulesForDevice(s.sn);
  return { id, device_sn: s.sn, name: b.name ?? s.name, actions, enabled: !!s.enabled };
 }

 async deleteScene(id: string, u: User) {
  const [s] = await this.db.query('SELECT s.*,d.sn,d.tenant_id FROM scenes s JOIN devices d ON d.id=s.device_id WHERE s.id=?', [id]);
  must(s, 404, 'SCENE_NOT_FOUND');
  const isOwner = s.user_id === u.id;
  const isTenantMember = !!(u.tenant_id && s.tenant_id && s.tenant_id === u.tenant_id);
  const isSuper = u.role === 'admin' || u.role === 'superadmin';
  must(isOwner || isTenantMember || isSuper, 403, 'FORBIDDEN');
  await this.db.transaction(async tx => {
   await tx.execute('DELETE r FROM schedule_runs r JOIN schedules x ON x.id=r.schedule_id WHERE x.scene_id=?', [id]);
   await tx.execute('DELETE FROM schedules WHERE scene_id=?', [id]);
   await tx.execute('DELETE FROM scenes WHERE id=?', [id]);
  });
  await this.syncSchedulesForDevice(s.sn);
  return { id, deleted: true };
 }

 async createSchedule(sn: string, body: unknown, u: User) {
  const d = await this.owned(sn, u);
  const b = scheduleSchema.parse(body);
  const [scene] = await this.db.query('SELECT * FROM scenes WHERE id=? AND device_id=?', [b.scene_id, d.id]);
  must(scene, 400, 'INVALID_SCENE');
  try { new Intl.DateTimeFormat('en-US', { timeZone: b.timezone }).format(); } catch { throw new ApiError(400, 'INVALID_TIMEZONE'); }
  const id = randomUUID();
  await this.db.execute('INSERT INTO schedules(id,user_id,device_id,scene_id,name,time_local,timezone,weekdays,enabled) VALUES (?,?,?,?,?,?,?,?,?)', [id, u.id, d.id, b.scene_id, b.name, b.time_local, b.timezone, JSON.stringify([...new Set(b.weekdays)].sort()), b.enabled]);
  await this.audit('schedule.created', d.id, u.id, { schedule_id: id });
  await this.syncSchedulesForDevice(d.sn);
  return { id, device_sn: d.sn, ...b, version: 1 };
 }

 async listSchedules(u: User) {
  if (u.tenant_id) {
   return (await this.db.query('SELECT s.*,d.sn AS device_sn,sc.name AS scene_name FROM schedules s JOIN devices d ON d.id=s.device_id JOIN scenes sc ON sc.id=s.scene_id WHERE d.tenant_id=? ORDER BY s.time_local,s.created_at', [u.tenant_id])).map(s => ({ ...s, weekdays: json(s.weekdays) }));
  }
  return (await this.db.query('SELECT s.*,d.sn AS device_sn,sc.name AS scene_name FROM schedules s JOIN devices d ON d.id=s.device_id JOIN scenes sc ON sc.id=s.scene_id WHERE s.user_id=? ORDER BY s.time_local,s.created_at', [u.id])).map(s => ({ ...s, weekdays: json(s.weekdays) }));
 }

 async updateSchedule(id: string, body: unknown, u: User) {
  const b = scheduleUpdateSchema.parse(body);
  const [s] = await this.db.query('SELECT s.*,d.sn,d.tenant_id FROM schedules s JOIN devices d ON d.id=s.device_id WHERE s.id=?', [id]);
  must(s, 404, 'SCHEDULE_NOT_FOUND');
  const isOwner = s.user_id === u.id;
  const isTenantMember = !!(u.tenant_id && s.tenant_id && s.tenant_id === u.tenant_id);
  const isSuper = u.role === 'admin' || u.role === 'superadmin';
  must(isOwner || isTenantMember || isSuper, 403, 'FORBIDDEN');
  const values = { name: b.name ?? s.name, scene_id: b.scene_id ?? s.scene_id, time_local: b.time_local ?? s.time_local, timezone: b.timezone ?? s.timezone, weekdays: b.weekdays ?? json<number[]>(s.weekdays), enabled: b.enabled ?? !!s.enabled };
  const [scene] = await this.db.query('SELECT id FROM scenes WHERE id=? AND device_id=?', [values.scene_id, s.device_id]);
  must(scene, 400, 'INVALID_SCENE');
  try { new Intl.DateTimeFormat('en-US', { timeZone: values.timezone }).format(); } catch { throw new ApiError(400, 'INVALID_TIMEZONE'); }
  await this.db.execute('UPDATE schedules SET name=?,scene_id=?,time_local=?,timezone=?,weekdays=?,enabled=?,version=version+1 WHERE id=?', [values.name, values.scene_id, values.time_local, values.timezone, JSON.stringify([...new Set(values.weekdays)].sort()), values.enabled, id]);
  await this.syncSchedulesForDevice(s.sn);
  return { id, device_sn: s.sn, ...values };
 }

 async deleteSchedule(id: string, u: User) {
  const [s] = await this.db.query('SELECT s.*,d.sn,d.tenant_id FROM schedules s JOIN devices d ON d.id=s.device_id WHERE s.id=?', [id]);
  must(s, 404, 'SCHEDULE_NOT_FOUND');
  const isOwner = s.user_id === u.id;
  const isTenantMember = !!(u.tenant_id && s.tenant_id && s.tenant_id === u.tenant_id);
  const isSuper = u.role === 'admin' || u.role === 'superadmin';
  must(isOwner || isTenantMember || isSuper, 403, 'FORBIDDEN');
  await this.db.transaction(async tx => {
   await tx.execute('DELETE FROM schedule_runs WHERE schedule_id=?', [id]);
   await tx.execute('DELETE FROM schedules WHERE id=?', [id]);
  });
  await this.syncSchedulesForDevice(s.sn);
  return { id, deleted: true };
 }

 async syncSchedulesForDevice(sn: string) {
  const [d] = await this.db.query('SELECT * FROM devices WHERE sn=? AND disabled=FALSE', [sn]);
  if (!d || !this.mqtt.connected) return;
  const rows = await this.db.query('SELECT s.id,s.name,s.time_local,s.timezone,s.weekdays,s.enabled,s.version,sc.actions,d.channels FROM schedules s JOIN scenes sc ON sc.id=s.scene_id JOIN devices d ON d.id=s.device_id WHERE d.id=? AND s.enabled=TRUE AND sc.enabled=TRUE', [d.id]);
  const schedules = rows.map(s => {
   const channels = json<any[]>(s.channels);
   const actions = json<any[]>(s.actions).map(a => {
    const c = channels.find(v => v.id === a.channel_id);
    return c ? { channel_id: a.channel_id, pin: c.pin, state: a.state } : null;
   }).filter(Boolean);
   return { id: s.id, name: s.name, time_local: s.time_local, weekdays: json(s.weekdays), enabled: !!s.enabled, version: s.version, tz_offset_minutes: timezoneOffsetMinutes(s.timezone), actions };
  });
  const payload = { cmd: 'schedule.sync', request_id: randomUUID(), timestamp: Math.floor(Date.now() / 1000), schedules };
  if (Buffer.byteLength(JSON.stringify(payload)) > 2048) {
   await this.audit('schedule.sync_failed', d.id, null, { reason: 'payload_too_large' });
   return;
  }
  try { await this.mqtt.publish(`devices/${sn}/command`, JSON.stringify(payload)); } catch {}
 }

 private localScheduleParts(timezone: string, now = new Date()) {
  const parts = new Intl.DateTimeFormat('en-US', { timeZone: timezone, year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', weekday: 'short', hourCycle: 'h23' }).formatToParts(now);
  const get = (type: string) => parts.find(p => p.type === type)?.value ?? '';
  const weekdays: { [key: string]: number } = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };
  return { date: `${get('year')}-${get('month')}-${get('day')}`, time: `${get('hour').padStart(2, '0')}:${get('minute').padStart(2, '0')}`, weekday: weekdays[get('weekday')] ?? 0 };
 }

 async runSchedules() {
  const rows = await this.db.query('SELECT s.*,sc.actions,d.sn,d.online,d.channels FROM schedules s JOIN scenes sc ON sc.id=s.scene_id JOIN devices d ON d.id=s.device_id WHERE s.enabled=TRUE AND sc.enabled=TRUE AND d.disabled=FALSE');
  for (const s of rows) {
   let now;
   try { now = this.localScheduleParts(s.timezone); } catch { continue; }
   if (now.time !== s.time_local || !json<number[]>(s.weekdays).includes(now.weekday)) continue;
   const runKey = `${now.date}T${s.time_local}`;
   const inserted = await this.db.execute("INSERT IGNORE INTO schedule_runs(schedule_id,run_key,mode,status) VALUES (?,?,'backend',?)", [s.id, runKey, s.online ? 'dispatched' : 'device_fallback']);
   if (!inserted.affectedRows) continue;
   if (!s.online || !this.mqtt.connected) continue;
   const channels = json<any[]>(s.channels);
   const actions = json<any[]>(s.actions).map(a => {
    const c = channels.find(v => v.id === a.channel_id);
    return c ? { channel_id: a.channel_id, pin: c.pin, state: a.state } : null;
   }).filter(Boolean);
   const payload = { cmd: 'scene.apply', request_id: randomUUID(), run_id: `${s.id}:${runKey}`, timestamp: Math.floor(Date.now() / 1000), actions };
   try {
    await this.mqtt.publish(`devices/${s.sn}/command`, JSON.stringify(payload));
   } catch {
    await this.db.execute("UPDATE schedule_runs SET status='device_fallback' WHERE schedule_id=? AND run_key=?", [s.id, runKey]);
   }
  }
 }

 async deleteDevice(sn: string, u: User) {
  let deviceId = '';
  await this.db.transaction(async tx => {
   const [d] = await tx.query<{ id: string }>('SELECT id FROM devices WHERE sn=? FOR UPDATE', [sn]);
   must(d, 404, 'DEVICE_NOT_FOUND');
   deviceId = d.id;
   await tx.execute('DELETE r FROM schedule_runs r JOIN schedules x ON x.id=r.schedule_id WHERE x.device_id=?', [d.id]);
   await tx.execute('DELETE FROM schedules WHERE device_id=?', [d.id]);
   await tx.execute('DELETE FROM scenes WHERE device_id=?', [d.id]);
   await tx.execute('DELETE FROM sensor_readings WHERE device_id=?', [d.id]);
   await tx.execute('DELETE FROM device_states WHERE device_id=?', [d.id]);
   await tx.execute('DELETE FROM device_commands WHERE device_id=?', [d.id]);
   await tx.execute('DELETE FROM device_logs WHERE device_id=?', [d.id]);
   await tx.execute('DELETE FROM devices WHERE id=?', [d.id]);
  });
  await this.audit('device.deleted', null, u.id, { sn, device_id: deviceId });
  return { sn, deleted: true };
 }

 async deleteUser(id: string, u: User) {
  must(id !== u.id, 400, 'CANNOT_DELETE_SELF');
  await this.db.transaction(async tx => {
   const devices = await tx.query<{ id: string }>('SELECT id FROM devices WHERE owner_user_id=? FOR UPDATE', [id]);
   for (const d of devices) {
    await tx.execute('DELETE r FROM schedule_runs r JOIN schedules x ON x.id=r.schedule_id WHERE x.device_id=?', [d.id]);
    await tx.execute('DELETE FROM schedules WHERE device_id=?', [d.id]);
    await tx.execute('DELETE FROM scenes WHERE device_id=?', [d.id]);
    await tx.execute('DELETE FROM sensor_readings WHERE device_id=?', [d.id]);
    await tx.execute('DELETE FROM device_states WHERE device_id=?', [d.id]);
    await tx.execute('DELETE FROM device_commands WHERE device_id=?', [d.id]);
    await tx.execute('DELETE FROM device_logs WHERE device_id=?', [d.id]);
    await tx.execute('DELETE FROM devices WHERE id=?', [d.id]);
   }
   await tx.execute('DELETE r FROM schedule_runs r JOIN schedules x ON x.id=r.schedule_id WHERE x.user_id=?', [id]);
   await tx.execute('DELETE FROM schedules WHERE user_id=?', [id]);
   await tx.execute('DELETE FROM scenes WHERE user_id=?', [id]);
   await tx.execute('DELETE FROM device_commands WHERE user_id=?', [id]);
   await tx.execute('DELETE FROM device_logs WHERE user_id=?', [id]);
   await tx.execute('DELETE FROM refresh_tokens WHERE user_id=?', [id]);
   const result = await tx.execute('DELETE FROM users WHERE id=?', [id]);
   must(result.affectedRows === 1, 404, 'USER_NOT_FOUND');
  });
  await this.audit('user.deleted', null, u.id, { target_user_id: id });
  return { id, deleted: true };
 }

 async deviceAuth(sn: string, key: string) {
  const [d] = await this.db.query('SELECT * FROM devices WHERE sn=? AND disabled=FALSE', [sn]);
  return d && equal(decrypt(d.device_key_encrypted, this.config.CREDENTIAL_ENCRYPTION_KEY), key) ? d : null;
 }

 async local(sn: string, u: User) {
  const d = await this.owned(sn, u);
  return localToken(sn, decrypt(d.device_key_encrypted, this.config.CREDENTIAL_ENCRYPTION_KEY));
 }

 async getDeviceIdentity(sn: string, u: User) {
  const d = await this.owned(sn, u);
  const key = decrypt(d.device_key_encrypted, this.config.CREDENTIAL_ENCRYPTION_KEY);
  let mqttHost = this.config.MQTT_TLS_SERVERNAME;
  try {
   if (!mqttHost) mqttHost = new URL(this.config.MQTT_URL).hostname;
  } catch {
   mqttHost = 'mqtt.rizbill.my.id';
  }
  return {
   sn: d.sn,
   device_key: key,
   setup_code: 'rizio123456',
   model: d.model,
   hardware_version: d.hardware_version,
   mqtt_host: mqttHost,
   mqtt_port: 8883,
   reset_pin: 0,
   ...(d.dht11_pin !== null && d.dht11_pin !== undefined ? { dht11_pin: d.dht11_pin } : {}),
   channels: json(d.channels)
  };
 }

 async createFirmware(body: unknown, u: User) {
  const b = firmwareSchema.parse(body);
  const id = randomUUID();
  await this.db.execute('INSERT INTO firmwares(id,model,hardware_version,version,firmware_type,url,checksum,file_size,release_notes) VALUES (?,?,?,?,?,?,?,?,?)', [id, b.model, b.hardware_version, b.version, b.firmware_type, b.url, b.checksum, b.file_size, b.release_notes]);
  await this.audit('firmware.created', null, u.id, { firmware_id: id, version: b.version, firmware_type: b.firmware_type });
  return { id, ...b, is_active: true };
 }

 async command(sn: string, input: unknown, u: User, admin = false) {
  const b = commandSchema.parse(input);
  const requestId = b.request_id ?? randomUUID();
  const result = await this.db.transaction(async tx => {
   const [d] = await tx.query('SELECT * FROM devices WHERE sn=? FOR UPDATE', [sn]);
   must(d, 404, 'DEVICE_NOT_FOUND');
   const isOwner = d.owner_user_id === u.id;
   const isTenantMember = !!(u.tenant_id && d.tenant_id && d.tenant_id === u.tenant_id);
   const isSuper = u.role === 'admin' || u.role === 'superadmin';
   must((admin && isSuper) || isOwner || isTenantMember || (!admin && isSuper), 403, 'DEVICE_NOT_OWNED');
   must(!d.disabled, 403, 'DEVICE_DISABLED');
   if (d.tenant_id) {
    const [t] = await tx.query<{ status: string }>('SELECT status FROM tenants WHERE id=?', [d.tenant_id]);
    must(t && t.status === 'active', 403, 'TENANT_SUSPENDED');
   }
   const [old] = await tx.query('SELECT * FROM device_commands WHERE request_id=?', [requestId]);
   if (old) {
    must(old.device_id === d.id && old.user_id === u.id, 409, 'REQUEST_ID_CONFLICT');
    const p = json(old.payload);
    must(old.command === b.command && p.pin === b.pin && (b.channel_id === undefined || p.channel_id === b.channel_id) && p.state === b.state && p.firmware_id === b.firmware_id, 409, 'REQUEST_ID_CONFLICT');
    return { old: true, request_id: requestId, device: sn, command_status: old.status };
   }
   must(!!d.online, 409, 'DEVICE_OFFLINE');
   must(this.mqtt.connected, 503, 'MQTT_ERROR');
   const payload: Record<string, any> = { request_id: requestId, cmd: b.command, timestamp: Math.floor(Date.now() / 1000) };
   if (b.command === 'gpio.set') {
    must(b.state !== undefined && !b.firmware_id && (b.channel_id !== undefined || b.pin !== undefined), 400, 'INVALID_COMMAND');
    const channel = json<any[]>(d.channels).find(c => (b.channel_id !== undefined ? c.id === b.channel_id : c.pin === b.pin) && c.type === 'switch');
    must(channel, 400, 'INVALID_GPIO');
    if (b.pin !== undefined) must(channel.pin === b.pin, 400, 'INVALID_GPIO');
    payload.channel_id = channel.id;
    payload.pin = channel.pin;
    payload.state = b.state;
   } else if (b.command === 'wifi.provision') {
    must(b.ssid !== undefined && b.password !== undefined && !b.firmware_id, 400, 'INVALID_COMMAND');
    must(b.password.length === 0 || b.password.length >= 8, 400, 'INVALID_WIFI_PASSWORD');
    payload.ssid = b.ssid;
    payload.password = b.password;
   } else {
    must(b.pin === undefined && b.state === undefined, 400, 'INVALID_COMMAND');
   }
   if (b.command === 'system.factory_reset') must(json(d.capabilities).factory_reset === true, 403, 'COMMAND_NOT_ALLOWED');
   if (b.command === 'firmware.update') {
    must(b.firmware_id, 400, 'INVALID_COMMAND');
    const [f] = await tx.query<{ id: string; model: string; hardware_version: string; version: string; firmware_type: 'ota' | 'factory'; url: string; checksum: string; file_size: number; release_notes: string }>('SELECT * FROM firmwares WHERE id=? AND is_active=TRUE', [b.firmware_id]);
    must(f && f.model === d.model && f.hardware_version === d.hardware_version, 400, 'FIRMWARE_INCOMPATIBLE');
    must(f.firmware_type === 'ota', 400, 'FIRMWARE_NOT_FOR_OTA');
    const metadata = firmwareSchema.parse({ model: f.model, hardware_version: f.hardware_version, version: f.version, firmware_type: f.firmware_type, url: f.url, checksum: f.checksum, file_size: Number(f.file_size), release_notes: f.release_notes });
    const { release_notes, firmware_type, ...wire } = metadata;
    Object.assign(payload, { firmware_id: f.id, ...wire });
   } else must(!b.firmware_id, 400, 'INVALID_COMMAND');
   must(Buffer.byteLength(JSON.stringify(payload)) <= 2048, 400, 'COMMAND_TOO_LARGE');
   await tx.execute('INSERT INTO device_commands(request_id,device_id,user_id,command,payload,expires_at) VALUES (?,?,?,?,?,?)', [requestId, d.id, u.id, b.command, JSON.stringify(payload), new Date(Date.now() + (b.command === 'firmware.update' ? this.config.OTA_TIMEOUT_SECONDS : this.config.COMMAND_TIMEOUT_SECONDS) * 1000)]);
   await tx.execute("INSERT INTO device_logs(device_id,user_id,event_type,payload) VALUES (?,?,'command.created',?)", [d.id, u.id, JSON.stringify({ request_id: requestId, command: b.command })]);
   return { old: false, request_id: requestId, device: sn, command_status: 'pending', payload };
  });
  if (!result.old) {
   try {
    await this.mqtt.publish(`devices/${sn}/command`, JSON.stringify(result.payload));
    await this.db.execute("UPDATE device_commands SET status='sent',sent_at=NOW(3) WHERE request_id=? AND status='pending'", [requestId]);
    result.command_status = 'sent';
   } catch {
    await this.db.execute("UPDATE device_commands SET status='failed',error='MQTT_ERROR' WHERE request_id=? AND status='pending'", [requestId]);
    throw new ApiError(503, 'MQTT_ERROR');
   }
  }
  return { request_id: result.request_id, device: result.device, command_status: result.command_status };
 }

 async expireCommands() {
  await this.db.execute("UPDATE device_commands SET status='timeout',error='COMMAND_TIMEOUT' WHERE status IN ('pending','sent') AND expires_at<=NOW(3)");
  await this.db.execute('UPDATE devices SET online=FALSE WHERE online=TRUE AND (last_seen IS NULL OR last_seen<DATE_SUB(NOW(3),INTERVAL 180 SECOND))');
 }

 async ingest(topic: string, raw: Buffer) {
  const match = /^devices\/([A-Z0-9-]{3,64})\/(state|telemetry|availability|response)$/.exec(topic);
  if (!match || raw.length > 16384) return;
  let body: any;
  try { body = JSON.parse(raw.toString()); } catch { return; }
  if (!body || typeof body !== 'object' || Array.isArray(body)) return;
  const sn = match[1]!, kind = match[2]!;
  await this.db.transaction(async tx => {
   const [d] = await tx.query('SELECT * FROM devices WHERE sn=? AND disabled=FALSE FOR UPDATE', [sn]);
   if (!d) return;
   if (kind === 'response') {
    const ack = z.object({ request_id: z.string().uuid(), success: z.boolean(), state: z.unknown().optional(), error: z.string().max(255).optional() }).safeParse(body);
    if (!ack.success) return;
    await tx.execute("UPDATE device_commands SET status=?,ack_at=NOW(3),error=? WHERE request_id=? AND device_id=? AND status IN ('pending','sent') AND expires_at>NOW(3)", [ack.data.success ? 'success' : 'failed', ack.data.success ? null : 'DEVICE_REJECTED', ack.data.request_id, d.id]);
   } else if (kind === 'availability') {
    if (typeof body.online !== 'boolean') return;
    await tx.execute('UPDATE devices SET online=?,last_seen=NOW(3) WHERE id=?', [body.online, d.id]);
    await tx.execute("INSERT INTO device_logs(device_id,event_type,payload) VALUES (?,?,'{}')", [d.id, body.online ? 'online' : 'offline']);
    return;
   } else {
    const fields = z.object({
     gpio: z.record(z.boolean()).optional(),
     channels: z.record(z.boolean()).optional(),
     rssi: z.number().int().min(-150).max(0).optional(),
     wifi_ssid: z.string().max(32).optional(),
     ip_address: z.string().ip().optional(),
     ip: z.string().ip().optional(),
     uptime: z.number().nonnegative().optional(),
     free_heap: z.number().nonnegative().optional(),
     firmware_version: z.string().max(32).optional(),
     firmware: z.string().max(32).optional(),
     temperature_c: z.number().min(-40).max(80).optional(),
     humidity_percent: z.number().min(0).max(100).optional()
    }).safeParse(body);
    if (!fields.success) return;
    const state: Record<string, any> = { ...fields.data };
    if (state.ip) { state.ip_address = state.ip; delete state.ip; }
    if (state.firmware) { state.firmware_version = state.firmware; delete state.firmware; }
    if (state.gpio) {
     const allowed = new Set(json<any[]>(d.channels).map(c => String(c.pin)));
     state.gpio = Object.fromEntries(Object.entries(state.gpio).filter(([pin]) => allowed.has(pin)));
    }
    const [previous] = await tx.query('SELECT state FROM device_states WHERE device_id=?', [d.id]);
    const old = json(previous?.state ?? {});
    const merged = { ...old, ...state, gpio: { ...old.gpio, ...state.gpio } };
    await tx.execute('INSERT INTO device_states(device_id,state) VALUES (?,?) ON DUPLICATE KEY UPDATE state=VALUES(state)', [d.id, JSON.stringify(merged)]);
    if (state.temperature_c !== undefined) {
     try {
      await tx.execute('INSERT INTO sensor_readings(device_id,temperature_c,humidity_percent) VALUES (?,?,?)', [d.id, state.temperature_c, state.humidity_percent ?? null]);
     } catch (error) {
      console.warn('[telemetry] sensor history write failed; keeping live state', error);
     }
    }
    if (state.firmware_version) await tx.execute('UPDATE devices SET firmware_version=? WHERE id=?', [state.firmware_version, d.id]);
   }
   await tx.execute('UPDATE devices SET online=TRUE,last_seen=NOW(3) WHERE id=?', [d.id]);
  });
  if (kind === 'availability' && body.online === true) await this.syncSchedulesForDevice(sn);
 }

 async sensorHistory(sn: string, u: User, rangeHours: number, bucketMinutes: number) {
  const d = await this.owned(sn, u);
  const hours = Math.min(Math.max(rangeHours, 1), 24 * 30);
  const bucket = Math.min(Math.max(bucketMinutes, 30), 60);
  const rows = await this.db.query<{ recorded_at: string | Date; temperature_c: number | string; humidity_percent: number | string | null }>(`SELECT recorded_at,temperature_c,humidity_percent FROM sensor_readings WHERE device_id=? AND recorded_at>=DATE_SUB(NOW(3),INTERVAL ${hours} HOUR) ORDER BY recorded_at ASC`, [d.id]);
  const seconds = bucket * 60;
  const buckets = new Map<number, { temperature: number; humidity: number; samples: number; humiditySamples: number }>();
  for (const row of rows) {
   const stamp = row.recorded_at instanceof Date ? row.recorded_at.getTime() : Date.parse(row.recorded_at);
   if (!Number.isFinite(stamp)) continue;
   const key = Math.floor(stamp / (seconds * 1000)) * seconds * 1000;
   const item = buckets.get(key) ?? { temperature: 0, humidity: 0, samples: 0, humiditySamples: 0 };
   item.temperature += Number(row.temperature_c);
   item.samples++;
   if (row.humidity_percent !== null) {
    item.humidity += Number(row.humidity_percent);
    item.humiditySamples++;
   }
   buckets.set(key, item);
  }
  return [...buckets.entries()].map(([stamp, item]) => ({
   time: new Date(stamp).toISOString(),
   temperature_c: Number((item.temperature / item.samples).toFixed(2)),
   humidity_percent: item.humiditySamples ? Number((item.humidity / item.humiditySamples).toFixed(2)) : null,
   samples: item.samples
  }));
 }

 async updateChannelAlias(sn: string, channelId: number, alias: string, u: User) {
  const d = await this.owned(sn, u);
  const channels = json<any[]>(d.channels);
  const channel = channels.find(c => c.id === channelId);
  must(channel, 404, 'CHANNEL_NOT_FOUND');
  channel.alias = alias.trim();
  await this.db.execute('UPDATE devices SET channels=? WHERE id=?', [JSON.stringify(channels), d.id]);
  return publicDevice({ ...d, channels: JSON.stringify(channels) });
 }
}
