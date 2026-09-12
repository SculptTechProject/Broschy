#!/usr/bin/env python3
"""Install Broschy's metadata-only agent hooks without replacing user settings.

Python 3.9+, standard library only. Every operation emits a single JSON result.
--home isolates both configuration and ownership state, ignoring config env vars.
"""
from __future__ import annotations

import argparse
import copy
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import stat
import sys
import tempfile
import time
import uuid
from contextlib import contextmanager
from dataclasses import dataclass

MAX_CONFIG_BYTES = 1024 * 1024
MAX_TEMPLATE_BYTES = 128 * 1024
PROVIDERS = ("codex", "claude", "opencode")
EVENTS = {
    "codex": (
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
        "PostToolUse", "Stop", "Interrupt", "SessionEnd",
    ),
    "claude": (
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest",
        "PostToolUse", "PostToolUseFailure", "Notification", "Stop", "StopFailure",
        "SessionEnd", "Elicitation", "ElicitationResult",
    ),
}
# Subagent hooks use the parent's session_id. They are deliberately not installed
# until the bridge can identify children without changing their parent's status.


class IntegrationError(Exception):
    pass


class JSONArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise IntegrationError(message)


@dataclass
class Snapshot:
    data: bytes | None
    mode: int = 0o600
    identity: tuple | None = None


def absolute_path(value, label):
    path = Path(value)
    if not path.is_absolute() or ".." in path.parts or any(ord(c) < 32 or ord(c) == 127 for c in str(path)):
        raise IntegrationError(label + " must be an absolute path without control characters or '..'.")
    return path


def check_path(path):
    """Reject symbolic links at every existing component, including ancestors."""
    current = Path(path.anchor)
    for index, component in enumerate(path.parts[1:]):
        current = current / component
        try:
            info = current.lstat()
        except FileNotFoundError:
            return
        if stat.S_ISLNK(info.st_mode):
            raise IntegrationError("A configuration or integration path is a symbolic link; nothing was changed.")
        if index < len(path.parts) - 2 and not stat.S_ISDIR(info.st_mode):
            raise IntegrationError("A configuration parent is not a directory; nothing was changed.")


def identity(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, stat.S_IMODE(info.st_mode))


def read_snapshot(path, limit=MAX_CONFIG_BYTES):
    check_path(path)
    try:
        descriptor = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return Snapshot(None)
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode):
            raise IntegrationError("A configuration or integration file is not a regular file.")
        if before.st_size > limit:
            raise IntegrationError("A configuration or integration file exceeds the size limit.")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            data = stream.read(limit + 1)
        if len(data) > limit:
            raise IntegrationError("A configuration or integration file exceeds the size limit.")
        after = os.fstat(descriptor)
        if identity(before) != identity(after):
            raise IntegrationError("A configuration changed while it was being read; try again.")
        return Snapshot(data, stat.S_IMODE(after.st_mode), identity(after))
    finally:
        os.close(descriptor)


def ensure_directory(path):
    check_path(path)
    if not path.exists():
        ensure_directory(path.parent)
        try:
            path.mkdir(mode=0o700)
        except FileExistsError:
            pass
    check_path(path)
    if not path.is_dir():
        raise IntegrationError("An integration parent is not a directory.")


def assert_unchanged(path, expected):
    current = read_snapshot(path)
    if current.identity != expected.identity or current.data != expected.data:
        raise IntegrationError("A configuration changed during installation; try again.")


def atomic_write(path, data, expected, mode=None):
    if len(data) > MAX_CONFIG_BYTES:
        raise IntegrationError("The updated configuration would exceed the size limit.")
    ensure_directory(path.parent)
    descriptor, temporary = tempfile.mkstemp(prefix=".broschy-", dir=str(path.parent))
    try:
        with os.fdopen(descriptor, "wb") as stream:
            os.fchmod(stream.fileno(), expected.mode if mode is None else mode)
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        assert_unchanged(path, expected)
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def safe_remove(path, expected):
    assert_unchanged(path, expected)
    if expected.data is not None:
        path.unlink()


def no_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise IntegrationError("A JSON configuration contains duplicate keys; nothing was changed.")
        result[key] = value
    return result


def parse_object(snapshot, label):
    if snapshot.data is None:
        return {}
    try:
        value = json.loads(snapshot.data.decode("utf-8"), object_pairs_hook=no_duplicate_keys,
                           parse_constant=lambda value: (_ for _ in ()).throw(ValueError("nonfinite")))
    except (ValueError, UnicodeError, RecursionError):
        raise IntegrationError(label + " is not valid JSON; nothing was changed.") from None
    if not isinstance(value, dict):
        raise IntegrationError(label + " must be a JSON object; nothing was changed.")
    return value


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False) + "\n").encode("utf-8")


