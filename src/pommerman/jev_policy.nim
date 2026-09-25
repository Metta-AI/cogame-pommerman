## Jev ranks ordinary orders and the independent radio, say, and notes slots.

import std/[json, monotimes, os, strutils, times]
import curly
import model_pacing, player_policy

proc jevConfigured*(): bool =
  getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip().len > 0 or
    (getEnv("METTA_CAPTURE_URL").strip().len > 0 and
      getEnv("METTA_CAPTURE_KEY").strip().len > 0) or
    getEnv("TYPESAFE_API_KEY").strip().len > 0

proc bestChoice(answer, criteria: JsonNode): string =
  if answer["type"].getStr() != "choice":
    raise newException(ValueError, "Jev returned a non-choice answer")
  let probabilities = answer["probabilities"]
  if probabilities.len != criteria.len:
    raise newException(ValueError, "Jev returned the wrong choice set")
  var best = -1.0
  var total = 0.0
  for choice, probability in probabilities.pairs:
    if not criteria.hasKey(choice):
      raise newException(ValueError, "Jev returned an unknown choice")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += value
    if value > best:
      best = value
      result = choice
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")

proc chooseJevAction*(
  view: JsonNode, pacer: var ModelPacer, budgetMs: int
): JsonNode =
  let started = getMonoTime()
  var orders = %*{
    "sapper": scriptedAction(view, "sapper")["order"],
    "camper": scriptedAction(view, "camper")["order"],
    "hide": {"verb": "hide"},
    "break": {"verb": "break"},
    "follow": {"verb": "follow"},
    "center": {"verb": "go", "x": 5, "y": 5}
  }
  let me = view["bombers"][view["slot"].getInt()]
  if me["ammo"].getInt() > 0:
    orders["bomb"] = %*{"verb": "bomb"}
  for index in 0 ..< view["bombers"].len:
    let bomber = view["bombers"][index]
    if bomber["id"] in view["enemies"] and bomber["alive"].getBool():
      orders["hunt_" & $index] = %*{
        "verb": "hunt", "target": bomber["id"]}
  for y in 0 ..< view["board"].len:
    for x, cell in view["board"][y].getStr():
      if cell in {'.', 'e', 'r', 'k'}:
        orders["go_" & $x & "_" & $y] = %*{
          "verb": "go", "x": x, "y": y}
  if me["kick"].getBool():
    for name in ["up", "down", "left", "right"]:
      orders["kick_" & name] = %*{"verb": "kick", "dir": name}

  var radios = newJObject()
  for a in 1 .. 8:
    for b in 1 .. 8:
      radios["radio_" & $a & "_" & $b] = %*[a, b]
  let says = %*{
    "silent": "",
    "pressure": "Pressing the nearest enemy.",
    "center": "Moving toward the center.",
    "safe": "Holding a safe lane."
  }
  let notes = %*{
    "clear": "",
    "keep": view["your_notes"],
    "attack": "Attack when the next safe lane opens.",
    "retreat": "Retreat before the next collapse."
  }
  var orderCriteria = newJObject()
  var radioCriteria = newJObject()
  var sayCriteria = newJObject()
  var noteCriteria = newJObject()
  for name, choice in orders.pairs:
    orderCriteria[name] = %($choice)
  for name, choice in radios.pairs:
    radioCriteria[name] = %($choice)
  for name, choice in says.pairs:
    sayCriteria[name] = %choice.getStr()
  for name, choice in notes.pairs:
    noteCriteria[name] = %choice.getStr()

  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  let endpoint =
    if sidecar.len > 0: sidecar
    elif capture.len > 0: capture
    else: getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
  let model =
    if sidecar.len > 0: "typesafe/jev-1.13"
    elif capture.len > 0: getEnv("METTA_CAPTURE_MODEL", "jev-latest")
    else: getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
  let key =
    if sidecar.len > 0: ""
    elif capture.len > 0: getEnv("METTA_CAPTURE_KEY").strip()
    else: getEnv("TYPESAFE_API_KEY").strip()
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  else:
    headers["x-coworld-player-slot"] = $view["slot"].getInt()
  let body = %*{
    "model": model,
    "state": "You control one bomber in a simultaneous 2v2 match. " &
      "Choose its order, private two-integer team radio, public narration, " &
      "and private notes independently. The partner receives radio one " &
      "turn late; opponents never see it. Here is this seat's complete " &
      "observation:\n" & $view,
    "questions": {
      "order": {"type": "choice", "instructions":
        "Choose the best ordinary order for this turn.",
        "criteria": orderCriteria},
      "radio": {"type": "choice", "instructions":
        "Choose two private symbols to send your partner.",
        "criteria": radioCriteria},
      "say": {"type": "choice", "instructions":
        "Choose optional public narration.", "criteria": sayCriteria},
      "notes": {"type": "choice", "instructions":
        "Choose private notes for your next turn.", "criteria": noteCriteria}
    }
  }
  pacer.acquire(budgetMs - (getMonoTime() - started).inMilliseconds.int)
  let remaining = budgetMs - (getMonoTime() - started).inMilliseconds.int
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body,
    max(1, (remaining - 500) div 1000))
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let payload = parseJson(response.body)
  let answers = payload["answers"]
  let order = bestChoice(answers["order"], orderCriteria)
  let radio = bestChoice(answers["radio"], radioCriteria)
  let say = bestChoice(answers["say"], sayCriteria)
  let note = bestChoice(answers["notes"], noteCriteria)
  echo "pommerman Jev player: order ", order, " radio ", radio,
    " model ", payload{"model"}.getStr(),
    " input_tokens ", payload["usage"]{"input_tokens"}.getInt(),
    " output_tokens ", payload["usage"]{"output_tokens"}.getInt()
  %*{"order": orders[order], "radio": radios[radio],
    "say": says[say], "notes": notes[note]}
