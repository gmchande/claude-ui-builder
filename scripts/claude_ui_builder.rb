#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "optparse"
require "shellwords"
require "tmpdir"

MAX_TEXT_BYTES = 200_000
MAX_DOC_BUNDLE_BYTES = 500_000
CLAUDE_DEFAULT_MODEL = ENV.fetch("CLAUDE_UI_MODEL", "claude-opus-4-8")
CLAUDE_DEFAULT_EFFORT = ENV.fetch("CLAUDE_UI_EFFORT", "xhigh")
CLAUDE_PERMISSION_MODE = "bypassPermissions"
CLAUDE_BYPASS_WARNING_MARKERS = ["Bypass", "Permissions", "Yes", "accept"].freeze
CLAUDE_READY_MARKERS = ["Claude Code", "❯"].freeze
BUILDER_TOOLS = ENV.fetch(
  "CLAUDE_UI_BUILDER_TOOLS",
  "Read,Grep,Glob,Bash,Edit,MultiEdit,Write,WebSearch,WebFetch"
)
EVALUATOR_TOOLS = ENV.fetch(
  "CLAUDE_UI_EVALUATOR_TOOLS",
  "Read,Grep,Glob,Bash,WebSearch,WebFetch"
)

options = {
  chrome: false,
  dry_run: false,
  effort: CLAUDE_DEFAULT_EFFORT,
  gh_issue: nil,
  gh_prd: nil,
  intent: nil,
  issue: nil,
  mode: "builder",
  model: CLAUDE_DEFAULT_MODEL,
  prd: nil,
  zellij_session: nil
}

parser = OptionParser.new do |opts|
  opts.banner = "Usage: claude_ui_builder.rb [options]"

  opts.on("--mode MODE", "builder or evaluator (default: builder)") { |value| options[:mode] = value }
  opts.on("--prd PATH", "PRD markdown file, usually .scratch/<feature>/PRD.md") { |value| options[:prd] = value }
  opts.on("--issue PATH", "Issue markdown file for the vertical UI slice") { |value| options[:issue] = value }
  opts.on("--gh-prd NUMBER_OR_URL", "Fetch PRD text from a GitHub issue with gh") { |value| options[:gh_prd] = value }
  opts.on("--gh-issue NUMBER_OR_URL", "Fetch issue text from a GitHub issue with gh") { |value| options[:gh_issue] = value }
  opts.on("--intent TEXT", "Short plain-English task intent") { |value| options[:intent] = value }
  opts.on("--zellij-session NAME", "Create this one-off visible Zellij session name") { |value| options[:zellij_session] = value }
  opts.on("--model MODEL", "Claude model (default: #{CLAUDE_DEFAULT_MODEL})") { |value| options[:model] = value }
  opts.on("--effort LEVEL", "Claude effort (default: #{CLAUDE_DEFAULT_EFFORT})") { |value| options[:effort] = value }
  opts.on("--chrome", "Enable Claude Code Chrome/browser integration") { options[:chrome] = true }
  opts.on("--dry-run", "Print the prompt bundle instead of calling Claude") { options[:dry_run] = true }
  opts.on("-h", "--help", "Show this help") do
    puts opts
    exit 0
  end
end

parser.parse!(ARGV)

unless %w[builder evaluator].include?(options[:mode])
  warn "Unsupported mode: #{options[:mode]}. Use builder or evaluator."
  exit 1
end

if [options[:prd], options[:issue], options[:gh_prd], options[:gh_issue], options[:intent]].compact.empty?
  warn "Pass at least one of --prd, --issue, --gh-prd, --gh-issue, or --intent."
  exit 1
end

def run(*cmd, allow_failure: false)
  stdout, stderr, status = Open3.capture3(*cmd)
  if !status.success? && !allow_failure
    warn "Command failed: #{cmd.shelljoin}"
    warn stderr unless stderr.empty?
    exit status.exitstatus || 1
  end
  [stdout, stderr, status]
end

def git(*args, allow_failure: false)
  stdout, _stderr, status = run("git", *args, allow_failure: allow_failure)
  return nil if allow_failure && !status.success?

  stdout
end

def command_available?(name)
  _stdout, _stderr, status = run("sh", "-c", "command -v #{Shellwords.escape(name)} >/dev/null 2>&1", allow_failure: true)
  status.success?
end

def inside_git_repo?
  _stdout, _stderr, status = run("git", "rev-parse", "--is-inside-work-tree", allow_failure: true)
  status.success?
end

def git_ref_exists?(ref)
  _stdout, _stderr, status = run("git", "rev-parse", "--verify", "--quiet", ref, allow_failure: true)
  status.success?
