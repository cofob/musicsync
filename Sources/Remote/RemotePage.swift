/// The remote web app: one page with inline styles and script, no outside requests.
/// It is a remote only; the Mac plays the music. A phone gets Now Playing with sheets for Up Next, Lyrics and the
/// Library; a tablet shows them beside Now Playing; a narrow screen (Apple Watch) gets the compact layout.
public enum RemotePage {
    public static let manifest = #"""
    {"name":"MusicSync Remote","short_name":"MusicSync","id":"/","start_url":"/","scope":"/","display":"standalone",
     "background_color":"#000000","theme_color":"#000000","icons":[{"src":"/icon.png","sizes":"180x180","type":"image/png"}]}
    """#

    public static let html = head + style + body + "<script>\n" + script + "</script>\n</body>\n</html>\n"

    static let head = #"""
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
    <meta name="theme-color" media="(prefers-color-scheme: light)" content="#f2f2f7">
    <meta name="theme-color" media="(prefers-color-scheme: dark)" content="#000000">
    <link rel="manifest" href="/manifest.webmanifest">
    <link rel="apple-touch-icon" href="/apple-touch-icon.png">
    <title>MusicSync</title>

    """#

    static let style = #"""
    <style>
    :root{--accent:#fa243c;--bg:#f2f2f7;--fg:#000;--fg2:rgba(60,60,67,.6);--fill:rgba(120,120,128,.14);--sep:rgba(60,60,67,.18);
      --sheet:rgba(248,248,250,.88);--card:#fff;--glow:.35;
      --top:env(safe-area-inset-top);--bottom:env(safe-area-inset-bottom);--left:env(safe-area-inset-left);--right:env(safe-area-inset-right);color-scheme:light dark}
    @media (prefers-color-scheme:dark){:root{--bg:#000;--fg:#fff;--fg2:rgba(235,235,245,.6);--fill:rgba(120,120,128,.3);--sep:rgba(84,84,88,.55);
      --sheet:rgba(28,28,30,.88);--card:#636366;--glow:.6}}
    *{box-sizing:border-box;-webkit-tap-highlight-color:transparent;margin:0}
    html,body{height:100%;background:var(--bg);color:var(--fg);font:16px -apple-system,system-ui,sans-serif;overflow:hidden;
      -webkit-user-select:none;user-select:none;-webkit-touch-callout:none}
    button{font:inherit;color:inherit;background:none;border:0;padding:0;cursor:pointer;display:grid;place-items:center}
    svg{width:100%;height:100%;fill:currentColor}
    .s{fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round}
    [hidden]{display:none!important}
    #bg{position:fixed;inset:-20%;background:center/cover;filter:blur(60px) saturate(1.8);opacity:var(--glow);transition:background-image .6s}
    #app{position:relative;height:100%;display:flex}
    #np{flex:1;min-width:0;display:flex;flex-direction:column;max-width:520px;margin:0 auto;
      padding:calc(var(--top) + 20px) calc(var(--right) + 28px) calc(var(--bottom) + 8px) calc(var(--left) + 28px)}
    #art{flex:1;min-height:0;display:flex;align-items:center;justify-content:center}
    #cover{width:min(100%,46vh);aspect-ratio:1;border-radius:12px;background:var(--fill) center/cover;
      box-shadow:0 18px 50px rgba(0,0,0,.35);transition:transform .45s cubic-bezier(.3,1.4,.5,1)}
    body.paused #cover{transform:scale(.84)}
    .info{display:flex;align-items:center;gap:12px;margin-top:24px}
    .info div{flex:1;min-width:0}
    .t{font-size:21px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .a{font-size:19px;color:var(--fg2);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    #star{width:32px;height:32px;padding:4px;color:var(--fg2);flex:none}#star.on{color:var(--accent)}
    #star .f{display:none}#star.on .f{display:block}#star.on .o{display:none}
    input[type=range]{-webkit-appearance:none;appearance:none;width:100%;height:28px;background:transparent;margin:0}
    input[type=range]::-webkit-slider-runnable-track{height:6px;border-radius:3px;
      background:linear-gradient(var(--fg2),var(--fg2)) 0/var(--p,0%) 100% no-repeat,var(--fill)}
    input[type=range]::-webkit-slider-thumb{-webkit-appearance:none;width:14px;height:14px;margin-top:-4px;border-radius:50%;background:transparent}
    input[type=range]:active::-webkit-slider-runnable-track{height:10px;margin-top:-2px}
    #seek{margin-top:14px}
    .times{display:flex;justify-content:space-between;font-size:12px;color:var(--fg2);font-variant-numeric:tabular-nums;margin-top:-2px}
    .ctl{display:flex;justify-content:space-evenly;align-items:center;margin:12px 0 16px}
    .ctl button{width:54px;height:54px;transition:transform .15s}.ctl button:active{transform:scale(.86)}
    #toggle{width:74px;height:74px}
    .vol{display:flex;align-items:center;gap:10px;color:var(--fg2)}.vol svg{width:20px;height:20px;flex:none}
    .bar{display:flex;justify-content:space-around;margin-top:16px;color:var(--fg2)}
    .bar button{width:44px;height:44px;padding:10px;border-radius:10px}
    .bar button.on{color:var(--accent);background:var(--fill)}
    #outname{text-align:center;font-size:12px;color:var(--fg2);margin-top:2px;min-height:15px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    #outname.server,#out.server{color:var(--accent)}
    #side{position:fixed;inset:0;z-index:2;display:flex;flex-direction:column;background:var(--sheet);
      -webkit-backdrop-filter:blur(30px) saturate(1.6);backdrop-filter:blur(30px) saturate(1.6);
      padding-top:calc(var(--top) + 8px);transform:translateY(105%);transition:transform .35s cubic-bezier(.2,.9,.3,1)}
    #side.open{transform:none}
    .head{display:flex;align-items:center;gap:12px;padding:4px calc(var(--right) + 16px) 10px calc(var(--left) + 16px)}
    .seg{flex:1;display:flex;background:var(--fill);border-radius:9px;padding:2px}
    .seg button{flex:1;padding:6px 0;font-size:13px;font-weight:600;border-radius:7px}
    .seg button.on{background:var(--card);box-shadow:0 1px 4px rgba(0,0,0,.14)}
    .done{color:var(--accent);font-weight:600;font-size:17px}
    .pane{flex:1;min-height:0;overflow-y:auto;-webkit-overflow-scrolling:touch;overscroll-behavior:contain;
      padding:0 calc(var(--right) + 16px) calc(var(--bottom) + 24px) calc(var(--left) + 16px)}
    .qhead{display:flex;align-items:center;gap:8px;padding:6px 0 8px;border-bottom:.5px solid var(--sep)}
    .qhead div{flex:1;min-width:0}.qhead h3{font-size:17px}.qhead span{font-size:13px;color:var(--fg2)}
    .qhead button{width:40px;height:34px;padding:7px 10px;border-radius:9px;background:var(--fill);color:var(--fg2);position:relative}
    .qhead button.on{background:var(--accent);color:#fff}
    #one{position:absolute;font-size:8px;font-weight:800;right:5px;bottom:3px;display:none}#rep.one #one{display:block}
    .row{display:flex;align-items:center;gap:12px;min-height:62px;padding:6px 0;border-bottom:.5px solid var(--sep);cursor:pointer;position:relative}
    .row>i{width:48px;height:48px;flex:none;border-radius:6px;background:var(--fill) center/cover;display:grid;place-items:center;color:var(--fg2)}
    .row>i svg{width:24px;height:24px}
    .row>i.round{border-radius:50%}
    .row .tx{flex:1;min-width:0}
    .row b,.row span{display:block;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .row b{font-weight:400}.row span{font-size:13px;color:var(--fg2);margin-top:1px}
    .row .n{width:24px;flex:none;text-align:center;color:var(--fg2);font-variant-numeric:tabular-nums;font-size:15px}
    .row button,.row .grip{width:36px;height:36px;padding:8px;color:var(--fg2);flex:none}
    .row .rm{color:var(--accent)}
    .row .grip{touch-action:none;cursor:grab}
    .row.drag{z-index:3;background:var(--card);box-shadow:0 8px 24px rgba(0,0,0,.25);border-radius:10px;border-color:transparent}
    .row.shift{transition:transform .2s}
    .row.cat{min-height:50px}.row.cat>i{width:28px;height:28px;background:none;color:var(--accent)}
    .row.cat b{font-size:19px}.chev{width:14px;height:14px;color:var(--fg2);flex:none}
    .sk{height:62px;border-bottom:.5px solid var(--sep);display:flex;align-items:center;gap:12px}
    .sk::before{content:"";width:48px;height:48px;border-radius:6px;background:var(--fill)}
    .sk::after{content:"";height:12px;width:55%;border-radius:6px;background:var(--fill)}
    .sk,.lsk{animation:pulse 1.2s ease-in-out infinite alternate}@keyframes pulse{to{opacity:.45}}
    .lnav{display:flex;align-items:center;min-height:34px}
    #lback{color:var(--accent);font-size:17px;display:flex;align-items:center;gap:2px}#lback svg{width:12px;height:20px}
    h1{font-size:30px;font-weight:700;margin:2px 0 10px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    #q{width:100%;font:inherit;color:inherit;background:var(--fill);border:0;border-radius:10px;padding:9px 12px;outline:none;margin-bottom:6px;
      -webkit-user-select:text;user-select:text}
    .sec{font-size:20px;font-weight:700;margin:20px 0 2px}
    .hero{display:flex;flex-direction:column;align-items:center;text-align:center;padding:4px 0 14px;gap:3px;border-bottom:.5px solid var(--sep)}
    .hero>i{width:min(64%,250px);aspect-ratio:1;border-radius:10px;background:var(--fill) center/cover;box-shadow:0 10px 30px rgba(0,0,0,.2);margin-bottom:12px}
    .hero>i.round{border-radius:50%}
    .hero h2{font-size:21px;font-weight:700}.hero p{color:var(--accent);font-size:17px}
    .acts{display:flex;gap:12px;width:100%;margin-top:12px}
    .acts button{flex:1;background:var(--fill);color:var(--accent);font-weight:600;border-radius:10px;padding:12px 0;display:flex;gap:6px;justify-content:center;align-items:center}
    .acts svg{width:17px;height:17px}
    .empty{color:var(--fg2);text-align:center;padding:40px 0}
    #ly{padding:16px 2px 45vh}
    .ly{font-size:27px;font-weight:700;line-height:1.25;margin-bottom:20px;opacity:.3;transition:opacity .35s;cursor:pointer}
    .ly.on{opacity:1}#ly.plain .ly{opacity:.85;font-size:21px;cursor:auto}
    .lsk{height:26px;border-radius:8px;background:var(--fill);margin-bottom:22px}
    #menu{position:fixed;inset:0;z-index:5;display:none;flex-direction:column;justify-content:flex-end;align-items:center;background:rgba(0,0,0,.3);
      padding:0 calc(var(--right) + 10px) calc(var(--bottom) + 10px) calc(var(--left) + 10px)}
    #menu.open{display:flex}
    .mbox{width:100%;max-width:420px;background:var(--sheet);-webkit-backdrop-filter:blur(30px);backdrop-filter:blur(30px);border-radius:14px;overflow:hidden;margin-bottom:8px}
    .mt{padding:13px 16px;text-align:center;font-size:13px;color:var(--fg2);border-bottom:.5px solid var(--sep)}
    .mt b{display:block;color:var(--fg);font-size:15px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
    .mbox>button{width:100%;padding:16px;font-size:18px;color:var(--accent);border-bottom:.5px solid var(--sep)}
    .mbox>button:last-child{border:0}#mcancel{font-weight:600}
    .opt{display:flex!important;align-items:center;gap:12px;text-align:left;color:var(--fg)!important;font-size:16px!important;padding:12px 16px!important}
    .opt i{width:30px;height:30px;border-radius:50%;background:var(--fill);display:grid;place-items:center;padding:6px;flex:none}
    .opt.on i{background:var(--accent);color:#fff}.opt div{flex:1;min-width:0}.opt span{display:block;font-size:13px;color:var(--fg2)}
    .opt .ck{width:18px;height:18px;color:var(--accent);visibility:hidden}.opt.on .ck{visibility:visible}
    .sw{position:relative;width:51px;height:31px;flex:none}.sw input{opacity:0;position:absolute}
    .sw span{position:absolute;inset:0;border-radius:16px;background:var(--fill);transition:.2s}
    .sw span::after{content:"";position:absolute;width:27px;height:27px;left:2px;top:2px;border-radius:50%;background:#fff;box-shadow:0 2px 4px rgba(0,0,0,.2);transition:.2s}
    .sw input:checked+span{background:var(--accent)}.sw input:checked+span::after{transform:translateX(20px)}
    #toast{position:fixed;left:50%;bottom:calc(var(--bottom) + 28px);z-index:6;transform:translate(-50%,16px);opacity:0;pointer-events:none;
      background:var(--sheet);-webkit-backdrop-filter:blur(20px);backdrop-filter:blur(20px);padding:10px 18px;border-radius:20px;
      font-size:15px;font-weight:600;box-shadow:0 4px 20px rgba(0,0,0,.2);transition:.25s;white-space:nowrap}
    #toast.on{opacity:1;transform:translate(-50%,0)}
    #pair{position:fixed;inset:0;z-index:7;background:var(--bg);display:none;flex-direction:column;align-items:center;justify-content:center;
      gap:14px;padding:24px;text-align:center}
    body.unpaired #pair{display:flex}
    #pair img{width:84px;height:84px;border-radius:20px}
    #pair p{color:var(--fg2);max-width:300px}
    #code{font:600 32px ui-monospace,monospace;letter-spacing:.3em;text-align:center;width:250px;padding:10px;border-radius:12px;
      border:0;background:var(--fill);color:inherit;outline:none;-webkit-user-select:text;user-select:text}
    #go{background:var(--accent);color:#fff;font-weight:600;border-radius:12px;padding:12px 40px}
    #msg{color:var(--accent);min-height:1.2em}
    .off .ctl,.off .vol,.off #seek,.off .times,.off #star{opacity:.35;pointer-events:none}
    @media (min-width:768px) and (min-height:560px){
      #np{flex:0 0 46%;max-width:none;margin:0;padding-left:calc(var(--left) + 40px);padding-right:36px}
      #side{position:relative;inset:auto;z-index:1;flex:1;min-width:0;transform:none;transition:none;border-radius:22px;padding-top:12px;
        margin:calc(var(--top) + 16px) calc(var(--right) + 16px) calc(var(--bottom) + 16px) 0}
      .done{display:none}
    }
    @media (max-width:260px){
      #np{padding:4px 6px;justify-content:center}
      #art,.vol,.bar,#outname,.times,#star,#side{display:none}
      .info{margin:0;text-align:center}.t{font-size:15px}.a{font-size:13px}
      #seek{margin-top:6px;height:12px;pointer-events:none}
      input[type=range]::-webkit-slider-runnable-track{height:3px}
      .ctl{margin:8px 0 0}.ctl button{width:38px;height:38px}#toggle{width:56px;height:56px}
      #pair img,#pair p{display:none}#code{font-size:20px;width:100%}#go{padding:8px 20px}
    }
    </style>
    </head>

    """#

    static let body = #"""
    <body class="paused">
    <svg style="display:none">
    <symbol id="i-play" viewBox="0 0 24 24"><path d="M7 4.5v15c0 .8.9 1.3 1.6.8l11.5-7.5c.6-.4.6-1.2 0-1.6L8.6 3.7C7.9 3.2 7 3.7 7 4.5z"/></symbol>
    <symbol id="i-pause" viewBox="0 0 24 24"><rect x="5.5" y="4" width="4.5" height="16" rx="1.2"/><rect x="14" y="4" width="4.5" height="16" rx="1.2"/></symbol>
    <symbol id="i-next" viewBox="0 0 24 24"><path d="M2 6.6v10.8c0 .7.8 1.1 1.3.7L11 13v4.4c0 .7.8 1.1 1.3.7l8.3-5.4c.5-.3.5-1.1 0-1.4l-8.3-5.4c-.5-.4-1.3 0-1.3.7V11L3.3 5.9C2.8 5.5 2 5.9 2 6.6z"/></symbol>
    <symbol id="i-shuffle" viewBox="0 0 24 24"><path class="s" d="M3 6.5h3.2c4.5 0 6.6 11 11 11H21M18 14.5l3 3-3 3M3 17.5h3.2c1.6 0 2.8-1.4 3.9-3.3M13.8 9.6c1-1.7 2.2-3.1 3.9-3.1H21M18 3.5l3 3-3 3"/></symbol>
    <symbol id="i-repeat" viewBox="0 0 24 24"><path class="s" d="M3.5 11.5V10a3.5 3.5 0 0 1 3.5-3.5h13M17 3.5l3 3-3 3M20.5 12.5V14a3.5 3.5 0 0 1-3.5 3.5H4M7 20.5l-3-3 3-3"/></symbol>
    <symbol id="i-list" viewBox="0 0 24 24"><path class="s" d="M9 6h12M9 12h12M9 18h12"/><circle cx="4" cy="6" r="1.5"/><circle cx="4" cy="12" r="1.5"/><circle cx="4" cy="18" r="1.5"/></symbol>
    <symbol id="i-quote" viewBox="0 0 24 24"><path class="s" d="M4 5.5h16a1.5 1.5 0 0 1 1.5 1.5v9a1.5 1.5 0 0 1-1.5 1.5h-9l-4.5 3.5V17.5H4A1.5 1.5 0 0 1 2.5 16V7A1.5 1.5 0 0 1 4 5.5z"/><path d="M8.2 9.2h2.3v2.3c0 1.3-.7 2.2-2 2.6l-.4-.8c.6-.3.9-.7.9-1.3H8.2zm5 0h2.3v2.3c0 1.3-.7 2.2-2 2.6l-.4-.8c.6-.3.9-.7.9-1.3h-.8z"/></symbol>
    <symbol id="i-airplay" viewBox="0 0 24 24"><path class="s" d="M6.5 17.5H5A2.5 2.5 0 0 1 2.5 15V6A2.5 2.5 0 0 1 5 3.5h14A2.5 2.5 0 0 1 21.5 6v9a2.5 2.5 0 0 1-2.5 2.5h-1.5"/><path d="M12 13.5l6 7.5H6z"/></symbol>
    <symbol id="i-lib" viewBox="0 0 24 24"><path class="s" d="M4 4v16M8.5 4v16M13 4.5l6.5 15"/></symbol>
    <symbol id="i-low" viewBox="0 0 24 24"><path d="M3 9.5h3.5L11 5.5v13l-4.5-4H3z"/></symbol>
    <symbol id="i-high" viewBox="0 0 24 24"><path d="M3 9.5h3.5L11 5.5v13l-4.5-4H3z"/><path class="s" d="M14.5 9a4.5 4.5 0 0 1 0 6M17.5 6.5a8 8 0 0 1 0 11"/></symbol>
    <symbol id="i-more" viewBox="0 0 24 24"><circle cx="5" cy="12" r="1.8"/><circle cx="12" cy="12" r="1.8"/><circle cx="19" cy="12" r="1.8"/></symbol>
    <symbol id="i-back" viewBox="0 0 12 20"><path class="s" stroke-width="2.6" d="M10 2L2 10l8 8"/></symbol>
    <symbol id="i-chev" viewBox="0 0 12 20"><path class="s" stroke-width="2.4" d="M2 2l8 8-8 8"/></symbol>
    <symbol id="i-minus" viewBox="0 0 24 24"><circle cx="12" cy="12" r="9.5"/><rect x="7" y="11" width="10" height="2" rx="1" fill="#fff"/></symbol>
    <symbol id="i-grip" viewBox="0 0 24 24"><path class="s" d="M4 8h16M4 12h16M4 16h16"/></symbol>
    <symbol id="i-person" viewBox="0 0 24 24"><circle cx="12" cy="8" r="4"/><path d="M4 20c0-4 3.6-6.5 8-6.5s8 2.5 8 6.5z"/></symbol>
    <symbol id="i-album" viewBox="0 0 24 24"><rect class="s" x="3" y="3" width="18" height="18" rx="3"/><circle class="s" cx="12" cy="12" r="4"/><circle cx="12" cy="12" r="1.2"/></symbol>
    <symbol id="i-note" viewBox="0 0 24 24"><path d="M9 17.5V5.8l11-2.3v11.8a3 3 0 1 1-2-2.8V7.1l-7 1.5v8.9a3 3 0 1 1-2-2.8z"/></symbol>
    <symbol id="i-playlist" viewBox="0 0 24 24"><path class="s" d="M3 6h11M3 11h11M3 16h7"/><path d="M15 19.5v-8.7l6-1.3v2l-4 .9v7.1a2.5 2.5 0 1 1-2-2.4z"/></symbol>
    <symbol id="i-mix" viewBox="0 0 24 24"><path d="M12 2.5l1.8 5.2 5.2 1.8-5.2 1.8L12 16.5l-1.8-5.2L5 9.5l5.2-1.8zM18.5 14l.9 2.6 2.6.9-2.6.9-.9 2.6-.9-2.6-2.6-.9 2.6-.9z"/></symbol>
    <symbol id="i-mac" viewBox="0 0 24 24"><path class="s" d="M4.5 5.5h15v10h-15zM2 19h20"/></symbol>
    <symbol id="i-server" viewBox="0 0 24 24"><rect class="s" x="6" y="2.5" width="12" height="19" rx="2.5"/><circle class="s" cx="12" cy="14.5" r="3.2"/><circle cx="12" cy="7" r="1.3"/></symbol>
    <symbol id="i-check" viewBox="0 0 24 24"><path class="s" stroke-width="2.6" d="M5 12.5l4.5 4.5L19 7.5"/></symbol>
    <symbol id="i-lock" viewBox="0 0 24 24"><rect x="5" y="10.5" width="14" height="10" rx="2"/><path class="s" d="M8 10.5V8a4 4 0 0 1 8 0v2.5"/></symbol>
    </svg>
    <div id="bg"></div>
    <div id="app">
    <main id="np" class="off">
      <div id="art"><div id="cover"></div></div>
      <div class="info"><div><div class="t" id="title">Not Playing</div><div class="a" id="artist">&nbsp;</div></div>
        <button id="star" aria-label="Favorite"><svg viewBox="0 0 24 24"><path class="s o" d="M12 3.2l2.7 5.6 6.1.8-4.5 4.3 1.1 6.1L12 17.1 6.6 20l1.1-6.1-4.5-4.3 6.1-.8z"/><path class="f" d="M12 3.2l2.7 5.6 6.1.8-4.5 4.3 1.1 6.1L12 17.1 6.6 20l1.1-6.1-4.5-4.3 6.1-.8z"/></svg></button></div>
      <input id="seek" type="range" min="0" max="1" step="0.1" value="0" aria-label="Position">
      <div class="times"><span id="el">0:00</span><span id="rem">-0:00</span></div>
      <div class="ctl">
        <button id="prev" aria-label="Previous"><svg style="transform:scaleX(-1)"><use href="#i-next"/></svg></button>
        <button id="toggle" aria-label="Play"><svg><use id="tg" href="#i-play"/></svg></button>
        <button id="next" aria-label="Next"><svg><use href="#i-next"/></svg></button>
      </div>
      <div class="vol"><svg><use href="#i-low"/></svg><input id="vol" type="range" min="0" max="1" step="0.01" aria-label="Volume"><svg><use href="#i-high"/></svg></div>
      <div class="bar">
        <button id="b-lyrics" data-tab="lyrics" aria-label="Lyrics"><svg><use href="#i-quote"/></svg></button>
        <button id="out" aria-label="Output"><svg><use href="#i-airplay"/></svg></button>
        <button id="b-queue" data-tab="queue" aria-label="Up Next"><svg><use href="#i-list"/></svg></button>
        <button id="b-lib" data-tab="lib" aria-label="Library"><svg><use href="#i-lib"/></svg></button>
      </div>
      <div id="outname"></div>
    </main>
    <aside id="side">
      <div class="head"><div class="seg" role="tablist">
        <button data-tab="queue" role="tab">Up Next</button><button data-tab="lyrics" role="tab">Lyrics</button><button data-tab="lib" role="tab">Library</button>
      </div><button class="done" id="done">Done</button></div>
      <div class="pane" id="p-queue">
        <div class="qhead"><div><h3>Playing Next</h3><span id="qsub"></span></div>
          <button id="shuf" aria-label="Shuffle"><svg><use href="#i-shuffle"/></svg></button>
          <button id="rep" aria-label="Repeat"><svg><use href="#i-repeat"/></svg><span id="one">1</span></button></div>
        <div id="ql"></div>
      </div>
      <div class="pane" id="p-lyrics"><div id="ly"></div></div>
      <div class="pane" id="p-lib">
        <div class="lnav"><button id="lback" hidden><svg><use href="#i-back"/></svg><span id="lbackt">Library</span></button></div>
        <h1 id="lt">Library</h1>
        <input id="q" type="search" placeholder="Artists, Albums, Songs" autocomplete="off" enterkeyhint="search">
        <div id="lc"></div>
      </div>
    </aside>
    </div>
    <div id="menu"><div class="mbox" id="mbox"></div><div class="mbox"><button id="mcancel">Cancel</button></div></div>
    <div id="toast"></div>
    <audio id="keep" src="/silence.wav" loop playsinline preload="none"></audio>
    <div id="pair"><img src="/icon.png" alt=""><h2>Pair with MusicSync</h2>
      <p>On your Mac, open MusicSync Settings &gt; Remote, click Pair a Device and scan the QR code or type the code.</p>
      <input id="code" inputmode="numeric" autocomplete="one-time-code" maxlength="6" placeholder="000000">
      <button id="go">Pair</button><div id="msg"></div></div>

    """#
}
