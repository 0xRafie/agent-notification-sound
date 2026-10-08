/**
 * OMP Notification Sound Extension
 *
 * Plays a sound and sends a desktop notification when OMP finishes, fails, or
 * asks you a question, with the same titles and messages as ../notify.sh uses
 * for Claude Code, Droid and Grok. macOS uses afplay + osascript; other
 * platforms can use a custom sound command and in-app OMP notifications.
 *
 * Works with no config. To override, add to ~/.omp/agent/config.yml
 * (values shown are the defaults):
 *   notificationSound:
 *     enabled: true
 *     sound: ~/.factory/sounds/fx-ok01.wav  # absolute path; Glass.aiff when missing
 *     volume: 1
 *     cooldownMs: 1500
 *     desktopNotification:
 *       title: "OMP [{project}]"            # {project} = session folder name
 *       message: OMP task completed
 *       failedMessage: OMP task failed
 *       questionMessage: OMP asks a question
 *     events:
 *       agent_end: true
 *       tool_execution_start: true          # only the `ask` tool
 */

import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { existsSync } from "node:fs";
import { spawn } from "node:child_process";
import { homedir, platform } from "node:os";
import { basename, join } from "node:path";

type NotifyLevel = "info" | "warning" | "error";

type CommandContext = {
  /** Host agent identity; `kind` is `"main"` for a top-level session, `"sub"` for a subagent. */
  agent?: { kind?: "main" | "sub"; name?: string };
  cwd?: string;
  settings?: Record<string, unknown>;
  ui?: { notify?: (message: string, type?: NotifyLevel) => void };
};

type EventContext = CommandContext;

type SoundCommandConfig = {
  command?: string;
  args?: string[];
};

type DesktopNotificationConfig = {
  enabled: boolean;
  title: string;
  message: string;
  failedMessage: string;
  questionMessage: string;
};

type NotificationSoundConfig = {
  enabled: boolean;
  sound: string;
  volume: number;
  cooldownMs: number;
  notifyOnLoad: boolean;
  events: Record<string, boolean>;
  command?: SoundCommandConfig;
  desktopNotification: DesktopNotificationConfig;
};

const LABEL = "Notification Sound";
const COMMAND_NAME = "notification-sound";
const FACTORY_SOUND = join(homedir(), ".factory/sounds/fx-ok01.wav");
const DEFAULT_SOUND = existsSync(FACTORY_SOUND) ? FACTORY_SOUND : "/System/Library/Sounds/Glass.aiff";
const DEFAULT_VOLUME = 1;
const DEFAULT_COOLDOWN_MS = 1500;
const DEFAULT_NOTIFICATION_TITLE = "OMP [{project}]";
const DEFAULT_NOTIFICATION_MESSAGE = "OMP task completed";
const DEFAULT_FAILED_MESSAGE = "OMP task failed";
const DEFAULT_QUESTION_MESSAGE = "OMP asks a question";
const DEFAULT_EVENTS: Record<string, boolean> = {
  session_start: false,
  agent_end: true,
  tool_execution_start: true, // only the `ask` tool notifies (see handleEvent)
};
const CANDIDATE_EVENTS = [
  "tool_execution_start",
  "session_start",
  "session_switch",
  "session_branch",
  "session_compact",
  "session_shutdown",
  "agent_start",
  "agent_end",
  "turn_start",
  "turn_end",
  "auto_compaction_start",
  "auto_compaction_end",
  "auto_retry_start",
  "auto_retry_end",
  "ttsr_triggered",
  "todo_reminder",
] as const;

let lastPlayedAt = 0;
let lastNotifiedAt = 0;

/**
 * Hosts that expose a settings layer on the handler context (upstream Pi) win.
 * OMP's ExtensionContext has no `settings` field, so on OMP the config must be
 * read from the process-wide settings singleton re-exported by the host module
 * (`pi.pi.settings`) — otherwise every `notificationSound.*` key is ignored and
 * the extension silently runs on its defaults.
 */
type SettingsSource = {
  getGlobalSettings?: () => unknown;
  getProjectSettings?: () => unknown;
};

let hostPi: { settings?: SettingsSource; logger?: { warn?: (message: string) => void } } | undefined;

