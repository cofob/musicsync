/// The remote web app: one page with inline styles and script, no outside requests.
/// It is a remote only; the Mac plays the music. A narrow screen (Apple Watch) gets the compact layout.
public enum RemotePage {
    public static let manifest = #"""
    {"name":"MusicSync Remote","short_name":"MusicSync","start_url":"/","display":"standalone",
     "background_color":"#000000","theme_color":"#000000","icons":[{"src":"/icon.png","sizes":"180x180","type":"image/png"}]}
    """#

    public static let html = #"""
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover,user-scalable=no">
    <meta name="disabled-adaptations" content="watch">
    <meta name="apple-mobile-web-app-capable" content="yes">
    <meta name="mobile-web-app-capable" content="yes">
    <meta name="apple-mobile-web-app-status-bar-style" content="black-translucent">
    <meta name="apple-mobile-web-app-title" content="MusicSync">
    <meta name="color-scheme" content="light dark">
    <meta name="theme-color" content="#000000">
    <link rel="manifest" href="/manifest.webmanifest">
    <link rel="apple-touch-icon" href="/apple-touch-icon.png">
    <title>MusicSync</title>
    <style>
    :root{--accent:#fa243c;--bg:#f2f2f7;--fg:#111;--fg2:rgba(0,0,0,.55);--fill:rgba(0,0,0,.1);--sheet:rgba(255,255,255,.82);--glow:.38;
      --top:env(safe-area-inset-top);--bottom:env(safe-area-inset-bottom);color-scheme:light dark}
    @media (prefers-color-scheme:dark){:root{--bg:#000;--fg:#fff;--fg2:rgba(255,255,255,.6);--fill:rgba(255,255,255,.16);--sheet:rgba(28,28,30,.82);--glow:.6}}
    *{box-sizing:border-box;-webkit-tap-highlight-color:transparent;margin:0}
    html,body{height:100%;background:var(--bg);color:var(--fg);font:16px -apple-system,system-ui,sans-serif;overflow:hidden;
      -webkit-user-select:none;user-select:none;-webkit-touch-callout:none}
    button{font:inherit;color:inherit;background:none;border:0;padding:0;cursor:pointer;display:grid;place-items:center}
    svg{width:100%;height:100%;fill:currentColor}
    .s{fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round}
    #bg{position:fixed;inset:-20%;background:center/cover;filter:blur(60px) saturate(1.8);opacity:var(--glow);transition:background-image .6s}
    main{position:relative;height:100%;display:flex;flex-direction:column;max-width:520px;margin:0 auto;
      padding:calc(var(--top) + 20px) 28px calc(var(--bottom) + 14px)}
    #art{flex:1;min-height:0;display:flex;align-items:center;justify-content:center}
    #cover{width:min(100%,46vh);aspect-ratio:1;border-radius:12px;background:var(--fill) center/cover;
      box-shadow:0 18px 50px rgba(0,0,0,.35);transition:transform .45s cubic-bezier(.3,1.4,.5,1)}
    body.paused #cover{transform:scale(.84)}
    .info{display:flex;align-items:center;gap:12px;margin-top:26px}
    .info div{flex:1;min-width:0}
    .t{font-size:21px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .a{font-size:19px;color:var(--fg2);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    #star{width:30px;height:30px;padding:3px;color:var(--fg2)}#star.on{color:var(--accent)}
    input[type=range]{-webkit-appearance:none;appearance:none;width:100%;height:28px;background:transparent;margin:0}
    input[type=range]::-webkit-slider-runnable-track{height:6px;border-radius:3px;
      background:linear-gradient(var(--fg2),var(--fg2)) 0/var(--p,0%) 100% no-repeat,var(--fill)}
    input[type=range]::-webkit-slider-thumb{-webkit-appearance:none;width:14px;height:14px;margin-top:-4px;border-radius:50%;background:transparent}
    input[type=range]:active::-webkit-slider-runnable-track{height:10px;margin-top:-2px}
    #seek{margin-top:16px}
    .times{display:flex;justify-content:space-between;font-size:12px;color:var(--fg2);font-variant-numeric:tabular-nums;margin-top:-2px}
    .ctl{display:flex;justify-content:space-evenly;align-items:center;margin:14px 0 18px}
    .ctl button{width:54px;height:54px;transition:transform .15s}.ctl button:active{transform:scale(.86)}
    #toggle{width:74px;height:74px}
    .vol{display:flex;align-items:center;gap:10px;color:var(--fg2)}.vol svg{width:20px;height:20px;flex:none}
    .bar{display:flex;justify-content:space-around;margin-top:20px;color:var(--fg2)}
    .bar button{width:44px;height:44px;padding:10px;border-radius:10px;position:relative}
    .bar button.on{color:var(--accent);background:var(--fill)}
    #one{position:absolute;font-size:9px;font-weight:700;right:7px;bottom:6px;display:none}#rep.one #one{display:block}
    .sheet{position:fixed;inset:0;z-index:2;display:flex;flex-direction:column;background:var(--sheet);
      -webkit-backdrop-filter:blur(30px) saturate(1.6);backdrop-filter:blur(30px) saturate(1.6);
      padding:calc(var(--top) + 12px) 0 var(--bottom);transform:translateY(105%);transition:transform .35s cubic-bezier(.2,.9,.3,1)}
    .sheet.open{transform:none}
    .head{display:flex;align-items:center;gap:12px;padding:6px 20px 10px}
    .head h2{flex:1;font-size:22px}.head .done{color:var(--accent);font-weight:600;font-size:17px}
    .list{flex:1;overflow-y:auto;-webkit-overflow-scrolling:touch;padding:0 20px 20px}
    .row{display:flex;align-items:center;gap:12px;width:100%;text-align:left;padding:7px 0;border-bottom:.5px solid var(--fill)}
    .row i{width:44px;height:44px;flex:none;border-radius:6px;background:var(--fill) center/cover}
    .row div{flex:1;min-width:0}.row b,.row span{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .row b{font-weight:500}.row span{font-size:14px;color:var(--fg2)}
    .empty{color:var(--fg2);text-align:center;padding:40px 0}
    #q{flex:1;font:inherit;color:inherit;background:var(--fill);border:0;border-radius:10px;padding:9px 12px;outline:none;-webkit-user-select:text;user-select:text}
    #pair{position:fixed;inset:0;z-index:3;background:var(--bg);display:none;flex-direction:column;align-items:center;justify-content:center;
      gap:14px;padding:24px;text-align:center}
    body.unpaired #pair{display:flex}
    #pair img{width:84px;height:84px;border-radius:20px}
    #pair p{color:var(--fg2);max-width:300px}
    #code{font:600 32px ui-monospace,monospace;letter-spacing:.3em;text-align:center;width:250px;padding:10px;border-radius:12px;
      border:0;background:var(--fill);color:inherit;outline:none;-webkit-user-select:text;user-select:text}
    #go{background:var(--accent);color:#fff;font-weight:600;border-radius:12px;padding:12px 40px}
    #msg{color:var(--accent);min-height:1.2em}
    .off .ctl,.off .bar,.off .vol,.off #seek,.off .times{opacity:.35;pointer-events:none}
    @media (max-width:260px){
      main{padding:4px 6px;justify-content:center}
      #art,.vol,.bar,.times,#star{display:none}
      .info{margin:0;text-align:center}.t{font-size:15px}.a{font-size:13px}
      #seek{margin-top:6px;height:12px;pointer-events:none}
      input[type=range]::-webkit-slider-runnable-track{height:3px}
      .ctl{margin:8px 0 0}.ctl button{width:38px;height:38px}#toggle{width:56px;height:56px}
      #pair img,#pair p{display:none}#code{font-size:20px;width:100%}#go{padding:8px 20px}
    }
    </style>
    </head>
    <body class="paused">
    <svg style="display:none">
    <symbol id="i-play" viewBox="0 0 24 24"><path d="M7 4.5v15c0 .8.9 1.3 1.6.8l11.5-7.5c.6-.4.6-1.2 0-1.6L8.6 3.7C7.9 3.2 7 3.7 7 4.5z"/></symbol>
    <symbol id="i-pause" viewBox="0 0 24 24"><rect x="5.5" y="4" width="4.5" height="16" rx="1.2"/><rect x="14" y="4" width="4.5" height="16" rx="1.2"/></symbol>
    <symbol id="i-next" viewBox="0 0 24 24"><path d="M2 6.6v10.8c0 .7.8 1.1 1.3.7L11 13v4.4c0 .7.8 1.1 1.3.7l8.3-5.4c.5-.3.5-1.1 0-1.4l-8.3-5.4c-.5-.4-1.3 0-1.3.7V11L3.3 5.9C2.8 5.5 2 5.9 2 6.6z"/></symbol>
    <symbol id="i-star" viewBox="0 0 24 24"><path class="s" d="M12 3.2l2.7 5.6 6.1.8-4.5 4.3 1.1 6.1L12 17.1 6.6 20l1.1-6.1-4.5-4.3 6.1-.8z"/></symbol>
    <symbol id="i-shuffle" viewBox="0 0 24 24"><path class="s" d="M3 6.5h3.2c4.5 0 6.6 11 11 11H21M18 14.5l3 3-3 3M3 17.5h3.2c1.6 0 2.8-1.4 3.9-3.3M13.8 9.6c1-1.7 2.2-3.1 3.9-3.1H21M18 3.5l3 3-3 3"/></symbol>
    <symbol id="i-repeat" viewBox="0 0 24 24"><path class="s" d="M3.5 11.5V10a3.5 3.5 0 0 1 3.5-3.5h13M17 3.5l3 3-3 3M20.5 12.5V14a3.5 3.5 0 0 1-3.5 3.5H4M7 20.5l-3-3 3-3"/></symbol>
    <symbol id="i-list" viewBox="0 0 24 24"><path class="s" d="M9 6h12M9 12h12M9 18h12"/><circle cx="4" cy="6" r="1.5"/><circle cx="4" cy="12" r="1.5"/><circle cx="4" cy="18" r="1.5"/></symbol>
    <symbol id="i-search" viewBox="0 0 24 24"><circle class="s" cx="10.5" cy="10.5" r="6.5"/><path class="s" d="M15.5 15.5L21 21"/></symbol>
    <symbol id="i-low" viewBox="0 0 24 24"><path d="M3 9.5h3.5L11 5.5v13l-4.5-4H3z"/></symbol>
    <symbol id="i-high" viewBox="0 0 24 24"><path d="M3 9.5h3.5L11 5.5v13l-4.5-4H3z"/><path class="s" d="M14.5 9a4.5 4.5 0 0 1 0 6M17.5 6.5a8 8 0 0 1 0 11"/></symbol>
    </svg>
    <div id="bg"></div>
    <main class="off">
      <div id="art"><div id="cover"></div></div>
      <div class="info"><div><div class="t" id="title">Not Playing</div><div class="a" id="artist">&nbsp;</div></div>
        <button id="star" aria-label="Favorite"><svg><use href="#i-star"/></svg></button></div>
      <input id="seek" type="range" min="0" max="1" step="0.1" value="0" aria-label="Position">
      <div class="times"><span id="el">0:00</span><span id="rem">-0:00</span></div>
      <div class="ctl">
        <button id="prev" aria-label="Previous"><svg style="transform:scaleX(-1)"><use href="#i-next"/></svg></button>
        <button id="toggle" aria-label="Play"><svg><use id="tg" href="#i-play"/></svg></button>
        <button id="next" aria-label="Next"><svg><use href="#i-next"/></svg></button>
      </div>
      <div class="vol"><svg><use href="#i-low"/></svg><input id="vol" type="range" min="0" max="1" step="0.01" aria-label="Volume"><svg><use href="#i-high"/></svg></div>
      <div class="bar">
        <button id="shuf" aria-label="Shuffle"><svg><use href="#i-shuffle"/></svg></button>
        <button id="rep" aria-label="Repeat"><svg><use href="#i-repeat"/></svg><span id="one">1</span></button>
        <button id="openq" aria-label="Up Next"><svg><use href="#i-list"/></svg></button>
        <button id="opens" aria-label="Search"><svg><use href="#i-search"/></svg></button>
      </div>
    </main>
    <section class="sheet" id="queue"><div class="head"><h2>Up Next</h2><button class="done">Done</button></div><div class="list" id="ql"></div></section>
    <section class="sheet" id="search"><div class="head"><input id="q" type="search" placeholder="Albums and Playlists" autocomplete="off"><button class="done">Done</button></div><div class="list" id="sl"></div></section>
    <div id="pair"><img src="/icon.png" alt=""><h2>Pair with MusicSync</h2>
      <p>On your Mac, open MusicSync Settings &gt; Remote, click Pair a Device and type the code.</p>
      <input id="code" inputmode="numeric" autocomplete="one-time-code" maxlength="6" placeholder="000000">
      <button id="go">Pair</button><div id="msg"></div></div>
    <script>
    "use strict";
    const $=id=>document.getElementById(id), B=document.body;
    let st=null, at=0, seeking=false, es=null, volAt=0, qKey="";
    const fmt=t=>{t=Math.max(0,Math.floor(t||0));return Math.floor(t/60)+":"+String(t%60).padStart(2,"0")};
    const esc=s=>String(s??"").replace(/[&<>"']/g,c=>"&#"+c.charCodeAt(0)+";");
    const css=u=>u?'url("'+u+'")':"";
    async function api(path,body){
      const r=await fetch(path,body===undefined?{}:{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(body)});
      if(r.status===401){B.classList.add("unpaired");throw new Error("unpaired")}
      return r;
    }
    const cmd=(name,args)=>api("/api/command/"+name,args||{}).catch(()=>{});
    function apply(s){
      st=s; at=performance.now();
      const song=s.song;
      $("title").textContent=song?song.title:"Not Playing";
      $("artist").textContent=song?[song.artist,song.album].filter(Boolean).join(" — ")||" ":" ";
      document.title=song?song.title+" — MusicSync":"MusicSync";
      const c=song&&song.cover?css(song.cover):"";
      if($("cover").dataset.c!==c){$("cover").dataset.c=c;$("cover").style.backgroundImage=c;$("bg").style.backgroundImage=c}
      B.classList.toggle("paused",!s.playing);
      $("tg").setAttribute("href",s.playing?"#i-pause":"#i-play");
      $("toggle").setAttribute("aria-label",s.playing?"Pause":"Play");
      document.querySelector("main").classList.toggle("off",!song);
      $("star").classList.toggle("on",s.starred);
      $("shuf").classList.toggle("on",s.shuffle);
      $("rep").classList.toggle("on",s.repeat!=="off");$("rep").classList.toggle("one",s.repeat==="one");
      if(performance.now()-volAt>800)setRange($("vol"),s.volume);
      $("seek").max=s.duration||1;
      const k=s.queue.map(i=>i.id).join();
      if(k!==qKey){qKey=k;$("ql").innerHTML=s.queue.length?s.queue.map((i,n)=>row(i.cover,i.title,i.artist,'data-o="'+n+'" data-id="'+esc(i.id)+'"')).join(""):'<p class="empty">No songs up next.</p>'}
    }
    const row=(cover,a,b,attr)=>'<button class="row" '+attr+'><i style="background-image:'+esc(cover?css(cover+"?size=small"):"none")+'"></i><div><b>'+esc(a)+'</b><span>'+esc(b)+'</span></div></button>';
    function setRange(el,v){el.value=v;el.style.setProperty("--p",(el.max>0?v/el.max*100:0)+"%")}
    function frame(){
      if(st&&!seeking){
        const t=Math.min(st.elapsed+(st.playing?(performance.now()-at)/1000:0),st.duration||Infinity);
        setRange($("seek"),t);$("el").textContent=fmt(t);$("rem").textContent="-"+fmt((st.duration||0)-t);
      }
      requestAnimationFrame(frame);
    }
    function connect(){
      if(es)es.close();
      es=new EventSource("/api/events");
      es.addEventListener("state",e=>{B.classList.remove("unpaired");apply(JSON.parse(e.data))});
      es.onerror=()=>{if(es.readyState===2){es=null;setTimeout(check,2000)}};
    }
    async function check(){
      try{const r=await api("/api/state");if(r.ok){B.classList.remove("unpaired");apply(await r.json());connect()}}
      catch(e){if(e.message!=="unpaired")setTimeout(check,3000)}
    }
    $("toggle").onclick=()=>{if(st){st.elapsed+=(st.playing?(performance.now()-at)/1000:0);apply({...st,playing:!st.playing})}cmd("toggle")};
    $("next").onclick=()=>cmd("next");$("prev").onclick=()=>cmd("previous");
    $("star").onclick=()=>cmd("star");$("shuf").onclick=()=>cmd("shuffle");$("rep").onclick=()=>cmd("repeat");
    const seek=$("seek");
    seek.oninput=()=>{seeking=true;setRange(seek,+seek.value);$("el").textContent=fmt(+seek.value)};
    seek.onchange=()=>{const t=+seek.value;if(st){st.elapsed=t;at=performance.now()}seeking=false;cmd("seek",{time:t})};
    const vol=$("vol");let volTimer=0;
    vol.oninput=()=>{setRange(vol,+vol.value);volAt=performance.now();if(!volTimer)volTimer=setTimeout(()=>{volTimer=0;cmd("volume",{value:+vol.value})},120)};
    const sheet=(id,open)=>$(id).classList.toggle("open",open);
    $("openq").onclick=()=>sheet("queue",true);
    $("opens").onclick=()=>{sheet("search",true);setTimeout(()=>$("q").focus(),350)};
    document.querySelectorAll(".done").forEach(b=>b.onclick=()=>{sheet("queue",false);sheet("search",false);$("q").blur()});
    $("ql").onclick=e=>{const r=e.target.closest(".row");if(r){cmd("queue",{offset:+r.dataset.o,id:r.dataset.id});sheet("queue",false)}};
    let sTimer=0,sSeq=0;
    $("q").oninput=()=>{clearTimeout(sTimer);sTimer=setTimeout(search,300)};
    async function search(){
      const q=$("q").value.trim(),n=++sSeq;
      if(!q){$("sl").innerHTML="";return}
      try{const r=await api("/api/search?q="+encodeURIComponent(q));const items=(await r.json()).items;if(n!==sSeq)return;
        $("sl").innerHTML=items.length?items.map(i=>row(i.cover,i.name,(i.kind==="playlist"?"Playlist":"Album")+(i.detail?" · "+i.detail:""),'data-k="'+i.kind+'" data-id="'+esc(i.id)+'"')).join(""):'<p class="empty">No results.</p>'}
      catch(e){}
    }
    $("sl").onclick=e=>{const r=e.target.closest(".row");if(r){api("/api/play/"+r.dataset.k+"/"+encodeURIComponent(r.dataset.id),{}).catch(()=>{});sheet("search",false)}};
    async function pair(){
      const code=$("code").value.replace(/\D/g,"");if(code.length!==6){$("msg").textContent="Type the 6-digit code.";return}
      const ua=navigator.userAgent,name=/Watch/.test(ua)?"Apple Watch":/iPad/.test(ua)?"iPad":/iPhone/.test(ua)?"iPhone":"";
      const r=await fetch("/api/pair",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({code,name})}).catch(()=>null);
      if(r&&r.ok){$("code").value="";$("msg").textContent="";B.classList.remove("unpaired");check();return}
      $("msg").textContent=!r?"Cannot reach the Mac.":r.status===429?"Too many tries. Wait a minute.":r.status===403?"Click Pair a Device on the Mac first.":"Wrong code.";
    }
    $("go").onclick=pair;$("code").onkeydown=e=>{if(e.key==="Enter")pair()};
    document.addEventListener("visibilitychange",()=>{if(!document.hidden&&!es)check()});
    check();requestAnimationFrame(frame);
    </script>
    </body>
    </html>
    """#
}
