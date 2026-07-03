#!/usr/bin/env python3
"""Argus activity-journal ledger — a standalone local inspector.

Reads ~/Library/Application Support/Argus/journal/*.jsonl (the Mac client's
attention-gated activity journal) and serves a single-page viewer on
localhost. No dependencies, no build, nothing leaves the machine.

    python3 tools/journal_dashboard.py            # serves + opens the browser
    python3 tools/journal_dashboard.py --port 9000 --no-open
"""

import argparse
import json
import os
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

JOURNAL_DIR = os.path.expanduser("~/Library/Application Support/Argus/journal")


def list_days():
    days = []
    if os.path.isdir(JOURNAL_DIR):
        for name in sorted(os.listdir(JOURNAL_DIR), reverse=True):
            if not name.endswith(".jsonl"):
                continue
            p = os.path.join(JOURNAL_DIR, name)
            try:
                st = os.stat(p)
                with open(p, "rb") as f:
                    count = sum(1 for _ in f)
                days.append({"day": name[:-6], "count": count,
                             "bytes": st.st_size, "mtime": int(st.st_mtime)})
            except OSError:
                continue
    return days


def read_day(day):
    # basic name hygiene: YYYY-MM-DD only
    if len(day) != 10 or any(c not in "0123456789-" for c in day):
        return None
    p = os.path.join(JOURNAL_DIR, day + ".jsonl")
    if not os.path.isfile(p):
        return None
    events, bad = [], 0
    with open(p, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                events.append(json.loads(line))
            except ValueError:
                bad += 1
    st = os.stat(p)
    return {"day": day, "events": events, "bad": bad, "mtime": int(st.st_mtime)}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):  # quiet
        pass

    def _json(self, obj, code=200):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path == "/":
            body = PAGE.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif u.path == "/api/days":
            self._json({"dir": JOURNAL_DIR, "days": list_days()})
        elif u.path == "/api/day":
            q = parse_qs(u.query)
            day = (q.get("d") or [""])[0]
            data = read_day(day)
            if data is None:
                self._json({"error": "no such day"}, 404)
            else:
                self._json(data)
        else:
            self._json({"error": "not found"}, 404)


PAGE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Argus · Activity Ledger</title>
<style>
:root {
  --paper: #0b0c0e; --paper2: #101216; --rule: #22252c; --rule2: #2e323b;
  --ink: #d8d2c5; --ink-dim: #7d7a70; --ink-faint: #4d4b45;
  --phos: #e8b34b; --phos-dim: rgba(232,179,75,.16);
  --u: #e8b34b; --o: #a9863f; --v: #6fb3c0; --s: #7aa2f7; --ms: #a8c0ff;
  --g: #b48ead; --w: #8fbf7f; --sn: #8fbf7f; --sk: #c77f7f; --t: #d9c66a;
  --n: #d08fae; --f: #6fc0a8; --wb: #e09b5a;
  --serif: "Iowan Old Style", "Palatino", "Georgia", serif;
  --mono: "SF Mono", "Menlo", ui-monospace, monospace;
}
* { box-sizing: border-box; margin: 0; }
html { background: var(--paper); }
body {
  color: var(--ink); font: 13px/1.55 var(--mono);
  background:
    radial-gradient(1100px 300px at 25% -120px, rgba(232,179,75,.06), transparent 60%),
    var(--paper);
  min-height: 100vh;
}
::selection { background: var(--phos-dim); }
::-webkit-scrollbar { width: 10px; height: 10px; }
::-webkit-scrollbar-thumb { background: var(--rule2); border-radius: 5px; border: 2px solid var(--paper); }
::-webkit-scrollbar-track { background: transparent; }

#wrap { display: grid; grid-template-columns: 230px 1fr; min-height: 100vh; }

