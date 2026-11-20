#!/usr/bin/env bash
# End-to-end test for Sail in linked git worktrees, on pgsql, mysql, mariadb or sqlite.
#
# Creates a fresh Laravel application that keeps this copy of Sail installed, makes it a git
# repository, starts its Sail stack in the main checkout and drives real git, docker and sail
# commands in linked worktrees. It asserts only observable results: exit codes, output, files
# and databases.
#
#   tests/worktree-e2e.sh
#
# Needs git, docker, php and composer on the host (php and composer only to create the
# application; the linked worktree commands run with php and jq hidden from PATH).
# SAIL_E2E_PHP (default 8.5) and SAIL_E2E_LARAVEL (default 12.x) choose the application,
# SAIL_E2E_DB (default pgsql) its database: pgsql, mysql, mariadb or sqlite.
# Host ports are picked by Docker, so runs never collide with other stacks.
set -euo pipefail

SAIL_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
PHP_VERSION="${SAIL_E2E_PHP:-8.5}"
LARAVEL_VERSION="${SAIL_E2E_LARAVEL:-12.x}"
DB="${SAIL_E2E_DB:-pgsql}"
WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/sail-e2e.XXXXXX")" && pwd -P)"
APP="$WORK/app"
PROJECT="sail-e2e-$(printf '%s' "${WORK##*.}" | tr '[:upper:]' '[:lower:]')"

export GIT_AUTHOR_NAME=sail-e2e GIT_AUTHOR_EMAIL=sail-e2e@example.com
export GIT_COMMITTER_NAME=sail-e2e GIT_COMMITTER_EMAIL=sail-e2e@example.com

function cleanup {
    if [ -x "$APP/vendor/bin/sail" ]; then
        (cd "$APP" && vendor/bin/sail down -v > /dev/null 2>&1) || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

function fail {
    echo "not ok - $*" >&2
    exit 1
}

function pass {
    echo "ok - $*"
}

# expect_failure <description> <expected output> <command...>
function expect_failure {
    local output

    if output="$("${@:3}" 2>&1)"; then
        fail "$1: expected a failure, got: $output"
    fi

    grep -qF -- "$2" <<< "$output" || fail "$1: expected output containing '$2', got: $output"
    pass "$1"
}

# db_query <database> <sql>: runs a query against the main checkout's database service.
function db_query {
    if [ "$DB" == "pgsql" ]; then
        (cd "$APP" && docker compose exec -T database psql -U sail -d "$1" -tAc "$2")
    else
        (cd "$APP" && docker compose exec -T -e MYSQL_PWD=password database "$DB" -u root -N -B -e "$2" "$1")
    fi
}

function database_exists {
    if [ "$DB" == "pgsql" ]; then
        [ "$(db_query postgres "SELECT 1 FROM pg_database WHERE datname = '$1'")" == "1" ]
    else
        [ "$(db_query information_schema "SELECT 1 FROM schemata WHERE schema_name = '$1'")" == "1" ]
    fi
}

function table_exists {
    if [ "$DB" == "pgsql" ]; then
        [ "$(db_query "$1" "SELECT to_regclass('public.$2') IS NOT NULL")" == "t" ]
    else
        [ "$(db_query information_schema "SELECT count(*) FROM tables WHERE table_schema = '$1' AND table_name = '$2'")" == "1" ]
    fi
}

# A fingerprint of the main checkout's database...
function main_database_state {
    if [ "$DB" == "sqlite" ]; then
        cksum < "$APP/database/database.sqlite"
    else
        db_query laravel "SELECT count(*) FROM migrations"
    fi
}

echo "# Work dir: $WORK"

case "$DB" in
    pgsql|mysql|mariadb) SERVICES="$DB" ;;
    sqlite) SERVICES=redis ;;
    *) fail "unknown SAIL_E2E_DB '$DB'" ;;
esac

