// HttpServer.cpp  ── Qt6 port of net/http_server.cpp
// Minimal HTTP/1.0 TCP server.  One request per connection (Connection: close).

#include "HttpServer.h"
#include "MotorModel.h"

#include <QTcpSocket>
#include <QUrl>
#include <QUrlQuery>
#include <QJsonObject>
#include <QJsonArray>
#include <QJsonDocument>
#include <QDebug>

// ──────────────────────────────────────────────────────────────────────────────
// Embedded web UI — XYLOSOME terminal aesthetic, matches QML design tokens
// ──────────────────────────────────────────────────────────────────────────────
static const char INDEX_HTML[] = R"HTML(<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>XYLOSOME</title>
<style>
:root{--bg:#050505;--panel:#0E0E0E;--border:#262626;--text:#ECECEC;--dim:#888888;--faint:#4A4A4A;--accent:#4ADE80;--accent-dim:#1F6E3A;--danger:#F87171;--font:'Courier New',Courier,'DejaVu Sans Mono',monospace}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--text);font-family:var(--font);font-size:16px}
.page{max-width:853px;margin:0 auto}
.hdr{display:flex;align-items:baseline;padding:22px 30px 14px}
.hdr h1{font-size:28px;font-weight:normal}
.hdr .sub{color:var(--dim);font-size:16px;margin-left:16px}
.hdr .ver{margin-left:auto;color:var(--dim);font-size:14px}
hr{border:0;border-top:1px solid var(--border)}
.sec{padding:16px 30px}
.lbl{color:var(--dim);font-size:16px;margin-bottom:10px}
.modes{display:flex;gap:8px}
.mbtn{background:var(--panel);color:var(--text);border:1px solid var(--border);border-radius:2px;padding:8px 18px;font:inherit;font-size:16px;cursor:pointer}
.mbtn.active{border-color:var(--accent);color:var(--accent)}
.sp-val{color:var(--accent);font-size:28px;margin-bottom:8px}
input[type=range]{-webkit-appearance:none;width:100%;height:12px;background:var(--panel);border:1px solid var(--border);border-radius:1px;outline:none}
input[type=range]::-webkit-slider-thumb{-webkit-appearance:none;width:12px;height:20px;background:var(--accent);border:0;border-radius:1px;cursor:pointer}
.ticks{display:flex;justify-content:space-between;color:var(--faint);font-size:14px;margin-top:4px}
.btns{display:flex;gap:10px;align-items:center;margin-top:14px}
.btn{background:var(--panel);color:var(--text);border:1px solid var(--border);border-radius:2px;padding:12px 22px;font:inherit;font-size:16px;cursor:pointer;min-width:96px;text-align:center;user-select:none;-webkit-user-select:none}
.btn:hover{border-color:#444}
.btn:active,.btn.pressed{background:#1a1a1a}
.btn.active{border-color:var(--accent);color:var(--accent)}
.btn.pause{border-color:#6B1A1A;color:#8B2A2A;font-size:26px}
.btn.trig{font-size:24px}
.en-pill{font-size:16px;color:var(--dim)}
.en-pill.on{color:var(--accent)}
.tel{display:grid;grid-template-columns:repeat(4,1fr);gap:20px}
.tk{color:var(--dim);font-size:16px;margin-bottom:4px}
.tv{font-size:24px}
.tu{color:var(--faint);font-size:14px;margin-left:3px}
.seq-st{font-size:16px;color:var(--dim);margin-left:8px}
.seq-st.on{color:var(--accent)}
.seq-wrap{width:100%;margin-bottom:12px;overflow:hidden}
#seq_canvas{display:block;width:100%;height:auto;cursor:crosshair}
.foot{padding:8px 30px 20px;color:var(--faint);font-size:14px}
</style></head>
<body><div class="page">
<div class="hdr">
  <h1>XYLOSOME</h1>
  <span class="sub">temporal scanning unit</span>
  <span class="ver" id="ver">v0.1-qt</span>
</div><hr>
<div class="sec">
  <div class="lbl">mode</div>
  <div class="modes">
    <button class="mbtn" data-mode="position">position</button>
    <button class="mbtn" data-mode="velocity">velocity</button>
    <button class="mbtn" data-mode="torque">torque</button>
  </div>
</div><hr>
<div class="sec">
  <div class="lbl">setpoint</div>
  <div class="sp-val" id="sp_val">    0.0</div>
  <input type="range" id="setpoint" min="-100" max="100" step="1" value="0">
  <div class="ticks"><span>-100</span><span>0</span><span>+100</span></div>
  <div class="btns">
    <div class="btn" id="btn_en" role="button" tabindex="0">[enable]</div>
    <div class="btn" id="btn_z"  role="button" tabindex="0">[zero]</div>
    <span class="en-pill" id="en_pill">[ ] DISABLED</span>
  </div>
</div><hr>
<div class="sec">
  <div class="lbl">sequences</div>
  <div class="seq-wrap">
    <canvas id="seq_canvas" width="853" height="410"></canvas>
  </div>
  <div class="btns">
    <div class="btn trig active" id="btn_trig" role="button" tabindex="0">&#9654;</div>
    <div class="btn pause"       id="btn_pause" role="button" tabindex="0">&#9208;</div>
    <span class="seq-st" id="seq_st">[ ] idle</span>
  </div>
</div><hr>
<div class="sec">
  <div class="lbl">telemetry</div>
  <div class="tel">
    <div><div class="tk">position</div><span class="tv" id="pos">   0.0</span><span class="tu">deg</span></div>
    <div><div class="tk">velocity</div><span class="tv" id="vel">   0.0</span><span class="tu">deg/s</span></div>
    <div><div class="tk">current</div> <span class="tv" id="cur">  0.00</span><span class="tu">A</span></div>
    <div><div class="tk">temp</div>    <span class="tv" id="tmp">   0.0</span><span class="tu">&#176;C</span></div>
  </div>
</div><hr>
<div class="foot">shared state &#8212; touch &#8596; web in sync</div>
</div>
<script>
// ── Utilities ────────────────────────────────────────────────────────────────
const $=s=>document.querySelector(s);
const sp=$('#setpoint');
let drag=false,lastSent=0;
function sendSp(){const n=performance.now();if(n-lastSent<50)return;lastSent=n;fetch('/api/setpoint?v='+(sp.value*1.8),{method:'POST',keepalive:true}).catch(()=>{})}
sp.addEventListener('pointerdown',()=>drag=true);
sp.addEventListener('pointerup',()=>{drag=false;lastSent=0;sendSp()});
sp.addEventListener('pointercancel',()=>drag=false);
sp.addEventListener('input',()=>{$('#sp_val').textContent=(sp.value*1.8).toFixed(1).padStart(7);sendSp()});
document.querySelectorAll('.mbtn').forEach(b=>b.addEventListener('click',()=>fetch('/api/mode?v='+b.dataset.mode,{method:'POST'})));
$('#btn_en').addEventListener('click',()=>fetch('/api/enable',{method:'POST'}));
$('#btn_z').addEventListener('click',()=>fetch('/api/zero',{method:'POST'}));

// ── Sequence canvas ──────────────────────────────────────────────────────────
// Direct port of QML ScreenSequences.qml canvas drawing logic.
const SEQ = {
  canvas:     document.getElementById('seq_canvas'),
  // Layout constants matching QML
  CW:         853,
  CH:         410,
  plotPadT:   44,
  plotPadB:   34,
  boxW:       520,   // time-axis pixel width (same default as QML)
  playheadX:  -1,
  isPlaying:  false,
  rafId:      null,
  // Default nodes matching QML ListModel
  nodes: [
    {nx:0.00, ny:0.52, locked:true },
    {nx:0.27, ny:0.27, locked:false},
    {nx:0.50, ny:0.63, locked:false},
    {nx:0.70, ny:0.17, locked:false},
    {nx:1.00, ny:0.41, locked:true }
  ],
  // Rainbow palette matching QML
  palette: [
    '#C0392B','#E67E22','#D4AC0D','#7D6608','#1E8449',
    '#117A65','#1A5276','#6C3483','#922B21','#784212',
    '#F1948A','#FAD7A0','#A9DFBF','#85C1E9','#D2B4DE',
    '#E74C3C','#E59866','#82E0AA','#5DADE2','#AF7AC5',
    '#CB4335','#CA6F1E','#1D8348','#1A5276','#7D3C98',
    '#F0B27A','#A3E4D7','#AED6F1','#F9E79F','#D5D8DC',
    '#884EA0','#2E86C1','#138D75','#B7950B','#A04000',
    '#C0392B','#566573','#1B4F72','#0E6655','#6E2F1A'
  ],

  pxOfNx(nx){ return nx * this.boxW; },
  pyOfNy(ny){
    var ph = this.CH - this.plotPadT - this.plotPadB;
    return this.plotPadT + ny * ph;
  },

  // Catmull-Rom → cubic Bézier, direct JS port of QML evalSeg()
  evalSeg(seg, t){
    var ns = this.nodes, n = ns.length;
    function cl(j){ return j<0?0:(j>=n?n-1:j); }
    var xs=[],ys=[];
    for(var k=0;k<n;k++){ xs.push(this.pxOfNx(ns[k].nx)); ys.push(this.pyOfNy(ns[k].ny)); }
    var x0=xs[seg],   y0=ys[seg];
    var x1=xs[seg+1], y1=ys[seg+1];
    var c1x=x0+(xs[cl(seg+1)]-xs[cl(seg-1)])/6;
    var c1y=y0+(ys[cl(seg+1)]-ys[cl(seg-1)])/6;
    var c2x=x1-(xs[cl(seg+2)]-xs[cl(seg)])/6;
    var c2y=y1-(ys[cl(seg+2)]-ys[cl(seg)])/6;
    var mt=1-t;
    return {
      x: mt*mt*mt*x0 + 3*mt*mt*t*c1x + 3*mt*t*t*c2x + t*t*t*x1,
      y: mt*mt*mt*y0 + 3*mt*mt*t*c1y + 3*mt*t*t*c2y + t*t*t*y1
    };
  },

  // Speed magnitude 0-1 at canvas-local pixel x (for playhead velocity)
  speedAtX(px){
    var ns=this.nodes, n=ns.length;
    if(n<2) return 0;
    var nx_t=Math.max(0,Math.min(1,px/this.boxW));
    var seg=n-2;
    for(var i=0;i<n-1;i++){
      if(ns[i].nx<=nx_t && nx_t<=ns[i+1].nx){ seg=i; break; }
    }
    var lo=0,hi=1;
    for(var k=0;k<16;k++){
      var m=(lo+hi)*0.5;
      if(this.evalSeg(seg,m).x<px) lo=m; else hi=m;
    }
    var pt=this.evalSeg(seg,(lo+hi)*0.5);
    var ph=this.CH-this.plotPadT-this.plotPadB;
    var ny=(pt.y-this.plotPadT)/ph;
    return Math.min(1,Math.abs(0.5-ny)*2);
  },

  // avgVelocity for info display
  avgVelocity(){
    var ns=this.nodes, n=ns.length;
    var ph=this.CH-this.plotPadT-this.plotPadB;
    var sv=0,sd=0;
    for(var i=0;i<n-1;i++){
      for(var k=0;k<40;k++){
        var p0=this.evalSeg(i,k/40), p1=this.evalSeg(i,(k+1)/40);
        var dnx=(p1.x-p0.x)/this.boxW;
        var mny=((p0.y-this.plotPadT)/ph+(p1.y-this.plotPadT)/ph)/2;
        var v=0.5-mny;
        sv+=v*Math.abs(dnx); sd+=Math.abs(dnx);
      }
    }
    return sd>0?sv/sd:0;
  },

  formatLines(n){ return n.toString().replace(/\B(?=(\d{3})+(?!\d))/g,'.'); },

  draw(){
    var ctx=this.canvas.getContext('2d');
    var bw=this.boxW, ch=this.CH, cw=this.CW;
    var zeroY=this.pyOfNy(0.5);

    // Background — full canvas black
    ctx.fillStyle='#050505';
    ctx.fillRect(0,0,cw,ch);

    // Rainbow fill — void area right of the handle
    var voidX=bw+35, voidW=cw-voidX;
    if(voidW>0){
      var pal=this.palette, lineH=3, stride=4;
      ctx.save(); ctx.globalAlpha=0.9;
      for(var ry=0;ry<ch;ry+=stride){
        var li=Math.floor(ry/stride);
        var ci=((li*1664525+1013904223)^(li*22695477))%pal.length;
        if(ci<0) ci+=pal.length;
        ctx.fillStyle=pal[ci];
        ctx.fillRect(voidX,ry,voidW,lineH);
      }
      ctx.restore();
    }

    // Handle bar — dark green, same as QML accentDim
    ctx.fillStyle='#1F6E3A';
    ctx.fillRect(bw,0,35,ch);

    // Box fill — near-black base for grid
    ctx.fillStyle='#0A0A0A';
    ctx.fillRect(0,0,bw,ch);

    // Minor grid lines every 10px
    ctx.save();
    ctx.strokeStyle='#1C1C1C'; ctx.lineWidth=0.5;
    ctx.beginPath();
    for(var gx=0;gx<=bw;gx+=10){ ctx.moveTo(gx,0); ctx.lineTo(gx,ch); }
    for(var gy=0;gy<=ch;gy+=10){ ctx.moveTo(0,gy); ctx.lineTo(bw,gy); }
    ctx.stroke();

    // Major grid lines every 50px
    ctx.strokeStyle='#272727'; ctx.lineWidth=1;
    ctx.beginPath();
    for(var gx2=0;gx2<=bw;gx2+=50){ ctx.moveTo(gx2,0); ctx.lineTo(gx2,ch); }
    for(var gy2=0;gy2<=ch;gy2+=50){ ctx.moveTo(0,gy2); ctx.lineTo(bw,gy2); }
    ctx.stroke();
    ctx.restore();

    // Zero (time) axis — white dotted horizontal
    ctx.save();
    ctx.strokeStyle='#FFFFFF'; ctx.lineWidth=0.5; ctx.globalAlpha=0.9;
    ctx.setLineDash([2,4]);
    ctx.beginPath(); ctx.moveTo(0,zeroY); ctx.lineTo(bw,zeroY); ctx.stroke();
    ctx.setLineDash([]);
    ctx.fillStyle='#5C5C5C'; ctx.font='11px sans-serif'; ctx.textAlign='right';
    ctx.fillText('time',bw-6,zeroY-5);
    ctx.restore();

    // Speed axis — white dotted vertical
    ctx.save();
    ctx.strokeStyle='#FFFFFF'; ctx.lineWidth=0.5; ctx.globalAlpha=0.9;
    ctx.setLineDash([2,4]);
    ctx.beginPath(); ctx.moveTo(bw/2,0); ctx.lineTo(bw/2,ch); ctx.stroke();
    ctx.setLineDash([]);
    ctx.fillStyle='#5C5C5C'; ctx.font='11px sans-serif'; ctx.textAlign='center';
    ctx.save();
    ctx.translate(bw/2-9,18); ctx.rotate(-Math.PI/2);
    ctx.fillText('speed',0,0);
    ctx.restore();
    ctx.restore();

    // Playhead — red vertical line
    if(this.playheadX>=0){
      ctx.save();
      ctx.strokeStyle='#F87171'; ctx.lineWidth=1.5; ctx.globalAlpha=0.9;
      ctx.beginPath(); ctx.moveTo(this.playheadX,0); ctx.lineTo(this.playheadX,ch); ctx.stroke();
      ctx.restore();
    }

    // Info column — bottom right inside box
    var linesCount=Math.max(1,Math.round(bw/ch*8000));
    ctx.save();
    ctx.fillStyle='#606060'; ctx.font='16px monospace'; ctx.textAlign='right'; ctx.globalAlpha=1;
    ctx.fillText('lines: '+this.formatLines(linesCount),      bw-8,ch-10);
    ctx.fillText('aspect: '+(bw/ch).toFixed(2),               bw-8,ch-30);
    ctx.fillText('velocity: '+this.avgVelocity().toFixed(3),  bw-8,ch-50);
    ctx.restore();

    // Catmull-Rom spline — thin white line
    var ns=this.nodes, n=ns.length;
    if(n<2) return;
    ctx.strokeStyle='#ECECEC'; ctx.lineWidth=1;
    ctx.beginPath();
    var first=true;
    for(var i=0;i<n-1;i++){
      var lastK=(i===n-2)?20:19;
      for(var k=0;k<=lastK;k++){
        var pt=this.evalSeg(i,k/20);
        var px2=Math.max(0,Math.min(cw-1,pt.x));
        var py2=Math.max(0,Math.min(ch-1,pt.y));
        if(first){ ctx.moveTo(px2,py2); first=false; }
        else       ctx.lineTo(px2,py2);
      }
    }
    ctx.stroke();

    // Nodes — green squares
    ctx.fillStyle='#4ADE80';
    for(var ni=0;ni<n;ni++){
      var nd=ns[ni];
      var nx2=this.pxOfNx(nd.nx), ny2=this.pyOfNy(nd.ny);
      var sz=nd.locked?7:9;
      ctx.fillRect(nx2-sz/2, ny2-sz/2, sz, sz);
    }
  },

  localActionTs: 0,   // timestamp of last browser-initiated action

  // Playhead animation — port of QML playheadTimer
  tick(){
    var spd=this.speedAtX(this.playheadX);
    this.playheadX+=3*Math.max(0.08,spd);
    if(this.playheadX>=this.boxW){
      this.playheadX=-1;
      this.isPlaying=false;
      this.rafId=null;
      updateSeqStatus(false);
      this.draw();
      return;
    }
    this.draw();
    this.rafId=requestAnimationFrame(()=>this.tick());
  },

  play(){
    if(this.isPlaying) return;
    this.localActionTs=performance.now();
    if(this.playheadX<0) this.playheadX=0;
    this.isPlaying=true;
    fetch('/api/sequence?v=play',{method:'POST'}).catch(()=>{});
    this.rafId=requestAnimationFrame(()=>this.tick());
  },

  pause(){
    if(!this.isPlaying) return;
    this.localActionTs=performance.now();
    this.isPlaying=false;
    if(this.rafId){ cancelAnimationFrame(this.rafId); this.rafId=null; }
    fetch('/api/sequence?v=pause',{method:'POST'}).catch(()=>{});
    this.draw();
  },

  // Called from poll() to sync state from device → web.
  // Ignores server state for 800ms after a browser-initiated action to avoid
  // the race where poll() fires before the POST has been processed by the Pi.
  syncFromServer(playing){
    if(performance.now()-this.localActionTs < 800) return;
    if(playing && !this.isPlaying){
      if(this.playheadX<0) this.playheadX=0;
      this.isPlaying=true;
      this.rafId=requestAnimationFrame(()=>this.tick());
    } else if(!playing && this.isPlaying){
      this.isPlaying=false;
      if(this.rafId){ cancelAnimationFrame(this.rafId); this.rafId=null; }
      this.draw();
    }
  }
};

function updateSeqStatus(playing){
  const ss=$('#seq_st');
  if(playing){ ss.textContent='[X] scanning'; ss.className='seq-st on'; }
  else        { ss.textContent='[ ] idle';     ss.className='seq-st'; }
}

// ── Canvas mouse / touch interaction ────────────────────────────────────────
// Translates browser event coords → canvas coordinate space (handles CSS scaling)
SEQ.toCanvas=function(e){
  var r=this.canvas.getBoundingClientRect();
  var sx=this.CW/r.width, sy=this.CH/r.height;
  var src=e.touches?e.touches[0]:e;
  return {x:(src.clientX-r.left)*sx, y:(src.clientY-r.top)*sy};
};

SEQ.dragNode=-1;   // index of node being dragged, -1 = none
SEQ.dragHandle=false;
SEQ.dragLast={x:0,y:0};

SEQ.hitTest=function(cx,cy){
  // Check handle bar first — wider zone (±20px) to compensate for CSS scaling
  if(cx>=this.boxW-20 && cx<=this.boxW+55) return {type:'handle'};
  // Check nodes
  var ph=this.CH-this.plotPadT-this.plotPadB;
  for(var i=0;i<this.nodes.length;i++){
    var nd=this.nodes[i];
    var nx=this.pxOfNx(nd.nx), ny=this.pyOfNy(nd.ny);
    var r=nd.locked?14:16;
    if(Math.abs(cx-nx)<r && Math.abs(cy-ny)<r) return {type:'node',idx:i};
  }
  return null;
};

SEQ.onDown=function(e){
  e.preventDefault();
  var p=this.toCanvas(e);
  var hit=this.hitTest(p.x,p.y);
  if(!hit) return;
  if(hit.type==='handle'){ this.dragHandle=true; }
  else                    { this.dragNode=hit.idx; }
  this.dragLast=p;
  // Attach move+up to document so drag keeps working outside the canvas element
  this._docMove=ev=>this.onMove(ev);
  this._docUp  =ev=>this.onUp(ev);
  document.addEventListener('mousemove', this._docMove);
  document.addEventListener('mouseup',   this._docUp);
};

SEQ.onMove=function(e){
  if(e.preventDefault) e.preventDefault();
  var p=this.toCanvas(e);
  var dx=p.x-this.dragLast.x, dy=p.y-this.dragLast.y;
  this.dragLast=p;
  if(this.dragHandle){
    this.boxW=Math.max(200,Math.min(this.CW-40,this.boxW+dx));
    this.draw(); return;
  }
  if(this.dragNode<0) return;
  var i=this.dragNode, nd=this.nodes[i], ph=this.CH-this.plotPadT-this.plotPadB;
  if(!nd.locked){
    var lo=i>0?this.nodes[i-1].nx+0.04:0;
    var hi=i<this.nodes.length-1?this.nodes[i+1].nx-0.04:1;
    nd.nx=Math.max(lo,Math.min(hi,nd.nx+dx/this.boxW));
  }
  nd.ny=Math.max(0.01,Math.min(0.99,nd.ny+dy/ph));
  this.draw();
};

SEQ.onUp=function(e){
  if(this.dragNode>=0||this.dragHandle) this.pushState();
  this.dragNode=-1; this.dragHandle=false;
  // Remove document listeners
  if(this._docMove){ document.removeEventListener('mousemove',this._docMove); this._docMove=null; }
  if(this._docUp)  { document.removeEventListener('mouseup',  this._docUp);   this._docUp=null; }
};

// Ensure endpoints are always pinned at nx=0 and nx=1
SEQ.fixEndpoints=function(){
  if(this.nodes.length>=2){
    this.nodes[0].nx=0.0; this.nodes[0].locked=true;
    this.nodes[this.nodes.length-1].nx=1.0; this.nodes[this.nodes.length-1].locked=true;
  }
};

// Push curve state to Pi after every drag gesture
SEQ.pushState=function(){
  this.fixEndpoints();
  this.localActionTs=performance.now(); // debounce: block syncStateFromServer for 800ms
  // Nodes
  var payload=JSON.stringify(this.nodes.map(n=>({nx:n.nx,ny:n.ny})));
  fetch('/api/nodes',{method:'POST',headers:{'Content-Type':'application/json'},body:payload}).catch(()=>{});
  // Box width
  fetch('/api/boxw?v='+Math.round(this.boxW),{method:'POST'}).catch(()=>{});
};

// Pull nodes+boxW from server (Pi touchscreen drag → browser)
SEQ.syncStateFromServer=function(j){
  if(this.dragNode>=0||this.dragHandle) return; // user is dragging — don't clobber
  if(performance.now()-this.localActionTs < 800) return; // debounce after browser push
  if(j.nodes && j.nodes.length>=2){
    var changed=false;
    if(j.nodes.length!==this.nodes.length){ changed=true; }
    else{
      for(var i=0;i<j.nodes.length;i++){
        if(Math.abs(j.nodes[i].nx-this.nodes[i].nx)>0.002||
           Math.abs(j.nodes[i].ny-this.nodes[i].ny)>0.002){ changed=true; break; }
      }
    }
    if(changed){
      this.nodes=j.nodes.map((n,i)=>({nx:n.nx,ny:n.ny,locked:(i===0||i===j.nodes.length-1)}));
      this.fixEndpoints();
      this.draw();
    }
  }
  if(j.seqBoxW && j.seqBoxW!==Math.round(this.boxW)){
    this.boxW=j.seqBoxW;
    this.draw();
  }
};

// Find point on curve at canvas-local x — returns {seg, nx, ny}
SEQ.findOnCurve=function(cx){
  var ns=this.nodes, n=ns.length;
  var nx_t=Math.max(0.01,Math.min(0.99,cx/this.boxW));
  var seg=n-2;
  for(var i=0;i<n-1;i++){
    if(ns[i].nx<=nx_t && nx_t<=ns[i+1].nx){ seg=i; break; }
  }
  var lo=0,hi=1;
  for(var k=0;k<24;k++){
    var m=(lo+hi)*0.5;
    if(this.evalSeg(seg,m).x<cx) lo=m; else hi=m;
  }
  var pt=this.evalSeg(seg,(lo+hi)*0.5);
  var ph=this.CH-this.plotPadT-this.plotPadB;
  var ny=(pt.y-this.plotPadT)/ph;
  return {seg:seg, nx:nx_t, ny:Math.max(0.01,Math.min(0.99,ny))};
};

SEQ.onDblClick=function(e){
  var p=this.toCanvas(e);
  // Check if on a non-endpoint node → delete it
  var ph=this.CH-this.plotPadT-this.plotPadB;
  for(var i=0;i<this.nodes.length;i++){
    var nd=this.nodes[i];
    var nx=this.pxOfNx(nd.nx), ny=this.pyOfNy(nd.ny);
    if(Math.abs(p.x-nx)<20 && Math.abs(p.y-ny)<20){
      if(!nd.locked && this.nodes.length>2){
        this.nodes.splice(i,1);
        // re-lock first/last
        this.nodes[0].locked=true;
        this.nodes[this.nodes.length-1].locked=true;
        this.draw(); this.pushState();
      }
      return;
    }
  }
  // Not on a node and within box → insert node on curve
  if(p.x>=1 && p.x<this.boxW-1 && this.nodes.length<10){
    var f=this.findOnCurve(p.x);
    var newNode={nx:f.nx, ny:f.ny, locked:false};
    this.nodes.splice(f.seg+1,0,newNode);
    this.draw(); this.pushState();
  }
};

SEQ.canvas.addEventListener('mousedown', e=>SEQ.onDown(e));
SEQ.canvas.addEventListener('dblclick',  e=>SEQ.onDblClick(e));
SEQ.canvas.addEventListener('touchstart',e=>SEQ.onDown(e),{passive:false});
SEQ.canvas.addEventListener('touchmove', e=>SEQ.onMove(e),{passive:false});
SEQ.canvas.addEventListener('touchend',  e=>SEQ.onUp(e));

// Wire sequence buttons
$('#btn_trig').addEventListener('click',()=>SEQ.play());
$('#btn_pause').addEventListener('click',()=>SEQ.pause());

// Initial canvas draw
SEQ.draw();

// ── Poll /api/state at 100ms ─────────────────────────────────────────────────
async function poll(){
  try{
    const j=await(await fetch('/api/state')).json();
    if(!drag){const t=Math.round(j.setpoint/1.8);if(parseInt(sp.value)!==t)sp.value=t;$('#sp_val').textContent=j.setpoint.toFixed(1).padStart(7)}
    $('#pos').textContent=j.position.toFixed(1).padStart(7);
    $('#vel').textContent=j.velocity.toFixed(1).padStart(7);
    $('#cur').textContent=j.current.toFixed(2).padStart(7);
    $('#tmp').textContent=j.temp.toFixed(1).padStart(7);
    const pill=$('#en_pill'),btn=$('#btn_en');
    if(j.enabled){pill.textContent='[X] ENABLED ';pill.className='en-pill on';btn.textContent='[disable]';btn.classList.add('active')}
    else{pill.textContent='[ ] DISABLED';pill.className='en-pill';btn.textContent='[enable]';btn.classList.remove('active')}
    document.querySelectorAll('.mbtn').forEach(b=>b.classList.toggle('active',b.dataset.mode===j.mode));
    updateSeqStatus(j.sequencePlaying);
    SEQ.syncFromServer(j.sequencePlaying);
    SEQ.syncStateFromServer(j);
    $('#ver').textContent=j.version;
  }catch(e){}
}
setInterval(poll,100);poll();
</script>
</body></html>)HTML";

// ──────────────────────────────────────────────────────────────────────────────

HttpServer::HttpServer(MotorModel *motor, QObject *parent)
    : QObject(parent), m_motor(motor)
{
    connect(&m_server, &QTcpServer::newConnection,
            this,      &HttpServer::onNewConnection);
}

bool HttpServer::listen(quint16 port) {
    m_port = port;
    const bool ok = m_server.listen(QHostAddress::Any, port);
    if (ok)
        qInfo("[http] server listening on :%d", port);
    else
        qWarning("[http] listen failed: %s", qPrintable(m_server.errorString()));
    return ok;
}

void HttpServer::onNewConnection() {
    while (m_server.hasPendingConnections()) {
        QTcpSocket *sock = m_server.nextPendingConnection();
        connect(sock, &QTcpSocket::readyRead, this, [this, sock]() {
            handleRequest(sock);
        });
        connect(sock, &QTcpSocket::disconnected, sock, &QObject::deleteLater);
    }
}

void HttpServer::handleRequest(QTcpSocket *socket) {
    const QByteArray raw = socket->readAll();
    if (raw.isEmpty()) return;

    const int nl = raw.indexOf('\n');
    const QByteArray line = raw.left(nl < 0 ? raw.size() : nl).trimmed();
    const QList<QByteArray> parts = line.split(' ');

    // Extract HTTP body (everything after the blank header line \r\n\r\n)
    const int bodyStart = raw.indexOf("\r\n\r\n");
    const QByteArray body = (bodyStart >= 0) ? raw.mid(bodyStart + 4) : QByteArray();
    if (parts.size() < 2) { socket->disconnectFromHost(); return; }

    const QByteArray method  = parts[0];
    const QUrl       url     = QUrl::fromEncoded(parts[1]);
    const QString    path    = url.path();
    const QUrlQuery  query(url.query());

    auto respond = [&](int code, const QByteArray &ct, const QByteArray &body) {
        static const auto statusLine = [](int c) -> QByteArray {
            switch (c) {
                case 200: return "200 OK";
                case 204: return "204 No Content";
                case 404: return "404 Not Found";
                default:  return "200 OK";
            }
        };
        socket->write("HTTP/1.0 " + statusLine(code) + "\r\n"
                      "Content-Type: "   + ct + "\r\n"
                      "Content-Length: " + QByteArray::number(body.size()) + "\r\n"
                      "Access-Control-Allow-Origin: *\r\n"
                      "Connection: close\r\n"
                      "\r\n" + body);
        socket->flush();
        socket->disconnectFromHost();
    };

    if (method == "GET"  && path == "/") {
        respond(200, "text/html; charset=utf-8", QByteArray(INDEX_HTML));
    }
    else if (method == "GET"  && path == "/api/state") {
        respond(200, "application/json", buildStateJson());
    }
    else if (method == "POST" && path == "/api/setpoint") {
        if (query.hasQueryItem("v"))
            m_motor->setSetpoint(query.queryItemValue("v").toDouble());
        respond(204, "text/plain", "");
    }
    else if (method == "POST" && path == "/api/mode") {
        if (query.hasQueryItem("v")) {
            const QString v = query.queryItemValue("v");
            if      (v == "position") m_motor->setMode(MotorModel::Position);
            else if (v == "velocity") m_motor->setMode(MotorModel::Velocity);
            else if (v == "torque")   m_motor->setMode(MotorModel::Torque);
        }
        respond(204, "text/plain", "");
    }
    else if (method == "POST" && path == "/api/enable") {
        m_motor->toggleEnabled();
        respond(204, "text/plain", "");
    }
    else if (method == "POST" && path == "/api/zero") {
        m_motor->zero();
        respond(204, "text/plain", "");
    }
    else if (method == "POST" && path == "/api/sequence") {
        if (query.hasQueryItem("v"))
            m_motor->setSequencePlaying(query.queryItemValue("v") == "play");
        respond(204, "text/plain", "");
    }
    else if (method == "POST" && path == "/api/nodes") {
        // Delegate all parsing to setNodesFromJson — avoids QVariantList/QJSValue issues
        m_motor->setNodesFromJson(QString::fromUtf8(body));
        respond(204, "text/plain", "");
    }
    else if (method == "POST" && path == "/api/boxw") {
        if (query.hasQueryItem("v"))
            m_motor->setSeqBoxW(query.queryItemValue("v").toInt());
        respond(204, "text/plain", "");
    }
    else {
        respond(404, "text/plain", "404 not found");
    }
}

QByteArray HttpServer::buildStateJson() const {
    QJsonObject j;
    j[QStringLiteral("mode")]             = m_motor->modeName();
    j[QStringLiteral("setpoint")]         = m_motor->setpoint();
    j[QStringLiteral("position")]         = m_motor->position();
    j[QStringLiteral("velocity")]         = m_motor->velocity();
    j[QStringLiteral("current")]          = m_motor->current();
    j[QStringLiteral("temp")]             = m_motor->tempC();
    j[QStringLiteral("enabled")]          = m_motor->enabled();
    j[QStringLiteral("sequencePlaying")]  = m_motor->sequencePlaying();
    // Convert QVariantList of QVariantMap → QJsonArray for the API
    QJsonArray nodesArr;
    for (const QVariant &v : m_motor->nodes()) {
        const QVariantMap m = v.toMap();
        QJsonObject o;
        o["nx"] = m.value("nx").toDouble();
        o["ny"] = m.value("ny").toDouble();
        nodesArr.append(o);
    }
    j[QStringLiteral("nodes")]            = nodesArr;
    j[QStringLiteral("seqBoxW")]          = m_motor->seqBoxW();
    j[QStringLiteral("version")]          = QStringLiteral("v0.1-qt");
    return QJsonDocument(j).toJson(QJsonDocument::Compact);
}
