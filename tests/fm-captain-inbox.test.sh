#!/usr/bin/env bash
# Synthetic behavioral contracts for local Captain's Inbox capture, state updates,
# and legacy/confirmed-ID deletion, including races and storage/transport failures.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-captain-inbox)
EXT="$ROOT/.pi/extensions/fm-captain-inbox.ts"
CLI="$ROOT/bin/fm-captain-inbox.sh"
OPERATIONAL_INPUT="$ROOT/bin/fm-operational-input.sh"

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT

if ! command -v node >/dev/null 2>&1; then
  echo "skip: node not found for Captain's Inbox contract test"
  exit 0
fi

out=$(EXT="$EXT" CLI="$CLI" OPERATIONAL_INPUT="$OPERATIONAL_INPUT" TMP_ROOT="$TMP_ROOT" node --input-type=module 2>&1 <<'JS'
import assert from "node:assert/strict";
import { execFile as execFileCallback, execFileSync, spawn } from "node:child_process";
import { chmod, link, lstat, mkdir, readFile, readdir, rename, rm, symlink, utimes, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { promisify } from "node:util";
import { pathToFileURL } from "node:url";

const execFile = promisify(execFileCallback);
const extensionPath = process.env.EXT;
const cli = process.env.CLI;
const operationalInput = process.env.OPERATIONAL_INPUT;
const root = process.env.TMP_ROOT;
const delay = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));

function cliEnvironment(home, extra = {}) {
  return {
    ...process.env,
    FM_HOME: home,
    FM_ROOT_OVERRIDE: home,
    FM_STATE_OVERRIDE: `${home}/state`,
    FM_CONFIG_OVERRIDE: `${home}/config`,
    ...extra,
  };
}

async function runCli(home, ...args) {
  return execFile(cli, args, { env: cliEnvironment(home) });
}

async function list(home) {
  const { stdout } = await runCli(home, "list");
  return JSON.parse(stdout);
}

async function expectCliFailure(home, args, pattern) {
  try {
    await runCli(home, ...args);
  } catch (error) {
    assert.match(`${error.message}\n${error.stderr ?? ""}`, pattern);
    return;
  }
  throw new Error(`Captain's Inbox command unexpectedly succeeded: ${args.join(" ")}`);
}

async function eventually(check, message) {
  for (let attempt = 0; attempt < 200; attempt += 1) {
    if (await check()) return;
    await delay(10);
  }
  throw new Error(message);
}

async function makeHome(name, { enabled = true, lock = String(process.pid), secondmate = false } = {}) {
  const home = `${root}/${name}`;
  await mkdir(`${home}/config`, { recursive: true });
  await mkdir(`${home}/state`, { recursive: true });
  await writeFile(`${home}/state/.lock`, `${lock}\n`);
  if (enabled) await writeFile(`${home}/config/captain-inbox`, "on\n");
  if (secondmate) await writeFile(`${home}/.fm-secondmate-home`, "inbox-test\n");
  return home;
}

async function loadExtension(home, harness = "pi") {
  process.env.FM_HOME = home;
  process.env.FM_STATE_OVERRIDE = `${home}/state`;
  process.env.FM_CONFIG_OVERRIDE = `${home}/config`;
  process.env.FM_PI_HARNESS = harness;
  const handlers = new Map();
  const pi = {
    on(name, handler) {
      handlers.set(name, handler);
    },
  };
  const extension = await import(`${pathToFileURL(extensionPath).href}?case=${encodeURIComponent(home)}-${Date.now()}-${Math.random()}`);
  extension.default(pi);
  return { handlers, ctx: {
    mode: "tui",
    isIdle: () => true,
    sessionManager: { getSessionId: () => "captain-session" },
  } };
}

function assistant(content, timestamp, stopReason = "stop") {
  return {
    role: "assistant",
    content,
    stopReason,
    timestamp,
  };
}

function emit(runtime, event, payload) {
  runtime.handlers.get(event)?.(payload, runtime.ctx);
}

async function deliver(runtime, {
  source = "interactive",
  text = "Captain request",
  prompt = text,
  beforeAgentStart = true,
  message = assistant([{ type: "text", text: "Captain response" }], Date.parse("2026-08-01T00:00:00.000Z")),
} = {}) {
  emit(runtime, "input", { source, text });
  if (beforeAgentStart) emit(runtime, "before_agent_start", { prompt });
  emit(runtime, "message_end", { message });
  emit(runtime, "agent_settled", {});
}

function queueOperationalFollowUp(runtime, text) {
  // Pi emits input when sendUserMessage queues a follow-up while the agent is
  // streaming, but that queued continuation has no matching before_agent_start.
  emit(runtime, "input", { source: "extension", text });
}

const disabled = await makeHome("disabled", { enabled: false });
const disabledRuntime = await loadExtension(disabled);
await deliver(disabledRuntime);
await delay(50);
assert.equal(existsSync(`${disabled}/state/captain-inbox`), false, "opt-out created Inbox state");
await expectCliFailure(disabled, ["list"], /disabled/);

const home = await makeHome("primary");
const runtime = await loadExtension(home);
const firstTimestamp = Date.parse("2026-08-01T00:00:00.000Z");
const body = "<b>literal response text</b>\nNothing here is HTML.";
const first = assistant([{ type: "thinking", thinking: "private" }, { type: "text", text: body }], firstTimestamp);
await deliver(runtime, { message: first });
await eventually(async () => (await list(home)).messages.length === 1, "primary response was not captured");

