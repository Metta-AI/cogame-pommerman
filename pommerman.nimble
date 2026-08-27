version       = "0.1.0"
author        = "Softmax"
description   = "Pommerman as a Coworld: four bombers, 2v2, and a two-integer private team radio"
license       = "MIT"
srcDir        = "src"
bin           = @["pommerman", "pommerman_player"]

requires "nim >= 2.2.4"
requires "mummy"
requires "curly"
requires "whisky"
requires "jsony"
requires "bitworld"
