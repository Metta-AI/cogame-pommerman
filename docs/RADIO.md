# The radio channel

Two integers, each in `1..8`, from you to your **partner**, once a turn, delivered one turn late.
The opposing team never sees them, at any delay. **The game assigns them no meaning.**

That is the whole specification, and it is the reason this coworld exists.

## The mechanics, exactly

- Every turn, every seat sends a pair with its order. A seat that says nothing repeats its
  previous pair; turn 1's default is `[1, 1]`. A seat that **fell back** to the scripted layer
  still sends a pair — `sapper`'s, which is a real signal, or `camper`'s, which is `[1, 1]`.
- The pair is delivered to the sender's **partner** on the **following** turn, as
  `radio_from_teammate` in that seat's observation. On turn 1 it is `null`.
- Each integer is clamped into `[1, 8]`. A missing, mis-shaped or non-numeric `radio` repeats
  this seat's previous pair; it is never a parse failure, because **the radio is a first-class
  output, not a rider on the order** — a reply carrying a valid `radio` and no `order` is
  perfectly usable.
- Both pairs are **hashed into `gameHash`**. They are inputs, and a replay that got them wrong
  would draw the wrong glyphs while claiming a clean chain.
- Spectator-side, both teams' pairs are drawn: over each bomber as a `≋a·b` badge, and on the
  team's scorebug plate. The hiding is enforced in the observation builder, never in the
  renderer.

`src/pommerman/radio.nim` is deliberately paranoid about the one thing that matters: every write
and every read goes through a proc that takes **both a team and a seat** and raises if
`teamOfSeat(seat)` does not match. There is no code path from a seat index to a cross-team pair.

## Why it is hard

You did not choose your partner and **you will never learn which policy it is**. In-game the four
seats are `RED-1`, `BLUE-1`, `RED-2` and `BLUE-2` and nothing else; no real policy name reaches
any observation or prompt. So the channel is not a private protocol between two copies of one
prompt — it is a coordination problem between two strangers under fire, with 64 symbols a turn
and 36 turns to establish anything at all.

The practical consequences, and what the shipped champion prompts do about them:

- **Send something simple.** A code with 64 distinct meanings is a code nobody decodes. Both
  champions use a two-field split: one integer for intent, one for position or contact.
- **Send it consistently.** A partner learns a mapping only from repetition against what it can
  see happening on the board.
- **Read your partner's pair against the board.** The position half of a pair is checkable
  against `bombers[]`; the intent half is not. `pommerman-firestarter`'s prompt says outright:
  believe the position half even if the intent half looks like noise.
- **One number should mean "get away from me".** Both champions reserve a value for it — the
  single most valuable thing to be able to say in a game where your partner's bomb kills you for
  the same price as an opponent's.

## The control

`camper` sends `[1, 1]` every single turn, on purpose. It is the **silent partner**: the control
against which "did the radio matter?" is measured on the ladder. `sapper` sends
`[1 + ammo, 1 + enemies within four cells]`, which is a real, legible signal — so an all-scripted
episode still exercises the channel and a champion partnered with a filler has something to
decode.

## What the game does NOT do

- It never interprets a pair. Nothing in the sim, the score or the viewer reads meaning into the
  digits; the viewer draws them and stops.
- It never widens the channel. Two integers in `1..8`, once a turn, one turn late — that is 6
  bits per turn per seat, and no `say`, `notes` or order text reaches the other seat.
- It never delivers across the table. Not now, not delayed, not aggregated.
