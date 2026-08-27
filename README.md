# cogame-pommerman

**Pommerman as a Coworld.** Four bombers stand in the four corners of an 11 × 11 walled grid
packed with wooden walls. They are two teams of two, seated on the diagonals **by the server**:
seats 0 and 2 are RED, seats 1 and 3 are BLUE. Bombs clear wooden walls, wooden walls hide
power-ups, and power-ups make your bombs more numerous, longer-reaching and kickable. A team
wins by killing both opponents — including by tricking them into a blast they cannot outrun.
Twice near the end the outer rings of the arena turn to rigid wall and crush whatever stands on
them, so the fight is forced into the middle and closes.

Every four sim ticks each seat issues its bomber **one order** and sends its **teammate two
integers in 1..8** — a two-symbol private channel with **no meaning the game assigns**. That
channel is the point of this coworld: it is an emergent-language link between two independent
policies that were seated as partners by the ladder and have never met. The opposing team never
sees a pair, at any delay.

Watch: **https://softmax.com/pommerman**

## A policy is just a prompt

There is one image with two entrypoints and the whole policy set is switched by environment:

```bash
# an LLM seat -- the strategy IS the policy
coworld upload-policy coworld-pommerman:latest --name my-bomber \
  --run /bin/pommerman-player \
  --secret-env PLAYER_PROMPT="Break wood until you have range 3, then hunt."

# a scripted seat
coworld upload-policy coworld-pommerman:latest --name my-filler \
  --run /bin/pommerman-player \
  --secret-env PLAYER_SCRIPTED=sapper
```

The player container is deliberately thin: it registers its seat and then only acknowledges
frames. **Every decision happens in the game server**, because that is the only container the
platform injects the `anthropic_api_key` coworld secret into, and because keeping the control
layer server-side is what makes the recorded order log reproducible with no network in the loop.

## What a seat sees, and what it says

Each turn a seat gets the whole board (terrain, flames, every bomb with its fuse and blast, every
dropped power-up, all four bombers' position/ammo/range/kick), a **decoded `danger` grid** —
"ticks until this cell is on fire", chain reactions and closing walls included — and its
partner's radio pair from the previous turn. It never sees the opposing team's pairs, what lies
under unbroken wood, any other seat's order or notes, or **any real policy name, including its
own partner's**.

It replies with one JSON object:

```json
{"order": {"verb": "hunt", "target": "BLUE-1"},
 "radio": [3, 7],
 "say": "boxing him against the SE lattice",
 "notes": "3 means 'I am out of ammo'"}
```

Seven verbs — `go`, `bomb`, `hunt`, `break`, `hide`, `kick`, `follow` — and a deterministic
controller executes the order tick by tick. The controller **always pulls a bomber out of fire
first** if it can, and refuses to lay a bomb it cannot see an escape from. It cannot save you
from a trap with no exit.

Full rules: [`docs/RULES.md`](docs/RULES.md). The radio: [`docs/RADIO.md`](docs/RADIO.md).
The wire contract: [`docs/PROTOCOL.md`](docs/PROTOCOL.md).

## Two name spaces

In-game the seats are **`RED-1`, `BLUE-1`, `RED-2`, `BLUE-2`** and nothing else — those aliases
are the only names that appear in an observation, a prompt, an order, a `say` or a sprite label.
The seats' real policy and player names live only in `results.names`, in the replay's join
records, and in the viewer's scorebug and endcard. **A seat cannot learn who its partner is**,
which is what makes the radio a real coordination problem rather than a pre-agreed protocol
between two copies of one prompt.

## Scoring

```
outcome[t]   = +1 / 0 / -1 by living bombers at the end
teamScore[t] = 100 * outcome[t] + 20 * (alive[t] - alive[other]) + (wood[t] - wood[other])
score[seat]  = teamScore[team(seat)]
```

Both seats of a team receive the identical score, so the four seat scores sum to **exactly
zero**. That, with server-assigned partners, is the anti-collusion rule: no two seats can raise
their joint total by cooperating across the table, which is the classic free-for-all Pommerman
exploit.

## Replays

The replay is the binary **`COWLDPOM`** format: a header, the resolved config, every order (verb,
argument and both radio integers), the chat records and **one `gameHash` per tick**. The static
wasm viewer re-simulates the episode in the browser from **the same `src/pommerman/sim.nim` the
server runs** and compares the hash every tick, so one divergent bit is caught at the tick it
happens. Nothing is contacted but S3 for the file.

`tools/replay_summary.py` (Python 3 stdlib only) prints one strict-UTF-8 JSON object describing
any replay:

```bash
curl -sSL "$replay_url" -o /tmp/ep.replay
python3 tools/replay_summary.py /tmp/ep.replay | jq -r '.protocol, .results.reason'
```

## Layout

| Path | What it is |
|---|---|
| `src/pommerman/` | the sim (`board`, `bombs`, `radio`, `sim`), the mummy server, the commander layer (`decide`, `directives`, `llm`, `baselines`, `control`), the replay codec and the broadcast layer |
| `src/pommerman.nim`, `src/pommerman_player.nim` | the two entrypoints of the one image |
| `client/` | the broadcast chrome: `chrome_common.js` byte-for-byte from coworld-ctf, the forked `broadcast_core.js`, and `replay_broadcast.html` built by `tools/build_broadcast_page.py` |
| `replay-viewer/` | the wasm entry, its emscripten link flags and the OffscreenCanvas Worker shell — all four from ONE starter, coworld-ctf |
| `scripts/art/` | the nano-banana bomber sheet and the split script |
| `tests/` | four balanced shards; `nim c -r --path:src tests/tests.nim` runs them all |
| `tools/ci/` | the docker smoke, the viewer smoke, the renderer fixture and the policy set |

Built by forking `Metta-AI/coworld-ctf`. Design note:
[`docs/plans/2026-08-27-pommerman-design.md`](docs/plans/2026-08-27-pommerman-design.md).
