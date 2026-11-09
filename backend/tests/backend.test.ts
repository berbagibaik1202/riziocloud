import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID, createHmac } from 'node:crypto';
import request from 'supertest';
import jwt from 'jsonwebtoken';
import { Service, firmwareSchema, inventorySchema, type User } from '../src/service.js';
import { createApp } from '../src/app.js';
import type { Config } from '../src/config.js';
import { deviceACL, encrypt, decrypt, localToken, sha256, redact } from '../src/security.js';
import { MemoryDB } from './memory-db.js';

const config:Config={PORT:3000,NODE_ENV:'test',DB_HOST:'localhost',DB_PORT:3306,DB_USER:'test',DB_PASSWORD:'test',DB_NAME:'test',JWT_SECRET:'j'.repeat(64),CREDENTIAL_ENCRYPTION_KEY:'ab'.repeat(32),INTERNAL_SECRET:'i'.repeat(32),MQTT_URL:'mqtts://localhost',MQTT_USERNAME:'backend',MQTT_PASSWORD:'m'.repeat(32),CORS_ORIGIN:'http://localhost',TRUST_PROXY:0,FIRMWARE_DIR:'./storage/test',FIRMWARE_PUBLIC_URL:'https://firmware.example.com',COMMAND_TIMEOUT_SECONDS:15,OTA_TIMEOUT_SECONDS:300};

test('sensor inventory accepts DHT11 and rejects missing sensor pin',()=>{
 const base={sn:'ESP-DHT11',name:'Sensor suhu',model:'ESP-DHT11',device_type:'sensor' as const,dht11_pin:14,hardware_version:'1.0',firmware_version:'1.1.0',capabilities:{temperature:true,humidity:true,sensor_type:'dht11'},channels:[{id:1,pin:14,name:'DHT11',alias:'',type:'sensor' as const,active_low:false}]};
 assert.equal(inventorySchema.safeParse(base).success,true);
 assert.equal(inventorySchema.safeParse({...base,dht11_pin:undefined}).success,false);
});
function fixture(){const db=new MemoryDB();const published:{topic:string;payload:any}[]=[];const mqtt={connected:true,async publish(topic:string,payload:string){published.push({topic,payload:JSON.parse(payload)});}};const service=new Service(db,config,mqtt);const a:User={id:randomUUID(),email:'a@example.com',name:'A',role:'user',status:'active'},b:User={id:randomUUID(),email:'b@example.com',name:'B',role:'user',status:'active'};db.users.push(a,b);db.devices.push({id:randomUUID(),sn:'ESP-TEST001',device_key_encrypted:encrypt('d'.repeat(64),config.CREDENTIAL_ENCRYPTION_KEY),claim_code_hash:sha256('claim-code-valid'),owner_user_id:null,name:'Test',model:'RELAY',hardware_version:'1.0',firmware_version:'1.0.0',online:true,disabled:false,channels:JSON.stringify([{id:1,pin:5,name:'Relay',type:'switch',active_low:true}]),capabilities:JSON.stringify({factory_reset:true})});return {db,service,a,b,published,mqtt,app:createApp(service)};}
const bearer=(u:User)=>jwt.sign({role:u.role,tenant_id:u.tenant_id??null},config.JWT_SECRET,{subject:u.id,issuer:'rizio',audience:'rizio-api',expiresIn:'15m'});

