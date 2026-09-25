## Scripted player choices from the same seat observation used by model players.

import std/json
import bombs, sim_types

proc scriptedAction*(view: JsonNode, baseline: string): JsonNode =
  let
    you = view["you"].getStr()
    boardRows = view["board"]
    dangerRows = view["danger"]
    tick = view["tick"].getInt()
  var me: JsonNode
  var nearestEnemy = -1
  var nearestDistance = high(int)
  for bomber in view["bombers"]:
    if bomber["id"].getStr() == you:
      me = bomber
      break
  let
    x = me["x"].getInt()
    y = me["y"].getInt()
    ammo = me["ammo"].getInt()
  var nearbyEnemies = 0
  var adjacentEnemy = false
  var laneEnemy = false
  for index in 0 ..< view["bombers"].len:
    let bomber = view["bombers"][index]
    if bomber["id"] notin view["enemies"] or not bomber["alive"].getBool():
      continue
    let
      ex = bomber["x"].getInt()
      ey = bomber["y"].getInt()
      distance = abs(x - ex) + abs(y - ey)
    if distance <= 4:
      inc nearbyEnemies
    if distance == 1:
      adjacentEnemy = true
    if distance < nearestDistance:
      nearestDistance = distance
      nearestEnemy = index
    if distance > 0 and distance <= 3 and (x == ex or y == ey):
      let
        dx = (if ex > x: 1 elif ex < x: -1 else: 0)
        dy = (if ey > y: 1 elif ey < y: -1 else: 0)
      var clear = true
      for step in 1 ..< distance:
        if boardRows[y + dy * step].getStr()[x + dx * step] != '.':
          clear = false
      if clear:
        laneEnemy = true

  var adjacentWood = false
  var safeExits = 0
  for offset in DirOffsets:
    let nx = x + offset.dx
    let ny = y + offset.dy
    if nx < 0 or nx >= BoardSize or ny < 0 or ny >= BoardSize:
      continue
    let cell = boardRows[ny].getStr()[nx]
    if cell == 'W':
      adjacentWood = true
    if cell in {'.', 'e', 'r', 'k'} and
        dangerRows[ny].getStr()[nx] == '.':
      inc safeExits

  let collapseSoon = view["collapse"]["next_tick"].getInt() - tick <= 8
  let outsideMiddle = x < 3 or x > 7 or y < 3 or y > 7
  var order = %*{"verb": "hide"}
  if me["alive"].getBool():
    if baseline == "camper":
      if ammo > 0 and (adjacentEnemy or
          (adjacentWood and safeExits >= 2)):
        order = %*{"verb": "bomb"}
      elif collapseSoon and outsideMiddle:
        order = %*{"verb": "go", "x": 5, "y": 5}
    else:
      if ammo > 0 and (laneEnemy or adjacentWood):
        order = %*{"verb": "bomb"}
      else:
        var bestItemDistance = high(int)
        for cy in 0 ..< boardRows.len:
          let row = boardRows[cy]
          for cx, cell in row.getStr():
            if cell in {'e', 'r', 'k'}:
              let distance = abs(x - cx) + abs(y - cy)
              if distance <= 4 and distance < bestItemDistance:
                bestItemDistance = distance
                order = %*{"verb": "go", "x": cx, "y": cy}
        if bestItemDistance == high(int):
          var woodRemains = false
          for row in boardRows:
            if 'W' in row.getStr():
              woodRemains = true
              break
          if woodRemains:
            order = %*{"verb": "break"}
          elif collapseSoon and outsideMiddle:
            order = %*{"verb": "go", "x": 5, "y": 5}
          elif nearestEnemy >= 0:
            order = %*{"verb": "hunt", "target":
              view["bombers"][nearestEnemy]["id"]}
  let radio =
    if baseline == "camper": %*[1, 1]
    else: %*[min(8, ammo + 1), min(8, nearbyEnemies + 1)]
  %*{"order": order, "radio": radio, "say": "", "notes": ""}
