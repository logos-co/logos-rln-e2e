# shellcheck shell=bash
# harness/lib/seed.sh — give a node a module's persisted state from elsewhere.
#
# A module's persistence dir is HOST-STAMPED: logoscore creates it under the
# node's config dir the first time the module loads, and nothing outside the
# daemon knows the path before that. So seeding is a three-step dance the
# scenario drives: start + load once (the dir appears), stop, overlay, restart
# + load again. This file holds the two primitives between the daemon calls.
#
# Source AFTER daemon.sh.

# Usage: seed_module_dir <node> <module> [wait_s=15] [marker-file]
# Prints the module's persistence dir under the node's config dir, waiting for
# it to appear (module init is asynchronous relative to load-module returning).
# Both depths scenarios/keystore/run.sh saw are tried. With a marker file, the
# dir holding it wins over any other dir of that name (a module cache, say).
# Returns 1 when none appears in the budget.
seed_module_dir() {
    local node="${1:?seed_module_dir <node> <module>}" mod="${2:?module}" wait="${3:-15}" marker="${4:-}"
    local cfg d m _t
    cfg=$(node_cfg_dir "$node")
    [ -n "$cfg" ] || die "seed_module_dir: unknown node '$node'"
    for _t in $(seq 1 "$wait"); do
        if [ -n "$marker" ]; then
            m=$(find "$cfg" -maxdepth 6 -type f -name "$marker" -path "*/$mod/*" 2>/dev/null | head -1)
            if [ -n "$m" ]; then
                dirname "$m"
                return 0
            fi
        fi
        d=$(find "$cfg" -maxdepth 4 -type d -name "$mod" 2>/dev/null | head -1)
        if [ -n "$d" ] && [ -z "$marker" ]; then
            # The instance dir below the module dir, when the layout has one;
            # the module dir itself otherwise (pick the dir holding files).
            local inst
            inst=$(find "$d" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
            if [ -n "$inst" ] && [ -z "$(find "$d" -mindepth 1 -maxdepth 1 -type f -print -quit)" ]; then
                printf '%s' "$inst"
            else
                printf '%s' "$d"
            fi
            return 0
        fi
        sleep 1
    done
    return 1
}

# Usage: seed_module_state <node> <module> <src-dir> [sibling-of-module]
# Replace the module's persistence dir contents with <src-dir>'s. The daemon
# MUST be stopped (daemon_stop_wait): the RLN module holds an exclusive lock
# on its keystore while up. When the module never created its dir (the lez
# module writes nothing until its wallet binds), the dir is derived from a
# sibling module's path by swapping the module name — pass that module as the
# 4th argument.
seed_module_state() {
    local node="${1:?seed_module_state <node> <module> <src-dir>}" mod="${2:?module}" src="${3:?src dir}"
    local sibling="${4:-}" dst
    [ -d "$src" ] || die "seed_module_state: no seed dir at $src"
    [ -z "$(gv NODEPID "$node")" ] || die "seed_module_state: $node is running — daemon_stop_wait first"
    # A file both the fresh dir and the seed carry pins the lookup to the
    # persistence dir (the RLN module's self-provisioned secret, for one).
    local marker=""
    [ -f "$src/rln_autounlock.secret" ] && marker=rln_autounlock.secret
    dst=$(seed_module_dir "$node" "$mod" 1 "$marker") || dst=""
    if [ -z "$dst" ]; then
        [ -n "$sibling" ] || die "seed_module_state: $node has no persistence dir for $mod yet"
        local sib
        sib=$(seed_module_dir "$node" "$sibling" 1) || die "seed_module_state: neither $mod nor $sibling has a persistence dir on $node"
        dst="${sib//$sibling/$mod}"
        say "$node: $mod has no persistence dir yet — deriving $dst from $sibling's"
        mkdir -p "$dst" || die "seed_module_state: cannot create $dst"
    fi
    find "$dst" -mindepth 1 -delete 2>/dev/null || true
    cp -R "$src/." "$dst/" || die "seed_module_state: cannot copy $src into $dst"
    chmod -R go-rwx "$dst" 2>/dev/null || true
    say "$node: $mod seeded from $src -> ${dst#"$E2E_RUN_DIR"/} ($(find "$dst" -type f | wc -l | tr -d ' ') files)"
}
