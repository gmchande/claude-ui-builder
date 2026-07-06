# claude-ui-builder

A Codex skill for delegating substantial frontend UI/DX implementation or skeptical UI evaluation to Claude Code while keeping Codex responsible for planning, integration, and technical review. For tiny copy, CSS, or component tweaks, Codex should usually make the change directly.

The workflow is deliberately singular: the helper always launches Claude in a new, one-off visible Zellij session with `--permission-mode bypassPermissions`. There is no hidden batch runner, prompt-copy runner, parsed handoff runner, approval-gated runner, or automatic fallback transport.

## What it does

- Reads PRD and issue markdown files when provided.
- Fetches PRD and issue bodies from GitHub Issues with `gh` when requested.
- Bundles local skill configuration from `docs/agents/`.
- Bundles `CONTEXT.md`, `CONTEXT-MAP.md`, and ADRs when present.
- Includes git status, current tracked diff, and untracked text files.
- Starts Claude Code in a visible Zellij pane with `claude-opus-4-8`, max effort, and `bypassPermissions` by default, with streamed output formatted for the terminal.
- Supports builder mode with edit tools.
- Supports evaluator mode without edit tools.
- Optionally enables Claude Code Chrome integration with `--chrome`.
- Opens a Ghostty tab attached to the one-off Zellij session and prints the exact attach, inspect, and interrupt commands.

## Requirements

- Ruby
- Git
- Claude Code CLI on `PATH`
- Zellij 0.44+ on `PATH`
- Ghostty.app installed and registered with macOS
- `ZELLIJ_SOCKET_DIR` set in shell startup to a short stable path such as `/tmp/zellij`
- Optional: GitHub CLI on `PATH` for `--gh-prd` and `--gh-issue`

For browser-based UI verification, Claude Code Chrome integration must be installed with a visible Chrome window and connected extension. Headless/remote environments may not support `--chrome`; the prompt requires Claude to say browser evidence was not captured rather than inventing screenshots.

## Usage

From a repo:

```sh
SKILL=/path/to/claude-ui-builder
$SKILL/scripts/claude_ui_builder.rb \
  --prd .scratch/feature-slug/PRD.md \
  --issue .scratch/feature-slug/issues/01-ui-slice.md \
  --intent "Implement the selected UI slice" \
  --zellij-session feature-ui \
  --chrome
```

Those `.scratch/...` paths are for repos configured with the local markdown issue tracker. If `/to-prd` and `/to-issues` published to GitHub Issues, use issue numbers or URLs instead:

```sh
$SKILL/scripts/claude_ui_builder.rb \
  --gh-prd 123 \
  --gh-issue 124 \
  --intent "Implement the selected UI slice" \
  --zellij-session feature-ui \
  --chrome
```

Dry-run the prompt without launching Claude:

```sh
$SKILL/scripts/claude_ui_builder.rb \
  --issue .scratch/feature-slug/issues/01-ui-slice.md \
  --dry-run
```

Run a separate evaluator after implementation:

```sh
$SKILL/scripts/claude_ui_builder.rb \
  --mode evaluator \
  --prd .scratch/feature-slug/PRD.md \
  --issue .scratch/feature-slug/issues/01-ui-slice.md \
  --zellij-session feature-ui-review \
  --chrome
```

Use a different effort or model:

```sh
CLAUDE_UI_EFFORT=high $SKILL/scripts/claude_ui_builder.rb --issue .scratch/x/issues/01.md
CLAUDE_UI_MODEL=claude-sonnet-4-6 $SKILL/scripts/claude_ui_builder.rb --issue .scratch/x/issues/01.md
```

Replace `/path/to/claude-ui-builder` with the loaded skill directory.

## Runtime Behavior

The helper creates a new named Zellij session, starts a `Claude UI Builder` pane in the repo root with `claude -p < prompt_bundle`, streams Claude's JSON events through a readable terminal formatter, opens a Ghostty tab attached to the session, and prints commands like:

```sh
zellij attach feature-ui
zellij --session feature-ui action dump-screen --pane-id terminal_0
zellij --session feature-ui action dump-screen --pane-id terminal_0 --full --path /tmp/claude-ui-builder-feature-ui.screen.txt
zellij --session feature-ui action send-keys --pane-id terminal_0 "Ctrl c"
```

Codex should let Claude run visibly. The user can attach to the Zellij session and interrupt the run; they should not need to press Enter for every command Claude wants to run. Codex should not continuously poll the pane. When completion matters, do the first done-marker check after 2-3 minutes, then poll the marker/handoff paths every 60-90 seconds. If the marker is absent, keep polling until about 15 minutes have passed. Do not rerun solely because `dump-screen`, `list-panes`, or `list-sessions` reports no active session; check the done marker and handoff paths directly first. If the session is repeatedly confirmed gone/exited and the marker remains absent after a brief direct recheck, treat the run as failed or ambiguous rather than polling forever. If the marker is non-zero but the handoff exists, inspect the handoff before discarding the run. Prefer viewport-only `dump-screen` with small output caps; reserve `dump-screen --full` for diagnostics, preferably with `--path`.

The helper writes the assembled prompt bundle, system prompt, handoff file, and done marker under `/tmp/claude-ui-builder/...` so the exact task and final handoff remain inspectable. Zellij must use a short, stable socket namespace such as `/tmp/zellij` in shell startup so plain commands like `zellij attach feature-ui` work from new terminal tabs. If `ZELLIJ_SOCKET_DIR` is missing, the helper exits instead of creating a hidden alternate namespace.

If the requested Zellij session name already exists, the helper exits. Session names are one-off handles for a single Claude run; use a fresh name for each run, or remove the old handle with `zellij delete-session <name>` or `zellij kill-session <name>` if it is still active.

Because the task is supplied through the prompt bundle on stdin, the helper does not wait for an interactive Claude prompt or paste into the terminal input buffer. Live visibility comes from the formatted stream rather than the Claude TUI.

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