let inbox = await list(home);
assert.equal(inbox.version, 1, "list did not expose the versioned consumer contract");
assert.equal(inbox.messages[0].body, body, "capture changed the plain response body");
assert.deepEqual(inbox.messages[0].source, { harness: "pi", session_id: "captain-session" }, "capture leaked or omitted source metadata");
assert.equal(inbox.messages[0].read, false, "new message was not unread");
assert.match(inbox.messages[0].id, /^ci_v1_[a-f0-9]{32}$/, "message ID was not stable contract syntax");
const firstId = inbox.messages[0].id;

const watcherRace = await makeHome("watcher-race");
const watcherRaceRuntime = await loadExtension(watcherRace);
const watcherRaceBody = "## Captain’s Call\nA watcher follow-up must not drop this completed response.";
const watcherInput = execFileSync(operationalInput, ["encode", "watcher"], {
  encoding: "utf8",
  input: "watcher notification after the completed response",
}).trimEnd();
const watcherRaceMessage = assistant([{ type: "thinking", thinking: "private" }, { type: "text", text: watcherRaceBody }], firstTimestamp + 1);
watcherRaceRuntime.ctx.isIdle = () => false;
emit(watcherRaceRuntime, "message_end", { message: watcherRaceMessage });
emit(watcherRaceRuntime, "input", { source: "extension", text: watcherInput });
emit(watcherRaceRuntime, "agent_settled", {});
await eventually(
  async () => (await list(watcherRace)).messages.length === 1,
  "a typed watcher follow-up dropped the completed Captain’s Call response",
);
assert.equal((await list(watcherRace)).messages[0].body, watcherRaceBody, "watcher-race capture changed the plain response body");
assert.equal((await list(watcherRace)).messages[0].read, false, "watcher-race capture was not unread");

const staleWatcher = await makeHome("stale-watcher");
const staleWatcherRuntime = await loadExtension(staleWatcher);
staleWatcherRuntime.ctx.isIdle = () => false;
emit(staleWatcherRuntime, "input", { source: "extension", text: watcherInput });
emit(staleWatcherRuntime, "message_end", { message: watcherRaceMessage });
emit(staleWatcherRuntime, "agent_settled", {});
await delay(50);
assert.equal((await list(staleWatcher)).messages.length, 0, "a stale watcher input captured a later non-idle response");

const unrelatedContinuation = await makeHome("unrelated-continuation");
const unrelatedRuntime = await loadExtension(unrelatedContinuation);
unrelatedRuntime.ctx.isIdle = () => false;
emit(unrelatedRuntime, "message_end", { message: watcherRaceMessage });
emit(unrelatedRuntime, "input", { source: "extension", text: "ordinary continuation" });
emit(unrelatedRuntime, "agent_settled", {});
await delay(50);
assert.equal((await list(unrelatedContinuation)).messages.length, 0, "an unrelated non-idle continuation captured a response");

await deliver(runtime, { message: first });
await delay(50);
assert.equal((await list(home)).messages.length, 1, "duplicate completed event created another message");

const queuedOperational = execFileSync(operationalInput, ["encode", "watcher"], {
  encoding: "utf8",
  input: "a watcher notification queued while Pi is streaming",
}).trimEnd();
const knowledgebaseOperational = execFileSync(operationalInput, ["encode", "watcher"], {
  encoding: "utf8",
  input: "Project Knowledgebase MVP ready",
}).trimEnd();
const dashboardOperational = execFileSync(operationalInput, ["encode", "watcher"], {
  encoding: "utf8",
  input: "dashboard update ready",
}).trimEnd();
const knowledgebaseResponse = "Captain, the Project Knowledgebase MVP is ready.";
const dashboardResponse = "Captain, the dashboard update is ready.";
const logResponse = "Captain, Captain’s Log test received after the dashboard update.";

// This is the exact poisoning sequence from the Pi extension API.
// An operational follow-up emits input while streaming and has no matching
// before_agent_start, so the old FIFO left a false eligibility entry behind.
// The later idle operational runs and fresh direct input each shifted that stale
// false entry and their finalized visible assistant messages were dropped.
queueOperationalFollowUp(runtime, queuedOperational);
await deliver(runtime, {
  source: "extension",
  text: knowledgebaseOperational,
  prompt: knowledgebaseOperational,
  message: assistant([{ type: "text", text: knowledgebaseResponse }], firstTimestamp + 5),
});
await deliver(runtime, {
  source: "extension",
  text: dashboardOperational,
  prompt: dashboardOperational,
  message: assistant([{ type: "text", text: dashboardResponse }], firstTimestamp + 6),
});
await deliver(runtime, {
  text: "captains log test",
  message: assistant([{ type: "text", text: logResponse }], firstTimestamp + 7),
});
await eventually(async () => (await list(home)).messages.length === 4, "operational or post-operational direct responses were not captured");
inbox = await list(home);
assert.deepEqual(
  inbox.messages.map((message) => message.body).sort(),
  [body, knowledgebaseResponse, dashboardResponse, logResponse].sort(),
  "the direct and operational finalized assistant responses did not reach the dashboard",
);

