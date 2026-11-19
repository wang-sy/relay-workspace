#!/usr/bin/env python3
"""Exercise clean MCP sessions, source permissions and the shipped CLI against an isolated Relay."""
import base64
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import uuid

root = Path(__file__).resolve().parents[1]
binary = str(Path(sys.argv[1]).resolve())
new_id = lambda: str(uuid.uuid4())


def exercise(folder, address, agent, viewer):
    relay = [binary, "--server", address]
    env = dict(os.environ, RELAY_TOKEN=agent, RELAY_ACTOR="unverified", RELAY_AGENT="Smoke",
               RELAY_ATTACHMENT_ROOT=str(folder / "allowed"))
    examples = [json.loads(line) for line in (root / "Examples/context.jsonl").read_text().splitlines() if line]
    def cli(args, obj=None, token=agent):
        run = subprocess.run(relay + args, input=json.dumps(obj) if obj else None, text=True,
                             capture_output=True, check=True, env=dict(env, RELAY_TOKEN=token), timeout=30)
        return json.loads(run.stdout)
    def mcp(tool, args, extra=None, fails=False):
        frames = [
            {"id": 1, "method": "initialize", "params": {"protocolVersion": "2025-11-25"}},
            {"method": "notifications/initialized"},
            {"id": 2, "method": "tools/call", "params": {"name": tool, "arguments": args}},
        ]
        stream = "".join(json.dumps(dict(jsonrpc="2.0", **f)) + "\n" for f in frames)
        run = subprocess.run(relay + ["mcp"], env={**env, **(extra or {})}, input=stream, text=True,
                             capture_output=True, check=True, timeout=30)
        answer = json.loads(run.stdout.splitlines()[-1])["result"]
        assert bool(answer.get("isError")) == fails, str(answer)[:300]
        block = answer["content"][0]
        return block if fails or block["type"] != "text" else json.loads(block["text"])
    cli(["apply"], {"requestID":new_id(), "change":{"operation":"create","itemID":"IDEA-01","kind":"idea","title":"展馆巡检记录"}})
    cli(["apply"], {"requestID":new_id(), "change":{"operation":"create","itemID":"other","kind":"idea","title":"统一图标字号"}})
    for ex in examples: cli(["context","attach"], ex)
    found = mcp("relay_recall", {"action":"search","query":"之前地库没有网络时的巡检异常"})
    assert found[0]["itemID"] == "IDEA-01"
    report = mcp("relay_recall", {"action":"recall","itemID":found[0]["itemID"]})
    assert [h["referenceID"] for h in report["highlights"]] == [e["requestID"] for e in examples]
    for h in report["highlights"]:
        ref = mcp("relay_recall", {"action":"get","referenceID":h["referenceID"]})
        assert ref["material"]["body"] and ref["note"] == h["text"] and ref["actor"] == "member"
    png = root / "App/Assets.xcassets/AppIcon.appiconset/mac-32.png"
    img = {"itemID":"IDEA-01","requestID":new_id(),"purpose":"图片样本"}
    saved = cli(["context","attach","--file",str(png)],img)
    result = mcp("relay_recall",{"action":"file","referenceID":saved["id"]}, {"RELAY_TOKEN":viewer})
    assert result["type"] == "image" and base64.b64decode(result["data"]) == png.read_bytes()
    output = folder / "received.png"
    cli(["context","download",saved["id"],str(output)],token=viewer)
    assert output.read_bytes() == png.read_bytes()
    allowed = folder / "allowed"
    allowed.mkdir()
    (allowed / "交接.txt").write_text("原始文件里的交接记录")
    file_args = {"itemID":"IDEA-01","requestID":new_id(),"filePath":"交接.txt"}
    file = mcp("relay_attach", file_args)
    assert mcp("relay_attach",file_args) == file
    chunk = mcp("relay_recall",{"action":"file","referenceID":file["id"],"offset":0,"limit":6})
    assert chunk["nextOffset"] == 6
    mcp("relay_attach", {**file_args,"requestID":new_id(),"filePath":"../received.png"}, fails=True)
    (allowed / "outside").symlink_to(output)
    mcp("relay_attach", {**file_args,"requestID":new_id(),"filePath":"outside"}, fails=True)
    mcp("relay_attach", {**img,"materialID":file["materialID"]}, {"RELAY_TOKEN":viewer}, fails=True)
    link = mcp("relay_attach",{"requestID":new_id(),"itemID":"IDEA-01","locator":"第 3 段",
        "material":{"kind":"link","title":"受限访谈","url":"https://example.feishu.cn/docx/Example#block3","sourceVersion":"7"}})
    stub = folder / "lark-cli"
    stub.write_text("""#!/usr/bin/env python3
import sys,os,json
args=sys.argv[1:]
if '--jq' in args:
    assert args[args.index('--as')+1]=='user'
    if os.environ.get('TEST_LARK_VISIBLE')!='1': sys.exit(1)
    print(7); sys.exit(0)
for key,expected in [('--as','user'),('--revision-id','7'),('--start-block-id','block3'),('--end-block-id','block3')]:
    assert args[args.index(key)+1]==expected
if os.environ.get('TEST_LARK_VISIBLE')!='1': sys.exit(1)
print(json.dumps({'ok':True,'excerpt':'restricted-only-during-read'}))
""")
    stub.chmod(0o700)
    local = {"PATH":str(folder) + os.pathsep + env["PATH"]}
    pin = {"itemID":"IDEA-01","requestID":new_id(),"pinSource":True,
           "material":{"kind":"link","title":"另一个受限文档","url":"https://example.feishu.cn/wiki/Other"}}
    pinned = mcp("relay_attach",pin,{**local,"TEST_LARK_VISIBLE":"1"})
    assert mcp("relay_attach",pin,{**local,"TEST_LARK_VISIBLE":"0"}) == pinned
    assert cli(["context","get",pinned["id"]])["material"]["sourceVersion"]=="7"
    empty = allowed / "empty.txt"
    empty.touch()
    empty_ref=cli(["context","attach","--file",str(empty)],{"itemID":"IDEA-01","requestID":new_id()})
    assert mcp("relay_recall",{"action":"file","referenceID":empty_ref["id"]})["size"] == 0
    source = {"action":"source","referenceID":link["id"]}
    assert mcp("relay_recall",source,{**local,"TEST_LARK_VISIBLE":"1"})["excerpt"]=="restricted-only-during-read"
    mcp("relay_recall",source,{**local,"TEST_LARK_VISIBLE":"0"},fails=True)
    assert cli(["context","search","restricted-only-during-read"],token=viewer) == []
    assert "restricted-only-during-read" not in json.dumps(cli(["context","get",link["id"]],token=viewer))
    print("Fresh MCP readers recovered all three citations. Image/file bytes, client-side Lark access and viewer limits passed.")


with tempfile.TemporaryDirectory() as tmp:
    folder = Path(tmp)
    agent, viewer = new_id(), new_id()
    server_env = dict(os.environ, RELAY_HOST="127.0.0.1", RELAY_PORT="0", RELAY_DB=str(folder/"test.sqlite"),
                      RELAY_MEMBERS_JSON=json.dumps({"member":{"agent":agent,"viewer":viewer}}))
    with subprocess.Popen(["node",str(root/"server/dist/index.js")],env=server_env,stdout=subprocess.PIPE,text=True) as service:
        try:
            with selectors.DefaultSelector() as ready:
                ready.register(service.stdout,selectors.EVENT_READ)
                assert ready.select(15)
                line=service.stdout.readline().strip()
            assert line.startswith("Relay listening on http://127.0.0.1:")
            exercise(folder,line.split()[-1],agent,viewer)
        finally:
            service.terminate()
            service.wait(timeout=10)
