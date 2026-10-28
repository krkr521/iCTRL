const assert=require('node:assert/strict');
global.window={};require('./web/quiet-manual-compat.js');
function fixture(extra={}) {
 let state={mode:'manual',ui_blocked:true,takeover_state:'restoration_pending',...extra};
 let failure=false,ownerOverride=null;const calls=[],controls={};
 const document={createElement(){return {querySelector(k){return controls[k]??={textContent:''}}}},addEventListener(){}};
 const raw=async(method)=>{calls.push(method);
  if(method==='automation_register')return {mode:'manual'};
  if(method==='automation_owner_status')return ownerOverride?ownerOverride():state;
  if(method==='automation_inspect'){if(failure)throw Error('response unknown');return {state:'restoration_pending'}};
  throw Error('Unexpected operation '+method);
 };
 const client=window.IctrlQuietManualCompat.create({rpc:raw,document,supportsQuiet:async()=>true});
 return {client,controls,calls,count:m=>calls.filter(x=>x===m).length,
  state(v){state={...state,...v}},loseResponse(){failure=true},owner(fn){ownerOverride=fn}};
}
(async()=>{
 let f=fixture({inspect_ready:false,inspect_wait_seconds:17});await f.client.connect();
 assert.equal(f.controls['[data-inspect]'].disabled,true);
 assert.match(f.controls['[role=status]'].textContent,/17 秒/);
 await f.controls['[data-inspect]'].onclick();assert.equal(f.count('automation_inspect'),0);
 f.state({inspect_ready:true,inspect_wait_seconds:0});await f.client.poll();
 assert.equal(f.count('automation_inspect'),0,'availability does not automatically inspect');
 assert.equal(f.controls['[data-inspect]'].disabled,false);
 await f.controls['[data-inspect]'].onclick();await f.controls['[data-inspect]'].onclick();
 assert.equal(f.count('automation_inspect'),1);
 await f.client.poll();assert.match(f.controls['[role=status]'].textContent,/已发送恢复检查/);
 assert.equal(f.client.getState().ready,false);

 f=fixture({inspect_ready:true});await f.client.connect();
 f.state({inspect_ready:false,inspect_wait_seconds:2});
 await f.controls['[data-inspect]'].onclick();assert.equal(f.count('automation_inspect'),0,'fresh preflight cancels stale eligibility');
 f.state({inspect_ready:true,inspect_wait_seconds:0});await f.client.poll();
 f.loseResponse();await f.controls['[data-inspect]'].onclick();await f.client.poll();
 await f.controls['[data-inspect]'].onclick();assert.equal(f.count('automation_inspect'),1,'unknown result is never replayed');
 await f.client.connect();await f.controls['[data-inspect]'].onclick();
 assert.equal(f.count('automation_inspect'),1,'reconnect cannot erase unknown attempt');
 f.state({ui_blocked:false,takeover_state:'manual_ready'});await f.client.poll();
 f.state({ui_blocked:true,takeover_state:'restoration_pending',inspect_ready:true});await f.client.poll();
 await f.controls['[data-inspect]'].onclick();
 assert.equal(f.count('automation_inspect'),2,'a confirmed ended recovery does not disable future leases');

 for(const value of ['true',1,null]){
  f=fixture({inspect_ready:value});await f.client.connect();
  await f.controls['[data-inspect]'].onclick();assert.equal(f.count('automation_inspect'),0);
 }
 f=fixture();await f.client.connect();await f.controls['[data-inspect]'].onclick();
 assert.equal(f.count('automation_inspect'),1,'older Native server remains compatible');

 f=fixture({inspect_ready:true});await f.client.connect();let resolve;
 f.owner(()=>new Promise(r=>{resolve=r}));
 const first=f.controls['[data-inspect]'].onclick();const second=f.controls['[data-inspect]'].onclick();
 assert.equal(f.count('automation_inspect'),0);
 resolve({mode:'manual',ui_blocked:true,takeover_state:'restoration_pending',inspect_ready:true});
 await Promise.all([first,second]);assert.equal(f.count('automation_inspect'),1,'concurrent click cannot double-submit');
 f=fixture({inspect_ready:true});await f.client.connect();let release;
 const ownerPending=new Promise(r=>{release=r});f.owner(()=>ownerPending);
 const stale=f.controls['[data-inspect]'].onclick();const reconnect=f.client.connect();
 release({mode:'manual',ui_blocked:true,takeover_state:'restoration_pending',inspect_ready:true});
 await Promise.all([stale,reconnect]);
 assert.equal(f.count('automation_inspect'),0,'reconnect invalidates stale read preflight without sending');
 await f.controls['[data-inspect]'].onclick();assert.equal(f.count('automation_inspect'),1);
 for(const m of ['automation_begin','automation_end','automation_takeover'])assert.equal(f.count(m),0);
 console.log('inspection wait: server eligibility, stale preflight, no automatic inspect, one-shot unknown, strict boolean, old server and concurrent click passed');
})().catch(e=>{console.error(e);process.exitCode=1});
