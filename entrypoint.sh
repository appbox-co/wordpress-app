#!/bin/bash
set -Eeuo pipefail

CORE_PATH="${WP_CORE_PATH:-/home/appbox/public_html}"
MYSQL_SOCKET="/run/mysqld/mysqld.sock"
MYSQL_ERROR_LOG="/home/appbox/logs/mysql/error.log"
# Seconds to wait for mysqld to accept connections. While mysqld is alive and
# running a server upgrade, the wait goes on up to MYSQL_UPGRADE_TIMEOUT.
MYSQL_START_TIMEOUT="${MYSQL_START_TIMEOUT:-240}"
MYSQL_UPGRADE_TIMEOUT="${MYSQL_UPGRADE_TIMEOUT:-3600}"
CALLBACK_PENDING_FILE="/etc/appbox-wordpress-callback.pending"
PIDS=()

log() {
    echo "[entrypoint] $*"
}

# shellcheck source=scripts/permissions.sh
source /usr/local/lib/wordpress/permissions.sh

prepare_runtime() {
    mkdir -p \
        /home/appbox/config/nginx/sites-enabled \
        /home/appbox/config/nginx/modules-enabled \
        /home/appbox/config/php-fpm/pool.d \
        /home/appbox/config/mysql \
        /home/appbox/logs/nginx \
        /home/appbox/logs/mysql \
        /home/appbox/mysql/data \
        /home/appbox/mysql/run \
        /home/appbox/public_html \
        /var/lib/mysql-files \
        /run/mysqld \
        /run/php \
        /tmp

    cp /usr/local/share/wordpress/nginx.conf /home/appbox/config/nginx/nginx.conf
    cp /usr/local/share/wordpress/php-fpm.conf /home/appbox/config/php-fpm/php-fpm.conf
    cp /usr/local/share/wordpress/www.conf /home/appbox/config/php-fpm/pool.d/www.conf
    cp /usr/local/share/wordpress/mysqld.cnf /home/appbox/config/mysql/mysqld.cnf
    cp /etc/nginx/fastcgi_params /home/appbox/config/nginx/fastcgi_params

    touch "${MYSQL_ERROR_LOG}"
    fix_ownership /home/appbox /run/mysqld /run/php /var/lib/mysql-files
    chmod 0775 /run/mysqld /run/php /home/appbox/mysql/run /var/lib/mysql-files
}

shutdown() {
    log "Stopping services"
    mysqladmin --protocol=socket --socket="${MYSQL_SOCKET}" --user=root --password="${MYSQL_ROOT_PASSWORD:-mysqlr00t}" shutdown >/dev/null 2>&1 || true
    for pid in "${PIDS[@]:-}"; do
        kill "${pid}" >/dev/null 2>&1 || true
    done
    wait >/dev/null 2>&1 || true
}

mysql_ping() {
    mysqladmin --protocol=socket --socket="${MYSQL_SOCKET}" --user=root --password="${MYSQL_ROOT_PASSWORD:-mysqlr00t}" ping >/dev/null 2>&1 \
        || mysqladmin --protocol=socket --socket="${MYSQL_SOCKET}" --user=root ping >/dev/null 2>&1
}

process_alive() {
    local stat

    kill -0 "$1" 2>/dev/null || return 1
    # An exited child that has not been reaped yet still answers kill -0.
    read -r stat 2>/dev/null < "/proc/$1/stat" || return 1
    stat="${stat##*) }"
    [[ "${stat%% *}" != "Z" ]]
}

# True while the mysqld that started writing to the error log at byte offset
# $1 has begun an upgrade and not logged the end of its server upgrade. MySQL
# logs "Data dictionary upgrading from version ..." (when the data dictionary
# changes), then "Server upgrade from '80411' to '80413' started." and
# "... completed.".
mysql_upgrade_running() {
    local new_log

    new_log="$(tail -c "+$(($1 + 1))" "${MYSQL_ERROR_LOG}" 2>/dev/null)" || return 1
    grep -Eq "Data dictionary upgrading from version|Server upgrade from '[0-9]+' to '[0-9]+' started" <<<"${new_log}" \
        && ! grep -Eq "Server upgrade from '[0-9]+' to '[0-9]+' completed" <<<"${new_log}"
}

