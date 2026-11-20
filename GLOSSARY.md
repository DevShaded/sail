# Sail

Sail runs a Laravel application's development environment in Docker. This fork also lets many git worktrees of one application work side by side without colliding.

## Language

### Checkouts

**Main checkout**:
The repository's main worktree, and the only checkout that runs a Sail stack.
_Avoid_: Main repo, root checkout, primary worktree

**Linked worktree**:
A checkout created with `git worktree add`. It never runs a Sail stack of its own.
_Avoid_: Worktree (unqualified), secondary checkout

### Runtime

**Sail stack**:
The set of running containers that Sail starts for the main checkout.
_Avoid_: Environment, cluster

**Shared services**:
The main checkout's database server, Redis and Mailpit, used by the main checkout and every linked worktree.
_Avoid_: Backing services, infrastructure

**Throwaway container**:
A container that exists for one Sail command in a linked worktree and is removed when the command ends.
_Avoid_: Ephemeral container, one-off container, worker

**Worktree database**:
The one database a linked worktree owns on the shared database server. The application and its tests both use it.
_Avoid_: Test database, branch database

### Lifecycle

**Worktree setup**:
The preparation that makes a linked worktree able to run Sail commands.
_Avoid_: Bootstrap, init, provisioning

**After-setup step**:
The project-defined work that runs at the end of worktree setup.
_Avoid_: Post-setup hook, setup script

**Prune**:
Removing worktree databases whose linked worktree no longer exists.
_Avoid_: Teardown, cleanup, garbage collection
