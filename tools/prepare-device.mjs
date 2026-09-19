import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import path from 'node:path';

// Input is the protected response saved by a production operator from POST /v1/admin/devices.
const [responsePath, brokerHost, outputDirectory] = process.argv.slice(2);
if (!responsePath || !brokerHost || !outputDirectory) {
  console.error('Usage: node tools/prepare-device.mjs <inventory-response.json> <mqtt-hostname> <new-output-directory>');
  process.exit(1);
}
if (!/^[a-zA-Z0-9.-]+$/.test(brokerHost) || brokerHost.length > 253) throw new Error('Invalid MQTT hostname.');
const response = JSON.parse(readFileSync(responsePath, 'utf8'));
const { device, production_credentials: credentials } = response.data ?? response;
if (!device || !credentials || !/^[A-Z0-9-]{3,64}$/.test(device.sn) || device.sn !== credentials.sn) {
  throw new Error('Invalid production response or serial mismatch.');
}
for (const key of ['device_key', 'claim_code', 'setup_code']) {
  const minimum = key === 'device_key' ? 32 : 12;
  if (typeof credentials[key] !== 'string' || credentials[key].length < minimum) throw new Error(`Invalid ${key}.`);
}
if (credentials.setup_code.length > 63) throw new Error('Setup/AP password exceeds WPA2 limit.');
if (!Array.isArray(device.channels) || typeof device.model !== 'string' || typeof device.hardware_version !== 'string') {
  throw new Error('Missing device model, hardware version or channels.');
}
const target = path.resolve(outputDirectory);
if (existsSync(target)) throw new Error('Output directory already exists; refusing to overwrite device identity.');
mkdirSync(target, { recursive: true, mode: 0o700 });
const write = (name, value) => writeFileSync(path.join(target, name), value, { flag: 'wx', mode: 0o600 });
write('identity.json', JSON.stringify({
  sn: device.sn, device_key: credentials.device_key, setup_code: credentials.setup_code,
  model: device.model, hardware_version: device.hardware_version,
  mqtt_host: brokerHost, mqtt_port: 8883, reset_pin: 0, channels: device.channels,
}, null, 2) + '\n');
write('claim-qr.txt', `ESPCTRL://claim?sn=${encodeURIComponent(device.sn)}&code=${encodeURIComponent(credentials.claim_code)}\n`);
write('setup-label.txt', `SN: ${device.sn}\nSSID: ESPCTRL-${device.sn.slice(-8)}\nSetup/AP password: ${credentials.setup_code}\n`);
write('README.txt', 'Production identity contains secrets. Keep this directory private.\nCopy identity.json and the broker CA as ca.pem into firmware/data before uploadfs.\nDo not print DEVICE_KEY on a label. claim-qr.txt is QR content, not an image.\nVerify board pin mapping and reset_pin before flashing.\n');
console.log('Device files created. Secret contents are not printed.');
