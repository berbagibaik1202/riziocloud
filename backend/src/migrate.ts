import { readFile, readdir } from 'node:fs/promises';
import { readConfig } from './config.js';
import { connectDB } from './db.js';
const {db,pool}=connectDB(readConfig());
try {
 await db.execute('CREATE TABLE IF NOT EXISTS schema_migrations (name VARCHAR(128) PRIMARY KEY, applied_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP)');
 for(const name of (await readdir('migrations')).filter(n=>n.endsWith('.sql')).sort()){
  if((await db.query('SELECT name FROM schema_migrations WHERE name=?',[name])).length)continue;
  // DDL implicitly commits in MySQL; migrations must be restart-safe.
  for(const statement of (await readFile(`migrations/${name}`,'utf8')).split(';').map(s=>s.trim()).filter(Boolean))await db.execute(statement);
  await db.execute('INSERT INTO schema_migrations(name) VALUES (?)',[name]);console.log(`Applied ${name}`);
 }
}finally{await pool.end();}
