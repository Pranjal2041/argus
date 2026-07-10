"use strict";

const Lab = {
  model: { sets: [], pendingKeys: [], pendingRuns: [], hubNotes: [] },
  area: "inbox",
  selection: null,
  details: Object.create(null),
  detailRequestedAt: Object.create(null),
  hostScale: 1,
  manualScale: (() => {
    try {
      const saved = Number(localStorage.getItem("argus.lab.text-scale.v1") || 1);
      return Number.isFinite(saved) ? Math.max(.8, Math.min(1.4, saved)) : 1;
    }
    catch (_) { return 1; }
  })(),
  autoScale: 1,
  uiScale: 1.3,
  initialized: false,
  drawerOpen: false,
  researchQuery: "",
  researchFilter: "active",
  runFilter: "all",
  runTab: "summary",
  compareMode: false,
  comparePicks: [],
  artifactSelection: Object.create(null),
  guidanceScope: 0,
  showHiddenNotes: false,
  accessOpen: false,
  drafts: Object.create(null),
  scroll: { main: 0, context: 0, blocks: Object.create(null) },
  action: null,
  syncAt: null,
  dataKey: "",
  fixture: new URLSearchParams(location.search).has("fixture"),
};

const $ = selector => document.querySelector(selector);
const esc = value => String(value == null ? "" : value).replace(/[&<>"']/g, ch => ({
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
})[ch]);
const jsText = value => String(value == null ? "" : value);
const clamp = (n, lo, hi) => Math.max(lo, Math.min(hi, n));

function icon(name) {
  const paths = {
    menu: '<path d="M3 6h18M3 12h18M3 18h18"/>',
    refresh: '<path d="M20 11a8 8 0 1 0 1.2 4.2M20 4v7h-7"/>',
    search: '<circle cx="11" cy="11" r="7"/><path d="m20 20-4-4"/>',
    terminal: '<path d="M4 5h16v14H4zM7 9l3 3-3 3M12 15h5"/>',
    folder: '<path d="M3 7h7l2 2h9v10H3z"/>',
    external: '<path d="M14 4h6v6M20 4l-9 9M18 13v7H4V6h7"/>',
    copy: '<rect x="8" y="8" width="11" height="11" rx="1"/><path d="M16 8V4H4v12h4"/>',
    archive: '<path d="M4 8h16v12H4zM3 4h18v4H3zM9 12h6"/>',
    compare: '<path d="M8 4 4 8l4 4M4 8h13M16 20l4-4-4-4M20 16H7"/>',
    note: '<path d="M5 4h14v16H5zM8 8h8M8 12h8M8 16h5"/>',
    chevron: '<path d="m9 18 6-6-6-6"/>',
  };
  return `<svg class="icon" viewBox="0 0 24 24" aria-hidden="true">${paths[name] || ""}</svg>`;
}

function ago(iso) {
  const at = Date.parse(iso || "");
  if (!Number.isFinite(at)) return iso || "";
  const seconds = Math.max(0, Math.floor((Date.now() - at) / 1000));
  if (seconds < 45) return "now";
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h`;
  if (seconds < 86400 * 30) return `${Math.floor(seconds / 86400)}d`;
  return new Date(at).toLocaleDateString(undefined, { month: "short", day: "numeric" });
}

function duration(seconds) {
  if (seconds == null || seconds < 0) return "—";
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
  return `${Math.floor(seconds / 3600)}h ${Math.floor((seconds % 3600) / 60)}m`;
}

function bytes(value) {
  const n = Number(value || 0);
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(n < 10 * 1024 ? 1 : 0)} KB`;
  return `${(n / (1024 * 1024)).toFixed(1)} MB`;
}

