import json, collections

CHAMP1 = """Play forward and make the board yours. Turn 1 through 6: "break", every turn, without
exception - you cannot fight with range 2 and one bomb, and every wooden wall you take
down is a lane you can retreat along and a chance at a power-up. The moment "board"
shows an e, r or k you can reach, "go" to it; range and extra bombs beat position this
early.
From turn 7, read "danger" before anything else. If your own cell shows a digit, order
"hide" and lose the turn - a dead bomber scores nothing. If you are clean and an enemy
is on your row or column within (your range - 1) cells with nothing but floor between
you, order "hunt" on it. Otherwise keep breaking toward the middle.
From turn 22 head inward: "go" to a cell in the 5x5 middle block (x and y both between
3 and 7) and be inside it before tick 96. Outside the ring is a death sentence at 96
and again at 120, and the bomber that arrives first picks the corner.
Once inside, hunt. Prefer the opponent with lower ammo. If you take kick, use it: a
kicked bomb down a straight lane is the only way to hit something that will not come
to you, and it costs you nothing.
RADIO. Send [a, b] where a is your intent this turn and b is where you are:
a = 1 breaking wood, 2 collecting a power-up, 3 hunting, 4 hiding, 5 I am in the middle,
6 I am about to bomb next to you so move, 7 I am out of ammo, 8 I am in trouble.
b = 1..4 for which quadrant you are in (1 NW, 2 NE, 3 SE, 4 SW), 5..8 for the same
quadrant when you are already inside the middle 5x5.
Read your partner's pair the same way and BELIEVE the position half even if the intent
half looks like noise - if partner says 6, get off its row and column this turn."""

CHAMP2 = """Win by not dying, and by making the enemy die of the walls. Most bombers in this game
kill themselves; you will not.
Rule one, absolute: if your own cell in "danger" shows any digit at all, order "hide".
Nothing else. Rule two: never order "bomb" or "hunt" unless "danger" shows at least two
'.' cells you can reach in three steps in DIFFERENT directions. A dead end plus a bomb
is a suicide.
Turns 1 through 10: "break", staying inside your own quadrant, and take any power-up
that appears within about five cells - do not cross the board for one. You want range 3
and two bombs by turn 10 and you want to still be alive.
Turns 11 through 24: hold the mouth of your own corridor. Order "hide" whenever no
enemy is within five cells, and "hunt" the moment one comes inside five. Let them walk
into your ground. If your partner's radio says it is in trouble, order "follow" for
exactly one turn and then go back to holding.
Turn 25 onward: "go" into the middle 5x5 (x and y between 3 and 7), take the cell with
the most exits, and from then on alternate "hide" and "hunt" - hide when both opponents
are alive and more than three cells away, hunt the nearer one otherwise. The rings do
half your work; you only have to outlive them.
RADIO. Send [a, b] where a counts your bombs in hand plus one (so 1 means empty, 2
means one bomb, and so on up to 6) and b is the number of living enemies you can see
within four cells, plus one (1 = none nearby, 2 = one, 3 = both), except send b = 8
when you are about to die and want your partner clear of you.
Read the partner's a as "can it help me right now" and its b as "is it in contact".
An 8 in either half means get away from that bomber this turn."""

policies = [
  {"name": "pommerman-firestarter", "run": "/bin/pommerman-player",
   "env": {"PLAYER_PROMPT": CHAMP1}},
  {"name": "pommerman-cornerman", "run": "/bin/pommerman-player",
   "env": {"PLAYER_PROMPT": CHAMP2},
   "player": "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"},
  {"name": "pommerman-sapper", "run": "/bin/pommerman-player",
   "env": {"PLAYER_SCRIPTED": "sapper"}},
  {"name": "pommerman-camper", "run": "/bin/pommerman-player",
   "env": {"PLAYER_SCRIPTED": "camper"}},
]
open("tools/ci/policies.json", "w").write(json.dumps(policies, indent=2) + "\n")

SEATS = [{"name": "RED-1"}, {"name": "BLUE-1"}, {"name": "RED-2"},
         {"name": "BLUE-2"}]
SLOTS = [{"team": "red"}, {"team": "blue"}, {"team": "red"}, {"team": "blue"}]

