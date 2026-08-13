# Lavish review architecture

Audience: maintainer architecture.

The normative review procedure lives in [`.agents/skills/lavish-review/SKILL.md`](../.agents/skills/lavish-review/SKILL.md).
This document records component ownership and extension boundaries without copying that procedure.
Current empirical evidence lives in [`verification/lavish-review.md`](verification/lavish-review.md).

## Ownership graph

The `lavish-review` skill owns semantic routing, captain-facing review lifecycle, privacy review, feedback interpretation, and the handoff to established authority owners.
The installed `lavish-axi --help`, `lavish-axi design`, and matching playbooks own volatile editor flags and artifact mechanics.
`bin/fm-lavish-review.sh` is deliberately narrower than an editor wrapper: it exposes the closed normalized chat-versus-Lavish recommendation table and prepares or validates one private local artifact path shape.
`bin/fm-procevent-lavish.sh` owns only the Lavish-specific blocking poll argv, source identity, response classification, and registration stop verdict.
`bin/fm-procevent.sh` owns process isolation, one machine-wide owner, durable capture before notification, re-announcement until handled, and interruption recovery.
The `process-event-sources` skill owns callback handling, while `decision-hold-lifecycle` and `bin/fm-decision-hold.sh` remain the only unresolved-decision policy and mechanism.
`bin/fm-brief.sh` owns the generated worker boundary that permits requested artifact preparation but reserves captain communication, polling, sharing, findings, and authority decisions to firstmate.

## Private artifact boundary

The helper accepts the active physical `FM_HOME` or a physical Git worktree root that already ignores `.lavish/`.
Firstmate authors only under its home, while an explicitly instructed worker may use its own disposable Git worktree; this keeps the helper reusable without relaxing Firstmate's read-only project boundary.
It creates only owner-accessible `.lavish/<slug>/` directories and never creates or rewrites HTML, so it imposes no generic design system and preserves sibling relative assets.
The pre-arm check accepts only a real `<allowed-root>/.lavish/<slug>/review.html` file and rejects symlinked roots, review directories, artifacts or sibling assets, special files, invalid slugs, and paths outside the allowed root.
The helper has no open, poll, export, publish, share, account, credential, or network command.
This boundary keeps direct `lavish-axi` authoring available while making Firstmate's private-by-default placement deterministic and testable.

## One-result poll registrations

A published `lavish-axi poll` destructively consumes queued feedback before returning it.
The generic runner already captures returned output durably before publishing its notification, but it cannot remove that source-side loss window.
The Lavish adapter therefore registers only the no-timeout blocking poll and continues to make no lossless-delivery claim.

Every completed Lavish feedback result makes its current process-event registration terminal, even when the browser session remains open.
The result stays durably available for handler work, while automatic source reconciliation has no registration to restart.
After revision and durable reconciliation, the handler explicitly arms a new registration with the installed tool's `--agent-reply` form.
This one-result shape prevents a plain replacement poll from racing ahead of the response that re-enables browser feedback, and it never kills a valid blocking poll.
Ended and missing sessions also retire, while waiting or malformed results remain registered for ordinary recovery.

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