function displayPath(value) {
  const full = String(value || "");
  if (!full) return "—";
  let shown = full.replace(/^\/Users\/[^/]+\//, "~/");
  if (shown.length <= 34) return shown;
  const separator = shown.includes("\\") ? "\\" : "/";
  const parts = shown.split(/[\\/]+/).filter(Boolean);
  if (parts.length < 3) return shown;
  const prefix = shown.startsWith("~/") ? "~/" : shown.startsWith("/") ? "/" : "";
  return `${prefix}${parts[0]}${separator}…${separator}${parts[parts.length - 1]}`;
}

function statusInfo(raw) {
  const s = String(raw || "recorded");
  if (s.startsWith("running")) return { key: "running", label: s.replace(/^running\s*/i, "Running ").trim(), tone: "live" };
  if (s === "done") return { key: "finished", label: "Finished", tone: "verified" };
  if (s.startsWith("failed")) return { key: "failed", label: s.replace(/^failed/i, "Failed"), tone: "danger" };
  if (s === "denied") return { key: "rejected", label: "Rejected", tone: "danger" };
  if (s.startsWith("proposed")) return { key: "needs", label: "Needs approval", tone: "decision" };
  if (s.startsWith("approved")) return { key: "approved", label: "Approved · awaiting launch", tone: "decision" };
  return { key: "recorded", label: "Recorded", tone: "quiet" };
}

function statusWord(raw) {
  const st = statusInfo(raw);
  return `<span class="status-word status-${st.key}">${esc(st.label)}</span>`;
}

function normalizeModel(input) {
  const model = input || {};
  model.sets = Array.isArray(model.sets) ? model.sets : [];
  model.pendingKeys = Array.isArray(model.pendingKeys) ? model.pendingKeys : [];
  model.pendingRuns = Array.isArray(model.pendingRuns) ? model.pendingRuns : [];
  model.hubNotes = Array.isArray(model.hubNotes) ? model.hubNotes : [];
  for (const set of model.sets) {
    set.runs = Array.isArray(set.runs) ? set.runs : [];
    set.notes = Array.isArray(set.notes) ? set.notes : [];
    set.setNotes = Array.isArray(set.setNotes) ? set.setNotes : [];
  }
  return model;
}

function pendingItems() {
  const keys = Lab.model.pendingKeys.map(item => ({ type: "key", id: item.id, item }));
  const runs = Lab.model.pendingRuns.map(item => ({ type: "proposal", id: item.id, item }));
  return [...runs, ...keys].sort((a, b) => String(a.item.created || "").localeCompare(String(b.item.created || "")));
}

function allRuns(includeArchived = true) {
  const out = [];
  for (const card of Lab.model.sets) {
    if (!includeArchived && card.archived) continue;
    for (const run of card.runs) {
      if (!includeArchived && run.archived) continue;
      out.push({ card, run });
    }
  }
  return out;
}

function cardByID(id) { return Lab.model.sets.find(card => card.id === id); }
function cardForProposal(proposal) {
  return Lab.model.sets.find(card => card.setID === proposal.set && card.machineID === proposal.machineID)
    || Lab.model.sets.find(card => card.setID === proposal.set);
}

function detailKey(cardID, run) { return `${cardID}/${run}`; }
function detailFor(cardID, run) { return Lab.details[detailKey(cardID, run)]; }

function foldDetail(detail) {
  const events = detail && Array.isArray(detail.events) ? detail.events : [];
  const proposal = events.find(event => event.kind === "proposal");
  const start = events.find(event => event.kind === "run-start");
  const end = [...events].reverse().find(event => event.kind === "run-end");
  const decision = [...events].reverse().find(event => event.kind === "decision");
  const env = (start && start.data) || (proposal && proposal.data) || {};
  const hidden = new Set(events.filter(event => event.kind === "hide" && event.data && event.data.target).map(event => event.data.target));
  const results = events.filter(event => ["result", "note", "hnote"].includes(event.kind));
  return {
    events,
    proposal,
    start,
    end,
    decision,
    env,
    hidden,
    results,
    pending: Boolean(proposal && !decision && !start),
    files: detail && detail.files ? detail.files : {},
    manifest: detail && Array.isArray(detail.manifest) ? detail.manifest : [],
  };
}

function draft(key, fallback = "") {
  return Object.prototype.hasOwnProperty.call(Lab.drafts, key) ? Lab.drafts[key] : fallback;
}

function captureViewState() {
  const main = $("#main");
  const context = $("#context");
  if (main) Lab.scroll.main = main.scrollTop;
  if (context) Lab.scroll.context = context.scrollTop;
  document.querySelectorAll("[data-scroll-key]").forEach(node => {
    Lab.scroll.blocks[node.dataset.scrollKey] = { top: node.scrollTop, left: node.scrollLeft };
  });
}

function restoreViewState() {
  const main = $("#main");
  const context = $("#context");
  if (main) main.scrollTop = Lab.scroll.main || 0;
  if (context) context.scrollTop = Lab.scroll.context || 0;
  document.querySelectorAll("[data-scroll-key]").forEach(node => {
    const pos = Lab.scroll.blocks[node.dataset.scrollKey];
    if (pos) { node.scrollTop = pos.top; node.scrollLeft = pos.left; }
  });
}

function resetMainScroll() { Lab.scroll.main = 0; }

function savedLocation() {
  try { return JSON.parse(localStorage.getItem("argus.lab.location.v2") || "null"); }
  catch (_) { return null; }
}

function persistLocation() {
  if (!Lab.initialized || Lab.fixture) return;
  try { localStorage.setItem("argus.lab.location.v2", JSON.stringify({ area: Lab.area, selection: Lab.selection })); }
  catch (_) {}
}

function ensureSelection() {
  if (Lab.area === "inbox") {
    const items = pendingItems();
    const valid = Lab.selection && items.some(item => item.type === Lab.selection.type && item.id === Lab.selection.id);
    if (!valid) Lab.selection = items.length ? { type: items[0].type, id: items[0].id } : null;
    return;
  }
  if (Lab.area === "research") {
    if (Lab.selection && Lab.selection.card) {
      const card = cardByID(Lab.selection.card);
      if (!card) Lab.selection = null;
      else if (Lab.selection.type === "run" && !card.runs.some(run => run.id === Lab.selection.run)) Lab.selection = { type: "set", card: card.id };
      else if (Lab.selection.type === "compare" && (!card.runs.some(run => run.id === Lab.selection.a) || !card.runs.some(run => run.id === Lab.selection.b))) Lab.selection = { type: "set", card: card.id };
    }
    return;
  }
  if (Lab.area === "guidance") Lab.selection = null;
}

function render() {
  captureViewState();
  ensureSelection();
  $("#masthead").innerHTML = renderMasthead();
  $("#context").innerHTML = renderContext();
  $("#main").innerHTML = renderMain();
  document.body.classList.toggle("context-open", Lab.drawerOpen);
  document.body.classList.toggle("action-busy", Boolean(Lab.action));
  persistLocation();
  requestAnimationFrame(restoreViewState);
}

function renderMasthead() {
  const count = pendingItems().length;
  const tabs = [
    ["inbox", "Inbox"], ["research", "Research"], ["guidance", "Guidance"],
  ].map(([key, label]) => `<button class="nav-item ${Lab.area === key ? "active" : ""}" type="button" data-nav="${key}">
      ${label}${key === "inbox" && count ? `<span class="nav-badge">${count}</span>` : ""}
    </button>`).join("");
  return `
    <button class="drawer-toggle" type="button" data-action="drawer" aria-label="Open contextual navigation">${icon("menu")}</button>
    <div class="lab-mark" aria-label="Argus Lab">
      <span class="lab-eye" aria-hidden="true"></span>
      <span class="lab-name">LAB <span>/ ARGUS</span></span>
    </div>
    <nav class="primary-nav" aria-label="Lab destinations">${tabs}</nav>
    <span class="mast-spacer"></span>
    <div class="type-controls" role="group" aria-label="Lab text size">
      <button type="button" data-action="font-down" aria-label="Decrease Lab text size" title="Decrease text size (⌘−)">A−</button>
      <button class="type-readout" type="button" data-action="font-reset" aria-label="Reset Lab text size" title="Reset adaptive text size">${Math.round(Lab.uiScale * 100)}%</button>
      <button type="button" data-action="font-up" aria-label="Increase Lab text size" title="Increase text size (⌘+)">A+</button>
    </div>
    <span class="sync-state"><span class="lamp"></span>${Lab.syncAt ? `synced ${ago(Lab.syncAt.toISOString())}` : "waiting for brokers"}</span>
    <button class="icon-button" type="button" data-action="refresh" aria-label="Refresh Lab" title="Refresh Lab">${icon("refresh")}</button>`;
}

function renderContext() {
  if (Lab.area === "inbox") return renderInboxContext();
  if (Lab.area === "guidance") return renderGuidanceContext();
  return renderResearchContext();
}

function renderInboxContext() {
  const items = pendingItems();
  const proposals = items.filter(item => item.type === "proposal");
  const keys = items.filter(item => item.type === "key");
  const rows = (group, label) => group.length ? `<section class="queue-group">
      <div class="group-label">${label}</div>
      ${group.map(entry => {
        const item = entry.item;
        const selected = Lab.selection && Lab.selection.type === entry.type && Lab.selection.id === entry.id;
        const intent = entry.type === "proposal" ? item.intent : "Agent access request";
        const rid = entry.type === "proposal" ? item.run : "KEY";
        return `<button class="queue-row ${selected ? "active" : ""}" type="button" data-select-pending="${esc(entry.type)}" data-id="${esc(entry.id)}">
          <span class="queue-row-top"><span class="queue-kind">${entry.type === "proposal" ? "Experiment" : "Access"}</span><span class="queue-id">${esc(rid)}</span><span class="queue-age">${esc(ago(item.created))}</span></span>
          <span class="queue-intent">${esc(intent)}</span>
          <span class="queue-meta">${esc(item.project)} · ${esc(item.machineName || item.machine || "")}</span>
        </button>`;
      }).join("")}
    </section>` : "";
  return `<div class="context-heading"><span class="context-title">Decision queue</span><span class="context-count">${items.length}</span></div>
    <div class="context-help">Oldest request first. J/K moves through the queue; the evidence follows your selection.</div>
    ${rows(proposals, "Experiment approvals")}${rows(keys, "Access requests")}
    ${items.length ? "" : `<div class="context-empty">Nothing needs a decision. Running and recently finished work remains in Research.</div>`}`;
}

function searchMatchesSet(card, query) {
  if (!query) return true;
  const haystack = [card.project, card.machineName, card.cwd, card.setID]
    .concat(card.runs.flatMap(run => [run.id, run.group, run.latest, run.status])).join(" ").toLowerCase();
  return haystack.includes(query.toLowerCase());
}

function setTone(card) {
  const runs = card.runs.filter(run => !run.archived);
  if (runs.some(run => statusInfo(run.status).key === "failed")) return "danger";
  if (runs.some(run => statusInfo(run.status).key === "needs")) return "decision";
  if (runs.some(run => statusInfo(run.status).key === "running")) return "live";
  if (runs.some(run => statusInfo(run.status).key === "finished")) return "verified";
  return "";
}

function researchCards() {
  let cards = Lab.model.sets.filter(card => searchMatchesSet(card, Lab.researchQuery));
  if (Lab.researchFilter !== "archived") cards = cards.filter(card => !card.archived);
  if (Lab.researchFilter === "archived") cards = cards.filter(card => card.archived || card.runs.some(run => run.archived));
  if (Lab.researchFilter === "active") cards = cards.filter(card => card.runs.some(run => ["running", "needs", "approved"].includes(statusInfo(run.status).key)) || card.runs.length === 0);
  if (Lab.researchFilter === "failed") cards = cards.filter(card => card.runs.some(run => statusInfo(run.status).key === "failed"));
  if (Lab.researchFilter === "finished") cards = cards.filter(card => card.runs.some(run => statusInfo(run.status).key === "finished"));
  return cards;
}

function renderResearchContext() {
  const cards = researchCards();
  const groups = new Map();
  for (const card of cards) {
    if (!groups.has(card.project)) groups.set(card.project, []);
    groups.get(card.project).push(card);
  }
  return `<div class="context-heading"><span class="context-title">Research index</span><span class="context-count">${Lab.model.sets.length} sets</span></div>
    <div class="context-search">${icon("search")}<input id="research-search" data-draft="research-search" value="${esc(Lab.researchQuery)}" placeholder="Project, run, result…" aria-label="Search research"></div>
    <div class="segmented" style="margin:0 5px 14px;display:flex">
      ${[["active","Active"],["all","All"],["failed","Failed"],["archived","Archive"]].map(([key,label]) => `<button class="segment ${Lab.researchFilter === key ? "active" : ""}" type="button" data-research-filter="${key}">${label}</button>`).join("")}
    </div>
    ${[...groups.entries()].sort((a,b) => a[0].localeCompare(b[0])).map(([project, sets]) => `<section class="project-group">
      <div class="project-name">${esc(project)}</div>
      ${sets.sort((a,b) => String(b.created || "").localeCompare(String(a.created || ""))).map(card => {
        const selected = Lab.selection && Lab.selection.card === card.id;
        const active = card.runs.filter(run => ["running","needs","approved"].includes(statusInfo(run.status).key) && !run.archived).length;
        const runCount = card.runs.length;
        const state = card.offline ? "offline" : card.archived ? "archived" : active ? `${active} active` : `${runCount} run${runCount === 1 ? "" : "s"}`;
        return `<button class="set-row ${selected ? "active" : ""}" type="button" data-select-set="${esc(card.id)}">
          <span class="set-row-top"><span class="status-sliver ${setTone(card)}"></span><span class="set-name" title="${esc(card.machineName)}">${esc(card.machineName)}</span><span class="set-state">${state}</span></span>
          <span class="set-meta"><span class="set-id">${esc(card.setID)}</span><span class="set-path" title="${esc(card.cwd)}">${esc(displayPath(card.cwd))}</span></span>
        </button>`;
      }).join("")}
    </section>`).join("")}
    ${cards.length ? "" : `<div class="context-empty">No sets match this view.</div>`}`;
}

function guidanceScopes() {
  const scopes = [{ type: "all", label: "Everywhere", sub: "all reachable stores" }];
  for (const group of Lab.model.hubNotes) {
    scopes.push({ type: "machine", machineID: group.machineID, label: group.machineName, sub: "all agents on this store" });
    const projects = [...new Set(Lab.model.sets.filter(card => card.machineID === group.machineID
      || card.machineID === `mirror/${group.machineID}` || card.machineName === group.machineName).map(card => card.project))].sort();
    for (const project of projects) scopes.push({ type: "project", machineID: group.machineID, project, label: project, sub: group.machineName });
  }
  return scopes;
}

function renderGuidanceContext() {
  const scopes = guidanceScopes();
  Lab.guidanceScope = clamp(Lab.guidanceScope, 0, Math.max(0, scopes.length - 1));
  return `<div class="context-heading"><span class="context-title">Audiences</span><span class="context-count">${scopes.length}</span></div>
    <div class="context-help">Human-authored guidance is ground truth the next time an agent reads its brief.</div>
    <section class="scope-group">
      ${scopes.map((scope, index) => `<button class="scope-row ${Lab.guidanceScope === index ? "active" : ""}" type="button" data-guidance-scope="${index}">
        <span class="queue-row-top"><span class="set-name">${esc(scope.label)}</span></span><span class="set-meta">${esc(scope.sub)}</span>
      </button>`).join("")}
    </section>`;
}

function renderMain() {
  if (Lab.area === "inbox") return renderInboxMain();
  if (Lab.area === "guidance") return renderGuidanceMain();
  return renderResearchMain();
}

function breadcrumbs(parts) {
  return `<div class="breadcrumbs"><button type="button" data-research-home>Research</button>${parts.map((part, index) => `<span class="sep">/</span>${part.action ? `<button type="button" ${part.action}>${esc(part.label)}</button>` : `<span>${esc(part.label)}</span>`}`).join("")}</div>`;
}

function renderInboxMain() {
  const items = pendingItems();
  if (!items.length) return renderInboxClear();
  if (!Lab.selection) return renderInboxClear();
  if (Lab.selection.type === "key") {
    const key = Lab.model.pendingKeys.find(item => item.id === Lab.selection.id);
    return key ? renderAccessDossier(key) : renderInboxClear();
  }
  const proposal = Lab.model.pendingRuns.find(item => item.id === Lab.selection.id);
  return proposal ? renderProposalDossier(proposal) : renderInboxClear();
}

function renderInboxClear() {
  const running = allRuns(false).filter(({ run }) => statusInfo(run.status).key === "running");
  const recent = allRuns(false).filter(({ run }) => statusInfo(run.status).key === "finished" && run.latest).sort((a,b) => String(b.run.started || "").localeCompare(String(a.run.started || ""))).slice(0,4);
  return `<div class="main-content"><div class="inbox-clear"><div>
      <div class="clear-mark">✓</div><div class="eyebrow">Decision queue clear</div>
      <div class="clear-title">Nothing is waiting on you.</div>
      <div class="clear-copy">${running.length ? `${running.length} experiment${running.length === 1 ? " is" : "s are"} still running. Research keeps their live record.` : "Every recorded experiment is either underway or resolved."}</div>
      <div style="margin-top:20px"><button class="button" type="button" data-nav="research">Open Research</button></div>
    </div></div>
    ${recent.length ? `<div class="section-head"><h2>Recent findings</h2></div><div class="result-ledger">${recent.map(({card,run}) => `<button class="queue-row" style="border-left-color:var(--verified)" type="button" data-open-run="${esc(card.id)}" data-run="${esc(run.id)}"><span class="queue-row-top"><span class="queue-id">${esc(run.id)}</span><span class="queue-age">${esc(ago(run.started))}</span></span><span class="queue-intent">${esc(run.latest)}</span><span class="queue-meta">${esc(card.project)} · ${esc(card.machineName)}</span></button>`).join("")}</div>` : ""}
    </div>`;
}

function renderAccessDossier(key) {
  const projectDraft = draft(`key-project:${key.id}`, key.project || "");
  return `<div class="main-content has-dock">
    <div class="eyebrow">Access request · ${esc(ago(key.created))}</div>
    <h1 class="display-title">An agent wants a research set.</h1>
    <p class="lede">Approval creates one machine-bound key and one isolated experiment set. The agent may append records there; it does not gain access to another agent's set.</p>
    <section class="dossier"><div class="dossier-body">
      <div class="section-head" style="margin-top:0"><h2>Assignment boundary</h2></div>
      <div class="facts">
        <div class="fact-label">Machine</div><div class="fact-value">${esc(key.machineName)}</div>
        <div class="fact-label">Folder</div><div class="fact-value mono selectable">${esc(key.cwd)}</div>
        <div class="fact-label">Session</div><div class="fact-value">${esc(key.session || "not reported")}</div>
        <div class="fact-label">Requested</div><div class="fact-value">${esc(ago(key.created))} ago</div>
        <div class="fact-label">Project label</div><div class="fact-value"><input class="text-input" style="width:min(360px,100%)" data-draft="key-project:${esc(key.id)}" value="${esc(projectDraft)}" aria-label="Project label"></div>
      </div>
      ${key.session ? `<div style="margin-top:20px"><button class="button" type="button" data-action="terminal" data-machine="${esc(key.machineID)}" data-session="${esc(key.session)}">${icon("terminal")}Open agent terminal</button></div>` : ""}
    </div></section>
    ${decisionDock("key", { id: key.id, project: projectDraft })}
  </div>`;
}

function requestDetail(cardID, run, force = false) {
  if (!cardID || !run) return;
  const key = detailKey(cardID, run);
  const now = Date.now();
  if (!force && Lab.details[key]) return;
  if (!force && now - (Lab.detailRequestedAt[key] || 0) < 1200) return;
  Lab.detailRequestedAt[key] = now;
  post({ type: "needRunDetail", card: cardID, run });
}

function renderProposalDossier(proposal) {
  const card = cardForProposal(proposal);
  if (!card) return `<div class="main-content">${emptyState("Unresolved proposal", "Its owning experiment set is not currently available.")}</div>`;
  const detail = detailFor(card.id, proposal.run);
  requestDetail(card.id, proposal.run);
  const folded = foldDetail(detail);
  const env = folded.env;
  const snapshot = env.snapshot || {};
  const params = folded.files.params || [];
  const diff = folded.files.diff || "";
  const dataFiles = env.dataFiles || [];
  const message = draft(`decision:${card.id}/${proposal.run}`, "");
  return `<div class="main-content has-dock">
    <div class="eyebrow">Experiment approval · ${esc(proposal.run)} · ${esc(ago(proposal.created))}</div>
    <h1 class="display-title">${esc(proposal.intent || "Proposed experiment")}</h1>
    <div class="meta-line"><span>${esc(card.project)}</span><span class="meta-divider">/</span><span>${esc(card.machineName)}</span><span class="meta-divider">/</span><span>${esc(card.setID)}</span>${proposal.tier ? `<span class="tag">${esc(proposal.tier)}</span>` : ""}${proposal.group ? `<span class="tag">${esc(proposal.group)}</span>` : ""}</div>
    ${card.offline ? offlineBanner(card) : ""}
    <section class="dossier"><div class="dossier-body">
      <div class="section-head" style="margin-top:0"><h2>Approval envelope</h2><span class="section-kicker">bound to this exact evidence</span></div>
      ${detail ? `<div class="trust-grid">
        ${trustCell("Command", env.argv && env.argv.length ? env.argv[0] : "missing", env.argv && env.argv.length ? "" : "alert")}
        ${trustCell("Code", snapshot.noGit ? "no repository" : snapshot.baseSha ? snapshot.baseSha.slice(0,10) : "not captured", snapshot.baseSha ? "good" : "alert")}
        ${trustCell("Changes", snapshot.patchBytes != null ? (snapshot.patchBytes ? `${snapshot.patchBytes} B diff` : "clean tree") : "not captured", snapshot.patchBytes != null ? "good" : "alert")}
        ${trustCell("Parameters", `${(env.params || []).length} file${(env.params || []).length === 1 ? "" : "s"}`, "")}
        ${trustCell("Declared data", `${dataFiles.length} fingerprint${dataFiles.length === 1 ? "" : "s"}`, dataFiles.length ? "good" : "")}
      </div>
      ${env.argv && env.argv.length ? `<div class="command-line selectable">${esc(env.argv.join(" "))}</div>` : ""}
      <div class="evidence-preview ${params.length && diff ? "" : "single"}">
        ${params.length ? renderEvidenceBlock(params[0].path, params[0].text, `proposal-param:${card.id}:${proposal.run}`, "wrap") : ""}
        ${diff ? renderEvidenceBlock("uncommitted code", colorDiff(diff), `proposal-diff:${card.id}:${proposal.run}`, "html") : ""}
      </div>` : `<div class="skeleton"></div><div class="skeleton"></div>`}
    </div></section>
    ${decisionDock("run", { card: card.id, run: proposal.run, message })}
  </div>`;
}

function trustCell(label, value, klass) {
  return `<div class="trust-cell"><div class="trust-label">${esc(label)}</div><div class="trust-value ${klass || ""}" title="${esc(value)}">${esc(value)}</div></div>`;
}

function decisionDock(kind, data) {
  const isKey = kind === "key";
  const key = isKey ? `key-project:${data.id}` : `decision:${data.card}/${data.run}`;
  const value = draft(key, isKey ? data.project : data.message);
  return `<div class="decision-dock" role="group" aria-label="Decision controls">
    ${isKey
      ? `<div class="secondary human-copy">One key · one isolated set · this machine only</div>`
      : `<input class="text-input" data-draft="${esc(key)}" value="${esc(value)}" placeholder="Optional message back to the agent" aria-label="Message to agent">`}
    <button class="button danger" type="button" data-action="${isKey ? "decide-key" : "decide-run"}" data-approve="0" data-id="${esc(data.id || "")}" data-card="${esc(data.card || "")}" data-run="${esc(data.run || "")}">${isKey ? "Deny" : "Reject"}</button>
    <button class="button primary" type="button" data-action="${isKey ? "decide-key" : "decide-run"}" data-approve="1" data-id="${esc(data.id || "")}" data-card="${esc(data.card || "")}" data-run="${esc(data.run || "")}">Approve</button>
  </div>`;
}

function renderResearchMain() {
  if (!Lab.selection) return renderResearchOverview();
  if (Lab.selection.type === "compare") return renderCompare();
  if (Lab.selection.type === "run") return renderRunRecord();
  if (Lab.selection.type === "set") return renderSetPage();
  return renderResearchOverview();
}

function renderResearchOverview() {
  const runs = allRuns(false);
  const active = runs.filter(({run}) => ["running","needs","approved"].includes(statusInfo(run.status).key));
  const failures = runs.filter(({run}) => statusInfo(run.status).key === "failed").sort((a,b) => String(b.run.started || "").localeCompare(String(a.run.started || ""))).slice(0,5);
  const findings = runs.filter(({run}) => statusInfo(run.status).key === "finished" && run.latest).sort((a,b) => String(b.run.started || "").localeCompare(String(a.run.started || ""))).slice(0,6);
  return `<div class="main-content wide">
    <div class="eyebrow">Research ledger</div><h1 class="display-title">The record, not the recollection.</h1>
    <p class="lede">Every wrapped run across ${Lab.model.sets.length} isolated set${Lab.model.sets.length === 1 ? "" : "s"}: intent, exact code, parameters, declared data, environment, logs, and findings.</p>
    <div class="section-head"><h2>In motion</h2><span class="section-kicker">${active.length} active or awaiting launch</span></div>
    ${active.length ? renderRunLedger(active, false, true) : `<div class="guidance-strip">No experiments are currently running or awaiting launch.</div>`}
    ${failures.length ? `<div class="section-head"><h2>Failures worth inspecting</h2></div>${renderRunLedger(failures, false, true)}` : ""}
    <div class="section-head"><h2>Recent findings</h2></div>
    ${findings.length ? `<div class="result-ledger">${findings.map(({card,run}) => `<div class="result-row"><span class="result-time">${esc(ago(run.started))}</span><button class="button link human-copy" style="justify-content:flex-start;text-align:left" type="button" data-open-run="${esc(card.id)}" data-run="${esc(run.id)}">${esc(run.latest)}</button><span class="tag">${esc(card.project)} / ${esc(run.id)}</span></div>`).join("")}</div>` : emptyState("No findings yet", "Agent-reported results will collect here as runs finish.")}
  </div>`;
}

function latestGuidance(card) {
  const notes = [...card.notes, ...card.setNotes]
    .filter(note => note.text && (note.author === "human" || note.kind === "hnote"))
    .sort((a,b) => String(a.time || "").localeCompare(String(b.time || "")));
  return notes.length ? notes[notes.length - 1] : null;
}

function renderSetPage() {
  const card = cardByID(Lab.selection.card);
  if (!card) return renderResearchOverview();
  const guidance = latestGuidance(card);
  return `<div class="main-content wide">
    ${breadcrumbs([{ label: card.project }])}
    <div class="page-head"><div class="page-head-main">
      <div class="eyebrow">Experiment set · ${esc(card.setID)}</div><h1 class="display-title">${esc(card.project)}</h1>
      <div class="meta-line"><span>${esc(card.machineName)}</span><span class="meta-divider">/</span><span class="selectable">${esc(card.cwd)}</span><span class="meta-divider">/</span><span>${card.keyActive ? "key active" : "access closed"}</span>${card.archived ? `<span class="tag">archived set</span>` : ""}</div>
    </div><div class="page-actions">${card.offline ? "" : `<button class="button" type="button" data-action="files" data-card="${esc(card.id)}" data-cwd="${esc(card.cwd)}">${icon("folder")}Files</button>`}</div></div>
    ${card.offline ? offlineBanner(card) : ""}
    <div class="set-summary-grid"><div>${guidance ? `<div class="guidance-strip"><strong>Current guidance</strong><br>${esc(guidance.text)}</div>` : `<div class="guidance-strip">No human guidance is attached to this set yet. Open Guidance to establish standing context.</div>`}</div>
      ${card.offline ? "" : `<details class="access-panel" ${Lab.accessOpen ? "open" : ""}><summary>Access &amp; policy</summary><div class="access-controls">
        <label class="fact-label" for="policy-select">Approval policy</label>
        <select id="policy-select" class="select-input" data-action="policy" data-card="${esc(card.id)}">
          <option value="all" ${card.policy === "all" ? "selected" : ""}>Every run needs approval</option>
          <option value="full-only" ${card.policy === "full-only" ? "selected" : ""}>Only full runs need approval</option>
          <option value="none" ${card.policy === "none" ? "selected" : ""}>Runs start without approval</option>
        </select>
        <button class="button small" type="button" data-action="archive" data-card="${esc(card.id)}" data-on="${card.archived ? "0" : "1"}">${icon("archive")}${card.archived ? "Unarchive set" : "Archive set"}</button>
        ${card.keyActive ? `<button class="button danger small" type="button" data-action="revoke" data-card="${esc(card.id)}">Revoke agent access</button>` : ""}
      </div></details>`}
    </div>
    <div class="research-toolbar">
      <div class="segmented">${[["all","All"],["active","Active"],["failed","Failed"],["finished","Finished"],["archived","Archive"]].map(([key,label]) => `<button class="segment ${Lab.runFilter === key ? "active" : ""}" type="button" data-run-filter="${key}">${label}</button>`).join("")}</div>
      <span style="flex:1"></span>
      <button class="button small ${Lab.compareMode ? "primary" : ""}" type="button" data-action="compare-mode">${icon("compare")}${Lab.compareMode ? "Cancel compare" : "Compare runs"}</button>
      ${Lab.compareMode && Lab.comparePicks.length === 2 ? `<button class="button primary small" type="button" data-action="compare-go">Compare ${esc(Lab.comparePicks[0])} / ${esc(Lab.comparePicks[1])}</button>` : ""}
    </div>
    ${renderRunLedger(filteredRuns(card), Lab.compareMode)}
  </div>`;
}

function filteredRuns(card) {
  let runs = card.runs.map(run => ({ card, run }));
  if (Lab.runFilter !== "archived") runs = runs.filter(({run}) => !run.archived);
  if (Lab.runFilter === "archived") runs = runs.filter(({run}) => run.archived);
  if (Lab.runFilter === "active") runs = runs.filter(({run}) => ["running","needs","approved"].includes(statusInfo(run.status).key));
  if (Lab.runFilter === "failed") runs = runs.filter(({run}) => statusInfo(run.status).key === "failed");
  if (Lab.runFilter === "finished") runs = runs.filter(({run}) => statusInfo(run.status).key === "finished");
  return runs.sort((a,b) => runNumber(b.run.id) - runNumber(a.run.id));
}

function runNumber(id) { const match = /^R(\d+)$/.exec(id || ""); return match ? Number(match[1]) : -1; }

function renderRunLedger(entries, compare, showScope = false) {
  if (!entries.length) return `<div class="empty-state" style="min-height:220px"><div><h2>No runs in this view.</h2><p>Change the filter or wait for the agent to record one.</p></div></div>`;
  return `<div class="ledger-wrap"><table class="ledger ${showScope ? "with-scope" : ""}"><thead><tr>${compare ? `<th class="compare-col"></th>` : ""}<th class="run-col">${showScope ? "Run / set" : "Run"}</th><th class="status-col">Phase</th><th class="tag-col">Tier / group</th><th>Latest result</th><th class="time-col">Started</th></tr></thead><tbody>
    ${entries.map(({card,run}) => `<tr data-open-run="${esc(card.id)}" data-run="${esc(run.id)}" style="${run.archived ? "opacity:.55" : ""}">
      ${compare ? `<td class="compare-col"><input type="checkbox" data-compare-pick="${esc(run.id)}" ${Lab.comparePicks.includes(run.id) ? "checked" : ""} aria-label="Select ${esc(run.id)} for comparison"></td>` : ""}
      <td class="run-col">${esc(run.id)}${showScope ? `<span class="run-scope" title="${esc(`${card.project} · ${card.machineName}`)}">${esc(card.project)}</span>` : ""}</td><td class="status-col">${statusWord(run.status)}</td>
      <td class="tag-col">${run.tier ? `<span class="tag">${esc(run.tier)}</span>` : ""}${run.group ? `<span class="tag" style="margin-left:4px">${esc(run.group)}</span>` : ""}</td>
      <td class="result-col">${esc(run.latest || (statusInfo(run.status).key === "running" ? "Awaiting the next reported result…" : "No result reported"))}</td>
      <td class="time-col">${esc(ago(run.started))}</td></tr>`).join("")}
  </tbody></table></div>`;
}

function renderRunRecord() {
  const card = cardByID(Lab.selection.card);
  if (!card) return renderResearchOverview();
  const run = card.runs.find(item => item.id === Lab.selection.run) || { id: Lab.selection.run, status: "recorded" };
  const detail = detailFor(card.id, run.id);
  requestDetail(card.id, run.id);
  const folded = foldDetail(detail);
  const st = statusInfo(run.status);
  const pending = folded.pending || st.key === "needs";
  const latest = [...folded.results].reverse().find(event => event.kind === "result" && event.text && !folded.hidden.has(event.id));
  const update = [...folded.results].reverse().find(event => event.kind === "note" && event.text && !folded.hidden.has(event.id));
  const hero = st.key === "failed" ? `The run exited without a successful result${run.exitCode >= 0 ? ` (code ${run.exitCode})` : ""}.`
    : latest ? latest.text : st.key === "running" && update ? update.text
    : run.latest ? run.latest
    : st.key === "running" ? "The experiment is running; no finding has been reported yet."
    : st.key === "needs" ? (folded.proposal && folded.proposal.text) || "This experiment is waiting for approval."
    : "No result has been reported.";
  const resultLabel = st.key === "failed" ? "Failure" : pending ? "Proposed intent"
    : st.key === "running" && !latest ? "Latest update" : "Latest finding";
  const message = draft(`decision:${card.id}/${run.id}`, "");
  return `<div class="main-content wide ${pending ? "has-dock" : ""}">
    ${breadcrumbs([{ label: card.project, action: `data-select-set="${esc(card.id)}"` }, { label: run.id }])}
    <div class="page-head"><div class="page-head-main"><div class="eyebrow">Run record · ${esc(card.setID)}</div>
      <h1 class="display-title mono">${esc(run.id)}</h1><div class="meta-line">${statusWord(run.status)}${run.tier ? `<span class="tag">${esc(run.tier)}</span>` : ""}${run.group ? `<span class="tag">${esc(run.group)}</span>` : ""}${run.archived ? `<span class="tag">archived run</span>` : ""}<span>${esc(card.machineName)}</span></div>
    </div><div class="page-actions">${runActions(card, run, folded)}</div></div>
    ${card.offline ? offlineBanner(card) : ""}
    ${evidenceSpine(folded, run, card)}
    <section class="run-result ${st.key === "failed" ? "failed" : pending ? "pending" : ""}"><div class="run-result-label">${resultLabel}</div><div class="run-result-text selectable">${esc(hero)}</div></section>
    ${folded.env.argv && folded.env.argv.length ? `<div class="command-line selectable">${esc(folded.env.argv.join(" "))}</div>` : ""}
    ${detail ? `<nav class="tab-bar" aria-label="Run evidence">${runTabs(folded).map(([key,label]) => `<button class="tab ${Lab.runTab === key ? "active" : ""}" type="button" data-run-tab="${key}">${label}</button>`).join("")}</nav><div class="tab-panel">${renderRunTab(card, run, folded)}</div>` : `<div class="skeleton"></div><div class="skeleton"></div>`}
    ${pending && !card.offline ? decisionDock("run", { card: card.id, run: run.id, message }) : ""}
  </div>`;
}

function runTabs(folded) {
  const tabs = [["summary","Summary"]];
  if ((folded.files.params || []).length) tabs.push(["parameters","Parameters"]);
  if (folded.env.snapshot && !folded.env.snapshot.noGit) tabs.push(["code","Code"]);
  if (folded.files.log) tabs.push(["log","Log"]);
  tabs.push(["provenance","Provenance"]);
  if (!tabs.some(([key]) => key === Lab.runTab)) Lab.runTab = "summary";
  return tabs;
}

function runActions(card, run, folded) {
  const out = [];
  if (!card.offline && folded.env.tmuxSession) out.push(`<button class="button small" type="button" data-action="terminal" data-machine="${esc(card.machineID)}" data-session="${esc(folded.env.tmuxSession)}">${icon("terminal")}Terminal</button>`);
  if (!card.offline && folded.env.cwd) out.push(`<button class="button small" type="button" data-action="files" data-card="${esc(card.id)}" data-cwd="${esc(folded.env.cwd)}">${icon("folder")}Files</button>`);
  if (!card.offline && folded.end && folded.end.data && folded.end.data.wandb && folded.end.data.wandb.length) out.push(`<button class="button small" type="button" data-action="wandb" data-card="${esc(card.id)}" data-session="${esc(folded.env.tmuxSession || "")}" data-run-ref="${esc(folded.end.data.wandb[0])}">${icon("external")}W&amp;B</button>`);
  if (card.runs.length > 1) out.push(`<button class="button small" type="button" data-action="compare-from" data-card="${esc(card.id)}" data-run="${esc(run.id)}">${icon("compare")}Compare</button>`);
  if (!card.offline) out.push(`<button class="button small" type="button" data-action="archive" data-card="${esc(card.id)}" data-run="${esc(run.id)}" data-on="${run.archived ? "0" : "1"}">${icon("archive")}${run.archived ? "Unarchive" : "Archive"}</button>`);
  return out.join("");
}

function evidenceSpine(folded, run, card) {
  const proposed = folded.proposal;
  const decision = folded.decision;
  const started = folded.start;
  const ended = folded.end;
  const approved = decision && decision.data && decision.data.approve === true;
  const rejected = decision && decision.data && decision.data.approve === false;
  const phase = statusInfo(run.status).key;
  const failed = (ended && ended.data && Number(ended.data.exit) !== 0) || phase === "failed";
  const startedEvidence = started || (run.started && ["running", "finished", "failed"].includes(phase) ? { time: run.started, data: {} } : null);
  const tier = folded.env.tier || run.tier || "";
  const policy = card.policy || "full-only";
  const decisionRequired = policy === "all" || (policy === "full-only" && tier === "full");
  const decisionState = rejected ? "rejected" : approved ? "complete"
    : proposed && !startedEvidence ? "current" : startedEvidence && !decision && !decisionRequired ? "bypassed" : "";
  const decisionNote = rejected ? "rejected" : approved ? "approved"
    : proposed && !startedEvidence ? "awaiting human" : startedEvidence && !decision && !decisionRequired ? "not required by policy"
    : "not recorded";
  const node = (label, event, state, note) => `<div class="spine-node ${state || ""}"><div class="spine-label">${label}</div><div class="spine-time">${event ? esc(ago(event.time)) + " ago" : "not recorded"}</div>${note ? `<div class="spine-note">${esc(note)}</div>` : ""}</div>`;
  return `<div class="evidence-spine" aria-label="Run lifecycle">
    ${node("Proposed", proposed, proposed ? "complete" : "", proposed && proposed.text)}
    ${node("Decision", decision, decisionState, decisionNote)}
    ${node("Started", startedEvidence, startedEvidence ? "complete" : approved ? "current" : "", started ? card.machineName : startedEvidence ? "summary record" : "")}
    ${node("Ended", ended, failed ? "failed" : ended ? "complete" : phase === "finished" ? "complete" : startedEvidence ? "current" : "", ended ? `exit ${ended.data && ended.data.exit != null ? ended.data.exit : run.exitCode}` : phase === "finished" ? `exit ${run.exitCode >= 0 ? run.exitCode : "recorded"} · detail unavailable` : failed ? `exit ${run.exitCode >= 0 ? run.exitCode : "recorded"} · detail unavailable` : startedEvidence ? "in progress" : "")}
  </div>`;
}

function renderRunTab(card, run, folded) {
  switch (Lab.runTab) {
    case "parameters": return renderParameters(folded, card, run);
    case "code": return renderCode(folded, card, run);
    case "log": return renderLog(folded, card, run);
    case "provenance": return renderProvenance(folded, card, run);
    default: return renderSummary(folded, card, run);
  }
}

function renderSummary(folded, card, run) {
  const end = folded.end && folded.end.data ? folded.end.data : {};
  const env = folded.env;
  const visible = folded.results.filter(event => !folded.hidden.has(event.id)).reverse();
  const dataFiles = env.dataFiles || [];
  const noteDraft = draft(`run-note:${card.id}/${run.id}`, "");
  return `<div class="summary-grid"><div class="summary-stack">
    <section><div class="section-head" style="margin-top:0"><h2>Reported results</h2><span class="section-kicker">agent claims remain attributable</span></div>
      ${visible.length ? `<div class="result-ledger">${visible.map(event => `<div class="result-row"><span class="result-time">${esc(ago(event.time))}</span><span class="result-copy selectable">${esc(event.text || "")}</span><span class="row-actions">${!card.offline && event.author === "agent" ? `<button class="row-action" type="button" data-action="hide-result" data-card="${esc(card.id)}" data-run="${esc(run.id)}" data-target="${esc(event.id)}">hide</button>` : `<span class="tag">${event.author === "human" ? "human" : event.author}</span>`}</span></div>`).join("")}</div>` : run.latest ? `<div class="result-ledger"><div class="result-row"><span class="result-time">summary</span><span class="result-copy selectable">${esc(run.latest)}</span><span class="tag">run summary</span></div></div>` : `<div class="secondary human-copy">No result has been reported yet.</div>`}
      ${card.offline ? "" : `<div class="note-composer"><input class="text-input" data-draft="run-note:${esc(card.id)}/${esc(run.id)}" value="${esc(noteDraft)}" placeholder="Add a human note to this run" aria-label="Human note"><button class="button" type="button" data-action="run-note" data-card="${esc(card.id)}" data-run="${esc(run.id)}">${icon("note")}Add note</button></div>`}
    </section>
    ${dataFiles.length ? `<section><div class="section-head"><h2>Declared data integrity</h2></div>${dataFiles.map(ref => { const drift = (end.drift || []).includes(ref.path); const state = drift ? "changed during run" : folded.end ? "unchanged" : "fingerprinted · final check pending"; return `<div class="integrity-row"><span class="integrity-path selectable">${esc(ref.path)}</span><span class="integrity-state ${drift ? "alert" : ""}">${state}</span></div>`; }).join("")}</section>` : ""}
  </div><aside class="summary-stack">
    <section><div class="section-head" style="margin-top:0"><h2>Envelope</h2></div><div class="facts">
      <div class="fact-label">Project</div><div class="fact-value">${esc(card.project)}</div>
      <div class="fact-label">Machine</div><div class="fact-value">${esc(card.machineName)}</div>
      <div class="fact-label">Folder</div><div class="fact-value mono selectable">${esc(env.cwd || card.cwd)}</div>
      <div class="fact-label">Tier</div><div class="fact-value">${esc(env.tier || run.tier || "—")}</div>
      <div class="fact-label">Group</div><div class="fact-value">${esc(env.group || run.group || "—")}</div>
      <div class="fact-label">Duration</div><div class="fact-value">${esc(duration(end.durationSec))}</div>
      <div class="fact-label">Exit</div><div class="fact-value">${end.exit != null ? esc(end.exit) : run.exitCode >= 0 ? esc(run.exitCode) : "—"}</div>
      <div class="fact-label">Python</div><div class="fact-value">${esc(env.env && env.env.python || "—")}</div>
      <div class="fact-label">GPU</div><div class="fact-value">${esc(env.env && env.env.gpus || "—")}</div>
    </div></section>
    ${end.wandb && end.wandb.length ? `<section><div class="section-head"><h2>Weights &amp; Biases</h2></div>${end.wandb.map(ref => card.offline ? `<span class="mono secondary selectable">${esc(ref)}</span>` : `<button class="button link mono" type="button" data-action="wandb" data-card="${esc(card.id)}" data-session="${esc(env.tmuxSession || "")}" data-run-ref="${esc(ref)}">${esc(ref)}</button>`).join("")}</section>` : ""}
  </aside></div>`;
}

function renderParameters(folded, card, run) {
  const params = folded.files.params || [];
  return params.length ? `<div class="summary-stack">${params.map((param,index) => renderEvidenceBlock(param.path, param.text, `param:${card.id}:${run.id}:${index}`, "wrap")).join("")}</div>` : emptyState("No parameter files", "This run did not capture a parameter file.");
}

function renderCode(folded, card, run) {
  const snapshot = folded.env.snapshot || {};
  if (snapshot.noGit) return emptyState("No Git snapshot", "The run folder was not a Git repository.");
  const diff = folded.files.diff || "";
  return `<div class="meta-line" style="margin-bottom:14px"><span class="tag">commit ${esc((snapshot.baseSha || "unknown").slice(0,12))}</span><span>${snapshot.patchBytes ? `${snapshot.patchBytes} bytes of uncommitted changes` : "clean working tree"}</span></div>
    ${diff ? renderEvidenceBlock("snapshot/diff.patch", colorDiff(diff), `diff:${card.id}:${run.id}`, "html") : snapshot.patchBytes ? `<div class="warning-banner">The snapshot records ${esc(bytes(snapshot.patchBytes))} of uncommitted changes, but this copy does not include the patch file.</div>` : `<div class="guidance-strip">No uncommitted changes were captured. The base commit is the complete code state.</div>`}`;
}

function renderLog(folded, card, run) {
  const log = folded.files.log || "";
  return log ? `${renderEvidenceBlock("log.txt · stored tail", log, `log:${card.id}:${run.id}`, "")}
    <div class="secondary" style="margin-top:10px;font-size:.72rem">This view shows the fetched tail. The capped full record remains with the run on its source machine.</div>` : emptyState("No log available", "The source machine may be offline or this run did not write a log.");
}

function artifactKind(name) {
  const path = String(name || "").toLowerCase();
  if (path.endsWith("log.txt")) return "run log";
  if (path.endsWith("diff.patch")) return "code diff";
  if (path.endsWith("events.jsonl")) return "event record";
  if (path.endsWith(".tar.gz")) return "binary archive";
  if (path.endsWith("env.txt")) return "environment";
  if (path.startsWith("files/") || path.includes("/files/")) return "parameters";
  return "artifact";
}

function artifactPayload(name, folded) {
  const path = String(name || "");
  const lowerPath = path.toLowerCase();
  if (lowerPath.endsWith("log.txt") && folded.files.log != null) return { text: folded.files.log, mode: "" };
  if (lowerPath.endsWith("diff.patch") && folded.files.diff != null) return { text: colorDiff(folded.files.diff), mode: "html" };
  if (lowerPath.endsWith("env.txt") && folded.files.env != null) return { text: folded.files.env, mode: "wrap" };
  if (lowerPath.endsWith("events.jsonl")) {
    return { text: (folded.events || []).map(event => JSON.stringify(event)).join("\n"), mode: "wrap" };
  }
  const basename = path.split(/[\\/]/).pop();
  const param = (folded.files.params || []).find(item => String(item.path || "").split(/[\\/]/).pop() === basename);
  if (param) return { text: param.text || "", mode: "wrap" };
  if (lowerPath.endsWith(".tar.gz")) return { message: "This is a binary snapshot archive. It is retained by the broker for recovery and provenance, but is not rendered as text." };
  return { message: "The broker lists this artifact, but no text preview is available in the current record." };
}

function renderArtifactPreview(name, folded, card, run) {
  const payload = artifactPayload(name, folded);
  return `<div class="artifact-preview" data-artifact-preview>
    ${payload.message ? `<div class="artifact-message"><span class="artifact-message-label">${esc(artifactKind(name))}</span>${esc(payload.message)}</div>`
      : renderEvidenceBlock(name, payload.text, `artifact:${card.id}:${run.id}:${name}`, payload.mode)}
  </div>`;
}

function renderProvenance(folded, card, run) {
  const envText = folded.files.env || "";
  const artifactKey = detailKey(card.id, run.id);
  const selectedArtifact = Lab.artifactSelection[artifactKey] || "";
  return `<div class="summary-grid"><div><div class="section-head" style="margin-top:0"><h2>Event record</h2></div><div class="timeline">${folded.events.filter(event => event.kind !== "hide").map(event => `<div class="timeline-event"><div class="timeline-kind">${esc(eventLabel(event.kind))}<span class="timeline-time">${esc(ago(event.time))} ago</span></div><div class="timeline-detail selectable">${esc(event.text || eventSummary(event))}</div></div>`).join("")}</div></div>
    <aside class="summary-stack"><section><div class="section-head" style="margin-top:0"><h2>Approval binding</h2></div><div class="command-line selectable" style="white-space:pre-wrap">${esc(folded.env.bind || "No bind recorded")}</div></section>
      ${folded.manifest.length ? `<section><div class="section-head"><h2>Stored artifacts</h2><span class="section-kicker">select to inspect</span></div><div class="artifact-list">${folded.manifest.map(file => `<button class="artifact-row ${selectedArtifact === file.name ? "active" : ""}" type="button" data-action="artifact" data-card="${esc(card.id)}" data-run="${esc(run.id)}" data-name="${esc(file.name)}" aria-expanded="${selectedArtifact === file.name}"><span class="artifact-name">${esc(file.name)}</span><span class="artifact-kind">${esc(artifactKind(file.name))}</span><span class="artifact-size">${esc(bytes(file.size))}</span>${icon("chevron")}</button>`).join("")}</div>${selectedArtifact ? renderArtifactPreview(selectedArtifact, folded, card, run) : ""}</section>` : ""}
      ${envText ? `<section><div class="section-head"><h2>Environment freeze</h2></div>${renderEvidenceBlock("files/env.txt", envText, `env:${card.id}:${run.id}`, "")}</section>` : ""}
    </aside></div>`;
}

function eventLabel(kind) {
  return ({ proposal: "Proposed", decision: "Decision", "run-start": "Started", "run-end": "Ended", result: "Result", note: "Agent note", hnote: "Human note", "data-drift": "Data drift", archive: "Archive" })[kind] || kind;
}

function eventSummary(event) {
  if (event.kind === "run-end" && event.data) return `exit ${event.data.exit}; ${duration(event.data.durationSec)}`;
  if (event.kind === "decision" && event.data) return event.data.approve ? "approved by human" : "rejected by human";
  if (event.kind === "run-start" && event.data && event.data.argv) return event.data.argv.join(" ");
  return "details recorded";
}

function renderEvidenceBlock(path, text, key, mode) {
  const body = mode === "html" ? text : esc(text || "");
  return `<section class="evidence-block"><header class="evidence-head"><span class="path">${esc(path)}</span><span class="spacer"></span><button class="row-action" type="button" data-action="copy" data-copy="${esc(mode === "html" ? stripTags(text) : text || "")}">${icon("copy")} copy</button></header><pre class="evidence-body ${mode === "wrap" ? "wrap" : ""}" data-scroll-key="${esc(key)}">${body}</pre></section>`;
}

function stripTags(html) { const div = document.createElement("div"); div.innerHTML = html || ""; return div.textContent || ""; }
function colorDiff(text) {
  return String(text || "").split("\n").map(line => {
    const value = esc(line);
    if (line.startsWith("+") && !line.startsWith("+++")) return `<span class="diff-add">${value}</span>`;
    if (line.startsWith("-") && !line.startsWith("---")) return `<span class="diff-del">${value}</span>`;
    if (line.startsWith("@@")) return `<span class="diff-hunk">${value}</span>`;
    return value;
  }).join("\n");
}

function offlineBanner(card) {
  return `<div class="offline-banner"><strong>Offline copy.</strong> ${card.machineName} is unavailable. This record was last mirrored ${card.mirroredAt ? `${ago(card.mirroredAt)} ago` : "before it went offline"}; actions requiring the source machine are disabled.</div>`;
}

function renderCompare() {
  const card = cardByID(Lab.selection.card);
  if (!card) return renderResearchOverview();
  const runA = card.runs.find(run => run.id === Lab.selection.a);
  const runB = card.runs.find(run => run.id === Lab.selection.b);
  if (!runA || !runB) return renderSetPage();
  requestDetail(card.id, runA.id); requestDetail(card.id, runB.id);
  const detailA = detailFor(card.id, runA.id), detailB = detailFor(card.id, runB.id);
  const a = foldDetail(detailA), b = foldDetail(detailB);
  const endA = a.end && a.end.data || {}, endB = b.end && b.end.data || {};
  const resultA = [...a.results].reverse().find(event => event.kind === "result" && event.text);
  const resultB = [...b.results].reverse().find(event => event.kind === "result" && event.text);
  const paramsA = a.files.params && a.files.params[0], paramsB = b.files.params && b.files.params[0];
  return `<div class="main-content wide">${breadcrumbs([{label:card.project,action:`data-select-set="${esc(card.id)}"`},{label:`${runA.id} vs ${runB.id}`}])}
    <div class="eyebrow">Run comparison</div><h1 class="display-title mono">${esc(runA.id)} <span class="quiet">/</span> ${esc(runB.id)}</h1>
    <p class="lede">A literal difference view of two recorded envelopes. Parameter lines are compared exactly; no semantic config interpretation is implied.</p>
    ${!detailA || !detailB ? `<div class="skeleton"></div><div class="skeleton"></div>` : `<div class="compare-heads">
      ${compareRow("", runA.id, runB.id, "run")}${compareRow("Phase", statusInfo(runA.status).label, statusInfo(runB.status).label)}${compareRow("Result", resultA && resultA.text || "—", resultB && resultB.text || "—")}${compareRow("Duration", duration(endA.durationSec), duration(endB.durationSec))}${compareRow("Exit", endA.exit == null ? "—" : endA.exit, endB.exit == null ? "—" : endB.exit)}${compareRow("Command", (a.env.argv || []).join(" ") || "—", (b.env.argv || []).join(" ") || "—")}${compareRow("Code", codeState(a.env.snapshot), codeState(b.env.snapshot))}
    </div>
    ${paramsA && paramsB ? `<div class="section-head"><h2>Parameter delta</h2><span class="section-kicker">exact non-empty lines</span></div>${parameterDelta(paramsA, paramsB, runA.id, runB.id)}` : ""}`}
  </div>`;
}

function compareRow(label, a, b, klass) { return `<div class="compare-cell label">${esc(label)}</div><div class="compare-cell ${klass || ""}">${esc(a)}</div><div class="compare-cell ${klass || ""}">${esc(b)}</div>`; }
function codeState(snapshot) {
  if (!snapshot || !Object.keys(snapshot).length) return "—";
  if (snapshot.noGit) return "no Git repository";
  return `${(snapshot.baseSha || "unknown").slice(0,10)}${snapshot.patchBytes ? ` + ${snapshot.patchBytes} B diff` : " · clean"}`;
}
function parameterDelta(a, b, labelA, labelB) {
  const linesA = String(a.text || "").split("\n").filter(line => line.trim());
  const linesB = String(b.text || "").split("\n").filter(line => line.trim());
  const setA = new Set(linesA), setB = new Set(linesB);
  const onlyA = linesA.filter(line => !setB.has(line)), onlyB = linesB.filter(line => !setA.has(line));
  if (!onlyA.length && !onlyB.length) return `<div class="guidance-strip">Captured parameter lines are identical.</div>`;
  return `<div class="compare-delta"><section class="delta-panel a">${renderEvidenceBlock(`only in ${labelA}`, onlyA.join("\n") || "nothing", `cmp-a:${labelA}:${labelB}`, "wrap")}</section><section class="delta-panel b">${renderEvidenceBlock(`only in ${labelB}`, onlyB.join("\n") || "nothing", `cmp-b:${labelA}:${labelB}`, "wrap")}</section></div>`;
}

function renderGuidanceMain() {
  const scopes = guidanceScopes();
  Lab.guidanceScope = clamp(Lab.guidanceScope, 0, Math.max(0, scopes.length - 1));
  const scope = scopes[Lab.guidanceScope] || scopes[0];
  const notes = guidanceNotes(scope).sort((a,b) => String(b.note.time || "").localeCompare(String(a.note.time || "")));
  const visible = Lab.showHiddenNotes ? notes : notes.filter(item => !item.note.hidden);
  const draftKey = `guidance:${Lab.guidanceScope}`;
  const copy = draft(draftKey, "");
  return `<div class="main-content wide"><div class="eyebrow">Human channel</div><h1 class="display-title">Guidance</h1>
    <p class="lede">These are instructions, not observations. Agents receive them as human-authored ground truth when they read their Lab brief.</p>
    <section class="audience-card" style="margin-top:25px"><div class="audience-row">
      <div><div class="fact-label">Audience</div><div style="margin-top:6px;font-family:var(--serif)">${esc(scope.label)}</div></div>
      <textarea class="text-area" data-draft="${esc(draftKey)}" placeholder="Write guidance your agents should carry forward…" aria-label="Guidance text">${esc(copy)}</textarea>
      <button class="button primary" type="button" data-action="guidance-note" data-scope-index="${Lab.guidanceScope}">Publish guidance</button>
    </div><div class="audience-explain">${esc(scopeExplanation(scope))}</div></section>
    <div class="section-head"><h2>Instruction ledger</h2><span class="section-kicker">${notes.filter(item => !item.note.hidden).length} active</span><span class="section-action"><button class="button small" type="button" data-action="toggle-hidden">${Lab.showHiddenNotes ? "Hide archived notes" : "Show hidden notes"}</button></span></div>
    ${visible.length ? `<div class="notes-ledger">${visible.map(item => `<div class="note-row"><span class="note-audience">${esc(noteAudience(item.note))}</span><span class="note-copy selectable ${item.note.hidden ? "hidden" : ""}">${esc(item.note.text)}</span><span class="note-origin">${esc(item.group.machineName)}<br>${esc(ago(item.note.time))}</span><span>${item.note.hidden ? `<span class="tag">hidden</span>` : `<button class="row-action" type="button" data-action="hide-guidance" data-machine="${esc(item.group.machineID)}" data-scope="${esc(item.note.scope)}" data-project="${esc(item.note.project || "")}" data-target="${esc(item.note.id)}">hide</button>`}</span></div>`).join("")}</div>` : emptyState("No guidance in this audience", "Write the first durable instruction above.")}
  </div>`;
}

function guidanceNotes(scope) {
  const out = [];
  for (const group of Lab.model.hubNotes) for (const note of group.notes || []) {
    const sameMachine = group.machineID === scope.machineID;
    const match = scope.type === "all"
      || (scope.type === "machine" && sameMachine && ["global", "machine"].includes(note.scope))
      || (scope.type === "project" && sameMachine && (["global", "machine"].includes(note.scope)
        || (note.scope === "project" && note.project === scope.project)));
    if (match) out.push({ group, note });
  }
  return out;
}
function noteAudience(note) { return note.scope === "global" ? "all agents" : note.scope === "machine" ? "machine" : note.scope === "project" ? `project / ${note.project || "?"}` : note.scope; }
function scopeExplanation(scope) {
  if (scope.type === "all") return "One copy is written to every reachable Lab store. Every approved agent, anywhere, will read it.";
  if (scope.type === "machine") return `Every approved agent on ${scope.label} will read it, regardless of project.`;
  return `Only agents working on ${scope.project} on ${scope.sub} will read it.`;
}

function emptyState(title, copy) { return `<div class="empty-state"><div><div class="empty-symbol"><span>·</span></div><h2>${esc(title)}</h2><p>${esc(copy)}</p></div></div>`; }

function post(message) {
  try {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ut) {
      window.webkit.messageHandlers.ut.postMessage(message);
      return true;
    }
  } catch (error) { console.error("Lab bridge", error); }
  console.log("Lab intent", message);
  return false;
}