def game_config(**over):
    base = collections.OrderedDict([
        ("players", SEATS), ("slots", SLOTS),
        ("num_agents", 4), ("minPlayers", 4),
        ("maxTicks", 144), ("turnTicks", 4),
        ("bombFuse", 8), ("flameLife", 2),
        ("startAmmo", 1), ("maxAmmo", 5),
        ("startBlast", 2), ("maxBlast", 6),
        ("collapseTicks", [96, 120]), ("dodgeHorizon", 8),
        ("attempt1Ms", 12000), ("retryMs", 5000),
        ("turnBudgetMs", 18000), ("turnSpacingMs", 10000),
        ("wallClockBudgetSeconds", 640), ("lobbyJoinTimeoutTicks", 2400),
        ("startWaitTicks", 24), ("gameOverTicks", 90),
        ("fastMode", True), ("showPlayerLabels", False),
    ])
    base.update(over)
    return base

def arr(desc, items, lo, hi):
    return {"type": "array", "description": desc, "items": items,
            "minItems": lo, "maxItems": hi}

config_schema = {
  "type": "object",
  "additionalProperties": False,
  "required": ["tokens", "players"],
  "properties": {
    "tokens": arr(
      "Per-seat join tokens. RUNNER-INJECTED: the platform supplies these, so "
      "no game_config in this manifest carries a literal tokens array.",
      {"type": "string"}, 4, 4),
    "players": arr(
      "One entry per seat. The name is spectator-side only; in game the seats "
      "are RED-1, BLUE-1, RED-2 and BLUE-2.",
      {"type": "object", "additionalProperties": False,
       "properties": {"name": {"type": "string"}}}, 4, 4),
    "slots": arr(
      "Which team each seat holds. Server-assigned by slot parity and never "
      "chosen by a policy: seats 0 and 2 are RED, 1 and 3 are BLUE.",
      {"type": "object", "additionalProperties": False,
       "properties": {"team": {"type": "string", "enum": ["red", "blue"]},
                      "token": {"type": "string"}}}, 0, 4),
    "collapseTicks": arr(
      "The ticks at which ring 1 and then ring 2 turn to rigid wall and crush "
      "whatever stands on them.",
      {"type": "integer", "minimum": 1}, 0, 3),
    "num_agents": {"type": "integer",
      "description": "Seats. Always exactly four: two teams of two on the "
                     "diagonals. There is no other seating.",
      "minimum": 4, "maximum": 4, "default": 4},
    "seed": {"type": "integer", "minimum": 0},
    "minPlayers": {"type": "integer", "minimum": 0, "maximum": 4, "default": 4},
    "maxTicks": {"type": "integer", "minimum": 4, "maximum": 2000,
                 "default": 144},
    "turnTicks": {"type": "integer", "minimum": 1, "maximum": 64, "default": 4},
    "bombFuse": {"type": "integer", "minimum": 1, "maximum": 60, "default": 8},
    "flameLife": {"type": "integer", "minimum": 1, "maximum": 10, "default": 2},
    "startAmmo": {"type": "integer", "minimum": 0, "maximum": 9, "default": 1},
    "maxAmmo": {"type": "integer", "minimum": 1, "maximum": 9, "default": 5},
    "startBlast": {"type": "integer", "minimum": 1, "maximum": 11,
                   "default": 2},
    "maxBlast": {"type": "integer", "minimum": 1, "maximum": 11, "default": 6},
    "dodgeHorizon": {"type": "integer", "minimum": 1, "maximum": 16,
                     "default": 8},
    "turnBudgetMs": {"type": "integer", "minimum": 0, "maximum": 60000,
                     "default": 18000},
    "attempt1Ms": {"type": "integer", "minimum": 1000, "maximum": 30000,
                   "default": 12000},
    "retryMs": {"type": "integer", "minimum": 1000, "maximum": 30000,
                "default": 5000},
    "turnSpacingMs": {"type": "integer", "minimum": 0, "maximum": 60000,
                      "default": 10000},
    "wallClockBudgetSeconds": {"type": "integer",
      "description": "The engine's own hard stop, in seconds. 640 is 53 "
                     "percent of the assumed 1200 s episode timeout, and the "
                     "budget guard at elapsed > 604 s means the worst modelled "
                     "settle is 642 s -- 54 percent, inside the 60 percent "
                     "target. Never above 640.",
      "minimum": 10, "maximum": 640, "default": 640},
    "lobbyJoinTimeoutTicks": {"type": "integer", "minimum": 1, "default": 2400},
    "startWaitTicks": {"type": "integer", "minimum": 0, "maximum": 600,
                       "default": 24},
    "gameOverTicks": {"type": "integer", "minimum": 0, "maximum": 600,
                      "default": 90},
    "fastMode": {"type": "boolean", "default": True},
    "showPlayerLabels": {"type": "boolean", "default": False},
    "maxOutputTokens": {"type": "integer", "minimum": 1, "maximum": 8192,
                        "default": 900},
    "model": {"type": "string"},
  }
}

