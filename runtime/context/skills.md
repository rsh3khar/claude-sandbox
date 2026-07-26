## Skills

Skills are reusable capabilities that extend what you can do. Browse and discover skills at [skills.sh](https://skills.sh).

### Claude Code Skills

- **Location**: `~/.claude/skills/` (mounted from host)
- **Install**: `npx skills add <owner/repo>`
- Skills are auto-discovered — just invoke with `/skill-name`

### Codex Skills

- **Location**: `~/.agents/skills/` (mounted from host)
- **Install**: `skill-installer install <name> from <source>`
- Skills activate via `/skills` or `$skill-name`, or implicitly when your task matches a skill's description
