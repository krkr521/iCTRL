/* Manual browser identity only. This panel never starts Focus or silently takes over. */
(()=>{'use strict';
const READ_ONLY=new Set('runtime_status device_info is_locked logs recent_logs config screenshot page_source view_tree ui_tree find_element find_elements resolve_app search_app search_apps list_apps installed_apps snapshot_api stream_ticket file_list file_read file_status'.split(' '));
const DIAGNOSTICS={foreground_restore_timeout:'原界面恢复超时',foreground_restore_unconfirmed:'原界面恢复未确认',foreground_before_helper_unknown:'辅助操作前界面未知',shortcut_launch_failed:'快捷指令启动失败',foreground_context_missing:'缺少原界面上下文',foreground_changed_during_helper:'辅助期间用户已切换界面'};
const isUI=m=>!READ_ONLY.has(m)&&!m.startsWith('automation_')&&!m.startsWith('file_');
function create({rpc:raw,document,targets=()=>[],cancelPointer=()=>{},supportsQuiet,clock=()=>Date.now()}){
 const panel=document.createElement('section');panel.className='ictrl-input-compat';
 panel.innerHTML='<h3>手动控制（保留通知）</h3><div role="status"></div><button data-refresh>检查连接</button><button data-takeover>接管手机</button><button data-inspect hidden>检查恢复状态</button><button data-legacy hidden>继续旧版手动控制</button>';
 const text=panel.querySelector('[role=status]'),take=panel.querySelector('[data-takeover]'),legacy=panel.querySelector('[data-legacy]'),refresh=panel.querySelector('[data-refresh]'),inspect=panel.querySelector('[data-inspect]');
 let ready=false,epoch=0,connectionEpoch=0,connected=false,supported=false,legacyAllowed=false,latched=false,takeSent=false,inspectSent=false,inspectPreflight=false,inspectionReady=true,polling=false;
 function pause(message){if(ready)epoch++;ready=false;cancelPointer();text.textContent=message;}
 function accept(){ready=true;text.textContent=legacyAllowed?'已继续旧版手动控制，不改变通知设置。':'手动控制已就绪，不改变通知设置。';}
 async function owner({explicit=false}={}){
  const s=await raw('automation_owner_status',{});
  inspectionReady=!Object.hasOwn(s,'inspect_ready')||s.inspect_ready===true;
  const inspectionWait=Number.isSafeInteger(s.inspect_wait_seconds)&&s.inspect_wait_seconds>0&&s.inspect_wait_seconds<=600?s.inspect_wait_seconds:null;
  inspect.hidden=s.takeover_state!=='restoration_pending';inspect.disabled=inspectSent||inspectPreflight||!inspectionReady;
  if(s.mode!=='manual'){pause('此连接不是手动连接，请单独配对后重试。');return false;}
  // Reconnecting does not resolve an unknown inspect. Only the server's
  // confirmed unblocked state retires that attempt before a future lease.
  if(s.ui_blocked===false&&s.takeover_state==='manual_ready')inspectSent=false;
  if(s.ui_blocked===false&&s.takeover_state==='manual_ready'&&(!latched||explicit)) {latched=false;accept();}
  else {
   const message=['ending','restoring'].includes(s.takeover_state)?'正在恢复手机界面，请稍后检查连接。':s.takeover_state==='restoration_pending'?'手机界面恢复尚未确认，可稍后检查恢复状态。':'自动操作正在使用手机；手动控制已暂停，可检查连接或接管手机。';
   const inspectionMessage=s.takeover_state==='restoration_pending'?(inspectSent?'已发送恢复检查；点「检查连接」查看结果，不会自动重试。':!inspectionReady?(inspectionWait!==null?`恢复保护期剩余约 ${inspectionWait} 秒，结束后可检查恢复状态。`:'暂未满足恢复检查条件，请稍后检查连接。'):message):message;
   pause(inspectionMessage+(Object.hasOwn(DIAGNOSTICS,s.context_diagnostic)?' '+DIAGNOSTICS[s.context_diagnostic]:''));
  }
  return true;
 }
 async function connect(){
  connectionEpoch++;
  pause('正在检查手动连接…');connected=false;legacyAllowed=false;takeSent=false;inspectionReady=true;latched=false;inspect.hidden=true;legacy.hidden=true;
  try{
   supported=await supportsQuiet();
   if(!supported){connected=true;legacy.hidden=false;pause('当前版本不支持区分手动与自动操作，请确认后继续旧版手动控制。');return;}
   const registration=await raw('automation_register',{mode:'manual'});
   if(registration.mode!=='manual')throw Error('manual registration refused');connected=true;
   await owner();
  }catch(e){pause('无法建立手动连接；如已用于自动操作，请为手动控制单独配对。');}
 }
 async function rpc(method,params={}){
  if(!isUI(method))return raw(method,params);
  if(!ready)throw Error('手动控制已暂停，请先检查连接或接管手机；原操作不会重发。');
  const at=epoch;
  try{
   if(supported)await owner();
   if(!ready||at!==epoch)throw Error('手机控制状态已改变，本次操作已取消。');
   return await raw(method,params);
  }catch(e){latched=true;pause('操作未获确认，已暂停；请检查手机或连接，原操作不会重发。');throw e;}
 }
 take.onclick=async()=>{
  if(!connected||!supported||takeSent)return;
  takeSent=true;latched=true;pause('正在接管手机，请等待界面恢复。');
  try{
   if(!await owner())return;
   const s=await raw('automation_takeover',{mode:'manual'});
   if(s.state==='manual_ready'){latched=false;await owner({explicit:true});}
   else text.textContent='手机界面尚未恢复，暂时保持暂停，请稍后检查连接。';
  }catch(e){pause('接管未获确认，暂时保持暂停；请稍后检查连接。');}
 };
 inspect.onclick=async()=>{
  if(!connected||!supported||inspect.hidden||inspectSent||inspectPreflight||!inspectionReady)return;
  const at=connectionEpoch;inspectPreflight=true;inspect.disabled=true;
  try{
   if(!await owner()||at!==connectionEpoch||!connected||!supported||inspectSent||inspect.hidden||!inspectionReady)return;
   inspectSent=true;latched=true;pause('正在检查恢复状态，暂时保持暂停。');
   await raw('automation_inspect',{});
   text.textContent='正在等待恢复确认，请稍后检查连接。';
  }catch(e){pause('暂时无法确认恢复，请稍后检查连接；不会重复操作。');}
  finally{inspectPreflight=false;inspect.disabled=inspectSent||!inspectionReady;}
 };
 refresh.onclick=async()=>{if(connected&&supported){try{await owner({explicit:true});}catch(e){pause('暂时无法检查连接，手动控制保持暂停。');}}else await connect();};
 legacy.onclick=()=>{if(connected&&!supported){legacyAllowed=true;accept();}};
 function guard(event){if(ready||!targets().some(n=>n&&(n===event.target||n.contains(event.target))))return;if(event.target?.hasAttribute?.('data-ictrl-input-sink'))event.target.value='';if(event.cancelable!==false)event.preventDefault();event.stopImmediatePropagation();}
 for(const t of ['pointerdown','pointerup','dblclick','contextmenu','wheel','keydown','beforeinput','input','paste','compositionstart','compositionend'])document.addEventListener(t,guard,{capture:true,passive:false});
 async function poll(){if(polling||!connected||!supported)return;polling=true;try{await owner();}catch(e){pause('连接状态暂时不可用，手动控制已暂停；原操作不会重发。');}finally{polling=false;}}
 return {panel,rpc,connect,poll,getState:()=>({ready,epoch}),accepts:e=>ready&&e===epoch};
}
window.IctrlQuietManualCompat={create,isUI};
})();
