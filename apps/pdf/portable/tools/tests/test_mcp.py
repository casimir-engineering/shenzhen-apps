import importlib.util
import io
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

MODULE_PATH = Path(__file__).resolve().parents[1] / "shenzhen-pdf-mcp.py"
spec = importlib.util.spec_from_file_location("reader_mcp", MODULE_PATH)
mcp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mcp)


class MCPTests(unittest.TestCase):
    def test_handshake_and_discovery_do_not_spawn_reader(self):
        with patch.object(mcp.subprocess, "run") as run:
            initialized = mcp.dispatch({"jsonrpc": "2.0", "id": 1, "method": "initialize"}, "/reader")
            self.assertEqual(initialized["result"]["protocolVersion"], "2025-11-25")
            tools = mcp.dispatch({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, "/reader")
            self.assertEqual(len(tools["result"]["tools"]), 9)
            self.assertIsNone(mcp.dispatch({"jsonrpc": "2.0", "method": "notifications/initialized"}, "/reader"))
            run.assert_not_called()

    def test_native_hook_is_lazy_and_precedes_application_creation(self):
        root = MODULE_PATH.parents[2]
        coordinator = (root / "portable/mac/ShenzhenPDFMac.mm").read_text()
        main = coordinator[coordinator.index("int main("):]
        self.assertLess(main.index("SPDFMacRunAgentCommand"), main.index("ShenzhenMacDelegate* delegate"))
        self.assertEqual(coordinator.count("acceptAgentCommandAtPath:path"), 1)
        gate = coordinator.index("acceptAgentCommandAtPath:path")
        self.assertIn('isEqualToString:@"spdf-command"', coordinator[gate - 150:gate])
        native = (root / "portable/mac/SPDFMacAgentIntegration.mm").read_text()
        self.assertNotIn("+ (void)load", native)
        self.assertNotIn("__attribute__((constructor))", native)

    def test_arguments_are_passed_as_data_without_shell(self):
        arguments = {"path": "/tmp/$(touch surprise).md", "query": "`command`", "page": 2}
        completed = subprocess.CompletedProcess([], 0, b'{"opened":true}', b'')
        with patch.object(mcp.subprocess, "run", return_value=completed) as run:
            result = mcp.call_tool("/reader", {"name": "open_document", "arguments": arguments})
            self.assertFalse(result["isError"])
            args, kwargs = run.call_args
            self.assertEqual(json.loads(args[0][2]), {"action": "open", **arguments})
            self.assertNotIn("shell", kwargs)

    def test_invalid_input_cannot_start_reader(self):
        cases = [{"path": "relative.md"}, {"path": "/a.md", "page": True},
                 {"path": "/a.md", "page": 0}, {"path": "/a.md", "page": 1.1},
                 {"path": "/a.md", "unknown": "x"}, {"path": "/a.md", "query": "\0"}]
        with patch.object(mcp.subprocess, "run") as run:
            for arguments in cases:
                self.assertTrue(mcp.call_tool("/reader", {"name": "open_document", "arguments": arguments})["isError"])
            run.assert_not_called()

    def test_group_tools_use_native_actions_and_preserve_ids(self):
        calls = [("list_tab_groups", {}),
                 ("create_tab_group", {"paths": ["/a.pdf", "/b.md"], "name": "Research", "color": "Blue"}),
                 ("update_tab_group", {"groupID": "stable-id", "collapsed": False, "hidden": True, "name": ""}),
                 ("jump_to_tab_group", {"groupID": "stable-id"}),
                 ("move_tab_to_group", {"path": "/a.pdf", "groupID": "general", "beforePath": "/b.md"}),
                 ("move_tab_group", {"groupID": "stable-id", "beforeGroupID": "general"}),
                 ("ungroup_tabs", {"groupID": "stable-id", "windowSessionID": "window-id"})]
        completed = subprocess.CompletedProcess([], 0, b'{"groups":[],"tabs":[]}', b'')
        for name, arguments in calls:
            with self.subTest(name=name), patch.object(mcp.subprocess, "run", return_value=completed) as run:
                self.assertFalse(mcp.call_tool("/reader", {"name": name, "arguments": arguments})["isError"])
                self.assertEqual(json.loads(run.call_args.args[0][2]), {"action": mcp.GROUP_ACTIONS[name], **arguments})

    def test_invalid_group_arguments_do_not_spawn_reader(self):
        calls = [("list_tab_groups", {"path": "/a.pdf"}), ("create_tab_group", {"paths": []}),
                 ("create_tab_group", {"paths": ["relative.md"]}),
                 ("create_tab_group", {"paths": ["/a.pdf", "/a.pdf"]}),
                 ("create_tab_group", {"paths": ["/a.pdf", {}]}),
                 ("update_tab_group", {"groupID": "id"}),
                 ("update_tab_group", {"groupID": "id", "collapsed": 1}),
                 ("update_tab_group", {"groupID": "id", "hidden": 1}),
                 ("move_tab_to_group", {"path": "/a.pdf"}), ("ungroup_tabs", {"groupID": ""})]
        with patch.object(mcp.subprocess, "run") as run:
            for name, arguments in calls:
                self.assertTrue(mcp.call_tool("/reader", {"name": name, "arguments": arguments})["isError"])
            run.assert_not_called()

    def test_errors_and_timeouts_are_tool_errors(self):
        for process in (subprocess.CompletedProcess([], 1, b'{"error":"bad page"}', b''),
                        subprocess.CompletedProcess([], 0, b'not json', b'')):
            with patch.object(mcp.subprocess, "run", return_value=process):
                self.assertTrue(mcp.call_tool("/reader", {"name": "open_document", "arguments": {"path": "/a.md"}})["isError"])
        with patch.object(mcp.subprocess, "run", side_effect=subprocess.TimeoutExpired("reader", 40)):
            self.assertTrue(mcp.call_tool("/reader", {"name": "inspect_document", "arguments": {"path": "/a.md"}})["isError"])

    def test_stream_recovers_after_bad_or_oversized_message(self):
        ping = json.dumps({"jsonrpc": "2.0", "id": 5, "method": "ping"}).encode() + b'\n'
        source = io.BytesIO(b'bad\n' + b'x' * 100000 + b'\n' + ping)
        output = io.StringIO()
        mcp.serve("/reader", source, output)
        responses = [json.loads(line) for line in output.getvalue().splitlines()]
        self.assertEqual([r.get("error", {}).get("code") for r in responses], [-32700, -32600, None])
        self.assertEqual(responses[-1]["id"], 5)


if __name__ == "__main__":
    unittest.main()
