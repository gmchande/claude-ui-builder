---
name: claude-ui-builder
description: Delegate frontend UI/DX implementation or UI review to Claude Code from Codex, using PRDs, vertical-slice issues, domain docs, and browser verification. Use when design/frontend work should be handed to Claude while Codex stays responsible for planning, integration, and technical review.
---

# Claude UI Builder

Use this skill when Codex should act as the technical lead and ask Claude Code to implement or evaluate a frontend/UI slice. It is designed to fit after the Matt Pocock skill flow: `/grill-with-docs` clarifies language and decisions, `/to-prd` creates the PRD, `/to-issues` creates vertical-slice issues, then this skill gives Claude one constrained UI/DX slice to build or review.

The helper runs Claude Code with `claude-opus-4-8` and `xhigh` effort by default. For supervised UI building, prefer the visible Zellij path (`--runner zellij`) so the user can watch and interrupt Claude directly. The Zellij runner expects Zellij 0.44+. The default `batch` runner still produces a parsed Markdown handoff for unattended runs. Builder mode grants edit tools and real shell access; use it only in trusted repos, preferably on a branch or isolated worktree. Evaluator mode is read-only-ish, but `Bash` is still shell access.

## Quick Start

From the repo root:

```sh
/Users/gaurav/.agents/skills/claude-ui-builder/scripts/claude_ui_builder.rb \
  --prd .scratch/feature-slug/PRD.md \
  --issue .scratch/feature-slug/issues/01-ui-slice.md \
  --intent "Implement the selected UI slice" \
  --runner zellij \
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

Prepare the prompt for a manually opened visible Claude terminal:

```sh
/Users/gaurav/.agents/skills/claude-ui-builder/scripts/claude_ui_builder.rb \
  --issue .scratch/feature-slug/issues/01-ui-slice.md \
  --runner prompt \
  --copy-prompt
```

Send the task into an already-open Zellij pane running Claude:

```sh
/Users/gaurav/.agents/skills/claude-ui-builder/scripts/claude_ui_builder.rb \
  --issue .scratch/feature-slug/issues/01-ui-slice.md \
  --runner zellij \
  --zellij-session story-claude \
  --zellij-pane-id terminal_3
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
3. Run builder mode. For work the user may want to steer, use `--runner zellij`; attach to the printed Zellij session and let Claude inspect the component system, implement, run checks, start the app when possible, and verify desktop/mobile/browser behavior.
4. If Claude is running visibly, let the user interrupt or correct it in the terminal. Codex should inspect the diff after Claude stops or when the user asks, not over-police the live run.
5. Read Claude's handoff or terminal summary. Verify its claims against the real diff, commands, and screenshots.
6. For subjective or high-stakes UI work, run evaluator mode as a separate pass.
7. Use Codex for final technical integration, test review, and follow-up issue creation.

## Matt Pocock Skill Fit

- PRDs and issues are source-of-truth inputs, not optional decoration.
- `--prd` and `--issue` are for repos configured with the local markdown issue tracker. Use `--gh-prd` and `--gh-issue` when the source material lives in GitHub Issues.
- Use the project glossary from `CONTEXT.md` and respect ADRs in `docs/adr/`.
- Keep work as one tracer-bullet slice: demoable, verifiable, and scoped to the issue acceptance criteria.
- If the issue is missing product/design decisions, Claude should report a blocker or suggest a HITL follow-up instead of inventing broad scope.

## Useful Options

```sh
CLAUDE_UI_EFFORT=max scripts/claude_ui_builder.rb --issue .scratch/x/issues/01.md
CLAUDE_UI_MODEL=claude-sonnet-4-6 scripts/claude_ui_builder.rb --issue .scratch/x/issues/01.md
scripts/claude_ui_builder.rb --output .scratch/x/ui-builder/01-handoff.md --issue .scratch/x/issues/01.md
scripts/claude_ui_builder.rb --runner zellij --zellij-session feature-ui --issue .scratch/x/issues/01.md
scripts/claude_ui_builder.rb --runner prompt --copy-prompt --issue .scratch/x/issues/01.md
scripts/claude_ui_builder.rb --timeout 1800 --max-turns 20 --issue .scratch/x/issues/01.md
scripts/claude_ui_builder.rb --gh-prd 123 --gh-issue 124 --intent "Implement the issue"
```

`--runner batch` uses `--output-format json` internally so the wrapper can parse Claude Code's final result and errors reliably. The human-facing output is still Markdown. `--runner zellij` and `--runner prompt` are live-supervision modes; they do not auto-write the final handoff to `--output`.
