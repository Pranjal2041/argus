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
  artifactSaved:["var(--a)", "saved PDF"],
};
const kcolor = k => (KINDS[k] || ["var(--ink-dim)"])[0];
const $ = id => document.getElementById(id);
const esc = s => String(s).replace(/[&<>"]/g, c => ({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;"}[c]));

let state = { day: null, events: [], days: [], offKinds: new Set(), q: "", machine: "", open: new Set() };

// In-app: Swift injects data (no HTTP server). JS asks for a day via the `ut`
// message handler; Swift replies with window.UTLedger.setDay(...).
function post(type, extra) {
  const h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ut;
  if (h) h.postMessage(Object.assign({ type: type }, extra || {}));
}

function paintDays() {
  const box = $("days"); box.innerHTML = "";
  if (!state.days.length) { box.innerHTML = '<div style="padding:14px 20px;color:var(--ink-faint)">no journal files yet</div>'; return; }
  state.days.forEach(d => {
    const el = document.createElement("div");
    el.className = "day" + (d.day === state.day ? " sel" : "");
    el.innerHTML = `<span class="d">${esc(d.day)}</span><span class="c">${d.count}</span>`;
    el.onclick = () => { state.day = d.day; state.open.clear(); paintDays(); post("day", { d: d.day }); };
    box.appendChild(el);
  });
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
    case "artifactSaved": return 'saved PDF <span class="artifact-link" data-artifact="' +
      esc(e.artifactID||"") + '">' + esc(e.filename||"render.pdf") + "</span>";
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
  document.querySelectorAll(".artifact-link").forEach(link => {
    link.onclick = event => {
      event.stopPropagation();
      post("openArtifact", { id: link.dataset.artifact });
    };
  });
  $("foot").textContent = "append-only · local only · " + (state.day || "");
}

// The header "live" control is a manual Refresh in-app (user chose no polling).
$("live").textContent = "refresh";
$("live").onclick = () => post("refresh");
const dl = $("dirline"); if (dl) dl.onclick = () => post("openFolder");

// ---- Swift → JS bridge (mirrors window.UTGit.*) --------------------------
window.UTLedger = {
  setTheme: function (t) {
    const r = document.documentElement.style;
    if (t.bg) r.setProperty("--paper", t.bg);
    if (t.fg) r.setProperty("--ink", t.fg);
    if (t.accent) { r.setProperty("--phos", t.accent); r.setProperty("--u", t.accent); }
  },
  setDays: function (payload) {
    state.days = (payload && payload.days) || [];
    if (payload && payload.dir) $("dirline").textContent = payload.dir;
    // default to the most recent day on first load
    if (!state.day && state.days.length) {
      state.day = state.days[0].day;
      post("day", { d: state.day });
    }
    paintDays();
  },
  setDay: function (payload) {
    if (!payload || payload.day !== state.day) {
      // a day the user isn't looking at anymore (rapid switch) — ignore
      if (payload && payload.day && payload.day !== state.day) return;
    }
    const events = [];
    (payload.jsonl || "").split("\n").forEach(line => {
      line = line.trim();
      if (!line) return;
      try { events.push(JSON.parse(line)); } catch (e) { /* tolerate a bad line */ }
    });
    state.events = events;
    render();
  }
};

post("ready");
