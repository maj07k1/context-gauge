# Context Gauge

A free, open-source macOS menu bar app that shows how full each Claude Code session's context window is, warns you before auto-compact kicks in, and shows what's taking up the space.

> **Unofficial.** Context Gauge is a community project. It isn't affiliated with, endorsed by or supported by Anthropic. "Claude" is a trademark of Anthropic.

## Features

- **Live gauge in the menu bar.** Shows the percentage full (or tokens left) for the session closest to running out among those active in the last 10 minutes. The icon fills up as the context does, and turns into a warning sign when auto-compact is close.
- **Warnings before auto-compact.** Get a notification when a live session passes your warning level (80% by default) and again when it gets close to compacting, so you can run `/compact` yourself and choose what's kept, or `/clear` and start fresh.
- **What's using the space.** The context split into system prompt and tools, tool output, tool calls, thinking, Claude's replies, your messages, reminders and compaction summaries, plus a per-tool breakdown.
- **Biggest items.** The file reads, command output, writes and pasted text taking the most room, with repeats merged ("Read · Views.swift ×3").
- **Context over time.** How each session grew, where it compacted, and how many more requests it has at the recent pace.
- **Every recent session.** Everything from the last 3 days, live sessions marked.

## How it works

Claude Code writes every session to `~/.claude/projects/<project>/<session>.jsonl`. Each request in that log records how many tokens it sent, so the context size shown is the API's own count, not an estimate.

The breakdown works step by step. Between two requests the context grows by the previous reply (its output tokens, including thinking you don't see) plus whatever arrived in between: tool output, your messages, reminders. That growth is split across those pieces in proportion to their size, so the totals always add up to what the API reported. Only the split within a single step is estimated.

The **auto-compact point is an estimate**: the window, minus room for a reply (up to 20K) and a 13K buffer. If you set `CLAUDE_AUTOCOMPACT_PCT_OVERRIDE` in `~/.claude/settings.json`, or turned auto-compact off, the gauge uses that.

The **window size** is assumed to be 1M for Claude 5 models and 200K for older ones. Once a session goes past 200K, the window is taken to be 1M. You can set it yourself in Settings.

## Privacy

- **Nothing leaves your Mac.** The app has no network code, no analytics and no servers.
- **Claude Code's files are only read, never modified.** The app reads session logs under `~/.claude/projects` (and `~/.config/claude/projects`), plus `~/.claude/settings.json` and `~/.claude.json` to check your auto-compact settings.
- Subagent logs are left out; each subagent has a context of its own.

## Install

Requires macOS 14 Sonoma or later, on Apple Silicon or Intel.

1. Download the latest `Context-Gauge-<version>.zip` from the Releases page and unzip it.
2. Move **Context Gauge.app** to your Applications folder.
3. The first time you open it, macOS will warn that the app is from an unidentified developer. Releases aren't notarized because that needs a paid Apple Developer account. To allow it:
   - macOS 15 and later: try to open the app once, then go to **System Settings → Privacy & Security** and click **Open Anyway**.
   - macOS 14: right-click the app, choose **Open**, then confirm.

If you'd rather not trust a downloaded binary, building from source takes about a minute.

## Build from source

You need the Xcode Command Line Tools (`xcode-select --install`). Xcode itself isn't required.

```bash
git clone <this repository>
cd context-gauge
./build.sh --install
```

`build.sh` produces a universal app in `build/`. Run it with `--zip` to also create a release archive. The script's header lists optional settings: `VERSION`, `SOURCE_URL`, `TIP_JAR_URL` and `SIGN_IDENTITY`.

### Development

```bash
swift test
```

```bash
CONTEXT_GAUGE_SNAPSHOT=/tmp/context-gauge-shots swift run
```

The snapshot command reads your real Claude Code logs from the last 30 days, renders the popover and settings to PNG, prints a one-line summary of the newest sessions, then exits. It's handy for checking UI changes without clicking through the menu bar.
