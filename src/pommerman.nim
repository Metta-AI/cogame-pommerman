## The pommerman game server entrypoint.
##
## SEED RANDOMISATION HAPPENS HERE, before `config.update`, so every
## seed-derived draw follows the FINAL seed (the starter's rule). The seed is
## the ONLY randomness in this game and it is used in exactly one place -- the
## map generator's orbit draw -- so two episodes with the same seed and the
## same orders are byte-identical.

import std/[os, random, strutils]
import bitworld/runtime
import pommerman/[sim, server]

when isMainModule:
  let runtimeCfg = readRuntimeConfig()
  var config = defaultGameConfig()
  randomize()
  config.seed = rand(1 .. 2_000_000_000)
  config.update(runtimeCfg.config)
  config.clampConfig()

  let replayOut = block:
    let path = outputPathFromCogameEnv(
      CogameSaveReplayUriEnv, "pommerman.replay")
    if path.len > 0: path
    else: getEnv("POMMERMAN_REPLAY_OUT").strip()
  if replayOut.len > 0:
    let dir = replayOut.parentDir()
    if dir.len > 0:
      createDir(dir)

  runServerLoop(
    host = runtimeCfg.host,
    port = runtimeCfg.port,
    initialConfig = config,
    saveReplayPath = replayOut,
    loadReplayPath = (if runtimeCfg.replayMode:
        pathFromCogameEnv(CogameLoadReplayUriEnv) else: ""),
    runtimeConfig = runtimeCfg
  )
