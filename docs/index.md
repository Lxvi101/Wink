---
title: Wink documentation
summary: 'Entry point for installing, configuring, and using Wink across CLI, MCP, app, and library surfaces.'
description: macOS automation that sees the screen and does the clicks. Native CLI, MCP server, and agent runtime for OpenAI, Claude, Grok, Gemini, and Ollama.
read_when:
  - 'starting with Wink or looking for the right documentation page'
  - 'linking the public documentation hub from README, site, or release notes'
---

# Wink documentation

Wink is a macOS automation toolkit for humans and agents. It captures pixels, reads the accessibility tree, drives input, and ships an agent runtime plus an MCP server so AI clients (Codex, Claude Code, Cursor) can drive the desktop with the same primitives you'd use from the shell.

> **TL;DR** — `brew install openclaw/tap/peekaboo`, grant Screen Recording + Accessibility, then
> `wink agent "open Safari and search for Wink" --allow-foreground`.

## Where to start

- **[Install](install.md)** — Homebrew, npm/MCP, source builds.
- **[Quickstart](quickstart.md)** — first capture, first click, first agent run in five minutes.
- **[Platform support](platform-support.md)** — supported macOS, Swift/Xcode, and Node versions by surface.
- **[Permissions](permissions.md)** — what to grant, why, and how to verify.
- **[Configuration](configuration.md)** — environment variables, config files, credential storage.

## What Wink does

- **[Capture & vision](commands/capture.md)** — pixel-accurate screen, window, and menu-bar capture; annotated AX maps.
- **[Automation](automation.md)** — click, type, scroll, drag, hotkeys, menus, dialogs, windows, Spaces.
- **[Agent](commands/agent.md)** — natural-language plan/act loop with provider switching, resumable sessions, and visualizer feedback.
- **[MCP](MCP.md)** — expose every Wink tool over stdio for Codex, Claude Code, and Cursor.
- **[Daemon](daemon.md)** — warm CLI runtime, lifecycle, sockets, and migration.
- **[Bridge host](bridge-host.md)** — TCC broker transport, discovery, security, and troubleshooting.

## Reference

- **[Command reference](cli-command-reference.md)** — every CLI command, grouped.
- **[Command index](commands/README.md)** — one page per command with flags and examples.
- **[Architecture](ARCHITECTURE.md)** — Core, CLI, Bridge, Daemon, Visualizer.
- **[AI providers](providers.md)** — current model/provider and credential reference.
- **[Releasing](RELEASING.md)** — versioning, signing, distribution.

## Surfaces

| Surface | Use it for | Entry point |
| --- | --- | --- |
| **CLI** | scripts, ad-hoc captures, CI | `brew install openclaw/tap/peekaboo` |
| **MCP server** | Codex, Claude Code, Cursor | `npx wink mcp` |
| **Mac app** | menu-bar visualizer, permission prompts | [Releases](https://github.com/Lxvi101/Wink/releases/latest) |
| **Library** | embed foundation, protocols, automation, or Bridge in Swift apps and tools | Root `Package.swift` |

## Get help

- File issues: [github.com/Lxvi101/Wink/issues](https://github.com/Lxvi101/Wink/issues)
- Source: [github.com/Lxvi101/Wink](https://github.com/Lxvi101/Wink)
- Author: [@steipete](https://x.com/steipete)