function resolveRawSettings(ctx: CommandContext | undefined): Record<string, unknown> {
  const fromContext = getRecord(ctx?.settings);
  if (Object.keys(fromContext).length > 0) return fromContext;

  // Read the proxy per call, not once at load: it throws until the host calls
  // `Settings.init()`, which has not happened yet when this module is evaluated.
  let source: SettingsSource | undefined;
  try {
    source = hostPi?.settings;
  } catch {
    source = undefined;
  }
  if (!source) return {};

  let global: Record<string, unknown> = {};
  let project: Record<string, unknown> = {};
  try {
    global = getRecord(source.getGlobalSettings?.());
    project = getRecord(source.getProjectSettings?.());
  } catch {
    return {};
  }
  if (Object.keys(project).length === 0) return global;

  // One level deep, so a project layer that sets a single
  // `notificationSound.events.*` key does not drop the global group.
  const merged: Record<string, unknown> = { ...global };
  for (const [key, value] of Object.entries(project)) {
    const base = merged[key];
    merged[key] =
      base && typeof base === "object" && !Array.isArray(base) && value && typeof value === "object" && !Array.isArray(value)
        ? { ...(base as Record<string, unknown>), ...(value as Record<string, unknown>) }
        : value;
  }
  return merged;
}

function readConfig(settings: unknown): NotificationSoundConfig {
  const raw = getRecord(getRecord(settings).notificationSound);
  const events = { ...DEFAULT_EVENTS, ...getBooleanRecord(raw.events) };
  const command = getRecord(raw.command);
  const desktopNotification = readDesktopNotificationConfig(raw.desktopNotification);

  return {
    enabled: raw.enabled !== false,
    sound: typeof raw.sound === "string" && raw.sound.trim() ? raw.sound : DEFAULT_SOUND,
    volume: clampNumber(raw.volume, DEFAULT_VOLUME, 0, 1),
    cooldownMs: Math.max(0, Math.trunc(toNumber(raw.cooldownMs, DEFAULT_COOLDOWN_MS))),
    notifyOnLoad: raw.notifyOnLoad === true,
    events,
    command: Object.keys(command).length > 0
      ? {
        command: typeof command.command === "string" ? command.command : undefined,
        args: Array.isArray(command.args) ? command.args.filter((arg): arg is string => typeof arg === "string") : undefined,
      }
      : undefined,
    desktopNotification,
  };
}

function readDesktopNotificationConfig(value: unknown): DesktopNotificationConfig {
  if (typeof value === "boolean") {
    return {
      enabled: value,
      title: DEFAULT_NOTIFICATION_TITLE,
      message: DEFAULT_NOTIFICATION_MESSAGE,
      failedMessage: DEFAULT_FAILED_MESSAGE,
      questionMessage: DEFAULT_QUESTION_MESSAGE,
    };
  }

  const raw = getRecord(value);
  const text = (key: string, fallback: string) =>
    typeof raw[key] === "string" && (raw[key] as string).trim() ? (raw[key] as string) : fallback;
  return {
    enabled: raw.enabled !== false,
    title: text("title", DEFAULT_NOTIFICATION_TITLE),
    message: text("message", DEFAULT_NOTIFICATION_MESSAGE),
    failedMessage: text("failedMessage", DEFAULT_FAILED_MESSAGE),
    questionMessage: text("questionMessage", DEFAULT_QUESTION_MESSAGE),
  };
}

function getRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, unknown> : {};
}

function getBooleanRecord(value: unknown): Record<string, boolean> {
  const raw = getRecord(value);
  const result: Record<string, boolean> = {};
  for (const [key, enabled] of Object.entries(raw)) {
    if (typeof enabled === "boolean") result[key] = enabled;
  }
  return result;
}