const ignoredCases = [
  {
    message: { role: "user", content: "Captain prompt", timestamp: firstTimestamp + 8 },
  },
  {
    message: assistant([{ type: "thinking", thinking: "private only" }], firstTimestamp + 9),
  },
  {
    message: assistant([{ type: "text", text: "intermediate" }, { type: "toolCall", id: "tool", name: "read", arguments: {} }], firstTimestamp + 10, "toolUse"),
  },
  {
    source: "extension",
    text: "extension-only notification",
    message: { role: "custom", content: "extension-only notification", timestamp: firstTimestamp + 11 },
  },
  {
    source: "extension",
    text: queuedOperational,
    prompt: queuedOperational,
    message: assistant([{ type: "text", text: "Captain, shipshape." }], firstTimestamp + 12),
  },
  {
    message: assistant([{ type: "text", text: "Captain, shipshape." }], firstTimestamp + 13),
  },
];
for (const ignored of ignoredCases) await deliver(runtime, ignored);
await delay(50);
assert.equal((await list(home)).messages.length, 4, "filter captured a prompt, tool path, extension entry, or routine acknowledgement");

await runCli(home, "mark", firstId, "read");
inbox = await list(home);
assert.equal(inbox.messages.find((message) => message.id === firstId)?.read, true, "mark read did not persist independently");
await runCli(home, "mark", firstId, "unread");
assert.equal((await list(home)).messages.find((message) => message.id === firstId)?.read, false, "mark unread did not persist independently");
await expectCliFailure(home, ["list", "/tmp/unrelated"], /invalid/);

if (process.platform !== "win32") {
  for (const [path, expected] of [
    [`${home}/state/captain-inbox`, 0o700],
    [`${home}/state/captain-inbox/v1`, 0o700],
    [`${home}/state/captain-inbox/v1/messages.json`, 0o600],
    [`${home}/state/captain-inbox/v1/read-state.json`, 0o600],
  ]) {
    assert.equal((await lstat(path)).mode & 0o777, expected, `unexpected private mode for ${path}`);
  }
}

for (let index = 0; index < 100; index += 1) {
  const timestamp = firstTimestamp + 10_000 + index;
  const retainedBody = `retained-message-${index}`;
  await deliver(runtime, {
    text: `Captain request ${index}`,
    message: assistant([{ type: "text", text: retainedBody }], timestamp),
  });
  await eventually(
    async () => (await list(home)).messages.some((message) => message.body === retainedBody),
    `retention fixture ${index} was not captured`,
  );
}
inbox = await list(home);
assert.equal(inbox.messages.length, 100, "retention did not keep the conservative bounded default");
assert.equal(inbox.messages.some((message) => message.id === firstId), false, "retention kept the oldest record");
assert.equal(inbox.messages.some((message) => message.body === body), false, "retention retained a pruned response body");

const [singleRead, singleUnread, firstBulkRead, secondBulkRead] = inbox.messages;
await runCli(home, "mark", singleRead.id, "read");
const singleDelete = JSON.parse((await runCli(home, "delete", singleRead.id)).stdout);
assert.deepEqual(singleDelete, { version: 1, id: singleRead.id, deleted: true }, "read single-message delete returned an unstable result");
inbox = await list(home);
assert.equal(inbox.messages.some((message) => message.id === singleRead.id), false, "read single-message delete retained its message");

await expectCliFailure(home, ["delete", singleUnread.id], /not found or is not read/);
await expectCliFailure(home, ["delete", "ci_v1_00000000000000000000000000000000"], /not found or is not read/);
inbox = await list(home);
assert.equal(inbox.messages.some((message) => message.id === singleUnread.id), true, "unread single-message delete changed membership");
for (const args of [
  ["delete"],
  ["delete", "../outside"],
  ["delete", singleUnread.id, "extra"],
  ["delete", "read", "extra"],
]) {
  await expectCliFailure(home, args, /invalid/);
}

await runCli(home, "mark", firstBulkRead.id, "read");
await runCli(home, "mark", secondBulkRead.id, "read");
const deleteRead = JSON.parse((await runCli(home, "delete", "read")).stdout);
assert.deepEqual(deleteRead, { version: 1, read: true, deleted: 2 }, "delete read did not report its durable membership change");
inbox = await list(home);
assert.equal(inbox.messages.some((message) => message.id === firstBulkRead.id || message.id === secondBulkRead.id), false, "delete read retained a read message");
assert.equal(inbox.messages.every((message) => !message.read), true, "delete read changed an unread message state");
const deleteUnread = JSON.parse((await runCli(home, "delete", "unread")).stdout);
assert.equal(deleteUnread.version, 1, "delete unread changed the versioned response shape");
assert.equal(deleteUnread.read, false, "delete unread reported the wrong state selector");
assert.equal(deleteUnread.deleted, 97, "delete unread did not remove every currently unread message");
assert.deepEqual(await list(home), { version: 1, messages: [] }, "bulk deletion left a visible message behind");
assert.deepEqual(
  JSON.parse(await readFile(`${home}/state/captain-inbox/v1/read-state.json`, "utf8")).states,
  {},
  "bulk deletion left an orphaned read-state entry",
);
assert.deepEqual(
  JSON.parse((await runCli(home, "delete", "read")).stdout),
  { version: 1, read: true, deleted: 0 },
  "an explicit empty delete read did not remain a stable no-op",
);

