import { randomUUID } from 'node:crypto';
import bcrypt from 'bcryptjs';
import jwt from 'jsonwebtoken';
import { z } from 'zod';
import type { Config } from './config.js';
import type { DB } from './db.js';
import { json } from './db.js';
import { ApiError, must } from './errors.js';
import { sha256, secret, encrypt, decrypt, equal, localToken, redact } from './security.js';

export interface User {id:string;email:string;name:string;role:'user'|'admin';status:string;password_hash?:string}
export interface Publisher {connected:boolean; publish(topic:string,payload:string):Promise<void>}
export const relayTypes=['relay_1ch','relay_2ch','relay_4ch','relay_8ch'] as const;
export const channelSchema=z.object({id:z.number().int().positive(),pin:z.number().int().min(0).max(39),name:z.string().min(1).max(64),alias:z.string().trim().max(100).default(''),type:z.enum(['switch','pwm','sensor']),active_low:z.boolean()}).strict();
export const inventorySchema=z.object({sn:z.string().regex(/^[A-Z0-9-]{3,64}$/),name:z.string().min(1).max(100),model:z.string().min(1).max(64),device_type:z.enum(['relay','switch','other']).default('relay'),relay_type:z.enum(relayTypes).nullable().optional(),hardware_version:z.string().min(1).max(32),firmware_version:z.string().min(1).max(32).default('unknown'),capabilities:z.record(z.unknown()).default({}),channels:z.array(channelSchema).max(40).refine(v=>new Set(v.map(c=>c.pin)).size===v.length&&new Set(v.map(c=>c.id)).size===v.length,'Duplicate channel pin/id'),device_key:z.string().regex(/^[a-f0-9]{64}$/).optional(),setup_code:z.string().min(16).max(63).optional()}).strict().superRefine((v,ctx)=>{if(v.device_type==='relay'||v.device_type==='switch'){const relayType=v.relay_type;if(!relayType)ctx.addIssue({code:'custom',path:['relay_type'],message:'relay_type is required'});else{const n=Number(relayType.split('_')[1]?.replace('ch','')??0);if(v.channels.length!==n)ctx.addIssue({code:'custom',path:['channels'],message:`${relayType} requires ${n} channels`});}}});
export const firmwareSchema=z.object({model:z.string().min(1).max(64),hardware_version:z.string().min(1).max(32),version:z.string().regex(/^\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?$/).max(32),url:z.string().url().max(1024).refine(v=>{const u=new URL(v);return u.protocol==='https:'&&!u.username&&!u.password&&!u.hash;},'HTTPS URL without credentials required'),checksum:z.string().regex(/^[a-fA-F0-9]{64}$/).transform(v=>v.toLowerCase()),file_size:z.number().int().positive().max(16*1024*1024),release_notes:z.string().max(10000).default('')}).strict();
export const commandSchema=z.object({command:z.enum(['gpio.set','system.reboot','system.factory_reset','firmware.update']),channel_id:z.number().int().positive().optional(),pin:z.number().int().min(0).max(39).optional(),state:z.boolean().optional(),firmware_id:z.string().uuid().optional(),request_id:z.string().uuid().optional()}).strict();
export type CommandInput=z.infer<typeof commandSchema>;
export function publicUser(u:User){return {id:u.id,email:u.email,name:u.name,role:u.role,status:u.status};}
export function publicDevice(d:any){return {sn:d.sn,name:d.name,model:d.model,device_type:d.device_type??'relay',relay_type:d.relay_type??null,hardware_version:d.hardware_version,firmware_version:d.firmware_version,online:!!d.online&&!d.disabled,disabled:!!d.disabled,last_seen:d.last_seen,capabilities:json(d.capabilities),channels:json(d.channels),state:json(d.state??{})};}
export class Service {
 constructor(public db:DB,public config:Config,public mqtt:Publisher){}
 async audit(event:string,deviceId:string|null,userId:string|null,payload:unknown={}){await this.db.execute('INSERT INTO device_logs(device_id,user_id,event_type,payload) VALUES (?,?,?,?)',[deviceId,userId,event,JSON.stringify(redact(payload))]);}
 async tokens(u:User,db:DB=this.db,familyId=randomUUID()){
  const refresh=secret();await db.execute('INSERT INTO refresh_tokens(token_hash,user_id,family_id,expires_at) VALUES (?,?,?,?)',[sha256(refresh),u.id,familyId,new Date(Date.now()+30*86400000)]);
  return {user:publicUser(u),access_token:jwt.sign({role:u.role},this.config.JWT_SECRET,{subject:u.id,expiresIn:'15m',issuer:'rizio',audience:'rizio-api',algorithm:'HS256'}),refresh_token:refresh};
 }
 async register(body:unknown){const b=z.object({email:z.string().email().max(254).transform(v=>v.toLowerCase()),password:z.string().min(12).max(72),name:z.string().trim().min(1).max(100)}).strict().parse(body);const u:User={id:randomUUID(),email:b.email,name:b.name,role:'user',status:'active'};await this.db.execute('INSERT INTO users(id,email,password_hash,name) VALUES (?,?,?,?)',[u.id,u.email,await bcrypt.hash(b.password,12),u.name]);return this.tokens(u);}
 async login(body:unknown){const b=z.object({email:z.string().email().transform(v=>v.toLowerCase()),password:z.string().min(1).max(72)}).strict().parse(body);const [u]=await this.db.query<User>('SELECT * FROM users WHERE email=?',[b.email]);const valid=await bcrypt.compare(b.password,u?.password_hash??'$2b$12$C6UzMDM.H6dfI/f/IKcEe.9V4xnBwRXf7oVHZ5.vF9FCOnSZR.ljW');must(u&&valid&&u.status==='active',401,'AUTH_INVALID');return this.tokens(u);}
 async refresh(token:string){
  // Return a failure marker from the transaction so replay revocation is COMMITTED.
  const result=await this.db.transaction(async tx=>{const [r]=await tx.query('SELECT * FROM refresh_tokens WHERE token_hash=? FOR UPDATE',[sha256(token)]);if(!r)return null;
   if(r.revoked_at||new Date(r.expires_at).getTime()<=Date.now()){await tx.execute('UPDATE refresh_tokens SET revoked_at=COALESCE(revoked_at,NOW(3)) WHERE family_id=?',[r.family_id]);return null;}
   const [u]=await tx.query<User>('SELECT * FROM users WHERE id=? AND status=\'active\'',[r.user_id]);if(!u)return null;
   await tx.execute('UPDATE refresh_tokens SET revoked_at=NOW(3) WHERE token_hash=?',[sha256(token)]);return this.tokens(u,tx,r.family_id);
  });must(result,401,'AUTH_INVALID');return result;
 }
 async logout(token:string){await this.db.execute('UPDATE refresh_tokens SET revoked_at=COALESCE(revoked_at,NOW(3)) WHERE family_id IN (SELECT family_id FROM (SELECT family_id FROM refresh_tokens WHERE token_hash=?) AS family)',[sha256(token)]);return {logged_out:true};}
 async authenticate(token:string){let sub:string;try{const p=jwt.verify(token,this.config.JWT_SECRET,{algorithms:['HS256'],issuer:'rizio',audience:'rizio-api'});must(typeof p!=='string'&&typeof p.sub==='string',401,'AUTH_INVALID');sub=p.sub;}catch{throw new ApiError(401,'AUTH_INVALID');}const [u]=await this.db.query<User>('SELECT id,email,name,role,status FROM users WHERE id=? AND status=\'active\'',[sub]);must(u,401,'AUTH_INVALID');return u;}
 async getDevice(sn:string,db:DB=this.db){const [d]=await db.query('SELECT d.*,s.state FROM devices d LEFT JOIN device_states s ON s.device_id=d.id WHERE d.sn=?',[sn]);must(d,404,'DEVICE_NOT_FOUND');return d;}
 async owned(sn:string,u:User,db:DB=this.db){const d=await this.getDevice(sn,db);must(d.owner_user_id===u.id,403,'DEVICE_NOT_OWNED');must(!d.disabled,403,'DEVICE_DISABLED');return d;}
 async list(u:User){return (await this.db.query('SELECT d.*,s.state FROM devices d LEFT JOIN device_states s ON s.device_id=d.id WHERE d.owner_user_id=? ORDER BY d.created_at DESC',[u.id])).map(publicDevice);}
 async claim(sn:string,u:User){return this.db.transaction(async tx=>{
  const [d]=await tx.query('SELECT * FROM devices WHERE sn=? FOR UPDATE',[sn]);must(d,404,'DEVICE_NOT_FOUND');must(!d.disabled,403,'DEVICE_DISABLED');must(!d.owner_user_id,409,'DEVICE_ALREADY_CLAIMED');
  const r=await tx.execute('UPDATE devices SET owner_user_id=? WHERE id=? AND owner_user_id IS NULL',[u.id,d.id]);must(r.affectedRows===1,409,'DEVICE_ALREADY_CLAIMED');await tx.execute('INSERT INTO device_logs(device_id,user_id,event_type,payload) VALUES (?,?,\'claim\',\'{}\')',[d.id,u.id]);return publicDevice({...d,owner_user_id:u.id});
 });}
 async unclaim(sn:string,password:string,u:User){const [account]=await this.db.query<User>('SELECT * FROM users WHERE id=?',[u.id]);must(account?.password_hash&&await bcrypt.compare(password,account.password_hash),401,'AUTH_INVALID');return this.db.transaction(async tx=>{const [d]=await tx.query('SELECT * FROM devices WHERE sn=? FOR UPDATE',[sn]);must(d,404,'DEVICE_NOT_FOUND');must(d.owner_user_id===u.id,403,'DEVICE_NOT_OWNED');await tx.execute('UPDATE devices SET owner_user_id=NULL WHERE id=?',[d.id]);await tx.execute("UPDATE device_commands SET status='failed',error='DEVICE_UNCLAIMED' WHERE device_id=? AND status IN ('pending','sent')",[d.id]);await tx.execute('INSERT INTO device_logs(device_id,user_id,event_type,payload) VALUES (?,?,\'unclaim\',\'{}\')',[d.id,u.id]);return {sn,unclaimed:true};});}
 async createDevice(body:unknown,u:User){const b=inventorySchema.parse(body);must(b.sn!==this.config.MQTT_USERNAME,400,'RESERVED_DEVICE_SN');const key=b.device_key??secret(),setup=b.setup_code??secret().slice(0,48);must(key!==setup,400,'CREDENTIALS_MUST_DIFFER');const id=randomUUID();await this.db.execute('INSERT INTO devices(id,sn,device_key_encrypted,claim_code_hash,name,device_type,relay_type,model,hardware_version,firmware_version,capabilities,channels) VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',[id,b.sn,encrypt(key,this.config.CREDENTIAL_ENCRYPTION_KEY),null,b.name,b.device_type,b.relay_type??null,b.model,b.hardware_version,b.firmware_version,JSON.stringify(b.capabilities),JSON.stringify(b.channels)]);await this.audit('inventory.created',id,u.id,{sn:b.sn,device_type:b.device_type,relay_type:b.relay_type});return {device:publicDevice({...b,id,online:false,disabled:false}),production_credentials:{sn:b.sn,device_key:key,setup_code:setup}};}
 async deleteDevice(sn:string,u:User){await this.db.transaction(async tx=>{const [d]=await tx.query('SELECT id FROM devices WHERE sn=? FOR UPDATE',[sn]);must(d,404,'DEVICE_NOT_FOUND');await tx.execute('DELETE FROM device_states WHERE device_id=?',[d.id]);await tx.execute('DELETE FROM device_commands WHERE device_id=?',[d.id]);await tx.execute('DELETE FROM device_logs WHERE device_id=?',[d.id]);await tx.execute('DELETE FROM devices WHERE id=?',[d.id]);});return {sn,deleted:true};}
 async deleteUser(id:string,u:User){must(id!==u.id,400,'CANNOT_DELETE_SELF');await this.db.transaction(async tx=>{const devices=await tx.query<{id:string}>('SELECT id FROM devices WHERE owner_user_id=? FOR UPDATE',[id]);for(const d of devices){await tx.execute('DELETE FROM device_states WHERE device_id=?',[d.id]);await tx.execute('DELETE FROM device_commands WHERE device_id=?',[d.id]);await tx.execute('DELETE FROM device_logs WHERE device_id=?',[d.id]);await tx.execute('DELETE FROM devices WHERE id=?',[d.id]);}await tx.execute('DELETE FROM device_logs WHERE user_id=?',[id]);await tx.execute('DELETE FROM refresh_tokens WHERE user_id=?',[id]);const result=await tx.execute('DELETE FROM users WHERE id=?',[id]);must(result.affectedRows===1,404,'USER_NOT_FOUND');});return {id,deleted:true};}
 async deviceAuth(sn:string,key:string){const [d]=await this.db.query('SELECT * FROM devices WHERE sn=? AND disabled=FALSE',[sn]);return d&&equal(decrypt(d.device_key_encrypted,this.config.CREDENTIAL_ENCRYPTION_KEY),key)?d:null;}
 async local(sn:string,u:User){const d=await this.owned(sn,u);return localToken(sn,decrypt(d.device_key_encrypted,this.config.CREDENTIAL_ENCRYPTION_KEY));}
 async createFirmware(body:unknown,u:User){const b=firmwareSchema.parse(body);const id=randomUUID();await this.db.execute('INSERT INTO firmwares(id,model,hardware_version,version,url,checksum,file_size,release_notes) VALUES (?,?,?,?,?,?,?,?)',[id,b.model,b.hardware_version,b.version,b.url,b.checksum,b.file_size,b.release_notes]);await this.audit('firmware.created',null,u.id,{firmware_id:id,version:b.version});return {id,...b,is_active:true};}
 async command(sn:string,input:unknown,u:User,admin=false){const b=commandSchema.parse(input);const requestId=b.request_id??randomUUID();
  const result=await this.db.transaction(async tx=>{
   const [d]=await tx.query('SELECT * FROM devices WHERE sn=? FOR UPDATE',[sn]);must(d,404,'DEVICE_NOT_FOUND');must(admin&&u.role==='admin'||d.owner_user_id===u.id,403,'DEVICE_NOT_OWNED');must(!d.disabled,403,'DEVICE_DISABLED');
   const [old]=await tx.query('SELECT * FROM device_commands WHERE request_id=?',[requestId]);if(old){must(old.device_id===d.id&&old.user_id===u.id,409,'REQUEST_ID_CONFLICT');const p=json(old.payload);must(old.command===b.command&&p.pin===b.pin&&(b.channel_id===undefined||p.channel_id===b.channel_id)&&p.state===b.state&&p.firmware_id===b.firmware_id,409,'REQUEST_ID_CONFLICT');return {old:true,request_id:requestId,device:sn,command_status:old.status};}
   must(!!d.online,409,'DEVICE_OFFLINE');must(this.mqtt.connected,503,'MQTT_ERROR');
   const payload:Record<string,any>={request_id:requestId,cmd:b.command,timestamp:Math.floor(Date.now()/1000)};
   if(b.command==='gpio.set'){must(b.state!==undefined&&!b.firmware_id&&(b.channel_id!==undefined||b.pin!==undefined),400,'INVALID_COMMAND');const channel=json<any[]>(d.channels).find(c=>(b.channel_id!==undefined?c.id===b.channel_id:c.pin===b.pin)&&c.type==='switch');must(channel,400,'INVALID_GPIO');if(b.pin!==undefined)must(channel.pin===b.pin,400,'INVALID_GPIO');payload.channel_id=channel.id;payload.pin=channel.pin;payload.state=b.state;}
   else {must(b.pin===undefined&&b.state===undefined,400,'INVALID_COMMAND');}
   if(b.command==='system.factory_reset')must(json(d.capabilities).factory_reset===true,403,'COMMAND_NOT_ALLOWED');
   if(b.command==='firmware.update'){must(b.firmware_id,400,'INVALID_COMMAND');const [f]=await tx.query('SELECT * FROM firmwares WHERE id=? AND is_active=TRUE',[b.firmware_id]);must(f&&f.model===d.model&&f.hardware_version===d.hardware_version,400,'FIRMWARE_INCOMPATIBLE');const metadata=firmwareSchema.parse({model:f.model,hardware_version:f.hardware_version,version:f.version,url:f.url,checksum:f.checksum,file_size:Number(f.file_size),release_notes:f.release_notes});const {release_notes,...wire}=metadata;Object.assign(payload,{firmware_id:f.id,...wire});}
   else must(!b.firmware_id,400,'INVALID_COMMAND');
   must(Buffer.byteLength(JSON.stringify(payload))<=2048,400,'COMMAND_TOO_LARGE');
   await tx.execute('INSERT INTO device_commands(request_id,device_id,user_id,command,payload,expires_at) VALUES (?,?,?,?,?,?)',[requestId,d.id,u.id,b.command,JSON.stringify(payload),new Date(Date.now()+(b.command==='firmware.update'?this.config.OTA_TIMEOUT_SECONDS:this.config.COMMAND_TIMEOUT_SECONDS)*1000)]);
   await tx.execute('INSERT INTO device_logs(device_id,user_id,event_type,payload) VALUES (?,?,\'command.created\',?)',[d.id,u.id,JSON.stringify({request_id:requestId,command:b.command})]);
   return {old:false,request_id:requestId,device:sn,command_status:'pending',payload};
  });
  if(!result.old){try{await this.mqtt.publish(`devices/${sn}/command`,JSON.stringify(result.payload));await this.db.execute("UPDATE device_commands SET status='sent',sent_at=NOW(3) WHERE request_id=? AND status='pending'",[requestId]);result.command_status='sent';}catch{await this.db.execute("UPDATE device_commands SET status='failed',error='MQTT_ERROR' WHERE request_id=? AND status='pending'",[requestId]);throw new ApiError(503,'MQTT_ERROR');}}
  return {request_id:result.request_id,device:result.device,command_status:result.command_status};
 }
 async expireCommands(){await this.db.execute("UPDATE device_commands SET status='timeout',error='COMMAND_TIMEOUT' WHERE status IN ('pending','sent') AND expires_at<=NOW(3)");await this.db.execute('UPDATE devices SET online=FALSE WHERE online=TRUE AND (last_seen IS NULL OR last_seen<DATE_SUB(NOW(3),INTERVAL 180 SECOND))');}
 async ingest(topic:string,raw:Buffer){
  const match=/^devices\/([A-Z0-9-]{3,64})\/(state|telemetry|availability|response)$/.exec(topic);if(!match||raw.length>16384)return;
  let body:any;try{body=JSON.parse(raw.toString());}catch{return;}if(!body||typeof body!=='object'||Array.isArray(body))return;
  const sn=match[1]!,kind=match[2]!;
  await this.db.transaction(async tx=>{const [d]=await tx.query('SELECT * FROM devices WHERE sn=? AND disabled=FALSE FOR UPDATE',[sn]);if(!d)return;
   if(kind==='response'){
    const ack=z.object({request_id:z.string().uuid(),success:z.boolean(),state:z.unknown().optional(),error:z.string().max(255).optional()}).safeParse(body);if(!ack.success)return;
    await tx.execute("UPDATE device_commands SET status=?,ack_at=NOW(3),error=? WHERE request_id=? AND device_id=? AND status IN ('pending','sent') AND expires_at>NOW(3)",[ack.data.success?'success':'failed',ack.data.success?null:'DEVICE_REJECTED',ack.data.request_id,d.id]);
    // State comes through the state topic; ACK cannot overwrite actual state out of order.
   }else if(kind==='availability'){
    if(typeof body.online!=='boolean')return;await tx.execute('UPDATE devices SET online=?,last_seen=NOW(3) WHERE id=?',[body.online,d.id]);
    await tx.execute('INSERT INTO device_logs(device_id,event_type,payload) VALUES (?,?,\'{}\')',[d.id,body.online?'online':'offline']);return;
   }else{
    const fields=z.object({gpio:z.record(z.boolean()).optional(),channels:z.record(z.boolean()).optional(),rssi:z.number().int().min(-150).max(0).optional(),ip_address:z.string().ip().optional(),ip:z.string().ip().optional(),uptime:z.number().nonnegative().optional(),free_heap:z.number().nonnegative().optional(),firmware_version:z.string().max(32).optional(),firmware:z.string().max(32).optional()}).safeParse(body);if(!fields.success)return;
    const state:Record<string,any>={...fields.data};if(state.ip){state.ip_address=state.ip;delete state.ip;}if(state.firmware){state.firmware_version=state.firmware;delete state.firmware;}
    if(state.gpio){const allowed=new Set(json<any[]>(d.channels).map(c=>String(c.pin)));state.gpio=Object.fromEntries(Object.entries(state.gpio).filter(([pin])=>allowed.has(pin)));}
    const [previous]=await tx.query('SELECT state FROM device_states WHERE device_id=?',[d.id]);const old=json(previous?.state??{});const merged={...old,...state,gpio:{...old.gpio,...state.gpio}};
    await tx.execute('INSERT INTO device_states(device_id,state) VALUES (?,?) ON DUPLICATE KEY UPDATE state=VALUES(state)',[d.id,JSON.stringify(merged)]);
    if(state.firmware_version)await tx.execute('UPDATE devices SET firmware_version=? WHERE id=?',[state.firmware_version,d.id]);
   }
   await tx.execute('UPDATE devices SET online=TRUE,last_seen=NOW(3) WHERE id=?',[d.id]);
  });
 }
 async updateChannelAlias(sn:string,channelId:number,alias:string,u:User){const d=await this.owned(sn,u);const channels=json<any[]>(d.channels);const channel=channels.find(c=>c.id===channelId);must(channel,404,'CHANNEL_NOT_FOUND');channel.alias=alias.trim();await this.db.execute('UPDATE devices SET channels=? WHERE id=? AND owner_user_id=?',[JSON.stringify(channels),d.id,u.id]);return publicDevice({...d,channels:JSON.stringify(channels)});}
}