/* ---- left: the archive drawer ---- */
#drawer { border-right: 1px solid var(--rule); padding: 26px 0 40px; background: rgba(0,0,0,.25); }
#brand { padding: 0 20px 20px; border-bottom: 1px solid var(--rule); }
#brand .eye { color: var(--phos); letter-spacing: .35em; font-size: 10px; text-transform: uppercase; }
#brand h1 { font: italic 600 25px/1.15 var(--serif); margin-top: 6px; color: var(--ink); }
#brand h1 em { color: var(--phos); font-style: normal; }
#brand .sub { color: var(--ink-dim); font-size: 10.5px; margin-top: 7px; }
#days { padding: 12px 10px; }
.day {
  display: flex; justify-content: space-between; align-items: baseline; gap: 8px;
  padding: 7px 11px; border-radius: 7px; cursor: pointer; color: var(--ink-dim);
  border: 1px solid transparent; transition: color .12s, background .12s;
}
.day:hover { color: var(--ink); background: rgba(255,255,255,.03); }
.day.sel { color: var(--ink); background: var(--phos-dim); border-color: rgba(232,179,75,.25); }
.day .d { font-size: 12.5px; }
.day .c { font-size: 10.5px; color: var(--ink-faint); }
.day.sel .c { color: var(--phos); }
#dirline { padding: 14px 20px 0; color: var(--ink-faint); font-size: 9.5px; word-break: break-all; }

/* ---- right: the ledger ---- */
#main { padding: 26px 34px 80px; min-width: 0; }
#head { display: flex; align-items: baseline; gap: 18px; flex-wrap: wrap; }
#daytitle { font: italic 600 30px/1.1 var(--serif); }
#counts { color: var(--ink-dim); font-size: 11px; }
#live { margin-left: auto; display: flex; align-items: center; gap: 7px; cursor: pointer;
  color: var(--ink-dim); font-size: 11px; user-select: none; }
#live .dot { width: 8px; height: 8px; border-radius: 50%; background: var(--ink-faint); transition: all .2s; }
#live.on { color: var(--phos); }
#live.on .dot { background: var(--phos); box-shadow: 0 0 8px var(--phos); animation: pulse 2s infinite; }
@keyframes pulse { 50% { opacity: .45; } }

/* hour density strip */
#strip { display: grid; grid-template-columns: repeat(24, 1fr); gap: 3px; align-items: end;
  height: 46px; margin: 20px 0 6px; }
#strip .bar { position: relative; background: var(--rule); border-radius: 2px 2px 0 0;
  min-height: 2px; cursor: pointer; transition: background .12s; }
#strip .bar:hover, #strip .bar.hot:hover { background: var(--ink-dim); }
#strip .bar.hot { background: linear-gradient(180deg, var(--phos), #8a6a2c); }
#striplabels { display: grid; grid-template-columns: repeat(24, 1fr); gap: 3px;
  color: var(--ink-faint); font-size: 8.5px; text-align: left; margin-bottom: 18px; }

/* filters */
#filters { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; margin-bottom: 26px; }
.chip { border: 1px solid var(--rule2); border-radius: 20px; padding: 3px 11px; cursor: pointer;
  color: var(--ink-dim); font-size: 11px; user-select: none; transition: all .12s; display: inline-flex; gap: 6px; align-items: center; }
.chip .k { width: 7px; height: 7px; border-radius: 2px; background: var(--kc, var(--ink-dim)); }
.chip:hover { color: var(--ink); border-color: var(--ink-faint); }
.chip.off { opacity: .32; }
#q { background: var(--paper2); color: var(--ink); border: 1px solid var(--rule2); border-radius: 7px;
  padding: 5px 11px; font: 12px var(--mono); outline: none; width: 210px; margin-left: auto; }
#q:focus { border-color: var(--phos); box-shadow: 0 0 0 3px var(--phos-dim); }
#q::placeholder { color: var(--ink-faint); }
select { background: var(--paper2); color: var(--ink-dim); border: 1px solid var(--rule2);
  border-radius: 7px; padding: 4px 8px; font: 11px var(--mono); outline: none; }

/* the spine */
#ledger { position: relative; padding-left: 26px; }
#ledger::before { content: ""; position: absolute; left: 7px; top: 0; bottom: 0; width: 1px;
  background: linear-gradient(180deg, transparent, var(--rule2) 40px, var(--rule2) calc(100% - 40px), transparent); }
.hourrule { display: flex; align-items: center; gap: 12px; margin: 26px 0 10px; color: var(--ink-faint); }
.hourrule::after { content: ""; flex: 1; height: 1px; background: var(--rule); }
.hourrule .h { font: italic 15px var(--serif); color: var(--ink-dim); }

.ev { position: relative; margin: 3px 0; border-radius: 8px; animation: rise .25s ease both; }
@keyframes rise { from { opacity: 0; transform: translateY(5px); } }
.ev::before { content: ""; position: absolute; left: -23px; top: 13px; width: 9px; height: 9px;
  border-radius: 50%; background: var(--paper); border: 2px solid var(--kc, var(--ink-dim)); }