def configuration_path(provider, home, env):
    if provider == "codex":
        base = absolute_path(env.get("CODEX_HOME", str(home / ".codex")), "CODEX_HOME")
        return base / "hooks.json"
    if provider == "claude":
        base = absolute_path(env.get("CLAUDE_CONFIG_DIR", str(home / ".claude")), "CLAUDE_CONFIG_DIR")
        return base / "settings.json"
    base = absolute_path(env.get("XDG_CONFIG_HOME", str(home / ".config")), "XDG_CONFIG_HOME")
    return base / "opencode" / "plugins" / "broschy.js"


def validate_hooks(config):
    hooks = config.get("hooks", {})
    if not isinstance(hooks, dict):
        raise IntegrationError("The existing hooks setting must be an object; nothing was changed.")
    for groups in hooks.values():
        if not isinstance(groups, list):
            raise IntegrationError("An existing hook event must contain a list; nothing was changed.")
        for group in groups:
            if not isinstance(group, dict) or not isinstance(group.get("hooks"), list):
                raise IntegrationError("An existing hook group is malformed; nothing was changed.")
            if any(not isinstance(handler, dict) for handler in group["hooks"]):
                raise IntegrationError("An existing hook handler is malformed; nothing was changed.")
    return hooks


def handler_for(cli_path, provider):
    return {"type": "command", "command": shlex.quote(str(cli_path)) + " agent hook --provider " + provider, "timeout": 2}


def locations(hooks, record):
    found = []
    for index, group in enumerate(hooks.get(record["event"], [])):
        # A user can add unrelated handlers to our group; retain those on removal.
        if {k: v for k, v in group.items() if k != "hooks"} != {}:
            continue
        matches = [i for i, value in enumerate(group["hooks"]) if value == record["handler"]]
        found.extend((index, item) for item in matches)
    if len(found) > 1:
        raise IntegrationError("An owned hook was duplicated; review it before changing this integration.")
    return found


def remove_owned(config, manifest):
    hooks = validate_hooks(config)
    for record in manifest.get("owned", []):
        matches = locations(hooks, record)
        if matches:
            group_index, item_index = matches[0]
            group = hooks[record["event"]][group_index]
            del group["hooks"][item_index]
            if not group["hooks"]:
                del hooks[record["event"]][group_index]
    # Refuse to overwrite hand-edited variants of our exact commands.
    owned_commands = {record["handler"]["command"] for record in manifest.get("owned", [])}
    for groups in hooks.values():
        for group in groups:
            for handler in group["hooks"]:
                if handler.get("command") in owned_commands:
                    raise IntegrationError("A Broschy hook was edited; it has been preserved. Review that hook before uninstalling or reinstalling.")
    for event in manifest.get("created_events", []):
        if hooks.get(event) == []:
            del hooks[event]
    if not hooks and manifest.get("created_hooks"):
        config.pop("hooks", None)


def manifest_for(provider, path, snapshot):
    value = parse_object(snapshot, "The Broschy ownership manifest")
    if not value:
        if snapshot.data is not None:
            raise IntegrationError("The Broschy ownership manifest is incomplete.")
        return None
    if (value.get("version") != 1 or value.get("provider") != provider
            or value.get("target") != str(path) or not isinstance(value.get("cli_path"), str)):
        raise IntegrationError("The integration manifest describes a different configuration location. Use its original configuration environment to uninstall it first.")
    absolute_path(value["cli_path"], "The stored CLI path")
    if provider == "opencode":
        hashes = value.get("owned_hashes")
        if not isinstance(hashes, list) or not hashes or len(hashes) > 32 or any(not isinstance(h, str) or len(h) != 64 for h in hashes):
            raise IntegrationError("The Broschy plugin ownership manifest is malformed.")
        if value.get("current_hash") not in hashes:
            raise IntegrationError("The Broschy plugin ownership manifest is incomplete.")
    else:
        records = value.get("owned")
        if not isinstance(records, list) or len(records) > 512:
            raise IntegrationError("The Broschy hook ownership manifest is malformed.")
        for record in records:
            if (not isinstance(record, dict) or record.get("event") not in EVENTS[provider]
                    or not isinstance(record.get("handler"), dict)
                    or record["handler"].get("type") != "command"
                    or not isinstance(record["handler"].get("command"), str)
                    or record["handler"].get("timeout") != 2):
                raise IntegrationError("The Broschy hook ownership manifest is malformed.")
        if not isinstance(value.get("created_events"), list) or any(event not in EVENTS[provider] for event in value["created_events"]):
            raise IntegrationError("The Broschy hook ownership manifest is malformed.")
    return value


def digest(data):
    return hashlib.sha256(data).hexdigest()


