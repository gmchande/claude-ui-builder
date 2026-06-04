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
  max_budget_usd: nil,
  max_turns: nil,
  mode: "builder",
  model: CLAUDE_DEFAULT_MODEL,
  output: nil,
  permission_mode: nil,
  prompt_file: nil,
  prd: nil,
  runner: "batch",
  timeout: 1200,
  zellij_pane_id: nil,
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
  opts.on("--output PATH", "Write Claude's Markdown handoff to PATH as well as stdout") { |value| options[:output] = value }
  opts.on("--runner MODE", "batch, prompt, or zellij (default: batch)") { |value| options[:runner] = value }
  opts.on("--prompt-file PATH", "Write the assembled prompt bundle to PATH for prompt/zellij runners") { |value| options[:prompt_file] = value }
  opts.on("--copy-prompt", "Copy the assembled prompt bundle to the macOS clipboard") { options[:copy_prompt] = true }
  opts.on("--zellij-session NAME", "Create/use this Zellij session name for --runner zellij") { |value| options[:zellij_session] = value }
  opts.on("--zellij-pane-id ID", "Send prompt to an existing Zellij pane id, e.g. terminal_3") { |value| options[:zellij_pane_id] = value }
  opts.on("--model MODEL", "Claude model (default: #{CLAUDE_DEFAULT_MODEL})") { |value| options[:model] = value }
  opts.on("--effort LEVEL", "Claude effort (default: #{CLAUDE_DEFAULT_EFFORT})") { |value| options[:effort] = value }
  opts.on("--timeout SECONDS", Integer, "Stop Claude after SECONDS (default: 1200)") { |value| options[:timeout] = value }
  opts.on("--max-turns N", Integer, "Optional Claude Code print-mode turn limit") { |value| options[:max_turns] = value }
  opts.on("--max-budget-usd AMOUNT", "Optional Claude Code print-mode spend cap") { |value| options[:max_budget_usd] = value }
  opts.on("--permission-mode MODE", "Optional Claude Code permission mode") { |value| options[:permission_mode] = value }
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

unless %w[batch prompt zellij].include?(options[:runner])
  warn "Unsupported runner: #{options[:runner]}. Use batch, prompt, or zellij."
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

def claude_base_cmd(system_prompt, options, tools, print_mode: false)
  cmd = [
    "claude",
    "--model",
    options[:model],
    "--effort",
    options[:effort],
    "--tools",
    tools,
    "--allowedTools",
    tools,
    "--append-system-prompt",
    system_prompt
  ]

  if print_mode
    cmd.insert(1, "-p")
    cmd.insert(2, "--no-session-persistence")
  end

  cmd << "--chrome" if options[:chrome]
  cmd.concat(["--permission-mode", options[:permission_mode]]) if options[:permission_mode]

  cmd
end

def run_claude(system_prompt, payload, options, tools)
  cmd = claude_base_cmd(system_prompt, options, tools, print_mode: true)
  cmd.concat([
    "--output-format",
    "json"
  ])

  cmd.concat(["--max-turns", options[:max_turns].to_s]) if options[:max_turns]
  cmd.concat(["--max-budget-usd", options[:max_budget_usd].to_s]) if options[:max_budget_usd]

  timed_out = false

  Open3.popen3(*cmd) do |stdin, stdout, stderr, wait_thread|
    stdin.write(payload)
    stdin.close

    stdout_reader = Thread.new { stdout.read }
    stderr_reader = Thread.new { stderr.read }

    if wait_thread.join(options[:timeout])
      return [stdout_reader.value, stderr_reader.value, wait_thread.value, false, cmd]
    end

    timed_out = true
    begin
      Process.kill("TERM", wait_thread.pid)
    rescue Errno::ESRCH
      # Process already exited between timeout detection and signal delivery.
    end

    sleep 2

    if wait_thread.alive?
      begin
        Process.kill("KILL", wait_thread.pid)
      rescue Errno::ESRCH
        # Process already exited after TERM.
      end
    end

    wait_thread.join
    [stdout_reader.value, stderr_reader.value, wait_thread.value, timed_out, cmd]
  end
end

def extract_result_text(stdout)
  parsed = JSON.parse(stdout)
  events = parsed.is_a?(Array) ? parsed : [parsed]
  result_event = events.reverse.find { |event| event.is_a?(Hash) && event["type"] == "result" }

  return [result_event["result"].to_s, result_event] if result_event

  [stdout, nil]
