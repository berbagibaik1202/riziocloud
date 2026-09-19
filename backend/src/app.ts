import express, { type Request, type Response, type NextFunction } from 'express';
import cors from 'cors';
import helmet from 'helmet';
import rateLimit from 'express-rate-limit';
import multer from 'multer';
import { mkdir, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { randomUUID } from 'node:crypto';
import { z, ZodError } from 'zod';
import { Service, publicUser, publicDevice, type User } from './service.js';
import { ApiError, must } from './errors.js';
import { deviceACL, equal, sha256 } from './security.js';

declare global {namespace Express {interface Request {user?:User}}}
const ok=(res:Response,data:unknown,status=200)=>res.status(status).json({status:'success',data});
const sn=(r:Request)=>z.string().regex(/^[A-Z0-9-]{3,64}$/).parse(r.params.sn);
const refreshBody=z.object({refresh_token:z.string().regex(/^[a-f0-9]{64}$/)}).strict();
export function createApp(s:Service){
 const app=express();app.disable('x-powered-by');app.set('trust proxy',s.config.TRUST_PROXY);
 app.use(helmet());app.use(cors({origin:s.config.CORS_ORIGIN.split(',').map(o=>o.trim())}));app.use(express.json({limit:'32kb'}));
 const limiter=(max:number,windowMs:number)=>rateLimit({windowMs,max,standardHeaders:'draft-7',legacyHeaders:false,message:{status:'error',code:'RATE_LIMITED',message:'Too many requests'}});
 app.use('/v1',limiter(300,60000));app.use('/v1/auth',limiter(20,15*60000));
 app.use('/v1',(req,res,next)=>{res.setHeader('Cache-Control','no-store');next();});
 app.get('/health',async(_req,res)=>{let database=false;try{await s.db.ping();database=true;}catch{}const mqtt=s.mqtt.connected;ok(res,{healthy:database&&mqtt,database,mqtt},database&&mqtt?200:503);});
 app.use('/firmware',express.static(resolve(s.config.FIRMWARE_DIR),{index:false,dotfiles:'deny',immutable:true,maxAge:'1y',setHeaders:res=>res.setHeader('Content-Type','application/octet-stream')}));
 const internal=(req:Request,res:Response,next:NextFunction)=>{const h=req.header('x-internal-secret')??'';if(!equal(h,s.config.INTERNAL_SECRET)){res.status(403).json({result:'deny'});return;}next();};
 app.post('/internal/mqtt/auth',internal,async(req,res)=>{
  const parsed=z.object({username:z.string().max(128),password:z.string().max(256),clientid:z.string().max(128)}).safeParse(req.body);if(!parsed.success){res.json({result:'deny'});return;}const b=parsed.data;
  if(b.username===s.config.MQTT_USERNAME){res.json({result:equal(b.password,s.config.MQTT_PASSWORD)&&b.clientid===s.config.MQTT_USERNAME?'allow':'deny',is_superuser:false});return;}
  const d=b.clientid===b.username?await s.deviceAuth(b.username,b.password):null;res.json({result:d?'allow':'deny',is_superuser:false});
 });
 app.post('/internal/mqtt/acl',internal,async(req,res)=>{
  const p=z.object({username:z.string().max(128),topic:z.string().max(256),action:z.enum(['publish','subscribe'])}).safeParse(req.body);if(!p.success){res.json({result:'deny'});return;}const b=p.data;
  if(b.username===s.config.MQTT_USERNAME){const allowed=b.action==='publish'?/^devices\/[A-Z0-9-]{3,64}\/command$/.test(b.topic):/^devices\/\+\/(state|telemetry|availability|response)$/.test(b.topic);res.json({result:allowed?'allow':'deny'});return;}
  const [d]=await s.db.query('SELECT id FROM devices WHERE sn=? AND disabled=FALSE',[b.username]);res.json({result:d&&deviceACL(b.username,b.topic,b.action)?'allow':'deny'});
 });
 app.post('/v1/auth/register',async(req,res)=>ok(res,await s.register(req.body),201));
 app.post('/v1/auth/login',async(req,res)=>ok(res,await s.login(req.body)));
 app.post('/v1/auth/refresh',async(req,res)=>ok(res,await s.refresh(refreshBody.parse(req.body).refresh_token)));
 app.post('/v1/auth/logout',async(req,res)=>ok(res,await s.logout(refreshBody.parse(req.body).refresh_token)));
 app.get('/v1/device/firmware/latest',async(req,res)=>{const auth=req.header('authorization')??'';must(auth.startsWith('Basic '),401,'AUTH_INVALID');const decoded=Buffer.from(auth.slice(6),'base64').toString();const split=decoded.indexOf(':');must(split>0,401,'AUTH_INVALID');const d=await s.deviceAuth(decoded.slice(0,split),decoded.slice(split+1));must(d,401,'AUTH_INVALID');const [f]=await s.db.query('SELECT * FROM firmwares WHERE model=? AND hardware_version=? AND is_active=TRUE ORDER BY created_at DESC LIMIT 1',[d.model,d.hardware_version]);ok(res,f??null);});
 app.use('/v1',async(req,_res,next)=>{const h=req.header('authorization')??'';must(h.startsWith('Bearer '),401,'AUTH_INVALID');req.user=await s.authenticate(h.slice(7));next();});
 app.get('/v1/auth/me',(req,res)=>ok(res,publicUser(req.user!)));
 app.get('/v1/devices',async(req,res)=>ok(res,await s.list(req.user!)));
 app.post('/v1/devices/claim',limiter(10,15*60000),async(req,res)=>{const b=z.object({sn:z.string().regex(/^[A-Z0-9-]{3,64}$/),claim_code:z.string().min(8).max(128)}).strict().parse(req.body);ok(res,await s.claim(b.sn,b.claim_code,req.user!));});
 app.get('/v1/devices/:sn',async(req,res)=>ok(res,publicDevice(await s.owned(sn(req),req.user!))));
 app.get('/v1/devices/:sn/status',async(req,res)=>{const d=publicDevice(await s.owned(sn(req),req.user!));ok(res,{sn:d.sn,online:d.online,last_seen:d.last_seen,...d.state});});
 app.get('/v1/devices/:sn/local-token',async(req,res)=>ok(res,await s.local(sn(req),req.user!)));
 app.patch('/v1/devices/:sn',async(req,res)=>{const b=z.object({name:z.string().trim().min(1).max(100)}).strict().parse(req.body);const d=await s.owned(sn(req),req.user!);const result=await s.db.execute('UPDATE devices SET name=? WHERE id=? AND owner_user_id=? AND disabled=FALSE',[b.name,d.id,req.user!.id]);must(result.affectedRows===1,403,'DEVICE_NOT_OWNED');ok(res,publicDevice({...d,name:b.name}));});
 app.delete('/v1/devices/:sn',limiter(10,15*60000),async(req,res)=>{const b=z.object({password:z.string().min(1).max(72)}).strict().parse(req.body);ok(res,await s.unclaim(sn(req),b.password,req.user!));});
 app.post('/v1/devices/:sn/commands',limiter(120,60000),async(req,res)=>ok(res,await s.command(sn(req),req.body,req.user!),202));
 app.get('/v1/devices/:sn/commands/:request_id',async(req,res)=>{const d=await s.owned(sn(req),req.user!);const id=z.string().uuid().parse(req.params.request_id);const [c]=await s.db.query('SELECT request_id,status,error,created_at,sent_at,ack_at FROM device_commands WHERE device_id=? AND request_id=? AND user_id=?',[d.id,id,req.user!.id]);must(c,404,'COMMAND_NOT_FOUND');ok(res,{...c,device:d.sn,command_status:c.status});});
 app.use('/v1/admin',(req,_res,next)=>{must(req.user?.role==='admin',403,'ADMIN_REQUIRED');next();});
 app.get('/v1/admin/summary',async(_req,res)=>{const [[d],[u],[c],firmware_distribution]=await Promise.all([s.db.query('SELECT COUNT(*) AS total_devices, COALESCE(SUM(online=TRUE AND disabled=FALSE),0) AS online_devices FROM devices'),s.db.query('SELECT COUNT(*) AS total_users FROM users'),s.db.query("SELECT COUNT(*) AS total_commands,COALESCE(SUM(status='success'),0) AS successful_commands,COALESCE(SUM(status='timeout'),0) AS timeout_commands,AVG(TIMESTAMPDIFF(MICROSECOND,created_at,ack_at)/1000) AS command_latency_ms FROM device_commands"),s.db.query('SELECT firmware_version,COUNT(*) AS count FROM devices GROUP BY firmware_version')]);ok(res,{...d,offline_devices:Number(d!.total_devices)-Number(d!.online_devices),...u,...c,command_success_rate:Number(c!.total_commands)?Number(c!.successful_commands)/Number(c!.total_commands):0,mqtt_connected:s.mqtt.connected,mqtt_connections:Number(d!.online_devices),firmware_distribution});});
 app.get('/v1/admin/users',async(_req,res)=>ok(res,await s.db.query('SELECT u.id,u.email,u.name,u.role,u.status,u.created_at,COUNT(d.id) AS claimed_devices FROM users u LEFT JOIN devices d ON d.owner_user_id=u.id GROUP BY u.id,u.email,u.name,u.role,u.status,u.created_at ORDER BY u.created_at DESC LIMIT 1000')));
 app.post('/v1/admin/users',async(req,res)=>{const b=z.object({email:z.string().email().max(254),name:z.string().trim().min(1).max(100),password:z.string().min(12).max(72)}).strict().parse(req.body);ok(res,await s.register(b),201);});
 app.patch('/v1/admin/users/:id',async(req,res)=>{const id=z.string().uuid().parse(req.params.id);const b=z.object({status:z.enum(['active','disabled'])}).strict().parse(req.body);must(id!==req.user!.id,400,'CANNOT_DISABLE_SELF');const result=await s.db.execute('UPDATE users SET status=? WHERE id=?',[b.status,id]);must(result.affectedRows===1,404,'USER_NOT_FOUND');if(b.status==='disabled')await s.db.execute('UPDATE refresh_tokens SET revoked_at=COALESCE(revoked_at,NOW(3)) WHERE user_id=?',[id]);await s.audit('user.status',null,req.user!.id,{target_user_id:id,status:b.status});ok(res,{id,...b});});
 app.delete('/v1/admin/users/:id',async(req,res)=>ok(res,await s.deleteUser(z.string().uuid().parse(req.params.id),req.user!)));
 app.get('/v1/admin/devices',async(_req,res)=>ok(res,(await s.db.query('SELECT d.*,s.state FROM devices d LEFT JOIN device_states s ON s.device_id=d.id ORDER BY d.created_at DESC LIMIT 1000')).map(d=>({...publicDevice(d),owner_user_id:d.owner_user_id}))));
 app.post('/v1/admin/devices',async(req,res)=>ok(res,await s.createDevice(req.body,req.user!),201));
 app.post('/v1/admin/devices/:sn/claim-code',async(req,res)=>ok(res,await s.rotateClaimCode(sn(req),req.user!),201));
 app.patch('/v1/admin/devices/:sn',async(req,res)=>{const b=z.object({name:z.string().trim().min(1).max(100).optional(),disabled:z.boolean().optional()}).strict().refine(v=>v.name!==undefined||v.disabled!==undefined,'At least one field is required').parse(req.body);const d=await s.getDevice(sn(req));await s.db.transaction(async tx=>{if(b.name!==undefined)await tx.execute('UPDATE devices SET name=? WHERE id=?',[b.name,d.id]);if(b.disabled!==undefined){await tx.execute('UPDATE devices SET disabled=?,online=IF(?,FALSE,online) WHERE id=?',[b.disabled,b.disabled,d.id]);if(b.disabled)await tx.execute("UPDATE device_commands SET status='failed',error='DEVICE_DISABLED' WHERE device_id=? AND status IN ('pending','sent')",[d.id]);}});await s.audit('device.updated',d.id,req.user!.id,b);ok(res,publicDevice({...d,...b}));});
 app.delete('/v1/admin/devices/:sn',async(req,res)=>ok(res,await s.deleteDevice(sn(req),req.user!)));
 app.get('/v1/admin/commands',async(_req,res)=>ok(res,await s.db.query('SELECT c.request_id,c.command,c.status AS command_status,c.error,c.created_at,c.sent_at,c.ack_at,d.sn,c.user_id FROM device_commands c JOIN devices d ON d.id=c.device_id ORDER BY c.created_at DESC LIMIT 500')));
 app.get('/v1/admin/logs',async(_req,res)=>ok(res,await s.db.query('SELECT l.*,d.sn FROM device_logs l LEFT JOIN devices d ON d.id=l.device_id ORDER BY l.id DESC LIMIT 500')));
 app.get('/v1/admin/firmwares',async(_req,res)=>ok(res,await s.db.query('SELECT * FROM firmwares ORDER BY created_at DESC LIMIT 500')));
 app.post('/v1/admin/firmwares',async(req,res)=>ok(res,await s.createFirmware(req.body,req.user!),201));
 const upload=multer({storage:multer.memoryStorage(),limits:{fileSize:16*1024*1024,files:1,fields:4}});
 app.post('/v1/admin/firmwares/upload',upload.single('file'),async(req,res)=>{
  must(req.file&&req.file.size>0&&req.file.buffer[0]===0xe9,400,'INVALID_FIRMWARE_BINARY');const b=z.object({model:z.string().min(1).max(64),hardware_version:z.string().min(1).max(32),version:z.string().regex(/^\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?$/).max(32),release_notes:z.string().max(10000).default('')}).strict().parse(req.body);
  const checksum=sha256(req.file.buffer);const filename=`${checksum}.bin`;await mkdir(resolve(s.config.FIRMWARE_DIR),{recursive:true});await writeFile(resolve(s.config.FIRMWARE_DIR,filename),req.file.buffer,{flag:'wx'}).catch((e:NodeJS.ErrnoException)=>{if(e.code!=='EEXIST')throw e;});
  ok(res,await s.createFirmware({...b,url:`${s.config.FIRMWARE_PUBLIC_URL.replace(/\/$/,'')}/${filename}`,checksum,file_size:req.file.size},req.user!),201);
 });
 app.post('/v1/admin/devices/:sn/ota',async(req,res)=>{const b=z.object({firmware_id:z.string().uuid()}).strict().parse(req.body);ok(res,await s.command(sn(req),{command:'firmware.update',...b},req.user!,true),202);});
 app.use((_req,res)=>res.status(404).json({status:'error',code:'NOT_FOUND',message:'Route not found'}));
 app.use((err:any,_req:Request,res:Response,_next:NextFunction)=>{if(err instanceof ZodError){res.status(400).json({status:'error',code:'VALIDATION_ERROR',message:err.issues.map(i=>`${i.path.join('.')}: ${i.message}`).join('; ')});return;}if(err instanceof ApiError){res.status(err.status).json({status:'error',code:err.code,message:err.message});return;}const code=err.code==='ER_DUP_ENTRY'?'ALREADY_EXISTS':err instanceof multer.MulterError?'INVALID_UPLOAD':err.type==='entity.parse.failed'?'INVALID_JSON':err.type==='entity.too.large'?'PAYLOAD_TOO_LARGE':'INTERNAL_ERROR';res.status(code==='ALREADY_EXISTS'?409:code==='INTERNAL_ERROR'?500:400).json({status:'error',code,message:code});});
 return app;
}
