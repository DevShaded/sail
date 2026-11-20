# Linked worktrees share the main checkout's Sail stack

Many agents work in parallel linked worktrees of one application. A Sail stack per linked worktree would need its own ports, container names, volumes and memory for every worktree, so linked worktrees never start a stack. Each Sail command in a linked worktree runs in a throwaway container from the app image, mounts that worktree, joins the main checkout's network and uses the shared services. Isolation comes from one worktree database per linked worktree plus a Redis and cache prefix.

## Considered Options

- **One Sail stack per linked worktree.** Full isolation, including HTTP. Rejected: port allocation, slow start and heavy resource use with many worktrees.
- **Run commands in the main checkout's app container.** Rejected: that container mounts only the main checkout.

## Consequences

- Linked worktrees are CLI-only: no HTTP server, no Vite dev server, no Dusk. Stack commands (`up`, `down`, `stop`, `build`) are refused there.
- The application and its tests share the worktree database, because it is injected as a real environment variable. Running tests wipes it. A `phpunit.xml` that forces `DB_DATABASE` defeats the isolation.
- Every linked worktree depends on the main checkout's Sail stack running.
- `bin/sail` hands off to `bin/sail-worktree` in one early block. That file keeps its own command mapping, so new upstream commands must be ported by hand.
