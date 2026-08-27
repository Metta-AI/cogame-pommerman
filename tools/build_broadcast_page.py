#!/usr/bin/env python3
"""Build client/replay_broadcast.html from the coworld-ctf starter page.

This script IS the provenance record for the fork. It takes the starter's page
byte for byte, deletes exactly the elements and CSS rules the design note lists
as removed, re-maps the paintbot vocabulary the design note's table names, swaps
the page IIFE for the pommerman fork of it, and appends the POMMERMAN game block
under its banner comment. Re-running it against the same starter reproduces the
committed file, so a reviewer can see what was changed rather than diffing 4,700
lines of rewritten page.

    python3 tools/build_broadcast_page.py \
        --starter /workspace/starters/coworld-ctf/client/replay_broadcast.html \
        --page-script client/page_script.js \
        --game-block client/game_block.html \
        --out client/replay_broadcast.html
"""

import argparse
import re
import sys

# Exactly the selectors the design note removes: all of #viewpanel (the board is
# a fixed 11x11 grid with a 1:1 aspect and no off-frame area, so zoom and the
# minimap have nothing to do), the whole first-person PIP, the POV badge, the
# ctf scorebug internals, the beat kinds this game never emits, and the
# perk / handicap badges.
REMOVED_SELECTORS = [
    "#viewpanel", "#minimap", "#minimap-canvas", "#zoombar", "#zoom-in",
    "#zoom-out", "#zoom-slider", "#zoom-read", ".zbtn", ".mm-cap",
    "#fpv", ".fpv", "#povBadge",
    ".hillchip", ".hcap", ".flagicon", ".lives-num", ".lives-label",
    ".squad-pip", ".pb-tags", ".squad", ".ec-heart",
    ".beat-marker.steal", ".beat-marker.return", ".beat-marker.capture",
    ".beat-marker.hillflip", ".beat-marker.hillhold", ".beat-marker.tagout",
    ".beat-marker.gamestart", ".beat-marker.kill", ".beat-marker.gameover",
    ".perk-ico", ".perk-icos", ".pgrp",
    "flagflip", "flagkill", ".pb-lbl", ".paint", "paintpip",
]

# Body markup deletions, as (first line, last line) anchors taken verbatim from
# the starter so a starter edit fails loudly instead of silently mis-cutting.
BODY_CUTS = [
    # all of #viewpanel (zoom bar + minimap)
    ("    <!-- View controls: zoom the board with buttons/slider/keys/pinch",
     "    <div id=\"mmwarn\">"),
    # the whole first-person picture-in-picture
    ("    <!-- First-person picture-in-picture:",
     "    <div id=\"bannerlane\"></div>"),
]

BODY_LINE_CUTS = [
    # #povBadge -- there is no per-bomber point of view worth showing here; the
    # whole board is the shot.
    'id="povBadge"',
]

BANNER = """<!-- ============================================================
     POMMERMAN additions to the inherited coworld-ctf chrome
     ============================================================
     Everything above this banner is the coworld-ctf broadcast page. Its CSS,
     markup, relayout(), transport wiring, endcard shell, locker-room curtain,
     ?embed=1 mode and .tiny density system are the starter's; the elements the
     design note lists as removed (all of #viewpanel -- the board is a fixed
     11x11 grid with a 1:1 aspect and ~32 px a cell at the 360 px embed, so
     zoom and the minimap have nothing to do -- the whole #fpv first-person
     PIP, #povBadge, the ctf scorebug internals, the beat kinds this game never
     emits, and the perk/handicap badges) are deleted rather than disabled, and
     the endcard/chrome vocabulary is re-mapped off paintbot's (Lives ->
     Bombers left, LIVES LEAD -> BOMBERS STANDING, Player/K/D/Clstr/Cap ->
     Bomber/Kills/Bombs/Wood/Radio, and so on).

     Nothing here touches the transport band. relayout() still owns --hudscale,
     --topband and --band on :root; the endcard still stops at
     bottom: var(--band, 0px) and is still dismissed by every seek; and every
     scrubber beat this block draws is a LABELLED, CLICKABLE BUTTON that seeks
     on click, styled for EVERY kind the sim emits and no others -- firstblood,
     kick, death, collapse, fallback, end. The builder is called pomBeat
     precisely so it can never be shadowed by the chrome alias block's own
     hoisted declaration of markBeat (cogame-tandem, 2026-08-23).
     ============================================================ -->"""

