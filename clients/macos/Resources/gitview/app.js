// Git panel logic. Swift injects data via window.UTGit.*; user intents go back via
// webkit.messageHandlers.ut.postMessage. Three read-only views: Changes (status +
// diffs with per-file stats), History (lane graph + commit detail with a file list),
// Blame (age-heat gutter).
(function () {
  "use strict";

  function post(type, extra) {
    var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ut;
    if (h) h.postMessage(Object.assign({ type: type }, extra || {}));
  }
  function el(id) { return document.getElementById(id); }
  function esc(s) {
    return String(s).replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }
  function rel(at) {
    if (!at) return "";
    var s = Math.max(1, Math.floor(Date.now() / 1000 - at));
    if (s < 60) return s + "s";
    if (s < 3600) return Math.floor(s / 60) + "m";
    if (s < 86400) return Math.floor(s / 3600) + "h";
    if (s < 86400 * 30) return Math.floor(s / 86400) + "d";
    if (s < 86400 * 365) return Math.floor(s / 86400 / 30) + "mo";
    return Math.floor(s / 86400 / 365) + "y";
  }
  // Stable pastel-ish color per author (GitKraken-style identity without network avatars).
  function authorColor(name) {
    var h = 0;
    for (var i = 0; i < name.length; i++) h = (h * 31 + name.charCodeAt(i)) >>> 0;
    return "hsl(" + (h % 360) + ", 45%, 45%)";
  }
  function initials(name) {
    var p = String(name).trim().split(/\s+/);
    return ((p[0] || "?")[0] + (p.length > 1 ? p[p.length - 1][0] : "")).toUpperCase();
  }
  function avatar(name) {
    return '<span class="avatar" style="background:' + authorColor(name) + '" title="' + esc(name) + '">' + esc(initials(name)) + "</span>";
  }
  function refPill(r) {
    var cls = "ref", label = r;
    if (/^tag: /.test(r)) { cls += " tag"; label = r.slice(5); }
    else if (/^[^/]+\/.+/.test(r)) { cls += " remote"; }
    return '<span class="' + cls + '" title="' + esc(r) + '">' + esc(label) + "</span>";
  }
  var EXT_COLORS = { go:"#00add8", swift:"#f05138", js:"#e8d44d", ts:"#3178c6", py:"#3572a5",
    md:"#8ba9c0", json:"#e0af68", css:"#7a67c9", html:"#e34c26", sh:"#89e051", rs:"#dea584",
    java:"#b07219", kt:"#a97bff", c:"#9a9db0", h:"#9a9db0", cpp:"#f34b7d", yml:"#cb5c5c",
    yaml:"#cb5c5c", txt:"#9a9db0", toml:"#9c4221", sql:"#c88536", rb:"#701516" };
  function extChip(path) {
    var m = String(path).match(/\.([a-z0-9]+)$/i);
    var ext = m ? m[1].toLowerCase() : "";
    if (!ext || ext.length > 5) return "";
    var c = EXT_COLORS[ext];
    return '<span class="ext"' + (c ? ' style="color:' + c + '"' : "") + ">" + esc(ext) + "</span>";
  }

  // Per-file added/removed counts parsed from a unified diff.
  function diffStats(text) {
    var files = [], cur = null;
    (text || "").split("\n").forEach(function (ln) {
      if (ln.startsWith("diff --git ")) {
        var m = ln.match(/ b\/(.+)$/);
        cur = { path: m ? m[1] : ln.slice(11), add: 0, del: 0 };
        files.push(cur);
      } else if (cur && ln.startsWith("+") && !ln.startsWith("+++")) cur.add++;
      else if (cur && ln.startsWith("-") && !ln.startsWith("---")) cur.del++;
    });
    return files;
  }

  var state = {
    summary: null,
    log: [],
    sideBySide: true,
    view: "changes",
    lastDiff: null,       // {target, text, meta}
    headStats: {},        // path → {add, del} from the head diff
    logFilter: "",
    fileFilter: "",
    allBranches: false,
    compareWith: null,
    selCommit: null,
    blameFrom: "changes"
  };

  // ---- view switching ------------------------------------------------------
  function showView(name) {
    state.view = name;
    ["changes", "history", "blame"].forEach(function (v) {
      var node = el("view-" + v);
      var show = v === name;
      if (show && node.style.display === "none") {
        node.classList.remove("showing");
        void node.offsetWidth; // restart the entrance animation
        node.classList.add("showing");
      }
      node.style.display = show ? "flex" : "none";
    });
    el("tab-changes").classList.toggle("active", name === "changes");
    el("tab-history").classList.toggle("active", name === "history");
  }
  el("tab-changes").onclick = function () { showView("changes"); };
  el("tab-history").onclick = function () {
    showView("history");
    if (!state.log.length) post("moreLog", { skip: 0, all: state.allBranches });
  };
  el("btn-refresh").onclick = function () { post("refresh"); };
  el("btn-lazygit").onclick = function () { post("lazygit"); };
  el("btn-mode").onclick = function () {
    state.sideBySide = !state.sideBySide;
    if (state.lastDiff) renderDiff(state.lastDiff.target, state.lastDiff.text, state.lastDiff.meta);
  };
  el("blame-back").onclick = function () { showView(state.blameFrom); };
  el("all-branches").onclick = function () {
    state.allBranches = !state.allBranches;
    this.classList.toggle("on", state.allBranches);
    state.log = [];
    overlay("loading history…");
    post("moreLog", { skip: 0, all: state.allBranches });
  };
  // draggable split between list and detail (both views)
  document.querySelectorAll(".drag").forEach(function (h) {
    h.addEventListener("mousedown", function (e) {
      e.preventDefault();
      var sidebar = h.previousElementSibling;
      h.classList.add("active");
      function move(ev) {
        var w = Math.min(Math.max(ev.clientX, 220), window.innerWidth * 0.65);
        sidebar.style.width = w + "px";
      }
      function up() {
        h.classList.remove("active");
        document.removeEventListener("mousemove", move);
        document.removeEventListener("mouseup", up);
      }
      document.addEventListener("mousemove", move);
      document.addEventListener("mouseup", up);
    });
  });
  el("log-filter").oninput = function () { state.logFilter = this.value.toLowerCase(); paintLog(); };
  el("files-filter").oninput = function () { state.fileFilter = this.value.toLowerCase(); paintFiles(); };

  // keyboard nav in History: ↑/↓ moves the selected commit
  document.addEventListener("keydown", function (ev) {
    if (state.view !== "history" || (ev.target && ev.target.tagName === "INPUT")) return;
    if (ev.key !== "ArrowDown" && ev.key !== "ArrowUp") return;
    ev.preventDefault();
    var rows = Array.prototype.slice.call(el("commits").querySelectorAll(".crow"));
    if (!rows.length) return;
    var idx = rows.findIndex(function (r) { return r.classList.contains("sel"); });
    idx = idx === -1 ? 0 : Math.min(rows.length - 1, Math.max(0, idx + (ev.key === "ArrowDown" ? 1 : -1)));
    rows[idx].click();
    rows[idx].scrollIntoView({ block: "nearest" });
  });

  // ---- diff rendering (diff2html + stats header) ---------------------------
  function renderDiff(targetID, text, meta) {
    state.lastDiff = { target: targetID, text: text, meta: meta };
    var target = el(targetID);
    if (!text || !text.trim()) {
      target.innerHTML = '<div class="empty"><span class="big">✓</span>No changes' +
        (meta && meta.title ? " in " + esc(meta.title) : "") + ".</div>";
      return;
    }
    var stats = diffStats(text);
    var totAdd = 0, totDel = 0;
    stats.forEach(function (f) { totAdd += f.add; totDel += f.del; });

    target.innerHTML = "";
    // "N files changed +X −Y" bar + per-file jump list (collapsed when 1 file)
    var bar = document.createElement("div");
    bar.className = "diffstat-bar";
    bar.innerHTML = '<span class="tot">' + stats.length + " file" + (stats.length === 1 ? "" : "s") + " changed</span>" +
      '<span class="p">+' + totAdd + '</span><span class="m">−' + totDel + "</span>" +
      '<span class="spacer"></span>' +
      '<button data-x="collapse">collapse all</button><button data-x="expand">expand all</button>';
    target.appendChild(bar);

    if (stats.length > 1) {
      var fl = document.createElement("div");
      fl.className = "filelist";
      fl.innerHTML = stats.map(function (f, i) {
        var tot = f.add + f.del, blocks = "";
        for (var b = 0; b < 5; b++) {
          blocks += '<i class="' + (tot === 0 ? "" : b < Math.round(5 * f.add / (tot || 1)) ? "p" : "m") + '"></i>';
        }
        return '<div class="flrow" data-i="' + i + '">' + extChip(f.path) + '<span class="fpath">' + esc(f.path) + "</span>" +
          '<span class="fstat"><span class="p">+' + f.add + '</span><span class="m">−' + f.del + "</span></span>" +
          '<span class="flbar">' + blocks + "</span></div>";
      }).join("");
      target.appendChild(fl);
    }

    var host = document.createElement("div");
    target.appendChild(host);
    /* global Diff2HtmlUI, hljs */
    var ui = new Diff2HtmlUI(host, text, {
      outputFormat: state.sideBySide ? "side-by-side" : "line-by-line",
      drawFileList: false,
      matching: "words",
      renderNothingWhenEmpty: true,
      colorScheme: "dark",
      highlight: true,
      fileContentToggle: true
    }, hljs);
    ui.draw();

    // per-file stats chip in each diff2html file header (before the Viewed toggle)
    var wrappersAll = host.querySelectorAll(".d2h-file-wrapper");
    wrappersAll.forEach(function (w, i) {
      var st = stats[i];
      var head = w.querySelector(".d2h-file-header");
      if (st && head) {
        var chip = document.createElement("span");
        chip.className = "gv-stats";
        chip.innerHTML = '<span class="p">+' + st.add + '</span><span class="m">−' + st.del + "</span>";
        head.insertBefore(chip, head.querySelector(".d2h-file-collapse"));
      }
    });
    // wire the jump list + expand/collapse
    var wrappers = host.querySelectorAll(".d2h-file-wrapper");
    target.querySelectorAll(".flrow").forEach(function (row) {
      row.onclick = function () {
        var w = wrappers[+row.dataset.i];
        if (w) w.scrollIntoView({ behavior: "smooth", block: "start" });
      };
    });
    bar.querySelectorAll("button").forEach(function (b) {
      b.onclick = function () {
        var hide = b.dataset.x === "collapse";
        host.querySelectorAll(".d2h-file-collapse input, .d2h-file-header + div, .d2h-files-diff, .d2h-file-diff").forEach(function () {});
        wrappers.forEach(function (w) {
          var body = w.querySelector(".d2h-file-diff, .d2h-files-diff");
          if (body) body.style.display = hide ? "none" : "";
        });
      };
    });
    target.scrollTop = 0;
  }

  // ---- Changes view --------------------------------------------------------
  function paintFiles() {
    var s = state.summary;
    if (!s) return;
    var staged = [], unstaged = [], untracked = [];
    (s.files || []).forEach(function (f) {
      if (state.fileFilter && f.path.toLowerCase().indexOf(state.fileFilter) === -1) return;
      if (f.untracked) untracked.push(f);
      else {
        if (f.staged !== ".") staged.push(f);
        if (f.unstaged !== ".") unstaged.push(f);
      }
    });
    var total = staged.length + unstaged.length + untracked.length;
    var h = "";
    if (total) {
      h += '<div class="frow" data-all="1"><span class="badge R">Σ</span><span class="fpath"><bdi>All changes</bdi></span>' +
        '<span class="fstat"><span class="p">' + Object.keys(state.headStats).length + " files</span></span></div>";
    }
    function stat(f) {
      var st = state.headStats[f.path];
      if (!st) return "";
      return '<span class="fstat"><span class="p">+' + st.add + '</span><span class="m">−' + st.del + "</span></span>";
    }
    function section(title, files, scope) {
      if (!files.length) return;
      h += '<div class="sec">' + title + ' <span class="cnt">' + files.length + "</span></div>";
      files.forEach(function (f) {
        var letter = scope === "staged" ? f.staged : scope === "worktree" ? f.unstaged : "U";
        var cls = letter === "?" ? "U" : letter;
        h += '<div class="frow" data-path="' + esc(f.path) + '" data-scope="' + scope + '">' +
          '<span class="badge ' + cls + '">' + letter + "</span>" +
          '<span class="fpath"><bdi>' + esc(f.path) + "</bdi></span>" + stat(f) +
          '<button class="blame-btn" data-blame="' + esc(f.path) + '">blame</button></div>';
      });
    }
    section("Staged", staged, "staged");
    section("Changes", unstaged, "worktree");
    section("Untracked", untracked, "untracked");
    if (!total) h += '<div class="empty"><span class="big">✓</span>Working tree clean.</div>';
    el("files").innerHTML = h;

    el("files").querySelectorAll(".frow").forEach(function (row) {
      row.onclick = function (ev) {
        if (ev.target.dataset.blame) { openBlame(ev.target.dataset.blame); return; }
        el("files").querySelectorAll(".frow.sel").forEach(function (r) { r.classList.remove("sel"); });
        row.classList.add("sel");
        if (row.dataset.all) { post("diff", { scope: "head" }); return; }
        if (row.dataset.scope === "untracked") { post("openFile", { path: row.dataset.path }); return; }
        post("diff", { scope: row.dataset.scope, path: row.dataset.path });
      };
    });
  }

  function renderSummary(s) {
    state.summary = s;
    el("branch").textContent = s.branch || "(detached)";
    var ab = "";
    if (s.ahead) ab += '<span class="chip" title="ahead of upstream" style="color:var(--added)">↑' + s.ahead + "</span>";
    if (s.behind) ab += '<span class="chip" title="behind upstream" style="color:var(--removed)">↓' + s.behind + "</span>";
    if (s.stashes) ab += '<span class="chip" title="stashes"><svg viewBox="0 0 24 24"><polyline points="21 8 21 21 3 21 3 8"/><rect x="1" y="3" width="22" height="5"/><line x1="10" y1="12" x2="14" y2="12"/></svg>' + s.stashes + "</span>";
    el("ab").innerHTML = ab;
    paintFiles();
  }

  // ---- History view: lane graph -------------------------------------------
  var LANE_COLORS = ["#7aa2f7", "#4fbf78", "#e0af68", "#e06c75", "#bb9af7", "#7dcfff", "#f7768e"];
  var LW = 14, ROW = 30;

  function layoutLanes(log) {
    var lanes = [];
    return log.map(function (c) {
      var col = lanes.indexOf(c.hash);
      var merged = [];
      if (col === -1) { col = lanes.indexOf(null); if (col === -1) { col = lanes.length; } }
      for (var i = 0; i < lanes.length; i++) {
        if (i !== col && lanes[i] === c.hash) { merged.push(i); lanes[i] = null; }
      }
      var before = lanes.slice();
      lanes[col] = c.parents && c.parents.length ? c.parents[0] : null;
      for (var p = 1; p < (c.parents || []).length; p++) {
        if (lanes.indexOf(c.parents[p]) === -1) {
          var free = lanes.indexOf(null);
          if (free === -1) { lanes.push(c.parents[p]); } else { lanes[free] = c.parents[p]; }
        }
      }
      while (lanes.length && lanes[lanes.length - 1] === null) lanes.pop();
      return { col: col, merged: merged, before: before, after: lanes.slice(),
               isMerge: (c.parents || []).length > 1,
               width: Math.max(before.length, lanes.length, col + 1) };
    });
  }

  function laneSVG(row) {
    var w = Math.max(row.width * LW, LW), mid = ROW / 2;
    var s = '<svg width="' + w + '" height="' + ROW + '" viewBox="0 0 ' + w + " " + ROW + '">';
    function x(i) { return i * LW + LW / 2; }
    function color(i) { return LANE_COLORS[i % LANE_COLORS.length]; }
    // smooth S-curve between two points (GitKraken-style continuous edges)
    function curve(x1, y1, x2, y2, col) {
      var my = (y1 + y2) / 2;
      return '<path d="M ' + x1 + " " + y1 + " C " + x1 + " " + my + ", " + x2 + " " + my + ", " + x2 + " " + y2 +
        '" fill="none" stroke="' + col + '" stroke-width="2.25" stroke-linecap="round"/>';
    }
    for (var i = 0; i < row.before.length; i++) {
      if (i === row.col || row.before[i] === null) continue;
      if (row.after[i] === row.before[i]) {
        s += curve(x(i), 0, x(i), ROW, color(i));
      }
    }
    if (row.after[row.col]) s += curve(x(row.col), mid, x(row.col), ROW, color(row.col));
    s += curve(x(row.col), 0, x(row.col), mid, color(row.col));
    row.merged.forEach(function (i) {
      s += curve(x(i), 0, x(row.col), mid, color(i));
    });
    for (var p = 1; p < row.after.length; p++) {
      if (row.before[p] === null && row.after[p] !== null && row.after[p] !== row.before[p]) {
        s += curve(x(row.col), mid, x(p), ROW, color(p));
      }
    }
    if (row.isMerge) {
      s += '<circle cx="' + x(row.col) + '" cy="' + mid + '" r="4.5" fill="var(--bg, #0d0e12)" stroke="' + color(row.col) + '" stroke-width="2.25"/>';
    } else {
      s += '<circle cx="' + x(row.col) + '" cy="' + mid + '" r="4" fill="' + color(row.col) + '"/>';
    }
    return s + "</svg>";
  }

  function paintLog() {
    var rows = layoutLanes(state.log);
    var q = state.logFilter;
    var h = "";
    // WIP row: uncommitted changes ride the top of the graph (click -> Changes view)
    var wip = state.summary ? (state.summary.files || []).length : 0;
    if (wip && !q) {
      var wcol = rows.length ? rows[0].col : 0;
      var wx = wcol * LW + LW / 2, ww = Math.max((rows.length ? rows[0].width : 1) * LW, LW);
      h += '<div class="crow wip" id="wip-row">' +
        '<svg width="' + ww + '" height="30" viewBox="0 0 ' + ww + ' 30">' +
        '<line x1="' + wx + '" y1="15" x2="' + wx + '" y2="30" stroke="' + LANE_COLORS[wcol % LANE_COLORS.length] + '" stroke-width="2.25" stroke-dasharray="3 3"/>' +
        '<circle cx="' + wx + '" cy="15" r="4.5" fill="none" stroke="' + LANE_COLORS[wcol % LANE_COLORS.length] + '" stroke-width="2" stroke-dasharray="2.5 2.5"/></svg>' +
        '<div class="csub"><span class="txt">' + wip + ' uncommitted change' + (wip === 1 ? '' : 's') + ' — working tree</span></div>' +
        '<span class="ctime">now</span></div>';
    }
    state.log.forEach(function (c, i) {
      if (q && (c.subject + " " + c.author + " " + c.hash).toLowerCase().indexOf(q) === -1) return;
      var refs = (c.refs || []).map(refPill).join("");
      h += '<div class="crow' + (state.selCommit === c.hash ? " sel" : "") + '" data-hash="' + c.hash + '">' +
        laneSVG(rows[i]) +
        '<div class="csub">' + refs + '<span class="txt" title="' + esc(c.subject) + '">' + esc(c.subject) + "</span></div>" +
        avatar(c.author) +
        '<span class="chash">' + c.hash.slice(0, 7) + "</span>" +
        '<span class="ctime">' + rel(c.at) + "</span></div>";
    });
    if (state.log.length >= 100) h += '<button id="more-log">Load more…</button>';
    el("commits").innerHTML = h || '<div class="empty">No commits' + (q ? " match" : "") + ".</div>";
    var wipRow = el("wip-row");
    if (wipRow) wipRow.onclick = function () { showView("changes"); };

    // lineage maps for hover-highlight (ancestors ∪ descendants of the hovered commit)
    var parentsOf = {}, childrenOf = {};
    state.log.forEach(function (c) {
      parentsOf[c.hash] = c.parents || [];
      (c.parents || []).forEach(function (p) { (childrenOf[p] = childrenOf[p] || []).push(c.hash); });
    });
    function lineage(h) {
      var set = {}, stack = [h];
      while (stack.length) { var x = stack.pop(); if (set[x]) continue; set[x] = 1; (parentsOf[x] || []).forEach(function (p) { stack.push(p); }); }
      stack = [h];
      while (stack.length) { var y = stack.pop(); if (y !== h && set[y]) continue; set[y] = 1; (childrenOf[y] || []).forEach(function (cc) { stack.push(cc); }); }
      return set;
    }
    var allRows = el("commits").querySelectorAll(".crow:not(.wip)");
    allRows.forEach(function (row) {
      row.onmouseenter = function () {
        var set = lineage(row.dataset.hash);
        allRows.forEach(function (r) { r.classList.toggle("dim", !set[r.dataset.hash]); });
      };
      row.onmouseleave = function () {
        allRows.forEach(function (r) { r.classList.remove("dim"); });
      };
      row.onclick = function (ev) {
        // ⌘/ctrl-click with a selection = COMPARE the two commits
        if ((ev.metaKey || ev.ctrlKey) && state.selCommit && state.selCommit !== row.dataset.hash) {
          state.compareWith = row.dataset.hash;
          allRows.forEach(function (r) { r.classList.remove("selb"); });
          row.classList.add("selb");
          var a = state.selCommit, b = state.compareWith;
          // diff from the OLDER to the NEWER so + means "added since"
          var byHash = {}; state.log.forEach(function (c) { byHash[c.hash] = c; });
          if (byHash[a] && byHash[b] && byHash[a].at < byHash[b].at) { var t = a; a = b; b = t; }
          overlay("comparing…");
          post("compare", { a: a, b: b });
          return;
        }
        state.compareWith = null;
        el("commits").querySelectorAll(".crow.sel, .crow.selb").forEach(function (r) { r.classList.remove("sel", "selb"); });
        row.classList.add("sel");
        state.selCommit = row.dataset.hash;
        post("commit", { hash: row.dataset.hash });
      };
    });
    var more = el("more-log");
    if (more) more.onclick = function () { post("moreLog", { skip: state.log.length, all: state.allBranches }); };
  }

  function renderLog(log, append) {
    state.log = append ? state.log.concat(log) : log;
    paintLog();
  }

  function renderRangeDiff(a, b, text) {
    var byHash = {}; state.log.forEach(function (c) { byHash[c.hash] = c; });
    var ca = byHash[a], cb = byHash[b];
    function side(c, h) {
      if (!c) return '<span class="h">' + h.slice(0, 10) + "</span>";
      return avatar(c.author) + '<span class="h">' + h.slice(0, 10) + '</span><span class="txt" style="overflow:hidden;text-overflow:ellipsis">' + esc(c.subject) + "</span>";
    }
    var target = el("history-diff");
    target.innerHTML = '<div class="commit-card"><div class="s">Compare</div>' +
      '<div class="meta" style="flex-wrap:nowrap;min-width:0">' + side(cb, b) +
      '<span style="color:var(--fg3);flex-shrink:0">→</span>' + side(ca, a) + "</div></div>" +
      '<div id="commit-diff-host"></div>';
    renderDiff("commit-diff-host", text, { title: b.slice(0, 8) + "…" + a.slice(0, 8), scope: "range-inner" });
  }

  function renderCommitDiff(hash, text) {
    var c = null;
    for (var i = 0; i < state.log.length; i++) if (state.log[i].hash === hash) { c = state.log[i]; break; }
    var target = el("history-diff");
    var head = "";
    if (c) {
      head = '<div class="commit-card"><div class="s">' + esc(c.subject) + "</div>" +
        '<div class="meta">' + avatar(c.author) + "<span>" + esc(c.author) + "</span>" +
        '<span class="h" title="click to copy" onclick="navigator.clipboard&&navigator.clipboard.writeText(\'' + c.hash + '\')">' + c.hash.slice(0, 12) + "</span>" +
        "<span>" + new Date(c.at * 1000).toLocaleString() + " · " + rel(c.at) + " ago</span>" +
        ((c.refs || []).map(refPill).join("")) + "</div></div>";
    }
    target.innerHTML = head + '<div id="commit-diff-host"></div>';
    renderDiff("commit-diff-host", text, { title: hash.slice(0, 8), scope: "commit-inner" });
  }

  // ---- Blame view ----------------------------------------------------------
  function openBlame(path) {
    state.blameFrom = state.view;
    post("blame", { path: path });
  }
  function renderBlame(data, path) {
    el("blame-path").textContent = path;
    var lines = data.lines || [];
    var times = {};
    lines.forEach(function (l) { times[l.hash] = l.at; });
    var sorted = Object.keys(times).map(function (k) { return times[k]; }).sort(function (a, b) { return a - b; });
    function heat(at) {
      if (sorted.length < 2) return 0;
      var idx = sorted.indexOf(at);
      return 0.04 + 0.16 * (idx / (sorted.length - 1));
    }
    var gutter = "", code = "";
    var prev = null;
    lines.forEach(function (l) {
      var first = l.hash !== prev;
      prev = l.hash;
      var uncommitted = /^0+$/.test(l.hash);
      gutter += '<div class="bg-row" data-hash="' + l.hash + '" style="background:rgba(122,162,247,' + (uncommitted ? 0 : heat(l.at)) + ')" title="' +
        esc(l.summary || "") + " — " + (l.at ? new Date(l.at * 1000).toLocaleString() : "") + '">' +
        (first ? '<span class="h">' + (uncommitted ? "·······" : l.short.slice(0, 7)) + '</span><span class="a">' + esc(uncommitted ? "uncommitted" : l.author) + '</span><span class="t">' + rel(l.at) + "</span>"
               : '<span class="h" style="visibility:hidden">' + l.short.slice(0, 7) + "</span>") +
        "</div>";
      code += esc(l.text) + "\n";
    });
    el("blame-body").innerHTML = '<div class="blame-wrap"><div class="blame-gutter">' + gutter +
      '</div><div class="blame-code"><pre><code>' + code + "</code></pre></div></div>";
    var codeEl = el("blame-body").querySelector("code");
    try { hljs.highlightElement(codeEl); } catch (e) { /* plain text is fine */ }
    el("blame-body").querySelectorAll(".bg-row").forEach(function (r) {
      r.ondblclick = function () {
        if (/^0+$/.test(r.dataset.hash)) return;
        showView("history");
        state.selCommit = r.dataset.hash;
        post("commit", { hash: r.dataset.hash });
        if (!state.log.length) post("moreLog", { skip: 0 });
      };
    });
    showView("blame");
  }

  // ---- overlay -------------------------------------------------------------
  function overlay(msg) {
    el("overlay").style.display = msg ? "flex" : "none";
    el("overlay-msg").textContent = msg || "";
  }

  // ---- bridge --------------------------------------------------------------
  window.UTGit = {
    setTheme: function (t) {
      var r = document.documentElement.style;
      if (t.bg) r.setProperty("--bg", t.bg);
      if (t.surface) r.setProperty("--surface", t.surface);
      if (t.border) r.setProperty("--border", t.border);
      if (t.fg) r.setProperty("--fg", t.fg);
      if (t.fg2) r.setProperty("--fg2", t.fg2);
      if (t.accent) r.setProperty("--accent", t.accent);
    },
    setFontSize: function (px) { document.documentElement.style.setProperty("--fs", px + "px"); },
    setSummary: function (s) { overlay(null); renderSummary(s); },
    setLog: function (log, append) { overlay(null); renderLog(log || [], !!append); },
    setDiff: function (text, meta) {
      overlay(null);
      if (meta && meta.scope === "commit") { renderCommitDiff(meta.hash, text); return; }
      if (meta && meta.scope === "range") { renderRangeDiff(meta.hash, meta.hash2, text); return; }
      // the head diff doubles as the source of per-file stats for the sidebar
      if (meta && meta.scope === "head") {
        state.headStats = {};
        diffStats(text).forEach(function (f) { state.headStats[f.path] = f; });
        paintFiles();
        var all = el("files").querySelector('.frow[data-all="1"]');
        if (all && !el("files").querySelector(".frow.sel")) all.classList.add("sel");
      }
      renderDiff("changes-diff", text, meta || {});
    },
    setBlame: function (data, path) { overlay(null); renderBlame(data, path); },
    setLoading: function (msg) {
      var skel = '<div class="skel"></div><div class="skel w80"></div><div class="skel w60"></div><div class="skel"></div><div class="skel w40"></div>';
      if (state.view === "history" && !el("commits").children.length) { el("commits").innerHTML = skel; return; }
      if (state.view === "changes" && !el("files").children.length) { el("files").innerHTML = skel; return; }
      overlay(msg || "loading…");
    },
    setRepo: function (name) { el("repo").textContent = name || ""; },
    setError: function (msg) { overlay(msg || "error"); },
    showView: showView
  };

  post("ready");
})();
