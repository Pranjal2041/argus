#!/usr/bin/env python3
"""Browser-level regression and visual artifact check for Argus Renders."""

import argparse
import json
import re
import urllib.parse
import urllib.error
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

TERMINAL_TABLE_SOURCE = """# Challenge audit

 Requirement                   Result
 ────────────────────────────  ─────────────────────────────────────────────
 Camera configuration          Pass. Camera settings are unrestricted.
                               Organizer forum ruling applies.
 ────────────────────────────  ─────────────────────────────────────────────
 Controller/action space       Pass. No published restriction.
 ────────────────────────────  ─────────────────────────────────────────────

Old document (https://github.com/example/vlnverse_emr/blob/main/README.md).
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


def terminal_table_document() -> dict:
    default = 0
    green = 1
    rule = 2

    def run(text: str, style: int = default) -> dict:
        return {"text": text, "style": style, "link": None}

    def line(*runs: dict) -> dict:
        return {"runs": list(runs), "wrapped": False}

    def style(foreground: str, bold: bool = False) -> dict:
        return {
            "foreground": foreground,
            "background": "#11131A",
            "bold": bold,
            "italic": False,
            "underline": None,
            "underlineColor": None,
            "strikethrough": False,
        }

    return {
        "id": "00000000-0000-0000-0000-000000000002",
        "source": TERMINAL_TABLE_SOURCE,
        "sourceOrigin": "terminal",
        "terminal": {
            "columns": 92,
            "fontFamily": "SF Mono",
            "background": "#11131A",
            "foreground": "#E8E9EE",
            "styles": [style("#E8E9EE"), style("#35C46A", True), style("#6E7681")],
            "lines": [
                line(run("# Challenge audit")),
                line(),
                line(run(" Requirement                   Result")),
                line(run(" ────────────────────────────  ─────────────────────────────────────────────", rule)),
                line(run(" Camera configuration          "), run("Pass", green),
                     run(". Camera settings are unrestricted.")),
                line(run("                               Organizer forum ruling applies.")),
                line(run(" ────────────────────────────  ─────────────────────────────────────────────", rule)),
                line(run(" Controller/action space       "), run("Pass", green),
                     run(". No published restriction.")),
                line(run(" ────────────────────────────  ─────────────────────────────────────────────", rule)),
                line(),
                line(run("Old document (https://github.com/example/vlnverse_emr/blob/main/README.md).")),
            ],
        },
    }


def contaminated_transcript_document() -> dict:
    default = 0
    yellow = 1
    stale_green = 2
    stale_purple = 3
    genuine_green = 4

    def run(text: str, style: int = default) -> dict:
        return {"text": text, "style": style, "link": None}

    def line(*runs: dict) -> dict:
        return {"runs": list(runs), "wrapped": False}

    def style(foreground: str, background: str = "#11131A", bold: bool = False) -> dict:
        return {
            "foreground": foreground,
            "background": background,
            "bold": bold,
            "italic": False,
            "underline": None,
            "underlineColor": None,
            "strikethrough": False,
        }

    source = """Measured uniformly using the emitted reasoning prefix—not hidden model internals:

| Model/mode | Raw coverage | Mean CoT/action |
|---|---:|---:|
| Dense2305 full | 128/128 | **104.89** |
| Router-trained Step900 router | 128/128 | **68.36** |
| No-router Stage B step900 full | 128/128 | **89.86** |
| Router-trained Step900 full | 128/128 | **70.31** |