# Wait for mysqld (pid $1, error log offset $2) to accept connections, and
# fail at once if it exits. After MYSQL_START_TIMEOUT seconds keep waiting only
# while it is running a server upgrade, up to MYSQL_UPGRADE_TIMEOUT in all. The
# first start after the image moves to a newer MySQL runs one, which took 4-6
# minutes on loaded nodes; giving up then SIGTERMs mysqld, which finishes the
# upgrade first, and the container restarts for nothing. When an upgrade ends
# past the first timeout, mysqld gets MYSQL_START_TIMEOUT again to finish
# starting.
wait_for_mysql() {
    local mysqld_pid="$1" log_offset="$2" started="${SECONDS}"
    local deadline=$((SECONDS + MYSQL_START_TIMEOUT)) upgrading=0

    while true; do
        if mysql_ping; then
            return 0
        fi
        if ! process_alive "${mysqld_pid}"; then
            echo "mysqld exited before accepting connections; see ${MYSQL_ERROR_LOG}" >&2
            return 1
        fi
        if (( SECONDS >= deadline )); then
            if mysql_upgrade_running "${log_offset}"; then
                if (( SECONDS - started >= MYSQL_UPGRADE_TIMEOUT )); then
                    echo "Timed out waiting for the MySQL server upgrade after $((SECONDS - started))s" >&2
                    return 1
                fi
                if [[ "${upgrading}" == "0" ]]; then
                    log "MySQL server upgrade still running after $((SECONDS - started))s; waiting up to ${MYSQL_UPGRADE_TIMEOUT}s while mysqld is alive"
                    upgrading=1
                fi
            elif [[ "${upgrading}" == "1" ]]; then
                log "MySQL server upgrade finished after $((SECONDS - started))s; waiting for mysqld to accept connections"
                deadline=$((SECONDS + MYSQL_START_TIMEOUT))
                upgrading=0
            else
                echo "Timed out waiting for MySQL after $((SECONDS - started))s" >&2
                return 1
            fi
        fi
        sleep 2
    done
}

