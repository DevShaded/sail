<p align="center"><img width="294" height="69" src="/art/logo.svg" alt="Logo Laravel Sail"></p>

<p align="center">
<a href="https://packagist.org/packages/laravel/sail"><img src="https://img.shields.io/packagist/dt/laravel/sail" alt="Total Downloads"></a>
<a href="https://packagist.org/packages/laravel/sail"><img src="https://img.shields.io/packagist/v/laravel/sail" alt="Latest Stable Version"></a>
<a href="https://packagist.org/packages/laravel/sail"><img src="https://img.shields.io/packagist/l/laravel/sail" alt="License"></a>
</p>

## Introduction

Sail provides a Docker powered local development experience for Laravel that is compatible with macOS, Windows (WSL2), and Linux. Other than Docker, no software or libraries are required to be installed on your local computer before using Sail. Sail's simple CLI means you can start building your Laravel application without any previous Docker experience.

#### Inspiration

Laravel Sail is inspired by and derived from [Vessel](https://github.com/shipping-docker/vessel) by [Chris Fidao](https://github.com/fideloper). If you're looking for a thorough introduction to Docker, check out Chris' course: [Shipping Docker](https://serversforhackers.com/shipping-docker).

## Git Worktrees

This fork lets many git worktrees of one application run Sail commands side by side. The main checkout runs the Sail stack as usual. A linked worktree, created with `git worktree add`, never runs a Sail stack: each `sail` command there runs in a throwaway container from the app image, on the main checkout's network, using the shared services (database server, Redis and Mailpit).

Allow the Composer plugin once in your application's `composer.json`, and commit it:

```json
"config": {
    "allow-plugins": {
        "laravel/sail": true
    }
}
```

Every `composer install` and `composer update` in the main checkout then keeps a managed block in `.git/hooks/post-checkout`, and appends usage notes for agents to `CLAUDE.md` and `AGENTS.md` where those files already exist. If `core.hooksPath` is set (for example by husky or lefthook), the plugin warns and installs no hook.

When `git worktree add` creates a linked worktree, the hook runs worktree setup:

- It copies the main checkout's root `.env*` files and `auth.json`, and its `vendor` and `node_modules` directories (with reflinks where supported).
- It removes worktree databases of linked worktrees that no longer exist (prune).
- It creates the linked worktree's own worktree database, `sail_wt_<directory>_<hash>`, and gives it its own Redis and cache prefix.
- It installs dependencies in a throwaway container when the linked worktree's lockfiles differ from the main checkout's.
- It runs the after-setup step: the `sail-worktree-setup` Composer script, if your project defines one, for example to migrate or build assets.

If the Sail stack is down at that moment, the first `sail` command in the linked worktree finishes worktree setup. A failed worktree setup never makes `git worktree add` fail; it prints the problem instead.

In a linked worktree, run `vendor/bin/sail` as usual: `artisan`, `test`, `composer`, `npm`, `shell`, `psql` and the other in-container commands work as in the main checkout. Its limits:

- The application and its tests share the worktree database, so running tests wipes it.
- There is no HTTP server, Vite dev server, `share`, `open` or Dusk.
- `up`, `down`, `stop`, `restart` and `build` are refused: start the Sail stack in the main checkout.
- After a lockfile change, run `sail worktree setup` again.

`sail worktree prune` drops worktree databases whose linked worktree is gone. It works in the main checkout and in linked worktrees.

When no hook ran (no `allow-plugins` entry, `core.hooksPath` set, or a linked worktree older than the plugin), the linked worktree has no `vendor/bin/sail`. Run the main checkout's copy from inside the linked worktree once:

```shell
"$(git worktree list --porcelain | sed -n '1s/^worktree //p')/vendor/bin/sail" worktree setup
```

## Official Documentation

Documentation for Sail can be found on the [Laravel website](https://laravel.com/docs/sail).

## Contributing

Thank you for considering contributing to Sail! You can read the contribution guide [here](.github/CONTRIBUTING.md).

## Code of Conduct

In order to ensure that the Laravel community is welcoming to all, please review and abide by the [Code of Conduct](https://laravel.com/docs/contributions#code-of-conduct).

## Security Vulnerabilities

Please review [our security policy](https://github.com/laravel/sail/security/policy) on how to report security vulnerabilities.

## License

Laravel Sail is open-sourced software licensed under the [MIT license](LICENSE.md).
