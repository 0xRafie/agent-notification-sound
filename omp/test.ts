// Run by ../test.sh: loads the extension with a fake OMP host and prints
// "<name>|<class>|<title>|<message>|<sound>" per case (NOTIFY_DRY_RUN=1).
const ext = await import("./index.ts");
const handlers: Record<string, Function> = {};
ext.default({ setLabel() {}, registerCommand() {}, on(name: string, fn: Function) { handlers[name] = fn; }, pi: {} });

const user = (text: string) => ({ role: "user", content: [{ type: "text", text }] });
const reply = (stopReason = "stop") => ({ role: "assistant", stopReason });
const result = (type: string, status = "completed") => ({ role: "custom", customType: "async-result", content: "x", details: { jobs: [{ type, status }] } });
const jobs = (...types: string[]) => () => ({ running: types.map(type => ({ type, status: "running" })) });

const cases: Array<[string, unknown[], (() => unknown) | undefined, string?]> = [
  ["done", [user("hi"), reply()], undefined],
  ["failed", [user("hi"), reply("error")], undefined],
  ["replied, busy", [user("hi"), reply()], jobs("task", "task", "bash")],
  ["job done, none left", [user("hi"), reply(), result("task"), reply()], jobs()],
  ["shell done, 1 left", [user("hi"), reply(), result("bash"), reply()], jobs("task")],
  ["subagent failed, 1 left", [user("hi"), reply(), result("task", "failed"), reply()], jobs("bash")],
  ["loop run", [user("check"), reply(), user("check"), reply()], undefined],
  ["question", [], undefined, "ask"],
];
for (const [name, messages, snapshot, tool] of cases) {
  const ctx = { cwd: "/x/proj", agent: { kind: "main" }, ui: {}, getAsyncJobSnapshot: snapshot };
  const orig = console.log;
  let line = "";
  console.log = (s: string) => { line = s; };
  if (tool) await handlers["tool_execution_start"]({ toolName: tool }, ctx);
  else await handlers["agent_end"]({ messages }, ctx);
  console.log = orig;
  console.log(`${name}|${line}`);
  await new Promise(r => setTimeout(r, 1)); // cooldown is skipped in dry-run
}