test('register hashes passwords, login verifies and JWT rejects tampering',async()=>{const {app,db}=fixture();const registered=await request(app).post('/v1/auth/register').send({email:'NEW@example.com',name:'New',password:'long-password-123'}).expect(201);assert.equal(registered.body.data.user.email,'new@example.com');assert.ok(db.users.at(-1).password_hash.startsWith('$2'));assert.equal(registered.body.data.user.password_hash,undefined);await request(app).post('/v1/auth/login').send({email:'new@example.com',password:'incorrect-password'}).expect(401);const login=await request(app).post('/v1/auth/login').send({email:'new@example.com',password:'long-password-123'}).expect(200);await request(app).get('/v1/auth/me').set('Authorization',`Bearer ${login.body.data.access_token}`).expect(200);await request(app).get('/v1/auth/me').set('Authorization',`Bearer ${login.body.data.access_token}x`).expect(401);});
test('refresh rotation and replay revoke the entire refresh family',async()=>{const {service,a,db}=fixture();const first=await service.tokens(a);const second=await service.refresh(first.refresh_token);assert.notEqual(first.refresh_token,second.refresh_token);await assert.rejects(service.refresh(first.refresh_token),{code:'AUTH_INVALID'});assert.ok(db.refresh.every(r=>r.revoked_at));await assert.rejects(service.refresh(second.refresh_token),{code:'AUTH_INVALID'});});
test('logout revokes refresh family while access token expires naturally',async()=>{const {service,a}=fixture();const first=await service.tokens(a);const second=await service.refresh(first.refresh_token);await service.logout(second.refresh_token);await assert.rejects(service.refresh(second.refresh_token),{code:'AUTH_INVALID'});assert.equal((await service.authenticate(second.access_token)).id,a.id);});
test('unclaim requires password and releases a device for SN-only reclaim',async()=>{const {service,app,db,a}=fixture();const registered=await service.register({email:'owner@example.com',password:'long-password-123',name:'Owner'});const owner=db.users.find(u=>u.id===registered.user.id);db.devices[0].owner_user_id=a.id;await request(app).delete('/v1/devices/ESP-TEST001').set('Authorization',`Bearer ${registered.access_token}`).send({password:'long-password-123'}).expect(403);db.devices[0].owner_user_id=owner.id;await assert.rejects(service.unclaim('ESP-TEST001','wrong-password',owner),{code:'AUTH_INVALID'});const removed=await service.unclaim('ESP-TEST001','long-password-123',owner);assert.equal(removed.unclaimed,true);assert.equal(db.devices[0].owner_user_id,null);await service.claim('ESP-TEST001',a);assert.equal(db.devices[0].owner_user_id,a.id);});
test('concurrent SN-only claim has exactly one owner',async()=>{const {service,a,b,db}=fixture();const results=await Promise.allSettled([service.claim('ESP-TEST001',a),service.claim('ESP-TEST001',b)]);assert.equal(results.filter(r=>r.status==='fulfilled').length,1);assert.ok([a.id,b.id].includes(db.devices[0].owner_user_id));await assert.rejects(service.claim('ESP-TEST001',b),{code:'DEVICE_ALREADY_CLAIMED'});});
test('HTTP enforces ownership on detail/status/token/rename/delete/commands and role on admin',async()=>{const {app,db,a,b}=fixture();db.devices[0].owner_user_id=a.id;for(const path of ['', '/status','/local-token','/commands/'+randomUUID()])await request(app).get('/v1/devices/ESP-TEST001'+path).set('Authorization',`Bearer ${bearer(b)}`).expect(403);await request(app).patch('/v1/devices/ESP-TEST001').set('Authorization',`Bearer ${bearer(b)}`).send({name:'stolen'}).expect(403);await request(app).post('/v1/devices/ESP-TEST001/commands').set('Authorization',`Bearer ${bearer(b)}`).send({command:'gpio.set',pin:5,state:true}).expect(403);await request(app).get('/v1/admin/devices').set('Authorization',`Bearer ${bearer(b)}`).expect(403);const own=await request(app).get('/v1/devices/ESP-TEST001').set('Authorization',`Bearer ${bearer(a)}`).expect(200);assert.ok(!JSON.stringify(own.body).includes('device_key'));assert.ok(!JSON.stringify(own.body).includes('claim_code'));});
test('MQTT ACL forbids wildcard, cross-device and command publishing; callback needs secret',async()=>{for(const topic of ['devices/+/command','devices/#','devices/ESP-OTHER/command'])assert.equal(deviceACL('ESP-TEST001',topic,'subscribe'),false);assert.equal(deviceACL('ESP-TEST001','devices/ESP-TEST001/command','publish'),false);assert.equal(deviceACL('ESP-TEST001','devices/ESP-TEST001/state','publish'),true);const {app}=fixture();await request(app).post('/internal/mqtt/auth').send({}).expect(403);const accepted=await request(app).post('/internal/mqtt/auth').set('x-internal-secret',config.INTERNAL_SECRET).send({username:'ESP-TEST001',clientid:'ESP-TEST001',password:'d'.repeat(64)}).expect(200);assert.equal(accepted.body.result,'allow');const denied=await request(app).post('/internal/mqtt/acl').set('x-internal-secret',config.INTERNAL_SECRET).send({username:'ESP-TEST001',topic:'devices/ESP-OTHER/state',action:'publish'});assert.equal(denied.body.result,'deny');});
test('command deduplication, pin validation, ACK device binding and terminal status',async()=>{const {service,db,a,published}=fixture();db.devices[0].owner_user_id=a.id;const id=randomUUID();const body={command:'gpio.set',pin:5,state:true,request_id:id};assert.equal((await service.command('ESP-TEST001',body,a)).command_status,'sent');await service.command('ESP-TEST001',body,a);assert.equal(published.length,1);await assert.rejects(service.command('ESP-TEST001',{...body,state:false},a),{code:'REQUEST_ID_CONFLICT'});await assert.rejects(service.command('ESP-TEST001',{command:'gpio.set',pin:2,state:true},a),{code:'INVALID_GPIO'});db.devices.push({...db.devices[0],id:randomUUID(),sn:'ESP-OTHER'});await service.ingest('devices/ESP-OTHER/response',Buffer.from(JSON.stringify({request_id:id,success:true})));assert.equal(db.commands[0].status,'sent');await service.ingest('devices/ESP-TEST001/response',Buffer.from(JSON.stringify({request_id:id,success:true})));assert.equal(db.commands[0].status,'success');await service.ingest('devices/ESP-TEST001/response',Buffer.from(JSON.stringify({request_id:id,success:false})));assert.equal(db.commands[0].status,'success');});
test('persistent timeout survives restart and late ACK cannot reverse timeout',async()=>{const {service,db,a,mqtt}=fixture();db.devices[0].owner_user_id=a.id;const c=await service.command('ESP-TEST001',{command:'system.reboot'},a);db.commands[0].expires_at=new Date(Date.now()-1000);const restarted=new Service(db,config,mqtt);await restarted.expireCommands();assert.equal(db.commands[0].status,'timeout');await restarted.ingest('devices/ESP-TEST001/response',Buffer.from(JSON.stringify({request_id:c.request_id,success:true})));assert.equal(db.commands[0].status,'timeout');});
test('MQTT failure persists failed status without automatic unsafe retries',async()=>{const {service,db,a,mqtt}=fixture();db.devices[0].owner_user_id=a.id;mqtt.publish=async()=>{throw Error('offline');};await assert.rejects(service.command('ESP-TEST001',{command:'system.reboot'},a),{code:'MQTT_ERROR'});assert.equal(db.commands[0].status,'failed');});
test('OTA validates metadata, matching model/hardware, and sends bounded wire payload',async()=>{const good={model:'RELAY',hardware_version:'1.0',version:'1.2.3',url:'https://firmware.example.com/a.bin',checksum:'ab'.repeat(32),file_size:100,release_notes:'x'.repeat(10000)};assert.equal(firmwareSchema.safeParse({...good,url:'http://unsafe/a.bin'}).success,false);assert.equal(firmwareSchema.safeParse({...good,checksum:'invalid'}).success,false);const {service,db,a,published}=fixture();db.devices[0].owner_user_id=a.id;const id=randomUUID();db.firmwares.push({id,...good,is_active:true,hardware_version:'2.0'});await assert.rejects(service.command('ESP-TEST001',{command:'firmware.update',firmware_id:id},a),{code:'FIRMWARE_INCOMPATIBLE'});db.firmwares[0].hardware_version='1.0';await service.command('ESP-TEST001',{command:'firmware.update',firmware_id:id},a);assert.equal(published[0]!.payload.release_notes,undefined);assert.ok(Buffer.byteLength(JSON.stringify(published[0]!.payload))<2048);});
test('state telemetry merges without clearing GPIO and ignores unconfigured pins',async()=>{const {service,db}=fixture();await service.ingest('devices/ESP-TEST001/state',Buffer.from(JSON.stringify({gpio:{'5':true,'99':true}})));await service.ingest('devices/ESP-TEST001/telemetry',Buffer.from(JSON.stringify({rssi:-62,ip:'192.168.1.10',firmware:'1.2.0'})));const state=JSON.parse(db.states[0].state);assert.deepEqual(state.gpio,{'5':true});assert.equal(state.rssi,-62);assert.equal(state.ip_address,'192.168.1.10');assert.equal(db.devices[0].firmware_version,'1.2.0');await service.ingest('devices/ESP-TEST001/availability',Buffer.from('{"online":false}'));assert.equal(db.devices[0].online,false);});
test('local token uses interoperable HMAC with 60 second expiry; credentials authenticated encrypted and audit redacted',()=>{const now=1700000000000,key='k'.repeat(64);const out=localToken('ESP-TEST001',key,now);const [payload,signature]=out.token.split('.');assert.equal(signature,createHmac('sha256',key).update(payload!).digest('hex'));assert.deepEqual(JSON.parse(Buffer.from(payload!,'base64url').toString()),{sn:'ESP-TEST001',exp:1700000060,scope:'local'});const encrypted=encrypt(key,config.CREDENTIAL_ENCRYPTION_KEY);assert.equal(decrypt(encrypted,config.CREDENTIAL_ENCRYPTION_KEY),key);assert.throws(()=>decrypt(encrypted.slice(0,-2)+'00',config.CREDENTIAL_ENCRYPTION_KEY));assert.deepEqual(redact({nested:{password:'secret',device_key:'key'},request_id:'safe'}),{nested:{password:'[REDACTED]',device_key:'[REDACTED]'},request_id:'safe'});});