echo "# Creating a Laravel application with Sail installed ($DB)"
composer create-project laravel/laravel "$APP" "$LARAVEL_VERSION" --remove-vcs --no-interaction --prefer-dist --quiet
cd "$APP"
composer config minimum-stability dev
composer config repositories.sail "{\"type\": \"path\", \"url\": \"$SAIL_REPO\", \"options\": {\"symlink\": false}}"
composer require laravel/sail:* --dev -W --no-interaction --quiet
php artisan sail:install --php="$PHP_VERSION" --with="$SERVICES" --no-interaction

# Rename the app and database services and set a project name unlike the directory name, so
# nothing can be derived from names. Declare an app service variable that must reach commands.
sed -i.bak \
    -e 's/^    laravel\.test:/    app:/' \
    -e "s/^    $DB:/    database:/" \
    -e "s/- $DB\$/- database/" \
    -e '/LARAVEL_SAIL: 1$/{p;s/LARAVEL_SAIL: 1/SAIL_E2E_SERVICE_VAR: from-compose/;}' \
    compose.yaml
rm compose.yaml.bak
if [ "$DB" != "sqlite" ]; then
    sed -i.bak -e 's/^DB_HOST=.*/DB_HOST=database/' .env
    rm .env.bak

    # A database test, so "sail test --parallel" creates its _test_N databases...
    composer require brianium/paratest --dev -W --no-interaction --quiet
    cat > tests/Feature/WorktreeDatabaseTest.php << 'PHP'
<?php

namespace Tests\Feature;

use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class WorktreeDatabaseTest extends TestCase
{
    use RefreshDatabase;

    public function test_database_is_usable(): void
    {
        $this->assertDatabaseHas('migrations', ['migration' => '0001_01_01_000000_create_users_table']);
    }
}
PHP
fi
cat >> .env << EOF
APP_SERVICE=app
COMPOSE_PROJECT_NAME=$PROJECT
APP_PORT=0
FORWARD_DB_PORT=0
FORWARD_REDIS_PORT=0
VITE_PORT=$((20000 + RANDOM % 20000))
EOF
echo '{}' > auth.json
mkdir -p node_modules/sail-e2e
echo marker > node_modules/sail-e2e/marker

git init -q -b main
git add -A
git commit -q -m "Initial application"

echo "# Main checkout: upstream Sail steps"
vendor/bin/sail up -d --wait
vendor/bin/sail artisan migrate --no-interaction
vendor/bin/sail test
pass "main checkout: up, migrate and test"
MAIN_DATABASE_STATE="$(main_database_state)"

expect_failure "worktree setup refused in the main checkout" "main checkout" vendor/bin/sail worktree setup

echo "# Composer plugin: post-checkout hook"
HOOK="$APP/.git/hooks/post-checkout"
HOOK_START="# >>> laravel/sail worktree setup >>>"

function managed_blocks {
    grep -cxF -- "$HOOK_START" "$1" || true
}

# A pre-existing shell hook, which must keep its content and still run...
printf '#!/bin/sh\necho "pre-existing hook ran" >> "%s"\n' "$WORK/chain.log" > "$HOOK"
chmod +x "$HOOK"
cp "$HOOK" "$WORK/hook.orig"

OUTPUT="$(composer install --no-interaction 2>&1)" || fail "non-interactive install without allow-plugins: $OUTPUT"
cmp -s "$HOOK" "$WORK/hook.orig" || fail "the plugin writes no hook unless allowed"
pass "non-interactive install without allow-plugins completes and writes no hook"

composer config allow-plugins.laravel/sail true
composer install --no-interaction --quiet
[ -x "$HOOK" ] || fail "install leaves the hook executable"
[ "$(managed_blocks "$HOOK")" == "1" ] || fail "install writes one managed block"
grep -qF "pre-existing hook ran" "$HOOK" || fail "install keeps the existing hook's content"
composer install --no-interaction --quiet
composer update laravel/sail --no-interaction --quiet
[ "$(managed_blocks "$HOOK")" == "1" ] || fail "a second install or update leaves one managed block"
pass "install and update keep one managed block in the existing shell hook"

