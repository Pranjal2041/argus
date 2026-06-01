#!/usr/bin/env python3
"""Generate Argus app-icon candidates as a PALETTE x SHAPE matrix, across
gpt-image-2 (OpenAI) and gemini-3-pro-image / Nano Banana Pro (Google).
Keys read from the repo .env. Files: {model}__{palette}__{shape}.png
Usage: python3 gen_icons.py test | all"""
import os, sys, json, base64, urllib.request, urllib.error, concurrent.futures

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "brand", "icons")
os.makedirs(OUT, exist_ok=True)

def load_env(path):
    env = {}
    for line in open(path):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    return env

ENV = load_env(os.path.join(ROOT, ".env"))
OPENAI = ENV.get("OPENAI_API_KEY", "")
GEMINI = ENV.get("GEMINI_API_KEY", "")

def openai_gen(prompt, out):
    body = json.dumps({"model": "gpt-image-2", "prompt": prompt,
                       "size": "1024x1024", "quality": "high", "output_format": "png", "n": 1}).encode()
    req = urllib.request.Request("https://api.openai.com/v1/images/generations", data=body,
                                 headers={"Authorization": f"Bearer {OPENAI}", "Content-Type": "application/json"})
    try:
        d = json.load(urllib.request.urlopen(req, timeout=300))
        open(out, "wb").write(base64.b64decode(d["data"][0]["b64_json"]))
        return f"OPENAI ok  {os.path.basename(out)}"
    except urllib.error.HTTPError as e:
        return f"OPENAI HTTP {e.code} {os.path.basename(out)}: {e.read()[:200].decode('utf-8','ignore')}"
    except Exception as e:
        return f"OPENAI err {os.path.basename(out)} {e!r}"

def gemini_gen(prompt, out):
    body = json.dumps({"contents": [{"parts": [{"text": prompt}]}],
                       "generationConfig": {"responseModalities": ["IMAGE"]}}).encode()
    url = f"https://generativelanguage.googleapis.com/v1beta/models/gemini-3-pro-image:generateContent?key={GEMINI}"
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    try:
        d = json.load(urllib.request.urlopen(req, timeout=300))
        parts = d["candidates"][0]["content"]["parts"]
        data = next((p.get("inlineData", p.get("inline_data", {})).get("data") for p in parts
                     if p.get("inlineData") or p.get("inline_data")), None)
        if not data:
            return f"GEMINI no-image {os.path.basename(out)}"
        open(out, "wb").write(base64.b64decode(data))
        return f"GEMINI ok  {os.path.basename(out)}"
    except urllib.error.HTTPError as e:
        return f"GEMINI HTTP {e.code} {os.path.basename(out)}: {e.read()[:200].decode('utf-8','ignore')}"
    except Exception as e:
        return f"GEMINI err {os.path.basename(out)} {e!r}"

SCAFFOLD = ("A flat, minimalist app icon. Full-bleed solid background, ONE centered mark, "
            "no inner rounded-rectangle, no border, no text. {shape} {palette} "
            "Bold and simple, strong geometric shape, generous negative space, 1-2 flat colors only. "
            "NO gradients, NO 3D, NO realism, NO fine detail, NO illustration. Clean vector look that "
            "stays instantly clear at 16px. Premium developer-tool aesthetic like Linear, Notion, Vercel.")

# the ONE glyph — kept deliberately spare
SHAPES = [
    ("eye", "The mark is a single, very simple eye: an almond/lens shape with a round pupil, reduced to its most essential geometric form."),
    ("eye-dot", "The mark is an extremely reduced eye — a bold lens silhouette with one solid dot as the pupil, maximum negative space."),
    ("a", "The mark is the capital letter 'A' as a bold, simple geometric monogram, in the spirit of Notion's 'N' lettermark — confident and clean."),
    ("a-eye", "The mark is a capital letter 'A' where the triangular gap inside it reads as an eye — one simple, clever lettermark."),
    ("aperture", "The mark is a simple geometric aperture / camera iris of a few clean blades that reads as a minimal abstract eye."),
]

# 1-2 colors, flat backgrounds
PALETTES = [
    ("gold-black", "A single warm gold mark on a solid black background."),
    ("ink-black", "A solid off-white mark on a solid near-black background — monochrome, one color."),
    ("blue-black", "A single electric cobalt-blue mark on a solid near-black background."),
    ("ink-light", "A solid charcoal-ink mark on a warm off-white background — a clean light-mode icon."),
]

def run_test():
    print(f"keys: openai={'set' if OPENAI else 'MISSING'} gemini={'set' if GEMINI else 'MISSING'}")
    p = SCAFFOLD.format(shape=SHAPES[0][1], palette=PALETTES[1][1])
    print(openai_gen(p, "/tmp/test-openai.png"))
    print(gemini_gen(p, "/tmp/test-gemini.png"))

def run_all():
    jobs = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as ex:
        for ci, (cslug, shape) in enumerate(SHAPES):
            for pi, (pslug, pal) in enumerate(PALETTES):
                model = "oa" if (ci + pi) % 2 == 0 else "gm"
                prompt = SCAFFOLD.format(shape=shape, palette=pal)
                out = os.path.join(OUT, f"{model}__{pslug}__{cslug}.png")
                jobs.append(ex.submit(openai_gen if model == "oa" else gemini_gen, prompt, out))
        for f in concurrent.futures.as_completed(jobs):
            print(f.result(), flush=True)

if __name__ == "__main__":
    (run_test if (len(sys.argv) > 1 and sys.argv[1] == "test") else run_all)()
