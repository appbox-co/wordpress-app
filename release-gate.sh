#!/bin/bash
set -Eeuo pipefail

release_ref="repo.cylo.net/wordpress:7.1.2-4"
usage() {
    echo "Usage: release-gate.sh ${release_ref}" >&2
    echo "       release-gate.sh local/wordpress-trial:7.1.2-4 ${release_ref}   (trial build, never pushed)" >&2
    exit 2
}
case $# in
    1) [[ "$1" == "${release_ref}" ]] || usage; mode=release ;;
    2) [[ "$1" == local/wordpress-trial:* && "$1" =~ ^[A-Za-z0-9._/:-]+$ && "$2" == "${release_ref}" ]] || usage; mode=trial ;;
    *) usage ;;
esac

image_ref="$1"
gate_dir="$(cd "$(dirname "$0")" && pwd)"
baseline_ref="repo.cylo.net/wordpress@sha256:f40b3d3637e5457fdb5f2acce820da5106c230ee9280749bd6bac564031fe79d"
# The deployed 7.1.2-2 image that 7.1.2-4 replaces; the PHP module lists must match it.
deployed_ref="repo.cylo.net/wordpress@sha256:1453be2f375879c4342edbfc88644f643dcc4095229d221e00f508fc4cf30923"
# The mutable wordpress:latest line (catalogue version latest-4) that the
# release moves onto 7.1.2-4. Only its current Ubuntu 24.04 / PHP 8.3 build
# is still in the registry. The Ubuntu 20.04 / PHP 7.4 build that 17 live
# instances run (sha256:dcd14f5eb6ac90fed9d14b44856329af8eb3797c9f606c25a604b31c62bfa17b)
# returns MANIFEST_UNKNOWN from repo.cylo.net and the node repo caches, so
# this gate does not cover the 20.04 upgrade path.
legacy_noble_ref="repo.cylo.net/wordpress@sha256:c3f4b3726aa0d6a26a4e85f52ab6e80d8bc2a96036216fbb3ae9a09fa57899c7"
wp_path="/home/appbox/public_html"
gate_root="$(mktemp -d /home/appbox/builds/wordpress-gate.XXXXXX)"

if [[ ! "${gate_root}" =~ ^/home/appbox/builds/wordpress-gate\.[A-Za-z0-9]{6}$ ]]; then
    echo "Unexpected release-gate directory" >&2
    exit 1
fi

gate_suffix="${gate_root##*.}"
fresh_container="wp-gate-fresh-${gate_suffix}"
legacy_container="wp-gate-legacy-${gate_suffix}"
upgrade_container="wp-gate-upgrade-${gate_suffix}"
noble_container="wp-gate-noble-${gate_suffix}"
noble_upgrade_container="wp-gate-noble-upgrade-${gate_suffix}"
prev_container="wp-gate-prev-${gate_suffix}"
prev_upgrade_container="wp-gate-prev-upgrade-${gate_suffix}"
slow_mysql_container="wp-gate-slow-mysql-${gate_suffix}"
dead_mysql_container="wp-gate-dead-mysql-${gate_suffix}"
capped_mysql_container="wp-gate-capped-mysql-${gate_suffix}"
test_password="$(openssl rand -base64 30)"

cleanup() {
    docker rm -f "${fresh_container}" "${legacy_container}" "${upgrade_container}" \
        "${noble_container}" "${noble_upgrade_container}" \
        "${prev_container}" "${prev_upgrade_container}" \
        "${slow_mysql_container}" "${dead_mysql_container}" "${capped_mysql_container}" >/dev/null 2>&1 || true
    if [[ "${gate_root}" =~ ^/home/appbox/builds/wordpress-gate\.[A-Za-z0-9]{6}$ ]]; then
        docker run --rm --platform linux/amd64 --entrypoint sh \
            -v "${gate_root}:/gate" "${image_ref}" \
            -c 'find /gate -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +' >/dev/null 2>&1 || true
        rmdir -- "${gate_root}" || echo "Builder cleanup needed at ${gate_root}" >&2
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
    echo "Release gate failed: $*" >&2
    exit 1
}

wait_ready() {
    local container="$1"

    for _ in $(seq 1 180); do
        if docker exec "${container}" wp --allow-root --path="${wp_path}" core is-installed >/dev/null 2>&1 \
            && docker exec "${container}" curl -kfsS \
                -H 'Host: wordpress-gate.local' \
                https://127.0.0.1/wp-login.php -o /dev/null >/dev/null 2>&1; then
            return 0
        fi

        if [[ "$(docker inspect --format '{{.State.Running}}' "${container}" 2>/dev/null || true)" != "true" ]]; then
            fail "${container} stopped before WordPress was ready"
        fi
        sleep 2
    done

    fail "${container} did not become ready"
}

