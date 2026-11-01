// Portable input safety tests. Live migration and netplan tests remain separate.
'use strict';
const {spawnSync}=require('node:child_process');
const path=require('node:path');
const script=path.resolve(__dirname,'../deploy/proxmox-static-network.sh');
const bash=process.env.BASH || (process.platform==='win32'?'C:/Program Files/Git/bin/bash.exe':'bash');
function run(command,args=[],env=process.env) {
  return spawnSync(bash,['-c',command,'test',script,...args],{encoding:'utf8',timeout:10000,env});
}
let passed=0;
const syntax=spawnSync(bash,['-n',script],{encoding:'utf8',timeout:10000});
if(syntax.status!==0) throw Error(syntax.stderr || 'Bash syntax failed');
passed++;
const valid=[
 ['lxc','100','dns01','192.168.1.210/24','192.168.1.1'],
 ['lxc','101','dns02','192.168.1.150/24','192.168.1.1'],
 ['vm','100','apps01','192.168.1.58/24','192.168.1.1']
];
for(const args of valid) {
 const result=run('source "$1"; shift; validate_arguments "$@"; printf "%s" "$EXPECTED_NODE"',args);
 if(result.status!==0 || result.stdout!==(args[2]==='dns01'?'pve01':'pve02')) throw Error('Valid resource rejected: '+args.join(' ')+result.stderr);
 passed++;
}
const invalid=[
 [], ['ct',...valid[0].slice(1)], ['lxc','0',...valid[0].slice(2)],
 ['lxc','100;false',...valid[0].slice(2)], ['lxc','100','dns02',...valid[0].slice(3)],
 ['lxc','100','dns01','192.168.1.211/24','192.168.1.1'],
 ['lxc','100','dns01','192.168.1.210/16','192.168.1.1'],
 ['lxc','100','dns01','192.168.1.210/24','1.1.1.1'],
 ['lxc','100','dns01','192.168.1.0210/24','192.168.1.1'],
 ['lxc','100','dns01','192.168.1.256/24','192.168.1.1'],
 [...valid[0],'extra']
];
for(const args of invalid) {
 const result=run('source "$1"; shift; validate_arguments "$@"',args);
 if(result.status===0) throw Error('Unsafe input accepted: '+args.join(' '));
 passed++;
}
// Sourcing must not execute privileged host commands or start a migration.
const sourceOnly=run('source "$1"; printf "loaded"');
if(sourceOnly.status!==0 || sourceOnly.stdout!=='loaded') throw Error('Source caused side effects');
passed++;
// Validate real parser behavior against PVE's reordered saved properties.
// Python is provided by the environment or located beside the bundled runtime.
const python=process.env.PYTHON || (process.platform==='win32'
 ? path.resolve(path.dirname(process.execPath),'../../python/python.exe') : 'python3');
const pythonCheck=spawnSync(python,['-c','import sys'],{encoding:'utf8',timeout:10000});
if(pythonCheck.status!==0) throw Error('Python is required for metadata regression checks; set PYTHON');
const parserEnv={...process.env,STATIC_TEST_PYTHON:python.replaceAll('\\','/')};
const parserCommand='source "$1"; shift; python3() { command "$STATIC_TEST_PYTHON" "$@"; }; validate_vm_ipconfig "$1" "192.168.1.58/24" "192.168.1.1"';
const metadataCases=[
 ['ip=dhcp',true],
 ['ip=192.168.1.58/24,gw=192.168.1.1',true],
 ['gw=192.168.1.1,ip=192.168.1.58/24',true],
 ['gw=192.168.1.1,ip=dhcp',false],
 ['ip=192.168.1.59/24,gw=192.168.1.1',false],
 ['ip=192.168.1.58/24,gw=192.168.1.2',false],
 ['ip=dhcp,ip=192.168.1.58/24,gw=192.168.1.1',false],
 ['ip=dhcp,ip=dhcp',false],
 ['ip=dhcp,ip6=auto',false],
 ['ip=dhcp,',false],
 ['',false]
];
for(const [metadata,accepted] of metadataCases) {
 const result=run(parserCommand,[metadata],parserEnv);
 if((result.status===0)!==accepted) throw Error('Unexpected metadata parser result for '+metadata+': '+result.stderr);
 passed++;
}
console.log(`PASS ${passed} static-network syntax/input safety checks; no live network mutation tested.`);
