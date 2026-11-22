import fs from 'node:fs';
const response = JSON.parse(fs.readFileSync(0, 'utf8'));
let output = response.Output;
if (typeof output !== 'string') throw new Error('Missing EC2 console output');
if (!output.includes('BEGIN SSH HOST KEY KEYS')) output = Buffer.from(output, 'base64').toString('utf8');
const block = output.match(/-----BEGIN SSH HOST KEY KEYS-----([\s\S]*?)-----END SSH HOST KEY KEYS-----/);
if (!block) throw new Error('No cloud-init SSH host public-key block in trusted console output');
const keys = [...block[1].matchAll(/(?:^|\s)(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(?:256|384|521)) ([A-Za-z0-9+/]+={0,2})(?:\s|$)/g)]
    .map(match => `${match[1]} ${match[2]}`);
if (!keys.length) throw new Error('No supported SSH host public keys');
process.stdout.write([...new Set(keys)].sort().join('\n') + '\n');