def ints(desc, lo=4, hi=4):
    return {"type": "array", "description": desc,
            "items": {"type": "integer"}, "minItems": lo, "maxItems": hi}

results_schema = {
  "type": "object",
  "additionalProperties": False,
  "properties": {
    "names": {"type": "array", "items": {"type": "string"},
              "minItems": 4, "maxItems": 4},
    "aliases": {"type": "array", "items": {"type": "string"},
                "minItems": 4, "maxItems": 4},
    "teams": {"type": "array", "items": {"type": "string"},
              "minItems": 4, "maxItems": 4},
    "scores": ints("Each seat's team score. Exactly zero-sum across the four."),
    "win": {"type": "array", "items": {"type": "boolean"},
            "minItems": 4, "maxItems": 4},
    "winner": {"type": ["string", "null"], "enum": ["RED", "BLUE", None]},
    "reason": {"type": "string",
               "enum": ["complete", "deadline", "fault"]},
    "endRule": {"type": "string",
                "enum": ["wipe", "tickCap", "wallClock", "fault"]},
    "teamScores": ints("Indexed [RED, BLUE].", 2, 2),
    "teamAlive": ints("Indexed [RED, BLUE].", 2, 2),
    "teamKills": ints("Indexed [RED, BLUE].", 2, 2),
    "teamWood": ints("Indexed [RED, BLUE].", 2, 2),
    "alive": {"type": "array", "items": {"type": "boolean"},
              "minItems": 4, "maxItems": 4},
    "kills": ints("Cross-team kills credited to each seat."),
    "deaths": ints("Deaths per seat, however caused."),
    "suicides": ints("Deaths per seat caused by that seat's own bomb."),
    "bombsPlaced": ints("Bombs laid per seat."),
    "woodCleared": ints("Wooden walls cleared per seat."),
    "kicks": ints("Bombs kicked per seat."),
    "pickups": ints("Power-ups taken per seat."),
    "radioSent": ints("Radio pairs sent per seat."),
    "finalTick": {"type": "integer"},
    "turnsPlayed": {"type": "integer"},
    "seed": {"type": "integer"},
    "policyKinds": {"type": "array", "items": {"type": "string"},
                    "minItems": 4, "maxItems": 4},
    "llmTurns": ints("Turns each seat answered with a real LLM reply."),
    "fallbackTurns": ints("Turns each seat fell back to the scripted order."),
    "ordersRejected": ints("Reply fields repaired by the validator, per seat."),
    "deadSeats": {"type": "array", "items": {"type": "boolean"},
                  "minItems": 4, "maxItems": 4},
    "stopDetail": {"type": "string"},
  }
}

DESC = (
  "Pommerman as a Coworld. Four bombers stand in the four corners of an 11x11 "
  "walled grid packed with wooden walls, seated as two teams of two on the "
  "diagonals by the server. Bombs clear wood and kill; wood hides power-ups "
  "that give extra bombs, longer blasts and the ability to kick a bomb down a "
  "lane. Every four ticks each seat issues its bomber ONE order and sends its "
  "PARTNER two integers in 1..8 that the game gives no meaning and the opposing "
  "team never sees - an emergent-language channel between two policies that "
  "were seated as partners by the ladder and have never met. At tick 96 and "
  "again at 120 the outer rings turn to rigid wall and crush whatever stands "
  "on them, so the fight is forced into the middle and closes. The team score "
  "is exactly zero-sum, so no two seats can raise their joint total by "
  "cooperating across the table."
)

