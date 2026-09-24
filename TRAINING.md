# Pommerman training

Both certified variants, `teams` and `blitz`, use the same simulator and
decision parser as the hosted game. The post-training exporter plays complete
matches with the shipped sapper and camper policies. It reconstructs the exact
hosted system and user messages from each recorded seat view, including that
seat's private notes field, and emits native JSON orders with both radio
symbols. Whole episodes stay in one data split.

```sh
nimby sync nimby.lock
nim c -d:release --path:src -o:/tmp/pommerman-posttrain tools/export_posttrain.nim
/tmp/pommerman-posttrain /tmp/pommerman-teams-data 10 teams
/tmp/pommerman-posttrain /tmp/pommerman-blitz-data 10 blitz
```

From a Metta checkout with `metta-posttrain` installed:

```sh
uv run --package metta-posttrain --extra train python -m metta_posttrain.train \
  --dataset /tmp/pommerman-teams-data --output /tmp/pommerman-adapter \
  --model Qwen/Qwen3-0.6B --max-steps 100 --max-length 4096
```

Ten complete matches produced 1,080 train and 192 validation decisions for
`teams`, and 592 train and 128 validation decisions for `blitz`. All 1,992
examples fit 4,096 tokens with a local WordLevel smoke tokenizer. One CPU
optimizer step reduced four-example validation loss from 1.74816 to 1.74303
and 1.74302, respectively. This checks the training path, not policy quality.

The persistent numeric bridge exposes 766 values from the acting seat's
redacted view. Seven independent action heads choose an order verb, visible
enemy target, destination, kick direction, and two radio symbols. The native
reply parser validates the resulting order. All four seats decide against the
same pre-turn state, then the game's own frame simulation advances.

```sh
nim c -d:release --path:src -o:/tmp/pommerman-train-bridge tools/train_bridge.nim
python3 tools/test_training.py /tmp/pommerman-train-bridge
```

From a Metta checkout with the Coworld training stack, call
`recipes.external.coworld.train` for native PufferLib or
`recipes.external.coworld_metta_rl.train` for Metta RL. Pass the absolute
bridge path, manifest path, and variant ID as the command. Use `players=4`, a
timestep limit, and `max_decisions=144` to allow a full `teams` game. The
bridge's `semantic_view` and `messages` also expose the seat-visible contract
to collectors outside the game server.
