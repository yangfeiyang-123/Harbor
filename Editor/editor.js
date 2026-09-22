import { basicSetup } from 'codemirror';
import { EditorView, keymap } from '@codemirror/view';
import { EditorState, Compartment } from '@codemirror/state';
import { indentWithTab, historyField } from '@codemirror/commands';
import { openSearchPanel } from '@codemirror/search';
import { StreamLanguage, HighlightStyle, syntaxHighlighting } from '@codemirror/language';
import { tags } from '@lezer/highlight';
import { python } from '@codemirror/lang-python';
import { javascript } from '@codemirror/lang-javascript';
import { json } from '@codemirror/lang-json';
import { markdown } from '@codemirror/lang-markdown';
import { cpp } from '@codemirror/lang-cpp';
import { rust } from '@codemirror/lang-rust';
import { html } from '@codemirror/lang-html';
import { css } from '@codemirror/lang-css';
import { yaml } from '@codemirror/lang-yaml';
import { shell } from '@codemirror/legacy-modes/mode/shell';
import { swift } from '@codemirror/legacy-modes/mode/swift';
import { go } from '@codemirror/legacy-modes/mode/go';
import palettes from '../Sources/HarborSSH/Resources/Themes/cursor.json';
import { marked } from 'marked';
import DOMPurify from 'dompurify';
const send = value => window.webkit?.messageHandlers.harbor.postMessage(value);
let editor, revision = -1, current, pendingScroll, config = new Compartment();
const scrollRestoreKey = {};
function applyScroll(saved){editor.scrollDOM.scrollTop=saved.top||0;editor.scrollDOM.scrollLeft=saved.left||0;document.querySelector('#preview').scrollTop=saved.previewTop||0;}
function restoreScroll() {
 if(!editor||!pendingScroll)return;
 // WebKit pauses animation frames while a native workspace is hidden. Apply
 // an initial position synchronously, then confirm it after CM's measurement.
 if(current?.preview){if(document.querySelector('#preview').clientHeight>0){applyScroll(pendingScroll);pendingScroll=null;}return;}
 if(editor.scrollDOM.clientHeight>0)applyScroll(pendingScroll);
 editor.requestMeasure({key:scrollRestoreKey,read:view=>view.scrollDOM.clientHeight,write:height=>{
  if(height>0&&pendingScroll){const saved=pendingScroll;pendingScroll=null;applyScroll(saved);}
 }});
}
for(const type of ['wheel','pointerdown','keydown'])document.addEventListener(type,()=>{pendingScroll=null;},{passive:true});
function language(path) {
 const ext=path.split('.').pop().toLowerCase();
 return ({py:python,js:javascript,jsx:()=>javascript({jsx:true}),ts:()=>javascript({typescript:true}),tsx:()=>javascript({typescript:true,jsx:true}),json,ipynb:json,md:markdown,markdown,c:cpp,h:cpp,cpp,cc:cpp,hpp:cpp,rs:rust,html,htm:html,css,yaml,yml:yaml,sh:()=>StreamLanguage.define(shell),bash:()=>StreamLanguage.define(shell),zsh:()=>StreamLanguage.define(shell),swift:()=>StreamLanguage.define(swift),go:()=>StreamLanguage.define(go)})[ext]?.()||[];
}
function theme(options) {
 const {colors:c,syntax:s}=palettes[options.dark?'dark':'light'];
 return [syntaxHighlighting(HighlightStyle.define([
  {tag:tags.comment,color:s.comment},{tag:[tags.keyword,tags.operator],color:s.keyword},
  {tag:[tags.string,tags.regexp],color:s.string},{tag:[tags.number,tags.bool,tags.null,tags.atom],color:s.number},
  {tag:tags.variableName,color:s.variable},{tag:[tags.typeName,tags.className],color:s.type},
  {tag:tags.function(tags.variableName),color:s.function},{tag:tags.function(tags.propertyName),color:s.function},
  {tag:[tags.tagName,tags.attributeName],color:s.tag},{tag:tags.propertyName,color:s.property},
  {tag:tags.invalid,color:s.invalid},{tag:tags.heading,color:s.heading,fontWeight:'bold'},
  {tag:tags.link,color:s.link,textDecoration:'underline'},
  {tag:tags.strong,fontWeight:'bold'},{tag:tags.emphasis,fontStyle:'italic'}
 ])),EditorView.theme({
 '&':{height:'100%',fontSize:options.font+'px',backgroundColor:c['editor.background'],color:c['editor.foreground']},
 '.cm-scroller':{overflow:'auto',minHeight:'0',fontFamily:'ui-monospace, SFMono-Regular, Menlo, monospace',lineHeight:'1.6'},
 '.cm-content':{padding:'10px 0',minHeight:'100%'},
 '.cm-gutters':{backgroundColor:c['editor.background'],color:c['editorLineNumber.foreground'],border:'none'},
 '.cm-lineNumbers .cm-gutterElement':{paddingLeft:'12px',paddingRight:'12px'},
 '.cm-activeLineGutter':{backgroundColor:c['editor.lineHighlightBackground'],color:c['editorLineNumber.activeForeground']},
 '.cm-activeLine':{backgroundColor:c['editor.lineHighlightBackground']},
 '.cm-cursor,.cm-dropCursor':{borderLeftColor:c['editorCursor.foreground']},
 '.cm-selectionBackground':{backgroundColor:c['editor.inactiveSelectionBackground']},
 '&.cm-focused .cm-selectionBackground,.cm-content ::selection':{backgroundColor:c['editor.selectionBackground']},
 '.cm-selectionMatch':{backgroundColor:c['editor.selectionHighlightBackground']},
 '.cm-searchMatch':{backgroundColor:c['editor.findMatchHighlightBackground'],outline:'none'},
 '.cm-searchMatch.cm-searchMatch-selected':{backgroundColor:c['editor.findMatchBackground']},
 '&.cm-focused .cm-matchingBracket':{backgroundColor:c['editorBracketMatch.background'],outline:'1px solid '+c['editorBracketMatch.border']},
 '.cm-panels,.cm-tooltip':{backgroundColor:c['editorWidget.background'],color:c['editorWidget.foreground'],borderColor:c['editorWidget.border']},
 '.cm-panels-top':{borderBottom:'1px solid '+c['editorWidget.border']},
 '.cm-panels-bottom':{borderTop:'1px solid '+c['editorWidget.border']},
 '.cm-textfield':{backgroundColor:c['input.background'],color:c['input.foreground'],border:'1px solid '+c['input.border']},
 '.cm-button':{backgroundImage:'none',backgroundColor:c['button.background'],color:c['button.foreground'],border:'none'},
 '.cm-tooltip-autocomplete > ul > li[aria-selected]':{backgroundColor:c['list.activeSelectionBackground'],color:c['list.activeSelectionForeground']}
 },{dark:options.dark}),options.wrap?EditorView.lineWrapping:[]];
}
function reportPosition(state){const pos=state.selection.main.head,line=state.doc.lineAt(pos);send({action:'position',line:line.number,column:pos-line.from+1,lines:state.doc.lines});}
function renderMarkdown(){document.querySelector('#preview').innerHTML=DOMPurify.sanitize(marked.parse(editor.state.sliceDoc(),{gfm:true}),{USE_PROFILES:{html:true},FORBID_TAGS:['form','input','button','iframe','style','video','audio'],FORBID_ATTR:['style','srcset']});}
window.harborSet = options => {
 current=options;document.documentElement.dataset.theme=options.dark?'dark':'light';document.documentElement.style.setProperty('--font',options.font+'px');
 const c=palettes[options.dark?'dark':'light'].colors;
 for(const [variable,role] of Object.entries({bg:'editor.background',fg:'editor.foreground',muted:'descriptionForeground',border:'panel.border',link:'textLink.foreground',linkActive:'textLink.activeForeground',code:'textCodeBlock.background',inline:'textPreformat.background',inlineText:'textPreformat.foreground',quote:'textBlockQuote.background',quoteBorder:'textBlockQuote.border',selection:'editor.selectionBackground',scrollbar:'scrollbarSlider.background'})) document.documentElement.style.setProperty('--'+variable,c[role]);
 if(!editor){
  const editorConfig={doc:options.text,extensions:[EditorState.lineSeparator.of(options.text.includes("\r\n") ? "\r\n" : "\n"),basicSetup,language(options.path),keymap.of([indentWithTab,{key:'Mod-s',run:()=>{send({action:'save'});return true;}}]),config.of(theme(options)),EditorView.contentAttributes.of({'aria-label':'Code Editor',spellcheck:'false'}),EditorView.updateListener.of(update=>{
   if(update.docChanged){send({action:'change',text:update.state.sliceDoc()});if(current.preview)renderMarkdown();}
   if(update.docChanged||update.selectionSet)reportPosition(update.state);
   if(pendingScroll&&(update.viewportChanged||update.geometryChanged))restoreScroll();
  })]};
  const saved=options.snapshot;let state;
  try{state=saved?.state?.doc===options.text?EditorState.fromJSON(saved.state,editorConfig,{history:historyField}):EditorState.create(editorConfig);}catch{state=EditorState.create(editorConfig);}
  editor=new EditorView({parent:document.querySelector('#editor'),state});
  if(saved){pendingScroll=saved;new ResizeObserver(restoreScroll).observe(editor.scrollDOM);restoreScroll();}
  revision=options.revision;reportPosition(editor.state);
 }else{if(revision!==options.revision){editor.dispatch({changes:{from:0,to:editor.state.doc.length,insert:options.text}});revision=options.revision;}editor.dispatch({effects:config.reconfigure(theme(options))});}
 document.querySelector('#editor').hidden=options.preview;document.querySelector('#preview').hidden=!options.preview;if(options.preview)renderMarkdown();
 restoreScroll();
};
window.harborSnapshot=()=>editor?{state:editor.state.toJSON({history:historyField}),top:editor.scrollDOM.scrollTop,left:editor.scrollDOM.scrollLeft,previewTop:document.querySelector('#preview').scrollTop}:null;
window.harborFocus=()=>{if(current?.preview){const preview=document.querySelector('#preview');preview.tabIndex=0;preview.focus();}else{editor?.focus();}};
window.harborFind=()=>{document.querySelector('#editor').hidden=false;document.querySelector('#preview').hidden=true;openSearchPanel(editor);};
document.addEventListener('click',event=>{const a=event.target.closest('a');if(a){event.preventDefault();send({action:'link',url:a.getAttribute('href')});}});
send({action:'ready'});
window.harborReveal=(number,column=1)=>{
 if(!editor)return;
 const line=editor.state.doc.line(Math.max(1,Math.min(editor.state.doc.lines,number)));
 const pos=Math.min(line.to,line.from+Math.max(0,column-1));
 editor.dispatch({selection:{anchor:pos},effects:EditorView.scrollIntoView(pos,{y:'center'})});editor.focus();
};
