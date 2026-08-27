#!/usr/bin/env python3
"""One strict-UTF-8 JSON object describing a pommerman replay.

Python 3 standard library ONLY -- no Nim, no Docker, no dependencies -- so a
spectator, a CI step or a phase-60 check can read a hosted replay with nothing
but curl and python3:

    curl -sSL "$replay_url" -o /tmp/ep.replay
    python3 tools/replay_summary.py /tmp/ep.replay > /tmp/ep.json
    jq -e . /tmp/ep.json >/dev/null                       # strict JSON: ok
    jq -r '.protocol, .results.reason, .results.teamKills[0]' /tmp/ep.json
    jq -r '[.orders[]|select(.source=="llm")]|length, .fallbacks' /tmp/ep.json
    jq -r '[.radio[]|select(.a!=1 or .b!=1)]|length' /tmp/ep.json

The replay is the binary COWLDPOM format the static wasm viewer parses. This
tool is the JSON VIEW of the same bytes: it reads the header, brace-matches the
resolved config JSON, and decodes the chat records. Every string in the file was
truncated on a RUNE boundary by the writer, so the output decodes as strict
UTF-8 with no lone surrogates -- which `tests/test_pom_replay.nim` asserts with
4-byte emoji sitting exactly on every cap.
"""

import json
import struct
import sys

MAGIC = b"COWLDPOM"
FORMAT_VERSION = 1

RK_JOIN = 1
RK_LEAVE = 2
RK_GAME_START = 3
RK_ORDER = 4
RK_CHAT = 5
RK_HASH = 6
RK_STOP = 7

ORDER_KINDS = ["go", "bomb", "hunt", "break", "hide", "kick", "follow"]
DIR_NAMES = ["up", "down", "left", "right"]
ALIASES = ["RED-1", "BLUE-1", "RED-2", "BLUE-2"]


class Reader:
    def __init__(self, data: bytes):
        self.data = data
        self.pos = 0

    def need(self, count: int) -> None:
        if self.pos + count > len(self.data):
            raise SystemExit(f"replay truncated at byte {self.pos}")

    def u8(self) -> int:
        self.need(1)
        value = self.data[self.pos]
        self.pos += 1
        return value

    def u16(self) -> int:
        self.need(2)
        value = struct.unpack_from("<H", self.data, self.pos)[0]
        self.pos += 2
        return value

    def u32(self) -> int:
        self.need(4)
        value = struct.unpack_from("<I", self.data, self.pos)[0]
        self.pos += 4
        return value

    def u64(self) -> int:
        self.need(8)
        value = struct.unpack_from("<Q", self.data, self.pos)[0]
        self.pos += 8
        return value

    def text(self) -> str:
        length = self.u32()
        self.need(length)
        raw = self.data[self.pos:self.pos + length]
        self.pos += length
        # STRICT: a byte-truncated codepoint raises here rather than being
        # smuggled out as a replacement character or a lone surrogate.
        return raw.decode("utf-8")


def brace_match(text: str, start: int) -> str:
    """The balanced {...} beginning at `start` -- the technique the starter's
    AGENTS.md documents for prod forensics, used here for the config JSON."""
    depth = 0
    in_string = False
    escaped = False
    for i in range(start, len(text)):
        ch = text[i]
        if in_string:
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
    raise SystemExit("unbalanced config JSON in the replay header")


