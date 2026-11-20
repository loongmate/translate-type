'use strict';
const $ = id => document.getElementById(id);
const seed = `# 给想法一点空间

有些想法，值得先记下来。
不必急着整理，也不必立刻有答案。

## 这周，想做的几件事

- [x] 记录那些一闪而过的灵感
- [ ] 把零散的笔记整理成文章
- [ ] 留一个下午，专心做点喜欢的事

## 一个小小的约定

先写下来，再慢慢变好。
让工具轻一点，让表达自由一点。

> 方寸之间，也能装下很多可能。

---

**随手记录，自在表达。**`;
const samples = {
  markdown: seed,
  html: '<!doctype html>\n<html lang="zh-CN">\n<head>\n  <meta charset="utf-8">\n  <style>\n    body { font-family: system-ui; padding: 24px; color: #51445f; }\n    h1 { color: #7960bb; font-size: 26px; }\n    p { line-height: 1.9; color: #807489; }\n  </style>\n</head>\n<body>\n  <h1>方寸之间</h1>\n  <p>让工具轻一点，让表达自由一点。</p>\n</body>\n</html>',
  json: '{\n  "name": "方寸",\n  "description": "随手记录，自在表达",\n  "features": [\n    "即时预览",\n    "临时草稿",\n    "问问 AI"\n  ],\n  "quiet": true\n}',
  text: '给想法一点空间\n\n有些想法，值得先记下来。\n不必急着整理，也不必立刻有答案。\n\n这周，想做的几件事\n\n记录那些一闪而过的灵感\n把零散的笔记整理成文章\n留一个下午，专心做点喜欢的事\n\n先写下来，再慢慢变好。'
};
let format = 'markdown', page = 'editor', activeChat = 'plan', reference = '', timer, generation = 0;
let fileName = '随手记.md', currentAnswer = '', selectedAnswer = '';
const drafts = {...samples};
const storeKey = 'fangcun-redesign-scratchpad-v1';
const titles = { plan: '整理这周的想法', email: '帮我写一封回复', code: '读懂这段代码', fresh: '新对话' };
const conversations = {
  plan: [{role:'user', text:'帮我把这周零散的想法整理一下，变成一份清晰的行动清单。'}, {role:'assistant', kind:'plan', text:'这周的行动清单\n\n1. 收集灵感：随手记下想到的句子，不急着分类。\n2. 整理笔记：挑一个最想展开的主题，列出文章大纲。\n3. 留出时间：为喜欢的事情留一个不被打扰的下午。\n\n不用一次完成，先做最想做的那一件。', tools:true}],
  email: [{role:'user', text:'朋友约我周六一起去看展，但我那天有安排。帮我写一句自然的回复。'}, {role:'assistant', text:'好想去！不过周六已经有安排了，这次可能赶不上。你们看完跟我分享一下，下次有好展再一起呀。'}],
  code: [{role:'user', text:'这句 JavaScript 是什么意思？\nconst unique = [...new Set(items)];'}, {role:'assistant', text:'这句代码会去掉 items 里的重复值。\n\nnew Set(items) 把数组转换为集合，集合只保留每个值的第一次出现。\n\n外面的 [... ] 再把集合转换回数组。例如 [1, 2, 2, 3] 会得到 [1, 2, 3]。\n\n对于对象，Set 比较的是引用；两个内容一样的独立对象仍会保留。'}],
  fresh: []
};
const chatDrafts = {};
function icons(){window.lucide?.createIcons();}
function notify(message){clearTimeout(timer);$('toast').textContent=message;$('toast').hidden=false;timer=setTimeout(()=>$('toast').hidden=true,3200);}
function escapeHTML(text){return text.replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));}
function inline(text){return escapeHTML(text).replace(/`([^`]+)`/g,'<code>$1</code>').replace(/\*\*([^*]+)\*\*/g,'<strong>$1</strong>');}
// A deliberately small, escaped Markdown renderer for the local design prototype.
function markdown(text){
  let result='', list=false, code=false, codeText=[];
  for(const line of text.split('\n')){
    if(line.startsWith('```')){if(code){result+='<pre><code>'+escapeHTML(codeText.join('\n'))+'</code></pre>';codeText=[];}else if(list){result+='</ul>';list=false;}code=!code;continue;}
    if(code){codeText.push(line);continue;}
    const item=line.match(/^- (.*)$/);
    if(item){if(!list){result+='<ul>';list=true;}const check=item[1].match(/^\[([ xX])\] (.*)$/);result+=check?'<li class="checkline"><input type="checkbox" disabled '+(check[1].toLowerCase()==='x'?'checked':'')+'>'+inline(check[2])+'</li>':'<li>'+inline(item[1])+'</li>';continue;}
    if(list){result+='</ul>';list=false;}
    const heading=line.match(/^(#{1,3}) (.*)$/);
    if(heading){result+='<h'+heading[1].length+'>'+inline(heading[2])+'</h'+heading[1].length+'>';continue;}
    if(line.startsWith('> ')){result+='<blockquote>'+inline(line.slice(2))+'</blockquote>';continue;}
    if(/^---+$/.test(line)){result+='<hr style="border:0;border-top:1px solid var(--line);margin:23px 0">';continue;}
    if(line.trim()){result+='<p>'+inline(line)+'</p>';}
  }
  if(list)result+='</ul>';if(codeText.length)result+='<pre><code>'+escapeHTML(codeText.join('\n'))+'</code></pre>';
  return result;
}
function updatePreview(){
  const text=$('source').value;
  $('highlight').innerHTML=text.split('\n').map(line=>{
    const value=escapeHTML(line);
    if(format!=='markdown')return value;
    if(/^#{1,3} /.test(line))return '<span class="md-heading">'+value+'</span>';
    if(line.startsWith('> '))return '<span class="md-quote">'+value+'</span>';
    return value.replace(/^(- )(\[[ xX]\])?/,'<span class="md-mark">$1$2</span>').replace(/(\*\*[^*]+\*\*)/g,'<span class="md-heading">$1</span>');
  }).join('\n')+'\n';
  $('lineNumbers').textContent=text.split('\n').map((_,index)=>index+1).join('\n');
  $('characterCount').textContent=Array.from(text).length+' 字';
  if(format==='markdown')$('rendered').innerHTML=markdown(text);
  else if(format==='html'){
    const frame=document.createElement('iframe');frame.title='HTML 预览';frame.setAttribute('sandbox','');frame.referrerPolicy='no-referrer';
    frame.srcdoc='<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'unsafe-inline\'; img-src data:; form-action \'none\'; base-uri \'none\'">'+text;
    $('rendered').replaceChildren(frame);
  }else{
    const pre=document.createElement('pre');
    if(format==='json'){try{pre.textContent=JSON.stringify(JSON.parse(text),null,2);}catch(error){pre.textContent='JSON 格式有误\n\n'+error.message;}}
    else pre.textContent=text;
    $('rendered').replaceChildren(pre);
  }
  updateCursor();syncScroll();
}
function updateCursor(){const prefix=$('source').value.slice(0,$('source').selectionStart).split('\n');$('cursorPosition').textContent='第 '+prefix.length+' 行，第 '+(Array.from(prefix.at(-1)).length+1)+' 列';}
function syncScroll(){$('highlight').scrollTop=$('source').scrollTop;$('highlight').scrollLeft=$('source').scrollLeft;$('lineNumbers').scrollTop=$('source').scrollTop;}
function persist(){drafts[format]=$('source').value;try{localStorage.setItem(storeKey,JSON.stringify({drafts,format,fileName}));$('saveState').innerHTML='<i data-lucide="check"></i>草稿已保存';}catch{$('saveState').textContent='请另存草稿';}icons();}
function switchPage(next){
  page=next==='ai'?'ai':'editor';$('editorPage').hidden=page!=='editor';$('aiPage').hidden=page!=='ai';
  document.querySelectorAll('[data-page]').forEach(button=>button.setAttribute('aria-pressed',String(button.dataset.page===page)));
  $('windowTitle').textContent=page==='editor'?'临时编辑器':'问问 AI';$('saveState').hidden=page==='ai';
  $('screenNumber').textContent=page==='editor'?'01 / SCRATCHPAD':'02 / ASK FANGCUN';
  $('headline').textContent=page==='editor'?'给想法，一点舒展的空间。':'想做什么，聊聊就好。';
  $('description').textContent=page==='editor'?'随手记下，即时预览。一个安静、轻巧的临时编辑器。':'从一个问题到一件小事，把思路和行动自然接在一起。';
  $('designNote').textContent=page==='editor'?'更少的边框，更好的留白。让编辑与阅读各得其所。':'让对话成为主角。把复杂的执行过程，收在需要时展开的细节里。';
  history.replaceState(null,'','#'+page);if(page==='ai')renderChat();
}
function answerMarkup(message){
  if(message.kind==='plan')return '<h3>这周的行动清单</h3><ul><li><strong>收集灵感</strong>：随手记下想到的句子，不急着分类。</li><li><strong>整理笔记</strong>：挑一个最想展开的主题，列出文章大纲。</li><li><strong>留出时间</strong>：为喜欢的事情留一个不被打扰的下午。</li></ul><p>不用一次完成，先做最想做的那一件。</p>';
  return escapeHTML(message.text);
}
function renderChat(){
  $('messages').replaceChildren();currentAnswer='';selectedAnswer='';
  $('chatTitle').textContent=titles[activeChat];$('chatInput').value=chatDrafts[activeChat]||'';
  const messages=conversations[activeChat];
  if(!messages.length)$('messages').innerHTML='<div class="empty-chat"><span class="empty-icon"><i data-lucide="sparkles"></i></span><h2>今天，想一起做点什么？</h2><p>问一个问题，理清一些想法，或处理手边的小事。<br>从你需要的地方开始。</p></div>';
  for(const message of messages){
    const element=document.createElement('div');element.className=message.role==='user'?'message-user':'message-assistant';
    if(message.role==='user')element.textContent=message.text;
    else{
      const index=messages.indexOf(message);
      element.innerHTML='<div class="assistant-label"><span class="ai-avatar"><i data-lucide="sparkles"></i></span>方寸<span class="message-time">演示回答</span></div>'+(message.tools?'<details class="tool-activity"><summary><i data-lucide="circle-check"></i>已整理参考笔记<span>· 2 个步骤</span><i data-lucide="chevron-right"></i></summary><div class="tool-log">演示执行记录 · 未读取或修改真实文件\n✓ read_file  本周想法.md\n✓ 整理主题与行动项\n完成 · 0.8 秒</div></details>':'')+'<div class="answer-body">'+answerMarkup(message)+'</div><div class="answer-actions"><button class="text-button" data-copy-answer="'+index+'"><i data-lucide="copy"></i>复制</button><button class="text-button" data-use-answer="'+index+'"><i data-lucide="corner-down-left"></i>插入</button></div>';
      currentAnswer=message.text;
    }
    $('messages').append(element);
  }
  document.querySelectorAll('[data-chat]').forEach(button=>button.classList.toggle('active',button.dataset.chat===activeChat));
  $('insertAnswer').disabled=!currentAnswer;$('send').disabled=!$('chatInput').value.trim();icons();
}
function stopGeneration(){generation++;document.querySelector('.pending')?.remove();$('send').hidden=false;$('stop').hidden=true;$('send').disabled=!$('chatInput').value.trim();}
function chooseChat(key){chatDrafts[activeChat]=$('chatInput').value;stopGeneration();activeChat=key;reference='';$('attach').innerHTML='<i data-lucide="paperclip"></i>参考文字';renderChat();}
function insertAnswer(text){if(!text)return;$('insertTarget').value=text;$('insertDialog').showModal();}
async function copy(text){try{await navigator.clipboard.writeText(text);notify('已复制');}catch{notify('浏览器未允许复制，请选中文字后按 ⌘C。');}}
function sendMessage(){
  const text=$('chatInput').value.trim();if(!text||!$('stop').hidden)return;
  const withReference=reference?text+'\n\n参考文字：\n'+reference:text;
  const hasReference=Boolean(reference);
  conversations[activeChat].push({role:'user',text:withReference});chatDrafts[activeChat]='';
  if(activeChat==='fresh'){titles.fresh=text.slice(0,18);}
  reference='';$('attach').innerHTML='<i data-lucide="paperclip"></i>参考文字';renderChat();
  const pending=document.createElement('div');pending.className='pending';pending.setAttribute('role','status');pending.textContent='方寸正在整理思路…';$('messages').append(pending);
  $('send').hidden=true;$('stop').hidden=false;$('chatScroll').scrollTop=$('chatScroll').scrollHeight;
  const ticket=++generation;
  setTimeout(()=>{
    if(ticket!==generation)return;
    const isPlan=/待办|想法|清单|整理这周/.test(text)&&!hasReference;
    let message;
    if(isPlan)message={...conversations.plan.find(item=>item.role==='assistant'),tools:false};
    else if(!hasReference&&text==='帮我写一封自然、简洁的邮件回复')message={role:'assistant',text:'以下是邮件语气的演示示例：\n\n你好，感谢你的消息！我会先看一下相关资料，整理好后再回复你。有需要补充的内容，也欢迎随时告诉我。\n\n祝好！'};
    else if(!hasReference&&text==='解释这段代码的思路')message={role:'assistant',text:'把代码粘贴到“参考文字”里，就可以在正式版本中解释它的逻辑、输入输出和容易出错的地方。\n\n此处是 HTML 设计原型，没有连接模型。'};
    else message={role:'assistant',text:'已收到你的'+(hasReference?'问题和参考文字':'消息')+'。\n\n这是界面交互演示，未连接 AI 模型，也不会操作文件或运行命令。正式接入后，回答会显示在这里，并支持复制、选取和插入。'};
    conversations[activeChat].push(message);pending.remove();$('send').hidden=false;$('stop').hidden=true;chatDrafts[activeChat]=$('chatInput').value;renderChat();$('chatScroll').scrollTop=$('chatScroll').scrollHeight;
  },850);
}
document.querySelectorAll('[data-page]').forEach(button=>button.onclick=()=>switchPage(button.dataset.page));
document.querySelectorAll('[data-chat]').forEach(button=>button.onclick=()=>chooseChat(button.dataset.chat));
document.querySelectorAll('[data-prompt]').forEach(button=>button.onclick=()=>{$('chatInput').value=button.dataset.prompt;chatDrafts[activeChat]=$('chatInput').value;$('send').disabled=false;$('chatInput').focus();});
$('theme').onclick=()=>{const dark=document.body.classList.toggle('dark');$('theme').setAttribute('aria-label',dark?'切换浅色外观':'切换深色外观');$('theme').title=dark?'切换浅色外观':'切换深色外观';$('theme').innerHTML='<i data-lucide="'+(dark?'sun':'moon')+'"></i>';icons();};
$('focus').onclick=()=>{const focused=document.body.classList.toggle('focused');$('focus').setAttribute('aria-label',focused?'退出专注视图':'切换专注视图');$('focus').title=focused?'退出专注视图':'切换专注视图';};
$('source').addEventListener('input',()=>{updatePreview();persist();if(!$('findBar').hidden)findText(false);});
['click','keyup','select'].forEach(event=>$('source').addEventListener(event,updateCursor));
$('source').addEventListener('scroll',syncScroll);
$('source').addEventListener('keydown',event=>{if(event.isComposing||event.keyCode===229)return;if(event.key==='Tab'){event.preventDefault();const textarea=$('source');textarea.setRangeText('  ',textarea.selectionStart,textarea.selectionEnd,'end');updatePreview();persist();}});
$('format').onchange=()=>{drafts[format]=$('source').value;format=$('format').value;$('source').value=drafts[format];fileName='随手记.'+({markdown:'md',html:'html',json:'json',text:'txt'}[format]);$('filename').textContent=fileName;updatePreview();persist();};
$('togglePreview').onclick=()=>{const visible=$('previewPane').hidden;$('previewPane').hidden=!visible;$('editorSplit').classList.toggle('no-preview',!visible);$('togglePreview').setAttribute('aria-pressed',String(visible));};
$('copySource').onclick=()=>{const source=$('source');copy(source.selectionStart!==source.selectionEnd?source.value.slice(source.selectionStart,source.selectionEnd):source.value);};
$('open').onclick=()=>$('fileInput').click();
$('fileInput').onchange=async()=>{const file=$('fileInput').files[0];if(!file)return;if(file.size>2_000_000){notify('请选择 2 MB 以内的文本文件。');return;}try{const content=await file.text();if(content.includes('\0')){notify('请选择 UTF-8 文本文件。');return;}drafts[format]=$('source').value;format=/\.html?$/i.test(file.name)?'html':/\.json$/i.test(file.name)?'json':/\.md|\.markdown$/i.test(file.name)?'markdown':'text';fileName=file.name;$('filename').textContent=fileName;$('format').value=format;$('source').value=content;updatePreview();persist();notify('已作为临时草稿打开');}catch{notify('文件读取失败，请重试。');}$('fileInput').value='';};
$('save').onclick=()=>{const blob=new Blob([$('source').value],{type:'text/plain;charset=utf-8'});const url=URL.createObjectURL(blob);const link=document.createElement('a');link.href=url;link.download=fileName;link.click();setTimeout(()=>URL.revokeObjectURL(url),1000);};
let lastMatch=-1;
function findText(advance=true){const needle=$('findInput').value;const text=$('source').value;if(!needle){$('findCount').textContent='';lastMatch=-1;return;}let hits=0,index=-1;while((index=text.indexOf(needle,index+1))!==-1)hits++;$('findCount').textContent=hits+' 处匹配';if(!advance)return;let next=text.indexOf(needle,lastMatch+1);if(next<0)next=text.indexOf(needle);if(next<0)return;lastMatch=next;$('source').focus();$('source').setSelectionRange(next,next+needle.length);$('source').scrollTop=Math.max(0,(text.slice(0,next).split('\n').length-3)*26);syncScroll();updateCursor();}
$('find').onclick=()=>{$('findBar').hidden=!$('findBar').hidden;if(!$('findBar').hidden)$('findInput').focus();};
$('closeFind').onclick=()=>{$('findBar').hidden=true;$('source').focus();};
$('findInput').oninput=()=>{lastMatch=-1;findText(false);};$('findNext').onclick=()=>findText();
$('findInput').onkeydown=event=>{if(event.key==='Enter'){event.preventDefault();findText();}};
$('newChat').onclick=()=>{chooseChat('fresh');conversations.fresh=[];titles.fresh='新对话';chatDrafts.fresh='';renderChat();$('chatInput').focus();};
$('chatForm').onsubmit=event=>{event.preventDefault();sendMessage();};
$('chatInput').oninput=()=>{chatDrafts[activeChat]=$('chatInput').value;$('send').disabled=!$('chatInput').value.trim();};
$('stop').onclick=()=>{stopGeneration();notify('已停止，消息与草稿仍保留');};
$('messages').onclick=event=>{const copyButton=event.target.closest('[data-copy-answer]');const insertButton=event.target.closest('[data-use-answer]');if(copyButton)copy(conversations[activeChat][Number(copyButton.dataset.copyAnswer)].text);if(insertButton)insertAnswer(conversations[activeChat][Number(insertButton.dataset.useAnswer)].text);};
document.addEventListener('selectionchange',()=>{const selection=window.getSelection();selectedAnswer='';if(selection&&!selection.isCollapsed&&selection.rangeCount){const range=selection.getRangeAt(0);const start=range.startContainer.parentElement?.closest('.answer-body');const end=range.endContainer.parentElement?.closest('.answer-body');if(start&&start===end)selectedAnswer=selection.toString();}$('insertAnswer').innerHTML='<i data-lucide="corner-down-left"></i>'+(selectedAnswer?'插入选中文字':'插入回答')+' <kbd>⌘ ↵</kbd>';icons();});
$('insertAnswer').onclick=()=>insertAnswer(selectedAnswer||currentAnswer);
$('closeInsert').onclick=()=>$('insertDialog').close();$('finishInsert').onclick=()=>$('insertDialog').close();
$('attach').onclick=()=>{$('reference').value=reference;$('referenceDialog').showModal();};$('closeReference').onclick=()=>$('referenceDialog').close();
$('referenceForm').onsubmit=event=>{event.preventDefault();reference=$('reference').value.trim();$('attach').innerHTML='<i data-lucide="paperclip"></i>'+(reference?'已附参考 · '+reference.length+' 字':'参考文字');icons();$('referenceDialog').close();};
$('directory').onclick=()=>$('directoryDialog').showModal();$('closeDirectory').onclick=()=>$('directoryDialog').close();
$('directoryForm').onsubmit=event=>{event.preventDefault();const name=$('directoryInput').value.trim();if(!name)return;$('directoryName').textContent=name;$('directoryDialog').close();notify('已切换演示目录');};
document.addEventListener('keydown',event=>{
  if(event.isComposing||event.keyCode===229||event.repeat)return;
  if(document.querySelector('dialog[open]'))return;
  if(event.key==='Escape'){if(!$('findBar').hidden)$('closeFind').click();else if(document.body.classList.contains('focused'))$('focus').click();return;}
  if((event.metaKey||event.ctrlKey)&&event.key.toLowerCase()==='f'&&page==='editor'){event.preventDefault();$('findBar').hidden=false;$('findInput').focus();}
  if(event.metaKey&&event.key.toLowerCase()==='s'&&page==='editor'){event.preventDefault();$('save').click();}
  if(event.metaKey&&event.key.toLowerCase()==='o'&&page==='editor'){event.preventDefault();$('open').click();}
  if(event.metaKey&&event.shiftKey&&event.key.toLowerCase()==='p'&&page==='editor'){event.preventDefault();$('togglePreview').click();}
  if(event.metaKey&&event.key.toLowerCase()==='n'&&page==='ai'){event.preventDefault();$('newChat').click();}
  if(event.ctrlKey&&!event.metaKey&&event.key==='Enter'&&page==='ai'){event.preventDefault();sendMessage();}
  if(event.metaKey&&!event.ctrlKey&&event.key==='Enter'&&page==='ai'){event.preventDefault();insertAnswer(selectedAnswer||currentAnswer);}
});
window.addEventListener('hashchange',()=>switchPage(location.hash.slice(1)));
try{const saved=JSON.parse(localStorage.getItem(storeKey));if(saved?.drafts&&Object.hasOwn(samples,saved.format)){for(const key of Object.keys(samples))if(typeof saved.drafts[key]==='string')drafts[key]=saved.drafts[key];format=saved.format;fileName=typeof saved.fileName==='string'?saved.fileName:fileName;}}catch{}
$('format').value=format;$('source').value=drafts[format];$('filename').textContent=fileName;updatePreview();switchPage(location.hash.slice(1));icons();
