#!/usr/bin/env python3
"""Scan brand/icons/*.png ({model}__{palette}__{shape}.png) and emit
brand/icons/index.html — a dark dashboard grouping each shape across all
palettes (click-to-zoom + small-size legibility)."""
import os, glob, html

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONS = os.path.join(ROOT, "brand", "icons")
files = sorted(os.path.basename(f) for f in glob.glob(os.path.join(ICONS, "*.png")))

MODEL = {"oa": "gpt-image-2", "gm": "Nano Banana Pro"}
PAL_ORDER = ["gold-black", "ink-black", "blue-black", "ink-light",
             "peacock", "gold-noir", "ink-mono", "cobalt", "emerald", "ember", "chrome", "daylight"]

shapes = {}  # shape -> {palette: (model, file)}
for f in files:
    parts = f[:-4].split("__")
    if len(parts) == 3:
        model, pal, shape = parts
    else:
        model, pal, shape = "", "?", f[:-4]
    shapes.setdefault(shape, {})[pal] = (model, f)

def pal_key(p):
    return PAL_ORDER.index(p) if p in PAL_ORDER else 99

cards = []
for shape in sorted(shapes):
    cells = ""
    for pal, (model, f) in sorted(shapes[shape].items(), key=lambda kv: pal_key(kv[0])):
        cells += f"""
        <figure class="variant">
          <img class="hero" src="{f}" loading="lazy" onclick="zoom('{f}')"/>
          <figcaption><b>{html.escape(pal)}</b> · {html.escape(MODEL.get(model, model))}</figcaption>
          <div class="sizes">
            <img src="{f}" style="width:48px;height:48px"/>
            <img src="{f}" style="width:24px;height:24px"/>
            <img src="{f}" style="width:16px;height:16px"/>
          </div>
        </figure>"""
    cards.append(f'<section class="card"><h2>{html.escape(shape)}</h2><div class="variants">{cells}</div></section>')

doc = f"""<!doctype html><html><head><meta charset="utf-8"><title>Argus — icon candidates</title>
<style>
  :root {{ --tile: 180px; }}
  * {{ box-sizing:border-box; }}
  body {{ margin:0; background:#0B0D12; color:#E6E9F5; font:14px/1.4 -apple-system,SF Pro,Segoe UI,Roboto,sans-serif; }}
  header {{ position:sticky; top:0; z-index:5; background:rgba(11,13,18,.92); backdrop-filter:blur(8px);
            border-bottom:1px solid rgba(255,255,255,.08); padding:14px 22px; display:flex; align-items:center; gap:18px; }}
  header h1 {{ font-size:17px; font-weight:700; margin:0; letter-spacing:.3px; }}
  header .sub {{ color:#9AA5CE; font-size:12px; }} .spacer {{ flex:1; }}
  header label {{ color:#9AA5CE; font-size:12px; display:flex; align-items:center; gap:8px; }}
  .card {{ margin:22px; background:#111219; border:1px solid rgba(255,255,255,.07); border-radius:14px; padding:16px; }}
  .card h2 {{ margin:0 0 14px; font-size:14px; font-weight:600; color:#AEB6E0; font-family:ui-monospace,Menlo,monospace; }}
  .variants {{ display:grid; grid-template-columns:repeat(auto-fill,minmax(var(--tile),1fr)); gap:16px; }}
  .variant {{ margin:0; }}
  .variant .hero {{ width:100%; aspect-ratio:1; object-fit:contain; border-radius:12px; background:#000;
                    border:1px solid rgba(255,255,255,.06); cursor:zoom-in; display:block; }}
  .variant figcaption {{ color:#9AA5CE; font-size:11px; margin-top:6px; }}
  .variant figcaption b {{ color:#E6E9F5; }}
  .sizes {{ display:flex; align-items:flex-end; gap:9px; margin-top:7px; padding:5px 8px; background:#000;
            border:1px solid rgba(255,255,255,.05); border-radius:8px; }}
  #lb {{ position:fixed; inset:0; background:rgba(0,0,0,.88); display:none; align-items:center; justify-content:center; z-index:50; cursor:zoom-out; }}
  #lb img {{ max-width:88vw; max-height:88vh; border-radius:16px; }}
</style></head>
<body>
<header><h1>Argus</h1>
  <span class="sub">{len(files)} candidates · shape × palette · click to zoom · tiny previews = legibility</span>
  <span class="spacer"></span>
  <label>size <input type="range" min="120" max="320" value="180"
    oninput="document.documentElement.style.setProperty('--tile', this.value+'px')"></label>
</header>
{''.join(cards)}
<div id="lb" onclick="this.style.display='none'"><img id="lbimg"></div>
<script>
  function zoom(s) {{ document.getElementById('lbimg').src=s; document.getElementById('lb').style.display='flex'; }}
  document.addEventListener('keydown', e => {{ if(e.key==='Escape') document.getElementById('lb').style.display='none'; }});
</script></body></html>"""

open(os.path.join(ICONS, "index.html"), "w").write(doc)
print(f"wrote index.html ({len(files)} icons, {len(shapes)} shapes)")