.ev.dim { opacity: .35; }
.evrow { display: flex; align-items: baseline; gap: 10px; padding: 6px 10px; border-radius: 8px; cursor: pointer; }
.evrow:hover { background: rgba(255,255,255,.03); }
.ev.open .evrow { background: var(--paper2); }
.ts { color: var(--ink-faint); font-size: 10.5px; flex-shrink: 0; width: 58px; }
.kind { flex-shrink: 0; font-size: 9.5px; letter-spacing: .12em; text-transform: uppercase;
  color: var(--kc, var(--ink-dim)); width: 92px; }
.who { color: var(--ink-dim); font-size: 11px; flex-shrink: 0; max-width: 220px; overflow: hidden;
  text-overflow: ellipsis; white-space: nowrap; }
.who b { color: var(--ink); font-weight: 500; }
.gist { color: var(--ink); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; min-width: 0; }
.gist .said { color: var(--phos); }
.gist .keys { color: var(--ink-dim); }
.gist .quiet { color: var(--ink-dim); }
.gist .redacted { color: var(--sk, #c77); }
.lock { color: #c98a8a; }

/* expanded detail */
.detail { display: none; padding: 4px 10px 14px 78px; }
.ev.open .detail { display: block; }
.screen {
  position: relative; background: #07080a; border: 1px solid var(--rule); border-radius: 8px;
  padding: 12px 14px; margin-top: 8px; max-height: 420px; overflow: auto;
  font-size: 11px; line-height: 1.45; color: #b7bfae; white-space: pre; box-shadow: inset 0 0 40px rgba(0,0,0,.5);
}
.screen::after { content: ""; position: absolute; inset: 0; pointer-events: none; border-radius: 8px;
  background: repeating-linear-gradient(180deg, transparent 0 2px, rgba(255,255,255,.012) 2px 4px); }
.screen mark { background: rgba(232,179,75,.14); color: var(--phos); border-radius: 2px; padding: 0 1px; }
.legend { color: var(--ink-faint); font-size: 9.5px; margin-top: 6px; }
.legend b { color: var(--phos); font-weight: 500; }
.screenhead { color: var(--ink-faint); font-size: 9.5px; margin-top: 10px; text-transform: uppercase; letter-spacing: .12em; }
.screen .ghost { color: #565a64; font-style: italic; }
.screen .gtag { display: inline-block; margin-left: 10px; padding: 0 7px; border-radius: 9px;
  border: 1px solid #3a3e48; color: #7d828e; font: normal 9px var(--mono); letter-spacing: .06em;
  vertical-align: 1px; }
.dl { display: grid; grid-template-columns: 92px 1fr; gap: 3px 14px; font-size: 11.5px; margin-top: 6px; }
.dl dt { color: var(--ink-faint); text-transform: uppercase; font-size: 9.5px; letter-spacing: .1em; padding-top: 2px; }
.dl dd { color: var(--ink); word-break: break-word; }
.dl dd.said { color: var(--phos); white-space: pre-wrap; }
.linkid { color: var(--v); cursor: pointer; text-decoration: underline dotted; }

#empty { color: var(--ink-dim); padding: 60px 0; text-align: center; font: italic 17px var(--serif); }
#foot { margin-top: 50px; color: var(--ink-faint); font-size: 10px; }
</style>
</head>
<body>
<div id="wrap">
  <aside id="drawer">
    <div id="brand">
      <div class="eye">Argus</div>
      <h1>Activity<br><em>Ledger</em></h1>
      <div class="sub">the raw record, read back</div>
    </div>
    <div id="days"></div>
    <div id="dirline"></div>
  </aside>
  <main id="main">
    <div id="head">
      <div id="daytitle">—</div>
      <div id="counts"></div>
      <div id="live" title="re-read this file every 5s"><span class="dot"></span>live</div>
    </div>
    <div id="strip"></div>
    <div id="striplabels"></div>
    <div id="filters"></div>
    <div id="ledger"></div>
    <div id="foot"></div>
  </main>
</div>
<script>
"use strict";
const KINDS = {
  utterance:  ["var(--u)",  "you spoke"],
  outcome:    ["var(--o)",  "what came of it"],
  viewed:     ["var(--v)",  "silent attention"],
  status:     ["var(--s)",  "fleet status"],
  manualStatus:["var(--ms)","your correction"],
  gitPanel:   ["var(--g)",  "review"],
  workflowRun:["var(--w)",  "commissioned"],
  sessionNew: ["var(--sn)", "session"],
  sessionKill:["#c77f7f",   "session"],
  todo:       ["var(--t)",  "todo"],
  note:       ["var(--n)",  "note"],
  fileSave:   ["var(--f)",  "hand edit"],
  wandbRun:   ["var(--wb)", "artifact"],
};
const kcolor = k => (KINDS[k] || ["var(--ink-dim)"])[0];
const $ = id => document.getElementById(id);
const esc = s => String(s).replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));

let state = { day: null, events: [], mtime: 0, offKinds: new Set(), q: "", machine: "", live: false, open: new Set() };

async function loadDays() {
  const r = await (await fetch("/api/days")).json();
  $("dirline").textContent = r.dir;
  const box = $("days"); box.innerHTML = "";
  if (!r.days.length) { box.innerHTML = '<div style="padding:14px 20px;color:var(--ink-faint)">no journal files yet</div>'; return; }
  r.days.forEach(d => {
    const el = document.createElement("div");
    el.className = "day" + (d.day === state.day ? " sel" : "");
    el.innerHTML = `<span class="d">${d.day}</span><span class="c">${d.count}</span>`;
    el.onclick = () => { state.day = d.day; state.open.clear(); loadDay(); loadDays(); };
    box.appendChild(el);
  });
  if (!state.day) { state.day = r.days[0].day; loadDay(); loadDays(); }
}

async function loadDay(silent) {
  if (!state.day) return;
  const r = await (await fetch("/api/day?d=" + state.day)).json();
  if (r.error) return;
  if (silent && r.mtime === state.mtime) return;
  state.mtime = r.mtime; state.events = r.events;
  render();
}

function gist(e) {
  switch (e.kind) {
    case "utterance": {
      let bits = [];
      if (e.redacted) bits.push('<span class="lock">🔒</span> <span class="redacted">redacted (' + (e.saidChars||"?") + ' chars — never echoed)</span>');
      else if (e.said) bits.push('<span class="said">' + esc(e.said.length > 110 ? e.said.slice(0,110) + "…" : e.said) + "</span>");
      if (e.keys) bits.push('<span class="keys">' + esc(e.keys) + "</span>");
      return bits.join(" · ") || '<span class="quiet">(keys only)</span>';
    }
    case "outcome": return '<span class="quiet">outcome snapshot · of <span class="linkid" data-of="' + esc(e.of||"") + '">' + esc((e.of||"").slice(0,8)) + '</span></span>';
    case "viewed": return '<span class="quiet">watched for ' + (e.dwellSec||0) + 's without typing</span>';
    case "status": return esc(e.from||"?") + ' → <b style="color:var(--s)">' + esc(e.to||"?") + "</b>" + (e.summary ? ' · <span class="quiet">' + esc(e.summary.length>90?e.summary.slice(0,90)+"…":e.summary) + "</span>" : "");
    case "manualStatus": return "you overrode " + esc(e.from||"?") + ' → <b style="color:var(--ms)">' + esc(e.to||"?") + "</b>";
    case "gitPanel": return (e.mode === "lazygit" ? "opened lazygit (write ops)" : "reviewed the repo in the git panel");
    case "workflowRun": return 'ran workflow <b>' + esc(e.workflow||"?") + "</b>" + (e.folder ? ' <span class="quiet">in ' + esc(e.folder) + "</span>" : "");
    case "sessionNew": return "created session" + (e.folder ? ' <span class="quiet">in ' + esc(e.folder) + "</span>" : "");
    case "sessionKill": return "killed session";
    case "todo": return esc(e.action||"") + ": " + esc(e.text||"");
    case "note": return "added a note";
    case "fileSave": return "saved <b>" + esc(e.path||"?") + "</b>";
    case "wandbRun": return 'new W&B run <b>' + esc(e.runId||"") + "</b>";
    default: return '<span class="quiet">' + esc(JSON.stringify(e)).slice(0,110) + "</span>";
  }
}

// The input box lives in the bottom lines of a capture. A ❯ line there that
// does NOT match what the user actually sent is the TUI's pre-filled
// SUGGESTION (claude-code renders these dim; plain-text capture loses that).
// Tag it so it can never read as the user's words. Display-only — raw stays raw.
function renderScreen(sawLines, saidNow, saidAll) {
  const norm = s => s.toLowerCase().replace(/[^a-z0-9]/g, "");
  const sent = (saidAll || []).map(norm).filter(Boolean);
  const n = sawLines.length;
  return sawLines.map((l, i) => {
    const m = l.match(/^\s*[❯›]\s+(.*\S)/);
    if (m && i >= n - 5) {
      const nl = norm(m[1]);
      const mine = nl && sent.some(s => s.includes(nl) || nl.includes(s.slice(0, 24)));
      if (!mine) return '<span class="ghost">' + esc(l) + '</span><i class="gtag">agent suggestion · not sent by you</i>';
    }
    let out = esc(l);
    if (saidNow) {
      const ns = norm(saidNow), nl = norm(l);
      let hit = false;
      if (ns && nl.length >= 4) {
        if (ns.length <= 12) hit = nl.includes(ns);
        else for (let k = 0; k + 12 <= ns.length; k += 6) { if (nl.includes(ns.slice(k, k + 12))) { hit = true; break; } }
      }
      if (hit) out = "<mark>" + out + "</mark>";
    }
    return out;
  }).join("\n");
}

function allSaid() {
  return state.events.filter(x => x.kind === "utterance" && x.said).map(x => x.said);
}

function detail(e) {
  let h = "";
  if (e.kind === "utterance" || e.kind === "outcome") {
    h += '<dl class="dl">';
    if (e.said) h += "<dt>said</dt><dd class='said'>" + esc(e.said) + "</dd>";
    if (e.redacted) h += "<dt>said</dt><dd class='said'>🔒 withheld — the pane never echoed it (secret input rule)</dd>";
    if (e.keys) h += "<dt>keys</dt><dd>" + esc(e.keys) + "</dd>";
    if (e.folder) h += "<dt>folder</dt><dd>" + esc(e.folder) + "</dd>";
    if (e.id) h += "<dt>id</dt><dd>" + esc(e.id) + "</dd>";
    if (e.of) h += "<dt>outcome of</dt><dd>" + esc(e.of) + "</dd>";
    h += "</dl>";
    if (e.saw && e.saw.length) {
      if (e.kind === "utterance") {
        // The snapshot PRE-dates the typing: nothing in it is user input. Text
        // sitting in an input box here is the agent's suggestion, not yours.
        h += '<div class="screenhead">screen as you began typing — pre-input context</div>';
        h += '<div class="screen">' + renderScreen(e.saw, null, allSaid()) + "</div>";
        h += '<div class="legend">nothing on this screen is your input (it was captured <b>before</b> you typed) — a pre-filled prompt in the input box is the agent\'s suggestion. Your input is exactly the <b>SAID</b> line above.</div>';
      } else {
        const src = state.events.find(x => x.kind === "utterance" && x.id === e.of);
        h += '<div class="screenhead">the same pane, minutes after your input</div>';
        h += '<div class="screen">' + renderScreen(e.saw, src && src.said, allSaid()) + "</div>";
        h += '<div class="legend"><b>amber</b> = your message from the linked utterance, echoed back · <i style="font-style:italic">grey-tagged ❯ lines</i> = the agent\'s suggested prompts, never sent · the rest is what the agent did</div>';
      }
    }
  } else {
    h += '<dl class="dl">';
    for (const [k, v] of Object.entries(e)) {
      if (["kind","ts","v","machine","machineID","session"].includes(k)) continue;
      h += "<dt>" + esc(k) + "</dt><dd>" + esc(typeof v === "string" ? v : JSON.stringify(v)) + "</dd>";
    }
    h += "</dl>";
  }
  return h;
}

function render() {
  const evs = state.events;
  $("daytitle").textContent = state.day || "—";
  // facet: machines
  const machines = [...new Set(evs.map(e => e.machine || e.machineID).filter(Boolean))];
  // filters bar
  const kindsHere = [...new Set(evs.map(e => e.kind))];
  let fh = kindsHere.map(k => {
    const off = state.offKinds.has(k) ? " off" : "";
    const n = evs.filter(e => e.kind === k).length;
    return `<span class="chip${off}" data-k="${esc(k)}" style="--kc:${kcolor(k)}"><span class="k"></span>${esc(k)} <span style="color:var(--ink-faint)">${n}</span></span>`;
  }).join("");
  fh += `<select id="msel"><option value="">every machine</option>` +
        machines.map(m => `<option${m===state.machine?" selected":""}>${esc(m)}</option>`).join("") + "</select>";
  fh += `<input id="q" placeholder="search the record…" value="${esc(state.q)}">`;
  $("filters").innerHTML = fh;
  document.querySelectorAll(".chip").forEach(c => c.onclick = () => {
    const k = c.dataset.k;
    state.offKinds.has(k) ? state.offKinds.delete(k) : state.offKinds.add(k);
    render();
  });
  $("msel").onchange = e => { state.machine = e.target.value; render(); };
  $("q").oninput = e => { state.q = e.target.value.toLowerCase(); renderLedger(); };
  renderStrip(evs);
  renderLedger();
}

function visible(e) {
  if (state.offKinds.has(e.kind)) return false;
  if (state.machine && (e.machine || e.machineID) !== state.machine) return false;
  if (state.q && !JSON.stringify(e).toLowerCase().includes(state.q)) return false;
  return true;
}

function renderStrip(evs) {
  const byHour = Array(24).fill(0);
  evs.forEach(e => { const h = new Date(e.ts).getHours(); if (h >= 0) byHour[h]++; });
  const max = Math.max(1, ...byHour);
  $("strip").innerHTML = byHour.map((n, h) =>
    `<div class="bar${n ? " hot" : ""}" style="height:${Math.max(4, n / max * 100)}%" title="${n} events · ${String(h).padStart(2,"0")}:00" data-h="${h}"></div>`).join("");
  $("striplabels").innerHTML = byHour.map((_, h) => h % 3 === 0 ? `<span>${String(h).padStart(2,"0")}</span>` : "<span></span>").join("");
  document.querySelectorAll("#strip .bar").forEach(b => b.onclick = () => {
    const el = document.querySelector(`.ev[data-h="${b.dataset.h}"]`);
    if (el) el.scrollIntoView({ behavior: "smooth", block: "center" });
  });
}

function renderLedger() {
  const evs = state.events.filter(visible);
  const shown = evs.length, total = state.events.length;
  $("counts").textContent = shown === total ? `${total} entries` : `${shown} of ${total} entries`;
  if (!evs.length) {
    $("ledger").innerHTML = "";
    $("empty")?.remove();
    $("ledger").insertAdjacentHTML("beforebegin", '<div id="empty">nothing recorded here — or your filters ate it all</div>');
    return;
  }
  $("empty")?.remove();
  let h = "", lastHour = -1, i = 0;
  for (const e of evs) {
    const d = new Date(e.ts);
    const hour = d.getHours();
    if (hour !== lastHour) {
      h += `<div class="hourrule"><span class="h">${String(hour).padStart(2,"0")}:00</span></div>`;
      lastHour = hour;
    }
    const t = d.toTimeString().slice(0, 8);
    const who = (e.src === "phone" ? "📱 " : "") +
                (e.session ? `<b>${esc(e.session)}</b>${e.machine || e.machineID ? " · " + esc(e.machine || e.machineID) : ""}`
                           : esc(e.machine || e.machineID || e.board || ""));
    const open = state.open.has(i) ? " open" : "";
    h += `<div class="ev${open}" data-i="${i}" data-h="${hour}" style="--kc:${kcolor(e.kind)};animation-delay:${Math.min(i*12,240)}ms">
      <div class="evrow"><span class="ts">${t}</span><span class="kind">${esc(e.kind)}</span>
      <span class="who">${who}</span><span class="gist">${gist(e)}</span></div>
      <div class="detail">${open ? detail(e) : ""}</div></div>`;
    i++;
  }
  $("ledger").innerHTML = h;
  document.querySelectorAll(".ev").forEach(el => {
    el.querySelector(".evrow").onclick = () => {
      const i = +el.dataset.i;
      if (state.open.has(i)) { state.open.delete(i); el.classList.remove("open"); el.querySelector(".detail").innerHTML = ""; }
      else { state.open.add(i); el.classList.add("open"); el.querySelector(".detail").innerHTML = detail(evs[i]); }
    };
  });
  $("foot").textContent = "append-only · local only · " + (state.day || "");
}

$("live").onclick = () => {
  state.live = !state.live;
  $("live").classList.toggle("on", state.live);
};
setInterval(() => { if (state.live) { loadDay(true); loadDays(); } }, 5000);

loadDays();
</script>
</body>
</html>
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--no-open", action="store_true")
    args = ap.parse_args()
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    url = f"http://127.0.0.1:{args.port}/"
    print(f"Argus activity ledger · {url}")
    print(f"reading {JOURNAL_DIR}")
    if not args.no_open:
        webbrowser.open(url)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
