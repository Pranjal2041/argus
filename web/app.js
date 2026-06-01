// Argus web client. Binary frame: [op u8][paneLen u8][pane][payload].
const OP_OUTPUT = 0x01, OP_INPUT = 0x02, OP_RESIZE = 0x03;

const term = new Terminal({
  cursorBlink: true,
  fontFamily: "Menlo, Monaco, monospace",
  fontSize: 13,
  theme: { background: "#0b0b0b" },
});
const fit = new FitAddon.FitAddon();
term.loadAddon(fit);
term.open(document.getElementById("terminal"));
fit.fit();

const enc = new TextEncoder();
const dec = new TextDecoder();
let lastPane = "";

function frame(op, pane, payload) {
  const p = enc.encode(pane);
  const buf = new Uint8Array(2 + p.length + payload.length);
  buf[0] = op;
  buf[1] = p.length;
  buf.set(p, 2);
  buf.set(payload, 2 + p.length);
  return buf;
}

const proto = location.protocol === "https:" ? "wss" : "ws";
const ws = new WebSocket(`${proto}://${location.host}/ws`);
ws.binaryType = "arraybuffer";

ws.onopen = () => sendResize();
ws.onclose = () => term.write("\r\n\x1b[31m[disconnected]\x1b[0m\r\n");

ws.onmessage = (ev) => {
  const b = new Uint8Array(ev.data);
  if (b.length < 2) return;
  const op = b[0], paneLen = b[1];
  const pane = dec.decode(b.subarray(2, 2 + paneLen));
  const payload = b.subarray(2 + paneLen);
  if (op === OP_OUTPUT) {
    lastPane = pane;
    term.write(payload);
  }
};

term.onData((d) => {
  if (ws.readyState === WebSocket.OPEN) ws.send(frame(OP_INPUT, lastPane, enc.encode(d)));
});

function sendResize() {
  if (ws.readyState !== WebSocket.OPEN) return;
  const payload = new Uint8Array(4);
  const view = new DataView(payload.buffer);
  view.setUint16(0, term.cols);
  view.setUint16(2, term.rows);
  ws.send(frame(OP_RESIZE, lastPane, payload));
}

term.onResize(sendResize);
window.addEventListener("resize", () => {
  fit.fit();
  sendResize();
});
