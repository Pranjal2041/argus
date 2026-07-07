'use strict';
// Argus Wrapped renderer. Receives ONE computed stats blob from Swift via
// window.UTWrapped.setData(obj) and draws the whole deck + dashboard grid.
// All numbers come pre-computed by WrappedStats.swift — this file only presents.

const SVGNS = 'http://www.w3.org/2000/svg';
const $ = (s, r = document) => r.querySelector(s);
const THEMES = 8; // number of t0..tN color classes in style.css

// ---------- tiny DOM + SVG helpers ----------
function el(tag, cls, html) {
  const n = document.createElement(tag);
  if (cls) n.className = cls;
  if (html != null) n.innerHTML = html;
  return n;
}
function s(tag, attrs) {
  const n = document.createElementNS(SVGNS, tag);
  for (const k in (attrs || {})) n.setAttribute(k, attrs[k]);
  return n;
}
function fmt(n) { return (n == null ? 0 : n).toLocaleString('en-US'); }
function esc(t) { const d = document.createElement('div'); d.textContent = t == null ? '' : String(t); return d.innerHTML; }
function pretty(day) { const p = String(day).split('-'); return p.length === 3 ? `${['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'][+p[1]-1]} ${+p[2]}` : day; }
function hourLabel(h) { h = h || 0; return h === 0 ? '12am' : h === 12 ? '12pm' : h < 12 ? h + 'am' : (h - 12) + 'pm'; }
function shortName(n) { return String(n).replace('this mac', 'Mac').replace(/\..*$/, '').slice(0, 14); }

