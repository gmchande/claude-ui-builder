---
name: claude-ui-builder
description: Claude Code UI delegation for substantial frontend UI/DX implementation or evaluation. Launches a visible Zellij builder/evaluator pass while Codex stays responsible for scope, integration, verification, and final judgment.
---

# Claude UI Builder

Codex acts as technical lead and asks Claude Code to implement or evaluate a
frontend/UI slice. Use it for substantial UI/DX work where a delegated model
pass is worth the visible Zellij session overhead; for tiny copy, CSS, or
component tweaks, Codex should usually make the change directly. It is designed
to fit after the Matt Pocock skill flow:
`/grill-with-docs` clarifies language and decisions, `/to-prd` creates the PRD,
`/to-issues` creates vertical-slice issues, then this skill gives Claude one
constrained UI/DX slice to build or review.

Claude is another agent, not the authority. It may miss main-session context, overbuild, or make unsupported claims. Codex remains responsible for scope, integration, verification, and final judgment.

The helper always launches Claude Code in a new, one-off visible Zellij session with `--permission-mode bypassPermissions`, passes the assembled task through a prompt file with `claude -p`, streams Claude's JSON events through a readable terminal formatter, and opens a Ghostty tab attached to that session. If the requested session name already exists, the helper exits instead of reusing it; remove old handles with `zellij delete-session <name>` or `zellij kill-session <name>` if still active. There is no hidden non-visible batch mode, prompt-copy mode, approval-gated mode, paste transport, or fallback transport. This is intentional: the user can attach, watch stdout, and interrupt while Codex remains responsible for planning, integration, and final review.

Requirements: Ruby, Git, Claude Code CLI on `PATH`, Zellij 0.44+ on `PATH`, Ghostty.app installed and registered with macOS, and `ZELLIJ_SOCKET_DIR` set in shell startup to a short stable path such as `/tmp/zellij`. Builder mode grants edit tools and shell access without per-command permission prompts; use it only in trusted repos, preferably on a branch or isolated worktree. Evaluator mode is read-only-ish, but `Bash` is still shell access.

## Commands

From the repo root:

```sh
SKILL=/Users/gaurav/.agents/skills/claude-ui-builder
$SKILL/scripts/claude_ui_builder.rb --prd .scratch/x/PRD.md --issue .scratch/x/issues/01-ui.md --intent "Implement the selected UI slice" --zellij-session feature-ui --chrome
$SKILL/scripts/claude_ui_builder.rb --gh-prd 123 --gh-issue 124 --intent "Implement the issue" --chrome
$SKILL/scripts/claude_ui_builder.rb --issue .scratch/x/issues/01-ui.md --dry-run
$SKILL/scripts/claude_ui_builder.rb --mode evaluator --prd .scratch/x/PRD.md --issue .scratch/x/issues/01-ui.md --chrome
```

## Workflow

1. Confirm the repo has already run `/setup-matt-pocock-skills`, or that `docs/agents/issue-tracker.md`, `docs/agents/domain.md`, and `docs/agents/triage-labels.md` exist.
2. Prefer passing a PRD or issue path. The selected issue is the scope boundary; Claude should not expand the feature beyond that vertical slice.
3. Run builder mode with a fresh Zellij session name. The helper prints the `zellij attach <session>` command and starts the visible Claude pane with the task from the prompt file.
4. Let Claude run in Zellij. The user is the live observer and can interrupt the run in the terminal. Codex should not continuously poll the pane.
5. Read Claude's handoff or terminal summary. Verify its claims against the real diff, commands, screenshots, and browser state.
6. For subjective or high-stakes UI work, run evaluator mode as a separate pass.
7. Send the post-Claude checkpoint below before further Codex edits, staging, commits, or acceptance.
8. After approval, use Codex for final technical integration, test review, and follow-up issue creation.

Observation policy: after launching Claude visibly, Codex should let the user be the live observer and should not continuously poll the pane. The pane should show formatted Claude status, text, tool calls, and tool output while the run is active. When Codex needs completion, do the first marker check after 2-3 minutes, then poll the printed done marker cheaply and read the handoff file once it exists. The marker holds Claude's exit code: `0` means read the handoff; non-zero means the run failed (crash, auth, interrupt), so inspect the pane and do not treat the handoff as complete. Inspect the pane only on explicit user request, a bounded checkpoint, or to verify a concrete finding. Prefer `zellij list-sessions --short` for liveness and viewport-only `dump-screen` with small output caps. Avoid repeated `dump-screen --full` polling; use full transcript dumps only as diagnostics, preferably written to a temp file.

## Post-Claude Checkpoint

Builder mode intentionally allows Claude to edit files. This gate applies after Claude returns: Codex must not make additional edits, stage, commit, push, or declare the work accepted until it verifies the actual output and summarizes it for the user.

Review the actual diff, commands, screenshots, and browser state, not Claude's handoff as a source of truth. Judge the work against, in order:

1. The PRD, issue, or task intent: whether Claude stayed inside the selected vertical slice and acceptance criteria.
2. Project constraints: AGENTS.md/CLAUDE.md rules, stack, existing components, styling tokens, package-manager conventions, CONTEXT.md vocabulary, and ADRs.
3. Correctness and UI quality: broken flows, runtime errors, accessibility, responsive behavior, visual fit, unsupported claims, overbuild, and unnecessary repo changes.

An unannounced or unjustified deviation from the issue/PRD is a finding even when the UI appears polished.

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

For evaluator mode, treat findings like review findings: verify each one, classify accepted/rejected/deferred, and wait for approval before implementing fixes.

## Matt Pocock Skill Fit

- PRDs and issues are source-of-truth inputs, not optional decoration.
- `--prd` and `--issue` are for repos configured with the local markdown issue tracker. Use `--gh-prd` and `--gh-issue` when the source material lives in GitHub Issues.
- Use the project glossary from `CONTEXT.md` and respect ADRs in `docs/adr/`.
- Keep work as one tracer-bullet slice: demoable, verifiable, and scoped to the issue acceptance criteria.
- If the issue is missing product/design decisions, Claude should report a blocker or suggest a HITL follow-up instead of inventing broad scope.

## Useful Options

```sh
CLAUDE_UI_EFFORT=high $SKILL/scripts/claude_ui_builder.rb --issue .scratch/x/issues/01.md
CLAUDE_UI_MODEL=claude-sonnet-4-6 $SKILL/scripts/claude_ui_builder.rb --issue .scratch/x/issues/01.md
```

The helper writes the assembled prompt bundle, system prompt, handoff path, and done marker under `/tmp/claude-ui-builder/...`, starts Claude in a pane inside the one-off Zellij session with `claude -p < prompt_bundle`, streams the run through a readable formatter, and opens Ghostty attached to the session. Zellij must use a short, stable socket namespace such as `/tmp/zellij` in shell startup so plain commands like `zellij attach feature-ui` work from new terminal tabs. If `ZELLIJ_SOCKET_DIR` is missing, the helper exits instead of creating a hidden alternate namespace. It does not parse a final handoff automatically; Codex should read the handoff file after the done marker appears and verify the actual diff before accepting it.