def configured(provider, config_snapshot, manifest):
    if manifest is None or config_snapshot.data is None:
        return False
    if provider == "opencode":
        return digest(config_snapshot.data) == manifest["current_hash"]
    hooks = validate_hooks(parse_object(config_snapshot, "The agent configuration"))
    expected = handler_for(manifest["cli_path"], provider)
    return all(len(locations(hooks, {"event": event, "handler": expected})) == 1 for event in EVENTS[provider])


def cli_available(path):
    check_path(path)
    try:
        info = path.stat()
    except (FileNotFoundError, PermissionError):
        return False
    return stat.S_ISREG(info.st_mode) and bool(stat.S_IMODE(info.st_mode) & 0o111) and os.access(path, os.X_OK)


def find_cli(explicit, isolated):
    candidates = []
    if explicit:
        candidates.append(absolute_path(explicit, "--cli-path"))
    else:
        here = Path(__file__).resolve()
        for parent in here.parents:
            if parent.name == "Contents":
                candidates.append(parent / "MacOS" / "broschy-cli")
                break
        candidates.append(here.parent.parent / "build" / "Broschy.app" / "Contents" / "MacOS" / "broschy-cli")
        if not isolated:
            located = shutil.which("broschy-cli")
            if located:
                candidates.append(absolute_path(located, "The CLI path"))
    for path in candidates:
        if cli_available(path):
            return path
    raise IntegrationError("Pass --cli-path with the absolute path to an executable broschy-cli.")


def plugin_bytes(template_path, cli_path):
    path = absolute_path(template_path, "--template-path") if template_path else Path(__file__).resolve().parent.parent / "Integrations" / "opencode" / "broschy.js"
    snapshot = read_snapshot(path, MAX_TEMPLATE_BYTES)
    if snapshot.data is None:
        raise IntegrationError("The bundled OpenCode template is missing; pass --template-path.")
    try:
        template = snapshot.data.decode("utf-8")
    except UnicodeError:
        raise IntegrationError("The OpenCode template is not UTF-8.") from None
    marker = '"__BROSCHY_CLI_PATH__"'
    if template.count(marker) != 1:
        raise IntegrationError("The OpenCode template has an invalid CLI placeholder.")
    return template.replace(marker, json.dumps(str(cli_path), ensure_ascii=True), 1).encode("utf-8")


@contextmanager
def mutation_lock(directory):
    ensure_directory(directory)
    path = directory / ".installer.lock"
    check_path(path)
    descriptor = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise IntegrationError("The integration lock is not a regular file.")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise IntegrationError("Another integration change is in progress; try again.") from None
        yield
    finally:
        os.close(descriptor)


def backup(directory, provider, snapshot, suffix):
    if snapshot.data is None:
        return
    target = directory / "backups" / provider / (time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + uuid.uuid4().hex + suffix)
    atomic_write(target, snapshot.data, Snapshot(None), mode=0o600)


def success_message(provider, action):
    if action == "uninstall":
        return "Broschy integration removed. Other hooks and settings were preserved."
    if provider == "codex":
        return "Hooks installed. Review and enable them with /hooks in Codex, then start a new session. Broschy does not change hook trust or permissions."
    if provider == "claude":
        return "Hooks installed. Start a new Claude Code session to load them."
    return "Plugin installed. Restart OpenCode to load it."


