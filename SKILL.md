---
name: claude-ui-builder
description: Delegate frontend UI/DX implementation or UI review to Claude Code from Codex, using PRDs, vertical-slice issues, domain docs, and browser verification. Use when design/frontend work should be handed to Claude while Codex stays responsible for planning, integration, and technical review.
---

# Claude UI Builder

Use this skill when Codex should act as the technical lead and ask Claude Code to implement or evaluate a frontend/UI slice. Use it for substantial UI/DX work where a delegated model pass is worth the visible Zellij session overhead; for tiny copy, CSS, or component tweaks, Codex should usually make the change directly. It is designed to fit after the Matt Pocock skill flow: `/grill-with-docs` clarifies language and decisions, `/to-prd` creates the PRD, `/to-issues` creates vertical-slice issues, then this skill gives Claude one constrained UI/DX slice to build or review.

The helper always launches Claude Code in a new, one-off visible Zellij session with `--permission-mode bypassPermissions` and opens a Ghostty tab attached to that session before sending the task. If the requested session name already exists, the helper exits instead of reusing it; remove old handles with `zellij delete-session <name>` or `zellij kill-session <name>` if still active. If Claude shows its bypass-permissions startup responsibility screen, the helper selects `Yes, I accept` before sending the task. If the Claude prompt never becomes visibly ready, the helper exits instead of pasting into an unknown screen. There is no hidden batch mode, prompt-copy mode, approval-gated mode, or fallback transport. This is intentional: the user can attach, watch stdout, interrupt, and correct Claude directly while Codex remains responsible for planning, integration, and final review.

Requirements: Ruby, Git, Claude Code CLI on `PATH`, Zellij 0.44+ on `PATH`, Ghostty.app installed and registered with macOS, and `ZELLIJ_SOCKET_DIR` set in shell startup to a short stable path such as `/tmp/zellij`. Builder mode grants edit tools and shell access without per-command permission prompts; use it only in trusted repos, preferably on a branch or isolated worktree. Evaluator mode is read-only-ish, but `Bash` is still shell access.

## Quick Start

From the repo root:

```sh
/Users/gaurav/.agents/skills/claude-ui-builder/scripts/claude_ui_builder.rb \
  --prd .scratch/feature-slug/PRD.md \
  --issue .scratch/feature-slug/issues/01-ui-slice.md \
  --intent "Implement the selected UI slice" \
  --zellij-session feature-ui \
  --chrome
```

For repos whose Matt Pocock skills publish to GitHub Issues instead of local markdown, pass issue numbers or URLs:

```sh
/Users/gaurav/.agents/skills/claude-ui-builder/scripts/claude_ui_builder.rb \
  --gh-prd 123 \
  --gh-issue 124 \
  --intent "Implement the selected UI slice" \
  --chrome
```

Inspect the prompt bundle without calling Claude:

```sh
/Users/gaurav/.agents/skills/claude-ui-builder/scripts/claude_ui_builder.rb \
  --issue .scratch/feature-slug/issues/01-ui-slice.md \
  --dry-run
```

Run a skeptical UI evaluator after the builder changes files:

```sh
/Users/gaurav/.agents/skills/claude-ui-builder/scripts/claude_ui_builder.rb \
  --mode evaluator \
  --prd .scratch/feature-slug/PRD.md \
  --issue .scratch/feature-slug/issues/01-ui-slice.md \
  --chrome
```

## Workflow

1. Confirm the repo has already run `/setup-matt-pocock-skills`, or that `docs/agents/issue-tracker.md`, `docs/agents/domain.md`, and `docs/agents/triage-labels.md` exist.
2. Prefer passing a PRD or issue path. The selected issue is the scope boundary; Claude should not expand the feature beyond that vertical slice.
3. Run builder mode with a fresh Zellij session name. The helper prints the `zellij attach <session>` command and sends the task into that visible Claude pane.
4. Let Claude run in Zellij. The user is the live observer and can interrupt or correct it in the terminal. Codex should not continuously poll the pane.
5. Read Claude's handoff or terminal summary. Verify its claims against the real diff, commands, and screenshots.
6. For subjective or high-stakes UI work, run evaluator mode as a separate pass.
7. Use Codex for final technical integration, test review, and follow-up issue creation.

Observation policy: after launching Claude visibly, Codex should let the user be the live observer and should not continuously poll the pane. When Codex needs completion, do the first marker check after 2-3 minutes, then poll the printed done marker cheaply and read the handoff file once it exists. Inspect the pane only on explicit user request, a bounded checkpoint, or to verify a concrete finding. Prefer `zellij list-sessions --short` for liveness and viewport-only `dump-screen` with small output caps. Avoid repeated `dump-screen --full` polling; use full transcript dumps only as diagnostics, preferably written to a temp file.

## Matt Pocock Skill Fit

- PRDs and issues are source-of-truth inputs, not optional decoration.
- `--prd` and `--issue` are for repos configured with the local markdown issue tracker. Use `--gh-prd` and `--gh-issue` when the source material lives in GitHub Issues.
- Use the project glossary from `CONTEXT.md` and respect ADRs in `docs/adr/`.
- Keep work as one tracer-bullet slice: demoable, verifiable, and scoped to the issue acceptance criteria.
- If the issue is missing product/design decisions, Claude should report a blocker or suggest a HITL follow-up instead of inventing broad scope.

## Useful Options

```sh
CLAUDE_UI_EFFORT=xhigh scripts/claude_ui_builder.rb --issue .scratch/x/issues/01.md
CLAUDE_UI_MODEL=claude-sonnet-4-6 scripts/claude_ui_builder.rb --issue .scratch/x/issues/01.md
scripts/claude_ui_builder.rb --zellij-session feature-ui --issue .scratch/x/issues/01.md
scripts/claude_ui_builder.rb --gh-prd 123 --gh-issue 124 --intent "Implement the issue"
```

The helper writes the assembled prompt bundle, system prompt, handoff path, and done marker under `/tmp/claude-ui-builder/...`, starts Claude in a pane inside the one-off Zellij session, opens Ghostty attached to the session, and bracket-pastes the task. Zellij must use a short, stable socket namespace such as `/tmp/zellij` in shell startup so plain commands like `zellij attach feature-ui` work from new terminal tabs. If `ZELLIJ_SOCKET_DIR` is missing, the helper exits instead of creating a hidden alternate namespace. It does not parse a final handoff automatically; Codex should read the handoff file after the done marker appears and verify the actual diff before accepting it.
