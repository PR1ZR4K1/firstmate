# Lavish review verification

Audience: maintainer verification.

This record holds current version-scoped evidence for Firstmate's private Lavish review integration.
[`../lavish-review.md`](../lavish-review.md) owns component architecture, `.agents/skills/lavish-review/SKILL.md` owns the runtime procedure, and the installed tool owns volatile editor mechanics.

Verification date: 2026-08-13.
Verification host: macOS Darwin 25.6.0 arm64.

## Installed and upstream evidence

The installed binary was inspected without reinstalling or upgrading it.

```text
$ lavish-axi --version
0.1.50

$ command -v lavish-axi
~/.local/bin/lavish-axi

$ realpath ~/.local/bin/lavish-axi
~/.local/lib/node_modules/lavish-axi/dist/cli.mjs
```

The installed `package.json` identifies `lavish-axi` 0.1.50, Node 22 or newer, the `dist/cli.mjs` binary, the MIT license, and `git+https://github.com/kunchenguid/lavish-axi.git` as its repository.
The installed README documents the recommended standalone skill path through `npx skills add kunchenguid/lavish-axi --skill lavish`, the global hook path through `npm install -g lavish-axi` followed by `lavish-axi setup hooks`, and source installation through pnpm.
Firstmate requires an installed compatible CLI in its universal toolchain, so `bin/fm-bootstrap.sh` retains the global npm plus hook setup method rather than adding an on-demand npx dependency.
No account, plugin registration, hook repair, package installation, or package update was performed during this verification.

