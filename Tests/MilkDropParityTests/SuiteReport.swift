import Foundation
@testable import MilkDropKit

/// The HTML report of `VisualizerSuiteTests`: `index.html` (summary and a sortable, filterable table) and one page per
/// preset (`p/<id>.html`: frames, difference images, video, debug info), plus `results.json`. No external assets.
enum SuiteReport {
    typealias Entry = VisualizerSuiteTests.Entry
    static let frames = VisualizerSuiteTests.frames

    static func write(_ entries: [Entry], to out: URL, seconds: (rendered: Double, total: Double), sample: Int) throws {
        for e in entries { try page(e).write(to: out.appendingPathComponent("p/\(e.id).html"), atomically: true, encoding: .utf8) }
        try index(entries, seconds: seconds, sample: sample).write(to: out.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        let plain = entries.map { var e = $0; e.debug = [:]; return e }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(plain).write(to: out.appendingPathComponent("results.json"))
    }

    // MARK: - Pieces

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    static func num(_ v: Double?, _ digits: Int = 1) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "–" }

    static func median(_ values: [Double]) -> Double? {
        let v = values.sorted()
        return v.isEmpty ? nil : v[v.count / 2]
    }

    /// The first line of a reason, short, for tables and grouping.
    static func short(_ s: String?, _ n: Int = 90) -> String { String((s ?? "").prefix { $0 != "\n" }.prefix(n)) }