function toNumber(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

function clampNumber(value: unknown, fallback: number, min: number, max: number): number {
  const numeric = toNumber(value, fallback);
  return Math.min(max, Math.max(min, numeric));
}

function notify(ctx: CommandContext | undefined, message: string, level: NotifyLevel = "info"): void {
  ctx?.ui?.notify?.(message, level);
}

function playSound(config: NotificationSoundConfig, reason: string): { played: boolean; reason?: string } {
  if (!config.enabled) return { played: false, reason: "disabled" };

  const now = Date.now();
  if (now - lastPlayedAt < config.cooldownMs) return { played: false, reason: "cooldown" };

  const command = resolveSoundCommand(config);
  if (!command) return { played: false, reason: "unsupported-platform-or-missing-sound" };

  const started = spawnDetached(command.command, command.args);
  if (!started.ok) return { played: false, reason: started.reason };

  lastPlayedAt = now;
  return { played: true, reason };
}

function sendDesktopNotification(config: NotificationSoundConfig, reason: string): { sent: boolean; reason?: string } {
  if (!config.enabled) return { sent: false, reason: "disabled" };
  if (!config.desktopNotification.enabled) return { sent: false, reason: "desktop-notification-disabled" };

  const now = Date.now();
  if (now - lastNotifiedAt < config.cooldownMs) return { sent: false, reason: "cooldown" };

  const command = resolveDesktopNotificationCommand(config);
  if (!command) return { sent: false, reason: "unsupported-platform" };

  const started = spawnDetached(command.command, command.args);
  if (!started.ok) return { sent: false, reason: started.reason };

  lastNotifiedAt = now;
  return { sent: true, reason };
}

function spawnDetached(command: string, args: string[]): { ok: true } | { ok: false; reason: string } {
  try {
    const child = spawn(command, args, {
      detached: true,
      stdio: "ignore",
    });
    // `spawn` reports ENOENT/EACCES asynchronously through the child's `error`
    // event, never as a throw, so the try/catch below cannot see them. With no
    // listener that becomes an uncaught exception that takes the host session
    // down — reachable from any typo in `notificationSound.command.command`,
    // since only the built-in afplay path is guarded by `existsSync`.
    child.on("error", (error: Error) => {
      hostPi?.logger?.warn?.(`${LABEL}: could not run ${command}: ${error.message}`);
    });
    child.unref();
    return { ok: true };
  } catch (error) {
    return { ok: false, reason: error instanceof Error ? error.message : "spawn-failed" };
  }
}

function resolveSoundCommand(config: NotificationSoundConfig): { command: string; args: string[] } | null {
  if (config.command?.command) {
    return { command: config.command.command, args: config.command.args ?? [] };
  }

  if (platform() !== "darwin") return null;
  if (!existsSync(config.sound)) return null;

  return {
    command: "afplay",
    args: ["-v", String(config.volume), config.sound],
  };
}

function resolveDesktopNotificationCommand(config: NotificationSoundConfig): { command: string; args: string[] } | null {
  if (platform() !== "darwin") return null;

  return {
    command: "/usr/bin/osascript",
    args: [
      "-e",
      `display notification ${quoteAppleScript(config.desktopNotification.message)} with title ${quoteAppleScript(config.desktopNotification.title)}`,
    ],
  };
}

function quoteAppleScript(value: string): string {
  return `"${value.replace(/\\/g, "\\\\").replace(/"/g, "\\\"")}"`;
}

type HostEvent = {
  willContinue?: boolean;
  toolName?: string;
  messages?: Array<{ role?: string; stopReason?: string }>;
};

function handleEvent(eventName: string, ctx: CommandContext | undefined, event?: HostEvent): void {
  // Subagents run their own session with the same extension bound to it, and
  // unlike `session_stop` the host does not gate their `agent_end` on agent
  // kind — so without this every `task`/scout completion chimes mid-task while
  // the main agent is still working.
  if (ctx?.agent?.kind === "sub") return;

  // A non-terminal `agent_end` is an auto-retry, compaction continuation or
  // empty-stop recovery — the agent is still working. Chiming here announces
  // "done" mid-task and, when the real settle follows more than `cooldownMs`
  // later, plays a second time.
  if (eventName === "agent_end" && event?.willContinue === true) return;

  // Only the `ask` tool (the agent asking you a question) notifies here.
  if (eventName === "tool_execution_start" && event?.toolName !== "ask") return;

  const config = readConfig(resolveRawSettings(ctx));
  if (!config.events[eventName]) return;

  // Same three messages as the Claude/Droid/Grok hooks: completed, failed, asks a question.
  let message = config.desktopNotification.message;
  if (eventName === "tool_execution_start") message = config.desktopNotification.questionMessage;
  if (eventName === "agent_end") {
    const last = [...(event?.messages ?? [])].reverse().find((m) => m.role === "assistant");
    if (last?.stopReason === "aborted") return; // you interrupted it; no "done" ping
    if (last?.stopReason === "error") message = config.desktopNotification.failedMessage;
  }

  // `{project}` -> session folder name, matching the other hooks' "<Tool> [folder]" title.
  const project = basename(ctx?.cwd ?? process.cwd()) || "?";
  config.desktopNotification.title = config.desktopNotification.title.replaceAll("{project}", project);
  config.desktopNotification.message = message.replaceAll("{project}", project);

  const notificationResult = sendDesktopNotification(config, eventName);
  if (!notificationResult.sent && notificationResult.reason && notificationResult.reason !== "cooldown" && notificationResult.reason !== "disabled" && notificationResult.reason !== "desktop-notification-disabled") {
    notify(ctx, `${LABEL}: desktop notification skipped (${notificationResult.reason})`, "warning");
  }

  const soundResult = playSound(config, eventName);
  if (!soundResult.played && soundResult.reason && soundResult.reason !== "cooldown" && soundResult.reason !== "disabled") {
    notify(ctx, `${LABEL}: sound skipped (${soundResult.reason})`, "warning");
  }
}

function registerEvent(pi: ExtensionAPI, eventName: string): void {
  pi.on(eventName as never, async (event: unknown, ctx: EventContext) => {
    handleEvent(eventName, ctx, event as HostEvent);
  });
}

async function handleCommand(args: string, ctx: CommandContext): Promise<void> {
  const subcommand = (args.trim().split(/\s+/, 1)[0] || "status").toLowerCase();
  const config = readConfig(resolveRawSettings(ctx));

  switch (subcommand) {
    case "test": {
      const testConfig = { ...config, cooldownMs: 0 };
      const notificationResult = sendDesktopNotification(testConfig, "manual-test");
      const soundResult = playSound(testConfig, "manual-test");
      notify(
        ctx,
        `${LABEL}: test ${soundResult.played ? "sound played" : `sound failed (${soundResult.reason ?? "unknown"})`}; ${notificationResult.sent ? "desktop notification sent" : `desktop notification skipped (${notificationResult.reason ?? "unknown"})`}.`,
        soundResult.played || notificationResult.sent ? "info" : "warning",
      );
      return;
    }
    case "status": {
      const enabledEvents = Object.entries(config.events).filter(([, enabled]) => enabled).map(([name]) => name);
      const soundCommand = resolveSoundCommand(config);
      const notificationCommand = resolveDesktopNotificationCommand(config);
      notify(
        ctx,
        [
          `${LABEL}: ${config.enabled ? "enabled" : "disabled"}`,
          `Sound: ${config.sound}`,
          `Sound command: ${soundCommand ? [soundCommand.command, ...soundCommand.args].join(" ") : "unavailable"}`,
          `Desktop notification: ${config.desktopNotification.enabled ? "enabled" : "disabled"}`,
          `Desktop command: ${notificationCommand ? [notificationCommand.command, ...notificationCommand.args].join(" ") : "unavailable"}`,
          `Cooldown: ${config.cooldownMs}ms`,
          `Events: ${enabledEvents.length > 0 ? enabledEvents.join(", ") : "none"}`,
        ].join("\n"),
        "info",
      );
      return;
    }
    default:
      notify(ctx, `${LABEL}: unknown command. Use /${COMMAND_NAME} status or /${COMMAND_NAME} test.`, "warning");
  }
}

export default function (pi: ExtensionAPI) {
  pi.setLabel?.(LABEL);

  // OMP does not put a settings layer on the handler context, so remember the
  // host module; the settings proxy itself is read lazily inside
  // `resolveRawSettings` because it is not initialized at load time.
  hostPi = pi.pi;

  pi.registerCommand(COMMAND_NAME, {
    description: "Play and inspect OMP notification sounds.",
    getArgumentCompletions(argumentPrefix: string) {
      return ["status", "test"]
        .filter(command => command.startsWith(argumentPrefix))
        .map(command => ({ label: command, value: command }));
    },
    handler: handleCommand,
  });

  for (const eventName of CANDIDATE_EVENTS) registerEvent(pi, eventName);

  pi.on("input", async (event: { text?: string }, ctx: CommandContext) => {
    const text = event.text?.trim();
    if (!text?.startsWith(`/${COMMAND_NAME}`)) return;
    const afterCommand = text.slice(COMMAND_NAME.length + 1);
    await handleCommand(afterCommand, ctx);
    return { handled: true };
  });

  pi.on("session_start", async (_event: unknown, ctx: EventContext) => {
    const config = readConfig(resolveRawSettings(ctx));
    if (config.notifyOnLoad) {
      notify(ctx, `${LABEL}: loaded. Run /${COMMAND_NAME} test to verify audio and desktop notification.`, "info");
    }
  });
}
