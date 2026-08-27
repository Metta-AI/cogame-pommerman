// broadcast_core.js — pommerman board renderer and state channel.
//
// Forked from coworld-ctf/client/broadcast_core.js, but a RETARGETED REWRITE,
// not a line-for-line fork: the starter's 1,407 lines are built around the
// Bitworld sprite protocol, vendored SnappyJS and an interpolating pixel
// camera, and none of that survives an 11x11 integer cell grid. What IS kept is
// the CONTRACT the surrounding chrome and the static adapter call through,
// method for method:
//
//   * the module shape -- a dependency-free IIFE publishing
//     `window.BroadcastCore.create`;
//   * every method `replay-viewer/static_replay_worker.js` and
//     `client/page_script.js` invoke: start/stop/ingest/sendCommand/clickMap,
//     zoomAt/setZoom/panBy/panByMap/panTo/resetView/attachMinimap (deliberate
//     no-ops for a fixed board), getTransform/setViewportSize/setViewportFit,
//     getState, getPaceStats;
//   * the callback contract (onText/onStatus/onFirstFrame/onTransform/
//     onSendPacket), the canvas/DPR sizing, the whole-board camera;
//   * the `getPaceStats()` shape `static_replay.js` mirrors
//     ({enabled, queued, presented, interval, draws});
//   * `pushFeed(text)`'s SIGNATURE, because the static adapter latches on a
//     throw from it (cogball 0.1.4) -- the ONE name in this file whose shape,
//     not whose body, is the inherited thing;
//   * the websocket mode the native server page uses, and the `?embed=1` path.
//
// The starter's wire-constants global read is renamed to `window.POM_WIRE`,
// emitted by tools/gen_wire_constants.nim.
//
// DELETED: the Bitworld sprite-protocol compositor and every ctf-specific draw
// call (flags, floor paint, hills, hearts, grenades) and the whole FPV
// pipeline. This game has none of them, and its board is an 11x11 INTEGER GRID
// rather than a pixel arena, so the wire is one UTF-8 JSON state object per
// frame instead of a binary sprite stream.
//
// ADDED: drawArena, drawBombs, drawBlastFootprint, drawDanger, drawRadioGlyphs,
// drawKickTrail, drawScorch.
//
// The native replay page runs this core in a Window. The static bundle runs
// the SAME file in a Dedicated Worker with an OffscreenCanvas. One
// implementation, so a rendering fix cannot drift between the two delivery
// modes.