Main observations follow.
"""
    return {
        "id": "00000000-0000-0000-0000-000000000004",
        "source": source,
        "sourceOrigin": "codex-transcript",
        "terminal": {
            "columns": 78,
            "fontFamily": "SF Mono",
            "background": "#11131A",
            "foreground": "#E8E9EE",
            "styles": [
                style("#E8E9EE"),
                style("#F1D18A", bold=True),
                style("#AAB2BD", background="#31443A"),
                style("#AAB2BD", background="#513040"),
                style("#35C46A", bold=True),
            ],
            "lines": [
                line(run("Main "), run("observations", stale_green), run(" follow.")),
                line(),
                line(run("Edited report: "), run("reason", stale_green), run(" "),
                     run("router", stale_green), run(" "), run("68", stale_green),
                     run(" "), run("66", stale_purple), run(" "), run("full", stale_green)),
                line(),
                line(run("Measured uniformly using the emitted reasoning prefix—not hidden model internals:")),
                line(),
                line(run(" Model/mode", yellow), run(" " * 22),
                     run("Raw coverage", yellow), run("    "), run("Mean CoT/action", yellow)),
                line(run(" ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━━")),
                line(run(" Dense2305 full                   128/128         104.89")),
                line(run(" ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━━")),
                line(run(" Router-                          128/128         "),
                     run("68.36", genuine_green)),
                line(run(" trained")),
                line(run(" Step900")),
                line(run(" router")),
                line(run(" ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━━")),
                line(run(" No-router Stage B step900 full  128/128         89.86")),
                line(run(" ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━━")),
                line(run(" Router-trained Step900 full     128/128         70.31")),
                line(run(" ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━  ━━━━━━━━━━━━━━━")),
                line(),
                line(run("Main observations follow.")),
            ],
        },
    }


def endpoint_source(endpoint: str, session: str) -> tuple[str, str]:
    query = urllib.parse.urlencode({"session": session})
    with urllib.request.urlopen(f"{endpoint.rstrip('/')}/render-source?{query}", timeout=10) as response:
        payload = json.load(response)
    return payload["source"], payload["origin"]


def recent_terminal_document(endpoint: str, session: str) -> dict:
    query = urllib.parse.urlencode({"session": session, "lines": 600})
    with urllib.request.urlopen(f"{endpoint.rstrip('/')}/recent?{query}", timeout=10) as response:
        source = response.read().decode("utf-8")
    base_style = {
        "foreground": "#E8E9EE",
        "background": "#11131A",
        "bold": False,
        "italic": False,
        "underline": None,
        "underlineColor": None,
        "strikethrough": False,
    }
    return {
        "id": "00000000-0000-0000-0000-000000000003",
        "source": source,
        "sourceOrigin": "terminal",
        "terminal": {
            "columns": max((len(line) for line in source.splitlines()), default=1),
            "fontFamily": "SF Mono",
            "background": "#11131A",
            "foreground": "#E8E9EE",
            "styles": [base_style],
            "lines": [
                {
                    "runs": ([{"text": line, "style": 0, "link": None}] if line else []),
                    "wrapped": False,
                }
                for line in source.splitlines()
            ],
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--endpoint", help="broker base URL for a real transcript-backed render")
    parser.add_argument("--session", help="session used with --endpoint")
    parser.add_argument("--output-dir", default="tmp/pdfs")
    args = parser.parse_args()

    active_document = document(FIXTURE, "codex-transcript")
    if args.endpoint:
        if not args.session:
            parser.error("--session is required with --endpoint")
        try:
            source, origin = endpoint_source(args.endpoint, args.session)
            active_document = document(source, origin)
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
            active_document = recent_terminal_document(args.endpoint, args.session)
    source = active_document["source"]

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
        page.evaluate("([doc]) => window.UTRender.setDocument(doc, 16, 'rendered')", [active_document])
        report = page.evaluate("window.UTRender.inspect()")

        assert report["error"] is None, report["error"]
        if re.search(r"(?m)^\s*#{1,6}\s+", source):
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
            assert report["verbatimBlocks"] + report["terminalTables"] >= 1
        assert not console_errors, console_errors

        page.screenshot(path=str(output_dir / "rendered-output.png"), full_page=True)
        page.pdf(path=str(output_dir / "rendered-output.pdf"), print_background=True,
                 width="1180px", height=f"{max(900, page.evaluate('document.documentElement.scrollHeight'))}px")

        page.evaluate("([doc]) => window.UTRender.setDocument(doc, 16, 'rendered')",
                      [terminal_table_document()])
        table_report = page.evaluate("window.UTRender.inspect()")
        assert table_report["error"] is None, table_report["error"]
        assert table_report["terminalTables"] == 1
        assert table_report["terminalTableRows"] == 3
        assert table_report["verbatimBlocks"] == 0
        assert table_report["inlineMath"] == 0
        assert table_report["links"] == 1
        pass_color = page.locator('table.terminal-table [data-terminal-style="1"]').first.evaluate(
            "element => getComputedStyle(element).color")
        assert pass_color != "rgb(31, 35, 40)", pass_color
        page.screenshot(path=str(output_dir / "borderless-table-rendered.png"), full_page=True)

        contaminated = contaminated_transcript_document()
        page.evaluate("([doc]) => window.UTRender.setDocument(doc, 16, 'rendered')", [contaminated])
        contaminated_report = page.evaluate("window.UTRender.inspect()")
        assert contaminated_report["error"] is None, contaminated_report["error"]
        assert contaminated_report["tables"] == 1
        assert page.locator('.terminal-accent[style*="background-color"]').count() == 0
        assert page.locator('th [data-terminal-style="1"]').count() == 3
        assert page.locator('td [data-terminal-style="4"]').text_content() == "68.36"
        page.screenshot(path=str(output_dir / "context-aligned-colors.png"), full_page=True)

        page.evaluate("([doc]) => window.UTRender.setDocument(doc, 16, 'terminal')", [active_document])
        terminal = page.evaluate("window.UTRender.inspect()")
        assert terminal["terminalRows"] == len(active_document["terminal"]["lines"])
        assert terminal["headings"] == 0
        page.screenshot(path=str(output_dir / "terminal-fallback.png"), full_page=True)
        browser.close()

    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
