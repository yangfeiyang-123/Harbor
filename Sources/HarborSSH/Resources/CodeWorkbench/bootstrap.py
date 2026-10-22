"""Harbor's private, version-pinned Code-OSS service. JSON in / JSON lines out.

Only a loopback listener is created. Remote access always goes through SSH.
No root, shell profile, existing editor installation, or project is modified.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import secrets
import shutil
import signal
import socket
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request

VERSION = "4.140.0"
DIGESTS = {
    "macos-arm64": "82c7144406ac31c373acfa786b6705c7c5463d895f728fde2cb94402b945b301",
    "macos-amd64": "a5393b6eed4aa68b084e724c3c565f805abd996c609356043119f0323e40cf52",
    "linux-amd64": "864c5d01c808ade57e4d12c708717be7a187219fded60428f263b9e2da9f6b48",
    "linux-arm64": "ae4b07153f2037b06d24749bc8004221fcbf3ffe317038401be0452f541bf200",
}

# Code-OSS's web layout forces a second title bar when its real activity bar is
# placed above Explorer. Harbor supplies that chrome natively. Patch the pinned
# layout decisions so the grid reclaims both title rows. Its own CompositeBar
# still calculates overflow and retains the active item at narrow widths.
# The embedded-only, fixed UI action API avoids a remote extension-host roundtrip.
# The official 4.140.0 macOS ARM64 and Linux x64 archives contain identical bytes.
HOST_LAYOUT_HASHES = {
    "4.140.0": {"b7f523084e197c272bc968d4c99c8cb9c6fa5f5191627e44291393ab28945040"},
}
HOST_LAYOUT_PATCHES_V2 = (
    ("function vq(s,o,e){if(!FF(s))return!1;",
     "function vq(s,o,e){if(globalThis.__harborEmbeddedWorkbench===true||!FF(s))return!1;"),
    ('if((n.affectsConfiguration("workbench.activityBar.location")&&["top","bottom"]',
     'if(globalThis.__harborEmbeddedWorkbench!==true&&(n.affectsConfiguration("workbench.activityBar.location")&&["top","bottom"]'),
    ('static{this.activeViewletSettingsKey="workbench.sidebar.activeviewletid"}get snap()',
     'static{this.activeViewletSettingsKey="workbench.sidebar.activeviewletid"}onDidOpen(e){super.onDidOpen(e);if(globalThis.__harborEmbeddedWorkbench===true){let t=e.getId()!=="workbench.view.explorer";this.options.hasTitle=t,this.titleArea&&(this.titleArea.style.display=t?"":"none"),this.relayout()}}get snap()'),
    ('preventLoopNavigation:this.options.preventLoopNavigation,openComposite:async(t,i)=>',
     'preventLoopNavigation:this.options.preventLoopNavigation,harborCentered:globalThis.__harborEmbeddedWorkbench===true&&this.part==="workbench.parts.sidebar"&&this.options.orientation===0,openComposite:async(t,i)=>'),
    ('create(e){let t=e.appendChild(T(".composite-bar"));this.compositeSwitcherBar=',
     'create(e){let t=e.appendChild(T(".composite-bar"));this.harborCompositeElement=t,this.compositeSwitcherBar='),
    ('layout(e){this.dimension=e,!(e.height===0||e.width===0)&&(this.compositeSizeInBar.size===0',
     'layout(e){this.dimension=e,this.options.harborCentered&&this.harborCompositeElement&&Object.assign(this.harborCompositeElement.style,{width:Math.max(0,e.width)+"px",display:"flex",justifyContent:"center"}),!(e.height===0||e.width===0)&&(this.compositeSizeInBar.size===0'),
    ('lvt=class extends p3{constructor(e){super({id:"additionalComposites.action",name:d(4597,null),classNames:Q.asClassNameArray(L.more)});',
     'lvt=class extends p3{constructor(e,t=L.more){super({id:"additionalComposites.action",name:d(4597,null),classNames:Q.asClassNameArray(t)});'),
    ('this.instantiationService.createInstance(lvt,()=>{this.compositeOverflowActionViewItem.value?.showMenu()})',
     'this.instantiationService.createInstance(lvt,()=>{this.compositeOverflowActionViewItem.value?.showMenu()},this.options.harborCentered?L.chevronDown:L.more)'),
    ('registerViewContainer({id:Fd,title:F(18710,"Terminal"),icon:ooo,',
     'registerViewContainer({id:Fd,title:globalThis.__harborEmbeddedWorkbench===true?{value:"Tasks",original:"Tasks"}:F(18710,"Terminal"),icon:ooo,'),
    ('},1,{doNotRegisterOpenCommand:!0,isDefault:!0});me.as(dr.ViewsRegistry).registerViews([{id:Fd,name:F(18710,"Terminal"),',
     '},1,{doNotRegisterOpenCommand:!0,isDefault:globalThis.__harborEmbeddedWorkbench!==true});me.as(dr.ViewsRegistry).registerViews([{id:Fd,when:globalThis.__harborEmbeddedWorkbench===true?_.greater("terminalCount",0):void 0,name:globalThis.__harborEmbeddedWorkbench===true?{value:"Tasks",original:"Tasks"}:F(18710,"Terminal"),'),
    ('registerActions(){let e=this;this._register(U(class extends j{constructor(){super({id:W5i,',
     'registerActions(){let e=this;if(globalThis.__harborEmbeddedWorkbench===true&&!Object.hasOwn(globalThis,"__harborWorkbenchCommand")){let t=Promise.resolve(),i;Object.defineProperty(globalThis,"__harborWorkbenchCommand",{configurable:!1,writable:!1,value:(n,o)=>{if(!["openTerminal","hidePanel","toggleMaximizedPanel","toggleSidebar","enterTerminalMode","leaveTerminalMode","setTerminalPanel"].includes(n))return Promise.resolve({ok:!1,error:"Unknown Harbor layout action"});if(n==="setTerminalPanel"&&(!o||typeof o.visible!=="boolean"||typeof o.maximized!=="boolean"))return Promise.resolve({ok:!1,error:"Invalid Harbor panel state"});let l=n==="setTerminalPanel"?{visible:o.visible,maximized:o.maximized}:void 0,r=async()=>{let a=e.layoutService,c=e.instantiationService.invokeFunction(u=>u.get(ui));try{if(n==="hidePanel"||n==="setTerminalPanel"&&!l.visible){n==="setTerminalPanel"&&!l.maximized&&a.isPanelMaximized()&&a.toggleMaximizedPanel(),a.setPartHidden(!0,"workbench.parts.panel")}else if(n==="toggleSidebar")a.setPartHidden(a.isVisible("workbench.parts.sidebar"),"workbench.parts.sidebar");else if(n==="leaveTerminalMode"){i&&(a.setPartHidden(!i.sidebar,"workbench.parts.sidebar"),i=void 0),globalThis.__harborTerminalMode=!1}else{if(n==="enterTerminalMode"&&!i)i={sidebar:a.isVisible("workbench.parts.sidebar")};if(!c.isViewVisible("harbor.nativeTerminal")){if(!await c.openView("harbor.nativeTerminal",!1))throw Error("Harbor terminal view is unavailable")}a.getPanelPosition()!==2&&a.setPanelPosition(2),a.getPanelAlignment()!=="center"&&a.setPanelAlignment("center");if(n==="toggleMaximizedPanel")a.toggleMaximizedPanel();else if(n==="setTerminalPanel"){a.isPanelMaximized()!==l.maximized&&a.toggleMaximizedPanel()}else if(n==="enterTerminalMode"){a.isPanelMaximized()||a.toggleMaximizedPanel(),a.setPartHidden(!0,"workbench.parts.sidebar"),globalThis.__harborTerminalMode=!0}}globalThis.dispatchEvent(new Event("harbor-layout"));return{ok:!0}}catch(a){return{ok:!1,error:String(a?.message||a)}}};let a=t.then(r);return t=a.then(()=>{},()=>{}),a}})}this._register(U(class extends j{constructor(){super({id:W5i,'),
    ('run:async(o,e,t)=>{let i=bi(t)?t:void 0,n=e.get(He),r=e.get(ve),a=e.get(Ft),c=n.getWorkspace().folders;',
     'run:async(o,e,t)=>{if(globalThis.__harborEmbeddedWorkbench===true&&t===void 0&&!e.get(ui).isViewVisible(Fd))return globalThis.dispatchEvent(new CustomEvent("harbor-terminal-action",{detail:"newTerminal"}));let i=bi(t)?t:void 0,n=e.get(He),r=e.get(ve),a=e.get(Ft),c=n.getWorkspace().folders;'),
    ('icon:L.splitHorizontal,run:async(o,e,t)=>{let i=bi(t)?t:void 0,n=e.get(ve),r=e.get(He),a=TRn(i),',
     'icon:L.splitHorizontal,run:async(o,e,t)=>{if(globalThis.__harborEmbeddedWorkbench===true&&t===void 0&&!e.get(ui).isViewVisible(Fd))return globalThis.dispatchEvent(new CustomEvent("harbor-terminal-action",{detail:"splitTerminal"}));let i=bi(t)?t:void 0,n=e.get(ve),r=e.get(He),a=TRn(i),'),
    ('async run(c,l){let u=c.get(Ft),p=c.get(fo),h=c.get(Ji),g=c.get(ui),f=c.get(ee);if(Ul.getValue(f)===e.id',
     'async run(c,l){if(globalThis.__harborEmbeddedWorkbench===true&&n==="workbench.action.terminal.toggleTerminal"&&l===void 0)return globalThis.dispatchEvent(new CustomEvent("harbor-terminal-action",{detail:"toggleTerminal"}));let u=c.get(Ft),p=c.get(fo),h=c.get(Ji),g=c.get(ui),f=c.get(ee);if(Ul.getValue(f)===e.id'),
)
# Retain complete released revisions so an installed runtime can be upgraded
# only after restoring and verifying every byte against the original SHA-256.
_host_action_old, _host_action_v2 = HOST_LAYOUT_PATCHES_V2[10]
_host_action_current = _host_action_v2
for _old, _new in (
    ('"leaveTerminalMode","setTerminalPanel"].includes(n)',
     '"leaveTerminalMode","setTerminalPanel","focusEditor"].includes(n)'),
    ('let l=n==="setTerminalPanel"?{visible:o.visible,maximized:o.maximized}:void 0,r=async()=>',
     'if(n==="toggleSidebar"&&o?.preserveFocus!==void 0&&typeof o.preserveFocus!=="boolean")return Promise.resolve({ok:!1,error:"Invalid Harbor focus option"});let l=n==="setTerminalPanel"?{visible:o.visible,maximized:o.maximized}:void 0,p=n==="toggleSidebar"&&o?.preserveFocus===true,r=async()=>'),
    ('else if(n==="toggleSidebar")a.setPartHidden(a.isVisible("workbench.parts.sidebar"),"workbench.parts.sidebar");',
     'else if(n==="toggleSidebar")a.setPartHidden(a.isVisible("workbench.parts.sidebar"),"workbench.parts.sidebar",p);else if(n==="focusEditor")a.focusPart("workbench.parts.editor");'),
):
    if _host_action_current.count(_old) != 1:
        raise RuntimeError("Invalid pinned Harbor layout action revision.")
    _host_action_current = _host_action_current.replace(_old, _new)
HOST_LAYOUT_PATCHES_V3 = (HOST_LAYOUT_PATCHES_V2[:10]
    + ((_host_action_old, _host_action_current),)
    + HOST_LAYOUT_PATCHES_V2[11:] + (
    ('setPartHidden(e,t){switch(t){case"workbench.parts.activitybar":return this.setActivityBarHidden(e);case"workbench.parts.sidebar":return this.setSideBarHidden(e);',
     'setPartHidden(e,t,i=!1){switch(t){case"workbench.parts.activitybar":return this.setActivityBarHidden(e);case"workbench.parts.sidebar":return this.setSideBarHidden(e,i);'),
    ('setSideBarHidden(e){if(!(!e&&this.setAuxiliaryBarMaximized(!1)&&this.isVisible("workbench.parts.sidebar"))){',
     'setSideBarHidden(e,t=!1){if(!(!e&&this.setAuxiliaryBarMaximized(!1)&&this.isVisible("workbench.parts.sidebar"))){'),
    ('this.paneCompositeService.hideActivePaneComposite(0),this.isAuxiliaryBarMaximized()||this.focusPanelOrEditor();',
     'this.paneCompositeService.hideActivePaneComposite(0),globalThis.__harborEmbeddedWorkbench===true&&t===!0||this.isAuxiliaryBarMaximized()||this.focusPanelOrEditor();'),
))
# V4 uses the genuine Code-OSS terminal. Historical native-panel patches are
# retained solely to recognize/reverse complete older installations, never applied.
HOST_LAYOUT_PREVIOUS_PATCH_SETS = (HOST_LAYOUT_PATCHES_V2[:2], HOST_LAYOUT_PATCHES_V2, HOST_LAYOUT_PATCHES_V3)
_builtin_actions = r'''registerActions(){let e=this;
if(globalThis.__harborEmbeddedWorkbench===true&&!Object.hasOwn(globalThis,"__harborWorkbenchCommand")){
 let queue=Promise.resolve(),saved;
 Object.defineProperty(globalThis,"__harborWorkbenchCommand",{configurable:!1,writable:!1,value:(action,options)=>{
  const commands={newTerminal:"workbench.action.terminal.new",splitTerminal:"workbench.action.terminal.split",toggleTerminal:"workbench.action.terminal.toggleTerminal",focusTerminal:"workbench.action.terminal.focus"};
  if(!["openTerminal","hidePanel","toggleMaximizedPanel","toggleSidebar","enterTerminalMode","leaveTerminalMode","setTerminalPanel","focusEditor",...Object.keys(commands)].includes(action))return Promise.resolve({ok:!1,error:"Unknown Harbor layout action"});
  if(action==="setTerminalPanel"&&(!options||typeof options.visible!=="boolean"||typeof options.maximized!=="boolean"))return Promise.resolve({ok:!1,error:"Invalid Harbor panel state"});
  if(action==="toggleSidebar"&&options?.preserveFocus!==void 0&&typeof options.preserveFocus!=="boolean")return Promise.resolve({ok:!1,error:"Invalid Harbor focus option"});
  const state=action==="setTerminalPanel"?{visible:options.visible,maximized:options.maximized}:void 0,preserve=action==="toggleSidebar"&&options?.preserveFocus===true;
  const run=async()=>{const layout=e.layoutService;try{
   if(Object.hasOwn(commands,action))await e.instantiationService.invokeFunction(accessor=>accessor.get(ve).executeCommand(commands[action]));
   else if(action==="hidePanel"||action==="setTerminalPanel"&&!state.visible){
    action==="setTerminalPanel"&&!state.maximized&&layout.isPanelMaximized()&&layout.toggleMaximizedPanel();layout.setPartHidden(!0,"workbench.parts.panel");
   }else if(action==="toggleSidebar")layout.setPartHidden(layout.isVisible("workbench.parts.sidebar"),"workbench.parts.sidebar",preserve);
   else if(action==="focusEditor")layout.focusPart("workbench.parts.editor");
   else if(action==="leaveTerminalMode"){
    if(saved){layout.setPartHidden(!saved.sidebar,"workbench.parts.sidebar",!0);layout.setPartHidden(!saved.auxiliary,"workbench.parts.auxiliarybar");saved=void 0}
    globalThis.__harborTerminalMode=!1;
   }else{
    if(action==="enterTerminalMode"&&!saved)saved={sidebar:layout.isVisible("workbench.parts.sidebar"),auxiliary:layout.isVisible("workbench.parts.auxiliarybar")};
    layout.getPanelPosition()!==2&&layout.setPanelPosition(2);layout.getPanelAlignment()!=="center"&&layout.setPanelAlignment("center");
    const views=e.instantiationService.invokeFunction(accessor=>accessor.get(ui));
    if(!views.isViewVisible(Fd)&&!await views.openView(Fd,!1))throw Error("The terminal view is unavailable");
    if(action==="toggleMaximizedPanel")layout.toggleMaximizedPanel();
    else if(action==="setTerminalPanel"){layout.isPanelMaximized()!==state.maximized&&layout.toggleMaximizedPanel()}
    else if(action==="enterTerminalMode"){
     layout.isPanelMaximized()||layout.toggleMaximizedPanel();layout.setPartHidden(!0,"workbench.parts.sidebar",!0);layout.setPartHidden(!0,"workbench.parts.auxiliarybar");globalThis.__harborTerminalMode=!0;
    }
   }
   globalThis.dispatchEvent(new Event("harbor-layout"));return{ok:!0}
  }catch(error){return{ok:!1,error:String(error?.message||error)}}};
  const result=queue.then(run);queue=result.then(()=>{},()=>{});return result;
 }});
}this._register(U(class extends j{constructor(){super({id:W5i,'''
HOST_LAYOUT_PATCHES_BUILTIN_V1 = HOST_LAYOUT_PATCHES_V2[:8] + ((_host_action_old, _builtin_actions),) + HOST_LAYOUT_PATCHES_V3[-3:]
HOST_LAYOUT_PREVIOUS_PATCH_SETS += (HOST_LAYOUT_PATCHES_BUILTIN_V1,)
# Opening another workspace must not shorten detached terminals from the first
# workspace to the upstream five-minute cleanup window. Actual terminal close
# still uses the upstream shutdown command; only reconnection cleanup is delayed.
HOST_LAYOUT_PATCHES_BUILTIN_V2 = HOST_LAYOUT_PATCHES_BUILTIN_V1 + (
    ('async reduceConnectionGraceTime(){if(!this._remoteTerminalChannel)throw new Error("Cannot reduce grace time when there is no remote");',
     'async reduceConnectionGraceTime(){if(globalThis.__harborEmbeddedWorkbench===true)return;if(!this._remoteTerminalChannel)throw new Error("Cannot reduce grace time when there is no remote");'),
)
HOST_LAYOUT_PREVIOUS_PATCH_SETS += (HOST_LAYOUT_PATCHES_BUILTIN_V2,)
# The terminal reserves this width for its scrollbar and overview ruler when
# it fits columns. Upstream uses 14 px; the embedded workbench uses a slim rail
# so text runs closer to the terminal list. Harbor's injected stylesheet moves
# the viewport edge by the same amount (TERMINAL_RAIL_WIDTH in CodeWorkbench.swift).
TERMINAL_RAIL_WIDTH = 6
HOST_LAYOUT_PATCHES_RAIL = HOST_LAYOUT_PATCHES_BUILTIN_V2 + (
    ('get scrollbarWidth(){return this._configurationService.getValue("workbench.experimental.modernUI")===!0?10:14}',
     'get scrollbarWidth(){return globalThis.__harborEmbeddedWorkbench===true?%d:this._configurationService.getValue("workbench.experimental.modernUI")===!0?10:14}' % TERMINAL_RAIL_WIDTH),
    # The activity row above Explorer shows a fixed number of views (Harbor's
    # "harbor.activityBar.visibleItems", default four); the rest stay in the
    # chevron menu however wide the sidebar is. Narrow widths still overflow
    # earlier, and a view opened from the menu joins the row while it is active.
    ('if(a+p>c){n=u;break}a+=p}for(r>n&&(i=i.slice(0,n)),this.model.activeItem&&',
     'if(a+p>c||this.options.harborCentered&&u>=Math.max(1,Math.min(12,globalThis.__harborActivityCount|0||4))){n=u;break}a+=p}for(r>n&&(i=i.slice(0,n)),this.model.activeItem&&'),
    # Lets Harbor re-evaluate the row when the setting changes, without a reload.
    ('updateCompositeSwitcher(e){let t=this.compositeSwitcherBar;if(!t||!this.dimension)return;',
     'updateCompositeSwitcher(e){this.options.harborCentered&&(globalThis.__harborRelayoutActivity=()=>this.updateCompositeSwitcher());let t=this.compositeSwitcherBar;if(!t||!this.dimension)return;'),
    # The sidebar cannot be dragged narrower than that row, and dragging never
    # hides it: Command+B (or the title-bar button) is the only way to close it.
    ('"sideBar","viewlet",MVo,xjt,0,zq.Viewlets,O.SidebarTitle,e,t,i,n,r,a,c,l,u,p,h,f,g);this.minimumWidth=170;',
     '"sideBar","viewlet",MVo,xjt,0,zq.Viewlets,O.SidebarTitle,e,t,i,n,r,a,c,l,u,p,h,f,g);this.minimumWidth=170;globalThis.__harborEmbeddedWorkbench===true&&Object.defineProperty(this,"minimumWidth",{configurable:!0,get:()=>Math.max(110,Math.min(420,globalThis.__harborSidebarMinimumWidth|0||170)),set(){}});'),
    ('get snap(){return!0}get preferredWidth(){let e=this.getActivePaneComposite();if(!e)return;let t=e.getOptimalWidth();if(typeof t=="number")return Math.max(t,300)}',
     'get snap(){return globalThis.__harborEmbeddedWorkbench!==true}get preferredWidth(){let e=this.getActivePaneComposite();if(!e)return;let t=e.getOptimalWidth();if(typeof t=="number")return Math.max(t,300)}'),
)
HOST_LAYOUT_PREVIOUS_PATCH_SETS += (HOST_LAYOUT_PATCHES_RAIL,)
# Explorer's folder view keeps its own header row (the folder's name, with New File, New Folder,
# Refresh and Collapse) even when it is the only view shown. Code-OSS merges a lone view into its
# container and moves that row's actions up into the sidebar's title area, which the embedded
# workbench has no room for (Harbor's patch above hides it under the activity row). So a workspace
# with Outline and Timeline hidden had no way to make a file or folder from the sidebar.
HOST_LAYOUT_PATCHES_EXPLORER = HOST_LAYOUT_PATCHES_RAIL + (
    ('super(dS,{mergeViewWithContainerWhenSingleView:!0},',
     'super(dS,{mergeViewWithContainerWhenSingleView:globalThis.__harborEmbeddedWorkbench!==true},'),
)
HOST_LAYOUT_PREVIOUS_PATCH_SETS += (HOST_LAYOUT_PATCHES_EXPLORER,)
# What is copied in the editor's terminal reaches the Mac's pasteboard, through the bridge Harbor
# gives the page (navigator.clipboard.writeText there is Harbor's, see WorkbenchClipboard in
# CodeWorkbench.swift).
HOST_LAYOUT_PATCHES = HOST_LAYOUT_PATCHES_EXPLORER + (
    # A program in the terminal copies with OSC 52: Codex and Claude Code on a server, tmux, vim.
    # The web workbench keeps such a write in a table of its own (a write "of a type" never
    # leaves the page), so the program said it had copied and the pasteboard held what it held
    # before. The text is still kept in that table too: a program that asks for the clipboard
    # (OSC 52 with "?") is answered with what a program put there, never with the Mac's pasteboard.
    ('async writeText(R,M){return g.writeText(M,R==="p"?"selection":"clipboard")}',
     'async writeText(R,M){if(globalThis.__harborEmbeddedWorkbench===true&&R!=="p")try{await globalThis.navigator.clipboard.writeText(M)}catch(P){console.error(P)}return g.writeText(M,R==="p"?"selection":"clipboard")}'),
    # Command+C and Copy in a menu. Under WebKit the workbench begins a clipboard write at every
    # key press and click, with a promise that a later copy fulfils; WebKit refuses it when the
    # pasteboard has changed in between (something was copied in another application), and a
    # copy with no press of its own before it (Copy in a menu, copy on selection) fulfils one
    # that is already used up. Both fail without a word. With Harbor's bridge there, text goes
    # straight to it.
    ('(Pf||MOt)&&this.installWebKitWriteTextWorkaround()',
     '(Pf||MOt)&&!(globalThis.__harborEmbeddedWorkbench===true&&globalThis.webkit?.messageHandlers?.harborClipboard)&&this.installWebKitWriteTextWorkaround()'),
)
# Built-in extensions Harbor does not ship: the bundled AI assistant and its
# prompt-file language, account providers for services code-server cannot use,
# desktop-only tunnelling, and task auto-detection for retired build tools.
# Language grammars, Git, Markdown, debugging and every Open VSX extension the
# user installs are untouched. Removal only unlinks names inside Harbor's
# private runtime copy; a donor runtime keeps its files.
PRUNED_BUILTIN_EXTENSIONS = ("copilot", "prompt-basics", "microsoft-authentication", "tunnel-forwarding", "grunt", "gulp", "jake")
RUNTIME_CONTENT_VERSION = 2
# Native payloads only the built-in assistant's agent host can use (about 110 MB
# of the 230 MB download). They are removed in place, without a new revision:
# nothing Harbor starts loads them. The Mac leaves them out of what it uploads.
PRUNED_RUNTIME_PATHS = ("lib/vscode/node_modules/@github/copilot-sdk-*", "lib/vscode/node_modules/@microsoft/mxc-sdk/bin")
RECONNECTION_GRACE_SECONDS = 7 * 24 * 60 * 60
# Keep the preview/editor feedback guards, but use one latest-wins animation
# frame for editor-to-preview scrolling. Initial positioning still waits for
# images and is canceled if a newer scroll supersedes it.
MARKDOWN_SCROLL_PATH = "lib/vscode/extensions/markdown-language-features/media/index.js"
MARKDOWN_SCROLL_HASHES = {"4.140.0": {"933e20a40a969254648efdd4e34b61303c68d7cc1ebd9b202d9f886240e14d19"}}
MARKDOWN_SCROLL_PATCHES = (
    ('var Ge=We(),S=0,w,ze=',
     'var harborScrollRevision=0,harborSyncFrame=0,harborSyncLine;var Ge=We(),S=0,w,ze='),
    ('Vt=e=>{S=1,w&&clearTimeout(w),w=window.setTimeout(()=>{S=0},100),le(()=>G(e,T,h))}',
     'Vt=e=>harborSyncScroll(e)'),
    ('function le(e){let t=document.getElementsByTagName("img");if(t.length>0){let r=Array.from(t,n=>n.complete?Promise.resolve():new Promise(i=>{n.addEventListener("load",()=>i()),n.addEventListener("error",()=>i())}));Promise.all(r).then(()=>setTimeout(e,0))}else setTimeout(e,0)}',
     'function le(e){let revision=harborScrollRevision,run=()=>{revision===harborScrollRevision&&e()},t=document.getElementsByTagName("img");if(t.length>0){let r=Array.from(t,n=>n.complete?Promise.resolve():new Promise(i=>{n.addEventListener("load",()=>i(),{once:!0}),n.addEventListener("error",()=>i(),{once:!0})}));Promise.all(r).then(()=>setTimeout(run,0))}else setTimeout(run,0)}'),
    ('var Wt=(()=>{let e=Ge(t=>{S=1,w&&clearTimeout(w),w=window.setTimeout(()=>{S=0},50),le(()=>G(t,T,h))},50);return t=>{isNaN(t)||(A.line=t,e(t))}})();',
     'function harborSyncScroll(line){if(!Number.isFinite(line))return;harborScrollRevision++,harborSyncLine=line,A&&(A.line=line),S=1,w&&clearTimeout(w);if(!harborSyncFrame)harborSyncFrame=requestAnimationFrame(()=>{harborSyncFrame=0;try{G(harborSyncLine,T,h)}finally{w=window.setTimeout(()=>{S=0},100)}})}var Wt=harborSyncScroll;'),
    ('if(et(),S>0)return;let e=me(window.scrollY,T);',
     'if(et(),S>0)return;harborScrollRevision++;let e=me(window.scrollY,T);'),
)
# Both the package and running service are private to the patch revision. An old
# Harbor process can neither rewrite this runtime nor stop/reuse its successor.
PROFILE_LAYOUT_VERSION = 2
HOST_LAYOUT_REVISION = "builtin-terminal-" + hashlib.sha256(json.dumps((HOST_LAYOUT_PATCHES, MARKDOWN_SCROLL_PATCHES, PROFILE_LAYOUT_VERSION, PRUNED_BUILTIN_EXTENSIONS, RUNTIME_CONTENT_VERSION), separators=(",", ":")).encode()).hexdigest()[:16]
HOST_LAYOUT_PATH = "lib/vscode/out/vs/code/browser/workbench/workbench.js"


def emit(**value):
    print(json.dumps(value), flush=True)


def private(path):
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink() or path.stat().st_uid != os.getuid():
        raise RuntimeError("The editor data directory must belong to the current user.")
    os.chmod(path, 0o700)
    return path


def save(path, value):
    temp = path.with_name(path.name + "." + secrets.token_hex(8))
    temp.write_text(json.dumps(value)); os.chmod(temp, 0o600)
    os.replace(temp, path)


def load(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def session_socket(data):
    # macOS Unix socket paths must fit in 104 bytes; Application Support and
    # temporary QA roots can already exceed that before adding the filename.
    identity = hashlib.sha256(str(data.resolve()).encode()).hexdigest()[:24]
    directory = private(Path('/tmp') / ('harbor-code-%d-%s' % (os.getuid(), identity)))
    return directory / 'session.sock'


def original_host_layout(source):
    """Restore a complete known patch revision and verify the upstream bytes."""
    revisions = (HOST_LAYOUT_PATCHES,) + HOST_LAYOUT_PREVIOUS_PATCH_SETS + ((),)
    for revision in revisions:
        if any(source.count(new) != 1 for _, new in revision):
            continue
        candidate = source
        for old, new in reversed(revision):
            candidate = candidate.replace(new, old)
        if hashlib.sha256(candidate.encode("utf-8")).hexdigest() in HOST_LAYOUT_HASHES.get(VERSION, set()):
            return candidate, revision == HOST_LAYOUT_PATCHES
    raise RuntimeError("Unsupported Code-OSS workbench layout. Update Harbor before retrying.")


def patch_host_layout(binary):
    """Make the native title bar authoritative only for Harbor's embedded view.

    Preserve the upstream workbench for ordinary browser clients. Refuse unknown
    releases/edits rather than guessing at minified internals. Run under the
    runtime-install lock; the atomic replacement leaves existing clients intact.
    """
    script = binary.parent.parent / HOST_LAYOUT_PATH
    failure = "Unsupported Code-OSS workbench layout. Update Harbor before retrying."
    if script.is_symlink() or not script.is_file():
        raise RuntimeError(failure)
    original = script.read_bytes()
    try:
        source = original.decode("utf-8")
    except UnicodeDecodeError as error:
        raise RuntimeError(failure) from error
    restored, current = original_host_layout(source)
    if current:
        return
    source = restored
    for old, new in HOST_LAYOUT_PATCHES:
        if source.count(old) != 1 or new in source:
            raise RuntimeError(failure)
        source = source.replace(old, new)
    temporary = script.with_name(script.name + ".harbor-" + secrets.token_hex(8))
    try:
        temporary.write_text(source, encoding="utf-8")
        os.chmod(temporary, script.stat().st_mode & 0o777)
        os.replace(temporary, script)
    finally:
        temporary.unlink(missing_ok=True)


def original_markdown_scroll(source):
    for revision in (MARKDOWN_SCROLL_PATCHES, ()):
        if any(source.count(new) != 1 for _, new in revision):
            continue
        restored = source
        for old, new in reversed(revision):
            restored = restored.replace(new, old)
        if hashlib.sha256(restored.encode()).hexdigest() in MARKDOWN_SCROLL_HASHES.get(VERSION, set()):
            return restored, bool(revision)
    raise RuntimeError("Unsupported Code-OSS Markdown preview. Update Harbor before retrying.")


def patch_markdown_scroll(binary):
    script = binary.parent.parent / MARKDOWN_SCROLL_PATH
    if script.is_symlink() or not script.is_file():
        raise RuntimeError("Unsupported Code-OSS Markdown preview. Update Harbor before retrying.")
    source, current = original_markdown_scroll(script.read_text())
    if current:
        return
    for old, new in MARKDOWN_SCROLL_PATCHES:
        if source.count(old) != 1 or new in source:
            raise RuntimeError("Unsupported Code-OSS Markdown preview. Update Harbor before retrying.")
        source = source.replace(old, new)
    temporary = script.with_name(script.name + ".harbor-" + secrets.token_hex(8))
    try:
        temporary.write_text(source)
        os.chmod(temporary, script.stat().st_mode & 0o777)
        os.replace(temporary, script)
    finally:
        temporary.unlink(missing_ok=True)


def prune_builtin_extensions(binary):
    """Remove unused built-in extensions from this private runtime copy."""
    extensions = binary.parent.parent / "lib/vscode/extensions"
    for name in PRUNED_BUILTIN_EXTENSIONS:
        target = extensions / name
        if target.is_symlink():
            target.unlink()
        elif target.is_dir():
            shutil.rmtree(target)
    package = binary.parent.parent
    for pattern in PRUNED_RUNTIME_PATHS:
        for target in package.glob(pattern):
            if target.is_symlink() or target.is_file():
                target.unlink()
            elif target.is_dir():
                shutil.rmtree(target, ignore_errors=True)


def patch_runtime(binary):
    patch_host_layout(binary)
    patch_markdown_scroll(binary)
    prune_builtin_extensions(binary)


# The editor is asked on this machine's own loopback. A proxy named in the environment
# (http_proxy on a server, the system's Web Proxy on a Mac) cannot reach that, and going
# through it made a running editor look as if it were down.
LOOPBACK = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def available(port, timeout=1):
    try:
        with LOOPBACK.open("http://127.0.0.1:%d/healthz" % port, timeout=timeout) as r:
            return r.status == 200
    except Exception:
        return False


def clone_immutable_file(source, target):
    try:
        return os.link(source, target)
    except OSError:
        return shutil.copy2(source, target)


def file_digest(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def describe_transfer(count, total, rate):
    """12.4 of 218 MB · 31 KB/s · about 1 h 50 min left"""
    text = "%.1f of %.0f MB" % (count / 1048576, total / 1048576) if total else "%.1f MB" % (count / 1048576)
    if rate > 0:
        text += " · %.1f MB/s" % (rate / 1048576) if rate >= 1048576 else " · %.0f KB/s" % (rate / 1024)
        if total > count:
            minutes = int((total - count) / rate / 60) + 1
            text += " · about %d h %d min left" % divmod(minutes, 60) if minutes >= 60 else " · about %d min left" % minutes
    return text


# Relays of GitHub's release downloads, used by putting them before the release's address. On some
# networks GitHub itself gives a few kilobytes per second, or nothing, and one of these megabytes.
# What comes from them is installed only if its SHA-256 is the release's, as from GitHub itself.
DOWNLOAD_MIRRORS = ("", "https://ghfast.top/", "https://gh-proxy.com/", "https://ghproxy.net/")
PROBE_SECONDS = 6


def release_url(name, mirror=""):
    return (mirror if mirror in DOWNLOAD_MIRRORS else "") + "https://github.com/coder/code-server/releases/download/v%s/%s.tar.gz" % (VERSION, name)


def runtime_name():
    """The release this machine runs, as (target, name)."""
    system = {"Darwin": "macos", "Linux": "linux"}.get(platform.system())
    machine = {"arm64": "arm64", "aarch64": "arm64", "x86_64": "amd64"}.get(platform.machine())
    target = "%s-%s" % (system, machine)
    if target not in DIGESTS:
        raise RuntimeError("Code-OSS currently requires macOS or Linux on ARM64/x86-64.")
    return target, "code-server-%s-%s" % (VERSION, target)


def probe_downloads(name, seconds=PROBE_SECONDS):
    """How fast this server downloads the release from GitHub and from each relay: all at once,
    for a few seconds, in bytes per second (0 for one that sends nothing). With the size of the
    release, when one of them says it."""
    import threading
    rates, sizes = {}, []

    def measure(mirror):
        rate = 0.0
        try:
            deadline = time.monotonic() + seconds
            request = urllib.request.Request(release_url(name, mirror), headers={"User-Agent": "Harbor"})
            with urllib.request.urlopen(request, timeout=seconds) as response:
                length = int(response.headers.get("Content-Length") or 0)
                if length:
                    sizes.append(length)
                # Timed from the first bytes: connecting says little about the rate that follows.
                first, count = None, 0
                while time.monotonic() < deadline:
                    chunk = response.read1(256 * 1024)
                    if not chunk:
                        break
                    if first is None:
                        first = time.monotonic()
                    else:
                        count += len(chunk)
                if first is not None and count:
                    rate = count / max(time.monotonic() - first, 0.001)
        except Exception:
            pass
        rates[mirror] = rate

    threads = [threading.Thread(target=measure, args=(mirror,), daemon=True) for mirror in DOWNLOAD_MIRRORS]
    for thread in threads:
        thread.start()
    # One deadline for all: a name that takes long to look up (the lookup has no timeout of its own)
    # is left behind, at 0, instead of making each of the others wait in turn.
    end = time.monotonic() + seconds + 3
    for thread in threads:
        thread.join(max(0.0, end - time.monotonic()))
    return {"rates": {mirror: float(rates.get(mirror, 0.0)) for mirror in DOWNLOAD_MIRRORS}, "size": max(sizes) if sizes else 0}


def download_archive(url, partial, attempts=4):
    """Fetch `url` into `partial`, continuing from the bytes already there."""
    failure = None
    host = url.split("/")[2] if url.count("/") >= 2 else "github.com"
    for attempt in range(attempts):
        have = partial.stat().st_size if partial.is_file() and not partial.is_symlink() else 0
        if not have:
            partial.unlink(missing_ok=True)
        headers = {"User-Agent": "Harbor"}
        if have:
            headers["Range"] = "bytes=%d-" % have
        note = "Resuming at %.1f MB" % (have / 1048576) if have else "Contacting " + host
        emit(phase="Downloading Code-OSS", progress=None, detail=note + (" · attempt %d of %d" % (attempt + 1, attempts) if attempt else ""))
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as response:
                resumed = have and response.status == 206
                remaining = int(response.headers.get("Content-Length", 0))
                count = have if resumed else 0; total = count + remaining if remaining else 0
                started = time.monotonic(); first = count; last = 0
                with partial.open("ab" if resumed else "wb") as out:
                    os.chmod(partial, 0o600)
                    while True:
                        # read1 returns what has arrived: a slow path still reports every second.
                        chunk = response.read1(256 * 1024)
                        if not chunk:
                            break
                        out.write(chunk); count += len(chunk)
                        now = time.monotonic()
                        if now - last >= 1:
                            # The first seconds say nothing about the rate the path settles at.
                            last = now; rate = (count - first) / (now - started) if now - started >= 3 else 0
                            emit(phase="Downloading Code-OSS", progress=count / total if total else None, detail=describe_transfer(count, total, rate))
                if not total or count >= total:
                    return
                failure = RuntimeError("The editor download was interrupted.")
        except urllib.error.HTTPError as error:
            error.close()
            if error.code == 416:
                # The saved part is already as long as the file (or longer): verify it as it is.
                if have and attempt == 0:
                    return
                partial.unlink(missing_ok=True)
            failure = error
        except (OSError, ValueError) as error:
            failure = error
        time.sleep(min(2 + attempt * 3, 10))
    raise RuntimeError("Code-OSS could not be downloaded (%s). What arrived is kept; opening the folder again continues from there." % failure)


def adopt_interrupted_download(root, partial):
    """Earlier versions downloaded into install-*/ and lost it when interrupted.

    Called under the runtime-install lock, so no other install owns those
    directories: keep the longest download as the part to resume, drop the rest.
    """
    best = None
    for leftover in root.glob("install-*/runtime.tar.gz"):
        if leftover.is_file() and not leftover.is_symlink() and (best is None or leftover.stat().st_size > best.stat().st_size):
            best = leftover
    if best is not None and (not partial.is_file() or best.stat().st_size > partial.stat().st_size):
        os.replace(best, partial)
    for directory in root.glob("install-*"):
        if directory.is_dir() and not directory.is_symlink():
            shutil.rmtree(directory, ignore_errors=True)


class ArchiveNeeded(Exception):
    """No runtime, no reusable copy and no delivered package: the caller supplies one."""
    def __init__(self, value):
        super().__init__("archive needed"); self.value = value


def slim_state(archives, name):
    """What the Mac has delivered so far of its trimmed package."""
    part = archives / (name + ".slim.part"); note = archives / (name + ".slim.sha256")
    digest = note.read_text().strip() if note.is_file() and not note.is_symlink() else ""
    size = part.stat().st_size if part.is_file() and not part.is_symlink() else 0
    return part, note, digest, size


def install(root, archive=None, download=True, slim_digest=None, slim_total=None, mirror=""):
    target, name = runtime_name()
    revision_root = private(private(root / "runtimes") / HOST_LAYOUT_REVISION)
    destination = revision_root / name
    binary = destination / "bin/code-server"
    if binary.is_file():
        patch_runtime(binary)
        return binary
    # Copy immutable runtime files by hard link, replacing patched workbench.js
    # atomically in the new directory. Existing clients keep their original inode.
    # Unknown/partially edited donors are ignored; a verified archive is fetched.
    donors = [root / name]
    donors += sorted((root / "runtimes").glob("*/" + name))
    for donor in donors:
        if donor == destination or not (donor / "bin/code-server").is_file():
            continue
        script = donor / HOST_LAYOUT_PATH
        try:
            if script.is_symlink():
                continue
            original_host_layout(script.read_text())
            markdown = donor / MARKDOWN_SCROLL_PATH
            if markdown.is_symlink():
                continue
            original_markdown_scroll(markdown.read_text())
        except (OSError, UnicodeError, RuntimeError):
            continue
        with tempfile.TemporaryDirectory(prefix="clone-", dir=revision_root) as tmp:
            clone = Path(tmp) / name
            shutil.copytree(donor, clone, symlinks=True, copy_function=clone_immutable_file)
            patch_runtime(clone / "bin/code-server")
            os.replace(clone, destination)
        return binary
    # The archive is about 230 MB and some servers are reached over a path that
    # carries a few kilobytes per second. Keep the partial download between
    # attempts and resume it, so progress is never thrown away. A complete,
    # verified archive placed at archives/<name>.tar.gz is used as it is.
    archives = private(root / "archives")
    staged = archives / (name + ".tar.gz"); partial = archives / (name + ".tar.gz.part")
    slim_part, slim_file, slim_note, slim_size = slim_state(archives, name)
    expected = DIGESTS[target]
    with tempfile.TemporaryDirectory(prefix="install-", dir=root) as tmp:
        # Resolved, because the archive's members are checked against it after resolving them:
        # where the home directory is itself a link (/home/me -> /data/me/home), every member
        # of a perfectly good archive would otherwise look as if it left this directory.
        tmp = Path(tmp).resolve(); package = tmp / "runtime.tar.gz"
        if archive:
            shutil.copyfile(archive, package)
        elif staged.is_file() and not staged.is_symlink() and file_digest(staged) == DIGESTS[target]:
            package = staged
        elif slim_digest and slim_size and slim_note == slim_digest and file_digest(slim_part) == slim_digest:
            # Built on the Mac from the verified release and sent over this ssh session,
            # which also delivers this script: the same trust, a third of the bytes.
            package = slim_part; expected = slim_digest
        elif partial.is_file() and not partial.is_symlink() and file_digest(partial) == expected:
            # The whole official release is already here from an earlier attempt. Use it
            # rather than ask for, or fetch, a single byte more.
            package = partial
        elif not download:
            import importlib.util
            if slim_digest and slim_note == slim_digest and isinstance(slim_total, int) and 0 < slim_total <= slim_size:
                # Every byte of the Mac's package arrived and it still is not that package (two
                # uploads once wrote into one file). Resuming cannot mend it: start it again.
                slim_part.unlink(missing_ok=True); slim_file.unlink(missing_ok=True)
                slim_size = 0; slim_note = ""
            raise ArchiveNeeded({"name": name, "target": target, "directory": str(archives), "slimHave": slim_size, "slimDigest": slim_note,
                                 "xz": importlib.util.find_spec("lzma") is not None})
        else:
            staged.unlink(missing_ok=True)
            adopt_interrupted_download(root, partial)
            # From the relay the Mac chose as fastest from here; when it fails, from GitHub itself,
            # continuing from what the relay delivered (it is the same file).
            try:
                download_archive(release_url(name, mirror), partial)
            except RuntimeError:
                if not mirror:
                    raise
                download_archive(release_url(name), partial)
            package = partial
        if file_digest(package) != expected:
            if package == partial:
                partial.unlink(missing_ok=True)
            raise RuntimeError("The editor download did not pass its SHA-256 check. Please retry.")
        emit(phase="Preparing editor", progress=None)
        with tarfile.open(package) as tar:
            # Validate paths and links even after verifying the official digest.
            for item in tar.getmembers():
                base = (tmp / item.name).resolve()
                if not str(base).startswith(str(tmp) + os.sep):
                    raise RuntimeError("Unsafe path in editor archive.")
                if item.isdev() or item.isfifo():
                    raise RuntimeError("Unexpected special file in editor archive.")
                if item.issym() or item.islnk():
                    link = (base.parent / item.linkname if item.issym() else tmp / item.linkname).resolve()
                    if not str(link).startswith(str(tmp) + os.sep):
                        raise RuntimeError("Unsafe link in editor archive.")
            tar.extractall(tmp)
        os.replace(tmp / name, destination)
    for used in (staged, partial, slim_part, slim_file, archives / (name + ".slim.lock")):
        used.unlink(missing_ok=True)
    patch_runtime(binary)
    return binary


def register_bundled_extensions(extensions, bundles):
    # Code-OSS keeps an explicit extension index after its first launch. Merely
    # writing a new version directory leaves the old manifest active forever.
    index = extensions / "extensions.json"
    if not index.exists():
        return  # First launch scans all directories itself.
    installed = json.loads(index.read_text())
    if not isinstance(installed, list):
        raise RuntimeError("The editor extension index is invalid.")
    updated = list(installed)
    for name, files in bundles.items():
        manifest = json.loads(files["package.json"])
        identifier = manifest["publisher"] + "." + manifest["name"]
        if identifier not in ("harbor.workbench", "harbor.themes"):
            raise RuntimeError("Invalid bundled extension identifier.")
        updated = [entry for entry in updated if entry.get("identifier", {}).get("id") != identifier]
        updated.append({"identifier": {"id": identifier}, "version": manifest["version"],
                        "location": {"$mid": 1, "path": str(extensions / name), "scheme": "file"},
                        "relativeLocation": name})
    if updated != installed:
        save(index, updated)


def copy_profile_directory(source, target):
    # A previous editor may still be writing SQLite state. Copy ordinary durable
    # files, then take read-only SQLite snapshots instead of mixing DB/WAL epochs.
    shutil.copytree(source, target, symlinks=True,
                    ignore=shutil.ignore_patterns("*.vscdb-wal", "*.vscdb-shm", "*.vscdb-journal"))
    for database in source.rglob("*.vscdb"):
        if database.is_symlink() or not database.is_file():
            continue
        destination = target / database.relative_to(source)
        snapshot = destination.with_name(destination.name + ".harbor-snapshot")
        started = time.monotonic()
        def progress(status, remaining, total):
            if time.monotonic() - started > 5:
                raise RuntimeError("The previous editor is busy saving its workspace. Please retry.")
        try:
            with sqlite3.connect(database.resolve().as_uri() + "?mode=ro", uri=True, timeout=1) as old:
                with sqlite3.connect(snapshot) as new:
                    old.backup(new, pages=128, progress=progress, sleep=.05)
            os.chmod(snapshot, database.stat().st_mode & 0o777)
            os.replace(snapshot, destination)
        finally:
            snapshot.unlink(missing_ok=True)


def service_profile(base):
    """Isolate service lifecycle; migrate durable state once without stopping it."""
    revisions = private(base / "revisions")
    data = revisions / HOST_LAYOUT_REVISION
    if data.is_dir():
        return private(data)
    with (base / "profile-migration.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if data.is_dir():
            return private(data)
        previous = load(base / "latest-profile.json").get("revision", "")
        source = revisions / previous if previous and all(c in "abcdefghijklmnopqrstuvwxyz0123456789-" for c in previous) else base
        if not source.is_dir():
            source = base
        with tempfile.TemporaryDirectory(prefix="profile-", dir=revisions) as tmp:
            staging = Path(tmp) / "data"
            private(staging)
            user_data = private(staging / "user-data")
            # Preserve settings, global/workspace state, snippets and hot-exit
            # backups, excluding Chromium caches, logs and obsolete lock files.
            for name in ("User", "Backups", "machineid"):
                old = source / "user-data" / name
                new = user_data / name
                if old.is_dir():
                    copy_profile_directory(old, new)
                elif old.is_file():
                    shutil.copy2(old, new)
            extensions = private(staging / "extensions")
            old_extensions = source / "extensions"
            for old in old_extensions.iterdir() if old_extensions.is_dir() else ():
                if old.is_dir() and not old.name.startswith(("harbor.workbench-", "harbor.themes-")):
                    # Independent directory entries survive removal/upgrades of
                    # an old profile's immutable package version without copying
                    # the package bytes on the same filesystem.
                    shutil.copytree(old.resolve(), extensions / old.name, symlinks=True,
                                    copy_function=clone_immutable_file)
            # Let Code-OSS scan packages and generate its new local index.
            save(staging / "migration.json", {"revision": HOST_LAYOUT_REVISION, "profileVersion": PROFILE_LAYOUT_VERSION})
            os.replace(staging, data)
        save(base / "latest-profile.json", {"revision": HOST_LAYOUT_REVISION})
    return data


# Keep shell processes alive after a browser/SSH disconnect. Inspection only
# starts after the renderer lease expires; an unreadable process table is not
# evidence that the user's terminal is gone.
SUPERVISOR_SOURCE = '''import os,subprocess,sys,time,signal,json
from pathlib import Path

def has_live_terminal(root_pid):
 try:
  result=subprocess.run(["ps","-A","-o","pid=,ppid=,tty="],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,timeout=3,check=True)
  rows={}
  for line in result.stdout.splitlines():
   fields=line.split()
   if len(fields)==3:
    rows[int(fields[0])]=(int(fields[1]),fields[2])
  if root_pid not in rows: return True
  children={}
  for pid,(parent,tty) in rows.items(): children.setdefault(parent,[]).append(pid)
  pending=list(children.get(root_pid,[])); visited=set()
  while pending:
   pid=pending.pop()
   if pid in visited: continue
   visited.add(pid)
   if rows[pid][1] not in ("?","??","-"): return True
   pending.extend(children.get(pid,[]))
  return False
 except (OSError,ValueError,subprocess.SubprocessError): return True

def should_stop(data,pid,now):
 if (data/"stop").exists(): return True
 try: expired=now-(data/"lease").stat().st_mtime>1800
 except OSError: expired=True
 return expired and not has_live_terminal(pid)

def supervise():
 d=Path(sys.argv[1]); mask=os.environ.pop("HARBOR_UMASK",None)
 def restore():
  if mask is not None: os.umask(int(mask,8))
 p=subprocess.Popen(json.loads(sys.argv[2]),start_new_session=True,preexec_fn=restore); next_check=0
 while p.poll() is None:
  time.sleep(2)
  now=time.time()
  if now<next_check and not (d/"stop").exists(): continue
  next_check=now+30
  if should_stop(d,p.pid,now):
   try: os.killpg(p.pid,signal.SIGTERM)
   except ProcessLookupError: pass
   try: p.wait(timeout=8)
   except subprocess.TimeoutExpired:
    try: os.killpg(p.pid,signal.SIGKILL)
    except ProcessLookupError: pass
   break

if __name__=="__main__": supervise()
'''


def holds_harbor_data(folder, root):
    """True when the opened folder contains Harbor's own runtime and extensions.

    The editor treats extensions that live inside an untrusted workspace as part of
    it and turns them off, Harbor's included; the app explains that instead of timing out.
    """
    try:
        root.resolve().relative_to(folder.resolve()); return True
    except (ValueError, OSError):
        return False


# What an update leaves behind is removed once the new version runs here: the previous layout
# revision's runtime (hundreds of megabytes on every server), this Mac's profile for it, the
# layout before revisions existed, and directories an interrupted install never cleaned up.
# A profile is kept for a day after its successor first started, in case that one misbehaves.
PROFILE_SETTLE_SECONDS = 24 * 60 * 60
OTHER_CLIENT_SECONDS = 30 * 24 * 60 * 60


def service_alive(directory):
    """True while an editor started from this profile directory is running (it may hold terminals).

    A busy server can be slow to answer, so its supervisor process counts as well.
    """
    runtime = load(directory / "runtime.json")
    port = runtime.get("port", 0)
    if isinstance(port, int) and not isinstance(port, bool) and port > 0 and available(port):
        return True
    return supervisor_running(directory, runtime)


def supervisor_running(directory, runtime, unknown=True):
    """True while the process that was started to keep this profile's editor is still there.

    `unknown` is the answer when that cannot be told: what is being cleaned up is then left
    alone, and a start goes ahead (it used to wait for a process that was long gone, on every
    server without `ps`).
    """
    pid = runtime.get("supervisor")
    if not isinstance(pid, int) or isinstance(pid, bool) or pid <= 1:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except OSError:
        return False  # another account's process: not what this one started
    # The supervisor was started with its profile directory as an argument; another process that
    # has since been given the same number does not mention it.
    arguments = process_arguments(pid)
    return unknown if arguments is None else os.fsencode(str(directory)) in arguments


def process_arguments(pid):
    """The command line of a process as bytes, or None when there is no way to ask."""
    try:
        return Path("/proc/%d/cmdline" % pid).read_bytes()
    except OSError:
        pass  # no /proc (macOS)
    try:
        # The supervisor's -c source precedes the profile directory. macOS ps can
        # truncate that long command line, hiding the identity we need to match.
        executable = "/bin/ps" if sys.platform == "darwin" else "ps"
        listing = subprocess.run([executable, "-ww", "-p", str(pid), "-o", "args="], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=3)
    except (OSError, subprocess.SubprocessError):
        return None
    return listing.stdout if listing.returncode == 0 else b""


def age(path, now):
    try:
        return now - path.lstat().st_mtime
    except OSError:
        return float("inf")


def prune_bundled_extensions(extensions):
    """Remove earlier versions of Harbor's own extensions; the index already names the current ones.

    Only for a profile no editor is running from: a running one has the old files loaded.
    """
    names = load(extensions / ".harbor-bundles.json").get("names")
    if not isinstance(names, list) or not names or not all(
            isinstance(name, str) and (extensions / name / "package.json").is_file() for name in names):
        return []
    removed = []
    for entry in sorted(extensions.iterdir()):
        if entry.name.startswith(("harbor.workbench-", "harbor.themes-")) and entry.name not in names \
                and entry.is_dir() and not entry.is_symlink():
            shutil.rmtree(entry, ignore_errors=True); removed.append(str(entry))
    return removed


def prune(root, base, data, force=False, dry=False):
    """Remove obsolete runtimes and profiles; returns the paths (to be) removed.

    Never removed: anything of another Harbor client's profile, a profile or runtime whose editor
    still answers, the runtime another recently used client would start next, and the pre-revision
    runtime while some client here has not moved to revisions yet.
    """
    now = time.time(); removed = []
    def drop(path):
        removed.append(str(path))
        if dry:
            return
        if path.is_dir() and not path.is_symlink():
            shutil.rmtree(path, ignore_errors=True)
        else:
            path.unlink(missing_ok=True)
    settled = force or age(data / "migration.json", now) > PROFILE_SETTLE_SECONDS
    revisions = base / "revisions"
    if settled:
        for entry in sorted(revisions.iterdir()):
            if entry.name == data.name or not entry.is_dir() or entry.is_symlink():
                continue
            if entry.name.startswith("profile-"):
                if age(entry, now) > 3600:
                    drop(entry)  # a migration that was interrupted
            elif not service_alive(entry):
                socket_directory = Path("/tmp") / ("harbor-code-%d-%s" % (os.getuid(), hashlib.sha256(str(entry.resolve()).encode()).hexdigest()[:24]))
                drop(entry)
                if socket_directory.is_dir() and not dry:
                    shutil.rmtree(socket_directory, ignore_errors=True)
        # The profile from before revisions existed lives directly in the client's directory.
        if not service_alive(base):
            for name in ("user-data", "extensions", "bridges", "config.yaml", "runtime.json", "service.log", "lease", "stop", "install.lock"):
                if (base / name).exists() or (base / name).is_symlink():
                    drop(base / name)
    with (root / "runtime-install.lock").open("a") as runtime_lock:
        fcntl.flock(runtime_lock, fcntl.LOCK_EX)
        needed = {HOST_LAYOUT_REVISION}; legacy_needed = False
        for client in sorted(root.iterdir()):
            if not client.is_dir() or client.is_symlink() or not ((client / "revisions").is_dir() or (client / "user-data").is_dir()):
                continue
            for entry in (client / "revisions").iterdir() if (client / "revisions").is_dir() else ():
                if entry.is_dir() and service_alive(entry):
                    needed.add(entry.name)
            if (client / "user-data").is_dir() and service_alive(client):
                legacy_needed = True
            if client == base:
                continue
            # Another Mac's Harbor may be an older version. Keep what it would start next while it is in use.
            latest = load(client / "latest-profile.json").get("revision")
            if isinstance(latest, str) and latest:
                if age(client / "revisions" / latest / "lease", now) < OTHER_CLIENT_SECONDS:
                    needed.add(latest)
            elif age(client / "lease", now) < OTHER_CLIENT_SECONDS:
                legacy_needed = True
        runtimes = root / "runtimes"
        for entry in sorted(runtimes.iterdir()) if runtimes.is_dir() else ():
            if not entry.is_dir() or entry.is_symlink():
                continue
            if entry.name not in needed:
                drop(entry)
            else:
                for leftover in entry.glob("clone-*"):
                    drop(leftover)  # nobody is installing while this lock is held
        for entry in sorted(root.iterdir()):
            if entry.is_symlink() or not entry.is_dir():
                continue
            if entry.name.startswith("install-") and (entry / "revisions").is_dir() is False and entry != base:
                drop(entry)
            elif entry.name.startswith("code-server-") and (entry / "bin/code-server").is_file() and not legacy_needed:
                drop(entry)
    return removed


def wait_for_lock(lock, phase):
    """Takes the lock. While another start holds it this says so every few seconds: the app
    ends a start that has been silent for five minutes, and an install can take longer."""
    told = None
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB); return
        except BlockingIOError:
            pass  # held by another start; any other failure is the caller's to hear about
        now = time.monotonic()
        if told is None or now - told >= 5:
            emit(phase=phase, progress=None); told = now
        time.sleep(.25)


# How long a start waits for an editor that is running but does not answer, for one it asked to
# stop, and for the one it started.
BUSY_WAIT_SECONDS = 30
STOP_WAIT_SECONDS = 25
START_WAIT_SECONDS = 60
# The umask this script was started with, before it made its own files private.
ACCOUNT_UMASK = None


def tidy(root, data):
    """Prune after this revision's editor is known to run. Tidying up must never fail a connection."""
    try:
        prune(root, data.parent.parent, data)
    except Exception:
        pass


