# Protocol

The Coworld contract this game speaks, unchanged in shape from `coworld-ctf`.

## Environment

| Variable | Direction | Meaning |
|---|---|---|
| `COGAME_CONFIG_URI` | in | the resolved `game_config` JSON (also accepted inline) |
| `COGAME_RESULTS_URI` | out | the results document, written once at episode end |
| `COGAME_SAVE_REPLAY_URI` | out | the binary `COWLDPOM` replay |
| `COGAME_PLAYER_FAILURE_URI` | out | the platform's **closed** payload, exactly `{"message", "failed_policy_index"}` |
| `COGAME_EVENTS_URI` | out | the tier-2 JSON-lines analysis stream (`file://` only) |
| `COGAME_LOAD_REPLAY_URI` | in | local replay mode |
| `HOST`, `PORT` | in | where to listen (default `0.0.0.0:8080`) |
| `ANTHROPIC_API_KEY_URI` | in | `secret://coworld/pommerman/anthropic_api_key`, injected into the **game** pod |
| `COWORLD_PLAYER_WS_URL` | in (player) | the seat socket; legacy alias `COGAMES_ENGINE_WS_URL` |
| `PLAYER_PROMPT` | in (player) | a strategy in plain English — this seat is an LLM seat |
| `PLAYER_SCRIPTED` | in (player) | `sapper` \| `camper` — this seat is scripted |
| `PLAYER_POLICY_LABEL` | in (player) | a free label for the replay's `register` record |

## Routes

| Route | What it is |
|---|---|
| `GET /healthz` | the runner's liveness probe |
| `WS /player?slot=<i>&token=<t>` | one seat; token-checked against the roster |
| `WS /global` | the spectator status feed; the certifier pings it **after** the player pods start |
| `GET /client/player?slot&token` | a real, token-checked **page**; it must NOT open the player socket |
| `GET /client/global` | a real page |
| `GET /client/replay` | the developer-local broadcast page, never declared to the platform |
| `GET /client/*` | fonts and board art |
| `GET /replay-data` | the recorded bytes, for local tooling |

Both `/client/` routes are registered **before** any catch-all asset route. `/healthz` and
`/global` keep answering for a bounded 20 s grace after the artifacts are written, then the
process exits.

## The seat socket

A seat connects, sends **one Sprite v1 chat message** carrying its registration, and then only
acknowledges frames. Nothing else it sends is applied: bombers speak through `say`, seats do not
shout.

```json
{"policy": "<label>", "prompt": "<PLAYER_PROMPT or empty>", "scripted": "sapper"|"camper"|null}
```

`prompt` is rune-truncated at 4000 runes and `policy` at 48. The registration is **re-sent** for
the first ~10 s of received frames: joins are slot-sequential, so a first registration can land
before the seat has an index (the paintball 2026-08-25 scar). Registering twice is harmless.

The server **consumes** the registration — it is never applied as a shout and never written to
the replay chat stream, because the prompt is a secret. What the replay gets is a **redacted**
`register` record: the policy label, the kind and the baseline, never the prompt. A seat that
joins and produces no register record before the lobby closes is **named in a warning line in the
game log** (the grf-football 2026-08-27 scar), and `results.policyKinds` carries the same fact.

The seat receives one 5-byte binary frame per server frame and replies with the Sprite v1
player-ready packet (`0x85`). It sends **no inputs at all**: the server computes every bomber's
action, so the dead-reckoning hazard the Sprite protocol warns about cannot arise and `fastMode`
can advance as soon as every seat has acknowledged the frame. It **exits 0 on a dead socket** —
whisky's `receiveMessage` raises on a close frame and mummy's `send` only queues, so the game's
own `quit(0)` can outrun the flushed frame (the raid 0.1.3 race).

## The decision, and where it happens

**In the game server, not the player container.** The `anthropic_api_key` coworld secret is
injected into the game pod, phase 60 greps the *game* log for `falling back` /
`LLM provider is unavailable`, and `docker_smoke.sh` forwards `ANTHROPIC_API_KEY` to the game
container only. No `USE_BEDROCK` flag is needed on the policies, because the player pod makes no
LLM call.

Credentials, in order: **Bedrock sidecar** (`AWS_ENDPOINT_URL_BEDROCK_RUNTIME` +
`AWS_BEARER_TOKEN_BEDROCK`) → `ANTHROPIC_API_KEY` → `ANTHROPIC_API_KEY_URI` → **none**, in which
case the client disables itself and every turn falls back instantly with no network wait, so
offline certification finishes in seconds.

All four seats' calls go out as **ONE parallel batch per turn** (`curly.makeRequests`): this is a
simultaneous-decision game and serial calls would quadruple the wall clock. At most 4 in flight;
at most `4 × 36 × 2 = 288` an episode including retries.