rescue JSON::ParserError
  [stdout, nil]
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
  path = options[:prompt_file] || default_prompt_file(repo_root, options)
  FileUtils.mkdir_p(File.dirname(path)) unless File.dirname(path) == "."
  File.write(path, payload)
  path
end

def write_system_prompt(system_prompt, prompt_path)
  path = default_system_prompt_file(prompt_path)
  File.write(path, system_prompt)
  path
end

def copy_to_clipboard(text)
  return false unless command_available?("pbcopy")

  Open3.popen3("pbcopy") do |stdin, _stdout, _stderr, wait_thread|
    stdin.write(text)
    stdin.close
    return wait_thread.value.success?
  end
end

def print_visible_runner_instructions(system_prompt, payload, repo_root, options, tools)
  prompt_path = write_prompt_bundle(payload, repo_root, options)
  system_prompt_path = write_system_prompt(system_prompt, prompt_path)
  copied = options[:copy_prompt] ? copy_to_clipboard(payload) : false
  cmd = claude_interactive_shell_cmd(system_prompt_path, options, tools)

  puts "Prompt bundle: #{prompt_path}"
  puts "System prompt: #{system_prompt_path}"
  puts "Claude command:"
  puts cmd
  puts
  puts "Open a visible terminal in this repo, run the command above, then paste the prompt bundle."
  puts "Paste helper:"
  puts "pbcopy < #{prompt_path.shellescape}"
  puts "Clipboard: #{copied ? "prompt copied" : "not copied"}" if options[:copy_prompt]
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
    "--tools",
    tools,
    "--allowedTools",
    tools
  ]

  cmd << "--chrome" if options[:chrome]
  cmd.concat(["--permission-mode", options[:permission_mode]]) if options[:permission_mode]
  "#{cmd.shelljoin} --append-system-prompt \"$(cat #{system_prompt_path.shellescape})\""
end

def visible_prompt_text(system_prompt, payload, include_system_prompt:)
  return payload unless include_system_prompt

  <<~PROMPT
    You are being handed a delegated Claude UI Builder task from Codex. Use these role instructions for this run:

    #{system_prompt}

    #{payload}
  PROMPT
end

def zellij(*args, allow_failure: false)
  stdout, stderr, status = run("zellij", *args, allow_failure: true)
  output = "#{stdout}\n#{stderr}"

  if !status.success? && output.match?(/(socket|path|file name).*(too long|name too long)/im)
    ENV["ZELLIJ_SOCKET_DIR"] ||= "/tmp/zellij"
    FileUtils.mkdir_p(ENV.fetch("ZELLIJ_SOCKET_DIR"))
    @zellij_socket_fallback_used = true
    stdout, stderr, status = run("zellij", *args, allow_failure: true)
  end

  if !status.success? && !allow_failure
    warn "Command failed: #{(["zellij"] + args).shelljoin}"
    warn stderr unless stderr.empty?
    exit status.exitstatus || 1
  end

  [stdout, stderr, status]
end

def zellij_dump_screen(session, pane_id)
  stdout, _stderr, status = zellij(
    "--session",
    session,
    "action",
    "dump-screen",
    "--pane-id",
    pane_id,
    "--full",
    allow_failure: true
  )

  return stdout if status.success?

  ""
end

def wait_for_zellij_claude_prompt(session, pane_id, timeout_seconds: 15)
  deadline = Time.now + timeout_seconds

  until Time.now > deadline
    screen = zellij_dump_screen(session, pane_id)
    return true if screen.include?("Claude Code") && screen.include?("❯")

    sleep 0.5
  end

  warn "Claude pane did not show a ready prompt within #{timeout_seconds}s; pasting anyway."
  false
end

def zellij_cli_prefix
  return "" unless @zellij_socket_fallback_used && ENV["ZELLIJ_SOCKET_DIR"]

  "ZELLIJ_SOCKET_DIR=#{ENV.fetch("ZELLIJ_SOCKET_DIR").shellescape} "
end

def zellij_paste_text(session, pane_id, text)
  text.each_char.each_slice(8_000) do |chars|
    chunk = chars.join
    zellij("--session", session, "action", "paste", "--pane-id", pane_id, chunk)
  end
end