printf '#!/usr/bin/env python3\nprint("python hook")\n' > "$HOOK"
cp "$HOOK" "$WORK/hook.python"
OUTPUT="$(composer install --no-interaction 2>&1)"
cmp -s "$HOOK" "$WORK/hook.python" || fail "a non-shell hook is left untouched"
grep -qF "post-checkout" <<< "$OUTPUT" || fail "a non-shell hook gives a warning, got: $OUTPUT"
pass "a non-shell hook is left untouched, with a warning"

rm "$HOOK"
git config core.hooksPath .githooks
OUTPUT="$(composer install --no-interaction 2>&1)"
[ ! -e "$HOOK" ] && [ ! -e .githooks ] || fail "nothing is written when core.hooksPath is set"
[ "$(git config core.hooksPath)" == ".githooks" ] || fail "core.hooksPath is unchanged"
grep -qF "core.hooksPath" <<< "$OUTPUT" || fail "core.hooksPath gives a warning, got: $OUTPUT"
git config --unset core.hooksPath
pass "with core.hooksPath set, nothing is written, with a warning"

# Composer in the main checkout's Sail container writes the hook the host then uses...
cp "$WORK/hook.orig" "$HOOK"
vendor/bin/sail composer install --no-interaction --quiet
[ "$(managed_blocks "$HOOK")" == "1" ] || fail "composer in the Sail container writes the managed block"
grep -qF -e "$APP" -e /var/www/html "$HOOK" && fail "the hook contains no absolute project path"
pass "composer in the Sail container writes a hook without absolute project paths"

: > "$WORK/chain.log"
HOOKED="$WORK/hooked-wt"
git worktree add -q -b hooked-wt "$HOOKED"
grep -qF "pre-existing hook ran" "$WORK/chain.log" || fail "the existing hook still runs"
(
    cd "$HOOKED"
    vendor/bin/sail test > /dev/null || fail "sail test passes in a linked worktree created by git worktree add"
)
pass "git worktree add sets up the linked worktree: sail test passes, existing hook still runs"

(
    cd "$HOOKED"
    mv "$HOOK" "$WORK/hook.saved"
    vendor/bin/sail composer install --no-interaction --quiet
    [ ! -e "$HOOK" ] || fail "composer in a linked worktree's throwaway container writes no hook"
    mv "$WORK/hook.saved" "$HOOK"

    rm .env
    git checkout -q -b hooked-wt-switch
    [ ! -e .env ] || fail "a branch switch in a linked worktree triggers worktree setup"
    cp "$APP/.env" .env
)
OUTPUT="$(git checkout -b main-switch 2>&1 && git checkout main 2>&1)" || fail "branch switches in the main checkout: $OUTPUT"
grep -qi "worktree setup" <<< "$OUTPUT" && fail "a branch switch in the main checkout triggers worktree setup: $OUTPUT"
OUTPUT="$(git clone -q "$APP" "$WORK/clone" 2>&1)" || fail "git clone: $OUTPUT"
grep -qi "worktree setup" <<< "$OUTPUT" && fail "git clone triggers worktree setup: $OUTPUT"
pass "composer in a linked worktree writes no hook; checkouts, clones and branch switches skip setup"

OUTPUT="$(SAIL_DOCKER_BINARY=false git worktree add -b failing-wt "$WORK/failing-wt" 2>&1)" \
    || fail "git worktree add exits 0 when worktree setup fails: $OUTPUT"
grep -qF "worktree setup failed" <<< "$OUTPUT" || fail "a failed worktree setup is printed, got: $OUTPUT"
pass "git worktree add exits 0 when worktree setup fails, and prints the failure"

composer remove laravel/sail --dev --no-interaction --quiet
[ "$(managed_blocks "$HOOK")" == "0" ] || fail "removing the package removes the managed block"
grep -qF "pre-existing hook ran" "$HOOK" || fail "removing the package keeps the rest of the hook"
pass "removing the package removes the managed block and keeps the rest of the hook"
# composer remove also drops the allow-plugins entry...
composer config allow-plugins.laravel/sail true
composer require laravel/sail:* --dev --no-interaction --quiet
[ "$(managed_blocks "$HOOK")" == "1" ] || fail "requiring the package again writes the managed block"

