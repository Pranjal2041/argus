// CodeMirror 6 editor bundled for the universal_tmux Files browser. Loaded in a
// WKWebView; exposes window.UTEditor for the Swift bridge:
//   UTEditor.init()
//   UTEditor.setContent(text, filename, readOnly)  -> repaints + picks language by extension
//   UTEditor.getContent()                          -> current document text
// Edits post {type:'change'} to the native ut message handler (for the editor phase).

import { EditorState, Compartment } from "@codemirror/state";
import {
  EditorView, keymap, lineNumbers, highlightActiveLine,
  highlightActiveLineGutter, drawSelection, highlightSpecialChars,
} from "@codemirror/view";
import { defaultKeymap, history, historyKeymap, indentWithTab } from "@codemirror/commands";
import { searchKeymap, highlightSelectionMatches } from "@codemirror/search";
import {
  syntaxHighlighting, defaultHighlightStyle, indentOnInput,
  bracketMatching, foldGutter, foldKeymap, StreamLanguage,
} from "@codemirror/language";
import { oneDark } from "@codemirror/theme-one-dark";

// First-party Lezer languages
import { javascript } from "@codemirror/lang-javascript";
import { python } from "@codemirror/lang-python";
import { json } from "@codemirror/lang-json";
import { markdown } from "@codemirror/lang-markdown";
import { html } from "@codemirror/lang-html";
import { css } from "@codemirror/lang-css";
import { xml } from "@codemirror/lang-xml";
import { java } from "@codemirror/lang-java";
import { cpp } from "@codemirror/lang-cpp";
import { rust } from "@codemirror/lang-rust";
import { go } from "@codemirror/lang-go";
import { php } from "@codemirror/lang-php";
import { sql } from "@codemirror/lang-sql";
import { yaml } from "@codemirror/lang-yaml";

// Legacy (CodeMirror 5) modes for the long tail
import { shell } from "@codemirror/legacy-modes/mode/shell";
import { ruby } from "@codemirror/legacy-modes/mode/ruby";
import { lua } from "@codemirror/legacy-modes/mode/lua";
import { swift } from "@codemirror/legacy-modes/mode/swift";
import { toml } from "@codemirror/legacy-modes/mode/toml";
import { dockerFile } from "@codemirror/legacy-modes/mode/dockerfile";
import { properties } from "@codemirror/legacy-modes/mode/properties";
import { diff } from "@codemirror/legacy-modes/mode/diff";
import { powerShell } from "@codemirror/legacy-modes/mode/powershell";
import { perl } from "@codemirror/legacy-modes/mode/perl";
import { r } from "@codemirror/legacy-modes/mode/r";
import { julia } from "@codemirror/legacy-modes/mode/julia";
import { haskell } from "@codemirror/legacy-modes/mode/haskell";
import { nginx } from "@codemirror/legacy-modes/mode/nginx";
import { cmake } from "@codemirror/legacy-modes/mode/cmake";
import { csharp, kotlin, scala, dart, objectiveC } from "@codemirror/legacy-modes/mode/clike";

const sl = (m) => StreamLanguage.define(m);

// Map a filename to a language extension (or [] for plain text).
function langForName(name) {
  const n = (name || "").toLowerCase();
  const dot = n.lastIndexOf(".");
  const ext = dot >= 0 ? n.slice(dot + 1) : n; // bare names like "Dockerfile"
  switch (ext) {
    case "js": case "cjs": case "mjs": case "jsx": return javascript({ jsx: true });
    case "ts": return javascript({ typescript: true });
    case "tsx": return javascript({ typescript: true, jsx: true });
    case "py": case "pyw": return python();
    case "json": case "jsonc": case "geojson": return json();
    case "md": case "markdown": case "mdx": return markdown();
    case "html": case "htm": case "xhtml": case "vue": case "svelte": return html();
    case "css": case "scss": case "less": case "sass": return css();
    case "xml": case "plist": case "svg": case "xaml": case "storyboard": return xml();
    case "java": return java();
    case "c": case "h": case "cpp": case "cc": case "cxx": case "hpp": case "hh": case "ino": return cpp();
    case "rs": return rust();
    case "go": return go();
    case "php": return php();
    case "sql": return sql();
    case "yaml": case "yml": return yaml();
    case "sh": case "bash": case "zsh": case "fish": case "ksh": case "profile": case "bashrc": case "zshrc": return sl(shell);
    case "rb": case "gemspec": case "rake": return sl(ruby);
    case "lua": return sl(lua);
    case "swift": return sl(swift);
    case "toml": return sl(toml);
    case "dockerfile": return sl(dockerFile);
    case "ini": case "cfg": case "conf": case "properties": case "env": return sl(properties);
    case "diff": case "patch": return sl(diff);
    case "ps1": case "psm1": case "psd1": return sl(powerShell);
    case "pl": case "pm": return sl(perl);
    case "r": return sl(r);
    case "jl": return sl(julia);
    case "hs": return sl(haskell);
    case "nginx": return sl(nginx);
    case "cmake": return sl(cmake);
    case "cs": return sl(csharp);
    case "kt": case "kts": return sl(kotlin);
    case "scala": case "sbt": return sl(scala);
    case "dart": return sl(dart);
    case "m": case "mm": return sl(objectiveC);
    default:
      if (n === "dockerfile") return sl(dockerFile);
      if (n === "makefile" || n === "gnumakefile") return sl(cmake);
      return [];
  }
}

const languageConf = new Compartment();
const readOnlyConf = new Compartment();
const fontConf = new Compartment();
const fontTheme = (px) => EditorView.theme({
  "&": { fontSize: px + "px" },
  ".cm-content": { fontSize: px + "px" },
  ".cm-gutters": { fontSize: Math.max(9, px - 1) + "px" },
});
let view;

// Notify the native side of every document change immediately (carries the full
// text so Swift's draft is always current — a save right after typing is correct).
function postChange(state) {
  if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ut) {
    window.webkit.messageHandlers.ut.postMessage({ type: "change", text: state.doc.toString() });
  }
}

window.UTEditor = {
  init() {
    const state = EditorState.create({
      doc: "",
      extensions: [
        lineNumbers(),
        highlightActiveLineGutter(),
        highlightSpecialChars(),
        history(),
        foldGutter(),
        drawSelection(),
        indentOnInput(),
        bracketMatching(),
        highlightActiveLine(),
        highlightSelectionMatches(),
        syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
        keymap.of([
          ...defaultKeymap, ...historyKeymap, ...searchKeymap, ...foldKeymap, indentWithTab,
        ]),
        EditorView.lineWrapping,
        oneDark,
        fontConf.of(fontTheme(13)),
        languageConf.of([]),
        readOnlyConf.of(EditorState.readOnly.of(true)),
        EditorView.updateListener.of((u) => {
          if (u.docChanged) postChange(u.state);
        }),
      ],
    });
    view = new EditorView({ state, parent: document.body });
  },

  setContent(text, name, readOnly) {
    if (!view) return;
    view.dispatch({
      changes: { from: 0, to: view.state.doc.length, insert: text },
      effects: [
        languageConf.reconfigure(langForName(name)),
        readOnlyConf.reconfigure(EditorState.readOnly.of(!!readOnly)),
      ],
    });
    view.scrollDOM.scrollTop = 0;
  },

  getContent() {
    return view ? view.state.doc.toString() : "";
  },

  setFontSize(px) {
    if (view) view.dispatch({ effects: fontConf.reconfigure(fontTheme(px)) });
  },

  setEditable(editable) {
    if (view) view.dispatch({ effects: readOnlyConf.reconfigure(EditorState.readOnly.of(!editable)) });
  },
};
