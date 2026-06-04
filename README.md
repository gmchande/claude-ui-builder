# claude-ui-builder

A Codex skill for delegating frontend UI/DX implementation or skeptical UI evaluation to Claude Code while keeping Codex responsible for planning, integration, and technical review.

The workflow is deliberately singular: the helper always launches Claude in a visible Zellij session with `--permission-mode bypassPermissions`. There is no hidden batch runner, prompt-copy runner, parsed handoff runner, approval-gated runner, or automatic fallback transport.

## What it does

- Reads PRD and issue markdown files when provided.
- Fetches PRD and issue bodies from GitHub Issues with `gh` when requested.
- Bundles local skill configuration from `docs/agents/`.
- Bundles `CONTEXT.md`, `CONTEXT-MAP.md`, and ADRs when present.
- Includes git status, current tracked diff, and untracked text files.
- Starts Claude Code in a visible Zellij pane with `claude-opus-4-8`, `xhigh` effort, and `bypassPermissions` by default.
- Supports builder mode with edit tools.
- Supports evaluator mode without edit tools.
- Optionally enables Claude Code Chrome integration with `--chrome`.
- Prints the exact attach, inspect, and interrupt commands for the Zellij session.

## Requirements

- Ruby
- Git
- Claude Code CLI on `PATH`
- Zellij 0.44+ on `PATH`
- Optional: GitHub CLI on `PATH` for `--gh-prd` and `--gh-issue`

For browser-based UI verification, Claude Code Chrome integration must be installed with a visible Chrome window and connected extension. Headless/remote environments may not support `--chrome`; the prompt requires Claude to say browser evidence was not captured rather than inventing screenshots.

## Usage

From a repo:

```sh
/Users/gaurav/.agents/skills/claude-ui-builder/scripts/claude_ui_builder.rb \
  --prd .scratch/feature-slug/PRD.md \
  --issue .scratch/feature-slug/issues/01-ui-slice.md \
  --intent "Implement the selected UI slice" \
  --zellij-session feature-ui \
  --chrome
```

Those `.scratch/...` paths are for repos configured with the local markdown issue tracker. If `/to-prd` and `/to-issues` published to GitHub Issues, use issue numbers or URLs instead:

```sh
/Users/gaurav/.agents/skills/claude-ui-builder/scripts/claude_ui_builder.rb \
  --gh-prd 123 \
  --gh-issue 124 \
  --intent "Implement the selected UI slice" \
  --zellij-session feature-ui \
  --chrome
```

Dry-run the prompt without launching Claude:

```sh
/Users/gaurav/.agents/skills/claude-ui-builder/scripts/claude_ui_builder.rb \
  --issue .scratch/feature-slug/issues/01-ui-slice.md \
  --dry-run
```

Run a separate evaluator after implementation:

```sh
/Users/gaurav/.agents/skills/claude-ui-builder/scripts/claude_ui_builder.rb \
  --mode evaluator \
  --prd .scratch/feature-slug/PRD.md \
  --issue .scratch/feature-slug/issues/01-ui-slice.md \
  --zellij-session feature-ui-review \
  --chrome
```

Use a different effort or model:

```sh
CLAUDE_UI_EFFORT=max /Users/gaurav/.agents/skills/claude-ui-builder/scripts/claude_ui_builder.rb --issue .scratch/x/issues/01.md
CLAUDE_UI_MODEL=claude-sonnet-4-6 /Users/gaurav/.agents/skills/claude-ui-builder/scripts/claude_ui_builder.rb --issue .scratch/x/issues/01.md
```

## Runtime Behavior

The helper creates or reuses the named Zellij session, starts a new `Claude UI Builder` pane in the repo root, waits briefly for the Claude prompt, pastes the assembled task, presses Enter, and prints commands like:

```sh
zellij attach feature-ui
zellij --session feature-ui action dump-screen --pane-id terminal_0 --full
zellij --session feature-ui action send-keys --pane-id terminal_0 Esc
zellij --session feature-ui action send-keys --pane-id terminal_0 "Ctrl c"
```

Codex should let Claude run visibly. The user can attach to the Zellij session, interrupt, and correct Claude directly; they should not need to press Enter for every command Claude wants to run. Codex should inspect the actual diff and terminal output after Claude stops or when the user asks.

The helper writes the assembled prompt bundle and system prompt to `/tmp/claude-ui-builder/...` so the exact task remains inspectable.

## Matt Pocock Skill Fit

- PRDs and issues are source-of-truth inputs, not optional decoration.
- `--prd` and `--issue` are for repos configured with the local markdown issue tracker.
- `--gh-prd` and `--gh-issue` are for repos whose source material lives in GitHub Issues.
- Use the project glossary from `CONTEXT.md` and respect ADRs in `docs/adr/`.
- Keep work as one tracer-bullet slice: demoable, verifiable, and scoped to the issue acceptance criteria.
- If the issue is missing product/design decisions, Claude should report a blocker or suggest a HITL follow-up instead of inventing broad scope.

## Safety

Builder mode grants edit tools and `Bash` without per-command permission prompts. That is real local access, not a sandbox. Run it only in trusted repos, preferably on a branch or isolated worktree. The prompt tells Claude not to revert unrelated changes, but Codex should still review the final diff before merging.

Evaluator mode removes edit tools, but still grants `Bash` so Claude can run tests, inspect the app, and use browser tooling.
