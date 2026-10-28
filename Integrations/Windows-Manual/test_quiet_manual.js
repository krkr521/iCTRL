const assert=require('node:assert/strict');
global.window={};require('./web/quiet-manual-compat.js');const api=window.IctrlQuietManualCompat;
function setup({supported=true,enabled=true,blocked=false,failUI=false,registration='manual',takeoverState='quiet_verified',diagnostic=null}={}){
 const calls=[];const controls={};const handlers=new Map();
 const document={createElement(){return {querySelector(k){return controls[k]??={textContent:''};}}},addEventListener(t,fn){handlers.set(t,fn)}};
 const raw=async(m,p)=>{calls.push([m,p]);if(m==='automation_config')return {enabled};if(m==='automation_register')return {mode:registration};if(m==='automation_owner_status')return {mode:'manual',ui_blocked:blocked,takeover_state:blocked?takeoverState:'manual_ready',context_diagnostic:diagnostic};if(m==='automation_takeover')return {state:'ending'};if(m==='automation_inspect')return {state:'restoration_pending'};if(failUI)throw Error('response lost');return {};};
 const node={contains:x=>x===node};
 const panel=api.create({rpc:raw,document,supportsQuiet:async()=>supported,targets:()=>[node],cancelPointer:()=>{}});
 return {panel,calls,controls,handlers,node,setBlocked(v){blocked=v},setEnabled(v){enabled=v},count:m=>calls.filter(x=>x[0]===m).length};
}
(async()=>{
 let f=setup();await f.panel.connect();assert.equal(f.panel.getState().ready,true);assert.equal(f.count('automation_register'),1);assert.equal(f.count('automation_begin'),0);
 const epoch=f.panel.getState().epoch;f.setBlocked(true);await f.panel.poll();assert.equal(f.panel.getState().ready,false);assert.equal(f.count('automation_takeover'),0);
 let stopped=false;f.handlers.get('pointerup')({target:f.node,preventDefault(){},stopImmediatePropagation(){stopped=true}});assert.equal(stopped,true);
 await assert.rejects(f.panel.rpc('tap',{}));assert.equal(f.count('tap'),0);
 await f.controls['[data-takeover]'].onclick();await f.controls['[data-takeover]'].onclick();assert.equal(f.count('automation_takeover'),1);assert.equal(f.panel.getState().ready,false);
 f.setBlocked(false);await f.controls['[data-refresh]'].onclick();assert.equal(f.panel.getState().ready,true);assert.equal(f.panel.accepts(epoch),false);await f.panel.rpc('tap',{});assert.equal(f.count('tap'),1);
 f=setup({failUI:true});await f.panel.connect();await assert.rejects(f.panel.rpc('type',{}));await assert.rejects(f.panel.rpc('type',{}));assert.equal(f.count('type'),1);assert.equal(f.panel.getState().ready,false);
 for(const options of [{supported:false}]){f=setup(options);await f.panel.connect();assert.equal(f.panel.getState().ready,false);await assert.rejects(f.panel.rpc('tap',{}));f.controls['[data-legacy]'].onclick();assert.equal(f.panel.getState().ready,true);assert.equal(f.count('automation_begin'),0);}
 f=setup({registration:'automation'});await f.panel.connect();assert.equal(f.panel.getState().ready,false);f.controls['[data-legacy]'].onclick();assert.equal(f.panel.getState().ready,false);
 f=setup({enabled:false,blocked:true,takeoverState:'restoration_pending'});await f.panel.connect();assert.equal(f.controls['[data-inspect]'].hidden,false);await f.controls['[data-inspect]'].onclick();await f.controls['[data-inspect]'].onclick();assert.equal(f.count('automation_inspect'),1);assert.equal(f.panel.getState().ready,false);
 f=setup({blocked:true,takeoverState:'restoring',diagnostic:'foreground_restore_timeout'});await f.panel.connect();assert.equal(f.panel.getState().ready,false);assert.match(f.controls['[role=status]'].textContent,/原界面恢复超时/);await assert.rejects(f.panel.rpc('tap',{}));assert.equal(f.count('tap'),0);
 // New Runner manual roles stay usable while quiet is OFF; no old-mode bypass.
 f=setup({enabled:false});await f.panel.connect();assert.equal(f.panel.getState().ready,true);assert.equal(f.controls['[data-legacy]'].hidden,true);
 assert.equal(f.count('automation_config'),0);await f.panel.rpc('tap',{});assert.equal(f.count('tap'),1);
 const beforeExternal=f.panel.getState().epoch;
 // External feature enable + Agent lease must be observed despite quiet initially off.
 f.setEnabled(true);f.setBlocked(true);await f.panel.poll();assert.equal(f.panel.getState().ready,false);
 await assert.rejects(f.panel.rpc('tap',{}));assert.equal(f.count('tap'),1);assert.equal(f.count('automation_begin'),0);assert.equal(f.count('automation_end'),0);
 await f.controls['[data-takeover]'].onclick();assert.equal(f.count('automation_takeover'),1);assert.equal(f.panel.getState().ready,false);
 f.setBlocked(false);await f.controls['[data-refresh]'].onclick();assert.equal(f.panel.getState().ready,true);assert.equal(f.panel.accepts(beforeExternal),false);assert.equal(f.count('tap'),1);
 await f.panel.rpc('tap',{});assert.equal(f.count('tap'),2);assert.equal(f.count('automation_register'),1);
 assert.doesNotMatch(f.panel.panel.innerHTML,/legacy setup|token|quiet_verified|deadline|300/);
 console.log('manual JS: registration, pause, explicit one-shot takeover, recovery, stale pointer, no UI replay, quiet-off manual, external lease pause, old-version choice and no downgrade passed');
})().catch(e=>{console.error(e);process.exitCode=1});
