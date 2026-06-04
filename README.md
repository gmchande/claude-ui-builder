# claude-ui-builder

A Codex skill that delegates frontend UI/DX implementation or skeptical UI evaluation to Claude Code while keeping Codex responsible for planning, integration, and technical review.

It is built to complement the Matt Pocock skill flow:

1. `/grill-with-docs` clarifies domain language and decisions.
2. `/to-prd` creates a PRD in the configured issue tracker.
3. `/to-issues` breaks the PRD into tracer-bullet vertical slices.
4. `claude-ui-builder` gives Claude one constrained UI/DX slice to build or evaluate.
5. Codex verifies the diff and decides what to integrate.

## What it does

- Reads PRD and issue markdown files when provided.
- Fetches PRD and issue bodies from GitHub Issues with `gh` when requested.
- Bundles local skill configuration from `docs/agents/`.
- Bundles `CONTEXT.md`, `CONTEXT-MAP.md`, and ADRs when present.
- Includes git status, current tracked diff, and untracked text files.
- Runs Claude Code with `claude-opus-4-8` and `xhigh` effort by default.
- Supports builder mode with edit tools.
- Supports evaluator mode without edit tools.
- Optionally enables Claude Code Chrome integration with `--chrome`.
- Writes Claude's Markdown handoff to stdout and optionally to `--output`.

## Requirements

- Ruby
- Git
- Claude Code CLI on `PATH`
- Optional: GitHub CLI on `PATH` for `--gh-prd` and `--gh-issue`

For browser-based UI verification, Claude Code Chrome integration must be installed with a visible Chrome window and connected extension. Headless/remote environments may not support `--chrome`; the prompt requires Claude to say browser evidence was not captured rather than inventing screenshots.

## Usage

From a repo:

```sh
/Users/gaurav/.agents/skills/claude-ui-builder/scripts/claude_ui_builder.rb \
  --prd .scratch/feature-slug/PRD.md \
  --issue .scratch/feature-slug/issues/01-ui-slice.md \
  --intent "Implement the selected UI slice" \
  --chrome
```

Those `.scratch/...` paths are for repos configured with the local markdown issue tracker. If `/to-prd` and `/to-issues` published to GitHub Issues, use issue numbers or URLs instead:

```sh
/Users/gaurav/.agents/skills/claude-ui-builder/scripts/claude_ui_builder.rb \
  --gh-prd 123 \
  --gh-issue 124 \
  --intent "Implement the selected UI slice" \
  --chrome
```

Dry-run the prompt:

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
  --chrome
```

Save the handoff:

```sh
/Users/gaurav/.agents/skills/claude-ui-builder/scripts/claude_ui_builder.rb \
  --issue .scratch/feature-slug/issues/01-ui-slice.md \
  --output .scratch/feature-slug/ui-builder/01-handoff.md
```

Use a different effort or model:

```sh
CLAUDE_UI_EFFORT=max /Users/gaurav/.agents/skills/claude-ui-builder/scripts/claude_ui_builder.rb --issue .scratch/x/issues/01.md
CLAUDE_UI_MODEL=claude-sonnet-4-6 /Users/gaurav/.agents/skills/claude-ui-builder/scripts/claude_ui_builder.rb --issue .scratch/x/issues/01.md
```

## Why JSON output?

The wrapper passes `--output-format json` to Claude Code so it can parse the final result event, detect `is_error`, preserve the real error message, and write only the final Markdown handoff for the user. It is not asking Claude to write JSON prose.

The trailing `\` you often see in examples is just shell line continuation.

## Safety

Builder mode grants edit tools and `Bash`. That is real local access, not a sandbox. Run it only in trusted repos, preferably on a branch or isolated worktree. The prompt tells Claude not to revert unrelated changes, but Codex should still review the final diff before merging.

Evaluator mode removes edit tools, but still grants `Bash` so Claude can run tests, inspect the app, and use browser tooling.