    static let style = """
    :root{color-scheme:light;--cf-color-canvas:#fff;--cf-color-surface:#fafafa;--cf-color-surface-raised:#fff;--cf-color-surface-muted:#f4f4f5;
    --cf-color-text:#27272a;--cf-color-text-strong:#18181b;--cf-color-text-muted:#52525b;--cf-color-text-subtle:#71717a;--cf-color-border:#e4e4e7;
    --cf-color-border-strong:#a1a1aa;--cf-color-accent:#0369a1;--cf-color-accent-soft:#e0f2fe;--cf-color-focus:#0284c7;--cf-color-success:#166534;
    --cf-color-success-surface:#f0fdf4;--cf-color-warning:#854d0e;--cf-color-warning-surface:#fefce8;--cf-color-danger:#b91c1c;--cf-color-danger-surface:#fef2f2;
    --cf-color-table-header:#e4e4e7;--cf-color-table-header-text:#27272a;
    --cf-font-sans:"Manrope",ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif;--cf-font-mono:ui-monospace,"SFMono-Regular",consolas,monospace;
    --cf-radius-sm:.375rem;--cf-radius-md:.5rem;--cf-radius-lg:.75rem;--cf-radius-full:9999px}
    @media (prefers-color-scheme:dark){:root{color-scheme:dark;--cf-color-canvas:#09090b;--cf-color-surface:#18181b;--cf-color-surface-raised:#27272a;
    --cf-color-surface-muted:#27272a;--cf-color-text:#e4e4e7;--cf-color-text-strong:#fafafa;--cf-color-text-muted:#d4d4d8;--cf-color-text-subtle:#a1a1aa;
    --cf-color-border:#3f3f46;--cf-color-border-strong:#71717a;--cf-color-accent:#38bdf8;--cf-color-accent-soft:#082f49;--cf-color-focus:#38bdf8;
    --cf-color-success:#86efac;--cf-color-success-surface:#052e16;--cf-color-warning:#fde047;--cf-color-warning-surface:#422006;--cf-color-danger:#fca5a5;
    --cf-color-danger-surface:#450a0a;--cf-color-table-header:#111113;--cf-color-table-header-text:#fafafa}}
    *{box-sizing:border-box}
    body{margin:0;background:var(--cf-color-canvas);color:var(--cf-color-text);font:14px/1.5 var(--cf-font-sans)}
    main{max-width:1600px;margin:0 auto;padding:24px 16px 64px}
    h1,h2,h3{color:var(--cf-color-text-strong);line-height:1.2;margin:28px 0 12px}h1{font-size:28px;margin-top:8px}h2{font-size:20px}h3{font-size:16px}
    a{color:var(--cf-color-accent)}a:focus-visible,button:focus-visible,input:focus-visible,select:focus-visible{outline:2px solid var(--cf-color-focus);outline-offset:2px}
    code,pre{font-family:var(--cf-font-mono);font-size:12px}
    pre{background:var(--cf-color-surface-muted);border:1px solid var(--cf-color-border);border-radius:var(--cf-radius-md);padding:12px;overflow:auto;max-height:480px;white-space:pre}
    .muted{color:var(--cf-color-text-subtle)}
    .cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:12px}
    .card{background:var(--cf-color-surface);border:1px solid var(--cf-color-border);border-radius:var(--cf-radius-lg);padding:12px 14px}
    .card b{display:block;font-size:22px;color:var(--cf-color-text-strong)}
    .grid2{display:grid;grid-template-columns:repeat(auto-fit,minmax(340px,1fr));gap:16px}
    .shell{overflow:auto;border:1px solid var(--cf-color-border);border-radius:var(--cf-radius-lg)}
    table{border-collapse:collapse;width:100%}
    th,td{padding:6px 8px;text-align:left;border-bottom:1px solid var(--cf-color-border);vertical-align:top;white-space:nowrap}
    th{background:var(--cf-color-table-header);color:var(--cf-color-table-header-text);font-weight:600;position:sticky;top:0}
    th[data-k]{cursor:pointer;user-select:none}th[data-k]:hover{text-decoration:underline}
    tbody tr:nth-child(even){background:var(--cf-color-surface)}
    td.n{text-align:right;font-variant-numeric:tabular-nums}
    td.wrap{white-space:normal;min-width:220px;max-width:380px}
    .badge{display:inline-block;border-radius:var(--cf-radius-full);padding:0 8px;font-size:12px;border:1px solid var(--cf-color-border);white-space:nowrap}
    .ok{color:var(--cf-color-success);background:var(--cf-color-success-surface)}.warn{color:var(--cf-color-warning);background:var(--cf-color-warning-surface)}
    .bad{color:var(--cf-color-danger);background:var(--cf-color-danger-surface)}
    .thumbs img{width:64px;height:48px;display:inline-block;margin-right:2px;background:#000;border-radius:2px}
    .controls{display:flex;flex-wrap:wrap;gap:8px;margin:8px 0 12px;align-items:center}
    input,select{font:inherit;color:inherit;background:var(--cf-color-surface-raised);border:1px solid var(--cf-color-border-strong);border-radius:var(--cf-radius-sm);padding:4px 8px}
    .frames{display:grid;grid-template-columns:repeat(5,minmax(0,256px));gap:8px;overflow:auto}
    .frames figure{margin:0}.frames img{width:100%;aspect-ratio:4/3;background:#000;border-radius:var(--cf-radius-sm);display:block}
    figcaption{font-size:12px;color:var(--cf-color-text-subtle)}
    video{max-width:100%;border-radius:var(--cf-radius-md);background:#000}
    details{margin:8px 0}summary{cursor:pointer;font-weight:600}
    ol li{margin:2px 0}
    """

    static func head(_ title: String) -> String {
        "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
            + "<title>\(esc(title))</title><style>\(style)</style></head><body><main>"
    }

    static func badge(_ e: Entry) -> String {
        let kind = e.status == "compiled" ? "ok" : e.status == "failed" ? "bad" : "warn"
        return "<span class=\"badge \(kind)\">\(esc(e.status))</span>"
    }

    static func pairs(_ p: [VisualizerSuiteTests.Pair?]) -> String {
        p.map { $0.map { String(format: "%.1f / %.2f", $0.difference, $0.correlation) } ?? "–" }.joined(separator: " · ")
    }

    // MARK: - Index

