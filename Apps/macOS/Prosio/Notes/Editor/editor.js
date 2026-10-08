import { CrepeBuilder } from '@milkdown/crepe/builder';
import { listItem } from '@milkdown/crepe/feature/list-item';
import { placeholder } from '@milkdown/crepe/feature/placeholder';
import { toolbar } from '@milkdown/crepe/feature/toolbar';
import { linkTooltip } from '@milkdown/crepe/feature/link-tooltip';
import { table } from '@milkdown/crepe/feature/table';
import { cursor } from '@milkdown/crepe/feature/cursor';
import { codeMirror } from '@milkdown/crepe/feature/code-mirror';
import { replaceAll, callCommand } from '@milkdown/kit/utils';
import { editorViewCtx, remarkCtx } from '@milkdown/kit/core';
import { toggleStrongCommand, toggleEmphasisCommand, wrapInHeadingCommand, wrapInBulletListCommand, wrapInBlockquoteCommand } from '@milkdown/kit/preset/commonmark';
import '@milkdown/crepe/theme/frame.css';
import '@milkdown/crepe/theme/common/prosemirror.css';
import '@milkdown/crepe/theme/common/reset.css';
import '@milkdown/crepe/theme/common/list-item.css';
import '@milkdown/crepe/theme/common/placeholder.css';
import '@milkdown/crepe/theme/common/toolbar.css';
import '@milkdown/crepe/theme/common/link-tooltip.css';
import '@milkdown/crepe/theme/common/cursor.css';
import '@milkdown/crepe/theme/common/table.css';
import '@milkdown/crepe/theme/common/code-mirror.css';
import './editor.css';
import { createOutline } from './outline.js';

const root = document.querySelector('#editor'), source = document.querySelector('#source');
let sourceStart = '', renderedMarkdown = '';
let documentID = '', currentText = '', sourceMode = false, unsupported = false, suppress = false, composing = false, changedRich = false, readonly = false, generation = 0;
const send = (event, payload = {}) => window.webkit?.messageHandlers?.notes?.postMessage({event, ...payload});
const crepe = new CrepeBuilder({root, defaultValue: ''})
  .addFeature(listItem).addFeature(placeholder, {text: '写点什么…', mode: 'doc'})
  .addFeature(toolbar).addFeature(linkTooltip).addFeature(table).addFeature(cursor).addFeature(codeMirror);
