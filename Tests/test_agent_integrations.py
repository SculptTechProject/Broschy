#!/usr/bin/env python3
"""Isolated installer and OpenCode adapter checks; no real agent settings or events."""
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "agent-integrations.py"
TEMPLATE = ROOT / "Integrations" / "opencode" / "broschy.js"
SPEC = importlib.util.spec_from_file_location("broschy_integrations", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="broschy-integrations-")
        # macOS /var and /tmp are platform aliases; use the physical test root.
        self.base = Path(self.temporary.name).resolve()
        self.home = self.base / "home"
        self.home.mkdir()
        self.cli = self.base / "Broschy's app $(echo inert)" / "broschy-cli"
        self.cli.parent.mkdir()
        self.cli.write_text("#!/bin/sh\nexit 0\n")
        self.cli.chmod(0o751)
        self.support = self.home / "Library/Application Support/NotchFlow/agents/integrations"

    def tearDown(self):
        self.temporary.cleanup()

    def target(self, provider):
        return MODULE.configuration_path(provider, self.home, {})

    def run_installer(self, action, provider="codex", extra=(), env=None, success=True):
        args = [sys.executable, str(SCRIPT), action, "--provider", provider, "--home", str(self.home)]
        if action == "install":
            args += ["--cli-path", str(self.cli)]
        process = subprocess.run(args + list(extra), env=env, text=True, capture_output=True, timeout=10)
        self.assertEqual(process.returncode, 0 if success else 1, process.stdout + process.stderr)
        self.assertEqual(process.stderr, "")
        result = json.loads(process.stdout)
        self.assertEqual(set(result), {"provider", "installed", "message"})
        self.assertEqual(result["provider"], provider)
        return result

    def put_config(self, provider, config, mode=0o640):
        path = self.target(provider)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(config, ensure_ascii=False, indent=4) + "\n")
        path.chmod(mode)
        return path

    def test_status_is_read_only_when_absent(self):
        for provider in MODULE.PROVIDERS:
            self.assertFalse(self.run_installer("status", provider)["installed"])
        self.assertEqual(list(self.home.iterdir()), [])

    def test_hooks_merge_idempotent_backup_permissions_and_uninstall(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                original = {
                    "permissions": {"allow": ["Read"], "deny": ["Bash(rm *)"]},
                    "custom": {"unicode": "Café", "enabled": False},
                    "hooks": {
                        "SessionStart": [{"matcher": "startup", "hooks": [{"type": "command", "command": "user-start", "timeout": 7}]}],
                        "Stop": [],
                        "CustomEvent": [{"hooks": [{"type": "command", "command": "user-custom"}]}],
                    },
                }
                path = self.put_config(provider, original)
                path.parent.chmod(0o750)
                before = path.read_bytes()
                self.assertTrue(self.run_installer("install", provider)["installed"])
                updated = json.loads(path.read_text())
                self.assertEqual(updated["permissions"], original["permissions"])
                self.assertEqual(updated["custom"], original["custom"])
                self.assertEqual(updated["hooks"]["CustomEvent"], original["hooks"]["CustomEvent"])
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o640)
                self.assertEqual(stat.S_IMODE(path.parent.stat().st_mode), 0o750)
                for event in MODULE.EVENTS[provider]:
                    own = updated["hooks"][event][-1]["hooks"][0]
                    self.assertEqual(shlex.split(own["command"]), [str(self.cli), "agent", "hook", "--provider", provider])
                    self.assertEqual(own["timeout"], 2)
                    self.assertNotIn("async", own)
                backup_files = list((self.support / "backups" / provider).iterdir())
                self.assertEqual(len(backup_files), 1)
                self.assertEqual(backup_files[0].read_bytes(), before)
                self.assertEqual(stat.S_IMODE(backup_files[0].stat().st_mode), 0o600)
                stable = path.read_bytes()
                inode = path.stat().st_ino
                self.run_installer("install", provider)
                self.assertEqual(path.read_bytes(), stable)
                self.assertEqual(path.stat().st_ino, inode)
                self.assertEqual(len(list((self.support / "backups" / provider).iterdir())), 1)
                self.assertTrue(self.run_installer("status", provider)["installed"])
                self.assertFalse(self.run_installer("uninstall", provider)["installed"])
                self.assertEqual(json.loads(path.read_text()), original)
                self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o640)
                self.assertFalse((self.support / (provider + ".json")).exists())
                self.assertFalse(self.run_installer("uninstall", provider)["installed"])

    def test_status_requires_an_available_executable_and_detects_app_moves(self):
        for provider in MODULE.PROVIDERS:
            with self.subTest(provider=provider):
                self.cli.chmod(0o751)
                self.run_installer("install", provider)
                path = self.target(provider)
                before = path.read_bytes()
                manifest_before = (self.support / (provider + ".json")).read_bytes()
                self.cli.chmod(0o600)
                unavailable = self.run_installer("status", provider)
                self.assertFalse(unavailable["installed"])
                self.assertIn("Reconnect", unavailable["message"])
                self.cli.chmod(0o751)
                moved = self.base / (provider + "-moved-cli")
                shutil.copy2(self.cli, moved)
                moved_status = self.run_installer("status", provider, extra=("--cli-path", str(moved)))
                self.assertFalse(moved_status["installed"])
                self.assertIn("Reconnect", moved_status["message"])
                hidden = self.cli.with_name("temporarily-absent-cli")
                self.cli.rename(hidden)
                self.assertFalse(self.run_installer("status", provider)["installed"])
                hidden.rename(self.cli)
                self.assertEqual(path.read_bytes(), before)
                self.assertEqual((self.support / (provider + ".json")).read_bytes(), manifest_before)
                self.assertTrue(self.run_installer("status", provider, extra=("--cli-path", str(self.cli)))["installed"])
                self.run_installer("install", provider, extra=("--cli-path", str(moved)))
                self.assertTrue(self.run_installer("status", provider, extra=("--cli-path", str(moved)))["installed"])

    def test_codex_result_requires_hook_review_and_does_not_edit_trust(self):
        config = self.home / ".codex/config.toml"
        config.parent.mkdir()
        original = b'[hooks_trust]\ntrusted_hashes = ["unchanged"]\n'
        config.write_bytes(original)
        result = self.run_installer("install")
        self.assertIn("/hooks", result["message"])
        self.assertEqual(config.read_bytes(), original)

    def test_fresh_configs_removed_on_uninstall(self):
        for provider in MODULE.PROVIDERS:
            self.run_installer("install", provider)
            self.run_installer("uninstall", provider)
            self.assertFalse(self.target(provider).exists())

    def test_uninstall_preserves_new_settings_and_handlers_in_our_group(self):
        self.run_installer("install", "claude")
        path = self.target("claude")
        value = json.loads(path.read_text())
        value["model"] = "user-model"
        added = {"type": "command", "command": "my-new-hook"}
        value["hooks"]["Stop"][0]["hooks"].append(added)
        value["hooks"]["SessionEnd"].append({"matcher": "other", "hooks": [added]})
        path.write_text(json.dumps(value))
        self.run_installer("uninstall", "claude")
        self.assertEqual(json.loads(path.read_text()), {
            "model": "user-model", "hooks": {"Stop": [{"hooks": [added]}], "SessionEnd": [{"matcher": "other", "hooks": [added]}]},
        })

    def test_reinstall_can_update_executable_without_duplicate_hooks(self):
        self.run_installer("install")
        moved = self.base / "Moved Broschy" / "broschy-cli"
        moved.parent.mkdir()
        shutil.copy2(self.cli, moved)
        self.run_installer("install", extra=("--cli-path", str(moved)))
        value = json.loads(self.target("codex").read_text())
        for groups in value["hooks"].values():
            self.assertEqual(len(groups), 1)
            self.assertEqual(shlex.split(groups[0]["hooks"][0]["command"])[0], str(moved))
        self.run_installer("uninstall")
        self.assertFalse(self.target("codex").exists())

    def test_missing_owned_hook_can_be_repaired(self):
        self.run_installer("install")
        path = self.target("codex")
        value = json.loads(path.read_text())
        del value["hooks"]["Stop"]
        path.write_text(json.dumps(value))
        self.assertFalse(self.run_installer("status")["installed"])
        self.assertTrue(self.run_installer("install")["installed"])
        self.assertTrue(self.run_installer("status")["installed"])

    def test_modified_owned_hooks_are_preserved(self):
        self.run_installer("install")
        path = self.target("codex")
        value = json.loads(path.read_text())
        value["hooks"]["Stop"][0]["hooks"][0]["timeout"] = 15
        before = json.dumps(value).encode()
        path.write_bytes(before)
        result = self.run_installer("uninstall", success=False)
        self.assertIn("edited", result["message"])
        self.assertEqual(path.read_bytes(), before)
        self.assertTrue((self.support / "codex.json").exists())

    def test_matching_unowned_hook_is_not_adopted(self):
        handler = MODULE.handler_for(self.cli, "codex")
        path = self.put_config("codex", {"hooks": {"Stop": [{"hooks": [handler]}]}})
        before = path.read_bytes()
        self.run_installer("install", success=False)
        self.assertEqual(path.read_bytes(), before)
        self.assertFalse((self.support / "codex.json").exists())

    def test_duplicate_owned_hook_is_not_ambiguously_removed(self):
        self.run_installer("install")
        path = self.target("codex")
        value = json.loads(path.read_text())
        value["hooks"]["Stop"].append(value["hooks"]["Stop"][0])
        before = json.dumps(value).encode()
        path.write_bytes(before)
        self.run_installer("uninstall", success=False)
        self.assertEqual(path.read_bytes(), before)

    def test_home_ignores_real_agent_environment_overrides(self):
        outside = self.base / "outside"
        outside.mkdir()
        sentinel = outside / "settings.json"
        sentinel.write_text('{"never":"change"}')
        env = dict(os.environ, CODEX_HOME=str(outside), CLAUDE_CONFIG_DIR=str(outside), XDG_CONFIG_HOME=str(outside))
        for provider in MODULE.PROVIDERS:
            self.run_installer("install", provider, env=env)
            self.assertTrue(self.target(provider).exists())
        self.assertEqual(sorted(path.name for path in outside.iterdir()), ["settings.json"])
        self.assertEqual(sentinel.read_text(), '{"never":"change"}')

    def test_configuration_paths_honor_environment_when_not_isolated(self):
        overrides = {"CODEX_HOME": str(self.base / "codex-env"), "CLAUDE_CONFIG_DIR": str(self.base / "claude-env"), "XDG_CONFIG_HOME": str(self.base / "xdg-env")}
        self.assertEqual(MODULE.configuration_path("codex", self.home, overrides), self.base / "codex-env/hooks.json")
        self.assertEqual(MODULE.configuration_path("claude", self.home, overrides), self.base / "claude-env/settings.json")
        self.assertEqual(MODULE.configuration_path("opencode", self.home, overrides), self.base / "xdg-env/opencode/plugins/broschy.js")
        with self.assertRaises(MODULE.IntegrationError):
            MODULE.configuration_path("codex", self.home, {"CODEX_HOME": "relative"})

    def test_malformed_or_oversize_configs_are_never_replaced(self):
        inputs = [b"not json", b"[]", b'{"hooks": []}', b'{"hooks":{"Stop":{}}}', b'{"hooks":{"Stop":[{}]}}',
                  b'{"a":1,"a":2}', b'{"value":NaN}', b" " * (MODULE.MAX_CONFIG_BYTES + 1)]
        path = self.target("codex")
        path.parent.mkdir()
        for original in inputs:
            with self.subTest(original=original[:40]):
                path.write_bytes(original)
                self.run_installer("install", success=False)
                self.assertEqual(path.read_bytes(), original)
                self.assertFalse((self.support / "codex.json").exists())

    def test_symlink_configuration_file_refused(self):
        outside = self.base / "outside.json"
        outside.write_text('{"untouched":true}')
        path = self.target("codex")
        path.parent.mkdir()
        path.symlink_to(outside)
        self.run_installer("install", success=False)
        self.assertTrue(path.is_symlink())
        self.assertEqual(outside.read_text(), '{"untouched":true}')

    def test_symlink_ancestor_refused(self):
        outside = self.base / "outside"
        outside.mkdir()
        (self.home / ".codex").symlink_to(outside, target_is_directory=True)
        self.run_installer("install", success=False)
        self.assertEqual(list(outside.iterdir()), [])

    def test_symlink_ownership_path_refused(self):
        outside = self.base / "outside"
        outside.mkdir()
        (self.home / "Library").symlink_to(outside, target_is_directory=True)
        self.run_installer("install", success=False)
        self.assertFalse(self.target("codex").exists())
        self.assertEqual(list(outside.iterdir()), [])

    def test_directory_config_and_relative_cli_refused(self):
        self.target("codex").mkdir(parents=True)
        self.run_installer("install", success=False)
        self.assertTrue(self.target("codex").is_dir())
        self.run_installer("install", "claude", extra=("--cli-path", "relative/broschy-cli"), success=False)
        self.assertFalse(self.target("claude").exists())

    def test_uninstall_does_not_recreate_a_config_deleted_by_the_user(self):
        self.put_config("codex", {"custom": "preserve if present"})
        self.run_installer("install")
        self.target("codex").unlink()
        self.run_installer("uninstall")
        self.assertFalse(self.target("codex").exists())

    def test_opencode_install_update_backup_and_uninstall(self):
        result = self.run_installer("install", "opencode")
        self.assertTrue(result["installed"])
        path = self.target("opencode")
        original = path.read_bytes()
        self.assertIn(("const CLI_PATH = " + json.dumps(str(self.cli)) + ";").encode(), original)
        self.assertNotIn(b"__BROSCHY_CLI_PATH__", original)
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        self.run_installer("install", "opencode")
        self.assertEqual(path.read_bytes(), original)
        self.assertFalse((self.support / "backups/opencode").exists())
        moved = self.base / "new-cli"
        shutil.copy2(self.cli, moved)
        self.run_installer("install", "opencode", extra=("--cli-path", str(moved)))
        files = list((self.support / "backups/opencode").iterdir())
        self.assertEqual(files[0].read_bytes(), original)
        self.assertTrue(self.run_installer("status", "opencode")["installed"])
        self.run_installer("uninstall", "opencode")
        self.assertFalse(path.exists())

    def test_opencode_unowned_or_edited_plugin_preserved(self):
        path = self.target("opencode")
        path.parent.mkdir(parents=True)
        path.write_text("// user plugin\n")
        self.run_installer("install", "opencode", success=False)
        self.assertEqual(path.read_text(), "// user plugin\n")
        path.unlink()
        self.run_installer("install", "opencode")
        with path.open("a") as stream:
            stream.write("\n// user edit\n")
        before = path.read_bytes()
        self.assertFalse(self.run_installer("status", "opencode")["installed"])
        self.run_installer("uninstall", "opencode", success=False)
        self.assertEqual(path.read_bytes(), before)

    def test_bundled_template_override_and_invalid_template(self):
        template = self.base / "template.js"
        shutil.copyfile(TEMPLATE, template)
        self.run_installer("install", "opencode", extra=("--template-path", str(template)))
        self.run_installer("uninstall", "opencode")
        template.write_text("// no placeholder")
        self.run_installer("install", "opencode", extra=("--template-path", str(template)), success=False)
        self.assertFalse(self.target("opencode").exists())


