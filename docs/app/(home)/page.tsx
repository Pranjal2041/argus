'use client';

import { useEffect } from 'react';
import Link from 'next/link';
import {
  Workflow, Terminal, FileCode2, ListTodo, Cable, History, Palette,
  Check, ArrowRight, Cpu, Laptop, Smartphone, Monitor,
  Radar, LineChart, Notebook, StickyNote, RefreshCw, Coffee,
  ShieldCheck, Sparkles, TerminalSquare, GitBranch, BookOpen, FlaskConical,
} from 'lucide-react';

function Github({ size = 17 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="currentColor" aria-hidden>
      <path d="M12 .297c-6.63 0-12 5.373-12 12 0 5.303 3.438 9.8 8.205 11.385.6.113.82-.258.82-.577 0-.285-.01-1.04-.015-2.04-3.338.724-4.042-1.61-4.042-1.61C4.422 18.07 3.633 17.7 3.633 17.7c-1.087-.744.084-.729.084-.729 1.205.084 1.838 1.236 1.838 1.236 1.07 1.835 2.809 1.305 3.495.998.108-.776.417-1.305.76-1.605-2.665-.3-5.466-1.332-5.466-5.93 0-1.31.465-2.38 1.235-3.22-.135-.303-.54-1.523.105-3.176 0 0 1.005-.322 3.3 1.23.96-.267 1.98-.399 3-.405 1.02.006 2.04.138 3 .405 2.28-1.552 3.285-1.23 3.285-1.23.645 1.653.24 2.873.12 3.176.765.84 1.23 1.91 1.23 3.22 0 4.61-2.805 5.625-5.475 5.92.42.36.81 1.096.81 2.22 0 1.606-.015 2.896-.015 3.286 0 .315.21.69.825.57C20.565 22.092 24 17.592 24 12.297c0-6.627-5.373-12-12-12" />
    </svg>
  );
}

function EyeMark() {
  return (
    <span className="al-eye" aria-hidden>
      <svg viewBox="0 0 32 32" fill="none">
        <path d="M2 16C2 16 7 7 16 7s14 9 14 9-5 9-14 9S2 16 2 16Z" stroke="var(--accent)" strokeWidth="1.5" />
        <circle cx="16" cy="16" r="5.4" stroke="var(--accent-bright)" strokeWidth="1.3" />
        <circle className="pupil" cx="16" cy="16" r="2.5" fill="var(--accent)" />
      </svg>
    </span>
  );
}

const ccCards = [
  { name: 'caption-model', host: 'gpu-node-07', cls: 's-needs', pill: 'pill-needs', label: 'Needs you', line: <>Run failed — <b>CUDA OOM</b> at step 4,210. Waiting on a smaller batch.</> },
  { name: 'Lab / R12', host: 'vlm-gating · gpu-node-12', cls: 's-lab', pill: 'pill-lab', label: 'Approval', line: <>Full experiment is gated — inspect the exact code, params, and intent.</> },
  { name: 'rl-finetune', host: 'gpu-node-12', cls: 's-working', pill: 'pill-working', label: 'Working', line: <>Generating rollouts <b>6/8</b> · 9.7 tok/s, GPUs healthy.</> },
  { name: 'recsys-train', host: 'gpu-node-12', cls: 's-milestone', pill: 'pill-mile', label: 'Milestone', line: <>Eval harness + model server <b>up</b>.</> },
  { name: 'web-agent', host: 'this mac', cls: 's-working', pill: 'pill-working', label: 'Working', line: <>Probe executing — 2/7 trials, no action needed.</> },
  { name: 'game-sim', host: 'gpu-node-03', cls: 's-working', pill: 'pill-working', label: 'Working', line: <>Compiling shaders · 41% · monitor at :07.</> },
  { name: 'paper-figures', host: 'this mac', cls: 's-idle', pill: 'pill-idle', label: 'Idle', line: <>Finished the figure export.</> },
];

const meshNodes = [
  { x: 50, y: 3, c: 'var(--green)', label: 'this mac' },
  { x: 94, y: 36, c: 'var(--blue)', label: 'gpu-node-07' },
  { x: 78, y: 92, c: 'var(--amber)', label: 'gpu-node-12' },
  { x: 22, y: 92, c: 'var(--violet)', label: 'windows-pc' },
  { x: 6, y: 36, c: 'var(--orange)', label: 'phone' },
];

