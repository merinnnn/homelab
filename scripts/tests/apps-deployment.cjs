const fs=require('node:fs'),path=require('node:path'),os=require('node:os'),cp=require('node:child_process'),assert=require('node:assert/strict');
const repo=path.resolve(__dirname,'../..'),tmp=fs.mkdtempSync(path.join(os.tmpdir(),'homelab-apps-'));
const bash=process.env.BASH||(process.platform==='win32'?path.join(process.env.ProgramFiles||'C:/Program Files','Git/bin/bash.exe'):'/bin/bash');
const posix=p=>p.replaceAll('\\','/').replace(/^([A-Za-z]):/,(_,d)=>'/'+d.toLowerCase()),q=s=>"'"+s.replaceAll("'","'\\''")+"'";
const template=path.join(repo,'configs/docker/uptime-kuma/docker-compose.yml');
const digest='louislam/uptime-kuma@sha256:'+'a'.repeat(64),results=[];
process.on('exit',()=>{const resolved=fs.realpathSync(tmp),parent=fs.realpathSync(os.tmpdir());if(resolved.startsWith(parent+path.sep)&&path.basename(resolved).startsWith('homelab-apps-'))fs.rmSync(resolved,{recursive:true,force:true});});
fs.writeFileSync(path.join(tmp,'mocks.sh'),String.raw`
log() { printf '%s\n' "$*" >> "$TEST_LOG"; }
if [ "$CASE" = pve-host ]; then pveversion() { echo pve-manager/fixture; }; fi
id() { if [ "$CASE" = not-root ]; then echo 1000; else echo 0; fi; }
dpkg() { echo amd64; }
dpkg-query() { [ "$CASE" = conflict ] && [ "${'$'}{@: -1}" = docker.io ] && printf 'install ok installed'; }
cloud-init() {
 if [ "$CASE" = degraded-fatal ]; then echo '{"status":"done","errors":["fatal"]}'; return 2; fi
 echo '{"status":"done","errors":[]}'
 [ "$CASE" != degraded-ok ]
}
timeout() {
 log "timeout $*"; shift 2
 if [ "$1" = cloud-init ] && [ "$CASE" = cloud-timeout ]; then return 124; fi
 if [ "$1" = docker ] && [ "$CASE" = pull-timeout ]; then return 124; fi
 if [ "$1" = cloud-init ] && [ "$CASE" = degraded-ok ]; then echo '{"status":"done","errors":[]}'; return 2; fi
 "$@"
}
python3() { node -e 'const fs=require("fs"),x=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));process.exit(x.status==="done"&&!x.errors.length?0:1)' "$2"; }
apt-get() { log "apt-get $*"; [ "$CASE" != apt-failure ]; }
install() {
 log "install $*"
 [[ "$*" != *'/etc/'* ]] || return 0
 [[ "$*" != '-d '* ]] || return 0
 command cp "${'$'}{@: -2:1}" "${'$'}{@: -1}"
}
tee() { log "tee $*"; cat > "$TEST_DIR/docker.sources"; }
curl() {
 log "curl $*"; [ "$CASE" != key-failure ] || return 22
 local prev='' arg
 for arg in "$@"; do [ "$prev" != -o ] || printf fixture-key > "$arg"; prev="$arg"; done
}
systemctl() { log "systemctl $*"; [ "$CASE" != daemon-failure ]; }
docker() {
 log "docker $*"
 [ "$CASE" != docker-failure ] || return 1
 if [[ "$*" = 'image inspect '* ]]; then
   if [ "$CASE" = bad-digest ]; then echo unrelated/image@sha256:invalid; else printf 'louislam/uptime-kuma@sha256:%064d\n' 0 | tr 0 a; fi
 elif [[ "$*" = *' config --quiet' ]]; then [ "$CASE" != config-failure ] || return 1
 elif [[ "$*" = *' up -d '* ]]; then [ "$CASE" != up-failure ] || return 1
 fi
 return 0
}
`);
const installSource=fs.readFileSync(path.join(repo,'scripts/provision/install-docker-debian.sh'),'utf8');
const deploySource=path.join(repo,'scripts/deploy/uptime-kuma.sh');
function run(name,kind,scenario='happy',env={},check=r=>r.code===0,prior=false){
 const dir=path.join(tmp,String(results.length));fs.mkdirSync(dir);fs.mkdirSync(path.join(dir,'stack'));
 const release=path.join(dir,'os-release');fs.writeFileSync(release,scenario==='wrong-os'?'ID=ubuntu\nVERSION_ID=24\nVERSION_CODENAME=noble\n':'ID=debian\nVERSION_ID=13\nVERSION_CODENAME=trixie\n');
 const script=kind==='install'?path.join(dir,'install.sh'):deploySource;
 if(kind==='install')fs.writeFileSync(script,installSource.replace('/etc/os-release',posix(release)));
 const log=path.join(dir,'commands.log');fs.writeFileSync(log,'');
 if(prior)fs.writeFileSync(path.join(dir,'stack/.env'),`KUMA_IMAGE=${digest}\nKUMA_BIND_IP=192.168.1.123\nKUMA_PORT=3001\nTZ=Europe/London\n`);
 const command=`source ${q(posix(path.join(tmp,'mocks.sh')))}; source ${q(posix(script))} ${kind==='deploy'?q(posix(template)):''}`;
 const r=cp.spawnSync(bash,['-c',command],{encoding:'utf8',env:{...process.env,CASE:scenario,TEST_DIR:posix(dir),TEST_LOG:posix(log),STACK_DIR:posix(path.join(dir,'stack')),TZ:'Europe/London',...env}});
 const item={name,code:r.status,stdout:r.stdout,stderr:r.stderr,log:fs.readFileSync(log,'utf8'),sources:fs.existsSync(path.join(dir,'docker.sources'))?fs.readFileSync(path.join(dir,'docker.sources'),'utf8'):'',saved:fs.existsSync(path.join(dir,'stack/.env'))?fs.readFileSync(path.join(dir,'stack/.env'),'utf8'):''};
 item.pass=Boolean(check(item));results.push(item);
}
run('Docker rejects nonroot','install','not-root',{},r=>r.code!==0&&!r.log.includes('apt-get'));
run('Docker refuses Proxmox host','install','pve-host',{},r=>r.code!==0&&!r.log.includes('apt-get'));
run('Docker rejects unsupported OS','install','wrong-os',{},r=>r.code!==0&&!r.log.includes('apt-get'));
run('Docker cloud-init bounded timeout stops apt','install','cloud-timeout',{},r=>r.code===124&&!r.log.includes('apt-get'));
run('Docker fatal cloud-init stops apt','install','degraded-fatal',{},r=>r.code!==0&&!r.log.includes('apt-get'));
run('Docker completed nonfatal cloud-init allowed','install','degraded-ok');
run('Docker conflicting runtime is preserved','install','conflict',{},r=>r.code!==0&&!r.log.includes('apt-get'));
run('Docker apt errors propagate','install','apt-failure',{},r=>r.code!==0&&!r.log.includes('curl'));
run('Docker key download failure stops install','install','key-failure',{},r=>r.code===22&&!r.log.includes('install -y docker-ce'));
run('Docker daemon failure propagates','install','daemon-failure',{},r=>r.code!==0);
run('Docker signed official trixie repository and compose plugin','install','happy',{},r=>r.code===0&&r.sources.includes('Suites: trixie')&&r.sources.includes('Signed-By: /etc/apt/keyrings/docker.asc')&&r.log.includes('docker-compose-plugin')&&!r.log.includes('get.docker.com'));
for(const [name,env] of [['moving tag',{KUMA_IMAGE:'louislam/uptime-kuma:2'}],['foreign image',{KUMA_IMAGE:'other/image:2.5.8'}],['invalid IP',{KUMA_BIND_IP:'999.1.1.1'}],['invalid port',{KUMA_PORT:'70000'}],['invalid timezone',{TZ:'Europe/London\nBAD=1'}]])run(`Kuma rejects ${name}`,'deploy','happy',env,r=>r.code!==0&&!r.log.includes('docker '));
for(const scenario of ['docker-failure','pull-timeout','bad-digest','config-failure','up-failure'])run(`Kuma propagates ${scenario}`,'deploy',scenario,{},r=>r.code!==0&&(scenario==='up-failure'||!r.log.includes(' up -d ')));
run('Kuma digest pin localhost bind health wait','deploy','happy',{},r=>r.code===0&&r.saved.includes(digest)&&r.saved.includes('KUMA_BIND_IP=127.0.0.1')&&r.log.includes('--wait --wait-timeout 300')&&r.log.includes('--pull never'));
run('Kuma repeat preserves digest and LAN bind','deploy','happy',{},r=>r.code===0&&r.log.includes(`docker pull ${digest}`)&&r.saved.includes('KUMA_BIND_IP=192.168.1.123'),true);
run('Kuma explicit LAN bind override','deploy','happy',{KUMA_BIND_IP:'192.168.1.44'},r=>r.code===0&&r.saved.includes('KUMA_BIND_IP=192.168.1.44'));
run('Kuma refuses Proxmox host','deploy','pve-host',{},r=>r.code!==0&&!r.log.includes('docker '));
const compose=fs.readFileSync(template,'utf8');results.push({name:'Compose local volume explicit sqlite built-in healthcheck no socket',pass:compose.includes('homelab-uptime-kuma-data')&&compose.includes('UPTIME_KUMA_DB_TYPE: sqlite')&&compose.includes('/app/extra/healthcheck')&&compose.includes('unless-stopped')&&!compose.includes('docker.sock')});

