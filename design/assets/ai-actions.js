'use strict';
const $ = id => document.getElementById(id);
const icon = name => { const el = document.createElement('i'); el.dataset.lucide = name; return el; };
const icons = () => window.lucide?.createIcons();
const samples = {
  ask: '周末想和朋友去海边，不想把行程排得太满。\n\n帮我想一个轻松的安排，再写一段可以直接发给朋友的邀请。语气自然一点。',
  german: '这周六我们去海边走走吧。\n\n下午三点在地铁站见，先喝杯咖啡，再去看日落。不用赶行程，带件外套就好。',
  extract: '这周六我们去海边走走吧。下午三点在地铁站见，先喝杯咖啡，再去看日落。不用赶行程，带件外套就好。',
  polish: '周六去海边？三点地铁站碰头，喝咖啡看日落。记得外套。'
};
const answers = {
  ask: '只安排咖啡和日落，把中间的时间留给散步。\n\n可以这样发给朋友：\n“周六要不要一起去海边？下午喝杯咖啡，沿着海边走走，等日落再回来。不赶行程，就当给自己放半天假。”',
  german: 'Lass uns diesen Samstag ans Meer fahren.\n\nTreffen wir uns um drei Uhr nachmittags an der U-Bahn-Station. Wir trinken erst einen Kaffee und schauen uns dann den Sonnenuntergang an. Ganz ohne Stress – bring einfach eine Jacke mit.',
  extract: '日期：这周六\n时间：下午三点\n碰面地点：地铁站（未提及具体站名）\n安排：喝咖啡 → 海边散步 → 看日落\n需要带：外套',
  polish: '这周六一起去海边吧？下午三点在地铁站见，喝杯咖啡，再慢慢走到海边看日落。记得带件外套。',
  english: "Let's go to the seaside this Saturday.\n\nLet's meet at the metro station at three in the afternoon, grab a coffee, and watch the sunset. No need to rush — just bring a jacket."
};
const builtins = [
  {id:'english',name:'翻译成英语',key:'en',description:'默认动作 · 自然表达，只返回译文',symbol:'languages',prompt:'将输入内容翻译成自然流畅的英语，保留原意和段落。只输出译文。'},
  {id:'german',name:'翻译成德语',key:'de',description:'自然表达，只返回译文',symbol:'languages',prompt:'将输入内容翻译成自然流畅的德语，保留原意和段落。只输出译文，不要解释。'},
  {id:'extract',name:'提取约定',key:'yueding',description:'时间、地点、安排、要带的东西',symbol:'list-checks',prompt:'从输入文字中提取日期、时间、碰面地点、安排和需要带的东西。按清单输出；没有提到的信息写“未提及”，不要猜测。'},
  {id:'polish',name:'说得自然点',key:'ziran',description:'保留你的意思，少一点生硬',symbol:'feather',prompt:'把输入改写成自然、轻松的日常表达，保留所有事实，不增加信息。只返回改写后的文字。'}
];
let customActions = [];
try { const data = JSON.parse(localStorage.getItem('fangcun-ai-actions-v1') || '[]'); if (Array.isArray(data)) customActions = data.filter(a => a && typeof a.id === 'string' && a.id.startsWith('custom-') && ['name','key','prompt'].every(k => typeof a[k] === 'string')).slice(0,40); } catch {}
let mode = 'transform', actionId = 'english', view = 'expanded', pending = null, selected = '', composing = false;
try {
  const saved = JSON.parse(localStorage.getItem('fangcun-ai-selection-v1') || 'null');
  if(saved && [...builtins,...customActions].some(a=>a.id===saved.actionId)) actionId=saved.actionId;
} catch {}
let requests = 0, failNext = false, toastTimer, anchor = null, lastInsert = null, editingAction = null;
const initialSession = source => ({ source, reference:'', result:'', versions:[], selectedVersion:0, stale:false });
const sessions = { ask:initialSession(samples.ask), transform:initialSession(samples[actionId] || samples.german) };
sessions.ask.result = answers.ask;
sessions.ask.versions = [{text:answers.ask,question:samples.ask,label:'初次回答'}];
const session = () => sessions[mode];
const allActions = () => [...builtins, ...customActions];
const action = () => allActions().find(a => a.id === actionId) || builtins[0];
function toast(message) { clearTimeout(toastTimer); $('toast').textContent=message; $('toast').hidden=false; toastTimer=setTimeout(()=>$('toast').hidden=true,3200); }
function status(message, warning=false) { $('status').textContent=message; $('status').classList.toggle('warning',warning); }
function captureAnchor() { anchor={value:$('hostInput').value,start:$('hostInput').selectionStart,end:$('hostInput').selectionEnd}; }
function targetValid() { return anchor && $('hostInput').value === anchor.value && $('hostInput').selectionStart === anchor.start && $('hostInput').selectionEnd === anchor.end; }
function syncSource() { session().source=$('source').value; session().reference=$('reference').value; }
function clearSelected() { selected=''; $('result').setSelectionRange($('result').selectionEnd,$('result').selectionEnd); updateControls(); }
function updateControls() {
  const s=session(), ready=!!s.result.trim() && !s.stale && !pending && !composing;
  $('sourceCount').textContent=`${s.source.length} 字`;
  $('run').disabled=composing || (!pending && !s.source.trim());
  $('runLabel').textContent=pending?'停止':(mode==='ask'?(s.result?'重新回答':'问一下'):'执行动作');
  $('copyResult').disabled=!s.result.trim() || !!pending;
  $('copyLabel').textContent=selected?'复制选中':'复制';
  $('insertResult').disabled=!ready || !targetValid();
  $('insertLabel').textContent=selected?'插入选中':mode==='ask'?'插入回答':'结果上屏';
  $('insertSource').hidden=mode!=='transform';
  $('insertSource').disabled=!s.source.trim() || !!pending || composing || !targetValid();
  $('selectionHint').textContent=selected?`已选 ${selected.length} 字 · 只插入这一部分`:'划选想用的部分，也可以直接修改回答';
  $('selectionBar').classList.toggle('selected',!!selected);
  $('clearSelection').hidden=!selected;
  $('followInput').disabled=!ready;
  $('followButton').disabled=!ready || !$('followInput').value.trim();
  $('shorten').disabled=!ready;
  $('resultBadge').textContent=pending?'处理中':s.stale?'输入已变化':'演示示例';
  $('result').readOnly=!!pending;
  $('destinationHint').textContent=targetValid()?'保留原光标位置 · 不会发送消息':'输入位置已变化 · 在原框重新唤起即可绑定';
  $('requestCount').textContent=`本次演示调用：${requests}`;
}
function renderVersions() {
  const s=session(); $('version').replaceChildren();
  s.versions.forEach((v,i)=>{const o=document.createElement('option');o.value=String(i);o.textContent=`${i+1} · ${v.label}`;o.selected=i===s.selectedVersion;$('version').append(o);});
  $('version').hidden=s.versions.length<2;
}
function render() {
  const s=session(); selected='';
  try { localStorage.setItem('fangcun-ai-selection-v1',JSON.stringify({actionId})); } catch {}
  updateDemoButtons();
  $('askTab').setAttribute('aria-selected',String(mode==='ask'));
  $('transformTab').setAttribute('aria-selected',String(mode==='transform'));
  $('workArea').setAttribute('aria-labelledby',mode==='ask'?'askTab':'transformTab');
  $('actionButton').hidden=mode==='ask'; $('toolbarHint').hidden=mode!=='ask';
  $('actionName').textContent=action().name;
  $('manageAction').querySelector('span').textContent=mode==='transform'?'编辑动作':'自定义动作';
  $('sourceTitle').textContent=mode==='ask'?'想让 AI 帮你做什么？':'要处理的文字';
  $('sourceSubtitle').textContent=mode==='ask'?'一句问题，也可以是一件具体的事。':action().description || '按你保存的特殊指令处理';
  $('source').value=s.source; $('source').placeholder=mode==='ask'?'问个问题，或描述你想完成的事…':'输入或粘贴想要处理的文字…';
  $('reference').value=s.reference; $('referenceDetails').hidden=mode!=='ask';
  $('resultTitle').textContent=mode==='ask'?'AI 的回答':'处理结果';
  $('result').value=s.result;
  $('emptyState').hidden=!!s.result;
  $('result').hidden=!s.result;
  $('emptyTitle').textContent=mode==='ask'?'先说说你在想什么':'你的文字，还有别的可能';
  $('emptyDescription').textContent=mode==='ask'?'主动问一次，才会得到回答。内容可以修改、复制，或直接插入。':'选一个动作，结果会出现在这里。你确认之前，原输入框保持原样。';
  $('followContext').querySelector('span').textContent='追问沿用本次对话';
  $('followInput').value='';
  renderVersions(); updateControls(); icons();
}
function stopRequest(notify=true) { if (!pending) return; clearTimeout(pending.timer); pending=null; render(); if(notify) status('已停止。输入和已有结果都保留，可以修改后再试。'); }
function switchMode(next) { syncSource(); stopRequest(false); closePicker(); mode=next; render(); status(session().result?'可以修改、复制或插入结果。':'内容准备好后再执行，输入和切换动作都不会调用 AI。'); }
function setView(next, bind=false) {
  if(view==='compact' && next==='expanded') syncCompact();
  if(bind) captureAnchor(); view=next;
  updateDemoButtons();
  $('editor').hidden=next!=='expanded'; $('compact').hidden=next!=='compact'; $('resume').hidden=next!=='hidden';
  if(next==='expanded') {$('source').value=session().source;updateControls();$('source').focus();}
  if(next==='compact') {$('compactDraft').value=session().source;$('compactDraft').focus();}
}
function updateDemoButtons(){
  const active=view==='compact'?'compact':mode==='ask'?'ask':actionId;
  document.querySelectorAll('[data-demo]').forEach(b=>b.classList.toggle('active',b.dataset.demo===active));
}
function syncCompact(){
  if(session().source===$('compactDraft').value)return;
  stopRequest(false);session().source=$('compactDraft').value;session().stale=!!session().result;
  status(session().stale?'草稿已修改，请重新执行后再使用结果。':'草稿已保留，准备好后再执行。',session().stale);
}
function setAction(id, demo=false) {
  syncSource(); stopRequest(false); mode='transform'; actionId=id;
  const s=session(); s.result='';s.versions=[];s.stale=false;
  if(demo) s.source=samples[id] || samples.german;
  closePicker();render();status('按你的规则处理；只有点击“执行动作”才调用 AI。');
}
function showPicker() {
  $('actionPicker').hidden=false;$('actionButton').setAttribute('aria-expanded','true');$('actionSearch').value='';renderActions();$('actionSearch').focus();
}
function closePicker(){ $('actionPicker').hidden=true;$('actionButton').setAttribute('aria-expanded','false'); }
function renderActions(){
  const q=$('actionSearch').value.replace(/^\//,'').toLowerCase().trim(); const list=$('actionList');list.replaceChildren();
  allActions().filter(a=>(a.name+' '+a.key).toLowerCase().includes(q)).forEach(a=>{
    const b=document.createElement('button');b.className='picker-item'+(a.id===actionId?' selected':'');b.type='button';b.append(icon(a.symbol||'wand-sparkles'));
    const text=document.createElement('span'),name=document.createElement('strong'),desc=document.createElement('small');name.textContent=a.name;desc.textContent=a.description||'我的自定义指令';text.append(name,desc);b.append(text);
    if(a.key){const key=document.createElement('kbd');key.textContent='/'+a.key;b.append(key);} b.onclick=()=>setAction(a.id);list.append(b);
  });
  if(!list.childElementCount){const p=document.createElement('p');p.className='picker-label';p.textContent='还没有这个动作，可以新建一个。';list.append(p);}
  icons();
}
function mockAnswer(snapshot, follow) {
  if(follow){
    if (follow==='帮我缩成一句话' && snapshot.result===answers.ask) return '周六一起去海边吧，喝咖啡、散散步，再等一场日落，不赶时间。';
    return `【追问交互示例，未调用模型】\n\n你刚才问：${follow}\n\n正式版本会结合本次输入和所选回答继续处理。这里可以直接编辑成你想要的文字，再试试复制或插入。`;
  }
  if(mode==='ask' && snapshot.source===samples.ask && !snapshot.reference.trim()) return answers.ask;
  if(mode==='transform' && !actionId.startsWith('custom-')) {
    const expected=actionId==='english'?samples.german:samples[actionId];
    if(snapshot.source===expected) return answers[actionId];
  }
  return `【交互示例，未调用模型】\n\n${mode==='ask'?'你的问题已准备好。':`将按「${action().name}」处理输入。`}\n\n这里会显示实际生成的结果。此原型只对内置样例提供固定演示内容，不会真正翻译或提取你输入的文字。\n\n你可以修改这段结果，体验选中、复制和上屏。`;
}
function run(follow='') {
  if(composing) return;
  if(pending){stopRequest();return;}
  syncSource(); const s=session(); if(!s.source.trim() || (follow && (!s.result || s.stale))) return;
  const snapshot={...s}; selected='';requests++;
  const simulatedFailure=failNext;failNext=false;
  $('emptyState').hidden=false;$('result').hidden=true;
  $('emptyTitle').textContent=follow?'接着想一想…':mode==='ask'?'想一想，再写好…':'正在处理这段文字…';
  $('emptyDescription').textContent='这次只执行一个动作，可以随时停止。';
  status(follow?`追问：${follow}`:'本次处理已开始。结果不会自动进入原输入框。');
  pending={timer:setTimeout(()=>{
    pending=null;
    if(simulatedFailure){render();status('这次没能得到结果。内容已保留，点击执行按钮可重试。',true);toast('模拟请求失败，未自动重试');return;}
    const output=mockAnswer(snapshot,follow);
    s.result=output;s.stale=false;
    if(!follow) s.versions=[];
    s.versions.push({text:output,question:follow||snapshot.source,label:follow?'追问回答':'初次回答'});
    s.selectedVersion=s.versions.length-1;
    render();status(follow?`已按“${follow}”继续处理（演示）。可从右上角回看之前的回答。`:'结果准备好了。可直接修改，或划选一段再插入。');
  },850)};
  updateControls();
}
function markChanged(){
  syncSource(); stopRequest(false); selected=''; session().stale=!!session().result;
  if(session().stale)status('输入已修改，右侧保留旧结果。请主动重新执行后再上屏。',true);
  else status('完成输入后再执行。空格选词和换行都不会调用 AI。');
  updateControls();
}
async function copyResult(){
  const text=selected||session().result;if(!text)return;
  try{await navigator.clipboard.writeText(text);toast(selected?'选中的文字已复制':'结果已复制');}
  catch{status('浏览器未允许直接复制。请在结果中选中文字后按 ⌘C。',true);}
}
function insert(kind='result'){
  if(pending||composing)return;const s=session();const text=kind==='source'?s.source:selected||s.result;
  if(!text.trim()||(kind==='result'&&s.stale))return;
  if(!targetValid()){status('原输入位置已变化。请在原输入框定位光标，再点“唤起方寸”。',true);return;}
  const field=$('hostInput'),previous={...anchor},after=anchor.value.slice(0,anchor.start)+text+anchor.value.slice(anchor.end);
  field.value=after;const caret=anchor.start+text.length;field.setSelectionRange(caret,caret);lastInsert={previous,after};
  $('hostState').textContent=`已插入 ${text.length} 字 · 未发送`;$('resumeText').textContent='内容已插入，草稿仍保留';$('undoInsert').hidden=false;
  setView('hidden');field.focus();captureAnchor();toast(`已插入${selected?'选中的':''} ${text.length} 字，未发送消息`);
}
function openActionDialog(existing=null){
  closePicker();editingAction=existing?.id?.startsWith('custom-')?existing.id:null;
  $('dialogTitle').textContent=existing?'把这个动作调成你的习惯':'给 AI 一个固定的拿手活';
  $('customName').value=existing?(editingAction?existing.name:existing.name+' · 我的'):'';
  $('customKey').value=editingAction?existing.key:'';
  $('customPrompt').value=existing?.prompt||'';$('formError').textContent='';$('actionDialog').showModal();
}
function saveAction(e){
  e.preventDefault();const name=$('customName').value.trim(),key=$('customKey').value.trim().toLowerCase();
  if(!name){$('formError').textContent='给动作起一个名字。';return;}
  if(key&&allActions().some(a=>a.key.toLowerCase()===key&&a.id!==editingAction)){$('formError').textContent='这个快捷名称已经在用了，请换一个。';return;}
  const a={id:editingAction||'custom-'+Date.now(),name,key,prompt:$('customPrompt').value.trim(),symbol:'wand-sparkles',description:'我的自定义指令'};
  if(editingAction)customActions=customActions.map(x=>x.id===editingAction?a:x);else customActions.push(a);
  let persisted=true;try{localStorage.setItem('fangcun-ai-actions-v1',JSON.stringify(customActions));}catch{persisted=false;}
  $('actionDialog').close();setAction(a.id);setView('expanded');toast(persisted?'动作已保存；选择后可反复使用':'已在本页保存，浏览器不允许持久保存');
}
function loadDemo(type){
  stopRequest(false);closePicker();syncSource();
  captureAnchor();
  if(type==='compact'){setView('compact');$('compactDraft').value='周末去海边，怎么安排轻松一点？';return;}
  mode=type==='ask'?'ask':'transform';
  if(mode==='ask'){sessions.ask=initialSession(samples.ask);sessions.ask.result=answers.ask;sessions.ask.versions=[{text:answers.ask,question:samples.ask,label:'初次回答'}];}
  else {actionId=type;sessions.transform=initialSession(samples[type] || samples.german);}
  render();setView('expanded');
  status(mode==='ask'?'这是一条示例回答。选中其中一句，试试只插入需要的部分。':'这是内置体验样例。点击“执行动作”查看处理结果。');
}
$('askTab').onclick=()=>switchMode('ask');$('transformTab').onclick=()=>switchMode('transform');
$('actionButton').onclick=()=> $('actionPicker').hidden?showPicker():closePicker();
$('actionSearch').oninput=renderActions;
$('actionSearch').onkeydown=e=>{if(e.key==='Enter'){e.preventDefault();$('actionList').querySelector('button')?.click();}};
document.addEventListener('click',e=>{if(!e.target.closest('.action-wrap'))closePicker();});
$('newAction').onclick=()=>openActionDialog();$('manageAction').onclick=()=>openActionDialog(mode==='transform'?action():null);
$('closeAction').onclick=$('cancelAction').onclick=()=>$('actionDialog').close();$('actionForm').onsubmit=saveAction;
document.querySelectorAll('[data-preset]').forEach(b=>b.onclick=()=>{const a=builtins.find(x=>x.id===b.dataset.preset);$('customName').value=a.name;$('customPrompt').value=a.prompt;$('customKey').value=a.key+'2';});
$('run').onclick=()=>run();$('source').oninput=markChanged;$('reference').oninput=markChanged;
$('clearSource').onclick=()=>{$('source').value='';markChanged();$('source').focus();};
$('pasteSource').onclick=async()=>{try{const text=await navigator.clipboard.readText();if(!text){toast('剪贴板里没有文字');return;}$('source').setRangeText(text,$('source').selectionStart,$('source').selectionEnd,'end');markChanged();$('source').focus();}catch{toast('请在左侧编辑区按 ⌘V 粘贴');$('source').focus();}};
$('result').oninput=()=>{selected='';session().result=$('result').value;const v=session().versions[session().selectedVersion];if(v)v.text=session().result;updateControls();};
$('result').addEventListener('select',()=>{selected=$('result').value.slice($('result').selectionStart,$('result').selectionEnd);updateControls();});
$('clearSelection').onclick=clearSelected;$('copyResult').onclick=copyResult;
$('version').onchange=()=>{const s=session();s.selectedVersion=Number($('version').value);s.result=s.versions[s.selectedVersion].text;render();status(`正在查看第 ${s.selectedVersion+1} 版。后续追问会以这一版为基础。`);};
$('followForm').onsubmit=e=>{e.preventDefault();if($('followInput').value.trim())run($('followInput').value.trim());};
$('followInput').oninput=updateControls;$('shorten').onclick=()=>run('帮我缩成一句话');
$('insertResult').onclick=()=>insert();$('insertSource').onclick=()=>insert('source');
$('compactButton').onclick=()=>{syncSource();setView('compact');};
$('hideButton').onclick=()=>{syncSource();setView('hidden');$('resumeText').textContent='内容已保留，随时回来继续';};
$('wideButton').onclick=()=>{const wide=$('editor').classList.toggle('wide');$('wideButton').setAttribute('aria-pressed',String(wide));};
$('openHost').onclick=$('resumeButton').onclick=()=>setView('expanded',true);
$('expandButton').onclick=()=>setView('expanded');
$('compactAsk').onclick=()=>{stopRequest(false);mode='ask';sessions.ask=initialSession($('compactDraft').value);render();setView('expanded');status('继续写清楚你的问题，再按 ⌃Enter 提问。');};
$('compactTransform').onclick=e=>{e.stopPropagation();stopRequest(false);mode='transform';sessions.transform=initialSession($('compactDraft').value);render();setView('expanded');status('选择一个动作，再主动执行。原输入框里的文字保持原样。');showPicker();};
$('compactDraft').oninput=syncCompact;
$('hostInput').oninput=()=>{$('hostState').textContent='原输入框已编辑';$('undoInsert').hidden=true;updateControls();};
$('hostInput').addEventListener('select',updateControls);
$('undoInsert').onclick=()=>{if(!lastInsert||$('hostInput').value!==lastInsert.after){toast('原输入框已有新内容，保留当前文字');return;}const p=lastInsert.previous;$('hostInput').value=p.value;$('hostInput').focus();$('hostInput').setSelectionRange(p.start,p.end);lastInsert=null;captureAnchor();$('undoInsert').hidden=true;$('hostState').textContent='已撤销插入';toast('这次插入已撤销');};
document.querySelectorAll('[data-demo]').forEach(b=>b.onclick=()=>loadDemo(b.dataset.demo));
$('guideButton').onclick=()=>{$('guideDialog').showModal();updateControls();};$('closeGuide').onclick=()=>$('guideDialog').close();
$('failNext').onclick=()=>{failNext=true;$('guideDialog').close();toast('下一次主动请求将演示失败状态');};
document.addEventListener('compositionstart',()=>{composing=true;updateControls();});
document.addEventListener('compositionend',()=>{composing=false;updateControls();});
document.addEventListener('keydown',e=>{
  if(e.isComposing||composing||e.keyCode===229)return;
  if($('actionDialog').open||$('guideDialog').open)return;
  if(e.key==='Escape') {e.preventDefault();if(!$('actionPicker').hidden){closePicker();$('actionButton').focus();}else if(view!=='hidden')setView('hidden');return;}
  if(e.key==='Enter'&&e.ctrlKey&&e.shiftKey){e.preventDefault();setView(view==='expanded'?'hidden':'expanded',view!=='expanded');return;}
  if(view!=='expanded')return;
  if(e.key==='Enter'&&e.metaKey){e.preventDefault();if(e.shiftKey){if(mode==='transform')insert('source');}else insert();return;}
  if(e.key==='Enter'&&e.ctrlKey){e.preventDefault();if(e.target===$('followInput')){if($('followInput').value.trim())run($('followInput').value.trim());}else run();}
});
$('hostInput').setSelectionRange($('hostInput').value.length,$('hostInput').value.length);
captureAnchor();render();
status(mode==='ask'?'这是一条示例回答。选中其中一句，试试只插入需要的部分。':`当前动作：${action().name}。按 Ctrl＋Enter 或点击“执行动作”后才会处理。`);
if(location.hash==='#compact')loadDemo('compact');else if(location.hash==='#transform')loadDemo('english');