function startAction(type, payload, successMessage, draftKey = "") {
  if (Lab.action) return;
  const id = `lab-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  Lab.action = { id, type, successMessage, draftKey };
  render();
  const bridged = post({ type, actionID: id, ...payload });
  if (!bridged) setTimeout(() => window.UTLab.actionResult(id, true, `Preview: ${successMessage}`), 240);
}

function toast(message, isError = false) {
  const region = $("#toast-region");
  const node = document.createElement("div");
  node.className = `toast ${isError ? "error" : ""}`;
  node.textContent = message;
  region.appendChild(node);
  setTimeout(() => node.remove(), 3600);
}

function copyText(text) {
  const area = document.createElement("textarea");
  area.value = text; area.style.position = "fixed"; area.style.opacity = "0";
  document.body.appendChild(area); area.select();
  try { document.execCommand("copy"); toast("Copied to clipboard"); } catch (_) { toast("Copy failed", true); }
  area.remove();
}

function setArea(area) {
  Lab.area = area;
  Lab.selection = null;
  Lab.drawerOpen = false;
  resetMainScroll();
  render();
}

function selectPending(type, id) { Lab.area = "inbox"; Lab.selection = { type, id }; Lab.drawerOpen = false; resetMainScroll(); render(); }
function selectSet(card) { Lab.area = "research"; Lab.selection = { type: "set", card }; Lab.drawerOpen = false; Lab.compareMode = false; Lab.comparePicks = []; resetMainScroll(); render(); }
function preferredRunTab(cardID, runID) {
  const card = cardByID(cardID);
  const run = card && card.runs.find(item => item.id === runID);
  return run && statusInfo(run.status).key === "failed" ? "log" : "summary";
}
function openRun(card, run) { Lab.area = "research"; Lab.selection = { type: "run", card, run }; Lab.drawerOpen = false; Lab.runTab = preferredRunTab(card, run); resetMainScroll(); render(); }

document.addEventListener("click", event => {
  const nav = event.target.closest("[data-nav]");
  if (nav) { setArea(nav.dataset.nav); return; }
  const pending = event.target.closest("[data-select-pending]");
  if (pending) { selectPending(pending.dataset.selectPending, pending.dataset.id); return; }
  const set = event.target.closest("[data-select-set]");
  if (set) { selectSet(set.dataset.selectSet); return; }
  const run = event.target.closest("[data-open-run]");
  if (run && !event.target.matches("input[type=checkbox]")) { openRun(run.dataset.openRun, run.dataset.run); return; }
  const home = event.target.closest("[data-research-home]");
  if (home) { Lab.area = "research"; Lab.selection = null; resetMainScroll(); render(); return; }
  const filter = event.target.closest("[data-research-filter]");
  if (filter) { Lab.researchFilter = filter.dataset.researchFilter; render(); return; }
  const runFilter = event.target.closest("[data-run-filter]");
  if (runFilter) { Lab.runFilter = runFilter.dataset.runFilter; render(); return; }
  const tab = event.target.closest("[data-run-tab]");
  if (tab) { Lab.runTab = tab.dataset.runTab; Lab.scroll.main = $("#main").scrollTop; render(); return; }
  const scope = event.target.closest("[data-guidance-scope]");
  if (scope) { Lab.guidanceScope = Number(scope.dataset.guidanceScope); Lab.drawerOpen = false; resetMainScroll(); render(); return; }
  const action = event.target.closest("[data-action]");
  if (!action) return;
  const kind = action.dataset.action;
  if (kind === "drawer") { Lab.drawerOpen = !Lab.drawerOpen; render(); return; }
  if (kind === "font-down") { setManualScale(Lab.manualScale - .1); return; }
  if (kind === "font-up") { setManualScale(Lab.manualScale + .1); return; }
  if (kind === "font-reset") { setManualScale(1); return; }
  if (kind === "refresh") { post({ type: "refresh" }); toast("Refreshing Lab…"); return; }
  if (kind === "terminal") { post({ type: "openTerminal", machineID: action.dataset.machine, session: action.dataset.session }); return; }
  if (kind === "files") { post({ type: "openFiles", card: action.dataset.card, cwd: action.dataset.cwd }); return; }
  if (kind === "wandb") { post({ type: "openWandb", card: action.dataset.card, session: action.dataset.session, run: action.dataset.runRef }); return; }
  if (kind === "copy") { copyText(action.dataset.copy || ""); return; }
  if (kind === "artifact") {
    const key = detailKey(action.dataset.card, action.dataset.run);
    Lab.artifactSelection[key] = Lab.artifactSelection[key] === action.dataset.name ? "" : action.dataset.name;
    render();
    if (Lab.artifactSelection[key]) setTimeout(() => {
      const preview = document.querySelector("[data-artifact-preview]");
      const main = $("#main");
      if (preview && main) {
        const target = preview.getBoundingClientRect(), frame = main.getBoundingClientRect();
        if (target.bottom > frame.bottom) main.scrollBy({ top: target.bottom - frame.bottom + 18, behavior: "smooth" });
        else if (target.top < frame.top) main.scrollBy({ top: target.top - frame.top - 18, behavior: "smooth" });
      }
    }, 40);
    return;
  }
  if (kind === "decide-key") {
    const id = action.dataset.id;
    startAction("decideKey", { id, approve: action.dataset.approve === "1", project: draft(`key-project:${id}`) }, action.dataset.approve === "1" ? "Access approved" : "Access denied", `key-project:${id}`); return;
  }
  if (kind === "decide-run") {
    const card = action.dataset.card, runID = action.dataset.run;
    startAction("decideRun", { card, run: runID, approve: action.dataset.approve === "1", note: draft(`decision:${card}/${runID}`) }, action.dataset.approve === "1" ? "Experiment approved" : "Experiment rejected", `decision:${card}/${runID}`); return;
  }
  if (kind === "compare-mode") { Lab.compareMode = !Lab.compareMode; Lab.comparePicks = []; render(); return; }
  if (kind === "compare-go" && Lab.comparePicks.length === 2 && Lab.selection && Lab.selection.card) { Lab.selection = { type: "compare", card: Lab.selection.card, a: Lab.comparePicks[0], b: Lab.comparePicks[1] }; Lab.compareMode = false; resetMainScroll(); render(); return; }
  if (kind === "compare-from") {
    const card = cardByID(action.dataset.card); if (!card) return;
    const other = card.runs.filter(item => item.id !== action.dataset.run && !item.archived).sort((a,b) => runNumber(b.id)-runNumber(a.id))[0];
    if (other) { Lab.selection = { type: "compare", card: card.id, a: action.dataset.run, b: other.id }; resetMainScroll(); render(); }
    return;
  }
  if (kind === "archive") { startAction("archive", { card: action.dataset.card, run: action.dataset.run || "", on: action.dataset.on === "1" }, action.dataset.on === "1" ? "Moved to archive" : "Restored from archive"); return; }
  if (kind === "revoke") { if (confirm("Revoke this agent's access? Every experiment record remains.")) startAction("revoke", { card: action.dataset.card }, "Agent access revoked"); return; }
  if (kind === "hide-result") { startAction("hide", { card: action.dataset.card, run: action.dataset.run, target: action.dataset.target }, "Agent claim hidden from briefs"); return; }
  if (kind === "run-note") {
    const key = `run-note:${action.dataset.card}/${action.dataset.run}`;
    const text = draft(key).trim(); if (!text) return;
    startAction("note", { card: action.dataset.card, run: action.dataset.run, scope: "run", text }, "Human note added", key); return;
  }
  if (kind === "guidance-note") {
    const index = Number(action.dataset.scopeIndex), scopes = guidanceScopes(), target = scopes[index];
    const text = draft(`guidance:${index}`).trim(); if (!target || !text) return;
    const draftKey = `guidance:${index}`;
    if (target.type === "all") startAction("hubNoteAll", { text }, "Guidance published everywhere", draftKey);
    else startAction("hubNote", { machineID: target.machineID, scope: target.type === "project" ? "project" : "machine", project: target.project || "", text }, "Guidance published", draftKey);
    return;
  }
  if (kind === "hide-guidance") { startAction("hubHide", { machineID: action.dataset.machine, scope: action.dataset.scope, project: action.dataset.project || "", target: action.dataset.target }, "Guidance hidden from agent briefs"); return; }
  if (kind === "toggle-hidden") { Lab.showHiddenNotes = !Lab.showHiddenNotes; render(); return; }
});

$("#drawer-scrim").addEventListener("click", () => { Lab.drawerOpen = false; render(); });

document.addEventListener("input", event => {
  const input = event.target;
  if (input.dataset && input.dataset.draft) Lab.drafts[input.dataset.draft] = input.value;
  if (input.id === "research-search") { Lab.researchQuery = input.value; Lab.scroll.context = 0; render(); const next = $("#research-search"); if (next) { next.focus(); next.setSelectionRange(next.value.length, next.value.length); } }
});

document.addEventListener("change", event => {
  const input = event.target;
  if (input.dataset && input.dataset.comparePick) {
    event.stopPropagation();
    const id = input.dataset.comparePick;
    if (input.checked && !Lab.comparePicks.includes(id)) Lab.comparePicks.push(id);
    if (!input.checked) Lab.comparePicks = Lab.comparePicks.filter(item => item !== id);
    while (Lab.comparePicks.length > 2) Lab.comparePicks.shift();
    render(); return;
  }
  if (input.dataset && input.dataset.action === "policy") startAction("policy", { card: input.dataset.card, policy: input.value }, "Approval policy updated");
});

document.addEventListener("toggle", event => {
  if (event.target.classList && event.target.classList.contains("access-panel")) Lab.accessOpen = event.target.open;
}, true);

document.addEventListener("keydown", event => {
  const editing = ["INPUT", "TEXTAREA", "SELECT"].includes(document.activeElement && document.activeElement.tagName);
  if (event.metaKey || event.ctrlKey) {
    if (event.key === "+" || event.key === "=") { setManualScale(Lab.manualScale + .1); event.preventDefault(); return; }
    if (event.key === "-") { setManualScale(Lab.manualScale - .1); event.preventDefault(); return; }
    if (event.key === "0") { setManualScale(1); event.preventDefault(); return; }
  }
  if (event.key === "Escape") {
    if (Lab.drawerOpen) { Lab.drawerOpen = false; render(); event.preventDefault(); return; }
    if (Lab.compareMode) { Lab.compareMode = false; Lab.comparePicks = []; render(); event.preventDefault(); return; }
  }
  if (!editing && event.key === "/" && Lab.area === "research") { event.preventDefault(); Lab.drawerOpen = true; render(); setTimeout(() => $("#research-search") && $("#research-search").focus(), 0); return; }
  if (!editing && Lab.area === "inbox" && ["j","k","ArrowDown","ArrowUp"].includes(event.key)) {
    const items = pendingItems(); if (!items.length) return;
    let index = items.findIndex(item => Lab.selection && item.type === Lab.selection.type && item.id === Lab.selection.id);
    const delta = event.key === "j" || event.key === "ArrowDown" ? 1 : -1;
    index = clamp(index + delta, 0, items.length - 1);
    Lab.selection = { type: items[index].type, id: items[index].id }; resetMainScroll(); render(); event.preventDefault();
  }
});

function automaticTextScale() {
  const widthProgress = clamp((window.innerWidth - 680) / 720, 0, 1);
  const heightProgress = clamp((window.innerHeight - 560) / 440, 0, 1);
  return .94 + Math.min(widthProgress, heightProgress) * .1;
}

function applyTextScale() {
  Lab.autoScale = automaticTextScale();
  Lab.uiScale = clamp(1.3 * Lab.hostScale * Lab.manualScale * Lab.autoScale, .9, 2.5);
  document.documentElement.style.setProperty("--ui-scale", Lab.uiScale);
  const readout = document.querySelector(".type-readout");
  if (readout) readout.textContent = `${Math.round(Lab.uiScale * 100)}%`;
}

function setManualScale(value) {
  Lab.manualScale = Math.round(clamp(value, .8, 1.4) * 10) / 10;
  try { localStorage.setItem("argus.lab.text-scale.v1", String(Lab.manualScale)); } catch (_) {}
  layout();
}

function layout() {
  applyTextScale();
  const effectiveWidth = window.innerWidth / Lab.uiScale;
  document.body.classList.toggle("compact", effectiveWidth < 800);
  document.body.classList.toggle("medium", effectiveWidth < 980);
  document.body.classList.toggle("narrow", effectiveWidth < 760);
  document.body.classList.toggle("ultra-compact", effectiveWidth < 520);
  if (effectiveWidth >= 800 && Lab.drawerOpen) { Lab.drawerOpen = false; document.body.classList.remove("context-open"); }
}
window.addEventListener("resize", layout);

window.UTLab = {
  setTheme() {},
  setFontSize(px) {
    Lab.hostScale = clamp(Number(px || 24) / 24, .8, 2);
    layout();
  },
  setData(input) {
    const model = normalizeModel(input);
    const key = JSON.stringify(model);
    Lab.model = model;
    Lab.syncAt = new Date();
    if (!Lab.initialized) {
      Lab.initialized = true;
      const queryView = new URLSearchParams(location.search).get("view");
      const saved = savedLocation();
      if (queryView === "notes" || queryView === "guidance") Lab.area = "guidance";
      else if (queryView === "home" || queryView === "research") Lab.area = "research";
      else if (pendingItems().length) { Lab.area = "inbox"; Lab.selection = null; }
      else if (saved && ["inbox", "research", "guidance"].includes(saved.area)) { Lab.area = saved.area; Lab.selection = saved.selection || null; }
      else Lab.area = "research";
    }
    if (key !== Lab.dataKey) { Lab.dataKey = key; render(); }
    else { $("#masthead").innerHTML = renderMasthead(); }
  },
  setRunDetail(card, run, detail) {
    Lab.details[detailKey(card, run)] = detail || {};
    if (Lab.selection && Lab.selection.card === card && (Lab.selection.run === run || Lab.selection.a === run || Lab.selection.b === run)) render();
    if (Lab.area === "inbox") render();
  },
  actionResult(id, ok, message) {
    if (!Lab.action || Lab.action.id !== id) return;
    const action = Lab.action;
    Lab.action = null;
    if (ok) {
      if (action.draftKey) delete Lab.drafts[action.draftKey];
      toast(message || action.successMessage || "Done");
    } else toast(message || "The action failed", true);
    render();
  },
  openView(view) { setArea(view === "notes" ? "guidance" : view === "home" ? "research" : view); },
  fixtureRoute(area, selection, options = {}) {
    Lab.fixture = true; Lab.area = area; Lab.selection = selection || null; Lab.initialized = true;
    if (options.researchFilter) Lab.researchFilter = options.researchFilter;
    if (selection && selection.type === "run") Lab.runTab = preferredRunTab(selection.card, selection.run);
    resetMainScroll(); render();
  },
};

setInterval(() => {
  let cardID = "", run = "", status = "";
  if (Lab.area === "research" && Lab.selection && Lab.selection.type === "run") {
    cardID = Lab.selection.card; run = Lab.selection.run;
    const card = cardByID(cardID); const summary = card && card.runs.find(item => item.id === run); status = summary && statusInfo(summary.status).key;
  } else if (Lab.area === "inbox" && Lab.selection && Lab.selection.type === "proposal") {
    const proposal = Lab.model.pendingRuns.find(item => item.id === Lab.selection.id); const card = proposal && cardForProposal(proposal);
    if (proposal && card) { cardID = card.id; run = proposal.run; status = "needs"; }
  }
  if (cardID && ["running","needs","approved"].includes(status)) requestDetail(cardID, run, true);
}, 5000);

layout();
render();