// ---------- charts (draw with rgba white + the card accent var --ca) ----------
function barChart(items, opts = {}) {
  const w = 680, h = opts.h || 300, pad = 30, gap = Math.max(4, 10 - items.length / 3);
  const val = opts.val || (d => d.count), lab = opts.lab || (d => d.label);
  const max = Math.max(1, ...items.map(val));
  const bw = (w - pad) / items.length - gap;
  const svg = s('svg', { viewBox: `0 0 ${w} ${h}`, preserveAspectRatio: 'xMidYMid meet' });
  items.forEach((d, i) => {
    const v = val(d), bh = (h - 52) * v / max, x = pad + i * (bw + gap), y = h - 32 - bh;
    svg.appendChild(s('rect', { x, y, width: Math.max(1, bw), height: Math.max(1, bh), rx: 4, class: 'bar' + (opts.warm ? ' warm' : '') }));
    const lt = lab(d);
    if (lt !== '' && lt != null) { const t = s('text', { x: x + bw / 2, y: h - 12, 'text-anchor': 'middle', class: 'axis' }); t.textContent = lt; svg.appendChild(t); }
    if (opts.showVal !== false && v > 0) { const vt = s('text', { x: x + bw / 2, y: y - 6, 'text-anchor': 'middle', class: 'axis' }); vt.textContent = fmt(v); svg.appendChild(vt); }
  });
  return svg;
}
function lineChart(pts, opts = {}) {
  const w = 680, h = opts.h || 280, pad = 10;
  const xs = pts.map(p => p.t);
  const minX = Math.min(...xs), maxX = Math.max(...xs);
  const ys = pts.map(opts.y || (p => p.count)); if (opts.y2) pts.forEach(p => ys.push(opts.y2(p)));
  const maxY = Math.max(1, ...ys);
  const X = x => pad + (w - 2 * pad) * (x - minX) / Math.max(1, maxX - minX);
  const Y = y => (h - 24) - (h - 40) * y / maxY;
  const svg = s('svg', { viewBox: `0 0 ${w} ${h}`, preserveAspectRatio: 'none' });
  const mk = (accessor, color, fill) => {
    let d = '';
    pts.forEach((p, i) => { const x = X(p.t), y = Y(accessor(p)); d += (i ? 'L' : 'M') + x.toFixed(1) + ' ' + y.toFixed(1) + ' '; });
    if (fill) { const a = d + `L${X(maxX)} ${h-24} L${X(minX)} ${h-24} Z`; svg.appendChild(s('path', { d: a, fill: color, 'fill-opacity': .14 })); }
    svg.appendChild(s('path', { d, class: 'dotline', stroke: color }));
  };
  mk(opts.y || (p => p.count), opts.color || 'var(--ca)', opts.fill !== false);
  if (opts.y2) mk(opts.y2, opts.color2 || 'var(--bad)', false);
  return svg;
}
function hourChart(hours) {
  const items = hours.map((c, i) => ({ label: (i % 3 === 0 ? (i === 0 ? '12a' : i === 12 ? '12p' : i < 12 ? i + 'a' : (i - 12) + 'p') : ''), count: c }));
  return barChart(items, { warm: true, showVal: false, h: 260 });
}
function heatmap(rows) {
  const cols = 24, gap = 3, left = 92, top = 20, ch = 16;
  const cw = 24;
  const w = left + cols * (cw + gap), h = top + rows.length * (ch + gap) + 6;
  const max = Math.max(1, ...rows.flatMap(r => r.hours));
  const svg = s('svg', { viewBox: `0 0 ${w} ${h}`, preserveAspectRatio: 'xMidYMid meet' });
  [0, 6, 12, 18, 23].forEach(hh => { const t = s('text', { x: left + hh * (cw + gap) + cw / 2, y: 13, 'text-anchor': 'middle', class: 'axis' }); t.textContent = hh === 0 ? '12a' : hh === 12 ? '12p' : hh < 12 ? hh + 'a' : (hh - 12) + 'p'; svg.appendChild(t); });
  rows.forEach((r, ri) => {
    const y = top + ri * (ch + gap);
    const lab = s('text', { x: left - 12, y: y + ch - 4, 'text-anchor': 'end', class: 'axis' }); lab.textContent = pretty(r.day); svg.appendChild(lab);
    r.hours.forEach((c, hi) => {
      const o = c === 0 ? 0.05 : 0.2 + 0.8 * c / max;
      svg.appendChild(s('rect', { x: left + hi * (cw + gap), y, width: cw, height: ch, rx: 3, fill: 'var(--ca)', 'fill-opacity': o }));
    });
  });
  return svg;
}
function ring(pct, label, big) {
  const w = 240, r = 92, cx = w / 2, cy = w / 2, C = 2 * Math.PI * r;
  const svg = s('svg', { viewBox: `0 0 ${w} ${w}`, preserveAspectRatio: 'xMidYMid meet' });
  svg.appendChild(s('circle', { cx, cy, r, fill: 'none', stroke: 'rgba(255,255,255,.12)', 'stroke-width': 18 }));
  svg.appendChild(s('circle', { cx, cy, r, fill: 'none', stroke: 'var(--ca)', 'stroke-width': 18, 'stroke-linecap': 'round', 'stroke-dasharray': `${C * Math.min(1, pct)} ${C}`, transform: `rotate(-90 ${cx} ${cy})` }));
  const t1 = s('text', { x: cx, y: cy + 4, 'text-anchor': 'middle', fill: 'var(--ink)', 'font-size': 46, 'font-weight': 800 }); t1.textContent = big; svg.appendChild(t1);
  const t2 = s('text', { x: cx, y: cy + 34, 'text-anchor': 'middle', class: 'axis' }); t2.textContent = label; svg.appendChild(t2);
  return svg;
}

// ---------- card scaffolding (each card holds a centered .inner column) ----------
function card(cls) {
  const c = el('div', 'card' + (cls ? ' ' + cls : ''));
  const inner = el('div', 'inner');
  c.appendChild(inner);
  c.body = inner;                 // helpers + builders append here
  return c;
}
function kicker(c, t) { c.body.appendChild(el('div', 'kicker', esc(t))); }
function chartCard(cls, title, kick, svg, note) {
  const c = card(cls); if (kick) kicker(c, kick); if (title) c.body.appendChild(el('h2', null, esc(title)));
  const wrap = el('div', 'chartwrap'); wrap.appendChild(svg); c.body.appendChild(wrap);
  if (note) c.body.appendChild(el('div', 'footnote', note)); return c;
}
function listCard(cls, kick, title, items, note) {
  const c = card(cls); if (kick) kicker(c, kick); c.body.appendChild(el('h2', null, esc(title)));
  const col = el('div', 'listcol');
  items.forEach((it, i) => {
    const row = el('div', 'li');
    row.appendChild(el('span', 'rank', String(i + 1)));
    row.appendChild(el('span', 'name', esc(it.name)));
    if (it.val != null) row.appendChild(el('span', 'val', typeof it.val === 'number' ? fmt(it.val) : esc(it.val)));
    col.appendChild(row);
  });
  c.body.appendChild(col); if (note) c.body.appendChild(el('div', 'footnote', note)); return c;
}

