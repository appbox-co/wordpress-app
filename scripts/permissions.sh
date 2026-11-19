# shellcheck shell=bash
# Ownership repair shared by /entrypoint.sh and /usr/local/bin/wordpress-setup.
# Callers define log().
#
# Startup used to run chown -R over every file on every start. On large sites
# that took many minutes, and under set -e a single file the container could
# not change, such as one owned by root outside the container's user
# namespace, stopped the container and the site crash-looped. These functions
# change only paths that are wrong, and log the paths they cannot change
# instead of failing.

PERMISSIONS_USER="${APP_USER:-appbox}"
PERMISSIONS_GROUP="${APP_GROUP:-appbox}"
PERMISSIONS_LOG_LIMIT=20

# Log the error lines find, chown or chmod wrote on stdin, up to a limit. Each
# line names a path that was left as it was and why.
log_permission_errors() {
    local line count=0

    while IFS= read -r line; do
        count=$((count + 1))
        if (( count <= PERMISSIONS_LOG_LIMIT )); then
            log "Left unchanged: ${line}"
        fi
    done
    if (( count > PERMISSIONS_LOG_LIMIT )); then
        log "Left unchanged: $((count - PERMISSIONS_LOG_LIMIT)) more paths"
    fi
    if (( count > 0 )); then
        log "Could not fix ${count} paths; continuing startup"
    fi
    return 0
}

# Give the app user and group every path under the given roots that they do
# not already own. Symlinks are re-owned themselves, not their targets.
fix_ownership() {
    local path started="${SECONDS}"
    local roots=()

    for path in "$@"; do
        if [[ -e "${path}" ]]; then
            roots+=("${path}")
        fi
    done
    if (( ${#roots[@]} == 0 )); then
        return 0
    fi

    { find "${roots[@]}" \( ! -user "${PERMISSIONS_USER}" -o ! -group "${PERMISSIONS_GROUP}" \) \
        -exec chown -h "${PERMISSIONS_USER}:${PERMISSIONS_GROUP}" -- {} + 2>&1 >/dev/null || true; } \
        | log_permission_errors
    if (( SECONDS - started >= 5 )); then
        log "Ownership check of ${roots[*]} took $((SECONDS - started))s"
    fi
}