end

def empty_tree_ref
  git("hash-object", "-t", "tree", "/dev/null").strip
end

def likely_text_file?(path)
  File.file?(path) && !File.binread(path, 4096).include?("\x00")
rescue Errno::ENOENT, Errno::EACCES
  false
end

def read_text_file(path, required: false)
  return nil unless path

  unless File.file?(path)
    warn "File not found: #{path}" if required
    exit 1 if required
    return "Skipped: file not found: #{path}"
  end

  unless likely_text_file?(path)
    return "Skipped: not a readable text file: #{path}"
  end

  if File.size(path) > MAX_TEXT_BYTES
    return "Skipped: file is larger than #{MAX_TEXT_BYTES} bytes: #{path}"
  end

  File.read(path)
end

def fetch_github_issue(reference)
  unless command_available?("gh")
    warn "GitHub CLI not found on PATH; cannot fetch #{reference}."
    exit 1
  end

  stdout, stderr, status = run(
    "gh",
    "issue",
    "view",
    reference.to_s,
    "--comments",
    "--json",
    "title,body,comments,url,labels,state",
    allow_failure: true
  )

  unless status.success?
    warn "Failed to fetch GitHub issue: #{reference}"
    warn stderr unless stderr.empty?
    exit status.exitstatus || 1
  end

  parsed = JSON.parse(stdout)
  labels = Array(parsed["labels"]).map { |label| label["name"] || label.to_s }.join(", ")
  comments = Array(parsed["comments"]).map.with_index(1) do |comment, index|
    author = comment.dig("author", "login") || "unknown"
    body = comment["body"].to_s
    "### Comment #{index} by #{author}\n\n#{body}"
  end.join("\n\n")

  <<~TEXT
    Source: #{parsed["url"]}
    State: #{parsed["state"]}
    Labels: #{labels.empty? ? "(none)" : labels}

    # #{parsed["title"]}

    #{parsed["body"]}

    #{comments.empty? ? "" : "## Comments\n\n#{comments}"}
  TEXT
rescue JSON::ParserError => error
  warn "Failed to parse GitHub issue JSON for #{reference}: #{error.message}"
  exit 1
end

def markdown_section(title, body)
  return "" if body.nil? || body.empty?

  <<~TEXT
    ## #{title}

    #{body}
  TEXT
end

def file_section(path, required: false)
  body = read_text_file(path, required: required)
  return "" unless body

  <<~TEXT
    ### #{path}

    <file path="#{path}">
    #{body}
    </file>
  TEXT
end

def collect_doc_bundle
  paths = []
  paths.concat(%w[
    AGENTS.md
    CLAUDE.md
    docs/agents/issue-tracker.md
    docs/agents/domain.md
    docs/agents/triage-labels.md
    CONTEXT.md
    CONTEXT-MAP.md
  ])
  paths.concat(Dir.glob("docs/adr/*.md").sort)
  paths.uniq!

  sections = []
  total_bytes = 0

  paths.each do |path|
    next unless File.file?(path)

    size = File.size(path)
    if total_bytes + size > MAX_DOC_BUNDLE_BYTES
      sections << "### #{path}\n\nSkipped: documentation bundle exceeded #{MAX_DOC_BUNDLE_BYTES} bytes.\n"
      next
    end

    total_bytes += size
    sections << file_section(path)
  end

  sections.join("\n")
end

def untracked_file_section(path)
  if !likely_text_file?(path)
    "### #{path}\n\nSkipped: not a readable text file.\n"
  elsif File.size(path) > MAX_TEXT_BYTES
    "### #{path}\n\nSkipped: file is larger than #{MAX_TEXT_BYTES} bytes.\n"
  else
    content = File.read(path)
    "### #{path}\n\n<file path=\"#{path}\">\n#{content}\n</file>\n"
  end
rescue Errno::ENOENT, Errno::EACCES
  "### #{path}\n\nSkipped: file disappeared or became unreadable.\n"
end

def untracked_bundle
  raw = git("ls-files", "--others", "--exclude-standard", "-z")
  paths = raw.split("\0").reject(&:empty?)
  return "" if paths.empty?

  sections = paths.map { |path| untracked_file_section(path) }

  <<~TEXT
    ## Untracked Files

    These files are not in `git diff`, but are part of the current working tree:

    #{sections.join("\n")}
  TEXT
end