// crisp single-stat slide: kicker + one giant number + one line
function bigCard(kick, huge, subHTML) {
  const c = card(); kicker(c, kick);
  c.body.appendChild(el('div', 'huge', huge));
  c.body.appendChild(el('div', 'sub', subHTML));
  return c;
}
// multi-segment donut + legend, for a composition ("what the fleet was doing")
function donut(segs) {
  const w = 230, r = 88, cx = w / 2, cy = w / 2, C = 2 * Math.PI * r, sw = 30;
  const total = segs.reduce((a, x) => a + x.value, 0) || 1;
  const svg = s('svg', { viewBox: `0 0 ${w} ${w}`, preserveAspectRatio: 'xMidYMid meet' });
  svg.appendChild(s('circle', { cx, cy, r, fill: 'none', stroke: 'rgba(255,255,255,.08)', 'stroke-width': sw }));
  let off = 0;
  segs.forEach(seg => {
    const dash = C * seg.value / total;
    svg.appendChild(s('circle', { cx, cy, r, fill: 'none', stroke: seg.color, 'stroke-width': sw, 'stroke-dasharray': `${dash} ${C - dash}`, 'stroke-dashoffset': -off, transform: `rotate(-90 ${cx} ${cy})` }));
    off += dash;
  });
  const wrap = el('div', 'donutwrap');
  const sv = el('div', 'donutsvg'); sv.appendChild(svg); wrap.appendChild(sv);
  const leg = el('div', 'legend');
  segs.forEach(seg => {
    const row = el('div', 'legrow');
    const dot = el('span', 'legdot'); dot.style.background = seg.color; row.appendChild(dot);
    row.appendChild(el('span', 'legname', esc(seg.label)));
    row.appendChild(el('span', 'legpct', Math.round(100 * seg.value / total) + '%'));
    leg.appendChild(row);
  });
  wrap.appendChild(leg);
  return wrap;
}
function hm(min) { min = Math.round(min || 0); const h = Math.floor(min / 60), m = min % 60; return h ? `${h}h ${m}m` : `${m}m`; }
function trunc(t, n) { t = String(t == null ? '' : t); return t.length > n ? t.slice(0, n - 1).trimEnd() + '…' : t; }