# Remaining arguments are extra docker run options (mounts, environment).
start_container() {
    local container="$1" data_dir="$2" release_image="$3"
    shift 3

    mkdir -p "${data_dir}/public_html" "${data_dir}/mysql" "${data_dir}/logs" "${data_dir}/config"
    docker run -d --platform linux/amd64 --name "${container}" \
        -e SKIP_APPBOX_CALLBACK=1 \
        -e WP_URL=https://wordpress-gate.local \
        -e WP_TITLE='WordPress release gate' \
        -e WP_ADMIN_USER=wpgate \
        -e WP_ADMIN_PASSWORD="${test_password}" \
        -e WP_ADMIN_EMAIL=wpgate@example.invalid \
        -v "${data_dir}/public_html:${wp_path}" \
        -v "${data_dir}/mysql:/home/appbox/mysql" \
        -v "${data_dir}/logs:/home/appbox/logs" \
        -v "${data_dir}/config:/home/appbox/config" \
        "$@" \
        "${release_image}" >/dev/null
}

launch() {
    start_container "$@"
    wait_ready "$1"
}

# Wait for a container to stop by itself; fail if it is still running after
# the given number of seconds.
wait_stopped() {
    local container="$1" limit="$2" started="${SECONDS}"

    while [[ "$(docker inspect --format '{{.State.Running}}' "${container}")" == "true" ]]; do
        (( SECONDS - started < limit )) || fail "${container} was still running after ${limit}s"
        sleep 2
    done
}

restart_count() {
    docker inspect --format '{{.RestartCount}}' "$1"
}

# Make a mysqld stand-in for the next container: it logs the start of a MySQL
# server upgrade as mysqld does, then stays up without accepting connections
# for GATE_MYSQLD_DELAY seconds before running the real mysqld, or exits at
# once when GATE_MYSQLD_EXIT=1. gate-entrypoint swaps it in for
# /usr/sbin/mysqld and runs the image's own entrypoint.
write_mysqld_stand_in() {
    local dir="$1"

    mkdir -p "${dir}"
    cat > "${dir}/gate-entrypoint" <<'SH'
#!/bin/sh
set -e
if [ ! -e /usr/sbin/mysqld.gate-real ]; then
    mv /usr/sbin/mysqld /usr/sbin/mysqld.gate-real
    install -m 0755 /gate-mysqld/mysqld /usr/sbin/mysqld
fi
exec /entrypoint.sh "$@"
SH
    cat > "${dir}/mysqld" <<'SH'
#!/bin/sh
case " $* " in *" --initialize"*) exec /usr/sbin/mysqld.gate-real "$@" ;; esac
error_log=/home/appbox/logs/mysql/error.log
note() {
    printf "%s 0 [System] [MY-013381] [Server] Server upgrade from '80411' to '80413' %s.\n" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "${error_log}"
}
note started
[ "${GATE_MYSQLD_EXIT:-0}" != 1 ] || exit 1
sleep "${GATE_MYSQLD_DELAY:?}"
note completed
exec /usr/sbin/mysqld.gate-real "$@"
SH
    chmod 0755 "${dir}/gate-entrypoint" "${dir}/mysqld"
}

check_core_updates() {
    local container="$1" expected_version="$2"

    [[ "$(docker exec "${container}" wp --allow-root --path="${wp_path}" core version)" == "${expected_version}" ]] \
        || fail "${container} has the wrong WordPress core version"
    docker exec "${container}" wp --allow-root --path="${wp_path}" \
        config is-true WP_AUTO_UPDATE_CORE >/dev/null \
        || fail "${container} does not enable core auto-updates"
    docker exec -u 1000 "${container}" test -w "${wp_path}/wp-includes/version.php" \
        || fail "${container} cannot write WordPress core as the app user"
    docker exec -u 1000 "${container}" test -w "${wp_path}/wp-content" \
        || fail "${container} cannot write WordPress update workspace as the app user"
    docker exec -u 1000 "${container}" wp --path="${wp_path}" --skip-plugins --skip-themes \
        eval 'require_once ABSPATH . "wp-admin/includes/class-wp-automatic-updater.php"; if ((new WP_Automatic_Updater())->is_disabled()) { exit(1); }' >/dev/null \
        || fail "${container} reports its automatic updater disabled"
}

check_fpm_upload() {
    local container="$1" result

    docker exec -i "${container}" sh -c 'cat > /home/appbox/public_html/appbox-gate-upload.php' <<'PHP'
<?php
echo count($_FILES), ':', $_FILES['f']['size'] ?? -1, ':', $_POST['a'] ?? '';
PHP
    result="$(docker exec "${container}" sh -c 'printf hello > /tmp/gate-upload.txt && curl -kfsS -H "Host: wordpress-gate.local" -F a=b -F f=@/tmp/gate-upload.txt https://127.0.0.1/appbox-gate-upload.php')" || true
    docker exec "${container}" rm -f /home/appbox/public_html/appbox-gate-upload.php /tmp/gate-upload.txt
    [[ "${result}" == "1:5:b" ]] \
        || fail "${container}: multipart upload through nginx and PHP-FPM returned '${result}', expected '1:5:b'"
}

