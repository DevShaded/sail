# A Composer plugin installs the post-checkout hook

Worktree setup must start without anyone running an install command, because agents create linked worktrees unattended. The package is therefore a Composer plugin: on every `composer install` and `composer update` in the main checkout it writes a managed block into `.git/hooks/post-checkout` in the git common dir. The hook runs worktree setup when the previous HEAD is all zeros and the checkout is a linked worktree. The hook finds the main checkout through git at run time, because Composer often runs inside the container, where the project path differs from the host path.

## Considered Options

- **An explicit install command** (`sail worktree install`). Rejected: a manual step per clone that agents and new developers forget.
- **Setting `core.hooksPath`.** Rejected: it takes over the project's whole hook setup and conflicts with husky and lefthook.
- **Installing the hook from `bin/sail` on each run.** Rejected: it changes main checkout behaviour and widens the diff to upstream.

## Consequences

- The package type becomes `composer-plugin`, which diverges from upstream. Each project needs `allow-plugins.laravel/sail: true` once, committed in `composer.json`. `plugin-optional` makes non-interactive installs skip the plugin instead of failing.
- When `core.hooksPath` is set, git ignores `.git/hooks`. The plugin warns and installs nothing; worktree setup then needs one manual command.
- The hook always exits 0, so a failed setup never makes `git worktree add` report failure. Setup that needs the Sail stack finishes lazily on the first Sail command.
- The plugin also appends usage notes to an existing `CLAUDE.md` and `AGENTS.md`, which leaves tracked files modified after the first install.