def main(request):
    # Per-Mac identity isolates editor state from other Harbor clients on a server.
    owner = request["owner"]
    if not owner or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-" for c in owner):
        raise RuntimeError("Invalid editor identity.")
    root = private(Path(request.get("storage") or "~/.local/share/harbor/code-oss").expanduser())
    if request.get("op") == "install":
        # Only the runtime: the Mac keeps a copy of the build its servers run, to answer the
        # editor's program files itself instead of fetching them over the link.
        with (root / "runtime-install.lock").open("a") as runtime_lock:
            wait_for_lock(runtime_lock, "Waiting for another Harbor window to finish installing the editor")
            install(root)
        emit(result={"installed": True}); return
    op = request.get("op", "start")
    if op == "probe":
        # For a server without the editor: how fast it downloads the release, and from where.
        emit(result=probe_downloads(runtime_name()[1])); return
    if op == "prune":
        # Asked for outright, for maintenance: nothing is created, and with `force` the day's
        # wait is skipped. A client that has not moved to this revision is left alone.
        base = root / owner; data = base / "revisions" / HOST_LAYOUT_REVISION
        if not data.is_dir():
            emit(result={"removed": [], "current": False}); return
        with (data / "install.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            dry = request.get("dryRun") is True
            removed = [] if dry or service_alive(data) else prune_bundled_extensions(data / "extensions")
            removed += prune(root, base, data, force=request.get("force") is True, dry=dry)
        emit(result={"removed": removed, "current": True}); return
    data = service_profile(private(root / owner)); runtime_file = data / "runtime.json"
    if op == "prepare":
        key = hashlib.sha256(os.path.realpath(os.path.expanduser(request["folder"])).encode()).hexdigest()
        (data / "bridges" / (key + ".json")).unlink(missing_ok=True)
        emit(result={"prepared": True}); return
    if op == "bridge":
        key = hashlib.sha256(os.path.realpath(os.path.expanduser(request["folder"])).encode()).hexdigest()
        bridge = load(data / "bridges" / (key + ".json"))
        runtime = load(runtime_file)
        emit(result={"port": bridge.get("port", 0), "token": runtime.get("token", "")})
        return
    if op == "stop":
        # A private request flag is consumed by the supervisor, avoiding PID reuse.
        (data / "stop").touch(); emit(result={"stopping": True}); return
    with (data / "install.lock").open("a") as lock:
        wait_for_lock(lock, "Waiting for another Harbor window to finish starting the editor")
        folder = Path(request.get("folder") or "~").expanduser().resolve()
        if not folder.is_dir():
            raise RuntimeError("The selected folder no longer exists.")
        with (root / "runtime-install.lock").open("a") as runtime_lock:
            wait_for_lock(runtime_lock, "Waiting for another Harbor client to finish installing the editor")
            try:
                binary = install(root, request.get("archive"), download=request.get("download", True) is not False,
                                 slim_digest=request.get("slimDigest"), slim_total=request.get("slimSize"), mirror=request.get("mirror") or "")
            except ArchiveNeeded as needed:
                emit(result={"needsArchive": needed.value}); return
        extensions = private(data / "extensions")
        # Harbor's own extensions are about 200 KB. They are sent once per version: a request
        # that only names their digest is answered from the copies already here.
        bundles = request.get("extensions"); bundle_digest = request.get("extensionsDigest"); marker = extensions / ".harbor-bundles.json"
        if bundles is None and bundle_digest:
            known = load(marker); names = known.get("names")
            if known.get("digest") != bundle_digest or not isinstance(names, list) or not names \
                    or not all(isinstance(name, str) and "/" not in name and (extensions / name / "package.json").is_file() for name in names):
                emit(result={"needsExtensions": True}); return
        bundles = bundles or {}
        for name, files in bundles.items():
            if "/" in name or name.startswith("."):
                raise RuntimeError("Invalid bundled extension.")
            directory = private(extensions / name)
            for filename, text in files.items():
                target = directory / filename
                if not str(target.resolve()).startswith(str(directory.resolve()) + os.sep):
                    raise RuntimeError("Invalid extension file.")
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(text)
        if bundles:
            register_bundled_extensions(extensions, bundles)
            if bundle_digest:
                save(marker, {"digest": bundle_digest, "names": sorted(bundles)})
        user = private(data / "user-data" / "User")
        settings = user / "settings.json"
        # Seed once: never overwrite personal JSONC settings or installed plugins.
        if not settings.exists():
            save(settings, request.get("settings", {}))
        runtime = load(runtime_file)
        # One that has been told to stop is on its way out, however well it still answers.
        current = runtime.get("version") == VERSION and runtime.get("layoutRevision") == HOST_LAYOUT_REVISION and not (data / "stop").exists()
        answers = available(runtime.get("port", 0))
        running = lambda: supervisor_running(data, runtime, unknown=False)
        if current and not answers and running():
            # It is running and does not answer: still starting, or the server is busy. A second
            # editor started beside it would take its profile, its port record and its password,
            # and leave the first one, terminals and all, out of reach. It is given time instead.
            emit(phase="Waiting for the editor service", progress=None)
            deadline = time.monotonic() + BUSY_WAIT_SECONDS
            while time.monotonic() < deadline and running():
                if available(runtime.get("port", 0), timeout=5):
                    answers = True; break
                time.sleep(.5)
        if current and answers:
            (data / "lease").touch()
            tidy(root, data)
            emit(result=dict(runtime, folder=str(folder), reused=True, dataInside=holds_harbor_data(folder, root))); return
        if runtime and (answers or running()):
            # One editor for a profile: what is there ends before another one starts.
            (data / "stop").touch()
            deadline = time.monotonic() + STOP_WAIT_SECONDS
            while available(runtime.get("port", 0)) or running():
                if time.monotonic() >= deadline:
                    raise RuntimeError("Close the previous editor service before upgrading it.")
                time.sleep(.15)
        with socket.socket() as sock:
            # Keep the browser origin stable across idle shutdown/app restarts.
            preferred = runtime.get("port", 0)
            if not isinstance(preferred, int) or not 1024 <= preferred <= 65535:
                preferred = 0
            try:
                sock.bind(("127.0.0.1", preferred))
            except OSError:
                sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        token = secrets.token_urlsafe(40); password = secrets.token_urlsafe(40)
        config = data / "config.yaml"
        config.write_text('bind-addr: "127.0.0.1:%d"\nauth: password\npassword: "%s"\ncert: false\n' % (port, password))
        os.chmod(config, 0o600)
        private(data / "bridges")
        for old in (data / "bridges").glob("*.json"):
            old.unlink()
        # No editor runs from this profile now, so earlier versions of Harbor's extensions can go.
        try:
            prune_bundled_extensions(extensions)
        except OSError:
            pass
        (data / "stop").unlink(missing_ok=True); (data / "lease").touch()
        env = os.environ.copy()
        # The command token is not put in the environment: every terminal and task of the editor
        # would inherit it. The bridge reads it from runtime.json, which only this account can.
        env.pop("HARBOR_CODE_TOKEN", None)
        env.update(HARBOR_CODE_DATA=str(data),
                   EXTENSIONS_GALLERY=json.dumps({"serviceUrl": "https://open-vsx.org/vscode/gallery", "itemUrl": "https://open-vsx.org/vscode/item"}))
        # Harbor's own files stay private; what the user creates in the editor and its terminals
        # gets the permissions it would get in any other login.
        if ACCOUNT_UMASK is not None:
            env["HARBOR_UMASK"] = "%o" % ACCOUNT_UMASK
        else:
            env.pop("HARBOR_UMASK", None)
        args = [str(binary), "--config", str(config), "--user-data-dir", str(data / "user-data"),
                "--extensions-dir", str(extensions), "--session-socket", str(session_socket(data)),
                "--disable-telemetry", "--disable-update-check", "--reconnection-grace-time", str(RECONNECTION_GRACE_SECONDS), str(folder)]
        # Idle services without terminals can exit. Live shells survive loss of
        # browser heartbeat and remain owned by the real Code-OSS pty host.
        log = data / "service.log"
        with log.open("wb") as output:
            supervisor_process = subprocess.Popen([sys.executable, "-c", SUPERVISOR_SOURCE, str(data), json.dumps(args)],
                stdin=subprocess.DEVNULL, stdout=output, stderr=output, env=env, start_new_session=True)
        runtime = dict(version=VERSION, layoutRevision=HOST_LAYOUT_REVISION, port=port, password=password, token=token,
                       supervisor=supervisor_process.pid, folder=str(folder))
        save(runtime_file, runtime)
        emit(phase="Starting editor", progress=None)
        deadline = time.monotonic() + START_WAIT_SECONDS
        while time.monotonic() < deadline:
            if available(port):
                tidy(root, data)
                emit(result=dict(runtime, dataInside=holds_harbor_data(folder, root))); return
            if supervisor_process.poll() is not None:
                raise RuntimeError("Editor could not start. " + log.read_text(errors="replace")[-3000:])
            time.sleep(.15)
        # What was started is left to come up: its record is the one on disk, so the next attempt
        # waits for it and uses it (a server that needs longer than this opens on the retry),
        # or ends it if it still does not answer. No second editor is started beside it.
        raise RuntimeError("Editor startup timed out. Check the server's available memory and runtime requirements.")


if __name__ == "__main__":
    try:
        ACCOUNT_UMASK = os.umask(0o077); main(json.load(sys.stdin))
    except Exception as error:
        emit(error=str(error)); sys.exit(1)
