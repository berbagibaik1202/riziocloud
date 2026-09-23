import mysql, { type Pool, type PoolConnection } from 'mysql2/promise';
import type { Config } from './config.js';
export interface DB {
 query<T = Record<string, any>>(sql:string, values?:any[]):Promise<T[]>;
 execute(sql:string, values?:any[]):Promise<{affectedRows:number}>;
 transaction<T>(fn:(tx:DB)=>Promise<T>):Promise<T>;
 ping():Promise<void>;
}
export class MysqlDB implements DB {
 constructor(private conn:Pool|PoolConnection, private pool?:Pool) {}
 async query<T>(sql:string, values:any[]=[]):Promise<T[]> { const [rows]=await this.conn.query(sql,values); return rows as T[]; }
 async execute(sql:string, values:any[]=[]){ const [r]=await this.conn.execute(sql,values); return r as {affectedRows:number}; }
 async transaction<T>(fn:(tx:DB)=>Promise<T>):Promise<T>{
  if(!this.pool) return fn(this);
  const c=await this.pool.getConnection();
  try {await c.beginTransaction();const result=await fn(new MysqlDB(c));await c.commit();return result;}
  catch(e){await c.rollback();throw e;} finally{c.release();}
 }
 async ping(){await this.query('SELECT 1');}
}
export function connectDB(c:Config){const pool=mysql.createPool({host:c.DB_HOST,port:c.DB_PORT,user:c.DB_USER,password:c.DB_PASSWORD,database:c.DB_NAME,connectionLimit:10,timezone:'Z',charset:'utf8mb4'});return {db:new MysqlDB(pool,pool),pool};}
export function json<T=any>(value:any):T {
 if(value===null||value===undefined)return value as T;
 if(Buffer.isBuffer(value))return JSON.parse(value.toString('utf8')) as T;
 return typeof value==='string'?JSON.parse(value):value;
}