start_mysql() {
    rm -f /home/appbox/mysql/run/mysqld.pid /run/mysqld/mysqld.sock /run/mysqld/mysqld.sock.lock

    if [[ ! -d /home/appbox/mysql/data/mysql || ! -f /home/appbox/mysql/data/mysql.ibd ]]; then
        log "Initializing fresh MySQL data directory"
        rm -rf /home/appbox/mysql/data/*
        if [[ -n "${MYSQL_DATA_TEMPLATE:-}" && -d "${MYSQL_DATA_TEMPLATE}/mysql" ]]; then
            cp -a "${MYSQL_DATA_TEMPLATE}/." /home/appbox/mysql/data/
        else
            mysqld --defaults-file=/home/appbox/config/mysql/mysqld.cnf --initialize-insecure --user=appbox 2>&1 | tee -a /home/appbox/logs/mysql/error.log &
            init_pid="$!"
            init_ready=0
            for _ in $(seq 1 300); do
                if [[ -f /home/appbox/mysql/data/mysql.ibd ]] \
                    && grep -q "A root@localhost is created with an empty password" /home/appbox/logs/mysql/error.log; then
                    init_ready=1
                    break
                fi
                if ! kill -0 "${init_pid}" >/dev/null 2>&1; then
                    wait "${init_pid}" || true
                    if [[ -f /home/appbox/mysql/data/mysql.ibd ]]; then
                        init_ready=1
                    fi
                    break
                fi
                sleep 1
            done
            if kill -0 "${init_pid}" >/dev/null 2>&1; then
                kill "${init_pid}" >/dev/null 2>&1 || true
                wait "${init_pid}" >/dev/null 2>&1 || true
            fi
            if [[ "${init_ready}" != "1" ]]; then
                echo "MySQL initialization did not complete" >&2
                exit 1
            fi
        fi
    fi
    fix_ownership /home/appbox/mysql /run/mysqld

    log_offset="$(stat -c %s "${MYSQL_ERROR_LOG}" 2>/dev/null || echo 0)"
    /usr/sbin/mysqld --defaults-file=/home/appbox/config/mysql/mysqld.cnf --verbose=0 --socket="${MYSQL_SOCKET}" &
    mysqld_pid="$!"
    PIDS+=("${mysqld_pid}")
    wait_for_mysql "${mysqld_pid}" "${log_offset}"
    log "MySQL is accepting connections"

    if mysql --protocol=socket --socket="${MYSQL_SOCKET}" --user=root -NBe "SELECT 1" >/dev/null 2>&1; then
        mysql --protocol=socket --socket="${MYSQL_SOCKET}" --user=root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD:-mysqlr00t}'; FLUSH PRIVILEGES;" >/dev/null 2>&1 \
            || mysql --protocol=socket --socket="${MYSQL_SOCKET}" --user=root -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD:-mysqlr00t}'; FLUSH PRIVILEGES;" >/dev/null 2>&1 \
            || true
    elif ! mysql --protocol=socket --socket="${MYSQL_SOCKET}" --user=root --password="${MYSQL_ROOT_PASSWORD:-mysqlr00t}" -NBe "SELECT 1" >/dev/null 2>&1; then
        mysql --protocol=socket --socket="${MYSQL_SOCKET}" --user=root -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD:-mysqlr00t}'; FLUSH PRIVILEGES;" >/dev/null 2>&1 \
            || mysql --protocol=socket --socket="${MYSQL_SOCKET}" --user=root -e "ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD:-mysqlr00t}'; FLUSH PRIVILEGES;" >/dev/null 2>&1 \
            || true
    fi
    mysql --protocol=socket --socket="${MYSQL_SOCKET}" --user=root --password="${MYSQL_ROOT_PASSWORD:-mysqlr00t}" -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME:-wordpress}\`;" \
        || mysql --protocol=socket --socket="${MYSQL_SOCKET}" --user=root -e "CREATE DATABASE IF NOT EXISTS \`${DB_NAME:-wordpress}\`;"
}

start_php_fpm() {
    php_fpm_bin="$(command -v php-fpm || find /usr/sbin -maxdepth 1 -type f -name 'php-fpm*' | sort -V | tail -1)"
    if [[ -z "${php_fpm_bin}" ]]; then
        echo "Unable to find php-fpm binary" >&2
        exit 1
    fi
    "${php_fpm_bin}" --nodaemonize --fpm-config /home/appbox/config/php-fpm/php-fpm.conf &
    PIDS+=("$!")
}

start_nginx() {
    nginx -c /home/appbox/config/nginx/nginx.conf -g "daemon off;" &
    PIDS+=("$!")
}

callback_installed() {
    if [[ ! -f "${CALLBACK_PENDING_FILE}" ]]; then
        return 0
    fi

    for _ in $(seq 1 120); do
        if wp --allow-root --path="${CORE_PATH}" core is-installed >/dev/null 2>&1 \
            && curl -fsS --max-time 5 http://127.0.0.1/appbox-health >/dev/null 2>&1; then
            break
        fi
        sleep 2
    done

    if [[ "${SKIP_APPBOX_CALLBACK:-0}" == "1" || -z "${INSTANCE_ID:-}" ]]; then
        rm -f "${CALLBACK_PENDING_FILE}"
        return 0
    fi

    headers=(-H "Accept: application/json" -H "Content-Type:application/json")
    if [[ -n "${CALLBACK_TOKEN:-}" ]]; then
        headers+=(-H "X-Cylo-Callback-Token: ${CALLBACK_TOKEN}")
    fi

    until curl -fsS -o /dev/null "${headers[@]}" -X POST "https://api.cylo.net/v1/apps/installed/${INSTANCE_ID}"; do
        sleep 5
    done

    rm -f "${CALLBACK_PENDING_FILE}"
}

trap shutdown TERM INT EXIT

prepare_runtime
start_mysql
/usr/local/bin/wordpress-setup
start_php_fpm
start_nginx
callback_installed &

wait -n "${PIDS[@]}"
exit $?
