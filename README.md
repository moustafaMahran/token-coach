# token-coach

A Claude Code plugin that makes **context/token cost visible and coachable** — so a team moving from human coding to AI-agent workflows can see, understand, and reduce what it spends, without anyone having to think about it.

It is **observe-only by default**: it shows you a live meter and quietly measures your habits. It never rewrites your prompts, never auto-`/clear`s, and **nothing but aggregate numbers ever leaves your machine**.

---

## Why this exists

In agentic coding the bill is **not** driven by how you word a prompt. It is driven by *context that lingers and gets re-sent* and by *session length*:

- conversation history re-sent every turn (the big one)
- large / repeated file reads
- verbose tool output (unbounded `git log`, full test runs, log dumps)
- pasting blobs instead of pointing at files
- idle gaps that evict the prompt cache
- vague prompts that send the agent on a search loop

The key insight token-coach is built around: **lean context is both cheaper and smarter.** Clearing *noise* (a 2,000-line file you read once) is a pure win — it cuts cost *and* sharpens the model's attention. The only thing that costs you quality is clearing *signal*. So the tool coaches you toward dropping noise, never toward blunt frugality.

---

## What it does

### 1. Budget meter (status line) — always on
A single glanceable line, the way a car's live-MPG display changes how you drive:

```
◐ Opus  │  ctx ███████░░░ 68%  │  $3.42  │  ●warm  │  ↑182k ↓24k
```

- context bar turns **amber at 70%**, **red at 85%**
- cache dot goes **○cold** when you've been idle past the cache TTL (~5 min)
- live session cost in USD and humanised token counts

### 2. `/cost-review` — per-session report
On demand, a summary built **entirely from locally-tracked numbers** (see *Privacy*), with concrete, derived suggestions:

```
───────────────  token-coach: session review  ───────────────
 Duration 108m   │   Cost $9.40   │   Prompts 63
 Tokens: ↑ 2.1M in   ↓ 180k out   │   cache hit ~71%   │   ctx 88%

 Observed activity
   • files read .............. 22   (re-read: 3)
   • tool output captured ..... 310 KB
   • coaching signals ......... 9 fired
        clear: 2   reread: 3   paste: 1   bashoutput: 3

 Suggestions for next time
   ① 3 file(s) read more than once — they were already in context.
   ② context is at 88% — /clear or /compact between unrelated tasks.
   ④ 310 KB of tool output — scope commands (head/tail/-n/--quiet).
```

### 3. Coaching nudges (observe-only by default)
A set of hooks watch for the expensive patterns and record a signal. Outside baseline mode they surface as a transient `⚠` on the meter; they are **logged for measurement either way**. Nothing is ever injected into Claude's context (that would itself cost tokens), and nothing blocks your work.

| Signal | Fires when | Hook |
|---|---|---|
| `paste` | you submit a large pasted blob | UserPromptSubmit |
| `clear` | session context is high and you start a new task | UserPromptSubmit |
| `cold` | you've been idle long enough to evict the cache | UserPromptSubmit |
| `scope` | broad-scope prompt ("refactor the entire …") | UserPromptSubmit |
| `vague` | short prompt with no file/symptom reference | UserPromptSubmit |
| `reread` | you read a file already in context | PreToolUse(Read) |
| `hugeread` | you read a very large file in full | PreToolUse(Read) |
| `bashoutput` | a command will dump heavy output | PreToolUse(Bash) |

> **On the "will this prompt cost a lot?" question:** the guard flags (a) prompts that are themselves heavy (pastes), (b) sessions already expensive, and (c) prompts *likely* to trigger expensive work (broad scope). (c) is a heuristic, not a prediction — the plugin cannot know in advance how many files the agent will read. That's exactly why it suggests and never blocks, and why **acceptance rate** is the metric that tunes it.

---

## Privacy — the company-scale boundary

This is the gating design constraint for an org-wide tool. The rule is absolute:

> **Only aggregate numbers are ever recorded or exported. Prompt text, code, file contents, and command bodies are never stored and never leave the machine.**