    static func index(_ entries: [Entry], seconds: (rendered: Double, total: Double), sample: Int) -> String {
        let bcOK = entries.filter { $0.butterchurnFailure == nil }, pmOK = entries.filter { $0.projectMFailure == nil }
        let link = { (e: Entry) in "<a href=\"p/\(e.id).html\">\(esc(e.name))</a> <span class=\"muted\">\(esc(e.pack))/\(esc(e.category))</span>" }
        var html = head("Visualizer suite")
        html += "<h1>Visualizer suite</h1><p class=\"muted\">MilkDropKit (native) against butterchurn and projectM 4.1.8, from the same audio, 1/60 s steps and random values 0.5, at 256×192. "
            + "\(sample > 0 ? "\(sample) presets of each category and the worst of the last run" : "Every preset"). "
            + String(format: "Rendered in %.0f s, %.0f s with videos and report; ", seconds.rendered, seconds.total)
            + "\(esc(ISO8601DateFormatter().string(from: Date()))).</p>"

        let cards: [(String, Int)] = [
            ("presets", entries.count), ("compiled", entries.filter { $0.status == "compiled" }.count),
            ("shader fallback", entries.filter { !$0.fallbacks.isEmpty }.count), ("EEL blocks skipped", entries.filter { !$0.skipped.isEmpty }.count),
            ("native failed", entries.filter { $0.nativeError != nil }.count),
            ("butterchurn wrong", entries.filter { $0.butterchurnFailure != nil && !$0.butterchurnFailure!.hasPrefix("cannot render") }.count),
            ("butterchurn cannot render", entries.filter { $0.butterchurnFailure?.hasPrefix("cannot render") == true }.count),
            ("projectM failed", entries.filter { $0.projectMFailure != nil }.count),
            ("all three disagree", entries.filter(\.allDisagree).count),
            ("flash too much", entries.filter { $0.flash.map { !$0.isSafe } ?? false }.count), ("videos", entries.filter(\.video).count),
        ]
        html += "<h2>Summary</h2><div class=\"cards\">" + cards.map { "<div class=\"card\"><b>\($0.1)</b>\(esc($0.0))</div>" }.joined() + "</div>"

        // Medians.
        html += "<h2>Medians</h2><p class=\"muted\">Blurred difference 0…255 / luminance correlation (−1…1) per frame, over presets whose reference did not fail. "
            + "A pair of engines disagrees when difference × (1 − correlation) passes \(Int(VisualizerSuiteTests.Pair.disagree)) in some frame.</p>"
        html += "<div class=\"shell\"><table><thead><tr><th>comparison</th><th>presets</th>" + frames.map { "<th>frame \($0)</th>" }.joined() + "<th>disagree</th></tr></thead><tbody>"
        for (name, rows, pick) in [("native vs butterchurn", bcOK, \Entry.butterchurn), ("native vs projectM", pmOK, \Entry.projectM),
                                   ("butterchurn vs projectM", entries.filter { $0.butterchurnFailure == nil && $0.projectMFailure == nil }, \Entry.references)] {
            html += "<tr><td>\(name)</td><td class=\"n\">\(rows.count)</td>"
            for i in frames.indices {
                let d = median(rows.compactMap { $0[keyPath: pick][safe: i]??.difference }), c = median(rows.compactMap { $0[keyPath: pick][safe: i]??.correlation })
                html += "<td class=\"n\">\(num(d)) / \(num(c, 2))</td>"
            }
            html += "<td class=\"n\">\(rows.filter { Entry.worst($0[keyPath: pick]) > VisualizerSuiteTests.Pair.disagree }.count)</td></tr>"
        }
        html += "</tbody></table></div>"
        let times: [(String, KeyPath<Entry, Double?>)] = [("translate ms", \.translateMs), ("compile ms", \.compileMs), ("frame ms", \.frameMs)]
        html += "<div class=\"shell\" style=\"margin-top:12px\"><table><thead><tr><th>native</th><th>median</th><th>90%</th><th>max</th></tr></thead><tbody>"
        for (name, key) in times {
            let v = entries.compactMap { $0[keyPath: key] }.sorted()
            html += "<tr><td>\(name)</td><td class=\"n\">\(num(median(v)))</td><td class=\"n\">\(num(v.isEmpty ? nil : v[v.count * 9 / 10]))</td><td class=\"n\">\(num(v.last))</td></tr>"
        }
        html += "</tbody></table></div><p class=\"muted\">Frame ms: render and GPU wait at 256×192, with the other engines running at the same time.</p>"

        // Worst lists.
        func list(_ title: String, _ rows: [Entry], _ note: (Entry) -> String) -> String {
            "<div><h3>\(esc(title))</h3>" + (rows.isEmpty ? "<p class=\"muted\">none</p>" : "<ol>" + rows.map { "<li>\(link($0)) <span class=\"muted\">\(esc(note($0)))</span></li>" }.joined() + "</ol>") + "</div>"
        }
        func groups(_ title: String, _ reasons: [String]) -> String {
            var counts: [String: Int] = [:]
            for r in reasons { counts[short(r, 80), default: 0] += 1 }
            let rows = counts.sorted { $0.value > $1.value }.prefix(12)
            return "<div><h3>\(esc(title))</h3>" + (rows.isEmpty ? "<p class=\"muted\">none</p>" : "<ol>" + rows.map { "<li><b>\($0.value)</b> \(esc($0.key))</li>" }.joined() + "</ol>") + "</div>"
        }
        let top = 15
        html += "<h2>Worst</h2><div class=\"grid2\">"
        html += list("vs butterchurn", Array(bcOK.sorted { Entry.worst($0.butterchurn) > Entry.worst($1.butterchurn) }.prefix(top))) { "badness \(num(Entry.worst($0.butterchurn))) · \($0.status)" }
        html += list("vs projectM", Array(pmOK.sorted { Entry.worst($0.projectM) > Entry.worst($1.projectM) }.prefix(top))) { "badness \(num(Entry.worst($0.projectM))) · \($0.status)" }
        html += list("all three disagree", Array(entries.filter(\.allDisagree).sorted { $0.badness > $1.badness }.prefix(30))) {
            "n–b \(num(Entry.worst($0.butterchurn))), n–p \(num(Entry.worst($0.projectM))), b–p \(num(Entry.worst($0.references)))"
        }
        html += list("slowest compile", Array(entries.filter { $0.compileMs != nil }.sorted { $0.compileMs! > $1.compileMs! }.prefix(10))) { "\(num($0.compileMs, 0)) ms" }
        html += list("slowest frame", Array(entries.filter { $0.frameMs != nil }.sorted { $0.frameMs! > $1.frameMs! }.prefix(10))) { "\(num($0.frameMs, 2)) ms" }
        html += groups("shader fallbacks", entries.flatMap(\.fallbacks))
        html += groups("EEL blocks skipped", entries.flatMap { $0.skipped.map { $0.drop { $0 != ":" }.dropFirst(2) }.map(String.init) })
        html += groups("native failures", entries.compactMap(\.nativeError))
        html += groups("butterchurn failures", entries.compactMap(\.butterchurnFailure))
        html += groups("projectM failures", entries.compactMap(\.projectMFailure))
        html += "</div>"

        // Table.
        struct Row: Encodable {
            var id, name, pack, category, status, reason: String
            var tr, co, fr: Double?
            var b, p, r: [[Double]?]
            var bf, pf: String?
            var flash: [Double]?, safe: Bool?, mood: [Double]?
            var video, known, all3: Bool
            var bad: Double
        }
        let rows = entries.map { e in
            Row(id: e.id, name: e.name, pack: e.pack, category: e.category, status: e.status,
                reason: short(e.nativeError ?? e.fallbacks.first ?? e.skipped.first, 120),
                tr: e.translateMs, co: e.compileMs, fr: e.frameMs,
                b: e.butterchurn.map { $0.map { [$0.difference, $0.correlation] } }, p: e.projectM.map { $0.map { [$0.difference, $0.correlation] } },
                r: e.references.map { $0.map { [$0.difference, $0.correlation] } },
                bf: e.butterchurnFailure.map { short($0, 120) }, pf: e.projectMFailure.map { short($0, 120) },
                flash: e.flash.map { [$0.general, $0.red, $0.screen] }, safe: e.flash?.isSafe, mood: e.mood,
                video: e.video, known: e.known, all3: e.allDisagree, bad: e.badness)
        }
        let json = String(decoding: (try? JSONEncoder().encode(rows)) ?? Data("[]".utf8), as: UTF8.self).replacingOccurrences(of: "</", with: "<\\/")
        let packs = Array(Set(entries.map(\.pack))).sorted(), categories = Array(Set(entries.map(\.category))).sorted()
        html += "<h2>All presets</h2><div class=\"controls\"><input id=\"q\" type=\"search\" placeholder=\"Search name or reason\" aria-label=\"Search\" size=\"30\">"
            + "<select id=\"pack\" aria-label=\"Pack\"><option value=\"\">all packs</option>" + packs.map { "<option>\(esc($0))</option>" }.joined() + "</select>"
            + "<select id=\"cat\" aria-label=\"Category\"><option value=\"\">all categories</option>" + categories.map { "<option>\(esc($0))</option>" }.joined() + "</select>"
            + "<select id=\"status\" aria-label=\"Status\"><option value=\"\">any native status</option><option>compiled</option><option value=\"fallback\">shader fallback</option><option value=\"EEL\">EEL skipped</option><option>failed</option></select>"
            + "<select id=\"ref\" aria-label=\"References\"><option value=\"\">any reference</option><option value=\"bok\">butterchurn ok</option><option value=\"bbad\">butterchurn failed</option><option value=\"pok\">projectM ok</option><option value=\"pbad\">projectM failed</option><option value=\"all3\">all three disagree</option><option value=\"video\">with video</option><option value=\"unsafe\">flashes too much</option></select>"
            + "<span id=\"count\" class=\"muted\"></span></div>"
        html += "<p class=\"muted\">Δ / r: blurred difference / luminance correlation at frames \(frames.map(String.init).joined(separator: ", ")); a column sorts by its worst frame. "
            + "Pictures: native, butterchurn, projectM at frame \(frames.last!). Flash: general, red and full-screen flashes a second (limits 3, 3, 2). Mood: arousal, valence, tension.</p>"
        html += "<div class=\"shell\"><table id=\"t\"><thead><tr>"
            + [("name", "preset"), ("", "frame \(frames.last!)"), ("pack", "pack / category"), ("status", "native"), ("tr", "translate ms"), ("co", "compile ms"), ("fr", "frame ms"),
               ("b", "Δ / r butterchurn"), ("p", "Δ / r projectM"), ("r", "Δ / r butterchurn–projectM"), ("bad", "badness"), ("bf", "butterchurn failure"), ("pf", "projectM failure"),
               ("flash", "flash"), ("mood", "mood")].map { $0.0.isEmpty ? "<th>\($0.1)</th>" : "<th data-k=\"\($0.0)\">\($0.1)</th>" }.joined()
            + "</tr></thead><tbody></tbody></table></div>"
        html += "<script type=\"application/json\" id=\"data\">\(json)</script><script>\(script)</script></main></body></html>"
        return html
    }