# Nothing under the WordPress root may be left to another owner than the app
# user that PHP-FPM runs as. Setup runs wp-cli as root, and a fresh install
# used to leave the wp-content/uploads/YYYY/MM folder that core install creates
# owned by root, so media uploads failed until the next restart. $2, if given,
# is a path under the root that is expected to keep another owner.
check_owned_by_app_user() {
    local container="$1" wrong prune=()

    [[ -z "${2:-}" ]] || prune=(-path "${wp_path}/$2" -prune -o)
    wrong="$(docker exec "${container}" find "${wp_path}" "${prune[@]}" \
        \( ! -user appbox -o ! -group appbox \) -printf '%u:%g %p\n')" \
        || fail "${container}: could not check owners under ${wp_path}"
    if [[ -n "${wrong}" ]]; then
        printf '%s\n' "${wrong}" | head -20 >&2
        fail "${container}: $(wc -l <<<"${wrong}") paths under ${wp_path} are not owned by appbox:appbox"
    fi
}

# Save a file into this month's uploads folder through WordPress as the app
# user, as a media upload from the dashboard does.
check_app_user_upload() {
    local container="$1"

    docker exec -u 1000 "${container}" wp --path="${wp_path}" --skip-plugins --skip-themes eval \
        '$r = wp_upload_bits("appbox-gate-upload.txt", null, "gate"); if ($r["error"]) { fwrite(STDERR, $r["error"] . "\n"); exit(1); } unlink($r["file"]);' \
        || fail "${container}: WordPress cannot save an upload as the app user"
}

