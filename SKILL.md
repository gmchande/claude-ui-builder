---
name: claude-ui-builder
description: Claude Code UI delegation for substantial frontend UI/DX implementation or evaluation. Launches a visible Zellij builder/evaluator pass while Codex stays responsible for scope, integration, verification, and final judgment.
---

# Claude UI Builder

Delegate substantial frontend UI/DX implementation or evaluation to Claude Code
while Codex stays responsible for scope, integration, verification, and final
judgment. For tiny copy, CSS, or component tweaks, make the change directly.

Claude is another agent, not the authority. It may miss main-session context,
overbuild, or make unsupported claims. Verify its output against the real repo.

## Run

Confirm the target repo root. Do not run from a parent directory containing
unrelated repos. From the target repo root, run the helper from this skill
directory:

```sh
SKILL=/path/to/claude-ui-builder
$SKILL/scripts/claude_ui_builder.rb \
  --prd .scratch/x/PRD.md \
  --issue .scratch/x/issues/01-ui.md \
  --intent "Implement the selected UI slice" \
  --zellij-session feature-ui \
  --chrome
```

Replace `/path/to/claude-ui-builder` with the loaded skill directory. Useful
options: `--gh-prd NUMBER_OR_URL`, `--gh-issue NUMBER_OR_URL`, `--mode
evaluator`, `--dry-run`, `--zellij-session NAME`, and `--chrome`.

Prerequisites: Ruby, Git, Claude Code, Zellij 0.44+, Ghostty, and
`ZELLIJ_SOCKET_DIR` set to a short stable path such as `/tmp/zellij`.

Prefer passing a PRD or issue. The selected issue is the scope boundary; Claude
should not expand the feature beyond that vertical slice. Use `--intent` when
the plan lives in conversation. Session names are one-off; choose a fresh
`--zellij-session` name for each run.

## Scope And Safety

This skill fits best after `/grill-with-docs`, `/to-prd`, and `/to-issues`, but
any clear PRD, issue, or narrow task intent is enough. Use `--mode evaluator`
as a separate pass for subjective or high-stakes UI work.

The helper carries the detailed Claude builder/evaluator prompt. Codex must
verify Claude's output against the real diff, commands, screenshots, browser
state, acceptance criteria, project constraints, and UI quality.

Builder mode grants edit tools and `Bash` under `bypassPermissions`; this is
real local access, not a sandbox. Evaluator mode removes edit tools, but still
grants `Bash`. Use either mode only in trusted repos, preferably on a branch or
isolated worktree.

## Observe

Let the user watch the visible Zellij/Ghostty session. First check the done
marker after 2-3 minutes, then poll the marker/handoff paths every 60-90
seconds. The marker holds the run exit status: `0` means read the handoff;
non-zero usually means the run failed or was interrupted, but check whether the
handoff exists before discarding it.

If the marker is absent, the run is not complete yet; keep polling until about
15 minutes have passed. If pane/session inspection says the session is gone or
exited, check the marker and handoff directly before diagnosing or rerunning. If
the session is repeatedly gone/exited and the marker is still absent after a
brief recheck, treat the run as failed or ambiguous. Prefer viewport-only
`dump-screen`; avoid repeated full transcript dumps.

## Post-Claude Checkpoint

After Claude returns, do not make additional Codex edits, stage, commit, push,
or declare the work accepted until you verify and summarize the actual output.
Judge the work against the PRD/issue/intent, project constraints, correctness,
and UI quality.
After verification and integration are done, delete the Zellij session; skipping this accumulates dead sessions.

Use this shape:

```md
Claude did / found:
- [short factual summary]

I verified:
- [diff, commands, screenshots, browser checks, or gaps]

I agree with:
- [what is solid and why]

I reject or want to adjust:
- [overbuild, unsupported claim, design mismatch, bug, or unnecessary work]

Integration plan:
- [smallest Codex follow-up edits, checks, or no-op]

Waiting for your go-ahead before I edit or commit.
```

For evaluator mode, verify and classify findings as accepted, rejected, or
deferred, then wait for approval before implementing fixes. After approval, use
Codex for final integration, test review, and follow-up issue creation.
