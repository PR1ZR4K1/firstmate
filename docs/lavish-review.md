# Lavish review architecture

Audience: maintainer architecture.

The normative review procedure lives in [`.agents/skills/lavish-review/SKILL.md`](../.agents/skills/lavish-review/SKILL.md).
This document records component ownership and extension boundaries without copying that procedure.
Current empirical evidence lives in [`verification/lavish-review.md`](verification/lavish-review.md).

## Ownership graph

The `lavish-review` skill owns semantic routing, captain-facing review lifecycle, privacy review, feedback interpretation, and the handoff to established authority owners.
The installed `lavish-axi --help`, `lavish-axi design`, and matching playbooks own volatile editor flags and artifact mechanics.
`bin/fm-lavish-review.sh` exposes the closed normalized chat-versus-Lavish recommendation table, prepares or validates one private local artifact path shape, and owns the only home-scoped runtime envelope for Firstmate review-lifecycle commands.
`bin/fm-procevent-lavish.sh` owns the Lavish-specific blocking poll, source identity, DOM-before-prompt normalization, sequence-keyed reply receipts, ambiguous-delivery recovery, response classification, and registration stop verdict.
`bin/fm-procevent.sh` owns process isolation, one machine-wide owner, durable capture before notification, re-announcement until handled, and interruption recovery.
The `process-event-sources` skill owns callback handling, while `decision-hold-lifecycle` and `bin/fm-decision-hold.sh` remain the only unresolved-decision policy and mechanism.
`bin/fm-brief.sh` owns the generated worker boundary that permits requested artifact preparation but reserves captain communication, polling, sharing, findings, and authority decisions to firstmate.

## Private artifact boundary

The path commands accept the active physical `FM_HOME` or a physical Git worktree root whose exact review file is ignored and untracked.
Firstmate authors only under its home, while an explicitly instructed worker may use its own disposable Git worktree; this keeps the helper reusable without relaxing Firstmate's read-only project boundary.
Preparation creates only owner-accessible `.lavish/<slug>/` directories and never creates or rewrites HTML, so it imposes no generic design system and preserves sibling relative assets.
Preparation and pre-arm validation reject symlinked or multiply linked files, special files, invalid slugs, noncanonical paths, tracked files, and every existing tree file that an index-aware Git check does not report ignored.
These checks close negated-ignore and hardlink paths that a constant probe or regular-file test cannot detect.

## Private runtime envelope

Every Firstmate review-lifecycle CLI invocation passes through `bin/fm-lavish-review.sh run`.
The command resolves the physical home, enforces an owner-only `state/lavish-axi/` tree under umask `077`, derives one deterministic home-specific port, and replaces ambient Lavish configuration with loopback bind and link hosts, a closed allowed-host set, and telemetry disabled.
It starts the installed CLI with a clean environment that carries no ambient publication token and refuses CLI port and export-output overrides, so help, design, playbooks, open, poll, end, stop, and default beside-source export address one consistent server identity.
It validates every lifecycle artifact through the same private path boundary, allows only the installed local review and guidance command set, and refuses external `share`, global `setup`, direct `server`, and unknown future subcommands entirely.
The policy skill still owns whether a local lifecycle action is allowed; the runtime envelope supplies confinement rather than authority.

## One-result poll registrations

A published `lavish-axi poll` destructively consumes queued feedback before returning it.
The generic runner already captures returned output durably before publishing its notification, but it cannot remove that source-side loss window.
The Lavish adapter therefore registers only the no-timeout blocking poll and continues to make no lossless-delivery claim.

Every completed Lavish feedback result makes its current process-event registration terminal, even when the browser session remains open.
The result stays durably available for handler work, while automatic source reconciliation has no registration to restart.
After revision and durable reconciliation, the handler explicitly arms a new registration keyed to the exact result sequence.
Under the same source lock, the adapter stores the owner-only reply receipt, publishes the continuation registration, and durably acknowledges that result.
A crash before the acknowledgement leaves the result eligible for re-announcement, while a registration published in the same partial operation waits locally for an idempotent repeat arm rather than invoking Lavish.
The registration contains only the adapter's artifact, source id, and sequence command, so retryable argv never contains the reply.
The first released runner atomically renames the ready receipt to claimed before invoking Lavish.
A restart that finds claimed or delivered state emits one terminal `ambiguous` result without invoking Lavish again; inspected recovery then either records the reply delivered and registers a plain poll, or records it not delivered and releases exactly that receipt for one retry.
The matching ambiguity may remain unacknowledged during recovery and is acknowledged only after recovery succeeds, so a crash before that point preserves re-announcement.
This one-result shape prevents both a plain replacement poll racing ahead of the response and an interrupted continuation reposting the response.
Ended, missing, and ambiguous results retire, while waiting or malformed results remain registered for ordinary recovery.

Lavish 0.1.50 serializes the potentially large DOM snapshot before prompts.
The adapter keeps a DOM value up to 16384 encoded bytes and replaces a larger value with a byte-count marker before the generic runner sees it.
All session, prompt, decision, answer, artifact-failure, and next-step fields remain intact under the adapter's 16 MiB normalized-result request, while an explicit generic output-limit override still wins.

## Decision and worker boundaries

A Lavish answer is presentation-channel input until firstmate validates its explicit decision key and scope.
The existing decision lifecycle records and routes accepted intent, so HTML session state never becomes a second decision database.
Generated ship and scout briefs let workers author private source material when asked but forbid them from opening, polling, sharing, addressing the captain, answering their own findings, or treating feedback as approval.
A marked secondmate request returns a local path when accessible or rebuildable report material when it is not, leaving the presenting home as the one captain-facing review owner.

## Harness and runtime axes

Lavish review polling is a home-level process-event source rather than a worker endpoint operation.
The supported primary harnesses - Claude, Codex, OpenCode, Pi, pi-signed, and Grok - receive its ordinary `check` notification through their existing supervision protocols, so no Lavish-specific harness hook or wait primitive exists.
Kimi and Muse are worker surfaces for this feature and receive the same generated prepare-only boundary; Muse remains inapplicable as a primary because Firstmate already refuses that role.
The runtime backends - tmux, Herdr, Zellij, Orca, and cmux - supply worker endpoints but do not own the home-level Lavish process or callback.
Orca and cmux secondmate restrictions are therefore unrelated, and Codex App remains inapplicable because it is not a selectable runtime backend.

A new primary harness needs only the ordinary process-event `check` wake guarantee before this feature can use it.
A new runtime backend needs no Lavish adapter change unless it alters the home-level notification contract rather than only worker endpoints.