# Install a site with a legacy wordpress:latest image, add content, switch
# its root account to mysql_native_password, then start the release image on
# the same volumes, as `apps update` does. The legacy images install MySQL 8.0
# with apt on first start, so this needs network access; api.cylo.io and
# api.cylo.net resolve to 127.0.0.1 so their install callback never reaches
# the API (it retries forever, which keeps their MySQL running for us).
legacy_upgrade() {
    local label="$1" legacy_ref="$2" legacy_c="$3" upgrade_c="$4"
    local data_dir="${gate_root}/${label}" post_id salt_hash upload_marker error_log_offset upgrade_log

    echo "-- ${label}: ${legacy_ref}"
    docker pull --platform linux/amd64 "${legacy_ref}" >/dev/null
    mkdir -p "${data_dir}/public_html" "${data_dir}/mysql" "${data_dir}/logs" "${data_dir}/config"
    docker run -d --platform linux/amd64 --name "${legacy_c}" \
        --add-host api.cylo.io:127.0.0.1 --add-host api.cylo.net:127.0.0.1 \
        -e INSTANCE_ID=0 \
        -e WP_URL=https://wordpress-gate.local \
        -e WP_TITLE='WordPress release gate' \
        -e WP_ADMIN_USER=wpgate \
        -e WP_ADMIN_PASSWORD="${test_password}" \
        -e WP_ADMIN_EMAIL=wpgate@example.invalid \
        -v "${data_dir}/public_html:${wp_path}" \
        -v "${data_dir}/mysql:/home/appbox/mysql" \
        -v "${data_dir}/logs:/home/appbox/logs" \
        -v "${data_dir}/config:/home/appbox/config" \
        "${legacy_ref}" >/dev/null
    for _ in $(seq 1 300); do
        if docker exec "${legacy_c}" sh -c "wp --allow-root --path='${wp_path}' core is-installed" >/dev/null 2>&1 \
            && docker exec "${legacy_c}" mysql -uroot -p"mysqlr00t" -NBe 'SELECT 1' >/dev/null 2>&1; then
            break
        fi
        [[ "$(docker inspect --format '{{.State.Running}}' "${legacy_c}" 2>/dev/null || true)" == "true" ]] \
            || { docker logs --tail 60 "${legacy_c}" >&2 || true; fail "${legacy_c} stopped before WordPress was installed"; }
        sleep 3
    done
    docker exec "${legacy_c}" sh -c "wp --allow-root --path='${wp_path}' core is-installed" >/dev/null 2>&1 \
        || { docker logs --tail 60 "${legacy_c}" >&2 || true; fail "${legacy_c} did not install WordPress"; }
    echo "${label}: legacy core $(docker exec "${legacy_c}" wp --allow-root --path="${wp_path}" core version), $(docker exec "${legacy_c}" php -r 'echo "PHP ", PHP_VERSION;'), $(docker exec "${legacy_c}" mysql -uroot -pmysqlr00t -NBe 'SELECT CONCAT("MySQL ", VERSION())' 2>/dev/null)"

    post_id="$(docker exec "${legacy_c}" wp --allow-root --path="${wp_path}" post create \
        --post_title='Release gate marker' --post_status=publish --porcelain)"
    upload_marker="$(openssl rand -hex 8)"
    docker exec "${legacy_c}" sh -c "mkdir -p '${wp_path}/wp-content/uploads' && printf '%s' '${upload_marker}' > '${wp_path}/wp-content/uploads/release-gate-marker'"
    salt_hash="$(docker exec "${legacy_c}" wp --allow-root --path="${wp_path}" config get AUTH_KEY | sha256sum | cut -d' ' -f1)"
    docker exec "${legacy_c}" mysql -uroot -pmysqlr00t -e \
        "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY 'mysqlr00t'; FLUSH PRIVILEGES;" \
        || fail "${label}: could not switch root to mysql_native_password"
    docker exec "${legacy_c}" mysqladmin -uroot -pmysqlr00t shutdown >/dev/null 2>&1 || true
    sleep 5
    docker rm -f "${legacy_c}" >/dev/null
    error_log_offset="$(stat -c %s "${data_dir}/logs/mysql/error.log" 2>/dev/null || echo 0)"

    launch "${upgrade_c}" "${data_dir}" "${image_ref}"
    check_core_updates "${upgrade_c}" 7.1.2
    # The entrypoint keeps waiting for mysqld while these messages show an
    # upgrade in progress, so check that real MySQL writes them as expected.
    upgrade_log="$(docker exec "${upgrade_c}" tail -c "+$((error_log_offset + 1))" /home/appbox/logs/mysql/error.log)"
    grep -Eq "Server upgrade from '[0-9]+' to '[0-9]+' started" <<<"${upgrade_log}" \
        || fail "${label}: MySQL did not log the start of its server upgrade as the entrypoint expects"
    grep -Eq "Server upgrade from '[0-9]+' to '[0-9]+' completed" <<<"${upgrade_log}" \
        || fail "${label}: MySQL did not log the end of its server upgrade as the entrypoint expects"
    grep -E "Data dictionary upgrading|Server upgrade from" <<<"${upgrade_log}" | sed "s/^/${label}: /"
    [[ "$(docker exec "${upgrade_c}" wp --allow-root --path="${wp_path}" post get "${post_id}" --field=post_title)" == "Release gate marker" ]] \
        || fail "${label}: site content was not preserved"
    [[ "$(cat "${data_dir}/public_html/wp-content/uploads/release-gate-marker")" == "${upload_marker}" ]] \
        || fail "${label}: uploads were not preserved"
    [[ "$(docker exec "${upgrade_c}" wp --allow-root --path="${wp_path}" config get AUTH_KEY | sha256sum | cut -d' ' -f1)" == "${salt_hash}" ]] \
        || fail "${label}: authentication salts changed"
    [[ "$(docker exec "${upgrade_c}" mysql --protocol=socket --socket=/run/mysqld/mysqld.sock -uroot -pmysqlr00t -NBe \
        "SELECT plugin FROM mysql.user WHERE user = 'root' AND host = 'localhost'" 2>/dev/null)" == "mysql_native_password" ]] \
        || fail "${label}: root no longer logs in with mysql_native_password"
    docker exec "${upgrade_c}" mysql --protocol=socket --socket=/run/mysqld/mysqld.sock -uroot -pmysqlr00t -NBe 'SELECT VERSION()' 2>/dev/null \
        | grep -q '^8\.4\.' || fail "${label}: MySQL was not upgraded to 8.4"
    check_fpm_upload "${upgrade_c}"
    check_owned_by_app_user "${upgrade_c}"
    check_app_user_upload "${upgrade_c}"
    docker restart "${upgrade_c}" >/dev/null
    wait_ready "${upgrade_c}"
    docker rm -f "${upgrade_c}" >/dev/null
    echo "${label}: upgraded to ${release_ref##*:} with content, uploads, salts and the root login kept"
}

echo "== Mode: ${mode} (${image_ref}, release tag ${release_ref})"
[[ "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "${image_ref}")" == "linux/amd64" ]] \
    || fail "built image is not linux/amd64"
[[ "$(docker run --rm --entrypoint php "${image_ref}" -r \
    'include "/opt/wordpress-7.1.2/wp-includes/version.php"; echo $wp_version;')" == "7.1.2" ]] \
    || fail "staged core is not WordPress 7.1.2"

