(() => {
'use strict';
const root=document.documentElement;
try { root.dataset.theme=localStorage.getItem('hy2-theme')||'light'; } catch {}
const $=selector=>document.querySelector(selector);
const toast=message=>{const el=$('#toast');el.textContent=message;el.hidden=false;clearTimeout(toast.timer);toast.timer=setTimeout(()=>el.hidden=true,3500);};
$('#theme-toggle')?.addEventListener('click',()=>{
 root.dataset.theme=root.dataset.theme==='dark'?'light':'dark';
 try {localStorage.setItem('hy2-theme',root.dataset.theme);} catch {}
 $('#theme-toggle').setAttribute('aria-label',root.dataset.theme==='dark'?'切换浅色模式':'切换深色模式');
 drawChart();
});
$('#theme-toggle')?.setAttribute('aria-label',root.dataset.theme==='dark'?'切换浅色模式':'切换深色模式');
$('#menu-toggle')?.addEventListener('click',()=>{
 if(document.body.classList.contains('menu-open'))closeMenu(true);else openMenu();
});
const sidebar=$('#sidebar'),menuToggle=$('#menu-toggle'),backdrop=$('#sidebar-backdrop'),mobileViewport=window.matchMedia('(max-width: 800px)');
function syncMenuAvailability(){if(!sidebar)return;const mobile=mobileViewport.matches;if(!mobile){document.body.classList.remove('menu-open');sidebar.inert=false;sidebar.setAttribute('aria-hidden','false');menuToggle?.setAttribute('aria-expanded','false');menuToggle?.setAttribute('aria-label','展开导航');if(backdrop)backdrop.hidden=true;}else if(!document.body.classList.contains('menu-open')){sidebar.inert=true;sidebar.setAttribute('aria-hidden','true');menuToggle?.setAttribute('aria-expanded','false');menuToggle?.setAttribute('aria-label','展开导航');if(backdrop)backdrop.hidden=true;}}
function openMenu(){if(!sidebar||!mobileViewport.matches)return;document.body.classList.add('menu-open');sidebar.inert=false;sidebar.setAttribute('aria-hidden','false');menuToggle?.setAttribute('aria-expanded','true');menuToggle?.setAttribute('aria-label','收起导航');if(backdrop)backdrop.hidden=false;sidebar.querySelector('a')?.focus();}
function closeMenu(returnFocus=false){if(!sidebar)return;document.body.classList.remove('menu-open');sidebar.inert=mobileViewport.matches;sidebar.setAttribute('aria-hidden',String(mobileViewport.matches));menuToggle?.setAttribute('aria-expanded','false');menuToggle?.setAttribute('aria-label','展开导航');if(backdrop)backdrop.hidden=true;if(returnFocus&&mobileViewport.matches)menuToggle?.focus();}
syncMenuAvailability();mobileViewport.addEventListener('change',syncMenuAvailability);
backdrop?.addEventListener('click',()=>closeMenu(true));
document.addEventListener('keydown',event=>{
 if(!document.body.classList.contains('menu-open'))return;
 if(event.key==='Escape'){event.preventDefault();closeMenu(true);return;}
 if(event.key==='Tab'){
  const items=[...sidebar.querySelectorAll('a[href],button:not([disabled]),[tabindex]:not([tabindex="-1"])')].filter(item=>!item.hidden);
  if(!items.length){event.preventDefault();return;}
  const first=items[0],last=items[items.length-1];
  if(event.shiftKey&&document.activeElement===first){event.preventDefault();last.focus();}
  else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first.focus();}
 }
});
document.addEventListener('focusin',event=>{if(document.body.classList.contains('menu-open')&&!sidebar.contains(event.target))sidebar.querySelector('a')?.focus();});
$('#subscription-visibility')?.addEventListener('click',event=>{
 const input=$('#subscription-url'),button=event.currentTarget,visible=input.type==='password';
 input.type=visible?'text':'password';button.setAttribute('aria-pressed',String(visible));button.textContent=visible?'隐藏订阅地址':'显示订阅地址';
});
document.querySelectorAll('[data-copy]').forEach(button=>button.addEventListener('click',async()=>{
 const input=document.getElementById(button.dataset.copy);
 const label=button.dataset.copyLabel||'地址';
 try {await navigator.clipboard.writeText(input.value);toast(label+'已复制');}
 catch {input.focus();input.select();toast('已选中'+label+'，请按复制快捷键或长按复制');}
}));
// 倒计时只提示有效期；是否已兑换始终由服务端核验，不在页面假定配对成功。
const pairingExpiry=$('#pairing-expiry');
if(pairingExpiry){
 const deadline=Number(pairingExpiry.dataset.expires)*1000;
 if(Number.isFinite(deadline)){
  const update=()=>{
   const seconds=Math.max(0,Math.ceil((deadline-Date.now())/1000));
   pairingExpiry.textContent=seconds>0?'剩余 '+String(Math.floor(seconds/60)).padStart(2,'0')+':'+String(seconds%60).padStart(2,'0'):'配对码已过期';
   if(seconds===0){$('#pairing-copy').disabled=true;pairingExpiry.classList.add('expired');clearInterval(pairingTimer);}
  };
  const pairingTimer=setInterval(update,1000);update();
 }
}
document.querySelectorAll('.qr-details').forEach(details=>details.addEventListener('toggle',()=>{
 const img=details.querySelector('img[data-src]');if(details.open&&img){img.src=img.dataset.src;delete img.dataset.src;}
}));
const dialog=$('#confirm-dialog');let pendingForm=null;
$('#confirm-cancel')?.addEventListener('click',()=>dialog.close());
$('#confirm-accept')?.addEventListener('click',()=>{const form=pendingForm;dialog.close();if(form){form.dataset.confirmed='true';form.requestSubmit();}});
dialog?.addEventListener('close',()=>{pendingForm=null;});
document.querySelectorAll('form[method="post"]').forEach(form=>form.addEventListener('submit',event=>{
 if(form.dataset.confirm&&!form.dataset.confirmed){
   event.preventDefault();pendingForm=form;$('#confirm-message').textContent=form.dataset.confirm;dialog.showModal();$('#confirm-cancel').focus();return;
 }
 if(form.dataset.submitted){event.preventDefault();return;}
 form.dataset.submitted='true';
 form.querySelectorAll('button').forEach(button=>{button.disabled=true;button.textContent='处理中…';});
}));
window.addEventListener('pageshow',event=>{if(event.persisted)location.reload();});
const bytes=value=>{
 if(value===null||value===undefined)return '—';
 const units=['B','KiB','MiB','GiB','TiB'];let i=0;
 while(value>=1024&&i<4){value/=1024;i++;}
 return value.toFixed(1)+' '+units[i];
};
const bj=value=>value?new Intl.DateTimeFormat('zh-CN',{timeZone:'Asia/Shanghai',year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',hour12:false}).format(new Date(value.replace(' ','T')+'Z')):'尚无记录';
const canvas=$('#traffic-chart');let points=canvas?JSON.parse(canvas.dataset.points):[];
function drawChart(){
 if(!canvas)return;
 const box=canvas.parentElement, w=box.clientWidth,h=box.clientHeight,dpr=window.devicePixelRatio||1;
 if(!w)return;canvas.width=w*dpr;canvas.height=h*dpr;
 const ctx=canvas.getContext('2d');ctx.scale(dpr,dpr);
 const style=getComputedStyle(root),muted=style.getPropertyValue('--muted'),line=style.getPropertyValue('--line');
 const left=58,right=12,top=12,bottom=30,cw=w-left-right,ch=h-top-bottom;
 const valid=points.some(p=>p.rx!==null||p.tx!==null);$('#chart-empty').hidden=valid;
 const max=Math.max(1024,...points.flatMap(p=>[p.rx||0,p.tx||0]))*1.15;
 ctx.font='10px system-ui';ctx.textBaseline='middle';
 for(let i=0;i<=4;i++){const y=top+ch*i/4;ctx.strokeStyle=line;ctx.beginPath();ctx.moveTo(left,y);ctx.lineTo(w-right,y);ctx.stroke();ctx.fillStyle=muted;ctx.textAlign='right';ctx.fillText(bytes(max*(1-i/4)),left-8,y);}
 const x=i=>left+i*cw/Math.max(1,points.length-1);
 ctx.textAlign='center';for(let i=0;i<points.length;i++){if(i%Math.max(1,Math.ceil(points.length/(w<450?3:6)))!==0)continue;const label=points[i].label;ctx.fillText(label.length>10?label.slice(11):label.slice(5),x(i),h-10);}
 for(const [key,color] of [['rx',root.dataset.theme==='dark'?'#58c9bd':'#167d82'],['tx','#7e9cd2']]){
  ctx.strokeStyle=color;ctx.lineWidth=2;ctx.beginPath();let active=false;
  points.forEach((point,i)=>{if(point[key]===null){active=false;return;}const y=top+ch*(1-point[key]/max);if(active)ctx.lineTo(x(i),y);else ctx.moveTo(x(i),y);active=true;});ctx.stroke();
  points.forEach((point,i)=>{if(point[key]===null)return;ctx.beginPath();ctx.arc(x(i),top+ch*(1-point[key]/max),2,0,Math.PI*2);ctx.fillStyle=color;ctx.fill();});
 }
}
if(canvas){new ResizeObserver(drawChart).observe(canvas.parentElement);drawChart();}
function refreshRows(){
 const body=$('#chart-rows');if(!body)return;
 body.replaceChildren(...points.map(point=>{
 const tr=document.createElement('tr');for(const value of [point.label,bytes(point.tx),bytes(point.rx),point.complete?'完整':'不完整']){const td=document.createElement('td');td.textContent=value;tr.append(td);}return tr;
 }));
}
let timer;
async function refresh(){
 if(!canvas||document.hidden||dialog?.open){schedule();return;}
 try{
  const period=new URLSearchParams(location.search).get('period')||'24h';
  const response=await fetch('/api/overview?period='+encodeURIComponent(period),{headers:{Accept:'application/json'},cache:'no-store'});
  if(response.status===401){clearTimeout(timer);$('#live-status').textContent='登录已过期，请重新登录。';const a=document.createElement('a');a.href='/login?next='+encodeURIComponent(location.pathname+location.search);a.textContent=' 前往登录 →';$('#live-status').append(a);return;}
  if(!response.ok)throw Error();
  const data=await response.json(),m=data.metrics;
  $('#metric-rx').textContent=bytes(m.rx);$('#metric-tx').textContent=bytes(m.tx);$('#metric-online').textContent=m.online??'—';
  const status=$('#live-status');status.className='notice '+(m.fresh?'info':'warning');status.replaceChildren(document.createTextNode(m.fresh?'统计正常更新':'统计尚未就绪或已过期，当前在线状态未知'));
  const span=document.createElement('span');span.textContent='最近有效采集：'+bj(m.captured_at);status.append(span);
  points=m.points;drawChart();refreshRows();$('#chart-quality').textContent=m.complete?'数据连续':'所选时段数据不完整；缺失区间未计入用量。';
  const cards=$('#service-cards');['hysteria','auth','nginx'].forEach((key,i)=>{const badge=cards?.querySelectorAll('.badge')[i];if(badge){badge.textContent=data.service[key]==='active'?'运行中':(data.service[key]?'异常':'未知');badge.className='badge '+(data.service[key]==='active'?'positive':'warning');}});
 }catch{const status=$('#live-status');status.className='notice warning';status.textContent='暂时无法刷新，显示的是上次数据。稍后自动重试。';}
 schedule();
}
function schedule(){clearTimeout(timer);if(canvas&&!document.hidden)timer=setTimeout(refresh,30000);}
document.addEventListener('visibilitychange',()=>{clearTimeout(timer);if(!document.hidden)refresh();});
schedule();
})();