test('SaaS Multi-Tenancy: Superadmin creates tenant, Tenant Admin claims device and enforces isolation', async () => {
 const { app, db, service } = fixture();
 const admin: User = { id: randomUUID(), email: 'super@example.com', name: 'Super Admin', role: 'admin', status: 'active' };
 db.users.push(admin);

 // 1. Superadmin creates Tenant A and Tenant B
 const resA = await request(app).post('/v1/admin/tenants').set('Authorization', `Bearer ${bearer(admin)}`).send({
  name: 'Tenant Alpha',
  slug: 'tenant-alpha',
  max_devices: 5,
  admin_email: 'admin@alpha.com',
  admin_name: 'Admin Alpha',
  admin_password: 'password-alpha-123'
 }).expect(201);
 assert.equal(resA.body.data.slug, 'tenant-alpha');
 const tenantAId = resA.body.data.id;
 const tenantAdminA = db.users.find(u => u.email === 'admin@alpha.com');
 assert.ok(tenantAdminA);
 assert.equal(tenantAdminA.role, 'tenant_admin');
 assert.equal(tenantAdminA.tenant_id, tenantAId);

 const resB = await request(app).post('/v1/admin/tenants').set('Authorization', `Bearer ${bearer(admin)}`).send({
  name: 'Tenant Beta',
  slug: 'tenant-beta',
  max_devices: 5,
  admin_email: 'admin@beta.com',
  admin_name: 'Admin Beta',
  admin_password: 'password-beta-123'
 }).expect(201);
 const tenantBId = resB.body.data.id;
 const tenantAdminB = db.users.find(u => u.email === 'admin@beta.com');

 // Non-admin cannot create tenants
 await request(app).post('/v1/admin/tenants').set('Authorization', `Bearer ${bearer(tenantAdminA)}`).send({
  name: 'Hacker Tenant',
  slug: 'hacker-tenant',
  admin_email: 'hacker@example.com',
  admin_name: 'Hacker',
  admin_password: 'password-hacker-123'
 }).expect(403);

 // 2. Tenant Admin A claims device ESP-TEST001
 const claimRes = await request(app).post('/v1/tenant/devices/claim').set('Authorization', `Bearer ${bearer(tenantAdminA)}`).send({
  sn: 'ESP-TEST001'
 }).expect(200);
 assert.equal(claimRes.body.data.tenant_id, tenantAId);
 assert.equal(db.devices[0].tenant_id, tenantAId);

 // Tenant Admin A can list and control the device
 const listA = await request(app).get('/v1/devices').set('Authorization', `Bearer ${bearer(tenantAdminA)}`).expect(200);
 assert.equal(listA.body.data.length, 1);
 assert.equal(listA.body.data[0].sn, 'ESP-TEST001');

 await request(app).post('/v1/devices/ESP-TEST001/commands').set('Authorization', `Bearer ${bearer(tenantAdminA)}`).send({
  command: 'gpio.set',
  pin: 5,
  state: true
 }).expect(202);

 // 3. Tenant Admin B CANNOT view or control Tenant A's device
 const listB = await request(app).get('/v1/devices').set('Authorization', `Bearer ${bearer(tenantAdminB)}`).expect(200);
 assert.equal(listB.body.data.length, 0);

 await request(app).get('/v1/devices/ESP-TEST001').set('Authorization', `Bearer ${bearer(tenantAdminB)}`).expect(403);
 await request(app).post('/v1/devices/ESP-TEST001/commands').set('Authorization', `Bearer ${bearer(tenantAdminB)}`).send({
  command: 'gpio.set',
  pin: 5,
  state: true
 }).expect(403);

 // 4. Tenant Admin A creates a Tenant User
 const createdUser = await request(app).post('/v1/tenant/users').set('Authorization', `Bearer ${bearer(tenantAdminA)}`).send({
  email: 'operator@alpha.com',
  name: 'Operator Alpha',
  password: 'operator-password-123',
  role: 'user'
 }).expect(201);
 assert.equal(createdUser.body.data.role, 'user');
 assert.equal(createdUser.body.data.tenant_id, tenantAId);

 const userAlpha = db.users.find(u => u.email === 'operator@alpha.com');
 assert.ok(userAlpha);

 // Tenant User Alpha CAN control device of Tenant A
 await request(app).post('/v1/devices/ESP-TEST001/commands').set('Authorization', `Bearer ${bearer(userAlpha)}`).send({
  command: 'gpio.set',
  pin: 5,
  state: false
 }).expect(202);

 // Regular Tenant User CANNOT create another tenant user
 await request(app).post('/v1/tenant/users').set('Authorization', `Bearer ${bearer(userAlpha)}`).send({
  email: 'another@alpha.com',
  name: 'Another',
  password: 'another-password-123'
 }).expect(403);

 // 5. Superadmin suspends Tenant A -> access is blocked
 await request(app).patch(`/v1/admin/tenants/${tenantAId}`).set('Authorization', `Bearer ${bearer(admin)}`).send({
  status: 'suspended'
 }).expect(200);

 await request(app).get('/v1/devices/ESP-TEST001').set('Authorization', `Bearer ${bearer(tenantAdminA)}`).expect(403);
 await request(app).post('/v1/devices/ESP-TEST001/commands').set('Authorization', `Bearer ${bearer(userAlpha)}`).send({
  command: 'gpio.set',
  pin: 5,
  state: true
 }).expect(403);
});