if (process.platform !== "win32") {
  const unsafeDelete = await makeHome("unsafe-delete");
  const unsafeRuntime = await loadExtension(unsafeDelete);
  await deliver(unsafeRuntime, { message: assistant([{ type: "text", text: "unsafe delete fixture" }], firstTimestamp + 30_000) });
  await eventually(async () => (await list(unsafeDelete)).messages.length === 1, "unsafe delete fixture was not captured");
  const unsafeId = (await list(unsafeDelete)).messages[0].id;
  const external = `${unsafeDelete}/external-messages.json`;
  await writeFile(external, "external sentinel\n", { mode: 0o600 });
  await rm(`${unsafeDelete}/state/captain-inbox/v1/messages.json`);
  await symlink(external, `${unsafeDelete}/state/captain-inbox/v1/messages.json`);
  await expectCliFailure(unsafeDelete, ["delete", unsafeId], /unsafe/);
  assert.equal(await readFile(external, "utf8"), "external sentinel\n", "delete followed an unsafe storage link");
}

async function makeLockedInboxHome(name, { ownerContent, ageMs } = {}) {
  const home = await makeHome(name);
  const directory = `${home}/state/captain-inbox/v1`;
  await mkdir(directory, { recursive: true, mode: 0o700 });
  await chmod(`${home}/state/captain-inbox`, 0o700);
  await chmod(directory, 0o700);
  await writeFile(`${directory}/messages.json`, '{"version":1,"messages":[]}\n', { mode: 0o600 });
  await writeFile(`${directory}/read-state.json`, '{"version":1,"states":{}}\n', { mode: 0o600 });
  const lockDirectory = `${directory}/.lock`;
  await mkdir(lockDirectory, { mode: 0o700 });
  if (ownerContent !== undefined) {
    await writeFile(`${lockDirectory}/owner`, ownerContent, { mode: 0o600 });
  }
  if (ageMs !== undefined) {
    const backdated = new Date(Date.now() - ageMs);
    await utimes(lockDirectory, backdated, backdated);
  }
  return { home, lockDirectory };
}

async function exitedPid() {
  const child = spawn(process.execPath, ["-e", "process.exit(0)"]);
  return new Promise((resolveExit, reject) => {
    child.on("exit", () => resolveExit(child.pid));
    child.on("error", reject);
  });
}

const staleAgeMs = 10 * 60 * 1000;
const deadOwnerPid = await exitedPid();

const staleDead = await makeLockedInboxHome("stale-lock-dead-owner", {
  ownerContent: `dead-owner-token\n${deadOwnerPid}`,
  ageMs: staleAgeMs,
});
const staleListStart = Date.now();
const staleInbox = await list(staleDead.home);
const staleListElapsed = Date.now() - staleListStart;
assert.equal(staleInbox.messages.length, 0, "stale-lock reclaim returned unexpected messages");
assert.ok(staleListElapsed < 2000, `stale lock with a dead owner was not reclaimed promptly (took ${staleListElapsed}ms)`);
assert.equal(existsSync(staleDead.lockDirectory), false, "stale lock directory with a dead owner was left behind after reclaim");

const staleAliveOwnerContent = `alive-owner-token\n${process.pid}`;
const staleAlive = await makeLockedInboxHome("stale-lock-alive-owner", {
  ownerContent: staleAliveOwnerContent,
  ageMs: staleAgeMs,
});
await expectCliFailure(staleAlive.home, ["list"], /busy/);
assert.equal(await readFile(`${staleAlive.lockDirectory}/owner`, "utf8"), staleAliveOwnerContent, "a stale lock whose owner process is still alive was reclaimed");

const staleUnverifiable = await makeLockedInboxHome("stale-lock-no-owner-record", { ageMs: staleAgeMs });
await expectCliFailure(staleUnverifiable.home, ["list"], /busy/);
assert.equal(existsSync(staleUnverifiable.lockDirectory), true, "a stale lock with no verifiable owner record was reclaimed");

const liveLockOwnerContent = "a-live-holder-token\n1";
const liveLock = await makeLockedInboxHome("live-lock", { ownerContent: liveLockOwnerContent });
await expectCliFailure(liveLock.home, ["list"], /busy/);
assert.equal(await readFile(`${liveLock.lockDirectory}/owner`, "utf8"), liveLockOwnerContent, "a fresh (non-stale) lock was reclaimed or its ownership token was disturbed");

const malformed = await makeHome("malformed");
await mkdir(`${malformed}/state/captain-inbox/v1`, { recursive: true });
await chmod(`${malformed}/state/captain-inbox`, 0o700);
await chmod(`${malformed}/state/captain-inbox/v1`, 0o700);
const malformedContent = '{"version":1,"messages":[{}]}\n';
await writeFile(`${malformed}/state/captain-inbox/v1/messages.json`, malformedContent, { mode: 0o600 });
const malformedRuntime = await loadExtension(malformed);
await deliver(malformedRuntime, { message: assistant([{ type: "text", text: "must not overwrite malformed state" }], firstTimestamp) });
await delay(50);
await expectCliFailure(malformed, ["list"], /malformed/);
assert.equal(await readFile(`${malformed}/state/captain-inbox/v1/messages.json`, "utf8"), malformedContent, "malformed storage was overwritten");

