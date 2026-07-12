"use strict";

// Native and browser screenshot harness. Production loads this file too, but it
// remains inert unless the URL explicitly asks for a fixture.
(function loadFixture() {
  const fixture = new URLSearchParams(location.search).get("fixture");
  if (!fixture) return;

  const now = Date.now();
  const iso = minutesAgo => new Date(now - minutesAgo * 60_000).toISOString();
  const localCard = "local/s-41ejpm";
  const offlineCard = "mirror/babel-q9-24/s-9k2mfa";
  const projectRoot = "/Users/mara/Developer/retina-calibration";
  const baseEnvelope = {
    argv: ["uv", "run", "python", "train.py", "--config", "configs/retina.yaml"],
    cwd: projectRoot,
    tier: "quick",
    group: "illumination-sweep",
    tmuxSession: "retina-lab",
    machine: "Mara's MacBook Pro",
    bind: "sha256:27cab55b68f9f890dca4d7a4433d5a60a767b4999f01abfe52ff4a51c6bcdfe1",
    snapshot: { baseSha: "6a91c32d8819b0ac7f9f2dfe675325f69277dc58", patchBytes: 684 },
    params: [
      { path: `${projectRoot}/configs/retina.yaml` },
      { path: `${projectRoot}/configs/augment.yaml` },
    ],
    dataFiles: [
      { path: `${projectRoot}/data/validation.parquet`, sha256: "d87be32dd86c" },
      { path: `${projectRoot}/data/panel-map.json`, sha256: "a398ef77b15c" },
    ],
    env: { python: "Python 3.13.5", gpus: "Apple M3 Max · Metal", platform: "macOS 15.5" },
  };

  const paramA = [
    "seed: 2027",
    "optimizer: adamw",
    "learning_rate: 0.0003",
    "batch_size: 24",
    "epochs: 18",
    "illumination_jitter: 0.08",
    "validation_panel: holdout-east",
  ].join("\n");
  const paramB = [
    "seed: 2027",
    "optimizer: adamw",
    "learning_rate: 0.0001",
    "batch_size: 24",
    "epochs: 24",
    "illumination_jitter: 0.03",
    "validation_panel: holdout-east",
  ].join("\n");
  const diff = [
    "diff --git a/train.py b/train.py",
    "index 984dc17..ef74cb2 100644",
    "--- a/train.py",
    "+++ b/train.py",
    "@@ -84,6 +84,9 @@ def validation_step(batch):",
    "     logits = model(batch.image)",
    "+    if config.calibrate_per_panel:",
    "+        logits = panel_calibrator(logits, batch.panel_id)",
    "+",
    "     return score(logits, batch.target)",
    "diff --git a/configs/retina.yaml b/configs/retina.yaml",
    "--- a/configs/retina.yaml",
    "+++ b/configs/retina.yaml",
    "@@ -3,4 +3,4 @@ seed: 2027",
    "-illumination_jitter: 0.08",
    "+illumination_jitter: 0.03",
  ].join("\n");
  const environment = [
    "Python 3.13.5",
    "Darwin arm64",
    "",
    "numpy==2.2.6",
    "polars==1.31.0",
    "pytorch-lightning==2.5.2",
    "torch==2.7.1",
    "wandb==0.20.1",
  ].join("\n");
  const markdownResult = [
    "## Illumination sweep",
    "",
    "**Status:** completed",
    "",
    "| Metric | Baseline | Low jitter |",
    "|---|---:|---:|",
    "| Macro F1 | 0.812 | **0.831** |",
    "| East-camera FNR | 14.8% | **11.2%** |",
    "",
    "- The primary guardrail improved.",
    "- No data drift was detected.",
  ].join("\n");

  const model = {
    pendingKeys: [
      {
        id: "local/key-99b2",
        machineID: "local",
        machineName: "Mara's MacBook Pro",
        project: "spectral-transfer",
        cwd: "/Users/mara/Developer/spectral-transfer",
        session: "spectral-agent",
        created: iso(52),
      },
    ],
    pendingRuns: [
      {
        id: "local/s-41ejpm/R4",
        set: "s-41ejpm",
        machineID: "local",
        machineName: "Mara's MacBook Pro",
        run: "R4",
        project: "retina-calibration",
        intent: "Test whether per-panel calibration removes the east-camera error without erasing the low-light gain.",
        tier: "full",
        group: "illumination-sweep",
        created: iso(38),
      },
    ],
    hubNotes: [
      {
        machineID: "local",
        machineName: "Mara's MacBook Pro",
        storeID: "store:local",
        notes: [
          { scope: "global", id: "hn-1", time: iso(4320), author: "human", text: "Fix the random seed and report it with every comparative result.", hidden: false },
          { scope: "machine", id: "hn-2", time: iso(860), author: "human", text: "Keep local sweeps under 48 GB unified memory; queue larger work on Babel.", hidden: false },
          { scope: "project", project: "retina-calibration", id: "hn-3", time: iso(180), author: "human", text: "Treat east-camera false negatives as the primary guardrail; aggregate accuracy is secondary.", hidden: false },
          { scope: "project", project: "retina-calibration", id: "hn-4", time: iso(5900), author: "human", text: "Use the old v1 panel split.", hidden: true },
        ],
      },
      {
        machineID: "babel-q9-24",
        machineName: "babel-q9-24",
        storeID: "store:babel",
        notes: [
          { scope: "global", id: "hn-1-replica", time: iso(4320), author: "human", text: "Fix the random seed and report it with every comparative result.", hidden: false },
          { scope: "global", id: "hn-5", time: iso(1220), author: "human", text: "Checkpoints belong under /data/user_data, never a login-node home folder.", hidden: false },
          { scope: "project", project: "pause-prediction", id: "hn-6", time: iso(740), author: "human", text: "Report cohort-level hit rate and p95 pause time together.", hidden: false },
        ],
      },
    ],
    sets: [
      {
        id: localCard,
        setID: "s-41ejpm",
        machineID: "local",
        machineName: "Mara's MacBook Pro",
        project: "retina-calibration",
        cwd: projectRoot,
        created: iso(7100),
        policy: "full-only",
        keyActive: true,
        offline: false,
        archived: false,
        notes: [
          { id: "n-1", time: iso(180), author: "human", kind: "hnote", text: "Treat east-camera false negatives as the primary guardrail; aggregate accuracy is secondary." },
        ],
        setNotes: [
          { id: "n-2", time: iso(84), author: "agent", kind: "note", text: "The calibration sweep is now varying jitter and panel conditioning independently." },
          { id: "hn-set-1", time: iso(72), author: "human", kind: "hnote", scope: "set", text: "Use R3 as this set's comparison anchor; do not mix in the archived baseline split.", hidden: false },
          { id: "hn-set-old", time: iso(1800), author: "human", kind: "hnote", scope: "set", text: "Prefer the v1 baseline for this set.", hidden: true },
        ],
        runs: [
          { id: "R1", status: "done", tier: "quick", group: "baseline", latest: "Baseline reproduced: macro F1 0.812; east-camera false-negative rate 14.8%.", started: iso(410), exitCode: 0, archived: true },
          { id: "R2", status: "approved (launch with --proposal R2)", tier: "full", group: "illumination-sweep", latest: "Approved; the agent has not started it yet.", started: iso(260), exitCode: -1, archived: false },
          { id: "R3", status: "done", tier: "quick", group: "illumination-sweep", latest: markdownResult, latestAt: iso(101), started: iso(146), exitCode: 0, archived: false },
          { id: "R4", status: "proposed (awaiting approval)", tier: "full", group: "illumination-sweep", latest: "", started: iso(38), exitCode: -1, archived: false },
          { id: "R5", status: "running (12m)", tier: "full", group: "panel-calibration", latest: "Epoch 7/18 · validation macro F1 0.839", started: iso(12), exitCode: -1, archived: false },
          { id: "R6", status: "failed (exit 137)", tier: "quick", group: "stress-check", latest: "Process was killed during validation after memory climbed past the local limit.", started: iso(74), exitCode: 137, archived: false },
        ],
      },
      {
        id: "local/s-r0i7cs",
        setID: "s-r0i7cs",
        machineID: "local",
        machineName: "Mara's MacBook Pro",
        project: "sequence-distillation",
        cwd: "/Users/mara/Developer/sequence-distillation",
        created: iso(9800),
        policy: "all",
        keyActive: true,
        offline: false,
        archived: false,
        notes: [],
        setNotes: [],
        runs: [
          { id: "R1", status: "done", tier: "quick", group: "teacher-check", latest: "Teacher logits match the reference export within 2e-5.", started: iso(520), exitCode: 0, archived: false },
          { id: "R2", status: "running (46m)", tier: "full", group: "temperature-sweep", latest: "4 of 9 temperatures complete; T=2.5 currently leads.", started: iso(46), exitCode: -1, archived: false },
        ],
      },
      {
        id: offlineCard,
        setID: "s-9k2mfa",
        machineID: "mirror/babel-q9-24",
        machineName: "babel-q9-24",
        project: "pause-prediction",
        cwd: "/data/user_data/mara/smart-caching",
        created: iso(21000),
        mirroredAt: iso(97),
        policy: "all",
        keyActive: false,
        offline: true,
        archived: false,
        notes: [],
        setNotes: [],
        runs: [
          { id: "R7", status: "done", tier: "full", group: "churn-sweep", latest: "The two-stage cache improves p95 pause time by 18.4% at neutral hit rate.", started: iso(640), exitCode: 0, archived: false },
        ],
      },
      {
        id: "local/s-old001",
        setID: "s-old001",
        machineID: "local",
        machineName: "Mara's MacBook Pro",
        project: "legacy-encoder",
        cwd: "/Users/mara/Archive/legacy-encoder",
        created: iso(44000),
        policy: "none",
        keyActive: false,
        offline: false,
        archived: true,
        notes: [],
        setNotes: [],
        runs: [
          { id: "R1", status: "done", tier: "full", latest: "Archived after the replacement encoder passed parity.", started: iso(18000), exitCode: 0, archived: true },
        ],
      },
    ],
  };

  const details = {
    R1: {
      events: [
        { id: "r1-start", kind: "run-start", time: iso(410), author: "machine", data: { ...baseEnvelope, group: "baseline", argv: ["uv", "run", "python", "train.py", "--config", "configs/baseline.yaml"] } },
        { id: "r1-end", kind: "run-end", time: iso(391), author: "machine", data: { exit: 0, durationSec: 1137 } },
        { id: "r1-result", kind: "result", time: iso(389), author: "agent", text: "Baseline reproduced: macro F1 0.812; east-camera false-negative rate 14.8%." },
      ],
      files: { params: [{ path: `${projectRoot}/configs/baseline.yaml`, text: paramA }], log: "epoch 18/18 | val/f1 0.812 | east/fnr 0.148\nrun complete\n", env: environment },
      manifest: [{ name: "events.jsonl", size: 2904 }, { name: "log.txt", size: 48112 }],
    },
    R2: {
      events: [
        { id: "r2-proposal", kind: "proposal", time: iso(281), author: "agent", text: "Run the complete illumination sweep before introducing per-panel calibration.", data: { ...baseEnvelope, tier: "full", argv: ["uv", "run", "python", "sweep.py", "--grid", "configs/illumination-grid.yaml"] } },
        { id: "r2-decision", kind: "decision", time: iso(260), author: "human", text: "Approved after confirming the validation split.", data: { approve: true } },
      ],
      files: { params: [{ path: `${projectRoot}/configs/illumination-grid.yaml`, text: paramA }], diff, env: environment },
      manifest: [{ name: "proposal.json", size: 1874 }, { name: "params/illumination-grid.yaml", size: 412 }],
    },
    R3: {
      events: [
        { id: "r3-start", kind: "run-start", time: iso(146), author: "machine", data: { ...baseEnvelope, argv: ["uv", "run", "python", "train.py", "--config", "configs/retina-low-jitter.yaml"] } },
        { id: "r3-end", kind: "run-end", time: iso(103), author: "machine", data: { exit: 0, durationSec: 2584, wandb: ["vision-lab/retina-calibration/runs/3k92w8fd"] } },
        { id: "r3-result", kind: "result", time: iso(101), author: "agent", text: markdownResult },
        { id: "r3-note", kind: "hnote", time: iso(96), author: "human", text: "The east-camera gain is meaningful; verify it survives panel conditioning." },
      ],
      files: { params: [{ path: `${projectRoot}/configs/retina-low-jitter.yaml`, text: paramB }], diff, log: "epoch 22/24 | val/f1 0.829\nepoch 24/24 | val/f1 0.831 | east/fnr 0.112\nrun complete\n", env: environment },
      manifest: [{ name: "events.jsonl", size: 4920 }, { name: "diff.patch", size: 684 }, { name: "log.txt", size: 95221 }],
    },
    R4: {
      events: [
        { id: "r4-proposal", kind: "proposal", time: iso(38), author: "agent", text: "Test whether per-panel calibration removes the east-camera error without erasing the low-light gain.", data: { ...baseEnvelope, tier: "full", group: "panel-calibration", argv: ["uv", "run", "python", "train.py", "--config", "configs/panel-calibration.yaml", "--epochs", "36"] } },
      ],
      files: { params: [{ path: `${projectRoot}/configs/panel-calibration.yaml`, text: `${paramB}\ncalibrate_per_panel: true\ncalibration_rank: 4` }], diff, env: environment },
      manifest: [{ name: "proposal.json", size: 2231 }, { name: "diff.patch", size: 684 }],
    },
    R5: {
      events: [
        { id: "r5-proposal", kind: "proposal", time: iso(33), author: "agent", text: "Fit a rank-2 panel calibration layer on the held-out split.", data: { ...baseEnvelope, tier: "full", group: "panel-calibration" } },
        { id: "r5-decision", kind: "decision", time: iso(24), author: "human", text: "Approved with the east-camera guardrail.", data: { approve: true } },
        { id: "r5-start", kind: "run-start", time: iso(12), author: "machine", data: { ...baseEnvelope, tier: "full", group: "panel-calibration", argv: ["uv", "run", "python", "train.py", "--config", "configs/panel-rank2.yaml"] } },
        { id: "r5-progress", kind: "note", time: iso(2), author: "agent", text: "Epoch 7/18 · validation macro F1 0.839; east-camera slice is still noisy." },
      ],
      files: { params: [{ path: `${projectRoot}/configs/panel-rank2.yaml`, text: `${paramB}\ncalibrate_per_panel: true\ncalibration_rank: 2` }], diff, log: "epoch 6/18 | val/f1 0.835\nepoch 7/18 | val/f1 0.839 | east/fnr 0.109\ntraining…\n", env: environment },
      manifest: [{ name: "events.jsonl", size: 3314 }, { name: "log.txt", size: 27890 }],
    },
    R6: {
      events: [
        { id: "r6-start", kind: "run-start", time: iso(74), author: "machine", data: { ...baseEnvelope, tier: "quick", group: "stress-check", argv: ["uv", "run", "python", "stress_validate.py", "--workers", "12"] } },
        { id: "r6-end", kind: "run-end", time: iso(68), author: "machine", data: { exit: 137, durationSec: 366, drift: [] } },
        { id: "r6-result", kind: "result", time: iso(67), author: "agent", text: "Process was killed during validation after memory climbed past the local limit." },
      ],
      files: { params: [{ path: `${projectRoot}/configs/stress.yaml`, text: "workers: 12\nprefetch_batches: 8\nbatch_size: 48\n" }], diff: "", log: "step 114 | memory 38.1 GB\nstep 127 | memory 45.7 GB\nstep 131 | memory 51.2 GB\nzsh: killed     uv run python stress_validate.py --workers 12\n", env: environment },
      manifest: [{ name: "events.jsonl", size: 1841 }, { name: "log.txt", size: 68211 }],
    },
  };

  const offlineDetail = {
    events: [
      { id: "off-start", kind: "run-start", time: iso(640), author: "machine", data: { ...baseEnvelope, cwd: "/data/user_data/mara/smart-caching", machine: "babel-q9-24", tmuxSession: "pause-sweep", params: [{ path: "/data/user_data/mara/smart-caching/config/churn.yaml" }], dataFiles: [{ path: "/data/user_data/mara/smart-caching/data/churn-cohorts.parquet", sha256: "b912e84acf10" }], env: { python: "Python 3.11.9", gpus: "4 × NVIDIA A100 80GB" } } },
      { id: "off-end", kind: "run-end", time: iso(522), author: "machine", data: { exit: 0, durationSec: 7078 } },
      { id: "off-result", kind: "result", time: iso(519), author: "agent", text: "The two-stage cache improves p95 pause time by 18.4% at neutral hit rate." },
    ],
    files: { params: [{ path: "/data/user_data/mara/smart-caching/config/churn.yaml", text: "cohort: high-churn\ncache: two-stage\nseed: 2027\n" }], log: "mirror captured after successful completion\n", env: "Python 3.11.9\ntorch==2.5.1\n" },
    manifest: [{ name: "events.jsonl", size: 3101 }, { name: "log.txt", size: 74003 }],
  };

  UTLab.setData(model);
  for (const [run, detail] of Object.entries(details)) UTLab.setRunDetail(localCard, run, detail);
  UTLab.setRunDetail(offlineCard, "R7", fixture === "offline-summary" ? { events: [], files: {}, manifest: [] } : offlineDetail);

  const routes = {
    inbox: ["inbox", { type: "proposal", id: "local/s-41ejpm/R4" }],
    access: ["inbox", { type: "key", id: "local/key-99b2" }],
    research: ["research", null],
    project: ["research", { type: "set", card: localCard }],
    run: ["research", { type: "run", card: localCard, run: "R3" }],
    pending: ["research", { type: "run", card: localCard, run: "R4" }],
    running: ["research", { type: "run", card: localCard, run: "R5" }],
    failed: ["research", { type: "run", card: localCard, run: "R6" }],
    offline: ["research", { type: "run", card: offlineCard, run: "R7" }],
    "offline-summary": ["research", { type: "run", card: offlineCard, run: "R7" }],
    archive: ["research", { type: "set", card: "local/s-old001" }],
    compare: ["research", { type: "compare", card: localCard, a: "R1", b: "R3" }],
    guidance: ["guidance", null],
  };

  if (fixture === "empty") {
    UTLab.setData({ sets: [], pendingKeys: [], pendingRuns: [], hubNotes: [] });
    UTLab.fixtureRoute("inbox", null);
  } else {
    const [area, selection] = routes[fixture] || routes.inbox;
    UTLab.fixtureRoute(area, selection, fixture === "archive" ? { researchFilter: "archived" } : {});
  }
  document.title = `Argus Lab · ${fixture}`;
})();