# Linked worktree commands must not need php or jq on the host.
mkdir "$WORK/no-host-tools"
for TOOL in php jq; do
    printf '#!/bin/sh\necho "host %s must not be used" >&2\nexit 97\n' "$TOOL" > "$WORK/no-host-tools/$TOOL"
    chmod +x "$WORK/no-host-tools/$TOOL"
done
export PATH="$WORK/no-host-tools:$PATH"

echo "# Linked worktree"
WORKTREE="$WORK/Wt.One"
git worktree add -q -b wt-one "$WORKTREE"
cd "$WORKTREE"
WORKTREE_DATABASE="sail_wt_wt_one_$(printf '%s' "$WORKTREE" | git hash-object --stdin | cut -c1-8)"

"$APP/vendor/bin/sail" worktree setup
cmp -s "$APP/.env" .env || fail "setup copies .env"
cmp -s "$APP/auth.json" auth.json || fail "setup copies auth.json"
[ -x vendor/bin/sail ] || fail "setup copies vendor"
[ -f node_modules/sail-e2e/marker ] || fail "setup copies node_modules"
if [ "$DB" == "sqlite" ]; then
    [ -f database/database.sqlite ] && [ ! -s database/database.sqlite ] || fail "setup creates an empty sqlite database file"
    pass "setup copies env, auth.json, dependencies and creates an empty sqlite database file"
else
    database_exists "$WORKTREE_DATABASE" || fail "setup creates worktree database $WORKTREE_DATABASE"
    pass "setup copies env, auth.json, dependencies and creates $WORKTREE_DATABASE"
fi

vendor/bin/sail worktree setup > /dev/null
pass "setup is re-runnable"

EXPECTED="$WORKTREE_DATABASE|${WORKTREE_DATABASE}_|${WORKTREE_DATABASE}_cache_|from-compose|sail-e2e"
if [ "$DB" == "sqlite" ]; then
    EXPECTED="|${EXPECTED#*|}"
fi
ACTUAL="$(AI_AGENT=sail-e2e vendor/bin/sail php -r 'echo implode("|", array_map("getenv", ["DB_DATABASE", "REDIS_PREFIX", "CACHE_PREFIX", "SAIL_E2E_SERVICE_VAR", "AI_AGENT"]));')"
[ "$ACTUAL" == "$EXPECTED" ] || fail "environment: expected $EXPECTED, got $ACTUAL"
pass "worktree, service and agent variables reach the throwaway container"

vendor/bin/sail artisan make:migration create_wt_markers_table > /dev/null
MIGRATION="$(ls database/migrations/*_create_wt_markers_table.php)"
[ -O "$MIGRATION" ] || fail "files created in the container are owned by the host user"
pass "files created in the container are owned by the host user"

vendor/bin/sail run git status --porcelain | grep -qF "?? $MIGRATION" || fail "git works inside the throwaway container"
pass "git works inside the throwaway container"

vendor/bin/sail artisan migrate --no-interaction
if [ "$DB" == "sqlite" ]; then
    [ -s database/database.sqlite ] || fail "migrate runs against the linked worktree's sqlite database file"
else
    table_exists "$WORKTREE_DATABASE" wt_markers || fail "migrate runs against the worktree database"
fi
vendor/bin/sail test
if [ "$DB" != "sqlite" ]; then
    table_exists laravel wt_markers && fail "main checkout's database gained the worktree's table"
fi
[ "$(main_database_state)" == "$MAIN_DATABASE_STATE" ] || fail "main checkout's database changed"
pass "migrate and test pass in the linked worktree, main checkout's database untouched"