def current_diff_bundle
  comparison_ref = git_ref_exists?("HEAD") ? "HEAD" : empty_tree_ref
  diff_stat = git("diff", "--stat", comparison_ref, "--")
  diff_body = git("diff", "--no-ext-diff", comparison_ref, "--")
  diff_truncated = false

  if diff_body.bytesize > MAX_TEXT_BYTES
    diff_body = diff_body.byteslice(0, MAX_TEXT_BYTES)
    diff_body = "#{diff_body}\n\n... diff truncated at #{MAX_TEXT_BYTES} bytes ..."
    diff_truncated = true
  end

  <<~TEXT
    ## Current Diff Against #{comparison_ref == "HEAD" ? "HEAD" : "Empty Tree"}

    Diff stat:

    ```text
    #{diff_stat.empty? ? "(no tracked diff)" : diff_stat}
    ```

    Diff:

    ```diff
    #{diff_body.empty? ? "(no tracked diff)" : diff_body}
    ```

    #{diff_truncated ? "Diff was truncated; inspect the full working tree before relying on this context." : ""}
  TEXT
end

def builder_system_prompt
  <<~PROMPT
    You are Claude Code acting as a delegated frontend UI/DX implementation agent for Codex.

    Codex is the technical lead. Your job is to produce a strong UI implementation and a clear handoff, not to broaden the product scope.

    Source of truth:
    - The supplied PRD and issue acceptance criteria define the scope.
    - The selected issue is a vertical slice; keep it demoable and verifiable on its own.
    - Use the project vocabulary from CONTEXT.md when present.
    - Respect ADRs. If you need to contradict one, stop and report the conflict.
    - If key product/design decisions are missing, report the blocker or suggest a HITL follow-up instead of inventing broad scope.

    Collaboration rules:
    - You are not alone in the codebase. Existing git changes may belong to the user or another agent.
    - Do not revert unrelated changes.
    - Prefer existing components, routes, styling tokens, icons, test helpers, and package-manager conventions.
    - Keep implementation scoped to the UI/DX slice and necessary supporting code.

    UI/DX craft:
    - Commit to one clear aesthetic direction before coding.
    - Avoid generic AI defaults: purple gradients, decorative blobs, nested cards, stock SaaS layouts, and unmodified component-library defaults unless the existing app already uses them.
    - Use real existing assets when visual assets matter. Do not invent broken URLs.
    - Preserve accessibility: semantic labels, keyboard/focus states, contrast, responsive behavior, and non-overlapping text.
    - Use stable dimensions for fixed-format UI elements so hover states, dynamic labels, and loading text do not shift layout.
    - Verify desktop and mobile viewports when the app can run.

    Workflow:
    1. Inspect the repo, component system, styling approach, routing, adjacent screens, assets, and scripts.
    2. Summarize the relevant existing patterns and the visual direction you chose.
    3. Implement the slice.
    4. Run the relevant build, typecheck, lint, and tests available in the repo.
    5. Start the app when feasible and use browser/Chrome/Playwright-style inspection when available: desktop, mobile, primary flow, console errors, and screenshots.
    6. Iterate on concrete discrepancies.
    7. Stop when verification passes or a blocker is explicit.

    Final response must be Markdown with these sections:
    - Files changed
    - Design direction
    - Acceptance criteria covered
    - Commands run
    - Browser checks (write "not run: <reason>" if no visible Chrome/browser tool was available; never invent browser evidence)
    - Screenshots or visual evidence (write "not captured: <reason>" if none were captured; never invent screenshot paths or observations)
    - Known gaps / risks
    - Suggested next steps for Codex
  PROMPT
end

def evaluator_system_prompt
  <<~PROMPT
    You are Claude Code acting as a skeptical frontend UI/DX evaluator for Codex.

    Do not edit files. Review the current repo state against the supplied PRD, issue, and domain docs.

    Evaluate:
    - Whether the selected issue acceptance criteria are actually satisfied.
    - Design quality, originality, craft, and fit with the existing product.
    - Responsive behavior, accessibility, keyboard/focus states, empty/loading/error states, and console/runtime errors.
    - Whether the implementation respects existing components, styling tokens, package-manager conventions, CONTEXT.md vocabulary, and ADRs.
    - Whether the work stayed inside the vertical slice.

    Use shell commands, tests, and browser/Chrome/Playwright-style inspection when available. Prefer concrete evidence over taste-only commentary.

    Output findings first, ordered by severity. For each finding, include the smallest reasonable fix. If there are no actionable findings, say that plainly. Then include checks run, visual evidence, and any remaining risks.
  PROMPT
end

def slug(value)
  value.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-+\z/, "")[0, 60]
end

