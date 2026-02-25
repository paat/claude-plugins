# Claude Plugins Repository

## Rules

- All plugins in this repo must be generic and project-agnostic
- Project-specific values must use template variables, not hardcoded strings
- No hardcoded project names, paths, stacks, or team conventions in plugin code
- Plugins must work with bash 4+ and standard POSIX tools
- External dependencies (jq, awk, sed) must be documented in README
- ALWAYS bump the plugin version in `.claude-plugin/plugin.json` before pushing — Claude Code uses this field to detect updates in containers
