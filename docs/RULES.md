# Rules

An 11 × 11 walled grid. Four bombers, two teams of two. Bombs, wooden walls, three power-ups and
two collapsing rings. `x` is the column `0..10` left→right, `y` is the row `0..10` top→bottom.

## Seats, teams, corners, aliases

Teams are fixed by slot parity and assigned **by the server**, never chosen by a policy.

| Seat | Alias | Team | Corner |
|---|---|---|---|
| 0 | `RED-1` | RED | NW `(1,1)` |
| 1 | `BLUE-1` | BLUE | NE `(9,1)` |
| 2 | `RED-2` | RED | SE `(9,9)` |
| 3 | `BLUE-2` | BLUE | SW `(1,9)` |

Partners sit on a diagonal. The map is 4-fold rotationally symmetric about `(5,5)`, so every
corner's surroundings are an exact rotation of every other's: **no seat has a positional
advantage**, and no side-swap game is needed. One game per episode.

## The board

- The outer ring (`x == 0 or x == 10 or y == 0 or y == 10`) is **rigid wall** — 40 cells.
- The interior cells with **both coordinates even** are rigid too — the classic Bomberman
  lattice, 16 cells. It guarantees the board is **connected by construction**: every odd row and
  every odd column is fully open, and those form a spanning grid, so there is no repair pass.
- The four corner cells and their two interior orthogonal neighbours each — 12 cells — and the
  centre `(5,5)` are always passage.
- The remaining 52 cells are 13 rotation orbits of four. A xorshift64\* seeded by the episode
  seed shuffles them; the first **9 orbits are wooden wall (36 cells)** and the last 4 are
  passage. Of the 9 wood orbits, orbits 1–2 hide an **extra bomb**, 3–4 hide **+1 range**, 5
  hides **kick** and 6–9 hide nothing: **20 power-ups**, upstream's `NUM_ITEMS`.

Totals at tick 0: **56 rigid, 36 wood, 29 passage**. One living bomber per cell; at most one bomb
per cell; at most one loose power-up per cell.

## The bomber

`alive`, `x`, `y`, `ammo` (start **1**, cap **5**), `range` (start **2**, cap **6**), `kick`
(start false). A bomber has no hit points: **a flame kills instantly**.

## Bombs

`fuse` **8** at placement, `range` copied from the placer and never updated, an owner, and a
velocity (`none|up|down|left|right`). A bomb laid at tick `t` detonates at tick `t + 8`.

A detonation's **blast cells** are its own cell plus, in each of the four directions, up to
`range − 1` cells: walking outward, **stopping before** the first rigid cell, **stopping at and
including** the first wood cell, and passing through passage, power-ups, bombers and bombs.

**Chain reaction:** any bomb standing in a blast cell detonates in the same tick, to a fixpoint.

**Flame** is a cell timer of **2** ticks set at detonation and decremented at the end of every
tick, so a flame is lethal on the tick it appears and on the one after it.

## Power-ups

`extrabomb` (`ammo += 1`, capped), `incrrange` (`range += 1`, capped), `kick` (idempotent).
Picked up by stepping onto the cell; consumed. Wood destroyed by a blast **reveals** the power-up
it was hiding onto that cell (it survives the blast that revealed it); a power-up **already
lying** in a blast cell is destroyed.

## Turns and ticks

A **tick** is one Pommerman step. A **command turn** is one order round, every `turnTicks = 4`
ticks, beginning immediately before tick 1. `maxTicks = 144` ⇒ **36 command turns**.

Per command turn `T`, in this order:

1. The engine snapshots the world and builds all four seats' observations.
2. **Radio delivery** — each seat's observation carries the pair its **partner** sent with its
   turn `T−1` order (`null` on turn 1). Exactly one turn late, always, including when the partner
   fell back. The opposing team's pairs are never in any observation.
3. All four seats' LLM requests go out as **one parallel batch**, attempt-1 deadline 8 s.
4. Every seat that timed out, errored or returned nothing usable is retried **once**, again as
   one batch, 3 s.
5. A seat still without a usable reply gets the **`sapper`** scripted order and a `fallback`
   record.
6. Orders are installed. A seat that names no `order` keeps last turn's; an invalid field is
   **repaired**, never dropped, and counted in `ordersRejected`.
