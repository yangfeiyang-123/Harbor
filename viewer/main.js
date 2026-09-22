import {AppStreamer, StreamType} from '@nvidia/omniverse-webrtc-streaming-library';
const q = new URLSearchParams(location.hash.slice(1));
const server=q.get('host'), port=Number(q.get('port')||49100);
const status=document.querySelector('#status'), notice=document.querySelector('#notice'), video=document.querySelector('video');
document.querySelector('#title').textContent=q.get('name')||'Harbor · Simulation';
document.title=(q.get('name')||'Simulation')+' · Harbor';
const failed=()=>{status.textContent='Connection interrupted';notice.style.display='block';notice.textContent='Check your VPN and that the simulation is running. Only one viewer can connect at a time. Close the other viewer, then reconnect.';};
document.querySelector('#retry').onclick=()=>location.reload();
document.querySelector('#full').onclick=()=>document.documentElement.requestFullscreen();
video.addEventListener('playing',()=>{status.textContent='Live';notice.style.display='none';video.focus();});
video.addEventListener('stalled',()=>{status.textContent='Waiting for video…';});
if (!server || !/^[a-zA-Z0-9.:-]+$/.test(server) || port<1 || port>65535) failed();
else AppStreamer.connect({streamSource:StreamType.DIRECT,streamConfig:{
 signalingServer:server,signalingPort:port,mediaServer:server,mediaPort:47998,
 videoElementId:'remote-video',audioElementId:'remote-audio',authenticate:true,
 width:1280,height:720,fps:30,mic:false,maxReconnects:5,nativeTouchEvents:true,
 onStart:()=>{status.textContent='Receiving video…';},onStop:failed,onTerminate:failed,
 onUpdate:(event)=>{if(event.status==='error')failed();}
}}).catch(failed);

// App controls are authoritative; leaving Harbor disconnects media without stopping the remote job.
if (location.pathname !== '/') {
 let failures=0;
 const heartbeat=setInterval(async()=>{
  try { const response=await fetch('./health',{cache:'no-store'}); if(!response.ok) throw Error(); failures=0; }
  catch { if(++failures>=2) { clearInterval(heartbeat); await AppStreamer.stop().catch(()=>{}); status.textContent='Disconnected from Harbor'; } }
 },5000);
}
