#!/usr/bin/env python3
"""Verify MCP JSON-RPC over stdio against a selected real AgentLab session."""
import argparse
import json
import select
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("session_id")
parser.add_argument("--mcp", default="Tools/MCP/.build/debug/agentdevkit-mcp")
parser.add_argument("--cli", default=".build/debug/agentdevctl")
args = parser.parse_args()

with subprocess.Popen(
    [args.mcp], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE
) as server:
    def send(method, params=None, request_id=None):
        request = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            request["params"] = params
        if request_id is not None:
            request["id"] = request_id
        server.stdin.write(json.dumps(request).encode() + b"\n")
        server.stdin.flush()
        if request_id is None:
            return None
        readable, _, _ = select.select([server.stdout], [], [], 6)
        assert readable, f"No stdio response for {method}"
        reply = json.loads(server.stdout.readline())
        assert reply["id"] == request_id and "error" not in reply, reply
        return reply["result"]

    try:
        hello = send("initialize", {
            "protocolVersion": "2025-11-25",
            "clientInfo": {"name": "agentdevkit-smoke", "version": "1"},
            "capabilities": {},
        }, 1)
        assert hello["serverInfo"]["name"] == "agentdevkit"
        send("notifications/initialized")
        catalog = {tool["name"]: tool for tool in send("tools/list", request_id=2)["tools"]}
        assert len(catalog) == 11
        assert catalog["agentdevkit_prepare"]["annotations"]["destructiveHint"] is True
        assert catalog["agentdevkit_state"]["annotations"]["readOnlyHint"] is True

        def tool(name, request_id, **params):
            reply = send("tools/call", {
                "name": "agentdevkit_" + name,
                "arguments": {"sessionId": args.session_id, **params},
            }, request_id)
            assert json.loads(reply["content"][0]["text"]) == reply["structuredContent"]
            return reply

        prepared = tool("prepare", 3, fixture="large-project-v1", route="projects.editor.inspector",
                        context={"nodeId": "node-42"})
        assert prepared["isError"] is False
        screen = prepared["structuredContent"]["result"]["screen"]
        assert screen["ready"] is True and screen["fields"]["nodeId"] == "node-42"
        mcp_state = tool("state", 4, scope="current-screen")["structuredContent"]["result"]
        cli_state = json.loads(subprocess.check_output([
            args.cli, "--session", args.session_id, "state", "--json",
        ]))["result"]
        assert screen == mcp_state == cli_state

        rejected = tool("state", 5, scope="not-registered")
        assert rejected["isError"] is True
        assert rejected["structuredContent"]["error"]["code"] == "INVALID_PARAMS"

        observation = tool("observe", 6, scope="current-screen", sinceRevision=screen["revision"])["structuredContent"]["result"]
        assert observation["screen"] == screen and observation["delta"]["events"] == []

        def successful(name, request_id, **params):
            reply = tool(name, request_id, **params)
            assert reply["isError"] is False, reply
            return reply["structuredContent"]["result"]

        assert successful("session", 7)["sessionId"] == args.session_id.upper()
        capabilities = successful("capabilities", 8)
        assert "large-project-v1" in capabilities["fixtures"]
        assert "inspector.save" in capabilities["actions"]
        assert successful("wait", 9, condition="screen.ready", scope="current-screen")["satisfied"]
        assert any(action["id"] == "inspector.save" and action["enabled"] for action in successful("actions", 10))
        assert isinstance(successful("diagnostics", 11, limit=1), list)
        saved = successful("invoke", 12, actionId="inspector.save",
                           arguments={"name": "Verified through MCP"}, expectedRevision=screen["revision"])
        assert saved["fields"]["nodeName"] == "Verified through MCP"
        delta = successful("events", 13, revision=screen["revision"])
        assert [event["type"] for event in delta["events"]] == ["work.started", "work.finished", "node.saved"]
        assert delta["events"][1]["lifecycle"]["outcome"] == "completed"
        assert "Verified through MCP" not in json.dumps(delta)
        assert successful("navigate", 14, route="home")["screenId"] == "home"

        server.stdin.close()
        assert server.wait(timeout=4) == 0
        assert not server.stdout.read(), "Unexpected output after the MCP exchange"
        assert not server.stderr.read()
    finally:
        if server.poll() is None:
            server.kill()

print("Live MCP passed: handshake, every registered tool, real Inspector, CLI parity, semantic save, error and clean stdio exit.")