def run_zellij_runner(system_prompt, payload, repo_root, options, tools)
  unless command_available?("zellij")
    warn "zellij is not available on PATH. Install it with `brew install zellij`, use --runner prompt, or start Claude manually in a visible terminal."
    exit 1
  end

  session = zellij_session_name(repo_root, options)
  existing_pane_id = options[:zellij_pane_id]
  prompt_text = visible_prompt_text(system_prompt, payload, include_system_prompt: !!existing_pane_id)
  prompt_path = write_prompt_bundle(prompt_text, repo_root, options)
  system_prompt_path = write_system_prompt(system_prompt, prompt_path)
  copied = options[:copy_prompt] ? copy_to_clipboard(prompt_text) : nil

  if existing_pane_id
    pane_id = existing_pane_id
  else
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

    wait_for_zellij_claude_prompt(session, pane_id)
  end

  zellij("--session", session, "action", "focus-pane-id", pane_id)
  zellij_paste_text(session, pane_id, prompt_text)
  zellij("--session", session, "action", "send-keys", "--pane-id", pane_id, "Enter")

  puts "Claude prompt sent to Zellij session: #{session}"
  puts "Zellij pane: #{pane_id}"
  puts "Prompt bundle: #{prompt_path}"
  puts "System prompt: #{system_prompt_path}"
  puts "Clipboard: #{copied ? "prompt copied" : "not copied"}" unless copied.nil?
  puts
  puts "Watch:"
  puts "#{zellij_cli_prefix}zellij attach #{session.shellescape}"
  puts
  puts "Inspect from Codex/shell:"
  puts "#{zellij_cli_prefix}zellij --session #{session.shellescape} action dump-screen --pane-id #{pane_id.shellescape} --full"
  puts
  puts "Interrupt:"
  puts "#{zellij_cli_prefix}zellij --session #{session.shellescape} action send-keys --pane-id #{pane_id.shellescape} Esc"
  puts "#{zellij_cli_prefix}zellij --session #{session.shellescape} action send-keys --pane-id #{pane_id.shellescape} \"Ctrl c\""
end

unless inside_git_repo?
  warn "Not inside a git repository. Run this from the project repo."
  exit 1
end

repo_root = git("rev-parse", "--show-toplevel").strip

options[:prd] = File.expand_path(options[:prd]) if options[:prd]
options[:issue] = File.expand_path(options[:issue]) if options[:issue]
options[:output] = File.expand_path(options[:output]) if options[:output]
options[:prompt_file] = File.expand_path(options[:prompt_file]) if options[:prompt_file]

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
  puts "Mode: #{options[:mode]}"
  puts "Runner: #{options[:runner]}"
  puts "Tools: #{tools}"
  puts "Chrome: #{options[:chrome] ? "enabled" : "disabled"}"
  puts "Output format: #{options[:runner] == "batch" ? "json" : "interactive terminal"}"
  puts
  puts "## Appended system prompt"
  puts system_prompt
  puts
  puts "## User payload"
  puts payload
  exit 0
end

if options[:runner] == "prompt"
  print_visible_runner_instructions(system_prompt, payload, repo_root, options, tools)
  exit 0
end

unless command_available?("claude")
  warn "Claude Code CLI not found on PATH."
  exit 1
end

if options[:runner] == "zellij"
  if options[:max_turns] || options[:max_budget_usd]
    warn "--max-turns and --max-budget-usd only apply to the default batch print-mode runner; ignoring them for zellij."
  end

  run_zellij_runner(system_prompt, payload, repo_root, options, tools)
  exit 0
end

stdout, stderr, status, timed_out, cmd = run_claude(system_prompt, payload, options, tools)
warn stderr unless stderr.empty?

if timed_out
  warn "Claude UI #{options[:mode]} timed out after #{options[:timeout]} seconds."
  exit 124
end

unless status.success?
  warn "Claude UI #{options[:mode]} failed."
  warn "Command: #{cmd.shelljoin}"
  partial_text, partial_metadata = extract_result_text(stdout)
  if !partial_text.to_s.empty?
    warn "Claude returned partial output before failing:"
    puts partial_text
  elsif partial_metadata
    warn "Claude returned metadata before failing: #{partial_metadata.inspect}"
  end
  exit status.exitstatus || 1
end

result_text, metadata = extract_result_text(stdout)

if metadata && metadata["is_error"]
  warn "Claude UI #{options[:mode]} returned an error result: #{metadata["subtype"] || "unknown"}"
  error_details = result_text.empty? ? Array(metadata["errors"]).join("\n") : result_text
  error_details = stdout if error_details.empty?
  warn error_details unless error_details.empty?
  exit 1
end

puts result_text

if options[:output]
  FileUtils.mkdir_p(File.dirname(options[:output])) unless File.dirname(options[:output]) == "."
  File.write(options[:output], result_text)
end
