# Protocol

Pommerman uses the Coworld four-seat WebSocket contract. The game owns the
board, visibility, action validation, simultaneous turn deadline, fallback,
results, and replay. Each player container owns its policy and credentials.

## Environment

| Variable | Container | Meaning |
|---|---|---|
| `COGAME_CONFIG_URI` | game | Resolved game config JSON |
| `COGAME_RESULTS_URI` | game | Results document written once |
| `COGAME_SAVE_REPLAY_URI` | game | Binary `COWLDPOM` replay |
| `COGAME_PLAYER_FAILURE_URI` | game | Closed player failure payload |
| `COGAME_EVENTS_URI` | game | Optional JSONL analysis stream |
| `COGAME_LOAD_REPLAY_URI` | game | Local replay mode |
| `COGAME_HOST`, `COGAME_PORT` | game | Listen address and port |
| `COWORLD_PLAYER_WS_URL` | player | Authenticated seat socket |
| `PLAYER_SCRIPTED` | player | `sapper` or `camper`; defaults to `sapper` |
| `PLAYER_PROMPT` | player | Claude strategy text; stays in the player |
| `PLAYER_JEV` | player | Set to `1` for Jev System One |
| `PLAYER_POLICY_LABEL` | player | Redacted replay registration label |
| `PLAYER_MODEL_SPACING_MS` | player | Per-player model request floor; default 10000 ms |
| `ANTHROPIC_API_KEY` or `ANTHROPIC_API_KEY_URI` | player | Prompt policy credential |
| `TYPESAFE_API_KEY` or `METTA_CAPTURE_KEY` | player | Jev credential |
| `AWS_ENDPOINT_URL_BEDROCK_RUNTIME` | player | Sidecar model endpoint |

The game manifest supplies no inference secret. Prompt and Jev players need
player-scoped credentials or the hosted sidecar. A player without credentials
sends a scripted action marked `fallback` and `no_credentials`.

## Routes

| Route | Purpose |
|---|---|
| `GET /healthz` | Runner liveness probe |
| `WS /player?slot=<i>&token=<t>` | Authenticated seat socket |
| `WS /global` | Live spectator status |
| `GET /client/player?slot&token` | Token-checked page, without opening a seat socket |
| `GET /client/global` | Spectator page |
| `GET /client/replay` | Local replay page |
| `GET /replay-data` | Recorded bytes for local tooling |

## Seat exchange

A player sends a Sprite v1 chat registration. It contains metadata only:

```json
{"protocol":"pommerman-player/v2","policy":"my-jev",
 "kind":"jev","scripted":"sapper"}
```

`kind` is `scripted`, `prompt`, or `jev`. The prompt and model key never enter
the registration or replay. The player resends registration during early
frames because seats join sequentially. The server records only label, kind,
and fallback baseline.

At each command turn, the game delivers partner radio from the prior turn and
builds all four seat views from the same board state. It sends each socket a
JSON text message:

```json
{"protocol":"pommerman-player/v2","kind":"decision",
 "turn":7,"deadline_ms":18000,
 "observation":{"slot":0,"you":"RED-1","board":[],"danger":[],
 "bombers":[],"bombs":[],"radio_from_teammate":[3,7],
 "your_last_radio":[1,2],"your_notes":"..."}}
```

The shown observation is abbreviated. The actual view includes terrain,
danger, every visible bomb and bomber, collapse timing, score, last order,
private notes, and only this seat's partner radio. Opposing radio, other
seats' notes, and policy identities are absent.

The player replies in a Sprite v1 chat message with one ordinary action:

```json
{"protocol":"pommerman-player/v2","kind":"action",
 "turn":7,"source":"llm","latency_ms":412,
 "action":{"order":{"verb":"hunt","target":"BLUE-1"},
 "radio":[3,7],"say":"Closing the lane.",
 "notes":"Partner sent 3; hold the flank."}}
```

All four requests are sent before replies are applied. The game accepts a
reply only for its seat and current turn. One bounded `turnBudgetMs` window
covers the exchange. If a seat does not answer, the game applies its sapper
fallback and records the cause. The game validates and repairs fields through
`parseSeatDirective`; the controller still owns survival overrides. The
simultaneous order log, private radio, results, and replay remain game-owned.

Orders are `go`, `bomb`, `hunt`, `break`, `hide`, `kick`, or `follow`.
`go` carries `x` and `y`; `hunt` carries a living enemy alias; `kick` carries
`up`, `down`, `left`, or `right`. `radio` contains two integers in `[1,8]`.
`say` is public and capped at 100 runes. `notes` is private, capped at 200
runes, and returned to the same seat on its next turn. The game repairs an
invalid field with the existing directive validator.

The player also acknowledges each binary simulation frame with Sprite v1
ready (`0x85`). `/healthz` and `/global` remain available during the bounded
shutdown grace. The player handshake is `pommerman-player/v2`. Older registration-only
players need reupload for this game interface. The binary replay format
remains `COWLDPOM` version 1.

## Player policies

`PLAYER_SCRIPTED` chooses from the ordinary observation. `PLAYER_PROMPT`
sends the same observation and an operator prompt to Claude, then returns a
normal action object. `PLAYER_JEV=1` sends the observation to System One with
separate choice questions for order, private radio, public `say`, and private
`notes`. Jev ranks ordinary action candidates; it does not change game rules
or see hidden state. Prompt and Jev requests are paced inside each player.

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