def default_prompt_file(repo_root, options)
  issue_slug = options[:issue] ? slug(File.basename(options[:issue], ".md")) : "prompt"
  repo_slug = slug(File.basename(repo_root))
  stamp = Time.now.utc.strftime("%Y%m%d-%H%M%S")
  File.join(Dir.tmpdir, "claude-ui-builder", "#{stamp}-#{repo_slug}-#{options[:mode]}-#{issue_slug}.md")
end

def default_system_prompt_file(prompt_path)
  return prompt_path.sub(/\.md\z/, "-system.md") if prompt_path.end_with?(".md")

  "#{prompt_path}-system.md"
end

def write_prompt_bundle(payload, repo_root, options)
  path = default_prompt_file(repo_root, options)
  FileUtils.mkdir_p(File.dirname(path)) unless File.dirname(path) == "."
  File.write(path, payload)
  path
end

def write_system_prompt(system_prompt, prompt_path)
  path = default_system_prompt_file(prompt_path)
  File.write(path, system_prompt)
  path
end

def zellij_session_name(repo_root, options)
  return options[:zellij_session] if options[:zellij_session]

  "cui-#{Time.now.utc.strftime("%H%M%S")}"
end

def claude_interactive_shell_cmd(system_prompt_path, options, tools)
  cmd = [
    "claude",
    "--model",
    options[:model],
    "--effort",
    options[:effort],
    "--permission-mode",
    CLAUDE_PERMISSION_MODE,
    "--tools",
    tools,
    "--allowedTools",
    tools
  ]

  cmd << "--chrome" if options[:chrome]
  "#{cmd.shelljoin} --append-system-prompt \"$(cat #{system_prompt_path.shellescape})\""
end

def zellij(*args, allow_failure: false)
  stdout, stderr, status = run("zellij", *args, allow_failure: true)

  if !status.success? && !allow_failure
    warn "Command failed: #{(["zellij"] + args).shelljoin}"
    warn stderr unless stderr.empty?
    exit status.exitstatus || 1
  end

  [stdout, stderr, status]
end

def zellij_session_exists?(session)
  stdout, _stderr, status = zellij("list-sessions", "--short", allow_failure: true)
  return false unless status.success?

  stdout.lines.map(&:strip).include?(session)
end

def zellij_dump_screen(session, pane_id, full: false)
  # Readiness checks must ignore scrollback; old bypass warnings can remain in `--full` output.
  args = [
    "--session",
    session,
    "action",
    "dump-screen",
    "--pane-id",
    pane_id
  ]
  args << "--full" if full

  stdout, _stderr, status = zellij(
    *args,
    allow_failure: true
  )

  return stdout if status.success?

  ""
end

def bypass_warning_screen?(screen)
  CLAUDE_BYPASS_WARNING_MARKERS.all? { |marker| screen.include?(marker) }
end

def claude_ready_screen?(screen)
  CLAUDE_READY_MARKERS.all? { |marker| screen.include?(marker) } && !bypass_warning_screen?(screen)
end

def accept_zellij_bypass_warning(session, pane_id)
  warn "Claude bypass-permissions startup screen detected; selecting Yes, I accept."
  zellij("--session", session, "action", "send-keys", "--pane-id", pane_id, "2", "Enter")
end

def wait_for_zellij_claude_prompt(session, pane_id, timeout_seconds: 30)
  deadline = Time.now + timeout_seconds

  until Time.now > deadline
    screen = zellij_dump_screen(session, pane_id)
    if bypass_warning_screen?(screen)
      accept_zellij_bypass_warning(session, pane_id)
      sleep 1
      next
    end

    return true if claude_ready_screen?(screen)

    sleep 0.5
  end

  warn "Claude pane did not show a ready prompt within #{timeout_seconds}s; not sending the task."
  warn "Inspect it with: zellij --session #{session.shellescape} action dump-screen --pane-id #{pane_id.shellescape} --full"
  false
end

def zellij_write_text(session, pane_id, text)
  text.each_char.each_slice(8_000) do |chars|
    chunk = chars.join
    zellij("--session", session, "action", "write-chars", "--pane-id", pane_id, chunk)
  end
end

