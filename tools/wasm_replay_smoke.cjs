// Runs the EXACT emitted wasm module headless under Node against a committed
// fixture replay. wasm32-only failures -- integer traps, address-space
// exhaustion, a bad free through -d:useMalloc -- are invisible to the native
// test shards, and the bundle's own browser smoke only proves the page draws.
//
//   node tools/wasm_replay_smoke.cjs <dist dir> <replay path> [frames]
//
// It loads pommerman_replay.js (non-modularized, ENVIRONMENT includes node), calls
// pom_load_replay on the bytes, steps pom_frame the requested number of
// times, and fails if any frame returns < 0, if the packet is ever empty, or if
// pom_mismatch_tick ever reports a divergence.
'use strict';

const fs = require('fs');
const path = require('path');

const distDir = process.argv[2] || 'replay-viewer/dist';
const replayPath = process.argv[3] || 'tests/replays/pommerman.replay';
const frames = Number(process.argv[4] || 400);

const modulePath = path.resolve(distDir, 'pommerman_replay.js');
if (!fs.existsSync(modulePath)) {
  console.error(`missing ${modulePath}`);
  process.exit(1);
}

// The bundle is injected below with `Module` as a function parameter -- a
// plain require() cannot configure it: under the CommonJS wrapper the
// emitted `var Module = typeof Module != "undefined" ? Module : {}` declares
// a new function-scoped binding that shadows any global we set, so it sees
// its own hoisted `undefined`, discards this object and starts from `{}`.
// locateFile and onRuntimeInitialized were silently dropped that way, run()
// never fired, and the smoke exited 0 having tested nothing.
const Module = {
  locateFile: (file) => path.resolve(distDir, file),
  onAbort: (what) => {
    console.error(`wasm aborted: ${what}`);
    process.exit(1);
  },
  onRuntimeInitialized: () => { run(); },
};

function decode(ptrFn, lenFn) {
  const length = Module[lenFn]();
  if (!length) return '';
  const pointer = Module[ptrFn]();
  return Buffer.from(Module.HEAPU8.slice(pointer, pointer + length))
    .toString('utf8');
}

function run() {
  const bytes = fs.readFileSync(replayPath);
  const pointer = Module._malloc(bytes.length);
  Module.HEAPU8.set(bytes, pointer);
  const loaded = Module._pom_load_replay(pointer, bytes.length);
  Module._free(pointer);
  if (!loaded) {
    console.error('pom_load_replay failed: ' +
      (decode('_pom_error_ptr', '_pom_error_len') ||
       decode('_pom_stage_ptr', '_pom_stage_len')));
    process.exit(1);
  }
  let smallest = Infinity;
  for (let i = 0; i < frames; i++) {
    if (Module._pom_frame() < 0) {
      console.error('pom_frame failed: ' +
        decode('_pom_error_ptr', '_pom_error_len'));
      process.exit(1);
    }
    const length = Module._pom_packet_len();
    if (!length) {
      console.error(`empty packet at frame ${i}`);
      process.exit(1);
    }
    smallest = Math.min(smallest, length);
  }
  const mismatch = Module._pom_mismatch_tick();
  if (mismatch >= 0) {
    console.error(`replay hash mismatch at tick ${mismatch}`);
    process.exit(1);
  }
  const packet = JSON.parse(decode('_pom_packet_ptr', '_pom_packet_len'));
  if (!packet.pm || !Array.isArray(packet.pm.bombers)) {
    console.error('the final packet carries no board state');
    process.exit(1);
  }
  console.log(`wasm smoke ok: ${frames} frames, smallest packet ${smallest} ` +
    `bytes, tick ${packet.pm.tick}, alive ${packet.pm.alive.join(' v ')}`);
}

new Function('Module', 'require', '__filename', '__dirname',
  fs.readFileSync(modulePath, 'utf8'))(
  Module, require, modulePath, path.dirname(modulePath));