# The design note's re-mapping table, left column -> right column. A forked ctf
# page otherwise silently ships paintbot's vocabulary: nothing in the starter's
# tests, in viewer_smoke.mjs or in the label manifest covers spectator chrome
# STRINGS, because labels.nim deliberately scopes itself to the policy contract.
# tests/test_pom_endcard_labels.nim enforces both halves -- zero forbidden
# words, and each replacement present exactly once.
RELABEL = [
    ("<title>Ctf \u2014 Broadcast Replay</title>",
     "<title>Pommerman \u2014 Broadcast Replay</title>"),
    ('<span class="momentum-label">LIVES LEAD</span>',
     '<span class="momentum-label">BOMBERS STANDING</span>'),
    ('<div id="mmwarn">Replay hash mismatch \u2014 showing recorded inputs</div>',
     '<div id="mmwarn">Replay hash mismatch \u2014 showing recorded orders</div>'),
    ('Filling hoppers with fresh paint&hellip;', 'Lighting the fuses&hellip;'),
    ('>In the locker room<', '>Taking corners<'),
    ('Bot locker room &middot; Loading replay',
     'Bomber ready room &middot; Loading replay'),
    ('title="Spoilers: kills / flag story / winner on the timeline ahead of the playhead (o)"',
     'title="Spoilers: kills / collapses / winner on the timeline ahead of the playhead (o)"'),
]


def split_top_level(css: str):
    """Yield brace-depth-0 chunks of a stylesheet."""
    chunks = []
    depth = 0
    start = 0
    i = 0
    while i < len(css):
        ch = css[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                chunks.append(css[start:i + 1])
                start = i + 1
        i += 1
    if start < len(css):
        chunks.append(css[start:])
    return chunks


def selector_of(chunk: str) -> str:
    at = chunk.find("{")
    return chunk[:at] if at >= 0 else ""


def strip_comments(text: str) -> str:
    return re.sub(r"/\*.*?\*/", "", text, flags=re.S)


def selector_is_removed(selector: str) -> bool:
    selector = strip_comments(selector)
    for part in selector.split(","):
        part = part.strip()
        if not part:
            continue
        for removed in REMOVED_SELECTORS:
            if removed in part:
                return True
    return False


def filter_css(css: str) -> str:
    out = []
    for chunk in split_top_level(css):
        selector = selector_of(chunk).strip()
        if selector.startswith("@media") or selector.startswith("@supports"):
            head, _, body = chunk.partition("{")
            inner = body.rstrip()
            assert inner.endswith("}"), selector
            inner = inner[:-1]
            kept = [c for c in split_top_level(inner)
                    if not selector_is_removed(selector_of(c))]
            if not [c for c in kept if selector_of(c).strip()]:
                continue
            out.append(head + "{" + "".join(kept) + "}")
            continue
        if selector_is_removed(selector):
            continue
        out.append(chunk)
    return "".join(out)


def cut(text: str, start_anchor: str, end_anchor: str) -> str:
    start = text.index(start_anchor)
    end = text.index(end_anchor, start)
    return text[:start] + text[end:]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--starter", required=True)
    parser.add_argument("--page-script", required=True)
    parser.add_argument("--game-block", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()

    page = open(args.starter, encoding="utf-8").read()

    # 1. CSS: drop the removed elements' rules.
    css_open = page.index("<style>")
    css_close = page.index("</style>", css_open)
    css = page[css_open + len("<style>"):css_close]
    page = page[:css_open + len("<style>")] + filter_css(css) + page[css_close:]

    # 2. Body markup: drop the removed elements.
    for start_anchor, end_anchor in BODY_CUTS:
        page = cut(page, start_anchor, end_anchor)
    for needle in BODY_LINE_CUTS:
        page = "\n".join(
            line for line in page.split("\n") if needle not in line)

    # 3. The endcard / chrome label re-mapping.
    for before, after in RELABEL:
        if before not in page:
            print(f"error: relabel source string not found: {before[:60]}",
                  file=sys.stderr)
            return 1
        page = page.replace(before, after)

    # 4. The page IIFE and everything after it: the pommerman fork plus the
    #    appended game block.
    script_open = page.index("<script>", page.index("<!-- BROADCAST_CORE -->"))
    page = page[:script_open]
    page += "<script>\n"
    page += open(args.page_script, encoding="utf-8").read().rstrip() + "\n"
    page += "</script>\n"
    page += BANNER + "\n"
    page += open(args.game_block, encoding="utf-8").read().rstrip() + "\n"
    page += "</body>\n</html>\n"

    # The residue check ignores CSS and HTML comments: a removed rule's own
    # explanatory comment goes with it (the chunk carries it), and any remaining
    # mention is prose in the inherited page's commentary.
    bare = re.sub(r"<!--.*?-->", "", strip_comments(page), flags=re.S)
    styles = "".join(re.findall(r"<style>(.*?)</style>", bare, flags=re.S))
    bad = [r for r in REMOVED_SELECTORS if r.startswith("#") and r in bare]
    bad += [r for r in REMOVED_SELECTORS
            if r.startswith(".") and r in styles]
    if bad:
        for removed in bad:
            haystack = bare if removed.startswith("#") else styles
            at = haystack.index(removed)
            print(f"error: removed selector still present: {removed}: "
                  f"...{haystack[max(0, at - 90):at + 60]}...", file=sys.stderr)
        return 1

    open(args.out, "w", encoding="utf-8").write(page)
    print(f"wrote {args.out} ({len(page)} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