def run_zellij_runner(system_prompt, payload, repo_root, options, tools)
  unless command_available?("zellij")
    warn "Zellij is required for claude-ui-builder. Install it with `brew install zellij` and rerun this command."
    exit 1
  end

  unless command_available?("claude")
    warn "Claude Code CLI not found on PATH."
    exit 1
  end

  session = zellij_session_name(repo_root, options)
  if zellij_session_exists?(session)
    warn "Zellij session already exists: #{session}"
    warn "claude-ui-builder sessions are one-off; choose a new --zellij-session name or close the old session first."
    exit 1
  end

  prompt_text = payload
  prompt_path = write_prompt_bundle(prompt_text, repo_root, options)
  system_prompt_path = write_system_prompt(system_prompt, prompt_path)

  _stdout, stderr, status = zellij("attach", "--create-background", session, allow_failure: true)
  unless status.success?
    warn "Failed to create or attach Zellij background session: #{session}"
    warn stderr unless stderr.empty?
    exit status.exitstatus || 1
  end

  cmd = claude_interactive_shell_cmd(system_prompt_path, options, tools)
  stdout, stderr, status = zellij(
    "--session",
    session,
    "run",
    "--cwd",
    repo_root,
    "--name",
    "Claude UI Builder",
    "--",
    "sh",
    "-lc",
    cmd,
    allow_failure: true
  )

  unless status.success?
    warn "Failed to create Zellij Claude pane in session: #{session}"
    warn stderr unless stderr.empty?
    exit status.exitstatus || 1
  end

  pane_id = stdout.strip
  if pane_id.empty?
    warn "Zellij did not return a pane id; cannot safely paste the prompt."
    exit 1
  end

  exit 1 unless wait_for_zellij_claude_prompt(session, pane_id)

  zellij("--session", session, "action", "focus-pane-id", pane_id)
  zellij_write_text(session, pane_id, prompt_text)
  sleep 2
  zellij("--session", session, "action", "send-keys", "--pane-id", pane_id, "Enter")

  puts "Claude prompt sent to Zellij session: #{session}"
  puts "Zellij pane: #{pane_id}"
  puts "Prompt bundle: #{prompt_path}"
  puts "System prompt: #{system_prompt_path}"
  puts
  puts "Watch:"
  puts "zellij attach #{session.shellescape}"
  puts
  puts "Inspect from Codex/shell:"
  puts "zellij --session #{session.shellescape} action dump-screen --pane-id #{pane_id.shellescape} --full"
  puts
  puts "Interrupt:"
  puts "zellij --session #{session.shellescape} action send-keys --pane-id #{pane_id.shellescape} Esc"
  puts "zellij --session #{session.shellescape} action send-keys --pane-id #{pane_id.shellescape} \"Ctrl c\""
end

unless inside_git_repo?
  warn "Not inside a git repository. Run this from the project repo."
  exit 1
end

repo_root = git("rev-parse", "--show-toplevel").strip

options[:prd] = File.expand_path(options[:prd]) if options[:prd]
options[:issue] = File.expand_path(options[:issue]) if options[:issue]

Dir.chdir(repo_root)

prd_text = read_text_file(options[:prd], required: !!options[:prd])
issue_text = read_text_file(options[:issue], required: !!options[:issue])
prd_text = fetch_github_issue(options[:gh_prd]) if options[:gh_prd]
issue_text = fetch_github_issue(options[:gh_issue]) if options[:gh_issue]
status_short = git("status", "--short")
doc_bundle = collect_doc_bundle
diff_bundle = current_diff_bundle
untracked = untracked_bundle

system_prompt = options[:mode] == "builder" ? builder_system_prompt : evaluator_system_prompt
tools = options[:mode] == "builder" ? BUILDER_TOOLS : EVALUATOR_TOOLS

payload = <<~PROMPT
  Repository: #{repo_root}
  Mode: #{options[:mode]}

  #{options[:intent] ? "Task intent:\n#{options[:intent]}\n" : ""}

  Git status:

  ```text
  #{status_short.empty? ? "(clean)" : status_short}
  ```

  #{markdown_section("PRD", prd_text ? "Source: #{options[:gh_prd] ? "GitHub issue #{options[:gh_prd]}" : options[:prd]}\n\n#{prd_text}" : "")}

  #{markdown_section("Issue", issue_text ? "Source: #{options[:gh_issue] ? "GitHub issue #{options[:gh_issue]}" : options[:issue]}\n\n#{issue_text}" : "")}

  #{markdown_section("Project Agent And Domain Docs", doc_bundle)}

  #{diff_bundle}

  #{untracked}
PROMPT

if options[:dry_run]
  puts "Claude model: #{options[:model]}"
  puts "Claude effort: #{options[:effort]}"
  puts "Permission mode: #{CLAUDE_PERMISSION_MODE}"
  puts "Mode: #{options[:mode]}"
  puts "Runner: visible Zellij session"
  puts "Tools: #{tools}"
  puts "Chrome: #{options[:chrome] ? "enabled" : "disabled"}"
  puts
  puts "## Appended system prompt"
  puts system_prompt
  puts
  puts "## User payload"
  puts payload
  exit 0
end

run_zellij_runner(system_prompt, payload, repo_root, options, tools)