test('Firmware upload accepts both standard binary (0xE9 at byte 0) and merged binary (0xE9 at byte 0x1000)', async () => {
 const { app, db } = fixture();
 const admin: User = { id: randomUUID(), email: 'admin@firmware.test', name: 'Admin', role: 'admin', status: 'active' };
 db.users.push(admin);

 // 1. Standard binary (buffer[0] === 0xe9)
 const standardBuf = Buffer.alloc(100);
 standardBuf[0] = 0xe9;
 await request(app)
  .post('/v1/admin/firmwares/upload')
  .set('Authorization', `Bearer ${bearer(admin)}`)
  .attach('file', standardBuf, 'standard.bin')
  .field('model', 'ESP-STANDARD')
  .field('hardware_version', '1.0')
  .field('version', '1.0.0')
  .expect(201);

 // 2. Merged binary (buffer[0] === 0xff, buffer[0x1000] === 0xe9)
 const mergedBuf = Buffer.alloc(0x2000, 0xff);
 mergedBuf[0x1000] = 0xe9;
 await request(app)
  .post('/v1/admin/firmwares/upload')
  .set('Authorization', `Bearer ${bearer(admin)}`)
  .attach('file', mergedBuf, 'merged.bin')
  .field('model', 'ESP-MERGED')
  .field('hardware_version', '1.0')
  .field('version', '1.0.0')
  .expect(201);

 // 3. Invalid binary (no 0xe9)
 const invalidBuf = Buffer.alloc(100, 0x00);
 await request(app)
  .post('/v1/admin/firmwares/upload')
  .set('Authorization', `Bearer ${bearer(admin)}`)
  .attach('file', invalidBuf, 'invalid.bin')
  .field('model', 'ESP-INVALID')
  .field('hardware_version', '1.0')
  .field('version', '1.0.0')
  .expect(400);
});

