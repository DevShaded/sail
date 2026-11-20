<?php

namespace Laravel\Sail;

use Composer\Composer;
use Composer\EventDispatcher\EventSubscriberInterface;
use Composer\IO\IOInterface;
use Composer\Plugin\PluginInterface;
use Composer\Script\ScriptEvents;
use Composer\Util\ProcessExecutor;

/**
 * Keeps a managed block in the main checkout's post-checkout hook that runs worktree setup when
 * "git worktree add" creates a linked worktree, and appends the agent notes to the main checkout's
 * CLAUDE.md and AGENTS.md.
 */
class WorktreePlugin implements PluginInterface, EventSubscriberInterface
{
    const BLOCK_START = '# >>> laravel/sail worktree setup >>>';

    const BLOCK_END = '# <<< laravel/sail worktree setup <<<';

    /**
     * The managed block. It finds the main checkout through git at run time, so it holds no path and
     * works whether Composer ran on the host or in the Sail container. It never makes the hook fail.
     */
    const BLOCK = <<<'SH'
# >>> laravel/sail worktree setup >>>
# Managed by laravel/sail: composer install rewrites this block, composer remove deletes it.
# When "git worktree add" creates a linked worktree, run the main checkout's Sail worktree setup.
case "$1" in
    *[!0]* | "") ;;
    *)
        (
            # Clear the variables git exports to hooks, so git finds the checkouts on its own...
            # shellcheck disable=SC2046
            unset $(git rev-parse --local-env-vars)
            [ "$(git rev-parse --path-format=absolute --git-dir)" != "$(git rev-parse --path-format=absolute --git-common-dir)" ] || exit 0
            sail="$(git worktree list --porcelain | sed -n '1s/^worktree //p')/vendor/bin/sail"
            [ -x "$sail" ] || exit 0
            "$sail" worktree setup || echo "Sail worktree setup failed. Fix the problem above, then run in this linked worktree: \"$sail\" worktree setup" >&2
        )
        ;;
esac
# <<< laravel/sail worktree setup <<<

SH;

    const NOTES_START = '<!-- sail-worktree:start -->';

    /**
     * The agent notes, appended to an existing CLAUDE.md and AGENTS.md in the main checkout.
     */
    const NOTES = <<<'MD'
<!-- sail-worktree:start -->
## Sail in git worktrees

- In a linked worktree, run `vendor/bin/sail` as usual. Each command runs in a throwaway container with this worktree's own database. Database server, Redis and Mailpit are shared with the main checkout.
- The Sail stack runs in the main checkout only. Never run `sail up`, `down`, `stop` or `build` in a linked worktree.
- App and tests share one database per worktree: running tests wipes it.
- No HTTP server, Vite dev server or Dusk in a linked worktree.
- After a lockfile change, run `vendor/bin/sail worktree setup`.
- If `vendor/bin/sail` is missing in a linked worktree, run from inside it:
  `"$(git worktree list --porcelain | sed -n '1s/^worktree //p')/vendor/bin/sail" worktree setup`
<!-- sail-worktree:end -->

MD;

    /**
     * @var \Composer\IO\IOInterface
     */
    protected $io;

    public function activate(Composer $composer, IOInterface $io)
    {
        $this->io = $io;
    }

    public function deactivate(Composer $composer, IOInterface $io)
    {
        //
    }

    public function uninstall(Composer $composer, IOInterface $io)
    {
        $this->io = $io;

        if ($this->inMainCheckout()) {
            $this->updateHook(false);
        }
    }

    public static function getSubscribedEvents()
    {
        return [
            ScriptEvents::POST_INSTALL_CMD => 'install',
            ScriptEvents::POST_UPDATE_CMD => 'install',
        ];
    }

    /**
     * Write the managed block into the main checkout's post-checkout hook and add the agent notes.
     *
     * @return void
     */
    public function install()
    {
        if (! $this->inMainCheckout()) {
            return;
        }

        $this->updateHook(true);
        $this->addAgentNotes();
    }

    /**
     * Write or remove the managed block.
     *
     * @param  bool  $install
     * @return void
     */
    protected function updateHook($install)
    {
        $root = getcwd();

        if ((new ProcessExecutor($this->io))->execute('git -C '.ProcessExecutor::escape($root).' config --get core.hooksPath', $hooksPath) === 0
            && trim($hooksPath) !== '') {
            $this->warn('core.hooksPath is set, so git ignores .git/hooks. Worktree setup needs a manual "sail worktree setup".');

            return;
        }

        $hook = $root.'/.git/hooks/post-checkout';
        $current = is_file($hook) ? file_get_contents($hook) : null;

        if ($current === null && ! $install) {
            return;
        }

        if ($current !== null && ! preg_match('~\A#!\s*\S*/(env\s+)?(ba|da|k|z)?sh\b~', $current)) {
            $this->warn('.git/hooks/post-checkout is not a shell script, so the worktree setup block was not added.');

            return;
        }

        $content = preg_replace(
            '~^'.preg_quote(self::BLOCK_START, '~').'\n.*?^'.preg_quote(self::BLOCK_END, '~').'\n\n?~ms', '', $current ?? "#!/bin/sh\n"
        );

        if ($install) {
            // After the shebang, so an exit later in an existing hook cannot skip the block...
            [$shebang, $rest] = array_pad(explode("\n", $content, 2), 2, '');
            $content = $shebang."\n".self::BLOCK.$rest;
        }

        if ($content === $current) {
            return;
        }

        if (! is_dir(dirname($hook))) {
            mkdir(dirname($hook), 0777, true);
        }

        $temporary = $hook.'.sail-'.getmypid();
        file_put_contents($temporary, $content);
        chmod($temporary, $current === null ? 0755 : fileperms($hook) & 0777);
        rename($temporary, $hook);
    }

    /**
     * Append the agent notes to CLAUDE.md and AGENTS.md where the file exists and lacks them.
     *
     * @return void
     */
    protected function addAgentNotes()
    {
        foreach (['CLAUDE.md', 'AGENTS.md'] as $name) {
            $file = getcwd().'/'.$name;

            // Read again for each file, so a CLAUDE.md that links to AGENTS.md gets the notes once...
            $current = is_file($file) ? file_get_contents($file) : false;

            if ($current === false || strpos($current, self::NOTES_START) !== false) {
                continue;
            }

            $separator = $current === '' ? '' : (substr($current, -1) === "\n" ? "\n" : "\n\n");

            file_put_contents($file, $separator.self::NOTES, FILE_APPEND);
        }
    }

    /**
     * Only a main checkout has a .git directory: a linked worktree, also inside a throwaway
     * container, has a .git file.
     *
     * @return bool
     */
    protected function inMainCheckout()
    {
        return is_dir(getcwd().'/.git');
    }

    /**
     * @param  string  $message
     * @return void
     */
    protected function warn($message)
    {
        $this->io->writeError('<warning>laravel/sail: '.$message.'</warning>');
    }
}