The upstream repository was inspected with `gh-axi` at exact default-branch revision [`e902be0f641d6cece2177c40a7551b9f8c8305ae`](https://github.com/kunchenguid/lavish-axi/commit/e902be0f641d6cece2177c40a7551b9f8c8305ae).
That revision's `package.json` is still version 0.1.50 and its license endpoint reports SPDX `MIT`.
The published 0.1.50 release tag resolves to commit `899747a3d7e03d1e3b8061fc3869331e514c2917` and was published on 2026-08-11.
Release 0.1.49 added realpath confinement for artifact assets, while 0.1.50 hardened feedback-submission boundaries.
Firstmate's compatibility floor is therefore 0.1.50, and the already-installed 0.1.50 needed no change.

## Current help and playbooks

The following current installed surfaces were opened before implementation.
The same help, design, playbook, and lifecycle argv now run through `bin/fm-lavish-review.sh run`, which supplies the private runtime envelope without changing the installed command grammar.

```text
lavish-axi --help
lavish-axi poll --help
lavish-axi end --help
lavish-axi export --help
lavish-axi share --help
lavish-axi stop --help
lavish-axi setup --help
lavish-axi design
lavish-axi playbook diagram
lavish-axi playbook table
lavish-axi playbook comparison
lavish-axi playbook plan
lavish-axi playbook code
lavish-axi playbook input
lavish-axi playbook slides
```

The help confirms local `.lavish/` placement by default, relative local assets, no-timeout long polling, retained queued feedback after interruption, `--agent-reply` continuation, user-ended reopen refusal, explicit `--reopen`, local export behavior, and third-party `ht-ml.app` publication through `share`.
The playbook router exposes `diagram`, `table`, `comparison`, `plan`, `code`, `input`, and `slides`, and requires every matching playbook to be opened for a combined artifact.
The `input` playbook requires selected state to remain local until an explicit per-question submission queues one final answer.
The design help requires explicit user design direction first, then the subject project's real design system, and only then the Lavish fallback.

## Isolated live smoke

The live exercises used only synthetic content, an isolated Firstmate home, its runtime-envelope-selected loopback port, an isolated process-event claim root, and for the responsive interaction exercise a named `chrome-devtools-axi` session backed by an already-cached local `chrome-devtools-mcp` executable.
No real captain operated the artifact, and the artifact loaded no remote scripts, fonts, images, styles, or other network resources.
No export, share, account, credential, token, purchase, telemetry, or external publishing action ran.
The correction smoke re-opened the installed 0.1.50 CLI through the final runtime envelope, submitted synthetic feedback over that loopback server, and exercised the final sequence-keyed reply continuation end to end.

The representative artifact combined the `comparison` and mandatory `input` playbooks with two radio options, an optional rationale, a separate queue action, a separate send action, visible focus, semantic landmarks, responsive stacking, explicit colors, and no hover-only control.

| Exercise | Observed result |
| --- | --- |
| private path | `bin/fm-lavish-review.sh prepare` produced an ignored `.lavish/live-runtime/review.html` path, and `check` accepted that real single-link file |
| runtime confinement | `bin/fm-lavish-review.sh run` selected `127.0.0.1`, one deterministic home port, mode `0700` runtime state, and mode `0600` state and server-log files |
| open | `bin/fm-lavish-review.sh run <artifact> --no-open` returned `status: opened` and one loopback session URL |
| resume | the same enveloped command returned the same session URL and remained opened |
| approved callback | `bin/fm-procevent-lavish.sh arm` plus `bin/fm-procevent.sh reconcile` reported one live `lavish` source without blocking the conversational command |
| structured input | browser automation selected Route A, filled a synthetic rationale, queued exactly one keyed `smoke-route` answer, and sent it |
| feedback intake | the process-event inbox captured sequence 1 at mode-private state with `status: feedback`, tag `choice`, key `smoke-route`, answer `A`, and the synthetic rationale |
| pre-handler stop | `bin/fm-procevent.sh list` reported no source after sequence 1, proving ordinary feedback retired before a plain poll could restart |
| revision and reply | explicit re-arm named `--after-sequence 1` and reported that sequence handled in the same operation; the installed server recorded the agent reply, the second result retained final feedback, and the private delivered receipt was mode `0600` |
| responsive and accessible surface | the browser accessibility snapshot exposed headings, region, form, radios, labeled textarea, buttons, and live status at a compact viewport, while the outer page reported equal client and scroll widths |
| end behavior | synthetic `Send & End` feedback arrived once as sequence 2 with `session_ended: true` and `ended_by: user`, then left no registered source |
| ended-session refusal | a later plain no-open command returned `status: user-ended` and did not reopen the browser session |
| cleanup | the named browser bridge stopped, the isolated Lavish server stopped, and process-event home preflight reported ready with no live source |

The smoke used the approved callback and runtime envelope rather than direct `lavish-axi poll`, shell backgrounding, or an untracked detached wait.
The synthetic input result was acknowledged only after its revision was applied, and the final ended result was acknowledged without re-arming.

## Machine-enforced coverage

`tests/fm-lavish-review.test.sh` exercises the closed chat-versus-Lavish routing set, unknown-shape refusal, private default path, design-neutral preparation, no preparation side effect, exact index-aware ignore and tracked-file rejection, path traversal, symlink and hardlink rejection, the loopback owner-only clean runtime envelope, telemetry opt-out, stable server identity, lifecycle artifact validation, export-output refusal, external-share refusal, and generated worker authority boundaries.
`tests/fm-procevent.test.sh` exercises exact internal poll argv, one owner, interruption recovery, durable capture and re-announcement, one-result ordinary feedback, sequence-keyed private reply receipts, no raw reply argv, automatic-replay refusal, both inspected ambiguity recovery outcomes, oversized DOM removal before complete prompt and decision capture, final feedback retirement, ended-session behavior, no-share invocation, and adapter path safety.
`tests/fm-decision-hold-lifecycle.test.sh` exercises durable unresolved-decision inventory, visual-review completion, post-review survival, exact answer files, dependent-work routing, idempotent resolution, and no parallel decision database.
`tests/fm-brief.test.sh` and `tests/fm-ask-user-authority.test.sh` exercise generated worker escalation and no-mistakes ask-user ownership.
`bin/fm-doc-audience-check.sh` enforces the new skill, architecture page, and verification page classifications and their owner pointer.

The focused commands are:

```text
bash tests/fm-lavish-review.test.sh
bash tests/fm-procevent.test.sh
bash tests/fm-decision-hold-lifecycle.test.sh
bash tests/fm-brief.test.sh
bash tests/fm-ask-user-authority.test.sh
bash tests/fm-bootstrap.test.sh
bin/fm-doc-audience-check.sh
bin/fm-lint.sh
git diff --check
```

The current focused summaries were:

```text
ok - Lavish routing keeps simple questions and routine notices in chat and selects rich review shapes explicitly
ok - Lavish review preparation is private, local, design-neutral, and free of open, poll, share, or network side effects
ok - Git index, ignore, symlink, and hardlink guards confine the complete Lavish review tree
ok - Lavish lifecycle commands use one owner-only loopback runtime with telemetry disabled
ok - generated worker instructions allow private artifact preparation without captain communication, polling, sharing, self-answer, or authority expansion
ok - ordinary feedback stops before handler work and resumes through a sequence-keyed reply receipt
ok - a registration-before-acknowledgement cut remains re-announceable and resumes once
ok - oversized DOM data is bounded before complete prompt and decision capture
ok - an interrupted claimed reply surfaces ambiguity and never replays automatically
ok - inspected not-delivered recovery releases exactly one explicit reply retry
all procevent tests passed
ok - ended visual review and its submitted answer use the same durable decision lifecycle
ok - fm-brief.sh: investigation and visual-review completions load the shared decision policy
ok - primary workers and secondmates receive the authority rule through generated instructions
ok - bootstrap enforces lavish-axi minimum version
fm-doc-audience-check: ok surfaces=73 local_links=252
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)
git diff --check: no output
```

## Harness and runtime review

The integration surfaces were inspected in `.agents/skills/harness-adapters/SKILL.md`, every `docs/supervision-protocols/*.md` primary protocol, `bin/fm-watch.sh`, `bin/fm-procevent.sh`, and the runtime-backend section of `docs/architecture.md`.

| Axis | Applicability and evidence |
| --- | --- |
| Claude primary | applicable through the existing ordinary process-event `check` wake and Stop-owned supervision continuation |
| Codex primary | applicable through the same `check` wake and bounded foreground watcher checkpoint |
| OpenCode primary | applicable through the same `check` wake and TUI plugin continuation |
| Pi primary | applicable through the same `check` wake and tracked watcher extension |
| pi-signed primary | applicable through the identical Pi protocol with its distinct launch identity |
| Grok primary | applicable through the same `check` wake and tracked background-notify cycle |
| Kimi worker | preparation boundary applies through generated worker instructions, while no supported Kimi primary protocol is claimed |
| Muse worker | preparation boundary applies, while primary use is inapplicable because Muse remains crew-and-scout-only |
| tmux, Herdr, Zellij, Orca, cmux | worker endpoints receive the same generated instructions, while the home-level process-event source and `check` notification do not call a backend adapter |
| Codex App | inapplicable because it remains a documented non-selectable host surface rather than a runtime backend |

No harness-specific background feature was added for Lavish.
The generic process-event source is the one callback for every applicable primary and the existing watcher protocol remains the one supervision owner.