    static let script = """
    const rows = JSON.parse(document.getElementById('data').textContent);
    const $ = (id) => document.getElementById(id);
    const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
    const f = (v, d = 1) => v == null ? '–' : v.toFixed(d);
    const worst = (p) => Math.max(0, ...p.filter(Boolean).map(([d, c]) => d * (1 - c)));
    const pairs = (p) => p.map((x) => x ? f(x[0]) + '/' + f(x[1], 2) : '–').join(' · ');
    const key = { b: (r) => worst(r.b), p: (r) => worst(r.p), r: (r) => worst(r.r), flash: (r) => r.flash ? Math.max(...r.flash) : -1,
      mood: (r) => r.mood ? r.mood[0] : -1, pack: (r) => r.pack + '/' + r.category };
    let sort = 'bad', dir = -1;
    function render() {
      const q = $('q').value.toLowerCase(), pack = $('pack').value, cat = $('cat').value, st = $('status').value, ref = $('ref').value;
      const shown = rows.filter((r) => (!q || (r.name + ' ' + r.reason + ' ' + (r.bf || '') + ' ' + (r.pf || '')).toLowerCase().includes(q))
        && (!pack || r.pack === pack) && (!cat || r.category === cat) && (!st || r.status.includes(st))
        && (!ref || { bok: !r.bf, bbad: !!r.bf, pok: !r.pf, pbad: !!r.pf, all3: r.all3, video: r.video, unsafe: r.safe === false }[ref]));
      const k = key[sort] || ((r) => r[sort] ?? -1);
      shown.sort((a, b) => { const x = k(a), y = k(b); return (x < y ? -1 : x > y ? 1 : 0) * dir; });
      $('count').textContent = shown.length + ' of ' + rows.length;
      const cls = (s) => s === 'compiled' ? 'ok' : s === 'failed' ? 'bad' : 'warn';
      const img = (src, alt) => '<img loading="lazy" src="' + src + '" alt="' + alt + '" onerror="this.style.visibility=\\'hidden\\'">';
      const last = \(frames.last!);
      $('t').tBodies[0].innerHTML = shown.map((r) => '<tr><td><a href="p/' + r.id + '.html">' + esc(r.name) + '</a>' + (r.video ? ' <span class="badge">video</span>' : '') + (r.known ? ' <span class="badge">known</span>' : '') + '</td>'
        + '<td class="thumbs">' + img('p/' + r.id + '/native-' + last + '.png', 'native') + img('p/' + r.id + '/butterchurn-' + last + '.png', 'butterchurn') + img('p/' + r.id + '/projectm/' + last + '.png', 'projectM') + '</td>'
        + '<td>' + esc(r.pack) + '<br><span class="muted">' + esc(r.category) + '</span></td>'
        + '<td class="wrap"><span class="badge ' + cls(r.status) + '">' + esc(r.status) + '</span>' + (r.reason ? '<br><span class="muted">' + esc(r.reason) + '</span>' : '') + '</td>'
        + '<td class="n">' + f(r.tr) + '</td><td class="n">' + f(r.co, 0) + '</td><td class="n">' + f(r.fr, 2) + '</td>'
        + '<td class="n">' + pairs(r.b) + '</td><td class="n">' + pairs(r.p) + '</td><td class="n">' + pairs(r.r) + '</td><td class="n">' + f(r.bad) + (r.all3 ? ' <span class="badge bad">all 3</span>' : '') + '</td>'
        + '<td class="wrap">' + esc(r.bf || '') + '</td><td class="wrap">' + esc(r.pf || '') + '</td>'
        + '<td class="n">' + (r.flash ? r.flash.map((v) => f(v)).join(' ') + (r.safe ? '' : ' <span class="badge bad">!</span>') : '–') + '</td>'
        + '<td class="n">' + (r.mood ? r.mood.map((v) => f(v, 2)).join(' ') : '–') + '</td></tr>').join('');
    }
    document.querySelectorAll('th[data-k]').forEach((th) => th.addEventListener('click', () => {
      dir = sort === th.dataset.k ? -dir : (['name', 'pack', 'status', 'bf', 'pf'].includes(th.dataset.k) ? 1 : -1);
      sort = th.dataset.k;
      render();
    }));
    ['q', 'pack', 'cat', 'status', 'ref'].forEach((id) => $(id).addEventListener('input', render));
    render();
    """