const concurrent = await makeHome("concurrent");
const concurrentRuntime = await loadExtension(concurrent, "pi-signed");
for (const [index, text] of ["one", "two"].entries()) {
  await deliver(concurrentRuntime, {
    message: assistant([{ type: "text", text }], firstTimestamp + 20_000 + index),
  });
  await eventually(async () => (await list(concurrent)).messages.some((message) => message.body === text), "concurrent fixture was not captured");
}
const concurrentMessages = await list(concurrent);
const concurrentResults = await Promise.all([
  ...concurrentMessages.messages.map((message) => runCli(concurrent, "mark", message.id, "read")),
  ...Array.from({ length: 4 }, () => list(concurrent)),
]);
for (const snapshot of concurrentResults.slice(concurrentMessages.messages.length)) {
  assert.equal(snapshot.version, 1, "concurrent reader received an invalid snapshot");
  assert.equal(snapshot.messages.length, 2, "concurrent reader observed incomplete message membership");
}
const afterConcurrentMarks = await list(concurrent);
assert.equal(afterConcurrentMarks.messages.length, 2, "concurrent update changed message membership");
assert.equal(afterConcurrentMarks.messages.every((message) => message.read), true, "concurrent updates lost a read state");
assert.equal(afterConcurrentMarks.messages.every((message) => message.source.harness === "pi-signed"), true, "pi-signed source identity was not retained");
const [concurrentSingle, concurrentBulk] = afterConcurrentMarks.messages;
const concurrentDeleteRequests = await Promise.allSettled([
  runCli(concurrent, "delete", concurrentSingle.id),
  runCli(concurrent, "delete", "read"),
  ...Array.from({ length: 4 }, () => list(concurrent)),
]);
assert.equal(concurrentDeleteRequests[1].status, "fulfilled", "concurrent delete read did not complete");
for (const snapshot of concurrentDeleteRequests.slice(2)) {
  assert.equal(snapshot.status, "fulfilled", "concurrent delete made a list snapshot fail");
  assert.equal(snapshot.value.version, 1, "concurrent delete returned an invalid snapshot version");
  assert.ok(snapshot.value.messages.length >= 0 && snapshot.value.messages.length <= 2, "concurrent delete returned unstable membership");
}
assert.deepEqual(await list(concurrent), { version: 1, messages: [] }, "concurrent deletion retained an already-read message");
assert.deepEqual(
  JSON.parse(await readFile(`${concurrent}/state/captain-inbox/v1/read-state.json`, "utf8")).states,
  {},
  "concurrent deletion left an orphaned read-state entry",
);

// Confirmed deletion fixtures contain only generated IDs and synthetic bodies.
const store = await import(new URL("./lib/fm-captain-inbox-store.mjs", pathToFileURL(extensionPath)));
const fixtureId = (index) => `ci_v1_${index.toString(16).padStart(32, "0")}`;
const fixtureTime = "2026-08-01T00:00:00.000Z";
const fixtureRecord = (index) => ({
  id: fixtureId(index), completed_at: fixtureTime, body: `synthetic deletion record ${index}`,
  source: { harness: "pi", session_id: "synthetic-deletion-session" },
});
const storePaths = (home) => store.resolveCaptainInboxPaths({ home });

async function seedConfirmedHome(name, flags) {
  const home = await makeHome(`confirmed-${name}`);
  const paths = storePaths(home);
  await mkdir(paths.directory, { recursive: true, mode: 0o700 });
  await writeFile(paths.messages, `${JSON.stringify({ version: 1, messages: flags.map((_, index) => fixtureRecord(index + 1)) })}\n`, { mode: 0o600 });
  await writeFile(paths.readState, `${JSON.stringify({
    version: 1,
    states: Object.fromEntries(flags.flatMap((read, index) => read === undefined ? [] : [[fixtureId(index + 1), { read, updated_at: fixtureTime }]])),
  })}\n`, { mode: 0o600 });
  return home;
}

async function documentSnapshot(home) {
  const paths = storePaths(home);
  return Promise.all([paths.messages, paths.readState].map(async (path) => ({
    content: await readFile(path, "utf8"), inode: (await lstat(path)).ino,
  })));
}

async function rejectedWithoutWrites(home, args, pattern = /invalid|not found|changed read state/) {
  const before = await documentSnapshot(home);
  await assert.rejects(runCli(home, "delete-ids", ...args), (error) => {
    assert.match(error.stderr, pattern);
    assert.equal(error.stdout, "", "rejected confirmation emitted a success payload");
    assert.notEqual(error.code, 0);
    return true;
  });
  assert.deepEqual(await documentSnapshot(home), before, "rejected confirmation replaced or changed a document");
}