const tiles = [
  { icon: Workflow, t: 'Workflows', d: 'Saved recipes — machine, folder, commands — that spin up an agent in one click. Wildcards pick a free node.' },
  { icon: ListTodo, t: 'Todo Maps', d: 'Per-session checklists that outlive the session, so the plan is waiting when you reopen it.' },
  { icon: StickyNote, t: 'Notes Hub', d: 'Free-form, multiline notes grouped by time — a scratchpad not tied to any machine.' },
  { icon: Cable, t: 'Port forwards', d: 'Bind a local port and tunnel it over the tailnet to any remote broker — no ssh -L juggling.' },
  { icon: History, t: 'Session history', d: 'A durable record of every session that ran — survives downtime; a click opens or re-creates it.' },
  { icon: Palette, t: 'Themes', d: 'Recolor the whole app — chrome, terminals, and editor — with editor-grade schemes.' },
  { icon: RefreshCw, t: 'Cross-device sync', d: 'Workflows, todos, and notes follow you from Mac to phone, with your Mac as the sync host.' },
  { icon: Coffee, t: 'Awake while locked', d: 'Keep the Mac reachable behind a lock screen, so tmux, the broker, and your jobs keep running.' },
  { icon: BookOpen, t: 'Activity journal', d: 'A local, append-only record of what you saw, said, and did across Mac and phone, with a first-class in-app ledger.' },
  { icon: Sparkles, t: 'Argus Wrapped', d: 'A living story and dashboard of your fleet, rhythm, delegation, interventions, experiments, and shipped work — derived from the journal.' },
];