    // MARK: - Preset page

    static func page(_ e: Entry) -> String {
        var html = head(e.name)
        html += "<p><a href=\"../index.html\">← all presets</a></p><h1>\(esc(e.name))</h1>"
        html += "<p class=\"muted\">\(esc(e.pack)) / \(esc(e.category)) · <code>\(esc(e.relative))</code>\(e.known ? " · among the worst of the last run" : "")</p>"
        html += "<p>native: \(badge(e)) · translate \(num(e.translateMs)) ms · compile \(num(e.compileMs, 0)) ms · frame \(num(e.frameMs, 2)) ms"
        if let flash = e.flash {
            html += String(format: " · flashes a second: general %.1f, red %.1f, screen %.1f", flash.general, flash.red, flash.screen) + (flash.isSafe ? "" : " <span class=\"badge bad\">too much</span>")
        }
        if let mood = e.mood { html += String(format: " · mood: arousal %.2f, valence %.2f, tension %.2f", mood[0], mood[1], mood[2]) }
        html += "</p>"
        let notes = [e.nativeError.map { "native failed: \($0)" }] + e.fallbacks.map { "shader fallback: \($0)" } + e.skipped.map { "EEL block skipped: \($0)" }
            + [e.butterchurnFailure.map { "butterchurn does not count: \($0)" }, e.projectMFailure.map { "projectM does not count: \($0)" }]
        let shown = notes.compactMap { $0 }
        if !shown.isEmpty { html += "<ul>" + shown.map { "<li>\(esc($0))</li>" }.joined() + "</ul>" }

        html += "<h2>Scores</h2><div class=\"shell\"><table><thead><tr><th>pair</th>" + frames.map { "<th>frame \($0): Δ / r</th>" }.joined() + "<th>worst</th></tr></thead><tbody>"
        for (name, p) in [("native – butterchurn", e.butterchurn), ("native – projectM", e.projectM), ("butterchurn – projectM", e.references)] {
            html += "<tr><td>\(name)</td>" + p.map { "<td class=\"n\">\($0.map { String(format: "%.1f / %.2f", $0.difference, $0.correlation) } ?? "–")</td>" }.joined()
                + "<td class=\"n\">\(num(Entry.worst(p)))</td></tr>"
        }
        html += "</tbody></table></div>"

        if e.video {
            html += "<h2>Video</h2><p class=\"muted\">4 s at 60 fps: native, butterchurn, projectM (left to right).</p>"
                + "<video src=\"\(e.id)/video.mp4\" controls loop muted autoplay playsinline width=\"768\" height=\"192\"></video>"
        }
        html += "<h2>Frames</h2>"
        for f in frames {
            let cells = [("native-\(f).png", "native"), ("butterchurn-\(f).png", "butterchurn"), ("projectm/\(f).png", "projectM"),
                         ("diff-butterchurn-\(f).png", "|native − butterchurn| × 4"), ("diff-projectm-\(f).png", "|native − projectM| × 4")]
            html += "<h3>frame \(f)</h3><div class=\"frames\">" + cells.map {
                "<figure><img src=\"\(e.id)/\($0.0)\" alt=\"\($0.1), frame \(f)\" onerror=\"this.style.visibility='hidden'\"><figcaption>\($0.1)</figcaption></figure>"
            }.joined() + "</div>"
        }

        html += "<h2>Debug</h2>"
        let order = ["MSL warp", "MSL comp", "HLSL warp", "HLSL comp", "butterchurn warp", "butterchurn comp", "butterchurn notes", "projectM log", "milk"]
        let keys = order.filter { e.debug[$0] != nil } + e.debug.keys.filter { !order.contains($0) && $0 != "butterchurn failure" }.sorted()
        for key in keys {
            let text = e.debug[key]!.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = ["butterchurn warp": "butterchurn warp (GLSL from its converter)", "butterchurn comp": "butterchurn comp (GLSL from its converter)",
                         "butterchurn notes": "butterchurn notes (what reference.html detected)", "projectM log": "projectM stderr", "milk": ".milk file"][key] ?? key
            html += "<details\(key.hasPrefix("MSL") || key == "butterchurn notes" || key == "projectM log" ? " open" : "")><summary>\(esc(label)) <span class=\"muted\">(\(text.count) chars)</span></summary>"
                + (text.isEmpty ? "<p class=\"muted\">empty</p>" : "<pre>\(esc(text))</pre>") + "</details>"
        }
        if e.skipped.isEmpty { html += "<p class=\"muted\">EEL: every equation block compiles.</p>" }
        return html + "</main></body></html>"
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