for (const scope of ["read", "unread"]) {
  const selectedRead = scope === "read";
  const confirmed = await seedConfirmedHome(`${scope}-races`, [selectedRead, !selectedRead, selectedRead]);
  const before = await list(confirmed);
  const selectedIds = [fixtureId(3), fixtureId(1)]; // Not storage or listing order.
  assert.equal(before.messages.filter((message) => message.read === selectedRead).length, 2);
  const arrival = await store.captureCaptainResponse(storePaths(confirmed), {
    harness: "pi-signed", sessionId: "synthetic-arrival", completedAt: "2026-08-01T00:00:01.000Z", body: "synthetic unseen arrival",
  });
  assert.equal(arrival.captured, true);
  if (selectedRead) await runCli(confirmed, "mark", arrival.id, "read");
  await runCli(confirmed, "mark", fixtureId(2), scope);
  const result = JSON.parse((await runCli(confirmed, "delete-ids", scope, ...selectedIds)).stdout);
  assert.deepEqual(result, { version: 1, scope, ids: selectedIds, deleted: 2 });
  const survivors = await list(confirmed);
  assert.deepEqual(survivors.messages.map((message) => message.id).sort(), [arrival.id, fixtureId(2)].sort(), "confirmation consumed arrival or moved-in record");
  assert.ok(survivors.messages.every((message) => message.read === selectedRead));
  const survivorStates = JSON.parse(await readFile(storePaths(confirmed).readState, "utf8")).states;
  assert.deepEqual(Object.keys(survivorStates).sort(), [arrival.id, fixtureId(2)].sort());
  await rejectedWithoutWrites(confirmed, [scope, ...selectedIds]); // Stale replay.

  const moved = await seedConfirmedHome(`${scope}-moved-out`, [selectedRead, selectedRead]);
  await runCli(moved, "mark", fixtureId(2), selectedRead ? "unread" : "read");
  await rejectedWithoutWrites(moved, [scope, fixtureId(1), fixtureId(2)]);
  await rejectedWithoutWrites(moved, [scope, fixtureId(1), fixtureId(99)]);

  for (const count of [1, 100]) {
    const boundary = await seedConfirmedHome(`${scope}-${count}`, Array(count).fill(selectedRead));
    const ids = Array.from({ length: count }, (_, index) => fixtureId(count - index));
    const result = JSON.parse((await runCli(boundary, "delete-ids", scope, ...ids)).stdout);
    assert.deepEqual(result, { version: 1, scope, ids, deleted: count });
    assert.deepEqual(await list(boundary), { version: 1, messages: [] });
    assert.deepEqual(JSON.parse(await readFile(storePaths(boundary).readState, "utf8")).states, {});
  }
}

const invalidConfirmed = await seedConfirmedHome("invalid", Array(101).fill(false));
for (const args of [
  [], ["unread"], ["read"], ["all", fixtureId(1)], ["READ", fixtureId(1)],
  ["true", fixtureId(1)], ["unread", fixtureId(1), fixtureId(1)],
  ["unread", fixtureId(1), "../outside"], ["unread", ""], ["unread", "ci_v1_deadbeef"],
  ["unread", `ci_v1_${"A".repeat(32)}`], ["unread", `${fixtureId(1)}\n`],
  ["unread", ...Array.from({ length: 101 }, (_, index) => fixtureId(index + 1))],
]) await rejectedWithoutWrites(invalidConfirmed, args);

const invalidPaths = storePaths(invalidConfirmed);
for (const [scope, ids] of [[true, [fixtureId(1)]], ["unread", null], ["unread", fixtureId(1)], ["unread", [1]], ["unread", [new String(fixtureId(1))]]]) {
  const before = await documentSnapshot(invalidConfirmed);
  await assert.rejects(store.deleteCaptainInboxMessagesByIds(invalidPaths, scope, ids), /invalid/);
  assert.deepEqual(await documentSnapshot(invalidConfirmed), before);
}

const implicitUnread = await seedConfirmedHome("implicit-unread", [undefined, undefined]);
assert.equal((await list(implicitUnread)).messages.every((message) => !message.read), true);
await runCli(implicitUnread, "delete-ids", "unread", fixtureId(1));
assert.deepEqual(JSON.parse(await readFile(storePaths(implicitUnread).readState, "utf8")).states, {}, "deletion marked an unrelated record");
assert.deepEqual((await list(implicitUnread)).messages.map((message) => message.id), [fixtureId(2)]);

const disabledConfirmed = await seedConfirmedHome("disabled", [false]);
await writeFile(`${disabledConfirmed}/config/captain-inbox`, "off\n");
await rejectedWithoutWrites(disabledConfirmed, ["unread", fixtureId(1)], /disabled/);
await expectCliFailure(disabled, ["delete-ids", "unread", fixtureId(1)], /disabled/);
assert.equal(existsSync(storePaths(disabled).root), false);

for (const document of ["messages", "readState"]) {
  for (const content of ["not JSON\n", '{"version":2}\n', document === "messages"
    ? `${JSON.stringify({ version: 1, messages: [fixtureRecord(1), fixtureRecord(1)] })}\n`
    : `${JSON.stringify({ version: 1, states: { [fixtureId(1)]: { read: "false", updated_at: fixtureTime } } })}\n`]) {
    const malformedConfirmed = await seedConfirmedHome(`malformed-${document}-${Math.random()}`, [false]);
    await writeFile(storePaths(malformedConfirmed)[document], content);
    await rejectedWithoutWrites(malformedConfirmed, ["unread", fixtureId(1)], /malformed/);
  }
  if (process.platform !== "win32") {
    for (const kind of ["symlink", "hardlink"]) {
      const unsafe = await seedConfirmedHome(`unsafe-${document}-${kind}`, [false]);
      const target = storePaths(unsafe)[document];
      const sentinel = `${unsafe}/synthetic-sentinel.json`;
      const original = await readFile(target, "utf8");
      await writeFile(sentinel, original, { mode: 0o600 });
      await rm(target);
      await (kind === "symlink" ? symlink : link)(sentinel, target);
      await rejectedWithoutWrites(unsafe, ["unread", fixtureId(1)], /unsafe/);
      assert.equal(await readFile(sentinel, "utf8"), original);
    }
  }
}

