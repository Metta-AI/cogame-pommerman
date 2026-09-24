"""Run complete Pommerman games through the published training interface."""

import json
import random
import subprocess
import sys
from pathlib import Path


manifest = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"
for variant in ("teams", "blitz"):
    for policy in ("teacher", "random"):
        with subprocess.Popen(
            [sys.argv[1], str(manifest), variant],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
        ) as bridge:
            assert bridge.stdin is not None and bridge.stdout is not None

            def request(payload):
                bridge.stdin.write(json.dumps(payload) + "\n")
                bridge.stdin.flush()
                return json.loads(bridge.stdout.readline())

            observation = request({"kind": "reset", "seed": f"{variant}-{policy}", "players": 4})
            decisions = 0
            width = None
            rng = random.Random(42)
            while observation["kind"] == "decision":
                view = observation["semantic_view"]
                assert "hidden" not in view and "your_notes" not in view
                assert len(view["board"]) == len(view["danger"]) == 11
                assert all(len(row) == 11 for row in view["board"])
                assert all(len(row) == 11 for row in view["danger"])
                assert observation["messages"][0]["content"].startswith("You command ONE bomber")
                assert '"your_notes":""' in observation["messages"][1]["content"]
                encoded = request({"kind": "encode"})
                assert encoded["decision_id"] == observation["decision_id"]
                width = len(encoded["values"]) if width is None else width
                assert len(encoded["values"]) == width == 766
                assert [len(head["choices"]) for head in encoded["action_heads"]] == [7, 2, 11, 11, 4, 8, 8]
                if policy == "teacher":
                    action = json.loads(request({"kind": "teacher"})["response"])
                else:
                    action = {
                        head["name"]: rng.choice([value for value in head["choices"] if value is not None])
                        for head in encoded["action_heads"]
                    }
                assert all(action[head["name"]] in head["choices"] for head in encoded["action_heads"])
                result = request(
                    {"kind": "step", "decision_id": observation["decision_id"], "response": json.dumps(action)}
                )
                assert result["kind"] == "accepted" and result["action"] == action
                observation = result["observation"]
                decisions += 1
            scores = observation["scores"]
            assert 0 < decisions <= (144 if variant == "teams" else 96)
            assert decisions % 4 == 0
            assert set(scores) == {"0", "1", "2", "3"}
            assert sum(scores.values()) == 0
            assert scores["0"] == scores["2"] and scores["1"] == scores["3"]
            bridge.stdin.close()
            assert bridge.wait() == 0
        print(f"{variant} {policy}: {decisions} decisions, {width} values")