echo "# Worktree databases per driver"
if [ "$DB" != "sqlite" ]; then
    vendor/bin/sail test --parallel --processes=2
    database_exists "${WORKTREE_DATABASE}_test_1" || fail "sail test --parallel creates ${WORKTREE_DATABASE}_test_1"
    pass "sail test --parallel creates its _test_N databases"
fi

if [ "$DB" == "mysql" ] || [ "$DB" == "mariadb" ]; then
    vendor/bin/sail "$DB" <<< 'SELECT DATABASE();' | grep -qx "$WORKTREE_DATABASE" || fail "sail $DB opens the worktree database"
    pass "sail $DB opens the worktree database"
fi

cp -p "$APP/.env" "$WORK/main.env"
sed -i.bak -e 's/^DB_CONNECTION=.*/DB_CONNECTION=sqlsrv/' "$APP/.env"
expect_failure "worktree setup fails for an unsupported driver" "sqlsrv" vendor/bin/sail worktree setup
mv "$WORK/main.env" "$APP/.env"
rm "$APP/.env.bak"

vendor/bin/sail composer --version > /dev/null
vendor/bin/sail bin phpunit --version > /dev/null
pass "composer and bin run in the throwaway container"

cmp -s "$APP/.env" .env || fail "the copied .env is not rewritten"
pass "the copied .env is not rewritten"

# --- Command surface (#4) ---
[ "$(vendor/bin/sail art --version)" == "$(vendor/bin/sail a --version)" ] || fail "artisan aliases run artisan"
vendor/bin/sail phpunit --version > /dev/null
vendor/bin/sail tinker --execute 'echo "tinker-ok";' | grep -qx tinker-ok || fail "tinker runs in the throwaway container"
[ "$(vendor/bin/sail debug tinker --execute 'echo getenv("XDEBUG_TRIGGER");')" == "1" ] || fail "debug sets XDEBUG_TRIGGER"
vendor/bin/sail node --version > /dev/null
vendor/bin/sail npm --version > /dev/null
pass "artisan aliases, phpunit, tinker, debug, node and npm run in the throwaway container"

[ "$(echo 'id -un' | vendor/bin/sail shell)" == "sail" ] || fail "shell runs as sail with piped input"
[ "$(echo 'id -un' | vendor/bin/sail root-shell)" == "root" ] || fail "root-shell runs as root"
pass "shells take piped input; shell runs as sail, root-shell as root"

if [ "$DB" == "pgsql" ]; then
    echo 'SELECT current_database();' | vendor/bin/sail psql | grep -qF "$WORKTREE_DATABASE" || fail "psql connects to the worktree database"
    pass "psql connects to the worktree database"
fi

for COMMAND in down share dusk; do
    expect_failure "'sail $COMMAND' is refused, naming the main checkout" "$APP" vendor/bin/sail "$COMMAND"
done
# --- End command surface (#4) ---

expect_failure "unknown commands are refused" "$APP" vendor/bin/sail up -d

echo "# Unsupported layouts"
git clone -q --bare "$APP" "$WORK/bare.git"
git -C "$WORK/bare.git" worktree add -q "$WORK/bare-wt"
cd "$WORK/bare-wt"
expect_failure "bare-repository layout is unsupported" "unsupported" "$APP/vendor/bin/sail" artisan --version

git init -q "$WORK/nested"
mkdir "$WORK/nested/app"
touch "$WORK/nested/app/artisan"
git -C "$WORK/nested" add -A
git -C "$WORK/nested" commit -q -m "App in a subdirectory"
git -C "$WORK/nested" worktree add -q "$WORK/nested-wt"
cd "$WORK/nested-wt/app"
expect_failure "app outside the git root is unsupported" "unsupported" "$APP/vendor/bin/sail" artisan --version

echo "# Main checkout's Sail stack down"
cd "$APP"
vendor/bin/sail down
cd "$WORKTREE"
expect_failure "commands name the main checkout when its stack is down" "$APP" vendor/bin/sail artisan --version
expect_failure "commands say how to start the stack" "sail up" vendor/bin/sail artisan --version

echo "# All worktree end-to-end checks passed"
