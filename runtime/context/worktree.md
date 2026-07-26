## Worktree Mode

If the session was launched with `--worktree`, the repo you see is a **git
worktree on a scratch branch**, not the user's working tree. Their checkout is
untouched, and your commits land in their repository for review. Commit
normally; the user merges the branch afterwards on the host.