GH = "https://github.com/Metta-AI/cogame-pommerman"

def player(pid, name, desc, env):
    return {
      "id": pid, "type": "player", "name": name, "description": desc,
      "image": "{{POMMERMAN_IMAGE}}", "run": ["/bin/pommerman-player"],
      "source_url": GH, "env": env,
      "resources": {"requests": {"cpu": "100m", "memory": "64Mi"},
                    "limits": {"cpu": "1"}},
    }

manifest = collections.OrderedDict([
  ("$schema", "https://softmax.com/schemas/coworld-manifest-v1.json"),
  ("tags", ["bomberman", "pommerman", "grid", "team", "emergent-comm"]),
  ("episode_timeout_minutes", 20),
  ("game", collections.OrderedDict([
    ("name", "pommerman"),
    ("owner", "daveey@softmax.com"),
    ("description", DESC),
    ("replay_viewer", {"bundle": "static-replay-viewer"}),
    ("runnable", {
      "type": "game", "image": "{{POMMERMAN_IMAGE}}",
      "run": ["/bin/pommerman"],
      "env": {"ANTHROPIC_API_KEY_URI":
              "secret://coworld/pommerman/anthropic_api_key"}}),
    ("protocols", {
      "player": {"type": "uri", "value": GH + "/blob/main/docs/PROTOCOL.md"},
      "global": {"type": "uri", "value": GH + "/blob/main/docs/PROTOCOL.md"}}),
    ("docs", {
      "readme": {"type": "uri", "value": GH + "/blob/main/README.md"},
      "pages": [
        {"id": "rules.md", "title": "Rules",
         "content": {"type": "uri",
                     "value": GH + "/blob/main/docs/RULES.md"}},
        {"id": "radio.md", "title": "The radio channel",
         "content": {"type": "uri",
                     "value": GH + "/blob/main/docs/RADIO.md"}}]}),
    ("config_schema", config_schema),
    ("results_schema", results_schema),
  ])),
  ("player", [
    player("sapper", "pommerman-sapper",
      "The published scripted default and the server-side fallback: bomb an "
      "enemy in a clear lane, else bomb the wood you are standing beside, else "
      "walk to the nearest power-up, else break toward the middle, and head "
      "inward before the rings close. Sends a real radio pair every turn: ammo "
      "plus one, and enemies within four cells plus one.",
      {"PLAYER_SCRIPTED": "sapper"}),
    player("camper", "pommerman-camper",
      "Deliberately weaker and different in shape: it only bombs an adjacent "
      "enemy or a wall it has two safe exits from, hides the rest of the time, "
      "and sends [1, 1] every single turn. The silent partner is the control "
      "against which 'did the radio matter?' is measured on the ladder.",
      {"PLAYER_SCRIPTED": "camper"}),
  ]),
  ("variants", [
    {"id": "teams", "name": "2v2 Team Radio (11x11)",
     "description":
       "Four bombers on an 11x11 grid, two teams of two on the diagonals, 36 "
       "command turns. Bombs clear wood and kill; power-ups give extra bombs, "
       "longer blasts and the ability to kick. Every turn each seat sends its "
       "partner two integers in 1..8 that the game gives no meaning and the "
       "opposing team never sees. The outer rings collapse at tick 96 and 120.",
     "game_config": game_config()},
    {"id": "blitz", "name": "Blitz (11x11, 96 ticks)",
     "description":
       "The same rules and the same radio on a 96-tick clock - 24 command "
       "turns, rings collapsing at 64 and 80. A faster ladder round with the "
       "identical command surface, for divisions that want more episodes per "
       "hour.",
     "game_config": game_config(maxTicks=96, collapseTicks=[64, 80])},
  ]),
  ("certification", {
    "players": [{"player_id": "sapper"}, {"player_id": "camper"},
                {"player_id": "sapper"}, {"player_id": "camper"}],
    "game_config": game_config(seed=42, turnSpacingMs=0,
                               wallClockBudgetSeconds=240,
                               lobbyJoinTimeoutTicks=600),
  }),
])

open("coworld_manifest_template.json", "w").write(
    json.dumps(manifest, indent=2) + "\n")
print("wrote manifest and policies")
