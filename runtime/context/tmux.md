## Parallel Agents with tmux

`tmux` is installed in the container. Use it to run multiple Claude Code or Codex sessions in parallel.

**Important**: Both Claude Code and Codex need **double Enter** to submit a message.

### Quick start

```bash
# Start a detached agent session
tmux new-session -d -s agent1
tmux send-keys -t agent1 'claude --dangerously-skip-permissions' Enter
sleep 3
tmux send-keys -t agent1 'Build the REST API with Express + TypeScript' Enter Enter

# Start another agent in parallel
tmux new-session -d -s agent2
tmux send-keys -t agent2 'claude --dangerously-skip-permissions' Enter
sleep 3
tmux send-keys -t agent2 'Write tests for the auth module' Enter Enter
```

### Managing sessions

```bash
tmux list-sessions              # List all sessions
tmux capture-pane -t agent1 -p -S -100  # Read last 100 lines of output
tmux attach -t agent1           # Watch live (detach: Ctrl+B then D)
tmux send-keys -t agent1 Escape # Interrupt an agent
tmux kill-session -t agent1     # Kill a session
```

### Long prompts (avoid special character issues)

```bash
cat > /tmp/task.txt << 'EOF'
Your detailed instructions here...
EOF
tmux load-buffer /tmp/task.txt
tmux paste-buffer -t agent1
tmux send-keys -t agent1 Enter Enter
```

### Observing agent activity

Claude Code writes session logs to `~/.claude/projects/`. Read the JSONL files directly for ground-truth status instead of asking agents to self-report:

```bash
# Find the latest session log
ls -t ~/.claude/projects/*//*.jsonl | head -1
```

### Git worktrees (parallel work on same repo)

When multiple agents touch the same codebase, use worktrees to avoid conflicts:

```bash
git worktree add ~/workspace/feat-auth -b feat/auth
git worktree add ~/workspace/feat-payments -b feat/payments
```

Each agent works on its own branch in its own directory. Merge when done.
