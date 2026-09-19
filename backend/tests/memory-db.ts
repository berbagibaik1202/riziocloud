// Deliberately small SQL adapter for service tests. This is NOT a MySQL emulator or integration test.
import type { DB } from '../src/db.js';
export class MemoryDB implements DB {
 users:any[]=[];devices:any[]=[];refresh:any[]=[];commands:any[]=[];firmwares:any[]=[];logs:any[]=[];states:any[]=[];
 private queue:Promise<unknown>=Promise.resolve();
 async transaction<T>(fn:(tx:DB)=>Promise<T>):Promise<T>{const run=this.queue.then(()=>fn({...this,query:this.query.bind(this),execute:this.execute.bind(this),ping:this.ping.bind(this),transaction:async f=>f(this)}));this.queue=run.catch(()=>{});return run;}
 async ping(){}
 async query<T=Record<string,any>>(sql:string,v:any[]=[]):Promise<T[]>{
  let rows:any[]=[];
  if(sql==='SELECT 1')rows=[{'1':1}];
  else if(sql.includes('FROM users')){rows=this.users.filter(u=>sql.includes('WHERE email=')?u.email===v[0]:sql.includes('WHERE id=')?u.id===v[0]:true);if(sql.includes("status='active'"))rows=rows.filter(u=>u.status==='active');}
  else if(sql.includes('FROM refresh_tokens'))rows=this.refresh.filter(r=>r.token_hash===v[0]);
  else if(sql.includes('FROM devices')){rows=this.devices.filter(d=>sql.includes('owner_user_id=?')?d.owner_user_id===v[0]:sql.includes('sn=?')||sql.includes('d.sn=?')?d.sn===v[0]:true);if(sql.includes('disabled=FALSE'))rows=rows.filter(d=>!d.disabled);rows=rows.map(d=>({...d,state:this.states.find(s=>s.device_id===d.id)?.state}));}
  else if(sql.includes('FROM device_commands'))rows=this.commands.filter(c=>sql.includes('WHERE device_id=?')?c.device_id===v[0]&&c.request_id===v[1]&&c.user_id===v[2]:c.request_id===v[0]);
  else if(sql.includes('FROM firmwares'))rows=this.firmwares.filter(f=>f.id===v[0]&&f.is_active);
  else if(sql.includes('FROM device_states'))rows=this.states.filter(s=>s.device_id===v[0]);
  else throw Error(`Unsupported test SQL: ${sql}`);
  return structuredClone(rows) as T[];
 }
 async execute(sql:string,v:any[]=[]):Promise<{affectedRows:number}>{
  let n=1;
  if(sql.startsWith('INSERT INTO users')){if(this.users.some(u=>u.email===v[1]))throw Object.assign(Error('duplicate'),{code:'ER_DUP_ENTRY'});this.users.push({id:v[0],email:v[1],password_hash:v[2],name:v[3],role:'user',status:'active'});}
  else if(sql.startsWith('INSERT INTO refresh_tokens'))this.refresh.push({token_hash:v[0],user_id:v[1],family_id:v[2],expires_at:v[3],revoked_at:null});
  else if(sql.startsWith('UPDATE refresh_tokens')){const family=sql.includes('WHERE family_id IN')?this.refresh.find(r=>r.token_hash===v[0])?.family_id:undefined;const match=family?this.refresh.filter(r=>r.family_id===family):sql.includes('WHERE token_hash=')?this.refresh.filter(r=>r.token_hash===v[0]):this.refresh.filter(r=>r.family_id===v[0]);for(const r of match)r.revoked_at=new Date();n=match.length;}
  else if(sql.startsWith('INSERT INTO device_commands'))this.commands.push({request_id:v[0],device_id:v[1],user_id:v[2],command:v[3],payload:v[4],expires_at:v[5],status:'pending'});
  else if(sql.startsWith('UPDATE device_commands')){
   let rows:any[]=[];
   if(sql.includes("status='timeout'")){rows=this.commands.filter(c=>['pending','sent'].includes(c.status)&&c.expires_at<=new Date());for(const c of rows){c.status='timeout';c.error='COMMAND_TIMEOUT';}}
   else if(sql.includes('ack_at=NOW')){rows=this.commands.filter(c=>c.request_id===v[2]&&c.device_id===v[3]&&['pending','sent'].includes(c.status)&&c.expires_at>new Date());for(const c of rows){c.status=v[0];c.error=v[1];c.ack_at=new Date();}}
   else if(sql.includes("status='sent'")){rows=this.commands.filter(c=>c.request_id===v[0]&&c.status==='pending');for(const c of rows)c.status='sent';}
   else if(sql.includes("error='MQTT_ERROR'")){rows=this.commands.filter(c=>c.request_id===v[0]&&c.status==='pending');for(const c of rows){c.status='failed';c.error='MQTT_ERROR';}}
   else if(sql.includes("error='DEVICE_UNCLAIMED'")){rows=this.commands.filter(c=>c.device_id===v[0]&&['pending','sent'].includes(c.status));for(const c of rows)c.status='failed';}
   else throw Error(`Unsupported test SQL: ${sql}`);n=rows.length;
  }
  else if(sql.startsWith('UPDATE devices SET owner_user_id=?')){const d=this.devices.find(d=>d.id===v[1]&&!d.owner_user_id&&d.claim_code_hash===v[2]);if(d){d.owner_user_id=v[0];d.claim_code_hash=null;}else n=0;}
  else if(sql.startsWith('UPDATE devices SET owner_user_id=NULL')){const d=this.devices.find(d=>d.id===v[1]);d.owner_user_id=null;d.claim_code_hash=v[0];}
  else if(sql.startsWith('UPDATE devices SET online=FALSE')){for(const d of this.devices)if(d.last_seen&&new Date(d.last_seen).getTime()<Date.now()-180000)d.online=false;}
  else if(sql.startsWith('UPDATE devices SET online=')){const d=this.devices.find(d=>d.id===v.at(-1));if(d){d.online=v.length===2?v[0]:true;d.last_seen=new Date();}}
  else if(sql.startsWith('UPDATE devices SET firmware_version=')){const d=this.devices.find(d=>d.id===v[1]);d.firmware_version=v[0];}
  else if(sql.startsWith('INSERT INTO device_states')){const old=this.states.find(s=>s.device_id===v[0]);if(old)old.state=v[1];else this.states.push({device_id:v[0],state:v[1]});}
  else if(sql.startsWith('INSERT INTO device_logs'))this.logs.push(v);
  else throw Error(`Unsupported test SQL: ${sql}`);
  return {affectedRows:n};
 }
}