def operate(args):
    isolated = args.home is not None
    home = absolute_path(args.home, "--home") if isolated else Path.home()
    env = {} if isolated else os.environ
    target = configuration_path(args.provider, home, env)
    # Preserve the app's legacy support location across the product rename.
    directory = home / "Library" / "Application Support" / "NotchFlow" / "agents" / "integrations"
    manifest_path = directory / (args.provider + ".json")
    check_path(directory)
    config_snapshot = read_snapshot(target)
    manifest_snapshot = read_snapshot(manifest_path)
    manifest = manifest_for(args.provider, target, manifest_snapshot)
    if args.provider != "opencode":
        validate_hooks(parse_object(config_snapshot, "The agent configuration"))
    installed = configured(args.provider, config_snapshot, manifest)
    if args.action == "status":
        message = success_message(args.provider, "install") if installed else "Broschy integration is not installed."
        if manifest is not None and not installed:
            message = "The integration is missing or was changed. Reinstall to repair it; modified hooks are preserved."
        if installed:
            recorded_cli = absolute_path(manifest["cli_path"], "The stored CLI path")
            supplied_cli = absolute_path(args.cli_path, "--cli-path") if args.cli_path else recorded_cli
            if supplied_cli != recorded_cli or not cli_available(recorded_cli):
                installed = False
                message = "Broschy moved or its executable is unavailable. Reconnect from the current app to repair this integration."
        return {"provider": args.provider, "installed": installed, "message": message}
    if args.action == "uninstall" and manifest is None:
        return {"provider": args.provider, "installed": False, "message": "Broschy integration is already absent."}

    cli_path = find_cli(args.cli_path, isolated) if args.action == "install" else None
    new_plugin = plugin_bytes(args.template_path, cli_path) if args.action == "install" and args.provider == "opencode" else None
    with mutation_lock(directory):
        # Refuse stale reads rather than overwriting concurrent user changes.
        assert_unchanged(target, config_snapshot)
        assert_unchanged(manifest_path, manifest_snapshot)
        if args.provider == "opencode":
            if config_snapshot.data is not None:
                if manifest is None:
                    raise IntegrationError("An existing broschy.js is not owned by this installer; it was preserved.")
                if digest(config_snapshot.data) not in manifest["owned_hashes"]:
                    raise IntegrationError("The installed plugin was edited; it was preserved. Review it before reinstalling or uninstalling.")
            updated = new_plugin
            new_manifest = copy.deepcopy(manifest) if manifest else {
                "version": 1, "provider": args.provider, "target": str(target), "owned_hashes": [],
            }
            if args.action == "install":
                current_hash = digest(new_plugin)
                if current_hash not in new_manifest["owned_hashes"]:
                    new_manifest["owned_hashes"].append(current_hash)
                if len(new_manifest["owned_hashes"]) > 32:
                    raise IntegrationError("Uninstall this integration before changing its executable again.")
                new_manifest.update(cli_path=str(cli_path), current_hash=current_hash)
        else:
            original = parse_object(config_snapshot, "The agent configuration")
            config = copy.deepcopy(original)
            new_manifest = copy.deepcopy(manifest) if manifest else {
                "version": 1, "provider": args.provider, "target": str(target), "owned": [],
                "created_config": config_snapshot.data is None, "created_hooks": "hooks" not in original,
                "created_events": [event for event in EVENTS[args.provider] if event not in original.get("hooks", {})],
            }
            if manifest:
                remove_owned(config, manifest)
            if args.action == "install":
                hooks = config.setdefault("hooks", {})
                handler = handler_for(cli_path, args.provider)
                for event in EVENTS[args.provider]:
                    record = {"event": event, "handler": handler}
                    # Do not adopt user-managed lookalikes on a first installation.
                    if any(item.get("command") == handler["command"] for group in hooks.get(event, [])
                           for item in group["hooks"]):
                        raise IntegrationError("A matching hook exists without Broschy ownership; it was preserved.")
                    hooks.setdefault(event, []).append({"hooks": [copy.deepcopy(handler)]})
                    if record not in new_manifest["owned"]:
                        new_manifest["owned"].append(copy.deepcopy(record))
                if len(new_manifest["owned"]) > 512:
                    raise IntegrationError("Uninstall this integration before changing its executable again.")
                new_manifest["cli_path"] = str(cli_path)
            updated = None if args.action == "uninstall" and (config_snapshot.data is None or (not config and manifest.get("created_config"))) else json_bytes(config)
            # Preserve the original formatting on an idempotent install.
            if config == original:
                updated = config_snapshot.data
        if args.action == "install" and updated == config_snapshot.data and new_manifest == manifest:
            return {"provider": args.provider, "installed": True, "message": success_message(args.provider, "install")}
        if updated is not None and len(updated) > MAX_CONFIG_BYTES:
            raise IntegrationError("The updated configuration would exceed the size limit.")
        backup(directory, args.provider, config_snapshot, ".js" if args.provider == "opencode" else ".json")
        if args.action == "install":
            # Record both current and past owned handlers before updating config.
            # An interrupted reinstall can safely remove either version later.
            atomic_write(manifest_path, json_bytes(new_manifest), manifest_snapshot, mode=0o600)
        if updated is None:
            safe_remove(target, config_snapshot)
        else:
            atomic_write(target, updated, config_snapshot)
        if args.action == "uninstall":
            safe_remove(manifest_path, manifest_snapshot)
    return {"provider": args.provider, "installed": args.action == "install", "message": success_message(args.provider, args.action)}


def main(argv=None):
    parser = JSONArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("install", "status", "uninstall"))
    parser.add_argument("--provider", required=True, choices=PROVIDERS)
    parser.add_argument("--cli-path")
    parser.add_argument("--home", help="Isolated home; ignores agent configuration environment variables.")
    parser.add_argument("--template-path", help="Absolute path to the bundled OpenCode JavaScript template.")
    provider = "unknown"
    try:
        args = parser.parse_args(argv)
        provider = args.provider
        result = operate(args)
        code = 0
    except (IntegrationError, OSError, RecursionError) as error:
        if isinstance(error, IntegrationError):
            message = str(error)
        elif isinstance(error, RecursionError):
            message = "A configuration is nested too deeply; nothing was changed."
        else:
            message = "The integration could not be changed: " + (error.strerror or "file operation failed") + "."
        result = {"provider": provider, "installed": False, "message": message}
        code = 1
    print(json.dumps(result, ensure_ascii=False))
    return code


if __name__ == "__main__":
    sys.exit(main())
