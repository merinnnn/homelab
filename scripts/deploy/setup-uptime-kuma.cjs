// Uptime Kuma 2.5.8 Socket.IO initialization. Read credentials as JSON on stdin.
// Run inside the pinned container, whose /app node_modules supplies the client.
const fs = require('node:fs');

function monitorDefinitions(dnsHost) {
    const common = {
        parent: null, method: 'GET', interval: 60, retryInterval: 60,
        resendInterval: 0, maxretries: 2, timeout: 20, notificationIDList: {},
        upsideDown: false, expiryNotification: false, domainExpiryNotification: false,
        maxredirects: 10, accepted_statuscodes: ['200-299'], conditions: [],
        kafkaProducerBrokers: [], kafkaProducerSaslOptions: {mechanism: 'None'}, rabbitmqNodes: [],
    };
    const list = ['192.168.1.2', '192.168.1.3'].map((host, i) => ({
        ...common, name: `pve0${i + 1} HTTPS`, type: 'http',
        url: `https://${host}:8006/`, ignoreTls: true,
    }));
    if (dnsHost !== undefined) {
        if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(dnsHost) || dnsHost.split('.').some(x => Number(x) > 255)) {
            throw new Error('Invalid DNS target');
        }
        list.push({...common, name: 'Pi-hole DNS', type: 'dns', hostname: 'example.com',
            dns_resolve_server: dnsHost, dns_resolve_type: 'A', port: 53, ignoreTls: false});
    }
    return list;
}

async function initialize(io, input) {
    if (typeof input.username !== 'string' || !input.username || typeof input.password !== 'string' || input.password.length < 12) {
        throw new Error('Supply username and a strong password via stdin JSON');
    }
    const desired = monitorDefinitions(input.dnsHost);
    const socket = io('http://127.0.0.1:3001', {transports: ['websocket'], reconnection: false, autoConnect: false, timeout: 15000});
    const request = (name, ...args) => new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error(`Timed out: ${name}`)), 15000);
        socket.emit(name, ...args, response => {clearTimeout(timer); resolve(response);});
    });
    const requireOK = (name, response) => {if (!response || response.ok !== true) throw new Error(`Request failed: ${name}`); return response;};
    let monitorList;
    let update;
    socket.on('monitorList', data => {monitorList = data; if (update) update();});
    try {
        await new Promise((resolve, reject) => {
            const timer = setTimeout(() => reject(new Error('Connection timed out')), 15000);
            socket.once('connect', () => {clearTimeout(timer); resolve();});
            socket.once('connect_error', () => {clearTimeout(timer); reject(new Error('Connection failed'));});
            socket.connect();
        });
        const needsSetup = await request('needSetup');
        if (typeof needsSetup !== 'boolean') throw new Error('Unexpected setup protocol');
        if (needsSetup) requireOK('setup', await request('setup', input.username, input.password));
        requireOK('login', await request('login', {username: input.username, password: input.password}));
        // The list is sent as an event, not the getMonitorList acknowledgement.
        monitorList = undefined;
        requireOK('getMonitorList', await request('getMonitorList'));
        if (monitorList === undefined) await new Promise((resolve, reject) => {
            const timer = setTimeout(() => reject(new Error('Monitor list timed out')), 15000);
            update = () => {clearTimeout(timer); resolve();};
            if (monitorList !== undefined) update();
        });
        let added = 0;
        for (const monitor of desired) {
            const existing = Object.values(monitorList).find(item => item.name === monitor.name);
            if (existing) {
                const targetMatches = monitor.type === 'http'
                    ? existing.url === monitor.url && Boolean(existing.ignoreTls) === monitor.ignoreTls && JSON.stringify(existing.accepted_statuscodes) === JSON.stringify(monitor.accepted_statuscodes)
                    : existing.dns_resolve_server === monitor.dns_resolve_server && existing.hostname === monitor.hostname && existing.dns_resolve_type === monitor.dns_resolve_type && Number(existing.port) === monitor.port;
                if (existing.type !== monitor.type || existing.active === false || existing.active === 0 || !targetMatches) {
                    throw new Error('Existing monitor target or required policy differs; review before changing it');
                }
                continue;
            }
            requireOK('add', await request('add', monitor));
            added++;
        }
        return {account: needsSetup ? 'created' : 'verified', monitorsAdded: added, monitorsExpected: desired.length};
    } finally {
        socket.disconnect();
    }
}

module.exports = {initialize, monitorDefinitions};
if (require.main === module) {
    (async () => {
        const input = JSON.parse(fs.readFileSync(0, 'utf8'));
        const {io} = require(require.resolve('socket.io-client', {paths: ['/app', process.cwd()]}));
        console.log(JSON.stringify(await initialize(io, input)));
    })().catch(() => {console.error('Kuma setup failed; check local service state and supplied input without logging credentials'); process.exitCode = 1;});
}
