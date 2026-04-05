# Onboarding - Read on Every New Session

This file must be read and actioned at the start of every new conversation.

## Steps

1. **Read CLAUDE.md** — understand the project rules and conventions
2. **Check repo state** — run the following commands to understand the current state and ongoing work:

   ```bash
   # Current branch and working tree status
   git status

   # Recent commits to see what's been happening
   git log --oneline -15

   # Any uncommitted changes (staged and unstaged)
   git diff --stat

   # List all branches to spot any feature/fix branches in progress
   git branch -a

   # Show the last commit in detail to understand the most recent change
   git log -1 --stat
   ```

3. **Read Progress.md** — check for any in-progress work from previous sessions that needs to be resumed
4. **Check memory** — read MEMORY.md for any stored user preferences or project context
5. **Ready** — you now have full context. Proceed with the user's request.

## Key Context

- This is an infrastructure automation repo (Bash/PowerShell scripts)
- Scripts deploy Zabbix (proxy/agent), TacticalRMM agents, and SQL Server on Linux
- All scripts must work non-interactively via TacticalRMM and interactively standalone
- The GitHub repo is `MarkLFT/Scripts` on the `main` branch
- Backup automation is in a separate repo: `MarkLFT/sql-server-linux-backups`

## Progress.md — MANDATORY (sessions can be lost at any time)

**You MUST keep `Progress.md` up to date at all times.** Sessions can end without warning — a crash, network drop, context limit, or the user simply closing the window. If Progress.md is stale, the next session starts blind.

### When to update Progress.md

- **Before starting work** — write what you are about to do
- **After completing each meaningful step** — mark it done, note what's next
- **When you make a decision or hit a blocker** — record it immediately
- **When the user changes direction** — update the plan to reflect the new goal
- **When work is fully complete** — move items to Completed, clear Current Work

### What to include

- **Current Work**: what is actively being worked on right now
- **Plan/Remaining**: numbered steps still to do
- **Decisions**: any choices made and why (so the next session doesn't re-debate them)
- **Blockers**: anything that prevented progress
- **Completed**: finished items with dates

### Rules

- Update Progress.md **as you go**, not at the end — there may be no "end"
- Be specific: "Editing install-zabbix-agent-linux-tactical-rmm.sh to add Redis plugin detection" not "Working on script"
- If there is no active work, Progress.md should say "No active tasks" under Current Work
- Never leave Progress.md in a state where a new session couldn't understand what's happening