async function testSocket(){
 const {EventEmitter}=require('node:events'),{initialize,monitorDefinitions}=require('../deploy/setup-uptime-kuma.cjs');
 const credentials={username:'fixture-user',password:'Fixture-only-password-12345',dnsHost:'192.168.1.123'};
 async function test(name,options,check){
  const calls=[];let disconnected=false;
  const io=()=>{
   const e=new EventEmitter();
   e.connect=()=>queueMicrotask(()=>EventEmitter.prototype.emit.call(e,'connect'));
   e.disconnect=()=>{disconnected=true;};
   e.emit=(name,...args)=>{
    const cb=args.pop();calls.push({name,args});
    queueMicrotask(()=>{
     if(name==='needSetup')cb(options.setup!==false);
     else if(name==='getMonitorList'){cb({ok:true});setImmediate(()=>EventEmitter.prototype.emit.call(e,'monitorList',options.existing||{}));}
     else cb({ok:!(name==='login'&&options.loginFailure)});
    });
    return e;
   };
   return e;
  };
  let response,error;try{response=await initialize(io,credentials);}catch(e){error=e;}
  results.push({name,pass:check({calls,response,error,disconnected})});
 }
 await test('Kuma setup then login creates three monitors',{},r=>!r.error&&r.disconnected&&r.response.monitorsAdded===3&&r.calls.findIndex(x=>x.name==='setup')<r.calls.findIndex(x=>x.name==='login'));
 const existing=Object.fromEntries(monitorDefinitions(credentials.dnsHost).map((m,i)=>[i+1,m]));
 await test('Kuma repeat setup does not duplicate monitors',{setup:false,existing},r=>!r.error&&r.response.monitorsAdded===0&&!r.calls.some(x=>x.name==='setup'));
 await test('Kuma login failure aborts before monitor mutation',{loginFailure:true},r=>r.error&&r.disconnected&&!r.calls.some(x=>x.name==='add'));
 await test('Kuma same-name changed target refuses silent overwrite',{setup:false,existing:{1:{...existing[1],url:'https://different.invalid/'}}},r=>r.error&&r.disconnected&&!r.calls.some(x=>x.name==='add'));
 await test('Kuma paused existing monitor requires review',{setup:false,existing:{1:{...existing[1],active:false}}},r=>r.error&&!r.calls.some(x=>x.name==='add'));
 await test('Kuma altered HTTP status policy requires review',{setup:false,existing:{1:{...existing[1],accepted_statuscodes:['200-599']}}},r=>r.error&&!r.calls.some(x=>x.name==='add'));
 await test('Kuma DNS query drift requires review',{setup:false,existing:{...existing,3:{...existing[3],hostname:'different.invalid'}}},r=>r.error&&!r.calls.some(x=>x.name==='add'));
 assert.throws(()=>monitorDefinitions('999.1.1.1'));
 results.push({name:'Kuma TLS exception only fixed Proxmox HTTPS monitors',pass:monitorDefinitions(credentials.dnsHost).filter(m=>m.ignoreTls).every(m=>['https://192.168.1.2:8006/','https://192.168.1.3:8006/'].includes(m.url))});
}
(async()=>{await testSocket();if(process.env.APPS_REPORT)fs.writeFileSync(process.env.APPS_REPORT,JSON.stringify(results,null,2));for(const item of results)console.log(`${item.pass?'PASS':'FAIL'} | ${item.name}`);console.log(`${results.filter(x=>x.pass).length}/${results.length} app deployment checks pass`);process.exitCode=results.every(x=>x.pass)?0:1;})().catch(e=>{console.error(e.message);process.exitCode=1;});
