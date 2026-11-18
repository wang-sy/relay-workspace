#!/usr/bin/env python3
"""Exercise real CLI and stdio MCP clients against a temporary folder or a TypeScript service."""
import argparse
import contextlib
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import urllib.request
import uuid

parser = argparse.ArgumentParser()
parser.add_argument("binary", type=Path)
parser.add_argument("--service", action="store_true", help="start the compiled TypeScript service for this test")
args = parser.parse_args()
binary = str(args.binary.resolve())
server_entry = Path(__file__).resolve().parents[1] / "server/dist/index.js"


@contextlib.contextmanager
def backend(root):
    token = str(uuid.uuid4())
    server_env = dict(os.environ, RELAY_HOST="127.0.0.1", RELAY_PORT="0", RELAY_DB=str(root / "journal.db"),
                      RELAY_MEMBERS_JSON=json.dumps({"test-member": token}))
    with subprocess.Popen(["node", str(server_entry)], env=server_env, stdout=subprocess.PIPE, text=True) as service:
        try:
            with selectors.DefaultSelector() as ready:
                ready.register(service.stdout, selectors.EVENT_READ)
                assert ready.select(15), "service did not become ready"
                line = service.stdout.readline().strip()
            assert line.startswith("Relay listening on http://127.0.0.1:"), line
            yield line.split()[-1], token
        finally:
            service.terminate()
            service.wait(timeout=10)


def exercise(cmd, env):
    request = {"requestID": str(uuid.uuid4()), "change": {
        "operation": "create", "itemID": "sample-direction", "kind": "direction", "title": "First use"
    }}
    writes = [subprocess.Popen(cmd + ["apply"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, env=env) for _ in range(2)]
    for writer in writes:
        writer.stdin.write(json.dumps(request).encode())
        writer.stdin.close()
    for writer in writes:
        assert writer.wait(timeout=30) == 0, writer.stderr.read()
        assert json.load(writer.stdout)["id"].lower() == request["requestID"]
    calls = [
        {"id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25"}},
        {"method": "notifications/initialized"},
        {"id": 2, "method": "tools/list"},
        {"id": 3, "method": "tools/call", "params": {"name": "relay_apply", "arguments": request}},
        {"id": 4, "method": "tools/call", "params": {"name": "relay_read", "arguments": {}}}
    ]
    frames = "".join(json.dumps(dict(jsonrpc="2.0", **c)) + "\n" for c in calls)
    output = subprocess.run(cmd + ["mcp"], input=frames, text=True, capture_output=True, check=True, env=env, timeout=30)
    responses = [json.loads(line)["result"] for line in output.stdout.splitlines()]
    assert len(responses) == 4 and responses[0]["protocolVersion"] == "2025-11-25"
    assert {t["name"] for t in responses[1]["tools"]} == {"relay_read", "relay_apply"}
    assert json.loads(responses[2]["content"][0]["text"])["actor"] == "test-member"
    state = json.loads(responses[3]["content"][0]["text"])
    assert len(state["items"]) == len(state["entries"]) == 1 and not state["conflicts"]
    assert json.loads(subprocess.check_output(cmd + ["gaps"], env=env)) == []
    return state



def exercise_board(cmd, env):
    def apply(change, check=True):
        data = json.dumps({"requestID": str(uuid.uuid4()), "change": change})
        return subprocess.run(cmd + ["apply"], input=data, text=True, env=env, check=check,
                              capture_output=True, timeout=15)

    apply({"operation": "create", "kind": "requirement", "itemID": "r", "title": "Import",
           "parentID": "sample-direction", "start": "2020-01-01T00:00:00Z", "end": "2050-01-01T00:00:00Z",
           "members": [{"name": "owner", "role": "delivery"}]})
    apply({"operation": "create", "kind": "task", "itemID": "t", "parentID": "r", "title": "Verify"})
    handoff = json.loads(apply({"operation": "handoff", "itemID": "t", "recipient": "reviewer",
                                "note": "verify import", "affectsRequirement": True}).stdout)
    rows = json.loads(subprocess.check_output(cmd + ["board"], env=env))
    assert len(rows) == 1 and rows[0]["phase"] == "waiting" and rows[0]["attention"]["id"].lower() == handoff["id"].lower()
    calls = [
        {"id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25"}},
        {"id": 2, "method": "tools/call", "params": {"name": "relay_read", "arguments": {"scope": "board"}}}
    ]
    frames = "".join(json.dumps(dict(jsonrpc="2.0", **c)) + "\n" for c in calls)
    output = subprocess.run(cmd + ["mcp"], input=frames, text=True, capture_output=True, check=True, env=env, timeout=15)
    assert json.loads(json.loads(output.stdout.splitlines()[-1])["result"]["content"][0]["text"]) == rows
    apply({"operation": "acknowledge", "itemID": "t", "reference": handoff["id"], "note": "verified"})
    assert json.loads(subprocess.check_output(cmd + ["board"], env=env))[0]["phase"] == "active"
    assert apply({"operation": "close", "itemID": "r", "note": "  "}, check=False).returncode != 0
    apply({"operation": "close", "itemID": "r", "note": "Import retry shipped"})
    finished = json.loads(subprocess.check_output(cmd + ["board"], env=env))[0]
    assert finished["phase"] == "completedToday" and finished["summary"] == "Import retry shipped"


with tempfile.TemporaryDirectory() as folder:
    if args.service:
        with backend(Path(folder)) as (address, token):
            env = dict(os.environ, RELAY_ACTOR="unverified-label", RELAY_TOKEN=token)
            snapshot = exercise([binary, "--server", address], env)
            req = urllib.request.Request(address + "/v1/workspace", headers={"Authorization": "Bearer " + token})
            with urllib.request.urlopen(req, timeout=5) as result:
                remote = json.load(result)
            assert remote["viewer"] == "test-member"
            assert remote["workspace"]["items"] == snapshot["items"]
            assert len(remote["workspace"]["entries"]) == 1
            exercise_board([binary, "--server", address], env)
        print("Swift CLI and MCP share one durable, attributed HTTP write.")
    else:
        cmd = [binary, "--workspace", folder]
        env = dict(os.environ, RELAY_ACTOR="test-member")
        exercise(cmd, env)
        exercise_board(cmd, env)
        print("CLI and MCP read the same idempotent file write.")