const view = () => crepe.editor.action(ctx => ctx.get(editorViewCtx));
const reducedMotion = () => window.matchMedia('(prefers-reduced-motion: reduce)').matches;
// Measure wrapped source lines using the textarea's own metrics, including code and blank lines.
function measureSource(entries) {
  if (!sourceMode || !entries.length) return;
  const mirror = document.createElement('div'), style = getComputedStyle(source);
  for (const property of ['font', 'lineHeight', 'letterSpacing', 'padding', 'border', 'tabSize', 'wordBreak', 'overflowWrap']) mirror.style[property] = style[property];
  Object.assign(mirror.style, { position: 'fixed', top: '0', left: '0', visibility: 'hidden', width: `${source.clientWidth}px`, whiteSpace: 'pre-wrap' });
  const markers = [];
  let previous = 0;
  for (const entry of entries) {
    mirror.append(document.createTextNode(source.value.slice(previous, entry.offset)));
    const marker = document.createElement('span'); marker.textContent = '\u200b'; mirror.append(marker);
    markers.push(marker); previous = entry.offset;
  }
  document.body.append(mirror);
  const top = mirror.getBoundingClientRect().top;
  entries.forEach((entry, index) => { entry.y = markers[index].getBoundingClientRect().top - top; });
  mirror.remove();
}
function outlineHeadings() {
  if (!sourceMode) {
    const v = view(), entries = [];
    v.state.doc.descendants((node, pos) => {
      if (node.type.name !== 'heading') return;
      const element = v.nodeDOM(pos);
      if (!element?.getBoundingClientRect) return;
      entries.push({ text: node.textContent.trim() || '未命名章节', level: node.attrs.level, element, top: () => element.getBoundingClientRect().top });
    });
    return entries;
  }
  const ast = crepe.editor.action(ctx => ctx.get(remarkCtx).parse(source.value));
  const entries = [];
  const plain = node => node.value ?? (node.children ?? []).map(plain).join('');
  const walk = node => {
    if (node.type === 'heading') {
      const offset = node.position.start.offset;
      const entry = { text: plain(node).trim() || '未命名章节', level: node.depth, offset, y: 0 };
      entry.top = () => source.getBoundingClientRect().top + entry.y - source.scrollTop;
      entries.push(entry);
    }
    node.children?.forEach(walk);
  };
  walk(ast); return entries;
}
const outline = createOutline({ headings: outlineHeadings, layout: measureSource, atEnd() {
  const scroller = sourceMode ? source : document.scrollingElement;
  return scroller.scrollTop > 0 && Math.ceil(scroller.scrollTop + scroller.clientHeight) >= scroller.scrollHeight - 2;
}, navigate(entry) {
  const behavior = reducedMotion() ? 'instant' : 'smooth';
  if (!sourceMode) {
    const top = window.scrollY + entry.element.getBoundingClientRect().top - 24;
    window.scrollTo({ top: Math.max(0, top), behavior });
  } else {
    source.focus({ preventScroll: true });
    source.setSelectionRange(entry.offset, entry.offset);
    source.scrollTo({ top: Math.max(0, entry.y - 24), behavior });
  }
} });
function emit() {
  if (suppress || composing || readonly) return;
  currentText = sourceMode ? source.value : crepe.getMarkdown();
  send('change', {text: currentText, document: documentID});
}
crepe.on(api => api.markdownUpdated((_ctx, _md, previous) => {
  outline.refresh();
  if (!suppress && !sourceMode && _md !== renderedMarkdown) { renderedMarkdown = _md; changedRich = true; emit(); }
}));
const ready = crepe.create();
const allowed = new Set(['root','paragraph','text','strong','emphasis','delete','inlineCode','code','heading','blockquote','list','listItem','thematicBreak','break','link','linkReference','definition','table','tableRow','tableCell']);
function supported(md) {
  if (/^---[\r]?\n[\s\S]*?\n---(?:\r?\n|$)/.test(md) || /(^|\n)\s*\$\$|\$[^$\n]+\$|(^|\n)\s*:::/m.test(md)) return false;
  const ast = crepe.editor.action(ctx => ctx.get(remarkCtx).parse(md));
  const walk = node => (allowed.has(node.type) || (node.type === 'html' && /^\s*<br\s*\/?>\s*$/i.test(node.value))) && (!node.children || node.children.every(walk));
  return walk(ast);
}
function snapshot() {
  // Preserve original bytes until an actual user edit, not just rendering/normalizing a document.
  const text = sourceMode ? source.value : changedRich ? crepe.getMarkdown() : currentText;
  return {text, document: documentID, composing: composing || (!sourceMode && view().composing)};
}
async function load({text, document, source: desiredSource = false}) {
  const token = ++generation; await ready; if (token !== generation) return;
  suppress = true; documentID = document; currentText = text; changedRich = false;
  unsupported = !supported(text); sourceMode = unsupported || desiredSource;
  source.value = text; sourceStart = text;
  if (!unsupported) crepe.editor.action(replaceAll(text, true)); // Different dates have independent undo histories.
  renderedMarkdown = crepe.getMarkdown();
  root.hidden = sourceMode; source.hidden = !sourceMode;
  outline.reset();
  suppress = false;
  send('mode', {source: sourceMode, document: documentID, reason: unsupported ? '此文件含未支持的语法，已保留原文并以源码模式打开。' : ''});
}
async function setSource(value) {
  await ready;
  if (composing || view().composing) return sourceMode;
  if (value === sourceMode) return sourceMode;
  if (value) { source.value = snapshot().text; sourceStart = source.value; }
  else {
    if (!supported(source.value)) { send('mode',{source:true,document:documentID,reason:'原文含未支持语法，请继续使用源码模式。'}); return true; }
    if (source.value !== sourceStart || unsupported) {
      suppress = true; crepe.editor.action(replaceAll(source.value, false)); suppress = false;
    }
    currentText = source.value; renderedMarkdown = crepe.getMarkdown(); unsupported = false; changedRich = false;
  }
  sourceMode = value; root.hidden = value; source.hidden = !value; focus();
  outline.reset();
  send('mode',{source:sourceMode,document:documentID,reason:''}); return sourceMode;
}
function focus() { if (sourceMode) source.focus(); else view().focus(); }
async function command(name) {
  await ready; if (sourceMode || readonly) return; view().focus();
  const commands = {bold:toggleStrongCommand,italic:toggleEmphasisCommand,heading:wrapInHeadingCommand,list:wrapInBulletListCommand,quote:wrapInBlockquoteCommand};
  if (commands[name]) crepe.editor.action(callCommand(commands[name].key, name === 'heading' ? 2 : undefined));
  if (name === 'task') {
    crepe.editor.action(callCommand(wrapInBulletListCommand.key));
    const v = view(), pos = v.state.selection.$from;
    for (let depth = pos.depth; depth > 0; depth--) {
      const node = pos.node(depth);
      if (node.type.name === 'list_item') { v.dispatch(v.state.tr.setNodeMarkup(pos.before(depth), null, {...node.attrs, checked:false})); break; }
    }
  }
}
function configure({dark, fontSize, readonly: locked}) {
  document.documentElement.dataset.theme = dark ? 'dark' : 'light';
  document.documentElement.style.setProperty('--note-size', `${fontSize}px`);
  if (locked !== undefined) { readonly = locked; source.readOnly = locked; crepe.setReadonly(locked); }
  outline.refresh();
}
for (const el of [root,source]) {
  el.addEventListener('compositionstart',()=>{composing=true;send('composition',{active:true,document:documentID});});
  el.addEventListener('compositionend',()=>{composing=false;queueMicrotask(()=>{changedRich=!sourceMode;emit();send('composition',{active:false,document:documentID});});});
}
source.addEventListener('input', () => { emit(); outline.refresh(); });
window.addEventListener('resize', () => { if (sourceMode) outline.refresh(); }, { passive: true });
// Close a hovered directory before the rich editor's own Escape handlers consume the key.
document.addEventListener('keydown', e => {
  if (e.key === 'Escape' && !composing && !e.isComposing && e.keyCode !== 229 && (sourceMode || !view().composing) && outline.dismiss()) {
    e.preventDefault(); e.stopPropagation();
  }
}, true);
document.addEventListener('keydown', e => {
  if (e.defaultPrevented || composing || e.isComposing || e.keyCode === 229 || (!sourceMode && view().composing)) return;
  if ((e.metaKey || e.ctrlKey) && ['s','w'].includes(e.key.toLowerCase())) {
    e.preventDefault(); send('command',{name:e.key.toLowerCase()==='s'?'save':'hide'});
  } else if (e.key === 'Escape') { e.preventDefault(); send('command',{name:'hide'}); }
});
document.addEventListener('paste',e=>{if(e.clipboardData?.files.length){e.preventDefault();send('warning',{message:'便签暂不支持图片附件，请粘贴文字。'});}});
document.addEventListener('drop',e=>{if(e.dataTransfer?.files.length){e.preventDefault();send('warning',{message:'便签暂不支持文件附件。'});}},true);
document.addEventListener('click',e=>{const a=e.target.closest('a');if(a){e.preventDefault();if(e.metaKey)send('openLink',{url:a.href});}});
window.notes = {load,setSource,command,configure,focus,snapshot,ready};
ready.then(()=>{send('ready'); window.__ready = true;}).catch(error=>send('error',{message:String(error)}));