def summarize(path: str) -> dict:
    data = open(path, "rb").read()
    if not data.startswith(MAGIC):
        raise SystemExit(f"{path} is not a {MAGIC.decode()} replay")
    reader = Reader(data)
    reader.pos = len(MAGIC)
    version = reader.u16()
    if version != FORMAT_VERSION:
        raise SystemExit(f"replay format {version} is not {FORMAT_VERSION}")
    game_name = reader.text()
    game_version = reader.text()
    config_text = reader.text()
    config = json.loads(brace_match(config_text, config_text.index("{")))

    joins = []
    orders = []
    radio = []
    chats = []
    hashes = 0
    stops = []
    game_starts = []
    while reader.pos < len(data):
        kind = reader.u8()
        if kind == RK_JOIN:
            tick, slot = reader.u32(), reader.u16()
            joins.append({"tick": tick, "slot": slot,
                          "name": reader.text(), "token": reader.text()})
        elif kind == RK_LEAVE:
            reader.u32()
            reader.u16()
        elif kind == RK_GAME_START:
            game_starts.append({"tick": reader.u32(),
                                "game": reader.u8() + 1})
        elif kind == RK_ORDER:
            tick = reader.u32()
            turn = reader.u16()
            slot = reader.u8()
            verb = ORDER_KINDS[reader.u8()]
            x, y = reader.u8(), reader.u8()
            target = reader.u8() - 1
            direction = reader.u8() - 1
            a, b = reader.u8(), reader.u8()
            entry = {"tick": tick, "turn": turn, "slot": slot,
                     "alias": ALIASES[slot] if slot < len(ALIASES) else "?",
                     "verb": verb}
            if verb == "go":
                entry["x"], entry["y"] = x, y
            elif verb == "hunt":
                entry["target"] = (ALIASES[target]
                                   if 0 <= target < len(ALIASES) else None)
            elif verb == "kick":
                entry["dir"] = (DIR_NAMES[direction]
                                if 0 <= direction < len(DIR_NAMES) else None)
            orders.append(entry)
            radio.append({"turn": turn, "slot": slot, "a": a, "b": b})
        elif kind == RK_CHAT:
            tick, slot = reader.u32(), reader.u16()
            chats.append({"tick": tick, "slot": slot, "text": reader.text()})
        elif kind == RK_HASH:
            reader.u32()
            reader.u64()
            hashes += 1
        elif kind == RK_STOP:
            stops.append({"tick": reader.u32(), "endRule": reader.text()})
        else:
            raise SystemExit(f"unknown replay record {kind} "
                             f"at byte {reader.pos - 1}")

    directives = []
    fallbacks = 0
    registers = []
    results = {}
    by_turn_slot = {}
    for chat in chats:
        text = chat["text"]
        if not text.startswith("{"):
            continue
        try:
            node = json.loads(text)
        except json.JSONDecodeError:
            continue
        kind = node.get("k")
        if kind == "directive":
            entry = {
                "turn": node.get("turn"),
                "slot": node.get("slot"),
                "alias": node.get("alias"),
                "team": node.get("team"),
                "source": node.get("source"),
                "latency_ms": node.get("latency_ms"),
                "verb": node.get("verb"),
                "arg": node.get("arg"),
                "radio": node.get("radio"),
                "radio_in": node.get("radio_in"),
                "say": node.get("say", ""),
            }
            directives.append(entry)
            by_turn_slot[(entry["turn"], entry["slot"])] = entry["source"]
        elif kind == "fallback":
            fallbacks += 1
        elif kind == "register":
            registers.append({"slot": node.get("slot"),
                              "alias": node.get("alias"),
                              "team": node.get("team"),
                              "policy": node.get("policy"),
                              "kind": node.get("kind"),
                              "baseline": node.get("baseline")})
        elif kind == "result":
            results = node.get("results", {})

    # `source` rides on the directive record, so mirror it onto the order log:
    # the phase-60 check filters `.orders[]|select(.source=="llm")`.
    for entry in orders:
        entry["source"] = by_turn_slot.get((entry["turn"], entry["slot"]),
                                           "scripted")

    return {
        "protocol": config.get("protocol", "pommerman/v1"),
        "game": game_name,
        "gameVersion": game_version,
        "seed": config.get("seed"),
        "boardSize": config.get("boardSize"),
        "names": results.get("names") or [join["name"] for join in joins],
        "aliases": results.get("aliases", ALIASES),
        "teams": results.get("teams", []),
        "policyKinds": results.get("policyKinds",
                                   [r["kind"] for r in registers]),
        "tickCount": hashes,
        "gameStarts": game_starts,
        "stops": stops,
        "registrations": registers,
        "orders": orders,
        "radio": radio,
        "directives": directives,
        "fallbacks": fallbacks,
        "results": results,
        "config": config,
    }


def main(argv: list) -> int:
    if len(argv) != 2:
        print(f"usage: {argv[0]} <replay path>", file=sys.stderr)
        return 2
    summary = summarize(argv[1])
    # ensure_ascii=False keeps the real UTF-8 bytes, so the output is a genuine
    # strict-UTF-8 test of what the writer produced rather than an escaped copy.
    sys.stdout.write(json.dumps(summary, ensure_ascii=False) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
