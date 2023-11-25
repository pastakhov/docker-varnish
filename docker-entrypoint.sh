#!/bin/bash

set -x

wait_varnish() {
    while ! nc -z localhost 80 ; do sleep 1 ; done
    sleep 1
}

if [ -z "$VARNISH_STORAGE_SPECIFICATION" ]; then
    if [ "$VARNISH_STORAGE_KIND" == "file" ]; then
        chown vcache "$VARNISH_STORAGE_FILE"
        VARNISH_STORAGE_SPECIFICATION="$VARNISH_STORAGE_KIND,$VARNISH_STORAGE_FILE,$VARNISH_SIZE"
    else
        VARNISH_STORAGE_SPECIFICATION="$VARNISH_STORAGE_KIND,$VARNISH_SIZE"
    fi
fi

CMD_ARGS=("-F" "-P" "/var/run/varnishd.pid" "-f" "$VARNISH_CONFIG" "-s" "$VARNISH_STORAGE_SPECIFICATION")

if [ -n "$VARNISH_LOG_DIR" ]; then
    (wait_varnish && varnishncsa | /usr/bin/rotatelogs -c -f -l -p /rotatelogs-compress.sh -L "$VARNISH_LOG_DIR/access_log.current" "$VARNISH_LOG_DIR/access_log_%Y%m%d" 86400) &
fi

if [ -f "$VARNISH_SECRET" ]; then
    CMD_ARGS+=("-S" "$VARNISH_SECRET" "-T" "127.0.0.1:6082")
    (wait_varnish && prometheus_varnish_exporter) &
fi

/usr/sbin/varnishd "${CMD_ARGS[@]}"
