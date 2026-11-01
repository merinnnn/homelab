const fs = require('fs');
const path = require('path');
const cp = require('child_process');
const os = require('os');
const repo = path.resolve(__dirname, '../..');
const bash = process.env.BASH || (process.platform === 'win32' ? path.join(process.env.ProgramFiles || 'C:/Program Files', 'Git/bin/bash.exe') : '/bin/bash');
const fixtures = fs.mkdtempSync(path.join(os.tmpdir(), 'homelab-offline-'));
process.on('exit', () => {
  const realTemp = fs.realpathSync(os.tmpdir());
  const realFixtures = fs.realpathSync(fixtures);
  if (realFixtures.startsWith(realTemp + path.sep) && path.basename(realFixtures).startsWith('homelab-offline-')) {
    fs.rmSync(realFixtures, {recursive:true, force:true});
  }
});
const posix = p => p.replaceAll('\\','/').replace(/^([A-Za-z]):/, (_,d)=>'/'+d.toLowerCase());
const quote = s => "'"+s.replaceAll("'", "'\\''")+"'";
const scripts = ['provision-debian-vm.sh','create-vm.sh','create-lxc.sh','prepare-images.sh'];
for (const script of scripts) fs.copyFileSync(path.join(repo,'scripts/provision',script),path.join(fixtures,script));
for (const script of ['network-connectivity.sh','service-health.sh']) fs.copyFileSync(path.join(repo,'scripts/tests',script),path.join(fixtures,script));
fs.writeFileSync(path.join(fixtures,'id.pub'),'ssh-ed25519 AAAATEST fixture\n');
fs.writeFileSync(path.join(fixtures,'mock-functions.sh'),String.raw`log() { printf '%s\n' "$*" >> "$TEST_LOG"; }
qm() {
  log "qm $*"
  if [ "$1" = config ]; then
    [ "$SCENARIO" != nonexistent-vm ] || return 2
    [ "$SCENARIO" != no-net0 ] || return 0
    if [ "$SCENARIO" = different-mac ]; then printf 'net0: virtio=AA:BB:CC:DD:EE:00,bridge=vmbr1\n';
    else printf 'net0: virtio=AA:BB:CC:DD:EE:FF,bridge=vmbr1\n'; fi
  fi
  if [ "$1" = set ] && [ "$SCENARIO" = import-failure ]; then return 7; fi
  return 0
}
dpkg() { echo amd64; }
pvesh() { echo 900; }
pvesm() {
  log "pvesm $*"
  if [ "$1" = status ]; then
    echo 'Name Type Status Total Used Available %'
    [ "$SCENARIO" != no-storage ] || return 0
    if [ "$3" = import ] || [ "$3" = vztmpl ]; then echo 'local dir active 100 0 100 0'; else echo 'local-lvm lvmthin active 100 0 100 0'; fi
    [ "$SCENARIO" != multiple-storage ] || echo 'extra dir active 100 0 100 0'
  elif [ "$1" = list ]; then
    echo 'Volid Format Type Size VMID'
    [ "$SCENARIO" != missing-image ] || return 0
    echo 'local:import/debian-13-genericcloud-amd64.qcow2 qcow2 import 100'
  elif [ "$1" = path ]; then echo "$TEST_DIR/cloud.qcow2"; fi
}
pveam() {
  log "pveam $*"
  case "$1" in
    available)
      if [ "$SCENARIO" = compat-two-col ]; then printf 'system debian-13-standard_13.6-1_amd64.tar.zst\n';
      else printf 'system debian-13-standard_13.6-1_amd64.tar.zst amd64\n'; fi;;
    list) printf 'NAME SIZE\nlocal:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst 100MB\n';;
    *) return 0;;
  esac
}
ip() { log "ip $*"; [ "$SCENARIO" != missing-bridge ]; }
pct() {
  log "pct $*"
  if [ "$SCENARIO" = restrictive-caller ]; then
    command mkdir "$TEST_DIR/guest-etc"
    : > "$TEST_DIR/guest-etc/resolv.conf"
    log "guest etc mode $(command stat -c %a "$TEST_DIR/guest-etc")"
    log "guest resolver mode $(command stat -c %a "$TEST_DIR/guest-etc/resolv.conf")"
  fi
  return 0
}
mkdir() { log "mkdir $*"; return 0; }
ssh() { log "ssh $*"; [ "$SCENARIO" != ssh-failure ]; }
awk() {
  local a args=()
  for a in "$@"; do
    if [ "$a" = /var/lib/misc/dnsmasq.leases ]; then args+=("$TEST_LEASES"); else args+=("$a"); fi
  done
  command awk "${'$'}{args[@]}"
}
ping() { [ "$SCENARIO" = all-healthy ]; }
nslookup() { [ "$SCENARIO" = all-healthy ]; }
nc() { [ "$SCENARIO" = all-healthy ]; }
curl() {
  if [ "$SCENARIO" = all-healthy ]; then printf 200; return 0; fi
  [ "$SCENARIO" = prepare-three-col ] || return 1
  local target='' previous='' arg
  for arg in "$@"; do [ "$previous" != -o ] || target="$arg"; previous="$arg"; done
  if [[ "$*" = *SHA512SUMS* ]]; then
    printf '%s  debian-13-genericcloud-amd64.qcow2\n' "$(printf test | command sha512sum | command awk '{print $1}')" > "$target"
  else printf test > "$target"; fi
}
dig() { if [ "$SCENARIO" = all-healthy ]; then echo 1.1.1.1; return 0; fi; [ "$SCENARIO" = empty-dns-answer ]; }
`);
const results=[];
function run(name, script,args=[],scenario='happy',leases='9999999999 aa:bb:cc:dd:ee:ff 10.0.10.128 vm *\n', assert=()=>true, callerUmask=null) {
  const log=path.join(fixtures,'commands.log'), lease=path.join(fixtures,'leases');
  fs.writeFileSync(log,'');fs.writeFileSync(lease,leases);
  const command=`${callerUmask ? 'umask '+quote(callerUmask)+'; ' : ''}source ${quote(posix(path.join(fixtures,'mock-functions.sh')))}; source ${quote(posix(path.join(fixtures,script)))} ${args.map(quote).join(' ')}`;
  const r=cp.spawnSync(bash,['-c',command],{encoding:'utf8',env:{...process.env,SCENARIO:scenario,TEST_LOG:posix(log),TEST_LEASES:posix(lease),TEST_DIR:posix(fixtures)}});
  const item={name,scenario,exit:r.status,stdout:r.stdout,stderr:r.stderr,commands:fs.readFileSync(log,'utf8')};
  item.expectationMet=!!assert(item);results.push(item);
}
const key=posix(path.join(fixtures,'id.pub'));
run('provision requires VMID','provision-debian-vm.sh',[],'happy',undefined,r=>r.exit!==0&&r.stdout.includes('Usage:')&&!r.commands);
run('provision rejects nonnumeric VMID before qm','provision-debian-vm.sh',['abc'],'happy',undefined,r=>r.exit!==0&&!r.commands);
run('provision rejects option VMID before qm','provision-debian-vm.sh',['--help'],'happy',undefined,r=>r.exit!==0&&!r.commands);
run('provision rejects excess arguments','provision-debian-vm.sh',['900','homelab','extra'],'happy',undefined,r=>r.exit!==0&&!r.commands);
run('provision rejects user containing destination separator','provision-debian-vm.sh',['900','bad@otherhost'],'happy',undefined,r=>r.exit!==0&&!r.commands);
run('provision rejects user beginning option dash','provision-debian-vm.sh',['900','-bad'],'happy',undefined,r=>r.exit!==0&&!r.commands);
run('provision accepts valid user punctuation','provision-debian-vm.sh',['900','lab.user-1$'],'happy',undefined,r=>r.exit===0&&r.commands.includes('lab.user-1$@10.0.10.128'));
run('provision rejects nonexistent VM','provision-debian-vm.sh',['900'],'nonexistent-vm',undefined,r=>r.exit!==0&&!r.commands.includes('ssh '));
run('provision rejects missing net0 MAC','provision-debian-vm.sh',['900'],'no-net0',undefined,r=>r.exit!==0&&!r.commands.includes('ssh '));
run('provision rejects no lease','provision-debian-vm.sh',['900'],'happy','',r=>r.exit!==0&&!r.commands.includes('ssh '));
run('provision rejects duplicate leases','provision-debian-vm.sh',['900'],'happy','9999999999 aa:bb:cc:dd:ee:ff 10.0.10.128 vm *\n9999999999 aa:bb:cc:dd:ee:ff 10.0.10.129 vm *\n',r=>r.exit!==0&&!r.commands.includes('ssh '));
run('provision SSH contract','provision-debian-vm.sh',['900','customuser'],'happy',undefined,r=>r.exit===0&&r.commands.includes('BatchMode=yes')&&r.commands.includes('ConnectTimeout=10')&&r.commands.includes('StrictHostKeyChecking=accept-new')&&r.commands.includes('HostKeyAlias=homelab-vm-900-aabbccddeeff')&&r.commands.includes('customuser@10.0.10.128')&&r.commands.includes('systemctl start qemu-guest-agent')&&r.commands.includes('systemctl is-active --quiet qemu-guest-agent')&&!r.commands.includes('systemctl enable'));
run('SSH alias stable across DHCP address changes','provision-debian-vm.sh',['900'],'happy','9999999999 aa:bb:cc:dd:ee:ff 10.0.10.200 vm *\n',r=>r.exit===0&&r.commands.includes('HostKeyAlias=homelab-vm-900-aabbccddeeff')&&r.commands.includes('homelab@10.0.10.200'));
run('SSH alias changes with VMID','provision-debian-vm.sh',['901'],'happy',undefined,r=>r.exit===0&&r.commands.includes('HostKeyAlias=homelab-vm-901-aabbccddeeff'));
run('SSH alias changes with MAC','provision-debian-vm.sh',['900'],'different-mac','9999999999 aa:bb:cc:dd:ee:00 10.0.10.128 vm *\n',r=>r.exit===0&&r.commands.includes('HostKeyAlias=homelab-vm-900-aabbccddee00'));
run('provision propagates SSH failure','provision-debian-vm.sh',['900'],'ssh-failure',undefined,r=>r.exit!==0&&!r.stdout.includes('Provisioned VM'));
run('provision should reject expired lease','provision-debian-vm.sh',['900'],'happy','1 aa:bb:cc:dd:ee:ff 10.0.10.128 vm *\n',r=>r.exit!==0&&!r.commands.includes('ssh '));
run('provision accepts infinite lease','provision-debian-vm.sh',['900'],'happy','0 aa:bb:cc:dd:ee:ff 10.0.10.128 vm *\n',r=>r.exit===0&&r.commands.includes('homelab@10.0.10.128'));
run('provision ignores expired lease beside valid lease','provision-debian-vm.sh',['900'],'happy','1 aa:bb:cc:dd:ee:ff 10.0.10.129 vm *\n9999999999 aa:bb:cc:dd:ee:ff 10.0.10.128 vm *\n',r=>r.exit===0&&r.commands.includes('homelab@10.0.10.128'));
for(const script of ['create-vm.sh','create-lxc.sh']) {
  const args=script==='create-vm.sh'?['offline-test','vmbr1',key]:['offline-test'];
  run(`${script} requires name`,script,[],'happy',undefined,r=>r.exit!==0&&!r.commands);
  run(`${script} happy path`,script,args,'happy',undefined,r=>r.exit===0&&r.commands.includes(script==='create-vm.sh'?'qm create 900':'pct create 900'));
  run(`${script} rejects missing bridge`,script,args,'missing-bridge',undefined,r=>r.exit!==0&&!r.commands.includes(script==='create-vm.sh'?'qm create':'pct create'));
  run(`${script} rejects multiple storage choices`,script,args,'multiple-storage',undefined,r=>r.exit!==0&&!r.commands.includes(script==='create-vm.sh'?'qm create':'pct create'));
  run(`${script} rejects missing storage`,script,args,'no-storage',undefined,r=>r.exit!==0&&!r.commands.includes(script==='create-vm.sh'?'qm create':'pct create'));
}
run('create-lxc normalizes restrictive caller mask for guest configuration','create-lxc.sh',['offline-test'],'restrictive-caller',undefined,r=>r.exit===0&&r.commands.includes('pct create 900')&&r.commands.includes('guest etc mode 755')&&r.commands.includes('guest resolver mode 644'),'077');
run('create-vm rejects missing image','create-vm.sh',['offline-test','vmbr1',key],'missing-image',undefined,r=>r.exit!==0&&!r.commands.includes('qm create'));
run('create-vm rejects missing key','create-vm.sh',['offline-test','vmbr1',key+'.missing'],'happy',undefined,r=>r.exit!==0&&!r.commands.includes('qm create'));
run('create-vm import failure leaves partial VM','create-vm.sh',['offline-test','vmbr1',key],'import-failure',undefined,r=>r.exit!==0&&r.commands.includes('qm create')&&!r.commands.includes('qm destroy'));
run('prepare-images current three-column pveam output','prepare-images.sh',[],'prepare-three-col',undefined,r=>r.exit===0);
run('prepare-images two-column pveam compatibility limit','prepare-images.sh',[],'compat-two-col',undefined,r=>r.exit!==0&&r.stdout.includes('No Debian'));
run('network checks should fail when every dependency fails','network-connectivity.sh',[],'all-down',undefined,r=>r.exit!==0);
run('health checks should fail when every dependency fails','service-health.sh',[],'all-down',undefined,r=>r.exit!==0);
run('health checks should reject empty DNS answer','service-health.sh',[],'empty-dns-answer',undefined,r=>!/^Pi-hole DNS.*: OK$/m.test(r.stdout));
run('network checks pass healthy fixture','network-connectivity.sh',[],'all-healthy',undefined,r=>r.exit===0&&!r.stdout.includes(': FAIL'));
run('health checks pass healthy fixture','service-health.sh',[],'all-healthy',undefined,r=>r.exit===0&&!r.stdout.includes(': FAIL'));
const invalidDir=path.join(fixtures,'ci-invalid');fs.mkdirSync(invalidDir,{recursive:true});fs.writeFileSync(path.join(invalidDir,'invalid.sh'),'if then\n');
const ciFile=path.join(repo,'.github/workflows/homelab-validation.yml');
const ciText=fs.readFileSync(ciFile,'utf8');
const ciShellArgs=/^\s+shell: bash\s*$/m.test(ciText)?['--noprofile','--norc','-e','-o','pipefail']:['-e'];
const ciCommand=ciText.split(/\r?\n/).find(line=>line.includes('find . -name "*.sh"')).trim().replace(/^find \./,'find '+quote(posix(invalidDir)));
const ci=cp.spawnSync(bash,[...ciShellArgs,'-c',ciCommand],{encoding:'utf8'});
results.push({name:'CI shell validation should fail for syntax error',exit:ci.status,stdout:ci.stdout,stderr:ci.stderr,expectationMet:ci.status!==0});
const missingComposeCommand=ciText.split(/\r?\n/).find(line=>line.includes('find configs/docker')).trim().replace('find configs/docker','find '+quote(posix(path.join(fixtures,'missing-compose-input'))));
const missingCompose=cp.spawnSync(bash,[...ciShellArgs,'-c',missingComposeCommand],{encoding:'utf8'});
results.push({name:'CI must fail for missing Compose input directory',exit:missingCompose.status,stdout:missingCompose.stdout,stderr:missingCompose.stderr,expectationMet:missingCompose.status!==0});
const syntax=[];
function collect(dir){for(const f of fs.readdirSync(dir,{withFileTypes:true})){const p=path.join(dir,f.name);if(f.isDirectory() && !['.git','node_modules','.obsidian'].includes(f.name) && path.resolve(p)!==path.resolve(fixtures))collect(p);else if(f.name.endsWith('.sh')){const r=cp.spawnSync(bash,['-n',posix(p)],{encoding:'utf8'});syntax.push({file:path.relative(repo,p),exit:r.status,stderr:r.stderr});}}}
collect(path.join(repo,'scripts'));
const crlfFiles=syntax.map(x=>x.file).filter(file=>fs.readFileSync(path.join(repo,file),'utf8').includes('\r\n'));
results.push({name:'Shell sources retain LF line endings',expectationMet:crlfFiles.length===0,files:crlfFiles});
const output={repo,notes:['Mocks intercept Proxmox/SSH/network commands; no node connections or repository modifications.','Script copies preserve original bytes; all external operations use fixtures.','Only lease-file pathname is redirected by the awk wrapper.','Service startup/package behavior requires live validation.'],syntax,results};
if (process.env.OFFLINE_REPORT) fs.writeFileSync(process.env.OFFLINE_REPORT,JSON.stringify(output,null,2));
for(const x of results)console.log(`${x.expectationMet?'PASS':'DEFECT'} | ${x.name} | exit ${x.exit}`);
console.log(`Syntax checks: ${syntax.filter(x=>x.exit===0).length}/${syntax.length}; behavioral expectations met: ${results.filter(x=>x.expectationMet).length}/${results.length}`);

process.exitCode = results.every(x=>x.expectationMet) && syntax.every(x=>x.exit===0) ? 0 : 1;
