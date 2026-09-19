import 'dotenv/config';
import { z } from 'zod';

const schema = z.object({
 PORT:z.coerce.number().int().min(1).max(65535).default(3000), NODE_ENV:z.enum(['development','test','production']).default('development'),
 DB_HOST:z.string().default('127.0.0.1'), DB_PORT:z.coerce.number().default(3306), DB_USER:z.string().min(1), DB_PASSWORD:z.string().min(1), DB_NAME:z.string().default('rizio'),
 JWT_SECRET:z.string().min(32), CREDENTIAL_ENCRYPTION_KEY:z.string().regex(/^[a-fA-F0-9]{64}$/), INTERNAL_SECRET:z.string().min(32),
 MQTT_URL:z.string().url().refine(v=>v.startsWith('mqtts://'),'MQTT TLS is required'), MQTT_TLS_SERVERNAME:z.string().min(1).optional(), MQTT_USERNAME:z.string().min(1), MQTT_PASSWORD:z.string().min(16), MQTT_CA_PATH:z.string().optional(),
 CORS_ORIGIN:z.string().default('http://localhost:5173'), TRUST_PROXY:z.coerce.number().int().min(0).max(3).default(0),
 FIRMWARE_DIR:z.string().default('./storage/firmware'), FIRMWARE_PUBLIC_URL:z.string().url().refine(v=>v.startsWith('https://')).default('https://firmware.example.com'),
 COMMAND_TIMEOUT_SECONDS:z.coerce.number().int().min(5).max(120).default(15),
 OTA_TIMEOUT_SECONDS:z.coerce.number().int().min(60).max(1800).default(300)
});
export type Config = z.infer<typeof schema>;
export function readConfig(): Config { return schema.parse(process.env); }