- Session state lives locally in `~/.claude/token-coach/state/<session_id>.json` and is **git-ignored**.
- What's recorded: token counts, cost, context %, cache numbers, file **paths** (local only), line **counts**, output **byte sizes**, and nudge **reasons/counts**.
- The optional Datadog/OTLP export (see below) carries **only numeric metrics and non-sensitive labels** — never paths, never content.

---

## Install

### Try it locally (this repo as its own marketplace)

```bash
# from inside Claude Code
/plugin marketplace add moustafaMahran/token-coach
/plugin install token-coach@token-coach
```

For a **private** repo, set a token Claude Code can use to fetch it:

```bash
export GITHUB_TOKEN=ghp_xxx   # needs repo:read
```

### Status-line note
Claude Code has a single global status line. If the plugin's bundled `statusLine` isn't picked up on your version, register it manually in `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/plugins/<...>/token-coach/bin/statusline.sh",
    "refreshInterval": 5
  }
}
```

### Requirements
`jq` and `bc` (preinstalled on most dev machines; `brew install jq` if missing). Every script degrades to a no-op without them — it will never break your session.

---

## Configuration

Defaults live in `config/defaults.json`. Override per-developer by creating `~/.claude/token-coach/config.json` (deep-merged over defaults):

```jsonc
{
  "baselineMode": true,            // master switch: log everything, surface nothing
  "statusline": { "amber_ctx": 70, "red_ctx": 85 },
  "submitGuard": {
    "enabled": false,              // active interventions off
    "strict": false,               // true => block egregious pastes (exit 2)
    "pasteLineThreshold": 150,
    "clearCtxPct": 75,
    "idleCacheWarnMins": 5
  },
  "wasteSniffer": { "hugeReadLines": 1000, "rereadGuard": true },
  "telemetry": { "datadog": false, "otlpEndpoint": "" }
}
```

`baselineMode` is the most important knob — see below.

---

## How you'll know it actually helped (measurement)

You **cannot** prove value from your monthly bill — cost per session is dominated by how hard the task was, not how disciplined you were. So measurement is built in:

1. **`baselineMode: true` (the default).** For the first ~2 weeks the plugin logs every metric but **surfaces nothing**. This is your silent baseline.
2. **Flip to `false`.** Same people, same work — only the intervention changed. Compare the *behavioral* metrics, not the dollars:
   - cache hit rate (should rise) · re-reads per session (should fall) · context % at task end (should drop) · tokens per commit (should fall)
3. **Acceptance rate** is the tuning signal: if nudges fire but nobody changes behavior, the threshold is wrong — not the developer.
4. **Team scale** is where it gets statistically real: a **staggered rollout** (cohort A flips in week 1, cohort B in week 3) makes the stagger its own control group, and `$/merged-PR` over many devs averages out task-difficulty noise.

---

## Org-wide telemetry (Datadog via OTLP)

Two layers:

- **Raw cost/tokens** are emitted natively by Claude Code's own OpenTelemetry support — enable with `CLAUDE_CODE_ENABLE_TELEMETRY=1` and the standard `OTEL_*` exporter vars pointed at your Datadog OTLP endpoint. token-coach does not duplicate these.
- **Behavioral metrics** (nudges fired/accepted, re-reads, paste sizes, context-at-task-end) are token-coach's unique contribution — the numbers that show whether the *coaching* works. (Exporter is stubbed in v0.1; see roadmap.)

---

## Status & roadmap

**v0.1 (this release):** meter · `/cost-review` · observe-only nudges · local state · privacy boundary.

Not yet built: the Datadog behavioral-metrics exporter, a `Stop`-hook auto-report, an effectiveness (baseline-vs-active) comparison view, and the savings ledger. These are deliberately deferred until the baseline data says which nudges matter.

---

## Design notes / honest limits

- **No transcript parsing.** Claude Code's transcript JSONL format is internal and unstable, so attribution is built from the plugin's own hook instrumentation (bytes read, output sizes) calibrated against the real session cost from the status-line JSON. It's an honest estimate, not fake precision.
- **Token attribution is session-level.** Claude Code exposes usage per session, not per message, so the report attributes by *observed tool I/O*, not by exact per-message tokens.
- **Heuristics are heuristics.** The scope/vague detectors will sometimes be wrong. That's why the default is suggest-not-block, and why acceptance rate governs tuning.

## License
MIT — see [LICENSE](LICENSE).
