const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');
const tests = [
    ['private-key material', /-----BEGIN (?:[A-Z0-9]+ )?PRIVATE KEY-----/],
    ['embedded public identity', /ssh-(?:rsa|ed25519)\s+[A-Za-z0-9+/]{40,}={0,3}/],
    ['assumed identity filename', /id_(?:rsa|ed25519)(?:\.pub)?/],
    ['personal desktop path', /C:[\\/]Users[\\/]/i],
];
let files = 0;
let failed = false;
function scan(dir) {
    for (const entry of fs.readdirSync(dir, {withFileTypes: true})) {
        if (['.git', 'node_modules'].includes(entry.name)) continue;
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) scan(full);
        else if (/\.(sh|cjs|js|ps1|py)$/.test(entry.name)) {
            files++;
            const text = fs.readFileSync(full, 'utf8');
            for (const [kind, pattern] of tests) {
                if (pattern.test(text)) {
                    console.error(`${path.relative(root, full)}: ${kind}`);
                    failed = true;
                }
            }
        }
    }
}
scan(path.join(root, 'scripts'));
console.log(`Identity-free script audit: ${files} files, ${failed ? 'FAIL' : 'PASS'}`);
process.exitCode = failed ? 1 : 0;