// ---------- card catalog: each returns a <div class=card> or null if no data ----------
function buildCards(D) {
  const T = D.totals || {}, R = D.rhythm || {}, SUP = D.superlatives || {}, W = D.window || {}, SM = D.statusMix || {};
  const cards = [];
  const push = c => { if (c) cards.push(c); };
  const activeDays = Math.max(1, W.activeDays || 1);

  // hero
  (() => {
    const c = card('hero');
    kicker(c, `${pretty(W.startDay)} – ${pretty(W.endDay)}`);
    c.body.appendChild(el('h1', null, 'Argus<br>Wrapped'));
    c.body.appendChild(el('p', null, `${W.activeDays || 0} active days of commanding your fleet. Here is what happened.`));
    push(c);
  })();

  // messages (huge)
  push(bigCard('You said', fmt(T.utterances),
    `messages to your agents — <b>${fmt(T.chars)}</b> characters, about <b>${fmt(Math.max(1, Math.round((T.chars || 0) / 1800)))}</b> pages of a book.`));

  // pace (crisp)
  push(bigCard('Your pace', fmt(Math.round((T.utterances || 0) / activeDays)),
    `messages a day, on an average active day. You never really logged off.`));

  // fleet size (huge)
  push(bigCard('Your fleet', fmt(T.agents),
    `agents commanded across <b>${fmt(T.machines)}</b> machines. ${fmt(T.sessionsNew)} spawned, ${fmt(T.sessionsKilled)} retired.`));

  // CREATIVE: what your fleet was doing (state mix donut)
  (() => {
    const segs = [
      { label: 'Heads-down working', value: SM.working || 0, color: 'var(--good)' },
      { label: 'Waiting on your call', value: (SM['needs-decision'] || 0) + (SM.look || 0), color: 'var(--ca)' },
      { label: 'Stuck', value: SM.stuck || 0, color: 'var(--bad)' },
      { label: 'Idle', value: SM.idle || 0, color: 'rgba(255,255,255,.35)' },
    ].filter(x => x.value > 0);
    if (segs.length < 2) return;
    const c = card(); kicker(c, 'The view from the bridge'); c.body.appendChild(el('h2', null, 'What your fleet was doing'));
    const wrap = el('div', 'chartwrap'); wrap.appendChild(donut(segs)); c.body.appendChild(wrap);
    push(c);
  })();

  // needs-decision (crisp)
  if (SM['needs-decision']) push(bigCard('Human in the loop', fmt(SM['needs-decision']),
    `times an agent stopped, hit a fork, and waited for <b>your</b> call.`));

  // watch time (crisp)
  if (T.viewedMinutes) push(bigCard('Eyes on the glass', hm(T.viewedMinutes),
    `spent watching your agents work — reading output as it streamed by.`));

  // heatmap
  if ((D.heatmap || []).length) push(chartCard(null, 'When you work', 'Your rhythm', heatmap(D.heatmap),
    `Busiest hour: ${hourLabel(R.peakHour)}. Night score: ${R.nightScore || 0}%.`));

  // hour histogram
  if (D.hourHistogram) push(chartCard(null, 'Hour of day', 'Your clock', hourChart(D.hourHistogram)));

  // milestones (crisp)
  if (SM.milestone) push(bigCard('Momentum', fmt(SM.milestone),
    `milestones your fleet reported hitting across the window.`));

  // pulse
  if ((D.pulse || []).length > 2) push(chartCard('span2', 'The pulse of your week', 'Activity over time', lineChart(D.pulse, { fill: true })));

  // fleet over time
  if ((D.fleet || []).length > 1) {
    const peak = D.fleet[0] && D.fleet[0].peak != null ? D.fleet[0].peak : null;
    const series = D.fleet.filter(p => p.alive != null);
    if (series.length > 1) push(chartCard('span2', 'Agents alive over time', 'Plate-spinning', lineChart(series, { y: p => p.alive, color: 'var(--ca)' }),
      peak != null ? `Peak: ${peak} agents alive at once.` : ''));
  }

  // stuck / rescue (crisp)
  if (SM.stuck) push(bigCard('Rescue squad', fmt(SM.stuck),
    `times an agent hit a wall — and you got it moving again.`));

  // agent leaderboard
  if ((D.agents || []).length) push(listCard(null, 'Most talked-to', 'Your agents', D.agents.slice(0, 10).map(a => ({ name: a.session, val: a.messages })), 'by messages'));

  // machines
  if ((D.machines || []).length) push(chartCard(null, 'Machines commanded', 'Your reach', barChart(D.machines.slice(0, 8), { val: m => m.events, lab: m => shortName(m.name), showVal: false, warm: true })));

  // phone (crisp)
  if (T.phoneMsgs) push(bigCard('Remote control', Math.round(100 * T.phoneMsgs / Math.max(1, T.utterances)) + '%',
    `of your commands were fired from your <b>phone</b> — ${fmt(T.phoneMsgs)} messages on the move.`));

  // catchphrase / top words
  if ((D.topWords || []).length) {
    const cw = D.catchphrase;
    push(chartCard(null, cw ? `You began ${fmt(cw.count)} messages with “${cw.word}”` : 'Your words', 'Catchphrase', barChart(D.topWords.slice(0, 8), { val: w => w.count, lab: w => w.word, showVal: false })));
  }

  // sentiment
  if ((D.sentiment || []).length > 2) push(chartCard('span2', 'Enthusiasm vs frustration', 'The vibe arc', lineChart(D.sentiment, { y: p => p.pos, y2: p => p.neg, color: 'var(--good)', color2: 'var(--bad)', fill: false }), 'green = excited words · red = stuck / frustrated words'));

  // message length
  if ((D.lengthHistogram || []).length) push(chartCard(null, 'How long you write', 'Message length', barChart(D.lengthHistogram, { showVal: true })));

  // projects
  if ((D.projects || []).length) push(listCard(null, 'Where your energy went', 'Projects', D.projects.slice(0, 8).map(p => ({ name: p.name, val: p.events }))));

  // delegation
  if (D.delegation && D.delegation.activeMin) {
    const dg = D.delegation; const c = card(); kicker(c, 'Leverage');
    c.body.appendChild(el('h2', null, 'Delegation ratio'));
    const wrap = el('div', 'chartwrap'); wrap.style.display = 'flex'; wrap.style.justifyContent = 'center';
    wrap.appendChild(ring(Math.min(1, (dg.ratio || 0) / 5), 'agent-min : your-min', (dg.ratio || 0) + '×'));
    c.body.appendChild(wrap);
    c.body.appendChild(el('div', 'footnote', `${fmt(dg.agentWorkingMin)} agent-minutes of work set in motion across ${fmt(dg.activeMin)} minutes of your attention.`));
    push(c);
  }

  // superlatives (records recap)
  (() => {
    const rows = [];
    if (SUP.busiestDay) rows.push({ name: 'Busiest day', val: `${pretty(SUP.busiestDay.day)} · ${fmt(SUP.busiestDay.count)}` });
    if (SUP.busiestMinute) rows.push({ name: 'Fastest minute', val: `${SUP.busiestMinute.count} msgs` });
    if (SUP.longestMessage) rows.push({ name: 'Longest message', val: `${fmt(SUP.longestMessage.chars)} chars` });
    if (SUP.longestSilenceHours) rows.push({ name: 'Longest silence', val: `${SUP.longestSilenceHours}h` });
    if (SUP.fastestKill) rows.push({ name: 'Shortest-lived agent', val: `${SUP.fastestKill.session} · ${SUP.fastestKill.sec}s` });
    if (SUP.mostRounds) rows.push({ name: 'Longest back-and-forth', val: `${SUP.mostRounds.session} · ${SUP.mostRounds.count}` });
    if (rows.length) push(listCard(null, 'Records', 'Your superlatives', rows.map(r => ({ name: r.name, val: r.val }))));
  })();

  // shipped reel — real milestones the fleet reported
  if ((D.shipped || []).length) {
    const c = card('span2'); kicker(c, "In your fleet's own words"); c.body.appendChild(el('h2', null, 'What got shipped'));
    const col = el('div', 'listcol'); col.style.borderTop = '0';
    D.shipped.slice(0, 6).forEach(sh => { const q = el('div', 'quote'); q.innerHTML = `<b>${esc(sh.session)}</b> — ${esc(trunc(sh.text, 150))}`; col.appendChild(q); });
    c.body.appendChild(col); push(c);
  }

  // experiments — distinct, cleaned W&B runs
  if ((D.experiments || []).length) {
    const projs = [...new Set(D.experiments.map(e => e.project).filter(Boolean))];
    push(listCard(null, 'Research', 'Experiments launched',
      D.experiments.slice(0, 8).map(e => ({ name: e.session || 'run', val: (e.runId || '').slice(0, 12) })),
      projs.length ? 'in ' + projs.join(', ') : ''));
  }

  // todos — with done/open state
  if ((D.todos || []).length) {
    const done = D.todos.filter(t => t.action === 'done').length, open = D.todos.length - done;
    const c = card(); kicker(c, 'On your mind'); c.body.appendChild(el('h2', null, 'Notes & todos'));
    const col = el('div', 'listcol');
    D.todos.slice(0, 10).forEach(t => {
      const dn = t.action === 'done';
      const row = el('div', 'li todo');
      row.appendChild(el('span', 'check' + (dn ? ' on' : ''), dn ? '✓' : '○'));
      const nm = el('span', 'name', esc(t.text)); if (dn) nm.classList.add('done');
      row.appendChild(nm);
      col.appendChild(row);
    });
    c.body.appendChild(col);
    c.body.appendChild(el('div', 'footnote', `${open} open · ${done} done`));
    push(c);
  }

  // awards — specific badges with icon + the real stat that earned each
  if ((D.awards || []).length) {
    const c = card(); kicker(c, 'Unlocked'); c.body.appendChild(el('h2', null, `Your badges · ${D.awards.length}`));
    const g = el('div', 'awards');
    D.awards.forEach(a => {
      const b = el('div', 'badge');
      b.appendChild(el('span', 'ico', esc(a.icon || '★')));
      const tx = el('div', 'btext');
      tx.appendChild(el('div', 'bname', esc(a.name)));
      if (a.detail) tx.appendChild(el('div', 'bdetail', esc(a.detail)));
      b.appendChild(tx);
      g.appendChild(b);
    });
    c.body.appendChild(g); push(c);
  }

  // archetype finale
  (() => {
    const a = D.archetype || { name: 'The Orchestrator', blurb: 'One mind, many machines.' };
    const c = card('hero'); kicker(c, 'You are');
    c.body.appendChild(el('h1', null, esc(a.name)));
    c.body.appendChild(el('p', null, esc(a.blurb)));
    const row = el('div', 'statrow');
    row.appendChild(el('span', 'chip', `<b>${fmt(T.utterances)}</b> messages`));
    row.appendChild(el('span', 'chip', `<b>${fmt(T.agents)}</b> agents`));
    row.appendChild(el('span', 'chip', `<b>${fmt(T.machines)}</b> machines`));
    if (T.viewedMinutes) row.appendChild(el('span', 'chip', `<b>${hm(T.viewedMinutes)}</b> watching`));
    c.body.appendChild(row);
    c.body.appendChild(el('div', 'footnote', 'Argus Wrapped · computed live from your activity journal'));
    push(c);
  })();

  // assign a rotating color theme to every card for a lively, colorful deck
  cards.forEach((c, i) => c.classList.add('t' + (i % THEMES)));
  return cards;
}

