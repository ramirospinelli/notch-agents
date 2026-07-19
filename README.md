# Notch Agents

A native macOS companion for keeping an eye on Codex Desktop tasks directly from the notch.

Notch Agents stays integrated with the menu bar, animates while Codex is working, and expands into a compact task dashboard. It reads local Codex session data and remains read-only: approvals and replies continue in Codex Desktop.

## Features

- Running and recently completed Codex tasks
- Live activity and latest output
- Context usage and current rate limit
- Completion notifications
- One-click deep links to the exact Codex task
- Retro animated mascot while an agent is working
- Automatic notch sizing on supported MacBook displays

## Requirements

- macOS 14 or later
- Codex Desktop
- A MacBook with a notch for the intended experience

## Build and install

```bash
git clone https://github.com/ramirospinelli/notch-agents.git
cd notch-agents
./scripts/build-app.sh
open dist/NotchAgents.app
```

Move `dist/NotchAgents.app` to `/Applications` if you want to keep it installed.

## Development

```bash
swift test
swift run NotchAgents
```

Codex session data is read locally from `~/.codex/sessions`. No account credentials or session contents are uploaded.

## Current limitation

Notch Agents cannot approve permissions or answer Codex questions directly. Those interactions belong to the Codex Desktop client that owns the running task; clicking a task opens that exact conversation instead.

## License

[MIT](LICENSE)