7. `say` (≤ 100 runes) and the accepted order become replay records; `notes` (≤ 200 runes) is
   echoed back to that seat only; the radio pair is stored for turn `T+1`.

Then, for each of the next four ticks, in this order — **this is the whole physics and nothing
else mutates the world**:

1. `tick += 1`. Snapshot.
2. **Collapse.** If this is a collapse tick, every cell of that ring becomes rigid; a living
   bomber there dies `crushed`, a bomb there is removed without detonating, a power-up there is
   destroyed, a flame there clears. First, so nothing else acts on a cell about to be wall.
3. **Choose one action per living bomber**, ascending seat, from the snapshot.
4. **Bomb placement**, ascending seat. A bomber whose action is `bomb` places one iff `ammo > 0`
   and no bomb is on its cell; otherwise the action degrades to `stay`. **A bomber that places a
   bomb does not move this tick.**
5. **Kicked-bomb movement**, ascending bomb id. A moving bomb advances one cell iff the
   destination is passage and holds no bomb, no living bomber and no flame; otherwise it stops.
6. **Bomber movement**, ascending seat, from the snapshot positions:
   rigid or wood → the move fails; a bomb in the way → **kick** it iff the mover has `kick` and
   the cell one further is clear (and **the kicker does not move**), else the move fails; a cell
   holding a bomber, or already taken this tick → the move fails (**no swaps**, and two bombers
   for one empty cell resolve **lower seat wins**); otherwise it moves and picks up whatever is
   there.
7. **Fuse tick.** Every bomb laid before this tick, `fuse -= 1`.
8. **Detonation, with chain reaction**, to a fixpoint.
9. **Flames and wood.** Blast cells become flame; wood becomes passage and is credited to the
   owning team of the lowest-id bomb covering it; every detonated bomb is removed and its owner
   regains one ammo (capped).
10. **Deaths, simultaneous.** Every living bomber on a flame cell dies, all at once — mutual
    annihilation is a real outcome. `cause ∈ {bomb, suicide, friendlyfire, crushed}`, and
    `kills` increments **only** for a victim on the other team.
11. **Flame decay.**
12. The tick is mixed into `gameHash`.
13. The end conditions are evaluated.

## Collapse

`ring(x,y) = min(x, y, 10−x, 10−y)`. Ring 0 is the permanent border. At tick **96** every cell of
ring 1 becomes rigid; at tick **120** ring 2 goes. Play ends inside the 5 × 5 block
`x,y ∈ [3,7]`. (The `blitz` variant collapses at 64 and 80 on a 96-tick clock.)

## Orders

| Verb | What the controller does | Bombs when |
|---|---|---|
| `go x y` | walks to that cell; if it names a wall, to the nearest passable cell | never |
| `bomb` | bombs where it stands, then retreats | on the first tick of the turn, with ammo and an escape |
| `hunt A` | closes on living enemy `A`; if `A` died, on the nearest living enemy | when `A` is on the same row or column within `range − 1` cells with only passage between |
| `break` | walks to the nearest passage cell beside a wooden wall | on arrival, with ammo and an escape |
| `hide` | moves to the safest reachable cell and sits | never |
| `kick dir` | shoves the bomb in that direction; without `kick`, or with nothing to shove, behaves as `hide` | never |
| `follow` | moves to the partner; within 2 cells, behaves as `break` | as `break` |

**The survival override runs ahead of the order.** If the bomber's own cell is dangerous within
the dodge horizon (6 ticks), the controller ignores the order and takes the first step of the
shortest path to a cell safe for the whole horizon. **It is not a shield:** a bomber boxed into a
dead end still dies, which is exactly how Pommerman is won.

**"An escape exists"** means: after hypothetically placing the bomb, the same escape search finds
a safe cell. This is the one place the controller refuses a commander's order.

## Ending and scoring

The game ends at the first of: **team wipe** (`endRule: wipe`; both teams at once is a draw),
the **tick cap** (`tickCap`, settled by living-bomber count), the engine's **wall-clock stop**
(`wallClock`, `results.reason: deadline`) or a **fault**.

```
outcome[t]   = +1 / 0 / -1 by living bombers
teamScore[t] = 100 * outcome[t] + 20 * (alive[t] - alive[other]) + (wood[t] - wood[other])
score[seat]  = teamScore[team(seat)]
```

Range `±176`. Higher is better. The four seat scores sum to **exactly zero**.