(function () {
  'use strict';

  var globalScope = typeof window !== 'undefined' ? window : self;
  var requestFrame = typeof globalScope.requestAnimationFrame === 'function'
    ? globalScope.requestAnimationFrame.bind(globalScope)
    : function (cb) { return setTimeout(function () { cb(Date.now()); }, 1000 / 60); };

  var WIRE = globalScope.POM_WIRE || {};
  var SPEEDS = WIRE.speeds || [1, 2, 4, 8];
  var FPS = WIRE.fps || 6;
  var BOARD = WIRE.boardSize || 11;

  var RED = '#e0523a';
  var BLUE = '#3f7cc4';
  var PAPER = '#f2e8d8';
  var AMBER = '#e8a33d';

  var SCORCH_FRAMES = 60;   // a broken wall keeps its mark this long
  var DEBRIS_FRAMES = 6;    // and shatters for this long first
  var KICK_FLASH_FRAMES = 3;

  function createCanvasSurface() {
    if (typeof document !== 'undefined') return document.createElement('canvas');
    if (typeof OffscreenCanvas !== 'undefined') return new OffscreenCanvas(1, 1);
    throw new Error('Canvas rendering is unavailable in this execution context');
  }

  // Asset base. This file is served from two places and a leading slash is
  // only correct at one of them:
  //   native server, page or proxied  ->  <prefix>/client/…
  //   the STATIC WASM BUNDLE          ->  the assets sit next to the worker
  var ART_BASE = (typeof document === 'undefined')
    ? './'
    : (location.pathname.replace(/\/clients?\/[^/]*$/, '') + '/client/');

  function loadBitmap(name) {
    return fetch(ART_BASE + name, { credentials: 'omit' })
      .then(function (r) {
        if (!r.ok) throw new Error(name + ': HTTP ' + r.status);
        return r.blob();
      })
      .then(function (b) { return createImageBitmap(b); });
  }

  // Bomber chips are BAKED ONCE at load: three sizes x (alive, dead outline)
  // per kit, four kits = 24 pre-baked chips, so drawing four bombers a frame is
  // four blits and never a per-bomber rasterisation.
  var CHIP_SIZES = [16, 24, 32];

  function bakeChips(bitmap, rim) {
    var chips = [];
    for (var s = 0; s < CHIP_SIZES.length; s++) {
      chips[s] = [];
      for (var dead = 0; dead < 2; dead++) {
        var size = CHIP_SIZES[s];
        var surface = createCanvasSurface();
        surface.width = size;
        surface.height = size;
        var c = surface.getContext('2d');
        c.clearRect(0, 0, size, size);
        if (bitmap) {
          c.globalAlpha = dead ? 0.28 : 1;
          c.drawImage(bitmap, 0, 0, bitmap.width, bitmap.height, 0, 0, size, size);
          c.globalAlpha = 1;
        } else {
          c.fillStyle = rim;
          c.globalAlpha = dead ? 0.28 : 1;
          c.fillRect(2, 2, size - 4, size - 4);
          c.globalAlpha = 1;
        }
        // 1 px team rim, so two adjacent bombers of opposite teams never read
        // as one blob at 32 px a cell.
        c.strokeStyle = rim;
        c.lineWidth = 1;
        if (dead) c.setLineDash([2, 2]);
        c.strokeRect(0.5, 0.5, size - 1, size - 1);
        chips[s][dead] = surface;
      }
    }
    return chips;
  }

  function BroadcastCore(config) {
    var canvas = config.canvas;
    var onText = config.onText || function () {};
    var onStatus = config.onStatus || function () {};
    var onFirstFrame = config.onFirstFrame || function () {};
    var onTransform = config.onTransform || function () {};
    var onSendPacket = config.onSendPacket || null;

    var ctx = canvas ? canvas.getContext('2d') : null;
    var viewport = {
      width: config.viewportWidth || 1,
      height: config.viewportHeight || 1,
      dpr: config.devicePixelRatio || 1
    };
    var state = null;
    var firstFrameSent = false;
    var running = false;
    var socket = null;
    var draws = 0;
    var scorch = [];          // {x, y, age, team}
    var outlines = [];        // {x, y, team} -- a dead bomber's chalk outline
    var kickFlash = {};       // seat -> frames left
    var dangerOn = true;
    var tiny = false;
    var kits = {};            // "red|blue" + "plain|crown" -> baked chips
    var floorBitmap = null;
    var wallH = null;
    var wallV = null;
    var bombBitmap = null;
    var rangeBitmap = null;
    var kickBitmap = null;
    var floorBake = null;
    var floorBakeKey = '';
    var assetsReady = false;
    var transform = {
      scale: 1, offsetX: 0, offsetY: 0, nativeW: 1, nativeH: 1,
      zoom: 1, minZoom: 1, maxZoom: 1, fitScale: 1,
      focusX: 0, focusY: 0, visW: 1, visH: 1
    };

    // ---- the feed queue -----------------------------------------------------
    // Kept for its SHAPE, not for rows of its own: pushFeed's signature is
    // load-bearing because a drift in it threw mid-replay and latched the
    // static adapter into `failed` with the scrubber still seekable, so every
    // static gate passed (cogball 0.1.4), and getPaceStats().queued reports
    // this queue's depth to `static_replay.js`. The rows the spectator reads
    // are DOM, built by the appended game block.
    var paceQueue = [];
    function pushFeed(text) {
      if (text === undefined || text === null) return;
      paceQueue.push({ text: String(text) });
      while (paceQueue.length > 64) paceQueue.shift();
    }
    function drainFeed() {
      while (paceQueue.length) onText(paceQueue.shift().text);
    }

    function loadAssets() {
      // bomber_<team>[_crown].png is the nano-banana render of the Softmax cog,
      // one kit per role (scripts/art/source/bombers_sheet.png +
      // scripts/art/split_cog_sheet.py). soldier_<team>.png -- the starter's
      // own shipped cog art, carried byte for byte -- is the fallback, so a
      // missing derived sprite degrades to real art rather than to a square.
      function withFallback(preferred, fallback) {
        return loadBitmap(preferred).catch(function () {
          return loadBitmap(fallback).catch(function () { return null; });
        });
      }
      var wanted = [
        withFallback('bomber_red.png', 'soldier_red.png'),
        withFallback('bomber_red_crown.png', 'soldier_red.png'),
        withFallback('bomber_blue.png', 'soldier_blue.png'),
        withFallback('bomber_blue_crown.png', 'soldier_blue.png'),
        loadBitmap('arena_floor.png').catch(function () { return null; }),
        loadBitmap('art/walls/wall_h.jpg').catch(function () { return null; }),
        loadBitmap('art/walls/wall_v.jpg').catch(function () { return null; }),
        loadBitmap('bomb.png').catch(function () { return null; }),
        loadBitmap('powerup_range.png').catch(function () { return null; }),
        loadBitmap('powerup_kick.png').catch(function () { return null; })
      ];
      return Promise.all(wanted).then(function (all) {
        kits['red|plain'] = bakeChips(all[0], RED);
        kits['red|crown'] = bakeChips(all[1], RED);
        kits['blue|plain'] = bakeChips(all[2], BLUE);
        kits['blue|crown'] = bakeChips(all[3], BLUE);
        floorBitmap = all[4];
        wallH = all[5];
        wallV = all[6];
        bombBitmap = all[7];
        rangeBitmap = all[8];
        kickBitmap = all[9];
        assetsReady = true;
      });
    }

    function setViewportSize(width, height, dpr) {
      viewport.width = Math.max(1, width || 1);
      viewport.height = Math.max(1, height || 1);
      viewport.dpr = dpr || viewport.dpr || 1;
      tiny = viewport.width < 640;
      if (canvas) {
        canvas.width = Math.round(viewport.width * viewport.dpr);
        canvas.height = Math.round(viewport.height * viewport.dpr);
      }
      floorBakeKey = '';
      draw();
    }

    function boardSize() {
      return (state && state.pm && state.pm.board && state.pm.board.w) || BOARD;
    }

    function boardGeometry() {
      var size = boardSize();
      var w = canvas ? canvas.width : 1;
      var h = canvas ? canvas.height : 1;
      var cell = Math.max(1, Math.floor(Math.min(w, h) / size));
      var span = cell * size;
      return {
        size: size,
        cell: cell,
        span: span,
        left: Math.floor((w - span) / 2),
        top: Math.floor((h - span) / 2)
      };
    }

    function publishTransform(geo) {
      var next = {
        scale: geo.cell, offsetX: geo.left, offsetY: geo.top,
        nativeW: geo.span, nativeH: geo.span,
        zoom: 1, minZoom: 1, maxZoom: 1, fitScale: geo.cell,
        focusX: geo.size / 2, focusY: geo.size / 2,
        visW: geo.size, visH: geo.size
      };
      var changed = false;
      for (var key in next) {
        if (next[key] !== transform[key]) changed = true;
      }
      transform = next;
      if (changed) onTransform(transform);
    }

    function terrainRows() {
      return (state && state.pm && state.pm.board && state.pm.board.terrain) || [];
    }

    // ---- drawArena ----------------------------------------------------------
    // The floor plate is tiled and darkened 18 % with 1 px cell gridlines, the
    // rigid cells carry the starter's wall tiles with a 1 px highlight (and a
    // red-hot rim once their ring has collapsed), and the wooden walls get a
    // per-cell seeded plank grain so 36 crates do not look stamped.
    function seededGrain(x, y) {
      var h = (x * 73856093) ^ (y * 19349663);
      h = (h ^ (h >>> 13)) >>> 0;
      return (h % 1000) / 1000;
    }

    function bakeFloor(geo) {
      var rows = terrainRows();
      var collapsed = (state && state.pm && state.pm.board &&
        state.pm.board.collapsedRings) || [];
      var key = geo.span + 'x' + geo.cell + '|' + rows.join('') + '|' +
        collapsed.join(',');
      if (floorBakeKey === key && floorBake) return floorBake;
      var surface = createCanvasSurface();
      surface.width = geo.span;
      surface.height = geo.span;
      var fc = surface.getContext('2d');
      fc.fillStyle = '#241a12';
      fc.fillRect(0, 0, geo.span, geo.span);
      if (floorBitmap) {
        var tile = Math.max(32, floorBitmap.width);
        for (var ty = 0; ty < geo.span; ty += tile) {
          for (var tx = 0; tx < geo.span; tx += tile) {
            fc.drawImage(floorBitmap, tx, ty, tile, tile);
          }
        }
      }
      fc.fillStyle = 'rgba(11,7,4,0.18)';
      fc.fillRect(0, 0, geo.span, geo.span);
      // 1 px cell gridlines, so the grid reads with the HUD off
      fc.strokeStyle = 'rgba(242,232,216,0.07)';
      fc.lineWidth = 1;
      for (var g = 1; g < geo.size; g++) {
        var p = g * geo.cell + 0.5;
        fc.beginPath(); fc.moveTo(p, 0); fc.lineTo(p, geo.span); fc.stroke();
        fc.beginPath(); fc.moveTo(0, p); fc.lineTo(geo.span, p); fc.stroke();
      }
      var maxRing = collapsed.length ? Math.max.apply(null, collapsed) : 0;
      for (var y = 0; y < rows.length; y++) {
        for (var x = 0; x < rows[y].length; x++) {
          var ch = rows[y][x];
          var px = x * geo.cell;
          var py = y * geo.cell;
          var ring = Math.min(Math.min(x, y),
            Math.min(geo.size - 1 - x, geo.size - 1 - y));
          if (ch === '#') {
            var tileArt = ((x + y) % 2 === 0) ? wallH : wallV;
            if (tileArt) {
              fc.drawImage(tileArt, 0, 0, tileArt.width, tileArt.height,
                px, py, geo.cell, geo.cell);
            } else {
              fc.fillStyle = '#4a3a2c';
              fc.fillRect(px, py, geo.cell, geo.cell);
            }
            fc.strokeStyle = (ring >= 1 && ring <= maxRing)
              ? 'rgba(224,82,58,0.85)' : 'rgba(242,232,216,0.16)';
            fc.lineWidth = 1;
            fc.strokeRect(px + 0.5, py + 0.5, geo.cell - 1, geo.cell - 1);
          } else if (ch === 'W') {
            var grain = seededGrain(x, y);
            fc.fillStyle = 'rgb(' + Math.round(126 + grain * 26) + ',' +
              Math.round(88 + grain * 20) + ',' +
              Math.round(52 + grain * 14) + ')';
            fc.fillRect(px, py, geo.cell, geo.cell);
            fc.strokeStyle = 'rgba(60,38,20,0.75)';
            fc.lineWidth = 1;
            var planks = Math.max(2, Math.round(geo.cell / 8));
            for (var k = 1; k < planks; k++) {
              var ly = py + Math.round(k * geo.cell / planks) + 0.5;
              fc.beginPath(); fc.moveTo(px, ly); fc.lineTo(px + geo.cell, ly);
              fc.stroke();
            }
            fc.strokeStyle = 'rgba(255,225,190,0.18)';
            fc.strokeRect(px + 0.5, py + 0.5, geo.cell - 1, geo.cell - 1);
          }
        }
      }
      fc.strokeStyle = 'rgba(242,232,216,0.28)';
      fc.strokeRect(0.5, 0.5, geo.span - 1, geo.span - 1);
      floorBake = surface;
      floorBakeKey = key;
      return surface;
    }

    function drawArena(geo) {
      ctx.drawImage(bakeFloor(geo), geo.left, geo.top);
    }

    // ---- drawScorch ---------------------------------------------------------
    function drawScorch(geo) {
      for (var i = scorch.length - 1; i >= 0; i--) {
        var mark = scorch[i];
        mark.age++;
        if (mark.age > SCORCH_FRAMES) { scorch.splice(i, 1); continue; }
        var px = geo.left + mark.x * geo.cell;
        var py = geo.top + mark.y * geo.cell;
        if (mark.age <= DEBRIS_FRAMES) {
          var frac = 1 - mark.age / DEBRIS_FRAMES;
          ctx.fillStyle = 'rgba(226,190,140,' + frac.toFixed(2) + ')';
          var bits = 6;
          for (var b = 0; b < bits; b++) {
            var a = (b / bits) * Math.PI * 2;
            var r = (1 - frac) * geo.cell * 0.7;
            ctx.fillRect(
              px + geo.cell / 2 + Math.cos(a) * r - 1,
              py + geo.cell / 2 + Math.sin(a) * r - 1, 2, 2);
          }
        }
        ctx.fillStyle = 'rgba(24,14,8,' +
          (0.4 * (1 - mark.age / SCORCH_FRAMES)).toFixed(2) + ')';
        ctx.fillRect(px, py, geo.cell, geo.cell);
      }
      for (var o = 0; o < outlines.length; o++) {
        var out = outlines[o];
        ctx.strokeStyle = out.team === 'red'
          ? 'rgba(224,82,58,0.42)' : 'rgba(63,124,196,0.42)';
        ctx.setLineDash([3, 3]);
        ctx.lineWidth = 1;
        ctx.strokeRect(
          geo.left + out.x * geo.cell + 2.5, geo.top + out.y * geo.cell + 2.5,
          geo.cell - 5, geo.cell - 5);
        ctx.setLineDash([]);
      }
    }

    // ---- drawDanger ---------------------------------------------------------
    // The state packet's decoded danger grid: an amber tint on cells that catch
    // fire within three ticks, deepening as the count falls. Under .tiny it
    // drops to a flat tint with no per-cell digits.
    function drawDanger(geo) {
      if (!dangerOn) return;
      var rows = (state.pm && state.pm.danger) || [];
      for (var y = 0; y < rows.length; y++) {
        for (var x = 0; x < rows[y].length; x++) {
          var ch = rows[y][x];
          if (ch < '0' || ch > '9') continue;
          var value = ch.charCodeAt(0) - 48;
          if (value > 3) continue;
          var alpha = tiny ? 0.22 : (0.34 - value * 0.07);
          ctx.fillStyle = 'rgba(232,163,61,' + alpha.toFixed(3) + ')';
          ctx.fillRect(geo.left + x * geo.cell, geo.top + y * geo.cell,
            geo.cell, geo.cell);
        }
      }
    }

    // ---- drawBlastFootprint -------------------------------------------------
    // Every bomb draws its CHAIN-RESOLVED footprint as a translucent
    // team-tinted cross on exactly the cells it will cover, from the same
    // bombs.nim proc the sim uses -- so what a spectator sees is what will
    // burn. Overlapping footprints blend, which is how a chain reads.
    function drawBlastFootprint(geo) {
      var bombs = (state.pm && state.pm.bombs) || [];
      ctx.globalCompositeOperation = 'lighter';
      for (var i = 0; i < bombs.length; i++) {
        var bomb = bombs[i];
        var urgent = bomb.fuse <= 2;
        var base = bomb.team === 'red' ? '224,82,58' : '63,124,196';
        ctx.fillStyle = 'rgba(' + base + ',' + (urgent ? 0.26 : 0.13) + ')';
        for (var c = 0; c < bomb.blast.length; c++) {
          ctx.fillRect(
            geo.left + bomb.blast[c][0] * geo.cell,
            geo.top + bomb.blast[c][1] * geo.cell, geo.cell, geo.cell);
        }
      }
      ctx.globalCompositeOperation = 'source-over';
    }

    // ---- drawFlames ---------------------------------------------------------
    // Procedural additive orange/white quads, three frames of life.
    function drawFlames(geo) {
      var flames = (state.pm && state.pm.board && state.pm.board.flame) || [];
      ctx.globalCompositeOperation = 'lighter';
      for (var i = 0; i < flames.length; i++) {
        var f = flames[i];
        var px = geo.left + f[0] * geo.cell;
        var py = geo.top + f[1] * geo.cell;
        ctx.fillStyle = 'rgba(255,150,40,0.72)';
        ctx.fillRect(px, py, geo.cell, geo.cell);
        var inset = Math.max(1, Math.round(geo.cell * 0.22));
        ctx.fillStyle = 'rgba(255,236,190,0.82)';
        ctx.fillRect(px + inset, py + inset,
          geo.cell - inset * 2, geo.cell - inset * 2);
      }
      ctx.globalCompositeOperation = 'source-over';
    }

    // ---- drawItems ----------------------------------------------------------
    function drawItems(geo) {
      var items = (state.pm && state.pm.board && state.pm.board.items) || [];
      for (var i = 0; i < items.length; i++) {
        var item = items[i];
        var px = geo.left + item.x * geo.cell;
        var py = geo.top + item.y * geo.cell;
        var inset = Math.max(2, Math.round(geo.cell * 0.18));
        var size = geo.cell - inset * 2;
        var art = item.kind === 'range' ? rangeBitmap
          : (item.kind === 'kick' ? kickBitmap : bombBitmap);
        if (art) {
          ctx.drawImage(art, 0, 0, art.width, art.height,
            px + inset, py + inset, size, size);
        } else {
          ctx.fillStyle = item.kind === 'range' ? '#8fd07a'
            : (item.kind === 'kick' ? '#7ab6d0' : '#d0b06a');
          ctx.fillRect(px + inset, py + inset, size, size);
        }
        // a gold rim, so a power-up reads as loot against the floor
        ctx.strokeStyle = 'rgba(232,192,90,0.9)';
        ctx.lineWidth = 1;
        ctx.strokeRect(px + inset - 0.5, py + inset - 0.5, size + 1, size + 1);
        if (item.kind === 'extrabomb') {
          ctx.fillStyle = AMBER;
          ctx.fillRect(px + geo.cell - inset - 5, py + inset + 1, 4, 1);
          ctx.fillRect(px + geo.cell - inset - 4, py + inset, 1, 3);
        }
      }
    }

    // ---- drawBombs ----------------------------------------------------------
    // Every bomb draws its art plus a COUNTDOWN RING whose arc shrinks with the
    // fuse and the NUMERIC FUSE in the centre (a digit, never a symbol). The
    // ring pulses red on the last two ticks.
    function drawBombs(geo) {
      var bombs = (state.pm && state.pm.bombs) || [];
      var maxFuse = 8;
      for (var i = 0; i < bombs.length; i++) {
        var bomb = bombs[i];
        var px = geo.left + bomb.x * geo.cell;
        var py = geo.top + bomb.y * geo.cell;
        var inset = Math.max(2, Math.round(geo.cell * 0.14));
        var size = geo.cell - inset * 2;
        if (bombBitmap) {
          ctx.drawImage(bombBitmap, 0, 0, bombBitmap.width, bombBitmap.height,
            px + inset, py + inset, size, size);
        } else {
          ctx.fillStyle = '#191410';
          ctx.beginPath();
          ctx.arc(px + geo.cell / 2, py + geo.cell / 2, size / 2, 0,
            Math.PI * 2);
          ctx.fill();
        }
        drawKickTrail(geo, bomb);
        var urgent = bomb.fuse <= 2;
        ctx.strokeStyle = urgent ? '#ff6a4a'
          : (bomb.team === 'red' ? RED : BLUE);
        ctx.lineWidth = Math.max(2, Math.round(geo.cell * 0.09));
        ctx.beginPath();
        ctx.arc(px + geo.cell / 2, py + geo.cell / 2,
          geo.cell / 2 - ctx.lineWidth, -Math.PI / 2,
          -Math.PI / 2 + Math.PI * 2 * Math.max(0, bomb.fuse) / maxFuse);
        ctx.stroke();
        var digits = tiny ? 14 : Math.max(12, Math.round(geo.cell * 0.46));
        ctx.font = digits + 'px system-ui, sans-serif';
        ctx.textAlign = 'center';
        ctx.textBaseline = 'middle';
        ctx.lineWidth = 1;
        ctx.strokeStyle = 'rgba(12,9,6,0.95)';
        ctx.strokeText(String(Math.max(0, bomb.fuse)),
          px + geo.cell / 2, py + geo.cell / 2);
        ctx.fillStyle = urgent ? '#ffd7c8' : PAPER;
        ctx.fillText(String(Math.max(0, bomb.fuse)),
          px + geo.cell / 2, py + geo.cell / 2);
      }
    }

    // ---- drawKickTrail ------------------------------------------------------
    // A bomb with moving != "none" draws a bright team-coloured motion trail
    // with a chevron in its direction of travel.
    function drawKickTrail(geo, bomb) {
      if (!bomb.moving || bomb.moving === 'none') return;
      var dx = bomb.moving === 'left' ? -1 : (bomb.moving === 'right' ? 1 : 0);
      var dy = bomb.moving === 'up' ? -1 : (bomb.moving === 'down' ? 1 : 0);
      var cx = geo.left + bomb.x * geo.cell + geo.cell / 2;
      var cy = geo.top + bomb.y * geo.cell + geo.cell / 2;
      ctx.strokeStyle = bomb.team === 'red' ? RED : BLUE;
      ctx.lineWidth = Math.max(2, Math.round(geo.cell * 0.1));
      for (var t = 1; t <= 3; t++) {
        ctx.globalAlpha = 0.5 / t;
        ctx.beginPath();
        ctx.moveTo(cx - dx * geo.cell * t * 0.6, cy - dy * geo.cell * t * 0.6);
        ctx.lineTo(cx - dx * geo.cell * (t - 1) * 0.6,
          cy - dy * geo.cell * (t - 1) * 0.6);
        ctx.stroke();
      }
      ctx.globalAlpha = 1;
      ctx.beginPath();
      ctx.moveTo(cx + dx * geo.cell * 0.42 - dy * geo.cell * 0.2,
        cy + dy * geo.cell * 0.42 - dx * geo.cell * 0.2);
      ctx.lineTo(cx + dx * geo.cell * 0.6, cy + dy * geo.cell * 0.6);
      ctx.lineTo(cx + dx * geo.cell * 0.42 + dy * geo.cell * 0.2,
        cy + dy * geo.cell * 0.42 + dx * geo.cell * 0.2);
      ctx.stroke();
    }

    // ---- drawBombers --------------------------------------------------------
    function drawBombers(geo) {
      var bombers = (state.pm && state.pm.bombers) || [];
      var sizeIndex = geo.cell >= 30 ? 2 : (geo.cell >= 20 ? 1 : 0);
      for (var i = 0; i < bombers.length; i++) {
        var b = bombers[i];
        if (!b.alive) continue;
        var kit = kits[b.team + '|' + b.skin];
        var px = geo.left + b.x * geo.cell;
        var py = geo.top + b.y * geo.cell;
        if (kickFlash[b.seat] > 0) {
          kickFlash[b.seat]--;
          ctx.fillStyle = 'rgba(242,232,216,0.5)';
          ctx.fillRect(px, py, geo.cell, geo.cell);
        }
        if (kit) {
          ctx.drawImage(kit[sizeIndex][0], px, py, geo.cell, geo.cell);
        } else {
          ctx.fillStyle = b.team === 'red' ? RED : BLUE;
          ctx.fillRect(px + 2, py + 2, geo.cell - 4, geo.cell - 4);
        }
      }
    }

    // ---- drawRadioGlyphs ----------------------------------------------------
    // The pair a seat sent this turn, drawn over that bomber as two digits 1..8
    // in the team colour inside a small radio-wave badge. BOTH teams' pairs are
    // visible to the spectator: the replay is spectator-side, and the hiding is
    // enforced in the observation builder, never in the renderer.
    function drawRadioGlyphs(geo) {
      var bombers = (state.pm && state.pm.bombers) || [];
      var digits = tiny ? 12 : Math.max(10, Math.round(geo.cell * 0.38));
      ctx.font = digits + 'px system-ui, sans-serif';
      ctx.textAlign = 'center';
      ctx.textBaseline = 'alphabetic';
      for (var i = 0; i < bombers.length; i++) {
        var b = bombers[i];
        if (!b.alive || !b.radio) continue;
        var cx = geo.left + b.x * geo.cell + geo.cell / 2;
        var cy = geo.top + b.y * geo.cell - 2;
        if (cy < digits + 2) cy = geo.top + b.y * geo.cell + geo.cell + digits;
        var text = '\u224b' + b.radio[0] + '\u00b7' + b.radio[1];
        var w = ctx.measureText(text).width + 6;
        ctx.fillStyle = 'rgba(12,9,6,0.72)';
        ctx.fillRect(cx - w / 2, cy - digits, w, digits + 3);
        ctx.lineWidth = 1;
        ctx.strokeStyle = 'rgba(12,9,6,0.95)';
        ctx.strokeText(text, cx, cy);
        ctx.fillStyle = b.team === 'red' ? RED : BLUE;
        ctx.fillText(text, cx, cy);
      }
    }

    function draw() {
      if (!ctx || !state) return;
      var geo = boardGeometry();
      publishTransform(geo);
      ctx.fillStyle = '#120d09';
      ctx.fillRect(0, 0, canvas.width, canvas.height);
      drawArena(geo);
      drawScorch(geo);
      drawDanger(geo);
      drawBlastFootprint(geo);
      drawItems(geo);
      drawBombs(geo);
      drawFlames(geo);
      drawBombers(geo);
      drawRadioGlyphs(geo);
      draws++;
    }

    function ingest(bytes) {
      var text;
      if (typeof bytes === 'string') text = bytes;
      else text = new TextDecoder('utf-8').decode(bytes);
      var next;
      try {
        next = JSON.parse(text);
      } catch (error) {
        throw new Error('state frame is not JSON: ' + error.message);
      }
      var jumped = !!(state && next.pm && state.pm && next.t < state.t);
      state = next;
      if (jumped) { scorch = []; outlines = []; kickFlash = {}; }
      var broken = (state.pm && state.pm.scorch) || [];
      for (var i = 0; i < broken.length; i++) {
        scorch.push({ x: broken[i].x, y: broken[i].y, age: 0,
          team: broken[i].team });
      }
      var deaths = (state.pm && state.pm.deaths) || [];
      for (var d = 0; d < deaths.length; d++) {
        outlines.push({ x: deaths[d].x, y: deaths[d].y, team: deaths[d].team });
      }
      var events = (state.pm && state.pm.events) || [];
      for (var e = 0; e < events.length; e++) {
        if (events[e].k === 'kick') kickFlash[events[e].seat] = KICK_FLASH_FRAMES;
      }
      while (scorch.length > 300) scorch.shift();
      while (outlines.length > 16) outlines.shift();
      // The visible feed is DOM, built by the appended game block from this
      // same `pm.events` array (client/game_block.html). The core formats no
      // rows of its own: the page's onText IS its JSON frame parser, so a
      // plain-text row handed to it is parsed, fails and is dropped. One
      // vocabulary, in one place.
      onText(text);
      drainFeed();
      draw();
      if (!firstFrameSent) {
        firstFrameSent = true;
        onFirstFrame();
      }
    }

    function sendCommand(textCommand) {
      if (onSendPacket) {
        onSendPacket(new TextEncoder().encode(String(textCommand)));
        return;
      }
      if (socket && socket.readyState === 1) socket.send(String(textCommand));
    }

    function connect() {
      var url = config.websocket;
      if (typeof url !== 'string' || !url.length) return;
      onStatus('connecting');
      socket = new WebSocket(url);
      socket.onopen = function () { onStatus('open'); };
      socket.onclose = function () { onStatus('closed'); };
      socket.onerror = function () { onStatus('closed'); };
      socket.onmessage = function (event) {
        if (typeof event.data === 'string') ingest(event.data);
      };
    }

    function tick() {
      if (!running) return;
      draw();
      requestFrame(tick);
    }

    function start() {
      if (running) return;
      running = true;
      loadAssets().then(function () {
        floorBakeKey = '';
        draw();
        // The static bundle has no socket, so nothing would ever move the
        // status chip off 'connecting' and the featured match would show
        // CONNECTING over a playing replay for the whole episode. Assets baked
        // and the first frame drawn IS this delivery mode's 'open'.
        if (!config.websocket) onStatus('open');
      });
      if (config.websocket) connect();
      requestFrame(tick);
    }

    function stop() {
      running = false;
      if (socket) { try { socket.close(); } catch (e) {} socket = null; }
    }

    return {
      start: start,
      stop: stop,
      ingest: ingest,
      sendCommand: sendCommand,
      clickMap: function () {},
      // Zoom and pan are NO-OPS by design: the board is a fixed 11x11 square
      // grid with a 1:1 aspect and no off-frame area, so #viewpanel is dropped.
      // The methods stay so the static adapter's API surface is unchanged.
      zoomAt: function () {},
      setZoom: function () {},
      panBy: function () {},
      panByMap: function () {},
      panTo: function () {},
      resetView: function () {},
      attachMinimap: function () {},
      setDanger: function (on) { dangerOn = !!on; draw(); },
      getDanger: function () { return dangerOn; },
      getTransform: function () { return transform; },
      setViewportSize: setViewportSize,
      setViewportFit: function () { draw(); },
      getState: function () { return state; },
      getPaceStats: function () {
        return {
          enabled: false, queued: paceQueue.length, presented: 0,
          interval: 1000 / FPS, draws: draws
        };
      },
      assetsReady: function () { return assetsReady; },
      SPEEDS: SPEEDS
    };
  }

  globalScope.BroadcastCore = { create: BroadcastCore };
})();
