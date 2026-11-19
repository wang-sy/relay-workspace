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
import time
import urllib.error
import urllib.request
import uuid

parser = argparse.ArgumentParser()
parser.add_argument("binary", type=Path)
parser.add_argument("--service", action="store_true", help="start the compiled TypeScript service for this test")
args = parser.parse_args()
binary = str(args.binary.resolve())
server_entry = Path(__file__).resolve().parents[1] / "server/dist/index.js"


@contextlib.contextmanager
def backend(root, local=False):
    token = str(uuid.uuid4())
    server_env = dict(os.environ, RELAY_HOST="127.0.0.1", RELAY_PORT="0", RELAY_DB=str(root / "journal.db"),
                      RELAY_MEMBERS_JSON="" if local else json.dumps({"test-member": token}),
                      RELAY_LOCAL_AGENT_DIR=str(root / "agent-keys"))
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
    expected = {"relay_read", "relay_apply"}
    if "--server" in cmd:
        expected.update(["relay_functions","relay_recall","relay_attach"])
    assert {t["name"] for t in responses[1]["tools"]} == expected
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


def exercise_types(cmd, env):
    fixture = server_entry.parents[2] / "Examples/experiment.jsonl"
    writes = [json.loads(line) for line in fixture.read_text().splitlines()]
    calls = [{"method": "initialize", "params": {}}]
    for write in writes:
        calls.append({"method": "tools/call", "params": {"name": "relay_apply", "arguments": write}})
    calls.append({"method": "tools/call", "params": {"name": "relay_read", "arguments": {"scope": "types"}}})
    frames = "".join(json.dumps(dict(jsonrpc="2.0", id=i, **call)) + "\n" for i, call in enumerate(calls))
    result = subprocess.run(cmd + ["mcp"], env=env, input=frames, text=True, capture_output=True, check=True, timeout=20)
    replies = [json.loads(line)["result"] for line in result.stdout.splitlines()]
    assert len(replies) == len(calls) and all(not r.get("isError") for r in replies), replies
    catalog = json.loads(replies[-1]["content"][0]["text"])
    assert catalog == json.loads(subprocess.check_output(cmd + ["types"], env=env))
    assert "experiment" in catalog["items"] and "实验复核" in catalog["triggers"]
    assert "产品 / 用户研究" in catalog["categories"] and "实验设计" in catalog["roles"]
    assert catalog["eventFields"]["复验通过"] == ["passRate"] and catalog["itemFields"]["experiment"] == ["sampleSize"]
    def apply(change, valid=True):
        reply = subprocess.run(cmd + ["apply"], env=env, input=json.dumps({"requestID": str(uuid.uuid4()), "change": change}),
                               capture_output=True, text=True, timeout=10)
        assert (reply.returncode == 0) == valid, reply.stderr
    apply({"operation": "update", "itemID": "EX-first-use", "fields": {"sampleSize": False}}, valid=False)
    apply({"operation": "复验通过", "itemID": "EX-first-use", "payload": {"passRate": "bad"}}, valid=False)
    apply({"operation": "复验通过", "itemID": "EX-first-use", "fields": {"sampleSize": None, "notes": ["ok", {"x": True}]}})
    apply({"operation": "create", "itemID": "other", "kind": "用户访谈", "title": "团队访谈"})
    apply({"operation": "create", "itemID": "deeper", "kind": "问题", "title": "反馈", "parentID": "other"})
    apply({"operation": "update", "itemID": "other", "parentID": "deeper"}, valid=False)
    state = json.loads(subprocess.check_output(cmd + ["read"], env=env))
    assert not state["conflicts"] and state["items"]["EX-first-use"]["baseKind"] == "idea"
    assert state["items"]["EX-first-use"]["fields"] == {"notes": ["ok", {"x": True}]}
    assert "用户访谈" in json.loads(subprocess.check_output(cmd + ["types"], env=env))["items"]


def exercise_functions(cmd, env):
    definition = json.loads((server_entry.parents[2] / "Examples/pause-review.json").read_text())
    definition["trigger"]["delaySeconds"] = 1
    definition["trigger"]["itemID"] = "t"
    def cli(arguments, body=None):
        reply = subprocess.run(cmd + arguments, input=json.dumps(body) if body else None,
                               capture_output=True, text=True, check=True, env=env, timeout=15)
        return json.loads(reply.stdout)

    calls = [
        {"id": 1, "method": "initialize", "params": {}},
        {"id": 2, "method": "tools/call", "params": {"name": "relay_functions",
            "arguments": {"action": "deploy", **definition}}},
    ]
    frames = "".join(json.dumps(dict(jsonrpc="2.0", **call)) + "\n" for call in calls)
    mcp = subprocess.run(cmd + ["mcp"], input=frames, capture_output=True, text=True, check=True, env=env, timeout=15)
    deployed = json.loads(json.loads(mcp.stdout.splitlines()[-1])["result"]["content"][0]["text"])
    assert deployed["actor"] == "test-member" and deployed["revision"] == 1
    pause = {"requestID": str(uuid.uuid4()), "change": {"operation": "pause", "itemID": "t", "recipient": "reviewer"}}
    cli(["apply"], pause)
    cli(["apply"], pause)
    # The publishing MCP process and both CLI writers have already exited.
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        function = cli(["functions", "get", definition["id"]])
        if function["runs"] and function["runs"][0]["status"] == "succeeded":
            break
        time.sleep(0.25)
    else:
        raise AssertionError(function)
    assert len(function["runs"]) == 1 and function["runs"][0]["writes"] == 1
    reminders = [e for e in cli(["read"])["entries"] if e["change"]["operation"] == "remind"]
    assert len(reminders) == 1 and reminders[0]["change"]["recipient"] == "reviewer"
    assert reminders[0]["change"]["reference"].lower() == pause["requestID"]
    assert cli(["functions", "disable", definition["id"], "1"])["enabled"] is False
    definition.update(expectedRevision=2, name="Updated pause review")
    assert cli(["functions", "deploy"], definition)["revision"] == 3
    assert cli(["functions", "list"])[0]["name"] == definition["name"]


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
            exercise_functions([binary, "--server", address], env)
            exercise_types([binary, "--server", address], env)
        with tempfile.TemporaryDirectory() as local_dir:
            root = Path(local_dir)
            with backend(root, local=True) as (address, _):
                env = dict(os.environ, RELAY_ACTOR="test-member", RELAY_LOCAL_AGENT_DIR=str(root / "agent-keys"))
                env.pop("RELAY_TOKEN", None)
                key = next((root / "agent-keys").glob("*.token"))
                assert key.stat().st_mode & 0o077 == 0
                req = urllib.request.Request(address + "/v1/events", data=b"{}", headers={
                    "X-Relay-Client": "agent", "Content-Type": "application/json"})
                try:
                    urllib.request.urlopen(req, timeout=5)
                    raise AssertionError("anonymous local writer accepted")
                except urllib.error.HTTPError as error:
                    assert error.code == 403
                exercise([binary, "--server", address], env)
        print("Swift CLI and MCP share custom types, event payloads, attributed writes and hosted functions.")
    else:
        cmd = [binary, "--workspace", folder]
        env = dict(os.environ, RELAY_ACTOR="test-member")
        exercise(cmd, env)
        exercise_board(cmd, env)
        exercise_types(cmd, env)
        print("CLI and MCP share custom types and replay idempotent file writes.")