export default function HomePage() {
  useEffect(() => {
    const els = document.querySelectorAll('.al-reveal');
    // Fallback: if the observer is unavailable, just show everything.
    if (typeof IntersectionObserver === 'undefined') {
      els.forEach((el) => el.classList.add('in'));
      return;
    }
    const io = new IntersectionObserver(
      (entries) => entries.forEach((e) => { if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } }),
      { threshold: 0.12, rootMargin: '0px 0px -40px 0px' },
    );
    els.forEach((el) => io.observe(el));
    return () => io.disconnect();
  }, []);

  return (
    <main className="argus-landing">
      {/* nav */}
      <nav className="al-nav">
        <span className="al-brand"><EyeMark /><span>Argus</span></span>
        <span className="al-nav-links">
          <Link href="/docs">Documentation</Link>
          <a href="https://github.com/Pranjal2041/argus">GitHub</a>
          <Link href="/docs" className="al-nav-cta">Get started</Link>
        </span>
      </nav>

      {/* hero */}
      <section className="al-hero al-wrap">
        <span className="al-eyebrow">macOS · Android · Windows — Tailscale, peer-to-peer</span>
        <h1>One <span className="glow">watchful eye</span> over every coding agent.</h1>
        <p className="al-hero-sub">
          Reach every <code>claude</code> and <code>codex</code> session across your Mac, clusters,
          Windows boxes, and phone — and know which ones <b style={{ color: 'var(--ink)' }}>need you</b>.
          Gate research, review changes, and keep the record. One native app, no central server.
        </p>
        <div className="al-hero-cta">
          <Link href="/docs" className="al-btn al-btn-primary">Read the docs <ArrowRight size={17} /></Link>
          <a href="https://github.com/Pranjal2041/argus" className="al-btn al-btn-ghost"><Github size={17} /> Star on GitHub</a>
        </div>
        <div className="al-hero-meta">
          <span><b>0</b> central servers</span>
          <span><b>3</b> native platforms</span>
          <span>tmux · ConPTY · <b>WireGuard</b></span>
        </div>

        {/* command center mockup */}
        <div className="al-cc al-reveal">
          <div className="al-cc-bar">
            <span className="al-traffic"><i style={{ background: '#e0655c' }} /><i style={{ background: '#e0a36b' }} /><i style={{ background: '#5fd07a' }} /></span>
            <span className="al-cc-title">Command Center</span>
            <span className="al-cc-glance"><b>2</b> need you · 5 quiet</span>
          </div>
          <div className="al-cc-body">
            <div className="al-cc-sec">Across every machine</div>
            <div className="al-cc-grid">
              {ccCards.map((c, i) => (
                <div key={c.name} className={`al-card ${c.cls}`} style={{ animationDelay: `${0.15 + i * 0.09}s` }}>
                  <div className="al-card-top">
                    <span className="al-card-dot" />
                    <span className="al-card-id">
                      <span className="al-card-name">{c.name}</span>
                      <span className="al-card-host">{c.host}</span>
                    </span>
                    <span className={`al-card-pill ${c.pill}`}>{c.label}</span>
                  </div>
                  <div className="al-card-line">{c.line}</div>
                </div>
              ))}
            </div>
          </div>
        </div>
      </section>

      {/* premise band */}
      <section className="al-sec al-wrap" style={{ paddingTop: 40 }}>
        <div className="al-sec-head al-reveal">
          <span className="al-eyebrow">The premise</span>
          <h2>Agents run everywhere now. Your attention shouldn&apos;t have to.</h2>
          <p>
            A few on your laptop, a dozen on a cluster behind SLURM, one on a Windows box, maybe one
            on your phone. Argus collapses the whole sprawl into a single pane of glass — and reads
            each agent&apos;s screen passively to tell you, in plain English, which ones are
            <em> working</em>, <em>stuck</em>, or <em>waiting on you</em> — while Lab brings the
            experiment decisions that require your judgment into the same attention surface.
          </p>
        </div>
      </section>

      {/* marquee feature rows — the flagship craft */}
      <section className="al-wrap" style={{ paddingBottom: 40 }}>
        {/* 1. Command Center — the intelligence */}
        <div className="al-feat al-reveal">
          <div className="al-feat-copy">
            <span className="al-eyebrow">Command Center</span>
            <h3>Know which agents need you.</h3>
            <p>This is the heart of Argus. It reads each session&apos;s screen, passively, and writes a one-line, plain-English status — working, stuck at a prompt, hit an error, or done. The ones that need you float to the top.</p>
            <ul>
              <li><Check size={16} /> A real status, in plain English, not just a blinking cursor.</li>
              <li><Check size={16} /> A <b style={{ color: 'var(--ink)' }}>Needs you</b> band so a stuck run never hides in a sea of tabs.</li>
              <li><Check size={16} /> Agent-agnostic: the unit is the session, not claude or codex.</li>
            </ul>
          </div>
          <div className="al-feat-art">
            <div className="al-art-bar"><Radar size={13} /> Command Center · every machine</div>
            <div className="al-art-body">
              <div className="al-triage-sec"><b>● Needs you — 1</b></div>
              <div className="al-card s-needs" style={{ opacity: 1, animation: 'none' }}>
                <div className="al-card-top">
                  <span className="al-card-dot" />
                  <span className="al-card-id">
                    <span className="al-card-name">caption-model</span>
                    <span className="al-card-host">gpu-node-07</span>
                  </span>
                  <span className="al-card-pill pill-needs">Needs you</span>
                </div>
                <div className="al-card-line">Run failed — <b>CUDA OOM</b> at step 4,210.</div>
                <div className="al-insight"><Sparkles size={14} /><span>Out of memory on the 80&nbsp;GB card. Drop the per-device batch to 2 and it should fit.</span></div>
              </div>
              <div className="al-triage-sec" style={{ color: 'var(--ink-3)' }}>Working — 4 · Idle — 2</div>
              <div className="al-row"><span className="al-card-dot" style={{ background: 'var(--blue)', marginTop: 0 }} /><b style={{ fontFamily: 'var(--font-display)', fontSize: 13 }}>rl-finetune</b><span style={{ marginLeft: 'auto', fontFamily: 'var(--font-mono)', fontSize: 11, color: 'var(--ink-3)' }}>rollouts 6/8</span></div>
              <div className="al-row"><span className="al-card-dot" style={{ background: 'var(--blue)', marginTop: 0 }} /><b style={{ fontFamily: 'var(--font-display)', fontSize: 13 }}>web-agent</b><span style={{ marginLeft: 'auto', fontFamily: 'var(--font-mono)', fontSize: 11, color: 'var(--ink-3)' }}>probe 2/7</span></div>
            </div>
          </div>
        </div>

        {/* 2. Lab — the research protocol */}
        <div className="al-feat rev al-reveal">
          <div className="al-feat-copy">
            <span className="al-eyebrow">Argus Lab</span>
            <h3>Experiments with a record you can trust.</h3>
            <p>Agents wrap research in <span className="al-mono">ut lab run</span>. Argus captures the exact code, parameters, data fingerprints, environment, log, artifacts, and exit status — then gates expensive work on your approval.</p>
            <ul>
              <li><Check size={16} /> Approve the captured proposal, not an agent&apos;s recollection of it.</li>
              <li><Check size={16} /> Compare runs and inspect the recorded code, parameters, data integrity, environment, artifacts, and rich results.</li>
              <li><Check size={16} /> Publish human guidance by network, machine, project, or isolated experiment set.</li>
              <li><Check size={16} /> Turn on Unattended Mode to pre-authorize Lab gates while you are away, with every decision audited.</li>
              <li><Check size={16} /> The full approval and research hub is native on macOS and Android.</li>
            </ul>
          </div>
          <div className="al-feat-art">
            <div className="al-art-bar"><FlaskConical size={13} /> Lab · approval dossier · R12</div>
            <div className="al-art-body al-lab-art">
              <div className="al-lab-kicker">Full experiment · waiting for you</div>
              <div className="al-lab-title">Does the frozen teacher improve routed accuracy?</div>
              <div className="al-lab-facts">
                <span><small>Code</small><b>bc34f7b + 18 KB diff</b></span>
                <span><small>Parameters</small><b>conf/train.yaml</b></span>
                <span><small>Data</small><b>eval.jsonl · fingerprinted</b></span>
                <span><small>Machine</small><b>gpu-node-12</b></span>
              </div>
              <div className="al-lab-bind"><ShieldCheck size={15} /> Approval binds this exact code and parameter state.</div>
              <div className="al-lab-actions"><span>Reject with note</span><b>Approve experiment</b></div>
            </div>
          </div>
        </div>

        {/* 3. Terminals + agent state + renders */}
        <div className="al-feat al-reveal">
          <div className="al-feat-copy">
            <span className="al-eyebrow">Live terminals</span>
            <h3>Every session live — and it tells you when it&apos;s working.</h3>
            <p>Stream any session over a binary WebSocket — tmux control-mode on Unix, ConPTY on Windows — with full input, reflow, and a 100k-line scrollback. A live dot reads the screen to show running versus idle, with no cooperation from the agent.</p>
            <ul>
              <li><Check size={16} /> Running/idle detected from the screen — the &quot;esc to interrupt&quot; signal.</li>
              <li><Check size={16} /> <span className="al-mono">⇧⌘M</span> renders Markdown, LaTeX math, and tables from raw output, offline.</li>
              <li><Check size={16} /> Keep the Mac awake and reachable while it&apos;s locked.</li>
            </ul>
          </div>
          <div className="al-feat-art">
            <div className="al-art-bar"><Terminal size={13} /> eval-pipeline · gpu-node-12</div>
            <div className="al-art-body al-mini al-term">
              <div><span className="c-green">●</span> Building the nightly eval pipeline: fetch, score, report.</div>
              <div className="c-dim">  5 tasks (4 done, 1 in progress)</div>
              <div><span className="c-green">  ✔</span> Dataset loader + shard caching</div>
              <div><span className="c-green">  ✔</span> Metric aggregation across shards</div>
              <div><span className="c-amber">  ◼</span> Wire the report + end-to-end test</div>
              <div style={{ marginTop: 8 }} className="c-cyan">✻ Working… <span className="c-dim">(esc to interrupt)</span></div>
            </div>
          </div>
        </div>

        {/* 4. Weights & Biases */}
        <div className="al-feat rev al-reveal">
          <div className="al-feat-copy">
            <span className="al-eyebrow">Weights &amp; Biases</span>
            <h3>Your runs, in the same window.</h3>
            <p>When an agent prints a W&amp;B run URL, Argus catches it off the output stream, validates it, and opens the run in a webview in place of the terminal — already logged in. No copy-paste, no browser tab hunting.</p>
            <ul>
              <li><Check size={16} /> Detected from the raw stream and validated, so no mangled false positives.</li>
              <li><Check size={16} /> Login persists; flip between every run an agent has launched.</li>
              <li><Check size={16} /> The run list persists and grows, on macOS and Android.</li>
            </ul>
          </div>
          <div className="al-feat-art">
            <div className="al-art-bar"><LineChart size={13} /> wandb · caption-model / k9f3m2x7</div>
            <div className="al-art-body">
              <div style={{ display: 'flex', alignItems: 'center', gap: 9, marginBottom: 14 }}>
                <span className="al-card-dot" style={{ background: 'var(--green)', marginTop: 0 }} />
                <b style={{ fontFamily: 'var(--font-display)', fontSize: 14 }}>silvery-sweep-42</b>
                <span className="al-chip" style={{ marginLeft: 'auto' }}>running</span>
              </div>
              <svg className="al-spark" viewBox="0 0 260 96" preserveAspectRatio="none" aria-hidden>
                <line className="grid" x1="0" y1="24" x2="260" y2="24" />
                <line className="grid" x1="0" y1="48" x2="260" y2="48" />
                <line className="grid" x1="0" y1="72" x2="260" y2="72" />
                <polyline className="reward" points="6,82 40,74 74,60 108,53 142,38 176,31 210,22 250,15" />
                <polyline className="loss" points="6,24 40,33 74,40 108,49 142,56 176,65 210,70 250,77" />
              </svg>
              <div className="al-metrics">
                <span className="al-metric"><i style={{ background: 'var(--accent-bright)' }} />reward <b>7.94</b></span>
                <span className="al-metric"><i style={{ background: 'var(--amber)' }} />loss <b>0.42</b></span>
                <span className="al-metric">step <b>4.2k</b></span>
              </div>
            </div>
          </div>
        </div>

        {/* 5. Dashboards & notebooks */}
        <div className="al-feat al-reveal">
          <div className="al-feat-copy">
            <span className="al-eyebrow">Dashboards &amp; JupyterLab</span>
            <h3>Remote web apps and notebooks, in app.</h3>
            <p>An in-app browser that probes each host and catalogs the ports that really answer HTTP — TensorBoard, dev servers, internal tools — plus Jupyter notebooks whose kernel runs on the remote machine.</p>
            <ul>
              <li><Check size={16} /> Discover a remote web service without guessing its port or wiring a tunnel.</li>
              <li><Check size={16} /> Persistent tabs, find, zoom, and 5–60 second auto-refresh for live dashboards.</li>
              <li><Check size={16} /> Run notebook cells against a kernel on the host, not your laptop.</li>
            </ul>
          </div>
          <div className="al-feat-art">
            <div className="al-art-bar"><Notebook size={13} /> train.ipynb · gpu-node-12 · Python 3.11</div>
            <div className="al-art-body al-mini">
              <div className="al-nb-cell">
                <span className="al-nb-prompt">In [12]:</span>
                <div className="al-term" style={{ flex: 1, minWidth: 0 }}>
                  <div><span style={{ color: 'var(--violet)' }}>from</span> trainer <span style={{ color: 'var(--violet)' }}>import</span> fit_model</div>
                  <div><span className="c-cyan">fit_model</span>(model, train_ds, epochs=<span className="c-amber">4</span>)</div>
                </div>
              </div>
              <div className="al-nb-out">Epoch 4/4 — val_acc <span className="c-green">0.91</span> · loss <span className="c-amber">0.42</span> · 1m 58s</div>
            </div>
          </div>
        </div>

        {/* 6. Files / Monaco */}
        <div className="al-feat rev al-reveal">
          <div className="al-feat-copy">
            <span className="al-eyebrow">Files</span>
            <h3>Edit any host&apos;s files in VS Code&apos;s editor.</h3>
            <p>A cross-host file explorer with Monaco built in — per-file tabs, quick-open, live Markdown, and image / PDF / media preview, themed to match the app.</p>
            <ul>
              <li><Check size={16} /> <span className="al-mono">⇧⌘G</span> jumps to absolute, relative, <span className="al-mono">~</span>, or <span className="al-mono">$VAR</span> paths with live completion.</li>
              <li><Check size={16} /> Search file contents with regex and open the exact matching line.</li>
              <li><Check size={16} /> Git status colors the tree before you even open the review pane.</li>
            </ul>
          </div>
          <div className="al-feat-art">
            <div className="al-art-bar"><FileCode2 size={13} /> control.go · gpu-node-12</div>
            <div className="al-art-body al-mini al-term" style={{ lineHeight: 1.7 }}>
              <div><span className="c-dim">160</span>  <span style={{ color: 'var(--violet)' }}>func</span> <span className="c-cyan">DetectState</span>(socket, name <span className="c-amber">string</span>) <span className="c-amber">string</span> {'{'}</div>
              <div><span className="c-dim">161</span>    out, err := exec.<span className="c-cyan">Command</span>(<span className="c-green">&quot;tmux&quot;</span>, ...)</div>
              <div><span className="c-dim">164</span>    <span style={{ color: 'var(--violet)' }}>if</span> screenHasInterrupt(out) {'{'}</div>
              <div><span className="c-dim">165</span>        <span style={{ color: 'var(--violet)' }}>return</span> <span className="c-green">&quot;working&quot;</span></div>
              <div><span className="c-dim">166</span>    {'}'}</div>
            </div>
          </div>
        </div>

        {/* 7. Git panel */}
        <div className="al-feat al-reveal">
          <div className="al-feat-copy">
            <span className="al-eyebrow">Git panel</span>
            <h3>See what your agents actually changed.</h3>
            <p>One keystroke opens the working tree, commit graph, blame, branches, and pull requests for <i>that repo, on that machine</i>. Local review stays read-only; explicit PR actions and lazygit are there when you choose to mutate.</p>
            <ul>
              <li><Check size={16} /> GitHub-grade side-by-side diffs, straight from the broker — nothing installed per host.</li>
              <li><Check size={16} /> Review checks, conversations, and diffs; approve, comment, request changes, merge, or open on GitHub.</li>
              <li><Check size={16} /> <b style={{ color: 'var(--ink)' }}>Agent insights</b> and free-form questions work on a commit, range, branch, or PR — on demand, cached forever.</li>
            </ul>
          </div>
          <div className="al-feat-art">
            <div className="al-art-bar"><GitBranch size={13} /> gym-anything · gpu-node-07</div>
            <div className="al-art-body al-mini" style={{ lineHeight: 2.0 }}>
              <div><span style={{ color: 'var(--ink-dim)' }}>┆</span> <i style={{ color: 'var(--ink-dim)' }}>3 uncommitted changes — working tree</i></div>
              <div><span style={{ color: 'var(--blue)' }}>●</span> <span className="al-card-pill" style={{ marginRight: 6 }}>main</span>Fix reward normalization <span style={{ color: 'var(--ink-dim)', float: 'right' }}>2h</span></div>
              <div><span style={{ color: 'var(--blue)' }}>◉</span> Merge branch sweep-fixes <span style={{ color: 'var(--ink-dim)', float: 'right' }}>1d</span></div>
              <div><span style={{ color: 'var(--green)' }}>&nbsp;●</span> <span className="al-card-pill" style={{ marginRight: 6 }}>sweep-fixes</span>Batch the rollout buffer <span style={{ color: 'var(--ink-dim)', float: 'right' }}>1d</span></div>
              <div><span style={{ color: 'var(--blue)' }}>●</span> Add eval harness <span style={{ color: 'var(--ink-dim)', float: 'right' }}>2d</span></div>
              <div style={{ borderTop: '1px solid var(--line)', marginTop: 6, paddingTop: 6 }}><span className="c-green">+ reward = raw / running_std</span></div>
              <div><span style={{ color: 'var(--red, #e06c75)' }}>− reward = raw</span></div>
            </div>
          </div>
        </div>

        {/* 8. Journal → Wrapped */}
        <div className="al-feat rev al-reveal">
          <div className="al-feat-copy">
            <span className="al-eyebrow">Activity Journal → Argus Wrapped</span>
            <h3>Your fleet leaves a memory, not just scrollback.</h3>
            <p>The local Activity Journal records the moments your attention touched the fleet across Mac and phone. Wrapped turns that raw evidence into a living story and dashboard — without inventing the missing parts.</p>
            <ul>
              <li><Check size={16} /> An in-app ledger for what you saw, said, reviewed, changed, and launched.</li>
              <li><Check size={16} /> Rhythm, fleet state, delegation, interventions, experiments, projects, and shipped work.</li>
              <li><Check size={16} /> Statistics stay local; the optional persona sees only a compact numeric digest.</li>
            </ul>
          </div>
          <div className="al-feat-art al-wrapped-art">
            <div className="al-art-bar"><Sparkles size={13} /> Argus Wrapped · all recorded time</div>
            <div className="al-art-body">
              <div className="al-wrapped-kicker">The view from the bridge</div>
              <div className="al-wrapped-title">You supervised a fleet,<br />not a tab bar.</div>
              <div className="al-wrapped-stats">
                <span><b>18</b><small>agents</small></span>
                <span><b>6.4×</b><small>delegation</small></span>
                <span><b>27</b><small>milestones</small></span>
              </div>
              <div className="al-wrapped-meter"><i style={{ width: '74%' }} /><span>74% of fleet time was heads-down work</span></div>
            </div>
          </div>
        </div>

        {/* 9. Work from your phone */}
        <div className="al-feat al-reveal">
          <div className="al-feat-copy">
            <span className="al-eyebrow">Android</span>
            <h3>Run it all from your pocket.</h3>
            <p>The Command Center, live terminals, Files, ports, and full Lab hub — on your phone, over the same tailnet. Jump into a stuck session or decide a gated experiment from anywhere.</p>
            <ul>
              <li><Check size={16} /> The same peer-to-peer reach — no servers, just your tailnet.</li>
              <li><Check size={16} /> Lab approvals, evidence, comparison, guidance, curation, Unattended Mode, and deep-linked notifications.</li>
              <li><Check size={16} /> Workflows, todos, notes, and sent journal messages synced with your Mac.</li>
              <li><Check size={16} /> Dead cluster nodes age out automatically instead of filling the machine list.</li>
              <li><Check size={16} /> Foreground forwarding keeps tunnels alive in your pocket.</li>
            </ul>
          </div>
          <div className="al-feat-art al-art-bare">
            <div className="al-phone">
              <div className="al-phone-screen">
                <div className="al-phone-hd"><EyeMark /> <b>Argus</b> <span className="al-phone-badge"><i />1 needs you</span></div>
                <div className="al-phone-body">
                  <div className="al-pcard s-needs">
                    <div className="al-pcard-top"><span className="al-card-dot" /><b>Lab · R12</b><span className="pill pill-needs">Approval</span></div>
                    <div className="al-pcard-line">Full experiment gated · open exact evidence.</div>
                  </div>
                  <div className="al-pcard">
                    <div className="al-pcard-top"><span className="al-card-dot" style={{ background: 'var(--blue)' }} /><b>rl-finetune</b><span className="pill pill-working">Working</span></div>
                    <div className="al-pcard-line">Generating rollouts 6/8 · GPUs healthy.</div>
                  </div>
                </div>
                <div className="al-keybar">
                  <span className="al-key">esc</span><span className="al-key">tab</span><span className="al-key">^C</span><span className="al-key">^L</span><span className="al-key">↑</span><span className="al-key">⇧</span>
                </div>
              </div>
            </div>
          </div>
        </div>
      </section>

      {/* the mesh / no central server */}
      <section className="al-sec al-wrap">
        <div className="al-mesh-wrap">
          <div className="al-mesh al-reveal">
            <svg className="al-mesh-links" viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden>
              {meshNodes.map((n) => (
                <line key={n.label} x1="50" y1="50" x2={n.x} y2={n.y} />
              ))}
            </svg>
            <div className="ring" /><div className="ring r2" /><div className="ring r3" />
            <div className="al-mesh-eye"><EyeMark /></div>
            {meshNodes.map((n) => (
              <div key={n.label} className="al-node" style={{ left: `${n.x}%`, top: `${n.y}%`, color: n.c }}>
                <i style={{ background: n.c }} />
                <span>{n.label}</span>
              </div>
            ))}
          </div>
          <div className="al-reveal">
            <span className="al-eyebrow">No central server</span>
            <h2 style={{ fontSize: 'clamp(28px,4vw,42px)', marginTop: 14 }}>Peer-to-peer, by design.</h2>
            <p style={{ color: 'var(--ink-2)', marginTop: 16, fontSize: 17 }}>
              Each host runs a small <b style={{ color: 'var(--ink)' }}>broker</b>; the app dials them
              directly over your tailnet — encrypted, peer-to-peer. Nothing is hosted, nothing is
              centralized, and a machine that goes away simply drops off the map.
            </p>
            <ul className="al-feat-copy" style={{ marginTop: 20, paddingLeft: 0, listStyle: 'none', display: 'grid', gap: 10 }}>
              <li><Check size={16} style={{ color: 'var(--accent)' }} /> Discovery is capability-based — never by hostname.</li>
              <li><Cpu size={16} style={{ color: 'var(--accent)' }} /> The unit is the tmux socket, not a SLURM job — clusters aren&apos;t a special case.</li>
              <li><TerminalSquare size={16} style={{ color: 'var(--accent)' }} /> Drive the whole fabric from a shell: <span className="al-mono">ut ls / exec / spawn / tail / cp</span>.</li>
            </ul>
            <div className="al-mini al-term al-cli">
              <div><span className="c-dim">$</span> ut ls</div>
              <div className="c-dim">HOST           SESSIONS  STATE</div>
              <div>gpu-node-12    <span style={{ color: 'var(--ink)' }}>3</span>         <span className="c-green">● working</span></div>
              <div>this-mac       <span style={{ color: 'var(--ink)' }}>2</span>         <span className="c-amber">● idle</span></div>
            </div>
          </div>
        </div>
      </section>

      {/* the rest, as a grid */}
      <section className="al-sec al-wrap" style={{ paddingTop: 24 }}>
        <div className="al-sec-head al-reveal">
          <span className="al-eyebrow">And the rest of the toolbox</span>
          <h2>Everything around the agents, in reach.</h2>
        </div>
        <div className="al-grid">
          {tiles.map((t, i) => (
            <div key={t.t} className="al-tile al-reveal" style={{ transitionDelay: `${(i % 4) * 50}ms` }}>
              <span className="al-tile-ic"><t.icon size={20} /></span>
              <h3>{t.t}</h3>
              <p>{t.d}</p>
            </div>
          ))}
        </div>
      </section>

      {/* platforms */}
      <section className="al-sec al-wrap" style={{ textAlign: 'center', paddingTop: 24 }}>
        <span className="al-eyebrow al-reveal" style={{ display: 'block', marginBottom: 26 }}>One app, every device</span>
        <div className="al-plat al-reveal">
          <span className="p"><Laptop size={18} /> macOS</span>
          <span className="p"><Smartphone size={18} /> Android</span>
          <span className="p"><Monitor size={18} /> Windows</span>
        </div>
      </section>

      {/* final CTA */}
      <section className="al-cta al-reveal">
        <EyeMark />
        <h2 style={{ marginTop: 18 }}>Watch over everything.</h2>
        <p>Point Argus at your tailnet and every agent on every machine is one calm pane of glass away.</p>
        <div className="al-hero-cta" style={{ justifyContent: 'center' }}>
          <Link href="/docs" className="al-btn al-btn-primary">Read the docs <ArrowRight size={17} /></Link>
          <a href="https://github.com/Pranjal2041/argus" className="al-btn al-btn-ghost"><Github size={17} /> GitHub</a>
        </div>
      </section>

      <footer className="al-foot">
        <div className="al-foot-in">
          <span className="al-brand" style={{ fontSize: 15 }}><EyeMark /> Argus</span>
          <span>Named for Argus Panoptes, the hundred-eyed giant who watched over everything.</span>
          <span><a href="https://github.com/Pranjal2041/argus">MIT</a> · © 2026 Pranjal Aggarwal</span>
        </div>
      </footer>
    </main>
  );
}