if (process.platform !== "win32") {
  for (const directory of ["root", "directory"]) {
    const unsafe = await seedConfirmedHome(`unsafe-${directory}`, [false]);
    const paths = storePaths(unsafe);
    const target = `${unsafe}/synthetic-external-store`;
    await rename(paths[directory], target);
    await symlink(target, paths[directory]);
    await rejectedWithoutWrites(unsafe, ["unread", fixtureId(1)], /unsafe/);
  }
}

const absentStore = await makeHome("confirmed-absent-store");
await expectCliFailure(absentStore, ["delete-ids", "unread", fixtureId(1)], /does not exist/);
assert.equal(existsSync(storePaths(absentStore).root), false);
const missingMessages = await seedConfirmedHome("missing-messages", [false]);
const missingPaths = storePaths(missingMessages);
await rm(missingPaths.messages);
const retainedState = await readFile(missingPaths.readState, "utf8");
await expectCliFailure(missingMessages, ["delete-ids", "unread", fixtureId(1)], /not found/);
assert.equal(existsSync(missingPaths.messages), false);
assert.equal(await readFile(missingPaths.readState, "utf8"), retainedState);

const overlapping = await seedConfirmedHome("overlapping-requests", [false, false, false]);
const overlappingResults = await Promise.allSettled([
  runCli(overlapping, "delete-ids", "unread", fixtureId(1), fixtureId(2)),
  runCli(overlapping, "delete-ids", "unread", fixtureId(2), fixtureId(3)),
  list(overlapping),
]);
assert.equal(overlappingResults.slice(0, 2).filter((result) => result.status === "fulfilled").length, 1);
const rejectedOverlap = overlappingResults.slice(0, 2).find((result) => result.status === "rejected");
assert.match(rejectedOverlap.reason.stderr, /not found/);
assert.equal(rejectedOverlap.reason.stdout, "");
const winningIds = JSON.parse(overlappingResults.find((result) => result.status === "fulfilled").value.stdout).ids;
assert.deepEqual((await list(overlapping)).messages.map((message) => message.id), [fixtureId(1), fixtureId(2), fixtureId(3)].filter((id) => !winningIds.includes(id)));
assert.equal(overlappingResults[2].status, "fulfilled");
assert.ok([1, 3].includes(overlappingResults[2].value.messages.length), "reader observed a partially validated deletion");

// Fault injection uses public Node filesystem boundaries, not implementation text.
// It is loaded only in the synthetic CLI child, never installed in a live home.
const faultModule = `${root}/confirmed-delete-faults.mjs`;
await writeFile(faultModule, `
import fs from "node:fs/promises";
import { syncBuiltinESMExports } from "node:module";
const originalWrite = fs.writeFile;
const originalMkdir = fs.mkdir;
const originalRename = fs.rename;
const originalChmod = fs.chmod;
const target = process.env.TEST_TARGET;
fs.mkdir = async (path, ...args) => {
  if (process.env.TEST_LOCK_ATTEMPT && path === process.env.TEST_LOCK) {
    await originalWrite(process.env.TEST_LOCK_ATTEMPT, "attempted");
  }
  return originalMkdir(path, ...args);
};
function injected() { return Object.assign(new Error("synthetic write failure"), { code: "EIO" }); }
fs.writeFile = async (path, ...args) => {
  if (process.env.TEST_FAULT === "write" && path.startsWith(target + ".")) throw injected();
  return originalWrite(path, ...args);
};
let replaced = false;
fs.rename = async (source, destination) => {
  if (destination === target && process.env.TEST_FAULT === "rename") throw injected();
  const result = await originalRename(source, destination);
  if (destination === target) replaced = true;
  return result;
};
fs.chmod = async (path, ...args) => {
  if (path === target && replaced && process.env.TEST_FAULT === "post-rename") throw injected();
  return originalChmod(path, ...args);
};
if (process.env.TEST_FAULT === "transport") {
  process.stdout.write = () => { throw Object.assign(new Error("synthetic transport failure"), { code: "EPIPE" }); };
}
syncBuiltinESMExports();
`);
function runInstrumented(home, extra, ...args) {
  return execFile(cli, args, { env: cliEnvironment(home, {
    NODE_OPTIONS: `--import=${pathToFileURL(faultModule).href}`, ...extra,
  }) });
}

