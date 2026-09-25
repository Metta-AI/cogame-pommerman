## Export complete hosted episodes with the game server's own seat views.

import std/[json, os, osproc, strutils]
import pommerman/[sim, baselines, decide, episode, llm, replays, roster]

when isMainModule:
  let args = commandLineParams()
  if args.len != 3:
    quit("usage: pommerman-posttrain OUTPUT EPISODES VARIANT", 1)
  let output = args[0]
  let episodes = parseInt(args[1])
  let variant = args[2]
  if episodes < 10: quit("at least ten games are required", 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = copy(entry["game_config"])
  doAssert variantConfig.kind == JObject
  createDir(output)
  let revision = execProcess("git rev-parse HEAD").strip()
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in 1 .. episodes:
    var config = defaultGameConfig()
    variantConfig["seed"] = %seed
    config.update($variantConfig)
    config.gameOverTicks = 1
    config.lobbyJoinTimeoutTicks = 1
    config.startWaitTicks = 0
    var engine = initDecisionEngine()
    for seat in 0 ..< SeatCount:
      engine.seats[seat].baseline =
        if (seed + seat) mod 2 == 0: blSapper else: blCamper
    let run = runHeadlessEpisode(config, engine, "")
    doAssert run.state.finished and run.sim.endReason == ReasonComplete
    let replay = parseReplayBytes(run.bytes)
    var rows: seq[string]
    for chat in replay.chats:
      let record = parseJson(chat.text)
      if record["k"].getStr() != "directive":
        continue
      doAssert record["source"].getStr() == "scripted"
      let view = copy(record["view"])
      doAssert view.kind == JObject
      view["your_notes"] = %""
      var order = %*{"verb": record["verb"]}
      case record["verb"].getStr()
      of "go":
        order["x"] = record["arg"]["x"]
        order["y"] = record["arg"]["y"]
      of "hunt": order["target"] = record["arg"]
      of "kick": order["dir"] = record["arg"]
      else: discard
      let reply = %*{
        "order": order, "radio": record["radio"],
        "say": record["say"], "notes": ""
      }
      rows.add($(%*{
        "episode_id": "pommerman-" & variant & "-" & $seed,
        "seed": "pommerman-" & variant & "-" & $seed,
        "decision_id": rows.len,
        "prompt": [
          {"role": "system", "content": SystemPrompt},
          {"role": "user", "content": userMessage("", $view)}
        ],
        "completion": [{"role": "assistant", "content": $reply}],
        "game": "pommerman",
        "action_schema_revision": "pommerman-reply-v1"
      }))
    doAssert rows.len == run.sim.turnsPlayed * SeatCount
    if seed mod 5 == 0: validationRows.add(rows)
    else: trainRows.add(rows)
    let results = parseJson(run.sim.bomberResultsJson())
    runs.add(%*{
      "seed": seed, "turns": run.sim.turnsPlayed,
      "decisions": rows.len, "scores": results["scores"],
      "reason": results["reason"]
    })
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "pommerman", "variant": variant,
    "source_revision": revision, "teacher": "sapper-and-camper",
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len, "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
