import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

test('production export keeps device key out of QR and refuses identity overwrite', () => {
  const root = mkdtempSync(path.join(os.tmpdir(), 'rizio-device-test-'));
  try {
    const input = path.join(root, 'input.json');
    const output = path.join(root, 'device');
    const device = { sn: 'ESP-TEST1234', model: 'ESP-RELAY-2CH', hardware_version: '1.0', channels: [] };
    const credentials = { sn: device.sn, device_key: 'a'.repeat(64), claim_code: 'b'.repeat(64), setup_code: 'c'.repeat(48) };
    writeFileSync(input, JSON.stringify({ status: 'success', data: { device, production_credentials: credentials } }));
    const script = fileURLToPath(new URL('./prepare-device.mjs', import.meta.url));
    const run = () => spawnSync(process.execPath, [script, input, 'mqtt.example.com', output], { encoding: 'utf8' });
    const result = run();
    assert.equal(result.status, 0, result.stderr);
    const identity = JSON.parse(readFileSync(path.join(output, 'identity.json'), 'utf8'));
    const qr = readFileSync(path.join(output, 'claim-qr.txt'), 'utf8');
    assert.equal(identity.device_key, credentials.device_key);
    assert.equal(identity.mqtt_host, 'mqtt.example.com');
    assert.equal(new URL(qr.trim()).searchParams.get('code'), credentials.claim_code);
    assert.equal(qr.includes(credentials.device_key), false);
    assert.equal(qr.includes(credentials.setup_code), false);
    assert.equal(result.stdout.includes(credentials.device_key), false);
    assert.match(readFileSync(path.join(output, 'setup-label.txt'), 'utf8'), /SSID: ESPCTRL-TEST1234/);
    assert.notEqual(run().status, 0);
    assert.equal(JSON.parse(readFileSync(path.join(output, 'identity.json'), 'utf8')).device_key, credentials.device_key);
  } finally {
    // Verify the absolute deletion target is the temporary directory we created.
    const temporaryRoot = path.resolve(os.tmpdir()) + path.sep;
    const target = path.resolve(root);
    assert.ok(target.startsWith(temporaryRoot) && path.basename(target).startsWith('rizio-device-test-'));
    rmSync(target, { recursive: true });
  }
});
