#!/usr/bin/env python3
"""Browser-level regression and visual artifact check for Argus Renders."""

import argparse
import json
import re
import urllib.parse
import urllib.request
from pathlib import Path

from playwright.sync_api import sync_playwright


FIXTURE = r"""# Analysis

The inline result is \(x^2 + y^2\), and the display result is:

\[
R_{\rm TP}=D_{\rm KL}(p^*\Vert p)-D_{\rm KL}(p^*\Vert q_{c,\lambda}).
\]

| Condition | Exact |
|---|---:|
| Gold answer | **0.42** |

See [the local report](/Users/example/project_with_underscores/report.pdf).

```swift
let answer = 42
```

┌──────┬──────┐
│ left │ right│
└──────┴──────┘
"""


def document(source: str, origin: str) -> dict:
    return {
        "id": "00000000-0000-0000-0000-000000000001",
        "source": source,
        "sourceOrigin": origin,
        "terminal": {
            "columns": 24,
            "fontFamily": "SF Mono",
            "background": "#11131A",
            "foreground": "#E8E9EE",
            "styles": [{
                "foreground": "#0A78F0",
                "background": "#11131A",
                "bold": True,
                "italic": False,
                "underline": None,
                "underlineColor": None,
                "strikethrough": False,
            }],
            "lines": [
                {"runs": [{"text": "ANSI heading", "style": 0, "link": None}], "wrapped": False},
                {"runs": [{"text": "└─ exact table", "style": 0, "link": None}], "wrapped": False},
            ],
        },
    }


def endpoint_source(endpoint: str, session: str) -> tuple[str, str]:
    query = urllib.parse.urlencode({"session": session})
    with urllib.request.urlopen(f"{endpoint.rstrip('/')}/render-source?{query}", timeout=10) as response:
        payload = json.load(response)
    return payload["source"], payload["origin"]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", help="broker base URL for a real transcript-backed render")
    parser.add_argument("--session", help="session used with --endpoint")
    parser.add_argument("--output-dir", default="tmp/pdfs")
    args = parser.parse_args()

    source, origin = FIXTURE, "codex-transcript"
    if args.endpoint:
        if not args.session:
            parser.error("--session is required with --endpoint")
        source, origin = endpoint_source(args.endpoint, args.session)

    render_dir = Path(__file__).resolve().parents[1] / "Resources" / "render"
    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    console_errors: list[str] = []

    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=True)
        page = browser.new_page(viewport={"width": 1180, "height": 900})
        page.on("console", lambda msg: console_errors.append(msg.text) if msg.type == "error" else None)
        page.goto((render_dir / "index.html").as_uri())
        page.wait_for_load_state("networkidle")
        page.evaluate("([doc]) => window.UTRender.setDocument(doc, 16, 'rendered')", [document(source, origin)])
        report = page.evaluate("window.UTRender.inspect()")

        assert report["error"] is None, report["error"]
        assert report["headings"] >= 1
        if re.search(r"(?m)^\s*\|.+\|\s*$", source):
            assert report["tables"] >= 1
        if "```" in source or "~~~" in source:
            assert report["codeBlocks"] >= 1 and report["highlightedCode"] >= 1
        if "\\[" in source or "$$" in source:
            assert report["displayMath"] >= 1
        if "\\(" in source or re.search(r"\$[^$\n]+\$", source):
            assert report["inlineMath"] >= 1
        if re.search(r"\[[^\]]+\]\([^)]+\)", source):
            assert report["links"] >= 1
        if any(char in source for char in "┌┐└┘─│"):
            assert report["verbatimBlocks"] >= 1
        assert not console_errors, console_errors

        page.screenshot(path=str(output_dir / "rendered-output.png"), full_page=True)
        page.pdf(path=str(output_dir / "rendered-output.pdf"), print_background=True,
                 width="1180px", height=f"{max(900, page.evaluate('document.documentElement.scrollHeight'))}px")

        page.evaluate("([doc]) => window.UTRender.setDocument(doc, 16, 'terminal')", [document(source, origin)])
        terminal = page.evaluate("window.UTRender.inspect()")
        assert terminal["terminalRows"] == 2
        assert terminal["headings"] == 0
        page.screenshot(path=str(output_dir / "terminal-fallback.png"), full_page=True)
        browser.close()

    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
