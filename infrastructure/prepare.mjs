import { randomBytes } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.dirname(fileURLToPath(import.meta.url));
const envPath = path.join(root, '.env');
if (!existsSync(envPath)) {
  const secret = () => randomBytes(32).toString('hex');
  const env = {
    DB_NAME: 'rizio', DB_USER: 'rizio', DB_PASSWORD: secret(), DB_ROOT_PASSWORD: secret(),
    JWT_SECRET: secret(), CREDENTIAL_ENCRYPTION_KEY: secret(), INTERNAL_SECRET: secret(),
    MQTT_USERNAME: 'rizio-backend', MQTT_PASSWORD: secret(), EMQX_DASHBOARD_PASSWORD: secret(),
    PUBLIC_API_URL: 'https://localhost/v1', FIRMWARE_BASE_URL: 'https://localhost/firmware',
  };
  writeFileSync(envPath, Object.entries(env).map(([k, v]) => `${k}=${v}`).join('\n') + '\n', { mode: 0o600 });
  console.log('Created infrastructure/.env with random secrets.');
}
const env = Object.fromEntries(readFileSync(envPath, 'utf8').split(/\r?\n/)
  .filter(line => line && !line.startsWith('#')).map(line => {
    const separator = line.indexOf('=');
    return [line.slice(0, separator), line.slice(separator + 1)];
  }));
if (!/^[a-zA-Z0-9_-]{32,}$/.test(env.INTERNAL_SECRET ?? '')) {
  throw new Error('INTERNAL_SECRET must contain at least 32 letters/digits/underscore/hyphen.');
}
const template = readFileSync(path.join(root, 'emqx/emqx.conf.template'), 'utf8');
const config = template.replaceAll('__INTERNAL_SECRET__', env.INTERNAL_SECRET)
  .replaceAll('__NODE_COOKIE__', randomBytes(32).toString('hex'));
writeFileSync(path.join(root, 'emqx/generated.conf'), config, { mode: 0o600 });
console.log('Generated EMQX configuration. Secret values are not printed.');
