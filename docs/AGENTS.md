# Agents

Broschy can monitor local Codex, Claude Code, and OpenCode sessions from the notch. It shows which projects have activity and which sessions need a response or review. This integration does not send prompts, approve tools, or stop agents.

## Connect

Build and launch `Broschy.app`, then open **Agents → Connections** and connect the tools you use. The setup helper requires Python 3 (`/usr/bin/python3`, available with the developer tools used to build Broschy).

- **Codex:** Broschy adds command hooks to your user `hooks.json`. Restart Codex and review the new hooks through `/hooks` when required. Broschy never changes Codex's hook trust records. This adapter targets Codex CLI. Monitoring conversations in the Codex desktop app is not currently verified. Configuration alone does not mean that an existing session is being observed.
- **Claude Code:** Broschy merges command hooks into your user `settings.json`. Restart Claude Code after connecting.
- **OpenCode:** Broschy installs a local JavaScript plugin. Restart OpenCode so it loads the plugin. Sessions running with plugins disabled will not send events.

Once a session emits an event, it appears in Agents. A configured connection with no events stays **Configured · awaiting events**. Existing conversations are not imported. You do not need API keys or a new account in Broschy.

Broschy installs a reference to the CLI inside your current app bundle. If you move the app, reconnect the integration from its new location.

## Read the panel

| Status | Meaning |
| :--- | :--- |
| Working | A recent prompt, tool call, or busy event was observed. Activity expires without new evidence, even when the process is still open. |
| Needs attention | The agent reported a permission request or a question. Respond in the original tool. |
| Ready to review | The agent stopped responding or became idle. Review the result; this does not certify that the task succeeded. |
| Error | A supported failure event was observed. Broschy shows a generic error, without recording the error contents. |
| Idle | The session started or was interrupted. |
| Status unknown | Working activity has not been refreshed for 120 seconds with a verified live process, or 75 seconds without one. Check the original tool. An unanswered request becomes unknown after 30 minutes even if its process remains alive. |

**Needs you** gathers questions, permission requests, unreviewed responses, and errors. Use the status icon at the right of a session for **Copy resume command**, **Open project folder**, or **Mark reviewed**. Paste a copied resume command in your terminal to resume the corresponding provider's session. This does not select a running terminal tab or jump to a particular desktop conversation.

Marking a response or error reviewed only clears its attention badge in Broschy. It does not change agent state. An active permission request cannot be marked reviewed. When its originating process exits, an active session is hidden even if no exit hook arrived. Completed responses and errors remain available for review. Ended sessions are hidden; the panel shows sessions updated in the last 24 hours, from the 512 most recently modified snapshots.

In the compact notch, attention takes priority over focus, command results, and music. Working agents appear when no focus session or recent command result needs that space. The animation indicates activity, not token throughput or percent complete. It respects Reduce Motion.

## What is stored

Hooks pass events to `broschy-cli agent hook`. Codex and Claude may include conversation content in their hook payloads; the CLI transiently receives bounded JSON and immediately drops fields outside its metadata allowlist before atomically updating a local session snapshot. It does not save stdin or transcripts. Provider names are part of session identities, so sessions with the same ID in different tools remain separate.

Saved fields include provider, session ID, working directory, project folder name, status, generic activity label, timestamps, parent session ID when available, opaque pending request IDs, and the originating process ID, start time, and executable name when identifiable. Process start time prevents a reused PID from keeping an old session active; no process arguments or executable paths are stored. Prompts, conversation titles, tool arguments, output, permission descriptions, answers, and credentials are not recorded.

```text
~/Library/Application Support/NotchFlow/agents/
├── sessions/       # Per-session status snapshots
└── integrations/   # Setup ownership records and configuration backups
```

Configuration backups contain the original tool settings, which may contain private configuration. They stay on your Mac and should not be shared or committed. No local network listener, cloud sync, analytics, or model requests are involved.

## Configuration and removal

Default locations:

| Tool | Configuration |
| :--- | :--- |
| Codex | `~/.codex/hooks.json` (`CODEX_HOME` is honored) |
| Claude Code | `~/.claude/settings.json` (`CLAUDE_CONFIG_DIR` is honored) |
| OpenCode | `~/.config/opencode/plugins/broschy.js` (`XDG_CONFIG_HOME` is honored) |

Environment overrides apply to the process running setup. A GUI app may not inherit your shell environment; use the command-line installer below for a custom configuration directory.

Setup preserves unrelated settings and hooks, makes backups, and refuses malformed JSON or unsafe file locations. **Disconnect** removes Broschy's own entries; restart the affected tool afterward. It leaves session history and backup files in Broschy's data folder.

From the repository:

```sh
python3 scripts/agent-integrations.py install --provider codex \
  --cli-path "$PWD/build/Broschy.app/Contents/MacOS/broschy-cli"

# Replace codex with claude or opencode for the other integrations.
python3 scripts/agent-integrations.py status --provider codex \
  --cli-path "$PWD/build/Broschy.app/Contents/MacOS/broschy-cli"

python3 scripts/agent-integrations.py uninstall --provider codex \
  --cli-path "$PWD/build/Broschy.app/Contents/MacOS/broschy-cli"

# Read normalized snapshots locally.
./build/Broschy.app/Contents/MacOS/broschy-cli agent list
```

## Scope and limitations

This first version monitors events going forward. It cannot attach to every already running session, guarantee event delivery after a force quit, or prove that an open process is currently working. It checks the identity of the specific originating process, not whether any process with the same provider name is running. Older snapshots without a process identity use the shorter activity expiry. Tools that disable hooks/plugins or use different configuration paths will not be visible. A stopped response may be followed by more work from another hook.

Codex and Claude subagent lifecycle callbacks are not used to mark the parent finished. OpenCode sessions with an explicit parent ID can be shown as child sessions. Tool compatibility depends on installed versions and their event support; the adapters were developed against Codex CLI 0.144.5, Claude Code 2.1.197, and OpenCode 1.17.15. Codex CLI 0.144.5 supports `Stop` after a completed response, but does not implement `SessionEnd` or `Interrupt` hooks. Its process identity therefore provides the exit fallback; configured keys for those events remain available for newer versions. An installed configuration is not an end-to-end compatibility guarantee. See the [0.144.5 event registry](https://github.com/openai/codex/blob/rust-v0.144.5/codex-rs/hooks/src/lib.rs#L18-L30).

Full task creation, sending follow-up prompts, cancellation, and approvals inside Broschy are outside this version. Those need separate provider control APIs and explicit ownership of the sessions being controlled.

Official integration references: [Codex hooks](https://learn.chatgpt.com/docs/hooks), [Claude Code hooks](https://code.claude.com/docs/en/hooks), [OpenCode plugins](https://opencode.ai/docs/plugins/).