echo "== PHP 8.5 packages"
php85_min="$(docker image inspect --format '{{index .Config.Labels "net.cylo.wordpress.php85-min-version"}}' "${image_ref}")"
dockerfile_min="$(sed -n 's/^ARG PHP85_MIN_VERSION=//p' "${gate_dir}/Dockerfile")"
[[ -n "${php85_min}" ]] || fail "image was built without PHP85_MIN_VERSION"
if [[ "${mode}" == release ]]; then
    [[ "${php85_min}" == "${dockerfile_min}" ]] \
        || fail "image was built with PHP85_MIN_VERSION=${php85_min}, but the Dockerfile pins '${dockerfile_min}'"
else
    echo "TRIAL: built with PHP85_MIN_VERSION=${php85_min}; the Dockerfile pins '${dockerfile_min:-<unset>}'"
fi
docker run --rm --network none -v "${gate_dir}/release:/release:ro" --entrypoint sh "${image_ref}" \
    /release/check-php-packages.sh php8.5 "${php85_min}" \
    || fail "php8.5 packages are not all at ${php85_min} or newer"
docker run --rm --network none --entrypoint php-fpm8.5 "${image_ref}" -v | head -1
docker run --rm --network none --entrypoint php-fpm8.5 "${image_ref}" -t \
    || fail "php-fpm8.5 configuration test failed"

echo "== nginx packages"
nginx_min="$(docker image inspect --format '{{index .Config.Labels "net.cylo.wordpress.nginx-min-version"}}' "${image_ref}")"
dockerfile_nginx_min="$(sed -n 's/^ARG NGINX_MIN_VERSION=//p' "${gate_dir}/Dockerfile")"
[[ -n "${nginx_min}" ]] || fail "image was built without NGINX_MIN_VERSION"
if [[ "${mode}" == release ]]; then
    [[ "${nginx_min}" == "${dockerfile_nginx_min}" ]] \
        || fail "image was built with NGINX_MIN_VERSION=${nginx_min}, but the Dockerfile pins '${dockerfile_nginx_min}'"
fi
docker run --rm --network none -v "${gate_dir}/release:/release:ro" --entrypoint sh "${image_ref}" \
    /release/check-php-packages.sh nginx "${nginx_min}" \
    || fail "nginx packages are not all at ${nginx_min} or newer"
docker run --rm --network none --entrypoint nginx "${image_ref}" -v

echo "== PHP modules match the deployed 7.1.2-2 image"
docker pull --platform linux/amd64 "${deployed_ref}" >/dev/null
for sapi in php php-fpm8.5; do
    deployed_modules="$(docker run --rm --network none --entrypoint "${sapi}" "${deployed_ref}" -m)" \
        || fail "could not list ${sapi} modules of ${deployed_ref}"
    release_modules="$(docker run --rm --network none --entrypoint "${sapi}" "${image_ref}" -m)" \
        || fail "could not list ${sapi} modules of ${image_ref}"
    [[ -n "${deployed_modules}" ]] || fail "${deployed_ref} reported no ${sapi} modules"
    if [[ "${deployed_modules}" != "${release_modules}" ]]; then
        diff <(printf '%s\n' "${deployed_modules}") <(printf '%s\n' "${release_modules}") >&2 || true
        fail "${sapi} module list differs from the deployed 7.1.2-2 image"
    fi
    echo "${sapi}: $(printf '%s\n' "${release_modules}" | grep -cv -e '^\[' -e '^$') modules, identical to 7.1.2-2"
done

echo "== Multipart upload (built-in server)"
docker run --rm --network none -v "${gate_dir}/release:/release:ro" --entrypoint sh "${image_ref}" \
    /release/multipart-smoke.sh php8.5 \
    || fail "multipart upload smoke test failed"