@unittest.skipUnless(shutil.which("node"), "Node.js is optional; required only for OpenCode adapter verification")
class OpenCodeAdapterTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="broschy-opencode-")
        self.base = Path(self.temporary.name).resolve()
        self.capture = self.base / "events.jsonl"
        self.cli = self.base / "broschy's cli $(inert)"
        self.cli.write_text("#!" + sys.executable + "\n" + textwrap.dedent('''
            import json, os, sys, time
            value = json.load(sys.stdin)
            with open(os.environ["BROSCHY_TEST_CAPTURE"], "a") as stream:
                stream.write(json.dumps({"args":sys.argv[1:], "payload":value}) + "\\n")
            if value["session_id"] == "slow-session":
                time.sleep(8)
                with open(os.environ["BROSCHY_TEST_CAPTURE"] + ".late", "w") as stream:
                    stream.write("should have timed out")
        '''))
        self.cli.chmod(0o700)
        self.plugin = self.base / "broschy.mjs"
        self.plugin.write_bytes(MODULE.plugin_bytes(str(TEMPLATE), self.cli))

    def tearDown(self):
        self.temporary.cleanup()

    def run_node(self, events, expected, fallback="/fallback", timeout_ms=4000):
        runner = self.base / "runner.mjs"
        runner.write_text(textwrap.dedent('''
            import { readFileSync, existsSync } from "node:fs";
            import { BroschyPlugin } from "./broschy.mjs";
            const plugin = await BroschyPlugin({directory: FALLBACK});
            const events = EVENTS;
            const start = Date.now();
            for (const event of events) await plugin.event({event});
            const callbackMilliseconds = Date.now() - start;
            while (Date.now() - start < TIMEOUT) {
              const count = existsSync(process.env.BROSCHY_TEST_CAPTURE)
                ? readFileSync(process.env.BROSCHY_TEST_CAPTURE, "utf8").trim().split("\\n").length : 0;
              if (count >= EXPECTED) break;
              await new Promise(resolve => setTimeout(resolve, 25));
            }
            await new Promise(resolve => setTimeout(resolve, 100));
            process.stdout.write(JSON.stringify({callbackMilliseconds}));
        ''').replace("FALLBACK", json.dumps(fallback)).replace("EVENTS", json.dumps(events)).replace("TIMEOUT", str(timeout_ms)).replace("EXPECTED", str(expected)))
        process = subprocess.run([shutil.which("node"), str(runner)], capture_output=True, text=True,
                                 env=dict(os.environ, BROSCHY_TEST_CAPTURE=str(self.capture)), timeout=8)
        self.assertEqual(process.returncode, 0, process.stderr)
        self.assertEqual(process.stderr, "")
        result = json.loads(process.stdout)
        records = [json.loads(line) for line in self.capture.read_text().splitlines()] if self.capture.exists() else []
        self.assertEqual(len(records), expected)
        for record in records:
            self.assertEqual(record["args"], ["agent", "hook", "--provider", "opencode"])
        return result, [record["payload"] for record in records]

    def test_event_mapping_uses_only_safe_metadata_and_preserves_session_cwd(self):
        events = [
            {"type": "session.created", "properties": {"info": {"id": "s1", "directory": "/project-one", "parentID": "parent", "title": "SECRET title"}}},
            {"type": "session.updated", "properties": {"info": {"id": "s1", "directory": "/project-renamed", "title": "SECRET updated"}}},
            {"type": "session.created", "properties": {"info": {"id": "s2", "directory": "/project-two"}}},
            {"type": "session.status", "properties": {"sessionID": "s1", "status": {"type": "busy", "message": "SECRET status"}}},
            {"type": "permission.asked", "properties": {"sessionID": "s1", "id": "permission-1", "permission": "bash", "patterns": ["SECRET input"]}},
            {"type": "question.asked", "properties": {"sessionID": "s1", "id": "question-1", "questions": ["SECRET question"]}},
            {"type": "permission.replied", "properties": {"sessionID": "s1", "requestID": "permission-1", "reply": "SECRET approval"}},
            {"type": "question.replied", "properties": {"sessionID": "s1", "requestID": "question-1", "answers": ["SECRET answer"]}},
            {"type": "session.idle", "properties": {"sessionID": "s2"}},
            {"type": "session.error", "properties": {"sessionID": "s1", "error": {"data": "SECRET error"}}},
            {"type": "message.updated", "properties": {"info": {"sessionID": "s1", "role": "user", "id": "SECRET-message-id", "body": "SECRET prompt"}}},
            {"type": "message.updated", "properties": {"info": {"sessionID": "s1", "role": "assistant", "body": "SECRET output"}}},
            {"type": "session.error", "properties": {"error": {"message": "SECRET global"}}},
        ]
        result, payloads = self.run_node(events, 11)
        self.assertLess(result["callbackMilliseconds"], 500)
        allowed = {"hook_event_name", "session_id", "cwd", "request_id", "status", "tool_name", "parent_session_id", "role"}
        self.assertTrue(all(set(payload) <= allowed for payload in payloads))
        self.assertNotIn("SECRET", self.capture.read_text())
        self.assertEqual(payloads[3]["cwd"], "/project-renamed")
        self.assertEqual(payloads[3]["parent_session_id"], "parent")
        self.assertEqual(payloads[4]["request_id"], "permission-1")
        self.assertEqual(payloads[4]["tool_name"], "bash")
        self.assertEqual(payloads[5]["request_id"], "question-1")
        self.assertEqual(payloads[6]["request_id"], "permission-1")
        self.assertEqual(payloads[7]["request_id"], "question-1")
        self.assertEqual(payloads[8]["cwd"], "/project-two")
        self.assertEqual(payloads[10]["role"], "user")

    def test_fallback_directory_validation_and_unknown_events(self):
        events = [
            {"type": "session.status", "properties": {"sessionID": "new", "status": {"type": "retry"}}},
            {"type": "question.rejected", "properties": {"sessionID": "new", "requestID": "q2"}},
            {"type": "session.status", "properties": {"sessionID": "bad\nID", "status": {"type": "busy"}}},
            {"type": "session.status", "properties": {"sessionID": "new", "status": {"type": "secret"}}},
            {"type": "permission.asked", "properties": {"sessionID": "new", "id": "p2", "permission": "SECRET custom tool"}},
            {"type": "question.replied", "properties": {"sessionID": "new", "requestID": "bad ID"}},
            {"type": "arbitrary.event", "properties": {"sessionID": "new"}},
            {"type": "session.status", "properties": []},
            None,
        ]
        _, payloads = self.run_node(events, 3)
        self.assertTrue(all(value["cwd"] == "/fallback" for value in payloads))
        self.assertNotIn("tool_name", payloads[-1])
        self.assertNotIn("SECRET", self.capture.read_text())

    def test_slow_bridge_is_killed_and_next_event_is_delivered(self):
        events = [
            {"type": "session.idle", "properties": {"sessionID": "slow-session"}},
            {"type": "session.idle", "properties": {"sessionID": "next-session"}},
        ]
        result, payloads = self.run_node(events, 2, timeout_ms=4500)
        self.assertLess(result["callbackMilliseconds"], 500)
        self.assertEqual([value["session_id"] for value in payloads], ["slow-session", "next-session"])
        self.assertFalse(Path(str(self.capture) + ".late").exists())

    def test_missing_cli_is_fail_open(self):
        self.cli.unlink()
        result, payloads = self.run_node([{"type": "session.idle", "properties": {"sessionID": "s1"}}], 0)
        self.assertLess(result["callbackMilliseconds"], 500)
        self.assertEqual(payloads, [])


if __name__ == "__main__":
    if not shutil.which("node"):
        print("SKIP: Node.js is unavailable; OpenCode adapter subprocess tests were not run.", file=sys.stderr)
    unittest.main()
