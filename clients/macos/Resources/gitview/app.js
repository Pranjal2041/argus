// Git panel logic. Swift injects data via window.UTGit.*; user intents go back via
// webkit.messageHandlers.ut.postMessage. The page renders three read-only views:
// Changes (status + diffs), History (lane graph + commit diffs), Blame.
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

  var state = {
    summary: null,
    log: [],
    sideBySide: true,
    view: "changes",
    selFile: null,       // {path, scope}
    selCommit: null,     // hash
    lastDiff: null,      // {text, meta}
    blameFrom: "changes" // view to return to from blame
  };

  // ---- view switching ------------------------------------------------------
  function showView(name) {
    state.view = name;
    ["changes", "history", "blame"].forEach(function (v) {
      el("view-" + v).style.display = v === name ? "flex" : "none";
    });
    el("tab-changes").classList.toggle("active", name === "changes");
    el("tab-history").classList.toggle("active", name === "history");
  }
  el("tab-changes").onclick = function () { showView("changes"); };
  el("tab-history").onclick = function () {
    showView("history");
    if (!state.log.length) post("moreLog", { skip: 0 });
  };
  el("btn-refresh").onclick = function () { post("refresh"); };
  el("btn-lazygit").onclick = function () { post("lazygit"); };
  el("btn-mode").onclick = function () {
    state.sideBySide = !state.sideBySide;
    if (state.lastDiff) renderDiff(state.lastDiff.target, state.lastDiff.text, state.lastDiff.meta);
  };
  el("blame-back").onclick = function () { showView(state.blameFrom); };

  // ---- diff rendering (diff2html) -----------------------------------------
  function renderDiff(targetID, text, meta) {
    state.lastDiff = { target: targetID, text: text, meta: meta };
    var target = el(targetID);
    if (!text || !text.trim()) {
      target.innerHTML = '<div class="empty">No changes' + (meta && meta.title ? " in " + esc(meta.title) : "") + '.</div>';
      return;
    }
    target.innerHTML = "";
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
    target.scrollTop = 0;
  }

  // ---- Changes view --------------------------------------------------------
  function renderSummary(s) {
    state.summary = s;
    el("branch").textContent = s.branch || "(detached)";
    var ab = [];
    if (s.ahead) ab.push("↑" + s.ahead);
    if (s.behind) ab.push("↓" + s.behind);
    if (s.upstream) ab.push(s.upstream);
    if (s.stashes) ab.push(s.stashes + " stash");
    el("ab").textContent = ab.join(" · ");

    var staged = [], unstaged = [], untracked = [];
    (s.files || []).forEach(function (f) {
      if (f.untracked) untracked.push(f);
      else {
        if (f.staged !== ".") staged.push(f);
        if (f.unstaged !== ".") unstaged.push(f);
      }
    });

    var h = "";
    var total = staged.length + unstaged.length + untracked.length;
    if (total) {
      h += '<div class="frow" data-all="1"><span class="badge R">Σ</span><span class="fpath"><bdi>All changes (' + total + ")</bdi></span></div>";
    }
    function section(title, files, scope) {
      if (!files.length) return;
      h += '<div class="sec">' + title + " (" + files.length + ")</div>";
      files.forEach(function (f) {
        var letter = scope === "staged" ? f.staged : scope === "worktree" ? f.unstaged : "?";
        var cls = letter === "?" ? "U" : letter;
        h += '<div class="frow" data-path="' + esc(f.path) + '" data-scope="' + scope + '">' +
          '<span class="badge ' + cls + '">' + (letter === "?" ? "U" : letter) + "</span>" +
          '<span class="fpath"><bdi>' + esc(f.path) + "</bdi></span>" +
          '<button class="blame-btn" data-blame="' + esc(f.path) + '">blame</button></div>';
      });
    }
    section("Staged", staged, "staged");
    section("Changes", unstaged, "worktree");
    section("Untracked", untracked, "untracked");
    if (!total) h += '<div class="empty">Working tree clean.</div>';
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

  // ---- History view: lane graph -------------------------------------------
  var LANE_COLORS = ["#7aa2f7", "#4fbf78", "#e0af68", "#e06c75", "#bb9af7", "#7dcfff", "#f7768e"];
  var LW = 12, ROW = 34; // lane width px, row height px

  // Assign each commit a column; track expected parent hashes per lane.
  function layoutLanes(log) {
    var lanes = []; // lanes[i] = hash we expect next in column i
    return log.map(function (c) {
      var col = lanes.indexOf(c.hash);
      var merged = [];
      if (col === -1) { col = lanes.indexOf(null); if (col === -1) { col = lanes.length; } }
      // all OTHER lanes waiting on this same hash merge into col
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
      return { col: col, merged: merged, before: before, after: lanes.slice(), width: Math.max(before.length, lanes.length, col + 1) };
    });
  }

  function laneSVG(row) {
    var w = row.width * LW, mid = ROW / 2;
    var s = '<svg width="' + w + '" height="' + ROW + '" viewBox="0 0 ' + w + " " + ROW + '">';
    function x(i) { return i * LW + LW / 2; }
    function color(i) { return LANE_COLORS[i % LANE_COLORS.length]; }
    // pass-through lanes: same hash pending before and after, not this commit's column
    for (var i = 0; i < row.before.length; i++) {
      if (i === row.col || row.before[i] === null) continue;
      if (row.after[i] === row.before[i]) {
        s += '<line x1="' + x(i) + '" y1="0" x2="' + x(i) + '" y2="' + ROW + '" stroke="' + color(i) + '" stroke-width="1.5"/>';
      }
    }
    // this column continues down when it still expects a parent
    if (row.after[row.col]) {
      s += '<line x1="' + x(row.col) + '" y1="' + mid + '" x2="' + x(row.col) + '" y2="' + ROW + '" stroke="' + color(row.col) + '" stroke-width="1.5"/>';
    }
    // line arriving from above into the dot
    s += '<line x1="' + x(row.col) + '" y1="0" x2="' + x(row.col) + '" y2="' + mid + '" stroke="' + color(row.col) + '" stroke-width="1.5"/>';
    // merged-in lanes curve into the dot
    row.merged.forEach(function (i) {
      s += '<path d="M ' + x(i) + " 0 Q " + x(i) + " " + mid + " " + x(row.col) + " " + mid + '" fill="none" stroke="' + color(i) + '" stroke-width="1.5"/>';
    });
    // second-parent branches curve out of the dot downward
    for (var p = 1; p < row.after.length; p++) {
      if (row.before[p] === null && row.after[p] !== null && row.after[p] !== row.before[p]) {
        s += '<path d="M ' + x(row.col) + " " + mid + " Q " + x(p) + " " + mid + " " + x(p) + " " + ROW + '" fill="none" stroke="' + color(p) + '" stroke-width="1.5"/>';
      }
    }
    s += '<circle cx="' + x(row.col) + '" cy="' + mid + '" r="3.4" fill="' + color(row.col) + '"/>';
    return s + "</svg>";
  }

  function renderLog(log, append) {
    if (append) state.log = state.log.concat(log);
    else state.log = log;
    var rows = layoutLanes(state.log);
    var h = "";
    state.log.forEach(function (c, i) {
      var refs = (c.refs || []).map(function (r) { return '<span class="ref">' + esc(r) + "</span>"; }).join("");
      h += '<div class="crow" data-hash="' + c.hash + '">' + laneSVG(rows[i]) +
        '<div class="cmeta"><div class="csub">' + refs + esc(c.subject) + "</div>" +
        '<div class="cwho">' + esc(c.author) + " · " + rel(c.at) + " · " + c.hash.slice(0, 8) + "</div></div></div>";
    });
    if (log.length >= 100 || (append && log.length)) {
      h += '<button id="more-log">Load more…</button>';
    }
    el("commits").innerHTML = h || '<div class="empty">No commits.</div>';
    el("commits").querySelectorAll(".crow").forEach(function (row) {
      row.onclick = function () {
        el("commits").querySelectorAll(".crow.sel").forEach(function (r) { r.classList.remove("sel"); });
        row.classList.add("sel");
        state.selCommit = row.dataset.hash;
        post("commit", { hash: row.dataset.hash });
      };
    });
    var more = el("more-log");
    if (more) more.onclick = function () { post("moreLog", { skip: state.log.length }); };
  }

  function renderCommitDiff(hash, text) {
    var c = null;
    for (var i = 0; i < state.log.length; i++) if (state.log[i].hash === hash) { c = state.log[i]; break; }
    var target = el("history-diff");
    var head = "";
    if (c) {
      head = '<div class="commit-head"><div class="s">' + esc(c.subject) + "</div>" +
        '<div class="h">' + c.hash + "</div>" +
        '<div class="cwho">' + esc(c.author) + " &lt;" + esc(c.email || "") + "&gt; · " + new Date(c.at * 1000).toLocaleString() +
        ((c.refs || []).length ? " · " + c.refs.map(function (r) { return '<span class="ref">' + esc(r) + "</span>"; }).join("") : "") +
        "</div></div>";
    }
    target.innerHTML = head + '<div id="commit-diff-host"></div>';
    renderDiff("commit-diff-host", text, { title: hash.slice(0, 8) });
  }

  // ---- Blame view ----------------------------------------------------------
  function openBlame(path) {
    state.blameFrom = state.view;
    post("blame", { path: path });
  }
  function renderBlame(data, path) {
    el("blame-path").textContent = path;
    var lines = data.lines || [];
    // age heat: rank commit times, newest = strongest tint
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
        (first ? '<span class="h">' + (uncommitted ? "·······" : l.short) + '</span><span class="a">' + esc(uncommitted ? "uncommitted" : l.author) + '</span><span class="t">' + rel(l.at) + "</span>"
               : '<span class="h" style="visibility:hidden">' + l.short + "</span>") +
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
      if (meta && meta.scope === "commit") renderCommitDiff(meta.hash, text);
      else renderDiff("changes-diff", text, meta || {});
    },
    setBlame: function (data, path) { overlay(null); renderBlame(data, path); },
    setLoading: function (msg) { overlay(msg || "loading…"); },
    setError: function (msg) { overlay(msg || "error"); },
    showView: showView
  };

  post("ready");
})();