// ---------- deck controller ----------
const state = { cards: [], idx: 0, grid: false, data: null };

function render() {
  const deck = $('#deck'); deck.innerHTML = '';
  state.cards.forEach((c, i) => { c.classList.toggle('active', i === state.idx); deck.appendChild(c); });
  // segmented progress bar
  const bars = $('#bars'); bars.innerHTML = '';
  state.cards.forEach((_, i) => {
    const seg = el('div', 'seg' + (i < state.idx ? ' done' : i === state.idx ? ' on' : ''));
    seg.appendChild(el('i'));
    seg.onclick = () => go(i);
    bars.appendChild(seg);
  });
  $('#counter').textContent = `${state.idx + 1} / ${state.cards.length}`;
}
function go(i) { state.idx = Math.max(0, Math.min(state.cards.length - 1, i)); render(); }
function next() { if (state.idx < state.cards.length - 1) go(state.idx + 1); }
function prev() { if (state.idx > 0) go(state.idx - 1); }

function toggleGrid() {
  state.grid = !state.grid;
  $('#deck').hidden = state.grid;
  $('#chrome').hidden = state.grid;
  const g = $('#grid'); g.hidden = !state.grid;
  if (state.grid) {
    g.innerHTML = '';
    const W = (state.data && state.data.window) || {};
    const head = el('div', null, ''); head.id = 'gridHead';
    head.appendChild(el('h1', null, 'Argus Wrapped'));
    head.appendChild(el('span', null, `${pretty(W.startDay)} – ${pretty(W.endDay)} · ${W.activeDays || 0} active days`));
    g.appendChild(head);
    buildCards(state.data).forEach(c => g.appendChild(c));
    const back = el('button', 'mode', '<span class="ico">◂</span> Back to story'); back.id = 'backBtn';
    back.onclick = toggleGrid; g.appendChild(back);
    g.scrollTop = 0;
  }
}

