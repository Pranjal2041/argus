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
    var cls = "ref", label = r, branchy = "";
    if (/^tag: /.test(r)) { cls += " tag"; label = r.slice(5); }
    else if (/^[^/]+\/.+/.test(r)) { cls += " remote"; branchy = "1"; }
    else { branchy = "1"; }
    return '<span class="' + cls + '"' + (branchy ? ' data-branch="' + esc(r) + '"' : "") +
      ' title="' + esc(r) + (branchy ? ' — click to select the whole branch' : "") + '">' + esc(label) + "</span>";
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
    prs: null,            // null = not fetched; [] = fetched empty; array = PRs
    prErr: null,
    prFilter: "",
    prState: "open",
    selPR: null,
    prInsight: null,      // {num, headSha} when a PR is the insight scope
    rangeSel: null,       // {hashes, newest, oldest, base, metas, label?} — range/branch/single selection
    insight: null,        // {level, status: running|done|error, text, cost, cached, t0, question?}
    insightChat: [],      // asked questions + answers for the current selection
    insightMem: {},       // key(level+newest+n) -> payload, to re-show instantly
    blameFrom: "changes"
  };

  // ---- view switching ------------------------------------------------------
  function showView(name) {
    state.view = name;
    ["changes", "history", "blame", "prs"].forEach(function (v) {
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
    el("tab-prs").classList.toggle("active", name === "prs");
  }
  el("tab-changes").onclick = function () { showView("changes"); };
  el("tab-history").onclick = function () {
    showView("history");
    if (!state.log.length) post("moreLog", { skip: 0, all: state.allBranches });
  };
  el("tab-prs").onclick = function () {
    showView("prs");
    if (!state.prs) post("prs", { state: state.prState });   // fetch once; Refresh re-fetches
  };
  el("pr-state").onchange = function () {
    state.prState = this.value;
    state.prs = null; state.selPR = null;
    el("pr-detail").innerHTML = '<div class="empty"><span class="big">⇅</span>Select a pull request</div>';
    post("prs", { state: state.prState });
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
  el("pr-filter").oninput = function () { state.prFilter = this.value.toLowerCase(); paintPRs(); };

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
      row.querySelectorAll(".ref[data-branch]").forEach(function (pill) {
        pill.onclick = function (ev) {
          ev.stopPropagation();
          selectBranch(row.dataset.hash, pill.dataset.branch, allRows);
        };
      });
      row.onclick = function (ev) {
        // SHIFT-click with a selection = select the contiguous RANGE (for insights)
        if (ev.shiftKey && state.selCommit && state.selCommit !== row.dataset.hash) {
          ev.preventDefault();
          var order = state.log.map(function (c) { return c.hash; });
          var i1 = order.indexOf(state.selCommit), i2 = order.indexOf(row.dataset.hash);
          if (i1 !== -1 && i2 !== -1) {
            var lo = Math.min(i1, i2), hi = Math.max(i1, i2);
            var range = state.log.slice(lo, hi + 1);   // newest → oldest
            state.prInsight = null; state.rangeSel = {
              hashes: range.map(function (c) { return c.hash; }),
              newest: range[0].hash,
              oldest: range[range.length - 1].hash,
              base: (range[range.length - 1].parents || [])[0] || null,
              metas: range.map(function (c) { return { h: c.hash, s: c.subject, a: c.author, at: c.at }; })
            };
            state.compareWith = null;
            state.insight = null;
            state.insightChat = [];
            allRows.forEach(function (r) {
              r.classList.toggle("rsel", state.rangeSel.hashes.indexOf(r.dataset.hash) !== -1);
              r.classList.remove("selb");
            });
            overlay("collecting the range…");
            post("compare", { a: state.rangeSel.newest, b: state.rangeSel.base || state.rangeSel.oldest });
          }
          return;
        }
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
        state.rangeSel = null;
        state.insight = null;
        state.insightChat = [];
        el("commits").querySelectorAll(".crow.sel, .crow.selb, .crow.rsel").forEach(function (r) { r.classList.remove("sel", "selb", "rsel"); });
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


  // ---- agent insights (range selection) ------------------------------------
  // Insight scope is either a commit RANGE selection or a PR. Both funnel through
  // the same bar/chat; the key distinguishes them and is echoed by Swift so a
  // result routes only to its own scope.
  function insightKey() {
    if (state.prInsight) return "pr:" + state.prInsight.num + ":" + (state.prInsight.headSha || "");
    var rs = state.rangeSel;
    return rs ? rs.newest + ":" + rs.hashes.length : "";
  }

  // Click a branch PILL → select that branch's whole loaded history (the tip's
  // ancestors within the log), for insights/questions about the branch as a whole.
  function selectBranch(tipHash, refName, allRows) {
    var parentsOf = {};
    state.log.forEach(function (c) { parentsOf[c.hash] = c.parents || []; });
    var inLog = {};
    state.log.forEach(function (c) { inLog[c.hash] = true; });
    var set = {}, stack = [tipHash];
    while (stack.length) {
      var x = stack.pop();
      if (set[x] || !inLog[x]) continue;
      set[x] = 1;
      (parentsOf[x] || []).forEach(function (p) { stack.push(p); });
    }
    var members = state.log.filter(function (c) { return set[c.hash]; });
    if (!members.length) return;
    var oldest = members[members.length - 1];
    state.prInsight = null; state.rangeSel = {
      hashes: members.map(function (c) { return c.hash; }),
      newest: tipHash,
      oldest: oldest.hash,
      base: (oldest.parents || [])[0] || null,
      metas: members.map(function (c) { return { h: c.hash, s: c.subject, a: c.author, at: c.at }; }),
      label: "branch " + refName + " — " + members.length + " commits"
    };
    state.compareWith = null;
    state.insight = null;
    state.insightChat = [];
    state.selCommit = tipHash;
    (allRows || []).forEach(function (r) {
      r.classList.toggle("rsel", !!set[r.dataset.hash]);
      r.classList.remove("selb");
    });
    overlay("collecting the branch…");
    post("compare", { a: state.rangeSel.newest, b: state.rangeSel.base || state.rangeSel.oldest });
  }

  // The insight bar + ask box, shared by range, branch, and single-commit views.
  function insightBarHTML() {
    return '<div id="insightbar">' +
      '<span class="it">✦ Agent insights</span>' +
      '<button class="ilvl" data-l="brief">Brief</button>' +
      '<button class="ilvl" data-l="medium">Medium</button>' +
      '<button class="ilvl" data-l="detailed">Detailed</button>' +
      '<span class="ihint">on demand · cached forever</span>' +
      "</div>" +
      '<div id="insightask">' +
      '<input id="iq" placeholder="Ask anything about this selection…">' +
      '<button id="iask">Ask</button></div>' +
      '<div id="insightbody"></div><div id="insightchat"></div>';
  }
  function wireInsightBar(target) {
    target.querySelectorAll(".ilvl").forEach(function (b) {
      b.onclick = function () { requestInsight(b.dataset.l); };
    });
    var iq = el("iq"), btn = el("iask");
    function fire() {
      var q = (iq.value || "").trim();
      if (q) { requestAsk(q); iq.value = ""; }
    }
    btn.onclick = fire;
    iq.onkeydown = function (ev) { if (ev.key === "Enter") fire(); };
  }

  function renderRangeView(diffText) {
    var rs = state.rangeSel;
    if (!rs) return;
    var byHash = {}; state.log.forEach(function (c) { byHash[c.hash] = c; });
    var newest = byHash[rs.newest], oldest = byHash[rs.oldest];
    var target = el("history-diff");
    var title = rs.label || (rs.hashes.length + " commits selected");
    target.innerHTML =
      '<div class="commit-card"><div class="s">' + esc(title) + "</div>" +
      '<div class="range-ends">' +
      (newest ? avatar(newest.author) + '<span class="txt">' + esc(newest.subject) + "</span>" : "") +
      '<span class="dots">⋯</span>' +
      (oldest ? avatar(oldest.author) + '<span class="txt">' + esc(oldest.subject) + "</span>" : "") +
      "</div></div>" +
      insightBarHTML() +
      '<div id="range-diff"></div>';
    wireInsightBar(target);
    renderDiff("range-diff", diffText, { title: rs.hashes.length + " commits" });
    paintInsight();
  }

  function selMetaLines() {
    return state.rangeSel.metas.map(function (m) {
      return m.h.slice(0, 10) + "  " + m.a + "  " + new Date(m.at * 1000).toISOString().slice(0, 16) + "  " + m.s;
    }).join("\n");
  }

  // Build the insight request for the current scope (range or PR).
  function insightReq(extra) {
    var key = insightKey();
    if (state.prInsight) {
      return Object.assign({ key: key, prNum: state.prInsight.num }, extra);
    }
    var rs = state.rangeSel;
    return Object.assign({ key: key, hashes: rs.hashes, newest: rs.newest, base: rs.base, metaLines: selMetaLines() }, extra);
  }

  function requestInsight(level) {
    if (!state.prInsight && !state.rangeSel) return;
    var mem = state.insightMem[insightKey() + "|" + level];
    if (mem) { state.insight = mem; paintInsight(); return; }
    if (state.insight && state.insight.status === "running") return;
    state.insight = { level: level, status: "running", t0: Date.now() };
    paintInsight();
    post("insight", insightReq({ level: level }));
  }

  // Free-form question about the current scope (commit, range, branch, or PR).
  // Each answer is cached like a level.
  function requestAsk(q) {
    if (!state.prInsight && !state.rangeSel) return;
    if (state.insight && state.insight.status === "running") return;
    state.insight = { level: "ask", question: q, status: "running", t0: Date.now() };
    paintInsight();
    post("insight", insightReq({ level: "ask", question: q }));
  }

  var insightTick = null;
  function paintInsight() {
    var box = el("insightbody");
    if (!box) return;
    var ins = state.insight;
    document.querySelectorAll(".ilvl").forEach(function (b) {
      b.classList.toggle("on", !!ins && ins.level === b.dataset.l);
    });
    if (insightTick) { clearInterval(insightTick); insightTick = null; }
    paintChat();
    if (!ins) { box.innerHTML = ""; return; }
    if (ins.status === "running") {
      var verb = ins.level === "ask" ? "answering" : "reading the diff";
      var paint = function () {
        var secs = Math.floor((Date.now() - ins.t0) / 1000);
        var node = el("insightbody");
        if (node) node.innerHTML = '<div class="ithinking">✦ sonnet is ' + verb + '… ' + secs + "s</div>";
      };
      paint();
      insightTick = setInterval(paint, 1000);
      return;
    }
    if (ins.status === "error") {
      box.innerHTML = '<div class="ierror">insight failed: ' + esc(ins.error || "unknown") +
        ' <button class="iretry">retry</button></div>';
      var r = box.querySelector(".iretry");
      if (r) r.onclick = function () { state.insight = null; requestInsight(ins.level); };
      return;
    }
    box.innerHTML = '<div class="ibody">' + mdlite(ins.text || "") + "</div>" +
      '<div class="ifoot">' + (ins.cached ? "from cache · free" : "sonnet · $" + (ins.cost || 0).toFixed(3)) + "</div>";
  }

  function paintChat() {
    var c = el("insightchat");
    if (!c) return;
    c.innerHTML = state.insightChat.map(function (m) {
      return '<div class="ichat-q">' + esc(m.q) + "</div>" +
        (m.error ? '<div class="ierror">' + esc(m.error) + "</div>"
                 : '<div class="ibody">' + mdlite(m.text || "") + "</div>" +
                   '<div class="ifoot">' + (m.cached ? "from cache · free" : "sonnet · $" + (m.cost || 0).toFixed(3)) + "</div>");
    }).join("");
  }

  // minimal markdown: headings, bullets, bold, code — enough for insight prose
  function mdlite(t) {
    var out = esc(t)
      .replace(/\*\*([^*]+)\*\*/g, "<b>$1</b>")
      .replace(/`([^`]+)`/g, "<code>$1</code>");
    return out.split("\n").map(function (l) {
      if (/^#{1,4}\s+/.test(l)) return '<div class="ih">' + l.replace(/^#+\s+/, "") + "</div>";
      if (/^\s*[-•*]\s+/.test(l)) return '<div class="ib">' + l.replace(/^\s*[-•*]\s+/, "") + "</div>";
      return l.trim() ? '<div class="ip">' + l + "</div>" : "";
    }).join("");
  }

  function renderRangeDiff(a, b, text) {
    if (state.rangeSel && a === state.rangeSel.newest) { renderRangeView(text); return; }
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
    var bar = "";
    if (c) {
      // Insights for a SINGLE commit too: selection = just this commit.
      state.prInsight = null; state.rangeSel = {
        hashes: [c.hash], newest: c.hash, oldest: c.hash,
        base: (c.parents || [])[0] || null,
        metas: [{ h: c.hash, s: c.subject, a: c.author, at: c.at }],
        label: "commit " + c.hash.slice(0, 10)
      };
      bar = insightBarHTML();
    }
    target.innerHTML = head + bar + '<div id="commit-diff-host"></div>';
    if (c) { wireInsightBar(target); paintInsight(); }
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
  // A loading/error overlay must never be a prison: click dismisses.
  el("overlay").addEventListener("click", function () { overlay(null); });

  // ---- Pull Requests -------------------------------------------------------
  function prStateBadge(pr) {
    if (pr.isDraft) return '<span class="pr-badge draft">draft</span>';
    var d = pr.reviewDecision;
    if (d === "APPROVED") return '<span class="pr-badge ok">approved</span>';
    if (d === "CHANGES_REQUESTED") return '<span class="pr-badge warn">changes</span>';
    if (d === "REVIEW_REQUIRED") return '<span class="pr-badge">review</span>';
    return "";
  }
  function checksDot(pr) {
    var roll = pr.statusCheckRollup || [];
    if (!roll.length) return "";
    var bad = 0, pending = 0, ok = 0;
    roll.forEach(function (c) {
      var s = (c.conclusion || c.state || c.status || "").toUpperCase();
      if (s === "FAILURE" || s === "ERROR" || s === "CANCELLED" || s === "TIMED_OUT") bad++;
      else if (s === "SUCCESS" || s === "NEUTRAL" || s === "SKIPPED") ok++;
      else pending++;
    });
    var cls = bad ? "bad" : (pending ? "pending" : "ok");
    var title = ok + " passed" + (bad ? ", " + bad + " failed" : "") + (pending ? ", " + pending + " pending" : "");
    return '<span class="pr-checks ' + cls + '" title="' + title + '">●</span>';
  }
  function paintPRs() {
    var box = el("pr-list");
    if (state.prErr) {
      var e = state.prErr;
      var hint = e.needsAuth ? "Run <code>gh auth login</code> on this machine."
        : e.noGH ? "Install GitHub CLI (<code>gh</code>) on this machine."
        : e.notRepo ? "This folder has no GitHub remote." : "";
      box.innerHTML = '<div class="empty" style="padding:32px 18px"><span class="big">⇅</span>' +
        esc(e.error) + (hint ? '<div class="hint">' + hint + "</div>" : "") + "</div>";
      el("pr-detail").innerHTML = '<div class="empty"><span class="big">⇅</span>Pull requests unavailable</div>';
      return;
    }
    var prs = state.prs || [];
    var f = state.prFilter;
    if (f) prs = prs.filter(function (p) {
      return (p.title || "").toLowerCase().indexOf(f) >= 0 ||
             ("#" + p.number).indexOf(f) >= 0 ||
             ((p.author && p.author.login) || "").toLowerCase().indexOf(f) >= 0 ||
             (p.headRefName || "").toLowerCase().indexOf(f) >= 0;
    });
    if (!prs.length) {
      box.innerHTML = '<div class="empty" style="padding:32px 18px"><span class="big">✓</span>No open pull requests</div>';
      return;
    }
    box.innerHTML = prs.map(function (p) {
      return '<div class="prrow' + (state.selPR === p.number ? " sel" : "") + '" data-num="' + p.number + '">' +
        '<div class="pr-top">' + avatar((p.author && p.author.login) || "?") +
        '<span class="pr-title">' + esc(p.title) + "</span>" + checksDot(p) + "</div>" +
        '<div class="pr-sub"><span class="pr-num">#' + p.number + "</span>" +
        '<span class="pr-branch">' + esc(p.headRefName) + " → " + esc(p.baseRefName) + "</span>" +
        prStateBadge(p) +
        '<span class="pr-stat"><span class="p">+' + (p.additions || 0) + '</span><span class="m">−' + (p.deletions || 0) + "</span></span>" +
        "</div></div>";
    }).join("");
    box.querySelectorAll(".prrow").forEach(function (row) {
      row.onclick = function () {
        state.selPR = parseInt(row.dataset.num, 10);
        paintPRs();
        el("pr-detail").innerHTML = '<div class="empty"><span class="big">⇅</span>Loading PR #' + state.selPR + "…</div>";
        post("pr", { num: state.selPR });
      };
    });
  }
  function relTime(iso) { try { return rel(Math.floor(new Date(iso).getTime() / 1000)); } catch (e) { return ""; } }
  function renderPRDetail(pr, diffText) {
    var t = el("pr-detail");
    var roll = pr.statusCheckRollup || [];
    var checksHTML = roll.length ? '<div class="pr-checkrow">' + roll.map(function (c) {
      var s = (c.conclusion || c.state || c.status || "").toUpperCase();
      var cls = (s === "SUCCESS" || s === "NEUTRAL" || s === "SKIPPED") ? "ok"
        : (s === "FAILURE" || s === "ERROR" || s === "CANCELLED" || s === "TIMED_OUT") ? "bad" : "pending";
      return '<span class="pr-check ' + cls + '" title="' + esc(s) + '">' + esc(c.name || c.context || "check") + "</span>";
    }).join("") + "</div>" : "";
    var reviews = (pr.reviews || []).filter(function (r) { return r.state && r.state !== "COMMENTED" || (r.body && r.body.trim()); });
    var revHTML = reviews.length ? '<div class="pr-reviews">' + reviews.map(function (r) {
      return '<div class="pr-rev"><b>' + esc((r.author && r.author.login) || "?") + "</b> " +
        '<span class="pr-badge ' + (r.state === "APPROVED" ? "ok" : r.state === "CHANGES_REQUESTED" ? "warn" : "") + '">' + esc((r.state || "").toLowerCase().replace("_", " ")) + "</span>" +
        (r.body ? '<div class="pr-revbody">' + esc(r.body) + "</div>" : "") + "</div>";
    }).join("") + "</div>" : "";
    t.innerHTML =
      '<div class="commit-card"><div class="s">' + esc(pr.title) + ' <span class="pr-num">#' + pr.number + "</span></div>" +
      '<div class="meta">' + avatar((pr.author && pr.author.login) || "?") + "<span>" + esc((pr.author && pr.author.login) || "") + "</span>" +
      "<span>" + esc(pr.headRefName) + " → " + esc(pr.baseRefName) + "</span>" +
      "<span>" + relTime(pr.updatedAt) + " ago</span>" + prStateBadge(pr) + "</div>" +
      (pr.body ? '<div class="pr-body">' + esc(pr.body).slice(0, 4000) + "</div>" : "") +
      checksHTML + revHTML +
      '<div class="pr-actions">' +
      '<button class="pr-act ok" data-act="APPROVE">Approve</button>' +
      '<button class="pr-act warn" data-act="REQUEST_CHANGES">Request changes</button>' +
      '<button class="pr-act" data-act="COMMENT">Comment</button>' +
      '<button class="pr-act" data-act="MERGE">Merge…</button>' +
      '<a class="pr-act link" href="' + esc(pr.url) + '" target="_blank">Open on GitHub ↗</a>' +
      "</div>" +
      '<div id="pr-actionbar"></div>' +
      "</div>" +
      insightBarHTML() +
      '<div id="pr-diff"></div>';
    // agent insights for the PR as a whole (same Brief/Medium/Detailed + ask)
    var headSha = pr.commits && pr.commits.length ? (pr.commits[pr.commits.length - 1].oid || "") : "";
    state.prInsight = { num: pr.number, headSha: headSha };
    state.rangeSel = null;
    state.insight = null;
    state.insightChat = [];
    wireInsightBar(t);
    paintInsight();
    renderDiff("pr-diff", diffText, { title: "PR #" + pr.number });
    t.querySelectorAll(".pr-act[data-act]").forEach(function (b) {
      b.onclick = function () { prAction(pr.number, b.dataset.act); };
    });
  }
  function prAction(num, act) {
    var bar = el("pr-actionbar");
    if (act === "APPROVE") {
      bar.innerHTML = '<span class="pr-confirm">Approve PR #' + num + '? <button class="go">Approve</button> <button class="no">Cancel</button> <input class="pr-note" placeholder="optional note"></span>';
      bar.querySelector(".go").onclick = function () { post("prReview", { num: num, event: "APPROVE", body: bar.querySelector(".pr-note").value }); bar.innerHTML = "submitting…"; };
    } else if (act === "REQUEST_CHANGES" || act === "COMMENT") {
      var label = act === "COMMENT" ? "Comment" : "Request changes";
      bar.innerHTML = '<div class="pr-form"><textarea class="pr-note" placeholder="Your ' + (act === "COMMENT" ? "comment" : "review") + '…"></textarea><div><button class="go">' + label + '</button> <button class="no">Cancel</button></div></div>';
      bar.querySelector(".go").onclick = function () {
        var body = bar.querySelector(".pr-note").value.trim();
        if (!body) { bar.querySelector(".pr-note").focus(); return; }
        post(act === "COMMENT" ? "prComment" : "prReview", { num: num, event: "REQUEST_CHANGES", body: body }); bar.innerHTML = "submitting…";
      };
    } else if (act === "MERGE") {
      bar.innerHTML = '<span class="pr-confirm">Merge PR #' + num + ' by <select class="pr-method"><option value="squash">squash</option><option value="merge">merge commit</option><option value="rebase">rebase</option></select> <button class="go">Merge</button> <button class="no">Cancel</button></span>';
      bar.querySelector(".go").onclick = function () { post("prMerge", { num: num, method: bar.querySelector(".pr-method").value }); bar.innerHTML = "merging…"; };
    }
    var no = bar.querySelector(".no"); if (no) no.onclick = function () { bar.innerHTML = ""; };
  }

  // ---- bridge --------------------------------------------------------------
  window.UTGit = {
    setPRs: function (payload) {
      overlay(null);
      if (payload && payload.error) { state.prErr = payload; state.prs = []; }
      else { state.prErr = null; state.prs = (payload && payload.prs) || []; }
      paintPRs();
    },
    setPRDetail: function (pr, diffText) {
      if (!pr || pr.number !== state.selPR) return;
      renderPRDetail(pr, diffText || "");
    },
    prActionResult: function (r) {
      var bar = el("pr-actionbar");
      if (r && r.error) { if (bar) bar.innerHTML = '<span class="pr-err">' + esc(r.error) + "</span>"; return; }
      if (bar) bar.innerHTML = '<span class="pr-ok">done ✓</span>';
      state.prs = null;                    // force a refresh of the list + detail
      post("prs", { state: state.prState });
      if (state.selPR) post("pr", { num: state.selPR });
    },
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
    setInsight: function (p) {
      // Route by the scope key Swift echoes back (range or PR) — a result only
      // applies if the user is still on that scope with that level running.
      var mine = p.key && p.key === insightKey() &&
                 state.insight && state.insight.level === p.level;
      if (p.level === "ask") {
        if (mine) {
          if (p.error) state.insightChat.push({ q: state.insight.question, error: p.error });
          else state.insightChat.push({ q: state.insight.question, text: p.text, cost: p.cost, cached: p.cached });
          state.insight = null;
          paintInsight();
        }
        return;
      }
      var done = p.error ? { level: p.level, status: "error", error: p.error }
                         : { level: p.level, status: "done", text: p.text, cost: p.cost, cached: p.cached };
      if (!p.error && p.key) state.insightMem[p.key + "|" + p.level] = done;
      if (mine) {
        state.insight = done;
        paintInsight();
      }
    },
    setLoading: function (msg) {
      var skel = '<div class="skel"></div><div class="skel w80"></div><div class="skel w60"></div><div class="skel"></div><div class="skel w40"></div>';
      if (state.view === "history" && !el("commits").children.length) { el("commits").innerHTML = skel; return; }
      if (state.view === "changes" && !el("files").children.length) { el("files").innerHTML = skel; return; }
      overlay(msg || "loading…");
    },
    setRepo: function (name) { el("repo").textContent = name || ""; },
    setError: function (msg) { overlay("⚠ " + (msg || "error") + " — click to dismiss"); },
    showView: showView
  };

  post("ready");
})();