| Bound | Value |
|---|---|
| `attempt1Ms` | 12 000 |
| `retryMs` | 5 000 |
| `turnBudgetMs` | 18 000 (a monotonic deadline around the whole turn) |
| `turnSpacingMs` | 10 000 (a wall-clock floor between batch STARTS → 24 req/min) |
| `wallClockBudgetSeconds` | 640 (the engine's own hard stop) |
| budget guard | fires at `elapsed + 2 × turnBudget > 640`, i.e. `elapsed > 604 s` |

## Reply schema

```json
{"order": {"verb": "hunt", "target": "BLUE-1"},
 "radio": [3, 7],
 "say": "boxing him against the SE lattice",
 "notes": "3 means 'I am out of ammo'"}
```

| Field | Cap / domain |
|---|---|
| `order` | one object; an array is accepted and its **first** element used |
| `order.verb` | ≤ 8 runes; `go`\|`bomb`\|`hunt`\|`break`\|`hide`\|`kick`\|`follow`; unknown → the seat's previous verb |
| `order.x`, `.y` | required iff `verb == "go"`; clamped into `[0,10]`, then retargeted to the nearest passable cell |
| `order.target` | required iff `verb == "hunt"`; ≤ 6 runes; a **living enemy** alias; unmatched or dead → the nearest living enemy |
| `order.dir` | required iff `verb == "kick"`; ≤ 5 runes; `up`\|`down`\|`left`\|`right` |
| `radio` | exactly 2 integers, each clamped into `[1,8]`; missing or malformed → this seat's previous pair |
| `say` | ≤ 100 runes — spectator chatter |
| `notes` | ≤ 200 runes — private, echoed to this seat only next turn |
| whole reply | ≤ 8192 **bytes** read before parsing |
| `PLAYER_PROMPT` | ≤ 4000 runes at registration |
| whole `directive` record | ≤ 900 runes |

Unknown top-level keys are ignored. A reply with a valid `radio` and no `order` is **usable**. A
reply that is not a JSON object is a parse failure and nothing else is.

**Every string that lands in the replay is truncated on RUNE boundaries.** Byte truncation is
what makes a replay that renders in a browser fail a strict UTF-8 parser.

## Results document (closed schema)

```json
{
  "names": ["daveey", "daveey-1", "Baseline (1)", "Baseline (2)"],
  "aliases": ["RED-1", "BLUE-1", "RED-2", "BLUE-2"],
  "teams": ["RED", "BLUE", "RED", "BLUE"],
  "scores": [141, -141, 141, -141],
  "win": [true, false, true, false],
  "winner": "RED",
  "reason": "complete",
  "endRule": "wipe",
  "teamScores": [141, -141], "teamAlive": [2, 0],
  "teamKills": [2, 0], "teamWood": [21, 20],
  "alive": [true, false, true, false],
  "kills": [1, 0, 1, 0], "deaths": [0, 1, 0, 1], "suicides": [0, 0, 0, 0],
  "bombsPlaced": [14, 11, 9, 13], "woodCleared": [12, 11, 9, 9],
  "kicks": [2, 0, 0, 1], "pickups": [3, 1, 2, 2], "radioSent": [36, 36, 36, 36],
  "finalTick": 118, "turnsPlayed": 30, "seed": 1734029581,
  "policyKinds": ["llm", "llm", "scripted", "scripted"],
  "llmTurns": [30, 30, 0, 0], "fallbackTurns": [1, 0, 0, 0],
  "ordersRejected": [0, 0, 0, 0], "deadSeats": [false, false, false, false],
  "stopDetail": ""
}
```

`teamScores` / `teamAlive` / `teamKills` / `teamWood` are two-element arrays indexed
`[RED, BLUE]`. `winner` is `"RED"`, `"BLUE"` or `null`. `reason` is the closed enum
`complete | deadline | fault`; `endRule` is `wipe | tickCap | wallClock | fault`.

Adding a key means updating `roster.bomberResultsJson`, the manifest's `results_schema` and
`tools/ci/docker_smoke.sh`'s expected-key set **in the same commit** — Coworld schemas are closed
and undeclared keys are dropped.

## Replay bytes

`COWLDPOM` = magic + format version + game name/version + the **resolved config JSON** + a record
stream + one `gameHash` per frame.

| Record | Fields |
|---|---|
| join / leave | tick, slot, real name, token |
| gameStart | tick, game index |
| **order** | tick, turn, slot, verb, argument, **both radio integers** — this game's entire input log |
| chat | tick, slot, text: `register` / `directive` / `fallback` / `budget_guard` / `stop` / `result` |
| hash | tick, `gameHash` |
| **stop** | tick, endRule — the **load-bearing** wall-clock / fault stop, applied by the same proc on record and on playback (the particle-worlds scar) |

Everything else is re-derived. About 20 KB an episode.

## Tier-2 event stream

`COGAME_EVENTS_URI` gets JSON lines plus a mandatory trailing summary row. Kinds:
`bomb_placed`, `bomb_kicked`, `explosion`, `wood_cleared`, `pickup`, `death`, `collapse`,
`turn_start`, `directive`, `radio`, `fallback`, `phase_change`.

## Derived broadcast events

`broadcast.stepEvents` derives thirteen kinds from state deltas and the frame's chat records, so
they cost no replay bytes and are identical live and in replay:

`turn`, `order`, `radio`, `say`, `fallback`, `bomb`, `kick`, `pickup`, `wood`, `firstblood`,
`death`, `collapse`, `end`.

Only **`firstblood`, `kick`, `death`, `collapse`, `fallback` and `end`** become scrubber beats;
the rest drive the feed.
