# Files — remote filesystem browser (design)

The third pillar of universal_tmux, alongside **terminals** (the DMUX) and **ports**.
A cross-host file browser + viewer/editor that rides the *same per-host broker* you
already run everywhere (runs as you, on every host, reachable over the tailnet).
The terminal stays the main interface; Files is a secondary, tabbed window like Ports.

## Goals
- Browse any host's filesystem (Mac / Linux / Windows) in a **Windows-Explorer-style
  tree** — flat, sharp, dense. Our own "Finder" for remote hosts.
- **Reveal here**: right-click a remote session → open Files at that session's cwd on that
  host (replacing "Reveal in Finder", which only works for local sessions today).
- **View** anything — source (syntax-highlighted), images, PDF, audio/video, binary.
- **Edit** text seamlessly and save back.

## Decisions (locked)
- **Transport = broker endpoints**, not a separate service/port. Same rationale as the
  port-hub: the broker is already the universal per-host reach; new endpoints = zero extra
  deployment.
- **Text engine = CodeMirror 6 in a `WKWebView`**, used read-only for the viewer and editable
  for the editor (one robust component, no throwaway viewer). Chosen over Monaco (lighter:
  ~125KB vs 2–10MB; <100ms start; clean multi-instance for tabs; easy offline bundle) and
  over native STTextView (GPLv3 + heavy) / Highlightr (whole-buffer rehighlight).
- **UI = minimal / Raycast** (flat, hairline separators, high-contrast, monospaced paths).
  Glass is reserved for Ports; Files is dense and wants sharp. The existing Ports window is
  left unchanged.

## Broker file service (`internal/fsvc`, wired into `cmd/ut-broker`)
Runs as the user; reads/writes whatever the user can; tailnet-only (same trust boundary as
the rest of the broker). No new exposure.

- `GET /fs/home` → `{home, roots:[...]}` — default landing dir + platform roots (`/` on Unix,
  drive letters `C:\`,`D:\` on Windows).
- `GET /fs/list?path=` → `{path, entries:[{name, path, isDir, size, mtime, mode, symlink, target?}]}`.
  **Each entry carries its full absolute `path`** so the client never joins paths itself —
  that's how we stay cross-platform (Windows `\` vs Unix `/`). Empty/omitted `path` returns the
  roots.
- `GET /fs/read?path=` → raw bytes, **HTTP Range** supported + content-type sniff. Range is what
  makes large files and **media streaming** work (`AVPlayer` issues range requests; big text is
  capped/previewed).
- `POST /fs/write?path=` (Phase 2) → atomic write (temp file + rename).
- Later: `mkdir`, `rename`, `delete`, `move`, `download` (dir→zip), `upload`.

Path handling: server returns platform-native absolute paths; client treats them as opaque
strings and always navigates by an entry's returned `path`. Symlinks reported with `target`.

## macOS Files window
Separate `Window(id: "files")` (like Ports), opened from a toolbar button and from "Reveal in
Files". **Tabbed**: each tab is an independent `(host, root)` browsing context.

Layout (Windows-Explorer):
- Left: lazy disclosure **tree** (`OutlineGroup` / `List(children:)`), children fetched from
  `/fs/list` on expand; file-type SF Symbols by extension; sizes/dates.
- Top: breadcrumb / path bar + host picker (derive host+scheme from `Machine.httpBase`, as
  `PortsView` does).
- Right: **content pane**, dispatched by file type:
  - **text/source** → CodeMirror 6 webview (read-only = viewer, editable = editor).
  - **image** → `NSImage`.
  - **pdf** → `PDFKit` (`PDFView`).
  - **audio/video** → AVKit, streaming from the `/fs/read?path=` URL (Range).
  - **binary/unknown/too-large** → metadata + hex peek, no auto-load.

### CodeMirror 6 integration
- Ship a small local CM6 bundle as app resources (`index.html` + bundled JS/CSS); `WKWebView`
  loads it from the bundle (offline, no network).
- **Languages**: ~20 first-party Lezer grammars (JS/TS, Python, Java, C/C++, Rust, Go, PHP,
  HTML, CSS, JSON, Markdown, XML, SQL, YAML, …) **plus** `@codemirror/legacy-modes` (100+ more:
  shell, Ruby, Lua, Swift, Kotlin, Haskell, Dockerfile, TOML, INI, diff, Makefile, PowerShell,
  R, Julia, …). Mode chosen by file extension; lazy-loaded so the bundle stays small.
- **Bridge** (JSON over `WKScriptMessageHandler` ⇄ `evaluateJavaScript`): native → web
  `setContent(text, language, readOnly)`; web → native `didEdit`, `save`. One CM6 instance per
  open file (independent instances = clean tabs).
- Theme tuned to match the minimal app palette.

## Reveal-here
The session row already has an `onReveal` action (today: "Reveal Folder in Finder", gated to
local). For **remote** sessions, swap in "Reveal in Files" → open the Files window with a new
tab on that `Machine`, rooted at the session's cwd (`s.path`), expanded to it. Local sessions
keep the real Finder.

## Phasing
1. **Browse + view** — `/fs/home` + `/fs/list` + `/fs/read`; Files window with tabs + tree +
   content pane (CM6 read-only, image, pdf, media, binary). The "remote Finder."
2. **Reveal-here** + **editor** — remote session menu integration; CM6 editable + `/fs/write`.
3. **File ops** — mkdir/rename/delete/move/download/upload, search, drag-and-drop.

## Out of scope (for now)
- LSP / IntelliSense (CM6 stays a great editor without it; revisit if wanted).
- Real-time collaborative editing.
- OS-level mounts (WebDAV/SSHFS) — we want an in-app custom UI that's uniform across hosts.