function show(data) {
  state.data = data;
  if (!data || data.empty || !((data.totals || {}).events)) {
    $('#loading').textContent = 'No activity recorded yet. Come back after you have used Argus for a while.';
    $('#loading').hidden = false; $('#deck').hidden = true; $('#chrome').hidden = true;
    return;
  }
  state.cards = buildCards(data); state.idx = 0; state.grid = false;
  $('#loading').hidden = true; $('#grid').hidden = true;
  $('#deck').hidden = false; $('#chrome').hidden = false;
  render();
}

// ---------- nav wiring ----------
$('#next').onclick = e => { e.stopPropagation(); next(); };
$('#prev').onclick = e => { e.stopPropagation(); prev(); };
$('#modeBtn').onclick = e => { e.stopPropagation(); toggleGrid(); };
// click left/right halves of the deck to move (ignore clicks on links/buttons)
$('#deck').addEventListener('click', e => {
  if (e.target.closest('a,button')) return;
  const r = $('#deck').getBoundingClientRect();
  (e.clientX - r.left < r.width * 0.35 ? prev : next)();
});
window.addEventListener('keydown', e => {
  if (state.grid) { if (e.key === 'Escape' || e.key.toLowerCase() === 'g') toggleGrid(); return; }
  if (e.key === 'ArrowRight' || e.key === ' ') { next(); e.preventDefault(); }
  else if (e.key === 'ArrowLeft') prev();
  else if (e.key.toLowerCase() === 'g') toggleGrid();
});

// ---------- Swift bridge ----------
window.UTWrapped = {
  setData(obj) { try { show(typeof obj === 'string' ? JSON.parse(obj) : obj); } catch (e) { $('#loading').textContent = 'Error: ' + e.message; $('#loading').hidden = false; } },
  setTheme(t) { const r = document.documentElement.style; if (t.bg) r.setProperty('--bg', t.bg); if (t.fg) r.setProperty('--ink', t.fg); }
};
// tell Swift we are ready for data
if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ut) {
  window.webkit.messageHandlers.ut.postMessage({ type: 'ready' });
}
