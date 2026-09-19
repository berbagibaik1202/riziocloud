import { readFileSync } from 'node:fs';
import mqtt, { type MqttClient } from 'mqtt';
import pino from 'pino';
import { readConfig } from './config.js';
import { connectDB } from './db.js';
import { Service, type Publisher } from './service.js';
import { createApp } from './app.js';
const config=readConfig();const logger=pino({level:'info'});const {db,pool}=connectDB(config);
let client:MqttClient|undefined;
const publisher:Publisher={get connected(){return client?.connected??false;},async publish(topic,payload){if(!client?.connected)throw Error('MQTT unavailable');await new Promise<void>((resolve,reject)=>{const timer=setTimeout(()=>reject(Error('MQTT publish timeout')),5000);client!.publish(topic,payload,{qos:1,retain:false},err=>{clearTimeout(timer);err?reject(err):resolve();});});}};
const service=new Service(db,config,publisher);
// HTTP must be listening before connecting MQTT: broker authenticates through this API.
const server=createApp(service).listen(config.PORT,()=>{
 logger.info({event:'api.started',port:config.PORT});
 client=mqtt.connect(config.MQTT_URL,{username:config.MQTT_USERNAME,password:config.MQTT_PASSWORD,clientId:config.MQTT_USERNAME,protocolVersion:4,clean:true,reconnectPeriod:2000,connectTimeout:10000,rejectUnauthorized:true,ca:config.MQTT_CA_PATH?readFileSync(config.MQTT_CA_PATH):undefined});
 client.on('connect',()=>{logger.info({event:'mqtt.connected'});client!.subscribe(['devices/+/state','devices/+/telemetry','devices/+/availability','devices/+/response'],{qos:1},err=>{if(err)logger.error({event:'mqtt.subscribe.failed'});});});
 client.on('error',()=>logger.error({event:'mqtt.error'}));client.on('offline',()=>logger.warn({event:'mqtt.offline'}));
 client.on('message',(topic,payload)=>{service.ingest(topic,payload).catch(()=>logger.error({event:'mqtt.ingest.failed',topic}));});
});
let sweeping=false;const timer=setInterval(async()=>{if(sweeping)return;sweeping=true;try{await service.expireCommands();}catch{logger.error({event:'commands.sweep.failed'});}finally{sweeping=false;}},1000);
let closing=false;async function shutdown(){if(closing)return;closing=true;clearInterval(timer);server.close();await client?.endAsync();await pool.end();logger.info({event:'api.stopped'});}
process.on('SIGINT',()=>void shutdown());process.on('SIGTERM',()=>void shutdown());
