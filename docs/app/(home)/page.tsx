'use client';

import { useEffect } from 'react';
import Link from 'next/link';
import {
  Workflow, Terminal, FileCode2, ListTodo, Cable, LayoutDashboard,
  LineChart, History, Palette, TerminalSquare, ShieldCheck, Check, ArrowRight,
  Cpu, Laptop, Smartphone, Monitor,
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
  { name: 'vlm_gating', host: 'babel-o9-32', cls: 's-needs', pill: 'pill-needs', label: 'Needs you', line: <>Run failed — <b>CUDA OOM</b> at step 4,210. Waiting on a smaller batch.</> },
  { name: 'dist_training', host: 'babel-t5-24', cls: 's-working', pill: 'pill-working', label: 'Working', line: <>Generating rollouts <b>6/8</b> · 9.7 tok/s, GPUs healthy.</> },
  { name: 'robocasa', host: 'babel-t5-24', cls: 's-milestone', pill: 'pill-mile', label: 'Milestone', line: <>Student-drop + teacher-full vLLM servers <b>up</b>.</> },
  { name: 'cua-mouse', host: 'this mac', cls: 's-working', pill: 'pill-working', label: 'Working', line: <>Probe executing — 2/7 trials, no action needed.</> },
  { name: 'unreal_engine', host: 'babel-q9-24', cls: 's-working', pill: 'pill-working', label: 'Working', line: <>Compiling shaders · 41% · monitor at :07.</> },
  { name: 'astronomy', host: 'this mac', cls: 's-idle', pill: 'pill-idle', label: 'Idle', line: <>Finished the figure export.</> },
];

const meshNodes = [
  { x: 50, y: 3, c: 'var(--green)', label: 'this mac' },
  { x: 94, y: 36, c: 'var(--blue)', label: 'babel-o9-32' },
  { x: 78, y: 92, c: 'var(--amber)', label: 'babel-t5-24' },
  { x: 22, y: 92, c: 'var(--violet)', label: 'pranjala-win' },
  { x: 6, y: 36, c: 'var(--orange)', label: 'phone' },
];

const tiles = [
  { icon: Cable, t: 'Port forwards', d: 'Bind a local port and tunnel it over the tailnet to any remote broker — no ssh -L juggling.' },
  { icon: LayoutDashboard, t: 'Dashboards & notebooks', d: 'An in-app browser for remote web UIs, and Jupyter notebooks whose kernel runs on the host.' },
  { icon: LineChart, t: 'Weights & Biases', d: 'When an agent prints a W&B run URL, open the run in place — already logged in.' },
  { icon: History, t: 'Session history', d: 'A durable record of every session that ran — survives downtime; a click opens or re-creates it.' },
  { icon: Palette, t: 'Themes', d: 'Recolor the whole app — chrome, terminals, and editor — with editor-grade schemes.' },
  { icon: TerminalSquare, t: 'ut CLI + mesh', d: 'A drop-in for tmux that publishes a host, plus a fabric: ut ls / exec / spawn / tail / cp.' },
];

