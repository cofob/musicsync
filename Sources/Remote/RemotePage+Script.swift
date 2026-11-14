extension RemotePage {
    /// State comes as Server-Sent Events (`/api/events`); a lost stream reconnects with backoff, and a woken phone
    /// reconnects at once. Lock screen controls use the Media Session API with a looped silent sound (`/silence.wav`).
    static let script = #"""
    "use strict";
    const $=id=>document.getElementById(id), B=document.body, wide=matchMedia("(min-width:768px) and (min-height:560px)");
    let st=null, at=0, seeking=false, es=null, volAt=0, qKey="", tab="queue", beat=0, tries=0, retry=0, open=false;
    const fmt=t=>{t=Math.max(0,Math.floor(t||0));return Math.floor(t/60)+":"+String(t%60).padStart(2,"0")};
    const esc=s=>String(s??"").replace(/[&<>"']/g,c=>"&#"+c.charCodeAt(0)+";");
    const css=u=>u?'url("'+u+'")':"";
    const icon=n=>'<svg><use href="#i-'+n+'"/></svg>';
    const pos=()=>st?Math.min(st.elapsed+(st.playing?(performance.now()-at)/1000:0),st.duration||Infinity):0;
    async function api(path,body){
      const r=await fetch(path,body===undefined?{cache:"no-store"}:{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify(body)});
      if(r.status===401){unpaired();throw new Error("unpaired")}
      return r;
    }
    const cmd=(name,args)=>api("/api/command/"+name,args||{}).then(r=>r.ok?r.json().then(apply):null).catch(()=>{});
    function toast(text){const t=$("toast");t.textContent=text;t.classList.add("on");clearTimeout(t.timer);t.timer=setTimeout(()=>t.classList.remove("on"),1600)}

    // Now Playing
    function apply(s){
      const old=st&&st.song?st.song.id:null;
      st=s; at=performance.now();
      const song=s.song;
      $("title").textContent=song?song.title:"Not Playing";
      $("artist").textContent=song?[song.artist,song.album].filter(Boolean).join(" — ")||" ":" ";
      document.title=song?song.title+" — MusicSync":"MusicSync";
      const c=song&&song.cover?css(song.cover):"";
      if($("cover").dataset.c!==c){$("cover").dataset.c=c;$("cover").style.backgroundImage=c;$("bg").style.backgroundImage=c}
      B.classList.toggle("paused",!s.playing);
      $("tg").setAttribute("href",s.playing?"#i-pause":"#i-play");
      $("toggle").setAttribute("aria-label",s.playing?"Pause":"Play");
      $("np").classList.toggle("off",!song);
      $("star").classList.toggle("on",!!s.starred);
      $("shuf").classList.toggle("on",s.shuffle);
      $("rep").classList.toggle("on",s.repeat!=="off");$("rep").classList.toggle("one",s.repeat==="one");
      if(performance.now()-volAt>800)setRange($("vol"),s.volume);
      $("seek").max=s.duration||1;
      $("outname").textContent=s.output||"";
      $("outname").classList.toggle("server",!!s.jukebox);$("out").classList.toggle("server",!!s.jukebox);
      queue();
      if((song?song.id:null)!==old){lyr=null;lyrIdx=-1;if(shows("lyrics"))lyrics()}
      session();
    }
    function setRange(el,v){el.value=v;el.style.setProperty("--p",(el.max>0?v/el.max*100:0)+"%")}
    function frame(){
      if(st&&!seeking){const t=pos();setRange($("seek"),t);$("el").textContent=fmt(t);$("rem").textContent="-"+fmt((st.duration||0)-t)}
      if(lyr&&lyr.synced&&shows("lyrics"))follow();
      requestAnimationFrame(frame);
    }
    $("toggle").onclick=()=>{unlock();if(st){st.elapsed=pos();at=performance.now();apply({...st,playing:!st.playing})}cmd("toggle")};
    $("next").onclick=()=>cmd("next");$("prev").onclick=()=>cmd("previous");
    $("star").onclick=()=>cmd("star");$("shuf").onclick=()=>cmd("shuffle");$("rep").onclick=()=>cmd("repeat");
    const seek=$("seek");
    seek.oninput=()=>{seeking=true;setRange(seek,+seek.value);$("el").textContent=fmt(+seek.value)};
    seek.onchange=()=>{const t=+seek.value;if(st){st.elapsed=t;at=performance.now()}seeking=false;cmd("seek",{time:t})};
    const vol=$("vol");let volTimer=0;
    vol.oninput=()=>{setRange(vol,+vol.value);volAt=performance.now();if(!volTimer)volTimer=setTimeout(()=>{volTimer=0;cmd("volume",{value:+vol.value})},120)};

    // Panels: a sheet on a phone, the right column on a tablet
    const shows=t=>tab===t&&(open||wide.matches);
    function show(t,sheet){
      tab=t;if(sheet!==undefined)open=sheet;
      $("side").classList.toggle("open",open);
      document.querySelectorAll("[data-tab]").forEach(b=>b.classList.toggle("on",b.dataset.tab===t&&(open||wide.matches)));
      ["queue","lyrics","lib"].forEach(n=>$("p-"+n).hidden=n!==t);
      if(t==="lyrics"&&shows("lyrics")){lyrIdx=-1;lyrics()}
      if(t==="lib"&&!libShown)lib();
    }
    document.querySelectorAll(".bar [data-tab]").forEach(b=>b.onclick=()=>show(b.dataset.tab,true));
    document.querySelectorAll(".seg [data-tab]").forEach(b=>b.onclick=()=>show(b.dataset.tab));
    $("done").onclick=()=>{show(tab,false);$("q").blur()};
    wide.onchange=()=>show(tab);

    // Up Next: tap to play, minus to remove, drag the grip to move
    function queue(){
      const k=st.queue.map(i=>i.id).join()+"|"+(st.song?st.song.id:"");
      if(k===qKey)return;qKey=k;
      $("qsub").textContent=st.queue.length?st.queue.length+(st.queue.length===1?" song":" songs"):"";
      $("ql").innerHTML=st.queue.length?st.queue.map((i,n)=>'<div class="row" data-o="'+n+'" data-id="'+esc(i.id)+'">'
        +'<button class="rm" aria-label="Remove">'+icon("minus")+'</button>'+cover(i.cover)
        +'<div class="tx"><b>'+esc(i.title)+'</b><span>'+esc(i.artist)+'</span></div><span class="grip" aria-label="Move">'+icon("grip")+'</span></div>').join("")
        :'<p class="empty">No songs up next.</p>';
    }
    const cover=(u,round,fallback)=>'<i class="'+(round?"round":"")+'" style="background-image:'+esc(u?css(u+"?size=small"):"none")+'">'+(u?"":icon(fallback||"note"))+'</i>';
    $("ql").onclick=e=>{
      const r=e.target.closest(".row");if(!r||e.target.closest(".grip"))return;
      const args={offset:+r.dataset.o,id:r.dataset.id};
      if(e.target.closest(".rm")){r.remove();cmd("remove",args)}else cmd("queue",args);
    };
    let drag=null;
    $("ql").addEventListener("pointerdown",e=>{
      const g=e.target.closest(".grip");if(!g)return;
      e.preventDefault();g.setPointerCapture(e.pointerId);
      const row=g.closest(".row"),rows=[...$("ql").querySelectorAll(".row")];
      drag={row,rows,from:+row.dataset.o,to:+row.dataset.o,y:e.clientY,h:row.offsetHeight};
      row.classList.add("drag");rows.forEach(r=>r!==row&&r.classList.add("shift"));
    });
    $("ql").addEventListener("pointermove",e=>{
      if(!drag)return;
      const dy=e.clientY-drag.y,to=Math.max(0,Math.min(drag.rows.length-1,drag.from+Math.round(dy/drag.h)));
      drag.row.style.transform="translateY("+dy+"px)";
      if(to===drag.to)return;drag.to=to;
      drag.rows.forEach(r=>{if(r===drag.row)return;const o=+r.dataset.o;
        r.style.transform=drag.from<to&&o>drag.from&&o<=to?"translateY(-"+drag.h+"px)":drag.from>to&&o>=to&&o<drag.from?"translateY("+drag.h+"px)":""});
    });
    const drop=()=>{
      if(!drag)return;const {from,to,row}=drag;drag=null;
      if(from!==to){const q=[...st.queue],[m]=q.splice(from,1);q.splice(to,0,m);st.queue=q;cmd("move",{from,to,id:row.dataset.id})}
      qKey="";queue();
    };
    $("ql").addEventListener("pointerup",drop);$("ql").addEventListener("pointercancel",drop);

    // Lyrics, following the position when they are synced
    let lyr=null,lyrIdx=-1,lyrTouch=0;
    async function lyrics(){
      const song=st&&st.song;
      if(!song){$("ly").innerHTML='<p class="empty">Not Playing</p>';return}
      if(lyr&&lyr.id===song.id)return render();
      lyr={id:song.id,loading:true};render();
      try{const l=await (await api("/api/lyrics")).json();if(!st.song||st.song.id!==l.id)return;l.synced=l.lines.length>0&&l.lines[0].start!=null;lyr=l}
      catch(e){lyr={id:song.id,lines:[]}}
      render();
    }
    function render(){
      const el=$("ly");lyrIdx=-1;
      if(lyr.loading){el.className="";el.innerHTML='<div class="lsk"></div><div class="lsk" style="width:70%"></div><div class="lsk" style="width:85%"></div>';return}
      if(!lyr.lines.length){el.innerHTML='<p class="empty">No lyrics for this song.</p>';return}
      el.className=lyr.synced?"":"plain";
      el.innerHTML=lyr.lines.map((l,n)=>'<p class="ly" data-n="'+n+'">'+(esc(l.text)||"&nbsp;")+'</p>').join("");
    }
    function follow(){
      const t=pos()+.25;let i=-1;
      for(let n=0;n<lyr.lines.length&&lyr.lines[n].start<=t;n++)i=n;
      if(i===lyrIdx)return;lyrIdx=i;
      const lines=$("ly").children;
      for(const l of lines)l.classList.toggle("on",+l.dataset.n===i);
      if(i>=0&&Date.now()-lyrTouch>3000)lines[i].scrollIntoView({block:"center",behavior:"smooth"});
    }
    $("ly").onclick=e=>{const l=e.target.closest(".ly");if(l&&lyr&&lyr.synced)cmd("seek",{time:lyr.lines[+l.dataset.n].start})};
    $("p-lyrics").addEventListener("touchmove",()=>lyrTouch=Date.now(),{passive:true});
    $("p-lyrics").addEventListener("wheel",()=>lyrTouch=Date.now(),{passive:true});

    // Library: categories, lists, opened items and search; every item can play now, next or last
    const cats=[["artist","Artists","person"],["album","Albums","album"],["playlist","Playlists","playlist"],["mix","Mixes","mix"]];
    const kindIcon={artist:"person",album:"album",playlist:"playlist",mix:"mix",song:"note"};
    let nav=[],items=[],libShown=false,libSeq=0,more=null,loadingMore=false;
    function lib(){
      libShown=true;const top=nav[nav.length-1],n=++libSeq;
      $("lback").hidden=!top;$("lbackt").textContent=nav.length>1?nav[nav.length-2].title:"Library";
      $("lt").textContent=top?(top.list?top.title:""):"Library";$("lt").hidden=!!top&&!top.list;
      $("q").hidden=!!top;more=null;items=[];
      if(!top){const q=$("q").value.trim();return q?search(q,n):($("lc").innerHTML=cats.map(c=>'<div class="row cat" data-cat="'+c[0]+'">'
        +'<i>'+icon(c[2])+'</i><div class="tx"><b>'+c[1]+'</b></div><svg class="chev"><use href="#i-chev"/></svg></div>').join(""))}
      $("lc").innerHTML='<div class="sk"></div>'.repeat(8);
      load(top,0,n);
    }
    async function load(top,offset,n){
      try{
        const r=await api(top.url+(top.url.includes("?")?"&":"?")+"offset="+offset);if(n!==libSeq)return;
        if(!r.ok)throw new Error();const l=await r.json();if(n!==libSeq)return;
        const start=items.length;items=items.concat(l.items);more=l.next!=null?()=>load(top,l.next,n):null;
        const rows=l.items.map((it,k)=>itemRow(it,start+k,top)).join("");
        if(offset===0){top.title=top.title||l.title;$("lc").innerHTML=(top.list?"":hero(top,l))+(rows||'<p class="empty">Nothing here.</p>')}
        else $("lc").insertAdjacentHTML("beforeend",rows);
      }catch(e){if(n===libSeq&&offset===0)$("lc").innerHTML='<p class="empty">Cannot load this. Try again later.</p>'}
      loadingMore=false;
    }
    function hero(top,l){
      top.hero={kind:top.kind,id:top.id,name:l.title,detail:l.detail};
      return '<div class="hero"><i class="'+(top.kind==="artist"?"round":"")+'" style="background-image:'+esc(css(l.cover))+'"></i><h2>'+esc(l.title)+'</h2>'
        +(l.detail?'<p>'+esc(l.detail)+'</p>':"")
        +'<div class="acts"><button data-act="play">'+icon("play")+'Play</button><button data-act="more">'+icon("more")+'More</button></div></div>'
        +(top.kind==="artist"?'<h3 class="sec">Albums</h3>':"");
    }
    function itemRow(it,i,top){
      const lead=top&&top.kind==="album"&&it.kind==="song"?'<span class="n">'+(i+1)+'</span>':cover(it.cover,it.kind==="artist",kindIcon[it.kind]);
      return '<div class="row" data-i="'+i+'">'+lead+'<div class="tx"><b>'+esc(it.name)+'</b>'+(it.detail?'<span>'+esc(it.detail)+'</span>':"")
        +'</div><button class="more" aria-label="More">'+icon("more")+'</button></div>';
    }
    async function search(q,n){
      $("lc").innerHTML='<div class="sk"></div>'.repeat(6);
      try{
        const l=await (await api("/api/search?q="+encodeURIComponent(q))).json();if(n!==libSeq)return;
        items=l.items;
        const groups=[["artist","Artists"],["album","Albums"],["song","Songs"],["playlist","Playlists"],["mix","Mixes"]];
        $("lc").innerHTML=items.length?groups.map(([k,title])=>{const rows=items.map((it,i)=>it.kind===k?itemRow(it,i):"").join("");
          return rows?'<h3 class="sec">'+title+'</h3>'+rows:""}).join(""):'<p class="empty">No results.</p>';
      }catch(e){if(n===libSeq&&e.message!=="unpaired")$("lc").innerHTML='<p class="empty">Cannot search now.</p>'}
    }
    const enc=encodeURIComponent;
    function openItem(it){nav.push({kind:it.kind,id:it.id,title:it.name,url:"/api/browse/"+it.kind+"/"+enc(it.id)});lib();$("p-lib").scrollTop=0}
    $("lc").onclick=e=>{
      const c=e.target.closest("[data-cat]");
      if(c){const cat=cats.find(x=>x[0]===c.dataset.cat);nav.push({list:true,kind:cat[0],title:cat[1],url:"/api/browse/"+cat[0]});lib();return}
      const act=e.target.closest("[data-act]"),top=nav[nav.length-1];
      if(act&&top){const h=top.hero;act.dataset.act==="play"?play(h,"now"):menu(h);return}
      const r=e.target.closest("[data-i]");if(!r)return;
      const it=items[+r.dataset.i];
      if(e.target.closest(".more"))return menu(it,top&&!top.list&&it.kind==="song"?{...top,start:+r.dataset.i}:null);
      if(it.kind!=="song")return openItem(it);
      top&&!top.list?play(top,"now",+r.dataset.i):play(it,"now");
    };
    $("lback").onclick=()=>{nav.pop();lib()};
    $("p-lib").addEventListener("scroll",e=>{const p=e.target;if(more&&!loadingMore&&p.scrollTop+p.clientHeight>p.scrollHeight-600){loadingMore=true;const m=more;more=null;m()}},{passive:true});
    let sTimer=0;$("q").oninput=()=>{clearTimeout(sTimer);sTimer=setTimeout(lib,300)};
    async function play(it,mode,start){
      unlock();
      try{
        const r=await api("/api/play/"+it.kind+"/"+enc(it.id)+"?mode="+mode+(start?"&start="+start:""),{});
        if(!r.ok)throw new Error();apply(await r.json());
        if(mode==="now"){toast("Playing");if(!wide.matches)setTimeout(()=>show(tab,false),300)}else toast(mode==="next"?"Playing Next":"Added to Queue");
      }catch(e){if(e.message!=="unpaired")toast("Cannot play this now")}
    }
    // An action sheet; `from` plays a collection from one of its songs.
    function menu(it,from){
      const acts=[["Play",()=>from?play(from,"now",from.start):play(it,"now")],["Play Next",()=>play(it,"next")],["Add to Queue",()=>play(it,"last")]];
      sheet('<div class="mt"><b>'+esc(it.name)+'</b>'+esc(it.detail||"")+'</div>'+acts.map((a,i)=>'<button data-m="'+i+'">'+a[0]+'</button>').join(""),acts);
    }
    let menuActs=[];
    function sheet(html,acts){$("mbox").innerHTML=html;menuActs=acts||[];$("menu").classList.add("open")}
    const closeMenu=()=>$("menu").classList.remove("open");
    $("menu").onclick=e=>{const b=e.target.closest("[data-m]");if(b){closeMenu();menuActs[+b.dataset.m][1]()}else if(!e.target.closest(".mbox")||e.target.id==="mcancel")closeMenu()};

    // Output: this Mac (its device, or the AirPlay speaker it uses) or the server; lock screen controls
    $("out").onclick=()=>{
      const s=st||{},opt=(i,sym,title,sub,on)=>'<button class="opt'+(on?" on":"")+'" data-m="'+i+'"><i>'+icon(sym)+'</i><div>'+esc(title)+'<span>'+esc(sub)+'</span></div><svg class="ck"><use href="#i-check"/></svg></button>';
      let html='<div class="mt"><b>Play On</b></div>'+opt(0,"mac","This Mac",s.jukebox?"":s.output||"",!s.jukebox);
      if(s.jukebox!=null)html+=opt(1,"server","Server",s.jukebox?s.output:"The server’s own speakers",s.jukebox);
      if(ms)html+='<label class="opt"><i>'+icon("lock")+'</i><div>Lock Screen Controls<span>Also on a paired Apple Watch. Plays silence on this device.</span></div>'
        +'<span class="sw"><input type="checkbox" id="lock"'+(lockOn?" checked":"")+'><span></span></span></label>';
      sheet(html,[["mac",()=>cmd("output",{server:false})],["server",()=>cmd("output",{server:true})]]);
      const l=$("lock");if(l)l.onchange=()=>{lockOn=l.checked;try{localStorage.setItem("lock",lockOn?"1":"0")}catch(e){}unlock();session()};
    };

    // Media Session: the lock screen, Control Center and Apple Watch show what plays while the silent sound loops
    const ms=navigator.mediaSession,keep=$("keep");let lockOn=false,metaKey="";
    try{lockOn=localStorage.getItem("lock")==="1"}catch(e){}
    // A tap lets the page start sound; later starts from events need that first one.
    function unlock(){if(ms&&lockOn&&keep.paused)keep.play().catch(()=>{})}
    function session(){
      if(!ms)return;
      const song=st&&st.song;
      if(!lockOn||!song){if(!keep.paused)keep.pause();if(metaKey)ms.metadata=null;metaKey="";return}
      const k=song.id+"|"+song.title;
      if(k!==metaKey){metaKey=k;try{ms.metadata=new MediaMetadata({title:song.title,artist:song.artist||"",album:song.album||"",
        artwork:song.cover?[{src:song.cover,sizes:"600x600",type:"image/jpeg"}]:[]})}catch(e){}}
      ms.playbackState=st.playing?"playing":"paused";
      if(st.playing&&keep.paused)keep.play().catch(()=>{});else if(!st.playing&&!keep.paused)keep.pause();
      try{if(st.duration>0)ms.setPositionState({duration:st.duration,position:Math.min(pos(),st.duration),playbackRate:1})}catch(e){}
    }
    if(ms){
      const h=(a,f)=>{try{ms.setActionHandler(a,f)}catch(e){}};
      h("play",()=>{keep.play().catch(()=>{});cmd("play")});h("pause",()=>{keep.pause();cmd("pause")});
      h("previoustrack",()=>cmd("previous"));h("nexttrack",()=>cmd("next"));
      h("seekto",d=>{if(d.seekTime!=null)cmd("seek",{time:d.seekTime})});
      h("seekbackward",null);h("seekforward",null);
    }

    // Live updates
    function connect(){
      if(es)es.close();
      es=new EventSource("/api/events");beat=Date.now();
      es.addEventListener("state",e=>{beat=Date.now();tries=0;B.classList.remove("unpaired");apply(JSON.parse(e.data))});
      es.addEventListener("ping",()=>beat=Date.now());
      es.onerror=later;
    }
    // Our own retry instead of the browser's: backoff with jitter up to 30 s, and a 401 shows the pairing screen.
    function later(){
      if(es){es.close();es=null}
      clearTimeout(retry);
      const wait=Math.min(30000,1000*2**tries++)*(.75+Math.random()/2);
      retry=setTimeout(check,wait);
    }
    async function check(){
      clearTimeout(retry);
      try{const r=await api("/api/state");if(!r.ok)throw new Error();B.classList.remove("unpaired");apply(await r.json());connect()}
      catch(e){if(e.message!=="unpaired")later()}
    }
    function unpaired(){B.classList.add("unpaired");if(es){es.close();es=null}clearTimeout(retry)}
    // A stream that missed two pings died while the phone slept.
    setInterval(()=>{if(es&&!document.hidden&&Date.now()-beat>50000){tries=0;check()}},10000);
    const wake=()=>{if(!document.hidden&&!B.classList.contains("unpaired")){tries=0;check()}};
    document.addEventListener("visibilitychange",wake);addEventListener("pageshow",e=>{if(e.persisted)wake()});addEventListener("online",wake);

    // Pairing: the QR code link (/pair?t=…) or the 6-digit code
    const deviceName=()=>{const ua=navigator.userAgent;return /Watch/.test(ua)?"Apple Watch":/iPad/.test(ua)||(/Macintosh/.test(ua)&&navigator.maxTouchPoints>1)?"iPad":/iPhone/.test(ua)?"iPhone":""};
    async function pair(body){
      const r=await fetch("/api/pair",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({...body,name:deviceName()})}).catch(()=>null);
      if(r&&r.ok){$("code").value="";$("msg").textContent="";B.classList.remove("unpaired");tries=0;check();return true}
      $("msg").textContent=!r?"Cannot reach the Mac.":r.status===429?"Too many tries. Wait a minute.":body.link?"This QR code was used or expired. Type the code instead."
        :r.status===403?"Click Pair a Device on the Mac first.":"Wrong code.";
      return false;
    }
    $("go").onclick=()=>{const code=$("code").value.replace(/\D/g,"");code.length===6?pair({code}):$("msg").textContent="Type the 6-digit code."};
    $("code").onkeydown=e=>{if(e.key==="Enter")$("go").onclick()};
    const link=location.pathname==="/pair"?new URLSearchParams(location.search).get("t"):null;
    if(link!==null)history.replaceState(null,"","/");
    show("queue",false);requestAnimationFrame(frame);
    link?pair({link}).then(ok=>{if(!ok)check()}):check();

    """#
}
