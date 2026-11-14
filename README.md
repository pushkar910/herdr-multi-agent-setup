# herdr-multi-agent-setup

A portable multi-agent setup for Claude Code inside [Herdr](https://herdr.dev). A **Lead** agent (Lead Architect / orchestrator) plans the work with you, then delegates it to paired **Engineer** and **Reviewer** agents that run in their own Herdr tabs.

## Architecture

The Lead is the only agent that talks to you. For every implementation task it spawns a 1:1 Engineer/Reviewer pair. Pairs are numbered: pair N is `engineer-N` + `reviewer-N`, each in a Herdr tab labelled with the agent name; the task a pair owns lives in the Lead's plan and briefs, not in the name.
Only the Lead creates Herdr tabs, panes, and agents: Engineers may use Claude Code's built-in sub-agents within their own scope, and ask the Lead if they need another Herdr agent.

```
                       ┌──────────┐
                       │   You    │
                       └────┬─────┘
                            │ plan, approve, decisions
                       ┌────▼─────┐
                       │   lead   │  Lead Architect / Orchestrator
                       └─┬──────┬─┘
          herdr agent    │      │    herdr agent
          start/prompt   │      │    start/prompt
              ┌──────────▼─┐  ┌─▼──────────┐
              │ engineer-1 │◄►│ reviewer-1 │   pair 1 (own Herdr tab each)
              └──────┬─────┘  └────────────┘
                     │ share contracts / API signatures
              ┌──────▼─────┐  ┌────────────┐
              │ engineer-2 │◄►│ reviewer-2 │   pair 2
              └────────────┘  └────────────┘
```

The Lead works in five phases with an explicit approval gate:

1. **Discover and plan** (read-only): The Lead analyzes the codebase and proposes a plan with tasks, owners, dependencies, acceptance criteria, risks, and test strategy.
2. **Gate**: nothing is spawned or changed until you explicitly approve. Any later scope change comes back to this gate.
3. **Spawn pairs**: one `engineer-N` + `reviewer-N` pair per independent work stream (the Lead picks the next free N from `herdr agent list`), each with its own non-overlapping files, started via the `herdr` CLI.
4. **Build and review**: Engineers implement and test; Reviewers send findings (severity + `file:line`) straight to their paired Engineer (`herdr agent prompt engineer-N "REVIEW FINDINGS: ..."`), up to 3 rounds, then escalate to the Lead.
5. **Integrate, verify, report**: The Lead reviews the combined diff, checks the quality gates (Reviewer approval, passing tests, no secrets or machine paths, docs updated), reports, and asks before closing the tabs it created.

### What the prompt contains

`prompts/lead_prompt.txt` is structured markdown with these sections: identity and mandate (never writes production code; never pushes, deploys, deletes, forces, or touches secrets without approval), startup, workflow and gates, paired topology, default models and permission mode, a Herdr command reference, operational gotchas, a brief template, the communication protocol (`STATUS:`, `QUESTION FOR LEAD:`, `DONE:`, `VERDICT: APPROVED` / `VERDICT: CHANGES REQUIRED`), decision authority and escalation, quality gates, and the final report format.

## Prerequisites

- [Herdr](https://herdr.dev) (tested with 0.9.5)
- Claude Code CLI: see the [official docs](https://docs.claude.com/en/docs/claude-code/overview) for installation
- zsh or bash
- git
- optional: [`gh`](https://cli.github.com/)

## Repo layout

| Path | Purpose | Installed to |
|------|---------|--------------|
| `prompts/lead_prompt.txt` | Lead system prompt | `~/.claude/lead_prompt.txt` |
| `config/herdr/config.toml` | Herdr config (adds `prefix+r` to open the Lead) | `~/.config/herdr/config.toml` |
| `bin/lead` | Launcher: `claude --append-system-prompt "$(cat prompt)" --model ... --permission-mode ... --settings ...` | `~/.local/bin/lead` |
| `bin/lead-notify` | Notification hook script (macOS; no-op elsewhere) | `~/.local/bin/lead-notify` |
| `config/claude/lead-settings.json` | Lead-only Claude Code settings: the notification hooks | `~/.claude/lead/settings.json` |
| `install.sh` | Idempotent installer with backups and manifest | n/a |
| `uninstall.sh` | Returns every installed path to its pre-install state | n/a |

The installer also writes `~/.claude/skills/herdr/SKILL.md` (from `herdr --skill`), a fenced `herdr-multi-agent-setup` block in your shell rc (PATH + `alias hlead="herdr --session main"`), and a manifest at `~/.local/share/herdr-multi-agent-setup/manifest`.

## Human Quickstart

```bash
git clone https://github.com/pushkar910/herdr-multi-agent-setup.git
cd herdr-multi-agent-setup
./install.sh
source ~/.zshrc    # or ~/.bashrc, or open a new terminal
```

Use it:

1. Run `hlead` to launch or attach to the Herdr `main` session.
2. Press `Ctrl+b r` (`prefix+r` in `config.toml`) to open a Lead pane. You can also run `lead` in any shell.
3. The Lead introduces itself and asks for a task. Describe it.
4. The Lead proposes a plan. Review it and reply with approval or changes.
5. After approval, the Lead opens `engineer-N` and `reviewer-N` tabs. Watch them or leave them to work; the Lead reports back and asks you only for product decisions, permission prompts, and risky actions.

Installer options: `--rc <file>` to pick the shell rc file (default `~/.zshrc` for zsh, otherwise `~/.bashrc`).
Set `HERDR_SETUP_SKIP_RELOAD=1` to skip reloading a running Herdr server.

> **`lead` alias?** If your rc file defines an `alias lead=...`, it shadows `~/.local/bin/lead` (aliases win over PATH). Remove that line, then open a new terminal. The installer prints a warning when it finds one.

## Models and permission mode

| Setting | Default | Override for the Lead | Override for sub-agents |
|---|---|---|---|
| Model | `claude-opus-5-5` | `LEAD_MODEL=<id> lead`, or `lead --model <id>` | Tell the Lead, e.g. "use `claude-sonnet-5-5` for the docs pair" |
| Permission mode | `auto` | `LEAD_PERMISSION_MODE=<mode> lead`, or `lead --permission-mode <mode>` | Tell the Lead, e.g. "start the infra pair in `plan` mode" |

- Arguments you pass to `lead` win over the environment and the defaults: `--model`/`--model=...` replaces the default model; `--permission-mode`/`--permission-mode=...` or `--dangerously-skip-permissions` replaces the default permission mode.
- The Lead starts every Engineer and Reviewer agent with `-- --model claude-opus-5-5 --permission-mode auto` unless you ask for something else for that task.
- **Why a pinned ID instead of the `opus` alias?** The alias moves to whatever model is newest. Pinning `claude-opus-5-5` keeps the Lead and its sub-agents on the same, tested model and makes runs reproducible. Change the ID deliberately when you upgrade.
- **Permission prompts:** even in `auto` mode, Claude Code can stop and ask before risky actions. A sub-agent waiting on such a dialog shows as `blocked` in Herdr. The Lead never answers these itself; it tells you, and you either approve it in that agent's pane or ask the Lead to restart the agent with another `--permission-mode` (choices: `acceptEdits`, `auto`, `bypassPermissions`, `manual`, `dontAsk`, `plan`; see `claude --help`).

## Pane, tab, and agent naming

Inside Herdr (`HERDR_ENV=1`), `lead` names itself so you and other agents can find it:

- the pane is renamed `lead`;
- the tab is renamed `lead`, but only if the Lead is the tab's only pane (a `Ctrl+b r` split never overwrites your tab label);
- the Herdr agent is renamed `lead` by a short background loop (Herdr only detects the agent after Claude starts; it retries once per second for about 30 seconds). If another live agent already has `lead`, it uses `lead-2`, `lead-3`, and so on.

All of this is best effort and never blocks the launch. Disable it with `LEAD_NO_RENAME=1`.

## Notifications (macOS)

You get a macOS banner (with sound) and, inside Herdr, a Herdr toast when the **Lead** session:

- finishes a reply (Claude Code `Stop` hook): "Lead replied · `<project folder>`", sound Glass;
- needs a tool-permission approval (Claude Code `Notification` hook, matcher `permission_prompt`): "Lead needs your approval · `<what it asks>`", sound Ping.

Idle "waiting for your input" reminders do not notify. Engineer and Reviewer sessions never notify, because only `lead` loads these hooks.

How it works: `lead` passes `--settings ~/.claude/lead/settings.json` to Claude Code. That file contains only the two hooks, which run `~/.local/bin/lead-notify`. Your own `~/.claude/settings.json` is never modified, and its hooks keep working: hooks from `--settings` merge with the hooks in your settings files rather than replacing them (verified on Claude Code v2.1.325). The hook script always exits 0 within about 2 seconds and prints nothing.

- **First use**: macOS shows banners from `osascript` as coming from **Script Editor**. If you see nothing, open System Settings → Notifications → Script Editor and allow notifications (banners or alerts).
- **Focus / Do Not Disturb** hides banners and sounds. The Herdr toast still appears.
- **Test it** (sends a real banner):
  ```bash
  echo '{"cwd":"/tmp/demo"}' | lead-notify stop
  echo '{"message":"Claude needs your permission to use Bash","notification_type":"permission_prompt"}' | lead-notify permission
  ```

| Variable | Effect |
|---|---|
| `LEAD_NOTIFY=0` | Turn notifications off (the hooks still load but do nothing). |
| `LEAD_NOTIFY_DEBUG=1` | Append a log to `~/.claude/lead/notify.log`. |
| `LEAD_NOTIFY_SOUND_STOP` | Reply sound (default `Glass`; set to empty for silent). Names from `/System/Library/Sounds`. |
| `LEAD_NOTIFY_SOUND_PERMISSION` | Approval sound (default `Ping`; empty for silent). |
| `LEAD_SETTINGS_FILE` | Use a different settings file instead of `~/.claude/lead/settings.json`. Passing `--settings <file>` to `lead` also replaces it. |

Set these in your shell before launching `lead`; the hooks inherit the Lead's environment.

## AI Agent Self-Install

For a coding agent told: *"Clone this repo and set up Herdr + the Lead on my machine."* Run these steps in order.

1. Check prerequisites:
   ```bash
   command -v herdr claude git
   ```
   Each found tool prints a path. If `herdr` or `claude` is missing, tell the user to install it (links above) and stop. Do not guess install commands.
2. Clone:
   ```bash
   git clone https://github.com/pushkar910/herdr-multi-agent-setup.git
   cd herdr-multi-agent-setup
   ```
3. Install:
   ```bash
   ./install.sh
   ```
   Expect lines starting `installed:`, `replacing:`, `backed up:`, `unchanged:`, `updated:` (the rc block), and `note:` (config reload status), possibly `warning:` lines on stderr (report them), and a `Done. Next steps:` block. Exit code 0.
4. Verify:
   ```bash
   test -x ~/.local/bin/lead && echo ok-lead
   test -x ~/.local/bin/lead-notify && test -f ~/.claude/lead/settings.json && echo ok-notify
   test -f ~/.claude/lead_prompt.txt && echo ok-prompt
   grep -c '>>> herdr-multi-agent-setup >>>' ~/.zshrc ~/.bashrc 2>/dev/null   # exactly 1 in the rc file used; with --rc <file>, grep that file instead
   test -f ~/.local/share/herdr-multi-agent-setup/manifest && echo ok-manifest
   ```
   Expected: `ok-lead`, `ok-notify`, `ok-prompt`, a count of `1` for the rc file that was used, and `ok-manifest`. Re-running `./install.sh` must print `unchanged:` for every file and create no new `.bak.*` files.
5. Do NOT touch: existing `~/.zshrc`/`~/.bashrc` content outside the `herdr-multi-agent-setup` block, any `.bak.*` backups, or secrets and tokens in the user's environment. Do not start, stop, or restart a Herdr server (the installer only reloads config in an already-running one). Do not edit files under `~/.claude` or `~/.config/herdr` by hand.
6. Report back: say that the install finished, list any backups the installer printed (`backed up:` lines), list any warnings (including an `alias lead=` warning), and tell the user to run `source ~/.zshrc` (or open a new terminal), then `hlead`, then `Ctrl+b r`.
7. Roll back if asked or if something failed:
   ```bash
   ./uninstall.sh
   ```

## Customization

- **Prompt**: edit `prompts/lead_prompt.txt` in the repo and re-run `./install.sh` (the old installed copy is backed up). To experiment without installing, point `lead` at another file: `LEAD_PROMPT_FILE=/path/to/prompt.txt lead`.
- **Models and permission mode**: see [Models and permission mode](#models-and-permission-mode). To change the sub-agent defaults permanently, edit Section 5 of the prompt and the agent arguments in Section 6.
- **Herdr config**: edit `config/herdr/config.toml` (for example the `prefix+r` binding) and re-run `./install.sh`.

## Uninstall

```bash
./uninstall.sh
```

Uninstall returns each installed path to its state before the **first** install, using the manifest:

| Before the first install | After uninstall |
|---|---|
| file did not exist | removed |
| file existed with identical content | left untouched; if a later install replaced it, restored from the first safety backup (your last own version) |
| file existed with different content | restored from the backup taken at that first install (the backup file is moved back) |

**Your edits are never silently lost.** The manifest stores the SHA-256 of what install last wrote to each file. If an installed file was changed after that, uninstall first moves it to `<file>.bak.uninstall.<timestamp>`, prints that path, and then removes or restores the file as above.

It also removes the `herdr-multi-agent-setup` rc block (and the rc file itself if the installer created it and it is now empty), deletes the manifest, and removes directories the installer created if they are empty (deepest first, never recursively). It only touches paths recorded in the manifest and is safe to run twice.

Re-installs take a safety backup (`*.bak.<timestamp>`) only when the file holds something of yours: you edited it after the last install, or it was yours before the first install. An unedited file from a previous install is simply replaced. Apart from the one uninstall restores, these stay in place for you to inspect or delete, as do `*.bak.uninstall.*` files and `~/.claude/lead/notify.log` (a directory holding them is kept).

## Troubleshooting

- **`lead: prompt file not found`**: run `./install.sh`, or set `LEAD_PROMPT_FILE`.
- **`lead: 'claude' ... not found on PATH`**: install Claude Code and make sure its binary is on `PATH`.
- **`lead` or `hlead` not found**: run `source ~/.zshrc` (or `~/.bashrc`), or open a new terminal. Check that `~/.local/bin` is on `PATH`.
- **`lead` runs something else**: an `alias lead=` in your rc file shadows the launcher. Remove it (`type lead` shows what runs).
- **`Ctrl+b r` does nothing**: the config was not loaded. Run `herdr server reload-config`, or restart Herdr.
- **A sub-agent is stuck `blocked`**: it is waiting on a permission dialog. Approve or deny it in that agent's tab, or ask the Lead to restart it with a different `--permission-mode`.
- **No notification banners**: allow Script Editor in System Settings → Notifications, check Focus/Do Not Disturb, check `LEAD_NOTIFY` is not `0`, then run the test commands in [Notifications](#notifications-macos) with `LEAD_NOTIFY_DEBUG=1` and read `~/.claude/lead/notify.log`. In a Lead session, `/hooks` lists the loaded hooks.
- **Unknown model error**: your Claude Code version or account may not offer `claude-opus-5-5`. Set `LEAD_MODEL` and tell the Lead which model to use for sub-agents.
- **Wrong rc file was edited**: run `./uninstall.sh`, then `./install.sh --rc <file>`.
- **`hlead` alias missing**: the installer omits it when you already define `alias hlead=` elsewhere in the rc file.
- **Agent spawn fails**: confirm `herdr --version` and see `herdr --skill`. The prompt was written against Herdr 0.9.5.