export default function HomePage() {
  useEffect(() => {
    const io = new IntersectionObserver(
      (entries) => entries.forEach((e) => { if (e.isIntersecting) { e.target.classList.add('in'); io.unobserve(e.target); } }),
      { threshold: 0.12, rootMargin: '0px 0px -40px 0px' },
    );
    document.querySelectorAll('.al-reveal').forEach((el) => io.observe(el));
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
          One native app, no central server.
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
            <span className="al-cc-glance"><b>1</b> needs you · 6 quiet</span>
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
            <em> working</em>, <em>stuck</em>, or <em>waiting on you</em>.
          </p>
        </div>
      </section>

      {/* marquee feature rows */}
      <section className="al-wrap" style={{ paddingBottom: 40 }}>
        {/* Workflows */}
        <div className="al-feat al-reveal">
          <div className="al-feat-copy">
            <span className="al-eyebrow">Workflows</span>
            <h3>Spin up an agent in one click.</h3>
            <p>Save the recipe — a machine, a folder, a command sequence — and starting it becomes a tap instead of attach, cd, and type.</p>
            <ul>
              <li><Check size={16} /> Wildcard machines: <span className="al-mono" style={{ color: 'var(--accent-bright)' }}>babel-*</span> picks any free node.</li>
              <li><Check size={16} /> Creates the session, cd&apos;s in, and types your commands — or just opens it if it&apos;s already running.</li>
              <li><Check size={16} /> Synced across your devices through your Mac.</li>
            </ul>
          </div>
          <div className="al-feat-art">
            <div className="al-art-bar"><Workflow size={13} /> Workflows · this mac</div>
            <div className="al-art-body">
              <div className="al-row"><span className="al-card-dot" style={{ background: 'var(--accent)' }} /><b style={{ fontFamily: 'var(--font-display)', fontSize: 14 }}>website</b><span className="al-card-host" style={{ marginLeft: 'auto' }}>~/dev/site</span><span className="al-chip">run</span></div>
              <div className="al-row"><span className="al-card-dot" style={{ background: 'var(--violet)' }} /><b style={{ fontFamily: 'var(--font-display)', fontSize: 14 }}>storage-analysis</b><span className="al-card-host" style={{ marginLeft: 'auto' }}>babel-* : ~/scratch</span><span className="al-chip">run</span></div>
              <div className="al-mini al-term" style={{ marginTop: 12 }}>
                <span className="c-dim">$</span> claude --resume <span className="c-cyan">b63novw6</span>
              </div>
            </div>
          </div>
        </div>

        {/* Terminals */}
        <div className="al-feat rev al-reveal">
          <div className="al-feat-copy">
            <span className="al-eyebrow">Terminals</span>
            <h3>Every session, live, in one window.</h3>
            <p>Stream any session over a binary WebSocket — tmux control-mode on Unix, ConPTY on Windows — with full input, reflow, and a 100k-line scrollback. No SSH drawer.</p>
            <ul>
              <li><Check size={16} /> A live running/idle dot per session, read passively from the screen.</li>
              <li><Check size={16} /> Render Markdown, math, and tables from agent output, offline.</li>
              <li><Check size={16} /> Keep the Mac awake and reachable while it&apos;s locked.</li>
            </ul>
          </div>
          <div className="al-feat-art">
            <div className="al-art-bar"><Terminal size={13} /> vlm_gating · babel-t5-24</div>
            <div className="al-art-body al-mini al-term">
              <div><span className="c-green">●</span> On-policy distillation: the student generates, the teacher scores.</div>
              <div className="c-dim">  5 tasks (4 done, 1 in progress)</div>
              <div><span className="c-green">  ✔</span> RL trainer drop-mode forward + router freeze</div>
              <div><span className="c-green">  ✔</span> Teacher multimodal logprob fix</div>
              <div><span className="c-amber">  ◼</span> OPD config + launch + end-to-end verify</div>
              <div style={{ marginTop: 8 }} className="c-cyan">✻ Working… <span className="c-dim">(esc to interrupt)</span></div>
            </div>
          </div>
        </div>

        {/* Files / Monaco */}
        <div className="al-feat al-reveal">
          <div className="al-feat-copy">
            <span className="al-eyebrow">Files</span>
            <h3>Edit any host&apos;s files in VS Code&apos;s editor.</h3>
            <p>A cross-host file explorer with Monaco built in — per-file tabs, <span className="al-mono">⌘P</span> quick-open, live Markdown preview, and image / PDF / media preview.</p>
            <ul>
              <li><Check size={16} /> Syntax highlighting and themes that match the app.</li>
              <li><Check size={16} /> Upload, download, and reveal a session&apos;s working directory.</li>
            </ul>
          </div>
          <div className="al-feat-art">
            <div className="al-art-bar"><FileCode2 size={13} /> control.go · babel-t5-24</div>
            <div className="al-art-body al-mini al-term" style={{ lineHeight: 1.7 }}>
              <div><span className="c-dim">160</span>  <span style={{ color: 'var(--violet)' }}>func</span> <span className="c-cyan">DetectState</span>(socket, name <span className="c-amber">string</span>) <span className="c-amber">string</span> {'{'}</div>
              <div><span className="c-dim">161</span>    out, err := exec.<span className="c-cyan">Command</span>(<span className="c-green">&quot;tmux&quot;</span>, ...)</div>
              <div><span className="c-dim">164</span>    <span style={{ color: 'var(--violet)' }}>if</span> screenHasInterrupt(out) {'{'}</div>
              <div><span className="c-dim">165</span>        <span style={{ color: 'var(--violet)' }}>return</span> <span className="c-green">&quot;working&quot;</span></div>
              <div><span className="c-dim">166</span>    {'}'}</div>
            </div>
          </div>
        </div>

        {/* Planning: Todo Maps + Notes */}
        <div className="al-feat rev al-reveal">
          <div className="al-feat-copy">
            <span className="al-eyebrow">Todo Maps · Notes Hub</span>
            <h3>Plans for your agents, kept with them.</h3>
            <p>When you run ahead of an agent, park the next steps in a per-session checklist that <em>outlives</em> the session — and keep a separate hub of free-form, time-grouped notes.</p>
            <ul>
              <li><Check size={16} /> Boards keyed to a machine + session; reopen it and your todos are there.</li>
              <li><Check size={16} /> Multiline notes, grouped Today / Yesterday / Earlier — by last edit.</li>
              <li><Check size={16} /> Both synced across your Mac and phone.</li>
            </ul>
          </div>
          <div className="al-feat-art">
            <div className="al-art-bar"><ListTodo size={13} /> vlm_gating</div>
            <div className="al-art-body">
              <div className="al-row"><span className="al-check on" /><span>Implement the work-while-I-sleep feature</span></div>
              <div className="al-row"><span className="al-check" /><span>Wire OPD config + launch</span></div>
              <div className="al-row al-strike"><span className="al-check on" /><span>Teacher multimodal logprob fix</span></div>
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
            <ul className="al-feat-copy" style={{ marginTop: 20, paddingLeft: 0, listStyle: 'none' }}>
              <li style={{ marginBottom: 10 }}><Check size={16} style={{ color: 'var(--accent)' }} /> &nbsp;Discovery is capability-based — never by hostname.</li>
              <li style={{ marginBottom: 10 }}><Cpu size={16} style={{ color: 'var(--accent)' }} /> &nbsp;The unit is the tmux socket, not a SLURM job — clusters are not a special case.</li>
              <li><ShieldCheck size={16} style={{ color: 'var(--accent)' }} /> &nbsp;Brokers run as you, reachable only from your devices.</li>
            </ul>
          </div>
        </div>
      </section>

      {/* the rest, as a grid */}
      <section className="al-sec al-wrap" style={{ paddingTop: 24 }}>
        <div className="al-sec-head al-reveal">
          <span className="al-eyebrow">And the rest of the toolbox</span>
          <h2>Everything an agent leaves behind, in reach.</h2>
        </div>
        <div className="al-grid">
          {tiles.map((t, i) => (
            <div key={t.t} className="al-tile al-reveal" style={{ transitionDelay: `${(i % 3) * 60}ms` }}>
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