for (const scope of ["read", "unread"]) {
  for (const moveOut of [false, true]) {
    const contended = await seedConfirmedHome(`${scope}-waiting-${moveOut}`, [scope === "read", scope !== "read"]);
    const paths = storePaths(contended);
    await mkdir(paths.lock, { mode: 0o700 });
    await writeFile(`${paths.lock}/owner`, `synthetic-owner\n${process.pid}`);
    const attempt = `${contended}/lock-attempt`;
    let settled = false;
    const pending = runInstrumented(contended, { TEST_LOCK: paths.lock, TEST_LOCK_ATTEMPT: attempt }, "delete-ids", scope, fixtureId(1))
      .then((value) => { settled = true; return { value }; }, (error) => { settled = true; return { error }; });
    await eventually(() => existsSync(attempt), "delete-ids did not contend for the existing lock");
    assert.equal(settled, false, "delete-ids ignored the held lock");
    // This synthetic lock owner finishes an arrival/state transition after the
    // deletion request starts, before releasing its lock to the actual CLI.
    await writeFile(paths.messages, `${JSON.stringify({ version: 1, messages: [fixtureRecord(1), fixtureRecord(2), fixtureRecord(3)] })}\n`);
    await writeFile(paths.readState, `${JSON.stringify({ version: 1, states: {
      [fixtureId(1)]: { read: moveOut ? scope !== "read" : scope === "read", updated_at: fixtureTime },
      [fixtureId(2)]: { read: scope === "read", updated_at: fixtureTime },
      [fixtureId(3)]: { read: scope === "read", updated_at: fixtureTime },
    } })}\n`);
    const beforeRelease = await documentSnapshot(contended);
    await rm(paths.lock, { recursive: true });
    const result = await pending;
    if (moveOut) {
      assert.ok(result.error, "a target moved out while waiting was deleted");
      assert.match(result.error.stderr, /changed read state/);
      assert.equal(result.error.stdout, "");
      assert.deepEqual(await documentSnapshot(contended), beforeRelease);
    } else {
      assert.equal(result.error, undefined);
      assert.deepEqual(JSON.parse(result.value.stdout), { version: 1, scope, ids: [fixtureId(1)], deleted: 1 });
      assert.deepEqual((await list(contended)).messages.map((message) => message.id).sort(), [fixtureId(2), fixtureId(3)]);
    }
  }
}

const busyConfirmed = await seedConfirmedHome("lock-timeout", [false]);
const busyPaths = storePaths(busyConfirmed);
await mkdir(busyPaths.lock);
const busyOwner = `synthetic-live-owner\n${process.pid}`;
await writeFile(`${busyPaths.lock}/owner`, busyOwner);
await rejectedWithoutWrites(busyConfirmed, ["unread", fixtureId(1)], /busy/);
assert.equal(await readFile(`${busyPaths.lock}/owner`, "utf8"), busyOwner);

// A caller cannot change its confirmed array while the public store awaits the lock.
const frozen = await seedConfirmedHome("frozen-input", [false, false]);
const frozenIds = [fixtureId(1)];
const frozenRequest = store.deleteCaptainInboxMessagesByIds(storePaths(frozen), "unread", frozenIds);
frozenIds[0] = fixtureId(2);
assert.deepEqual(await frozenRequest, { version: 1, scope: "unread", ids: [fixtureId(1)], deleted: 1 });
assert.deepEqual((await list(frozen)).messages.map((message) => message.id), [fixtureId(2)]);

for (const document of ["messages", "readState"]) {
  for (const fault of ["write", "rename", "post-rename"]) {
    const failure = await seedConfirmedHome(`failure-${document}-${fault}`, [false, false]);
    const paths = storePaths(failure);
    const before = await documentSnapshot(failure);
    await assert.rejects(runInstrumented(failure, { TEST_TARGET: paths[document], TEST_FAULT: fault }, "delete-ids", "unread", fixtureId(1)), (error) => {
      assert.match(error.stderr, /outcome may be partial; refresh/);
      assert.equal(error.stdout, "", "write failure claimed a successful deletion");
      return true;
    });
    const after = await documentSnapshot(failure);
    const messagesReplaced = document === "readState" || fault === "post-rename";
    if (messagesReplaced) {
      assert.deepEqual((await list(failure)).messages.map((message) => message.id), [fixtureId(2)]);
    } else assert.deepEqual(after[0], before[0]);
    if (document === "readState" && fault === "post-rename") {
      assert.deepEqual(Object.keys(JSON.parse(after[1].content).states), [fixtureId(2)]);
    } else assert.deepEqual(after[1], before[1], "failure falsely rolled back or changed read state");
    assert.equal(existsSync(paths.lock), false, "failed write leaked the lock");
    assert.equal((await readdir(paths.directory)).some((name) => name.endsWith(".tmp")), false, "failed write leaked a temporary record");
  }
}

const transportFailure = await seedConfirmedHome("transport-failure", [false, false]);
await assert.rejects(runInstrumented(transportFailure, { TEST_FAULT: "transport" }, "delete-ids", "unread", fixtureId(1)), (error) => {
  assert.match(error.stderr, /synthetic transport failure/);
  assert.equal(error.stdout, "");
  return true;
});
assert.deepEqual((await list(transportFailure)).messages.map((message) => message.id), [fixtureId(2)], "transport test did not exercise committed deletion");
await rejectedWithoutWrites(transportFailure, ["unread", fixtureId(1)]);

const worker = await makeHome("worker", { lock: "1" });
const workerRuntime = await loadExtension(worker);
await deliver(workerRuntime);
await delay(50);
assert.equal(existsSync(`${worker}/state/captain-inbox`), false, "non-primary session captured worker output");

const secondmate = await makeHome("secondmate", { secondmate: true });
const secondmateRuntime = await loadExtension(secondmate);
await deliver(secondmateRuntime);
await delay(50);
assert.equal(existsSync(`${secondmate}/state/captain-inbox`), false, "secondmate session captured output");
JS
)
status=$?
[ "$status" -eq 0 ] || fail "Captain's Inbox contract failed: $out"
[ -z "$out" ] || fail "Captain's Inbox contract printed output: $out"
pass "Captain's Inbox is opt-in, filters only completed primary Pi responses, preserves private consumer records, and supports legacy and confirmed-ID serialized deletion"
