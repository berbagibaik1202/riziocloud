import { randomUUID } from 'node:crypto';
import bcrypt from 'bcryptjs';
import { z } from 'zod';
import { readConfig } from './config.js';
import { connectDB } from './db.js';
const {db,pool}=connectDB(readConfig());
try{const email=z.string().email().parse(process.env.ADMIN_EMAIL).toLowerCase();const password=z.string().min(12).max(72).parse(process.env.ADMIN_PASSWORD);await db.execute("INSERT INTO users(id,email,password_hash,name,role) VALUES (?,?,?,'Administrator','admin')",[randomUUID(),email,await bcrypt.hash(password,12)]);console.log('Administrator created.');}finally{await pool.end();}