echo "== Regression checks"
for check in "${gate_dir}"/release/regression/*.sh; do
    [[ -e "${check}" ]] || continue
    echo "-- $(basename "${check}")"
    docker run --rm --network none -v "${gate_dir}/release:/release:ro" --entrypoint sh "${image_ref}" \
        "/release/regression/$(basename "${check}")" \
        || fail "regression check $(basename "${check}") failed"
done

echo "== Core sync"

# Exercise both sides of the version guard without a customer database.
mkdir -p "${gate_root}/older/wp-includes" "${gate_root}/older/wp-content" \
    "${gate_root}/newer/wp-includes" "${gate_root}/newer/wp-content"
printf '%s\n' '<?php' "\$wp_version = '7.0.2';" > "${gate_root}/older/wp-includes/version.php"
printf '%s\n' '<?php' "\$wp_version = '99.0.0';" > "${gate_root}/newer/wp-includes/version.php"
touch "${gate_root}/older/wp-content/keep" "${gate_root}/newer/wp-content/keep"
docker run --rm --platform linux/amd64 \
    --entrypoint /usr/local/bin/sync-wordpress-core \
    -v "${gate_root}/older:/tmp/installed" \
    "${image_ref}" /opt/wordpress-7.1.2 /tmp/installed >/dev/null
[[ "$(docker run --rm --entrypoint php -v "${gate_root}/older:/tmp/installed" "${image_ref}" \
    -r 'include "/tmp/installed/wp-includes/version.php"; echo $wp_version;')" == "7.1.2" ]] \
    || fail "older core was not upgraded"
[[ -f "${gate_root}/older/wp-content/keep" ]] || fail "older site content was removed"
docker run --rm --platform linux/amd64 \
    --entrypoint /usr/local/bin/sync-wordpress-core \
    -v "${gate_root}/newer:/tmp/installed" \
    "${image_ref}" /opt/wordpress-7.1.2 /tmp/installed >/dev/null
[[ "$(docker run --rm --entrypoint php -v "${gate_root}/newer:/tmp/installed" "${image_ref}" \
    -r 'include "/tmp/installed/wp-includes/version.php"; echo $wp_version;')" == "99.0.0" ]] \
    || fail "newer automatically updated core was overwritten"
[[ -f "${gate_root}/newer/wp-content/keep" ]] || fail "newer site content was removed"

echo "== Fresh install and restart"
launch "${fresh_container}" "${gate_root}/fresh" "${image_ref}"
check_core_updates "${fresh_container}" 7.1.2
# Test the configuration files the entrypoint actually runs with.
docker exec "${fresh_container}" php-fpm8.5 -t --fpm-config /home/appbox/config/php-fpm/php-fpm.conf \
    || fail "php-fpm8.5 runtime configuration test failed"
docker exec "${fresh_container}" nginx -t -c /home/appbox/config/nginx/nginx.conf \
    || fail "nginx runtime configuration test failed"
check_fpm_upload "${fresh_container}"
[[ -n "$(docker exec "${fresh_container}" find "${wp_path}/wp-content/uploads" -mindepth 2 -maxdepth 2 -type d)" ]] \
    || fail "core install no longer creates an uploads folder; the ownership check below would not cover it"
check_owned_by_app_user "${fresh_container}"
check_app_user_upload "${fresh_container}"
fresh_config_hash="$(docker exec "${fresh_container}" sha256sum "${wp_path}/wp-config.php" | cut -d' ' -f1)"
docker restart "${fresh_container}" >/dev/null
wait_ready "${fresh_container}"
[[ "$(docker exec "${fresh_container}" sha256sum "${wp_path}/wp-config.php" | cut -d' ' -f1)" == "${fresh_config_hash}" ]] \
    || fail "restart changed WordPress configuration or salts"
check_owned_by_app_user "${fresh_container}"
docker rm -f "${fresh_container}" >/dev/null

# A MySQL minor-version bump makes the first start run a server upgrade, which
# took 4-6 minutes on loaded nodes. The entrypoint must keep waiting while
# mysqld is alive and upgrading, instead of giving up after
# MYSQL_START_TIMEOUT and restarting the container. MYSQL_START_TIMEOUT is
# shortened here so the stand-in's upgrade outlasts it.
echo "== Delayed MySQL readiness during a server upgrade"
write_mysqld_stand_in "${gate_root}/mysqld-stand-in"
stand_in=(--entrypoint /gate-mysqld/gate-entrypoint -v "${gate_root}/mysqld-stand-in:/gate-mysqld:ro")
start_container "${slow_mysql_container}" "${gate_root}/fresh" "${image_ref}" "${stand_in[@]}" \
    -e MYSQL_START_TIMEOUT=20 -e GATE_MYSQLD_DELAY=75
wait_ready "${slow_mysql_container}"
docker logs "${slow_mysql_container}" 2>&1 | grep -F "MySQL server upgrade still running" \
    || fail "${slow_mysql_container} did not wait past MYSQL_START_TIMEOUT for the upgrade"
docker logs "${slow_mysql_container}" 2>&1 | grep -F "MySQL server upgrade finished" \
    || fail "${slow_mysql_container} did not notice the end of the upgrade"
[[ "$(restart_count "${slow_mysql_container}")" == "0" ]] \
    || fail "${slow_mysql_container} restarted while MySQL was upgrading"
docker rm -f "${slow_mysql_container}" >/dev/null

# Without a restart policy, a failed start leaves the container stopped.
start_container "${dead_mysql_container}" "${gate_root}/fresh" "${image_ref}" "${stand_in[@]}" \
    -e MYSQL_START_TIMEOUT=600 -e GATE_MYSQLD_EXIT=1
wait_stopped "${dead_mysql_container}" 60
docker logs "${dead_mysql_container}" 2>&1 | grep -F "mysqld exited before accepting connections" \
    || fail "${dead_mysql_container} did not report that mysqld exited"
echo "mysqld exiting during an upgrade stops the container without waiting for MYSQL_START_TIMEOUT"
docker rm -f "${dead_mysql_container}" >/dev/null

start_container "${capped_mysql_container}" "${gate_root}/fresh" "${image_ref}" "${stand_in[@]}" \
    -e MYSQL_START_TIMEOUT=10 -e MYSQL_UPGRADE_TIMEOUT=30 -e GATE_MYSQLD_DELAY=600
wait_stopped "${capped_mysql_container}" 90
docker logs "${capped_mysql_container}" 2>&1 | grep -F "Timed out waiting for the MySQL server upgrade" \
    || fail "${capped_mysql_container} did not stop at MYSQL_UPGRADE_TIMEOUT"
echo "an upgrade that outlasts MYSQL_UPGRADE_TIMEOUT stops the container"
docker rm -f "${capped_mysql_container}" >/dev/null

echo "== Upgrade from 7.0.2"
docker pull --platform linux/amd64 "${baseline_ref}" >/dev/null
launch "${legacy_container}" "${gate_root}/upgrade" "${baseline_ref}"
[[ "$(docker exec "${legacy_container}" wp --allow-root --path="${wp_path}" core version)" == "7.0.2" ]] \
    || fail "legacy fixture has the wrong core version"
docker exec "${legacy_container}" mkdir -p "${wp_path}/wp-content/uploads"
docker exec "${legacy_container}" touch "${wp_path}/wp-content/uploads/release-gate-marker"
legacy_salt_hash="$(docker exec "${legacy_container}" wp --allow-root --path="${wp_path}" \
    config get AUTH_KEY | sha256sum | cut -d' ' -f1)"
docker rm -f "${legacy_container}" >/dev/null
launch "${upgrade_container}" "${gate_root}/upgrade" "${image_ref}"
check_core_updates "${upgrade_container}" 7.1.2
[[ -f "${gate_root}/upgrade/public_html/wp-content/uploads/release-gate-marker" ]] \
    || fail "legacy site content was not preserved"
[[ "$(docker exec "${upgrade_container}" wp --allow-root --path="${wp_path}" \
    config get AUTH_KEY | sha256sum | cut -d' ' -f1)" == "${legacy_salt_hash}" ]] \
    || fail "legacy authentication salts changed"
check_owned_by_app_user "${upgrade_container}"
check_app_user_upload "${upgrade_container}"
docker rm -f "${upgrade_container}" >/dev/null

echo "== Upgrade from the legacy wordpress:latest image (latest-4, Ubuntu 24.04)"
echo "NOT COVERED: the Ubuntu 20.04 / PHP 7.4 latest-4 image is no longer in the registry"
legacy_upgrade noble "${legacy_noble_ref}" "${noble_container}" "${noble_upgrade_container}"

echo "== Upgrade from the deployed 7.1.2-2 image, with a root-owned file the container cannot change"
launch "${prev_container}" "${gate_root}/prev" "${deployed_ref}"
docker exec "${prev_container}" mkdir -p "${wp_path}/wp-content/uploads"
docker exec "${prev_container}" touch "${wp_path}/wp-content/uploads/release-gate-marker"
prev_salt_hash="$(docker exec "${prev_container}" wp --allow-root --path="${wp_path}" \
    config get AUTH_KEY | sha256sum | cut -d' ' -f1)"
docker rm -f "${prev_container}" >/dev/null
# Stands in for plugins that create files when WordPress loads. Setup's
# wp-cli calls run as root, so the folder this one creates must end up owned
# by the app user too. Only `wp core update-db` creates it: setup runs that,
# and the gate never does, so the gate's own wp-cli calls as root, which poll
# while setup runs, cannot create it first. It is written without loading
# WordPress.
wp_cli_created_rel="wp-content/uploads/gate-created-by-wp-cli"
docker run --rm -i --platform linux/amd64 --network none --entrypoint sh \
    -v "${gate_root}/prev/public_html:/site" "${image_ref}" \
    -c 'mkdir -p /site/wp-content/mu-plugins && cat > /site/wp-content/mu-plugins/gate-created-by-wp-cli.php' <<'PHP'
<?php
if (defined('WP_CLI') && WP_CLI && in_array('update-db', $GLOBALS['argv'] ?? [], true)) {
    wp_mkdir_p(WP_CONTENT_DIR . '/uploads/gate-created-by-wp-cli');
}
PHP
# In production, files owned by root on the host sit outside the container's
# user namespace, so its chown and chmod fail with EPERM. The builder has no
# user namespace remapping and its virtiofs has no immutable flag, so a
# root-owned, read-only bind mount stands in: chown and chmod fail on it with
# EROFS. Its mode also differs from the 0664 startup wants in wp-content.
root_owned_rel="wp-content/plugins/gate-root-owned/gate-root-owned.php"
mkdir -p "${gate_root}/root-owned"
docker run --rm --platform linux/amd64 --network none --entrypoint sh \
    -v "${gate_root}/root-owned:/fixture" "${image_ref}" \
    -c 'printf "<?php\n" > /fixture/gate-root-owned.php && chown 0:0 /fixture/gate-root-owned.php && chmod 0600 /fixture/gate-root-owned.php'
launch "${prev_upgrade_container}" "${gate_root}/prev" "${image_ref}" \
    -v "${gate_root}/root-owned/gate-root-owned.php:${wp_path}/${root_owned_rel}:ro"
check_core_updates "${prev_upgrade_container}" 7.1.2
check_fpm_upload "${prev_upgrade_container}"
[[ -f "${gate_root}/prev/public_html/wp-content/uploads/release-gate-marker" ]] \
    || fail "7.1.2-2 site content was not preserved"
[[ "$(docker exec "${prev_upgrade_container}" wp --allow-root --path="${wp_path}" \
    config get AUTH_KEY | sha256sum | cut -d' ' -f1)" == "${prev_salt_hash}" ]] \
    || fail "7.1.2-2 authentication salts changed"
[[ "$(docker exec "${prev_upgrade_container}" stat -c '%u %a' "${wp_path}/${root_owned_rel}")" == "0 600" ]] \
    || fail "the read-only root-owned fixture changed; it no longer tests an unchangeable file"
# Docker created the fixture's parent directory as root; startup must re-own it.
[[ "$(docker exec "${prev_upgrade_container}" stat -c '%U:%G %a' "$(dirname "${wp_path}/${root_owned_rel}")")" == "appbox:appbox 775" ]] \
    || fail "startup did not fix the changeable directory around the root-owned file"
docker logs "${prev_upgrade_container}" 2>&1 | grep -F "Left unchanged: " | grep -F "${root_owned_rel}" \
    || fail "startup did not log the root-owned file it could not change"
docker exec "${prev_upgrade_container}" test -d "${wp_path}/${wp_cli_created_rel}" \
    || fail "setup's wp core update-db did not load the must-use plugin fixture"
check_owned_by_app_user "${prev_upgrade_container}" "${root_owned_rel}"
check_app_user_upload "${prev_upgrade_container}"
# On a restart wordpress-setup, not the entrypoint, re-owns the WordPress root.
docker exec "${prev_upgrade_container}" sh -c \
    "touch '${wp_path}/wp-content/uploads/gate-restart-owner' && chown 0:0 '${wp_path}/wp-content/uploads/gate-restart-owner'"
docker restart "${prev_upgrade_container}" >/dev/null
wait_ready "${prev_upgrade_container}"
[[ "$(docker exec "${prev_upgrade_container}" stat -c '%U:%G' "${wp_path}/wp-content/uploads/gate-restart-owner")" == "appbox:appbox" ]] \
    || fail "restart did not re-own a root-owned file in public_html"
echo "7.1.2-2 site upgraded and restarted with an unchangeable root-owned file in public_html"
docker rm -f "${prev_upgrade_container}" >/dev/null

echo "== Registry tag must not exist"
# A 404 from the authenticated registry API proves the exact tag is unused.
python3 - "${release_ref}" <<'PY'
import json
import pathlib
import sys
import urllib.error
import urllib.request

config_path = pathlib.Path.home() / '.docker' / 'config.json'
try:
    auth = json.loads(config_path.read_text())['auths']['repo.cylo.net']['auth']
    if not auth:
        raise ValueError('empty registry authentication')
    request = urllib.request.Request(
        'https://repo.cylo.net/v2/wordpress/manifests/' + sys.argv[1].rsplit(':', 1)[1],
        headers={
            'Authorization': 'Basic ' + auth,
            'Accept': ','.join((
                'application/vnd.oci.image.index.v1+json',
                'application/vnd.oci.image.manifest.v1+json',
                'application/vnd.docker.distribution.manifest.v2+json',
            )),
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            raise RuntimeError(f'tag already exists (HTTP {response.status})')
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise RuntimeError(f'registry returned HTTP {error.code}') from error
        body = error.read(4096).decode('utf-8', 'replace')
        if 'MANIFEST_UNKNOWN' not in body:
            raise RuntimeError(f'registry returned 404 without MANIFEST_UNKNOWN: {body[:300]}') from error
except Exception as error:
    print(f'Registry precondition failed: {error}', file=sys.stderr)
    sys.exit(1)

print(f'Authenticated registry confirms {sys.argv[1]} is not in the registry yet')
PY

echo "PASS (${mode}): WordPress ${release_ref##*:} release gate passed for ${image_ref}"
