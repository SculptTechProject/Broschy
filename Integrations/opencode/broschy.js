// Broschy's local OpenCode event adapter. The installer fills in the CLI path.
// Only allowlisted lifecycle metadata leaves this plugin; never conversation text.
import { spawn } from "node:child_process";

const CLI_PATH = "__BROSCHY_CLI_PATH__";
const MAX_PENDING = 64;
const MAX_SESSIONS = 256;
const MAX_BYTES = 8192;
const TOOL_NAMES = new Set([
  "bash", "read", "write", "edit", "glob", "grep", "webfetch", "websearch",
  "task", "question", "todowrite", "todoread", "patch", "multiedit", "lsp",
]);

const safeID = (value) => typeof value === "string" && value.length <= 256
  && /^[A-Za-z0-9._:-]+$/.test(value) ? value : undefined;
const safeDirectory = (value) => typeof value === "string" && value.startsWith("/")
  && Buffer.byteLength(value, "utf8") <= 4096 && !/[\x00-\x1f\x7f-\x9f]/.test(value)
  ? value : undefined;

export const BroschyPlugin = async (context) => {
  const sessions = new Map();
  const pending = [];
  let running = false;
  const fallbackDirectory = safeDirectory(context?.directory);

  const drain = () => {
    if (running || pending.length === 0 || !CLI_PATH.startsWith("/")) return;
    running = true;
    const payload = pending.shift();
    let child;
    let timer;
    let finished = false;
    const finish = () => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      running = false;
      drain();
    };
    try {
      child = spawn(CLI_PATH, ["agent", "hook", "--provider", "opencode"], {
        stdio: ["pipe", "ignore", "ignore"],
        windowsHide: true,
      });
      child.once("error", finish);
      child.once("close", finish);
      child.stdin.on("error", () => {});
      child.stdin.end(payload);
      timer = setTimeout(() => {
        try { child.kill("SIGKILL"); } catch {}
        finish();
      }, 2000);
      timer.unref?.();
      child.unref?.();
    } catch {
      try { child?.kill("SIGKILL"); } catch {}
      finish();
    }
  };

  const enqueue = (payload) => {
    const serialized = JSON.stringify(payload) + "\n";
    if (Buffer.byteLength(serialized, "utf8") > MAX_BYTES) return;
    if (pending[pending.length - 1] === serialized) return;
    if (pending.length >= MAX_PENDING) {
      // Prefer dropping an old heartbeat over a permission/question transition.
      const heartbeat = pending.findIndex((item) => item.includes('"hook_event_name":"session.status"')
        || item.includes('"hook_event_name":"session.updated"'));
      pending.splice(heartbeat >= 0 ? heartbeat : 0, 1);
    }
    pending.push(serialized);
    drain();
  };

  return {
    event: async ({ event } = {}) => {
      // Event callbacks never wait for Broschy or alter the agent's result.
      try {
        if (!event || typeof event.type !== "string") return;
        const properties = event.properties;
        if (!properties || typeof properties !== "object" || Array.isArray(properties)) return;
        let sessionID;
        let requestID;
        let status;
        let toolName;
        let role;
        let metadata;
        switch (event.type) {
          case "session.created":
          case "session.updated": {
            const info = properties.info;
            if (!info || typeof info !== "object") return;
            sessionID = safeID(info.id);
            if (!sessionID) return;
            const previous = sessions.get(sessionID);
            metadata = {
              cwd: safeDirectory(info.directory) ?? previous?.cwd ?? fallbackDirectory,
              parentSessionID: safeID(info.parentID) ?? previous?.parentSessionID,
            };
            sessions.delete(sessionID);
            sessions.set(sessionID, metadata);
            if (sessions.size > MAX_SESSIONS) sessions.delete(sessions.keys().next().value);
            break;
          }
          case "session.status":
            sessionID = safeID(properties.sessionID);
            status = properties.status?.type;
            if (!["busy", "idle", "retry"].includes(status)) return;
            break;
          case "session.idle":
          case "session.deleted":
          case "session.error":
            sessionID = safeID(properties.sessionID ?? properties.info?.id);
            break;
          case "permission.asked":
            sessionID = safeID(properties.sessionID);
            requestID = safeID(properties.id);
            toolName = TOOL_NAMES.has(properties.permission) ? properties.permission : undefined;
            if (!requestID) return;
            break;
          case "question.asked":
            sessionID = safeID(properties.sessionID);
            requestID = safeID(properties.id);
            if (!requestID) return;
            break;
          case "permission.replied":
          case "question.replied":
          case "question.rejected":
            sessionID = safeID(properties.sessionID);
            requestID = safeID(properties.requestID);
            if (!requestID) return;
            break;
          case "message.updated":
            if (properties.info?.role !== "user") return;
            sessionID = safeID(properties.info.sessionID);
            role = "user";
            break;
          default:
            return;
        }
        // Global errors have no trustworthy session ID and are not attributed.
        if (!sessionID) return;
        metadata = metadata ?? sessions.get(sessionID);
        const cwd = metadata?.cwd ?? fallbackDirectory;
        if (!cwd) return;
        enqueue({
          hook_event_name: event.type,
          session_id: sessionID,
          cwd,
          request_id: requestID,
          status,
          tool_name: toolName,
          parent_session_id: metadata?.parentSessionID,
          role,
        });
        if (event.type === "session.deleted") sessions.delete(sessionID);
      } catch {
        // Monitoring is best effort. Never block a coding session on an adapter error.
      }
    },
  };
};
