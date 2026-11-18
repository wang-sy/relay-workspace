#!/usr/bin/env python3
"""Exercise the real CLI and stdio MCP server against an isolated workspace."""
import json
import os
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory() as root:
    cmd = [binary, "--workspace", root]
    request = {"requestID": str(uuid.uuid4()), "change": {
        "operation": "create", "itemID": "sample-direction", "kind": "direction", "title": "First use"
    }}
    env = dict(os.environ, RELAY_ACTOR="test-member")
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
    frames = "".join(json.dumps(dict(jsonrpc="2.0", **c))+"\n" for c in calls)
    output = subprocess.run(cmd + ["mcp"], input=frames, text=True, capture_output=True, check=True, env=env)
    responses = [json.loads(line)["result"] for line in output.stdout.splitlines()]
    assert len(responses) == 4 and responses[0]["protocolVersion"] == "2025-11-25"
    assert {t["name"] for t in responses[1]["tools"]} == {"relay_read", "relay_apply"}
    assert json.loads(responses[2]["content"][0]["text"])["actor"] == "test-member"
    state = json.loads(responses[3]["content"][0]["text"])
    assert len(state["items"]) == len(state["entries"]) == 1 and not state["conflicts"]
print("CLI and MCP read the same idempotent write.")
