#!/usr/bin/env python3
"""Verify MCP JSON-RPC over stdio against a selected real AgentLab session."""
import argparse
import json
import os
import select
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("session_id")
parser.add_argument("--mcp", default="Tools/MCP/.build/release/agentdevkit-mcp")
parser.add_argument("--cli", default=".build/debug/agentdevctl")
args = parser.parse_args()
flags = []
for variable, option in [("AGENTDEVKIT_APP_GROUP", "--app-group"), ("AGENTDEVKIT_PAIRING_DIR", "--pairing-dir")]:
    if variable in os.environ:
        flags.extend([option, os.environ[variable]])

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
        version = subprocess.check_output([args.cli, "--version"], text=True).strip()
        assert hello["serverInfo"]["version"] == version
        send("notifications/initialized")
        catalog = {tool["name"]: tool for tool in send("tools/list", request_id=2)["tools"]}
        # session, capabilities and one tool per shared operation.
        assert len(catalog) == 28, sorted(catalog)
        for name in ["ui_perform", "ui_key", "ui_hover", "ui_scroll", "operator_ask"]:
            assert catalog["agentdevkit_" + name]["annotations"]["destructiveHint"] is True, name
        for name in ["operation_status", "ui_surfaces", "ui_snapshot", "invariants", "privacy_status"]:
            assert catalog["agentdevkit_" + name]["annotations"]["readOnlyHint"] is True, name
        assert catalog["agentdevkit_state"]["inputSchema"]["properties"]["fields"]["type"] == "array"
        assert "until" in catalog["agentdevkit_wait"]["inputSchema"]["properties"]
        assert catalog["agentdevkit_press"]["annotations"]["destructiveHint"] is True
        assert catalog["agentdevkit_capture"]["annotations"]["readOnlyHint"] is True
        assert catalog["agentdevkit_prepare"]["annotations"]["destructiveHint"] is True
        assert catalog["agentdevkit_fixtures"]["annotations"]["destructiveHint"] is True
        assert catalog["agentdevkit_state"]["annotations"]["readOnlyHint"] is True
        assert "not a physical click" in catalog["agentdevkit_invoke"]["description"]
        assert all("timeoutMs" in tool["inputSchema"]["properties"] for tool in catalog.values())

        def tool(name, request_id, **params):
            reply = send("tools/call", {
                "name": "agentdevkit_" + name,
                "arguments": {"sessionId": args.session_id, **params},
            }, request_id)
            text = [item for item in reply["content"] if item["type"] == "text"]
            assert len(text) == 1 and json.loads(text[0]["text"]) == reply["structuredContent"]
            return reply

        prepared = tool("prepare", 3, fixture="large-project-v1", route="projects.editor.inspector",
                        context={"nodeId": "node-42"})
        assert prepared["isError"] is False
        screen = prepared["structuredContent"]["result"]["screen"]
        assert screen["ready"] is True and screen["fields"]["nodeId"] == "node-42"
        mcp_state = tool("state", 4)["structuredContent"]["result"]
        cli_state = json.loads(subprocess.check_output([
            args.cli, *flags, "--session", args.session_id, "state", "--json",
        ]))["result"]
        assert screen == mcp_state == cli_state

        rejected = tool("state", 5, scope="not-registered")
        assert rejected["isError"] is True
        assert rejected["structuredContent"]["error"]["code"] == "INVALID_PARAMS"
        assert "current-screen" in rejected["structuredContent"]["error"]["details"]["validNames"]
        projected = tool("state", 50, fields=["nodeId", "missing.field"])["structuredContent"]
        assert projected["result"] == {"nodeId": "node-42"} and projected["missingFields"] == ["missing.field"]
        assert tool("wait", 51, until="nodeId=node-42")["structuredContent"]["result"]["condition"] == "state.field_equals"

        observation = tool("observe", 6, scope="current-screen", sinceRevision=screen["revision"])["structuredContent"]["result"]
        assert observation["screen"] == screen and observation["delta"]["events"] == []

        def mcp_state_bundle():
            return successful("session", 69)["bundleId"]

        def successful(name, request_id, **params):
            reply = tool(name, request_id, **params)
            assert reply["isError"] is False, reply
            return reply["structuredContent"]["result"]

        assert successful("session", 7)["sessionId"] == args.session_id.upper()
        bundle_selected = send("tools/call", {"name": "agentdevkit_state", "arguments": {"sessionId": mcp_state_bundle()}}, 70)
        assert bundle_selected["structuredContent"]["result"] == screen
        capabilities = successful("capabilities", 8)
        assert "large-project-v1" in capabilities["fixtures"]
        assert "inspector.save" in capabilities["actions"]
        assert successful("wait", 9, condition="screen.ready", timeoutMs=1500)["satisfied"]
        loaded = successful("fixtures", 90, fixture="large-project-v1")
        assert loaded["fields"]["projectId"] == "fixture:large-project"
        prepared = tool("prepare", 91, fixture="large-project-v1", route="projects.editor.inspector",
                        context={"nodeId": "node-42"})
        screen = prepared["structuredContent"]["result"]["screen"]
        assert any(action["id"] == "inspector.save" and action["enabled"] for action in successful("actions", 10))
        assert isinstance(successful("diagnostics", 11, limit=1), list)
        saved = successful("invoke", 12, actionId="inspector.save",
                           arguments={"name": "Verified through MCP"}, expectedRevision=screen["revision"])
        assert saved["outcome"] == "completed"
        assert saved["screen"]["fields"]["nodeName"] == "Verified through MCP"
        delta = successful("events", 13, revision=screen["revision"])
        assert [event["type"] for event in delta["events"]] == ["work.started", "work.finished", "node.saved"]
        assert delta["events"][1]["lifecycle"]["outcome"] == "completed"
        assert "Verified through MCP" not in json.dumps(delta)
        assert successful("navigate", 14, route="home")["screenId"] == "home"

        # In-process UI tools: the agent sees the window and its accessibility tree, and presses a control.
        captured = tool("capture", 15, maxDimension=800)
        assert captured["isError"] is False
        image = captured["content"][0]
        assert image["type"] == "image" and image["mimeType"] in ("image/png", "image/jpeg") and len(image["data"]) > 1000
        meta = captured["structuredContent"]["result"]
        assert "data" not in meta and max(meta["width"], meta["height"]) <= 800
        tree = successful("ui_tree", 16, onlyIdentified=True)
        identifiers = {element.get("identifier") for element in tree["elements"]}
        assert {"nav.projects.list", "screen.home"} <= identifiers, identifiers
        operations = successful("operations", 19)
        assert all({"id", "kind", "name", "ageMs"} <= set(item) for item in operations)
        pressed = successful("press", 17, identifier="nav.projects.list")
        assert pressed["role"] == "AXButton"
        assert successful("wait", 18, condition="screen.ready", timeoutMs=2000)["screen"]["screenId"] == "projects.list"

        server.stdin.close()
        assert server.wait(timeout=4) == 0
        assert not server.stdout.read(), "Unexpected output after the MCP exchange"
        assert not server.stderr.read()
    finally:
        if server.poll() is None:
            server.kill()

print("Live MCP passed: handshake, every registered tool, bundle-ID selection, fixtures, real Inspector, CLI parity, semantic save, window capture as image content, accessibility tree, press, error and clean stdio exit.")
