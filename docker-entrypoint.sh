#!/bin/bash

set -x

wait_varnish() {
    while ! nc -z localhost 80 ; do sleep 1 ; done
    sleep 1
}

rm /var/run/varnishd.pid /var/run/varnishncsa.pid

if [ -z "$VARNISH_STORAGE_SPECIFICATION" ]; then
    if [ "$VARNISH_STORAGE_KIND" == "file" ]; then
        chown vcache "$VARNISH_STORAGE_FILE"
        VARNISH_STORAGE_SPECIFICATION="$VARNISH_STORAGE_KIND,$VARNISH_STORAGE_FILE,$VARNISH_SIZE"
    else
        VARNISH_STORAGE_SPECIFICATION="$VARNISH_STORAGE_KIND,$VARNISH_SIZE"
    fi
fi

CMD_ARGS=("-F" "-P" "/var/run/varnishd.pid" "-f" "$VARNISH_CONFIG" "-s" "$VARNISH_STORAGE_SPECIFICATION")
if [ "$VARNISH_LOG_FORMAT" == "X-Forwarded-For" ]; then
    VARNISH_LOG_FORMAT='%{X-Forwarded-For}i %l %u %t "%r" %s %b "%{Referer}i" "%{User-agent}i"'
elif [ "$VARNISH_LOG_FORMAT" == "X-Real-IP" ]; then
    VARNISH_LOG_FORMAT='%{X-Real-IP}i %l %u %t "%r" %s %b "%{Referer}i" "%{User-agent}i"'
else
    VARNISH_LOG_FORMAT=${VARNISH_LOG_FORMAT:-'%h %l %u %t "%r" %s %b "%{Referer}i" "%{User-agent}i"'}
fi

if [ -n "$VARNISH_LOG_DIR" ]; then
    (wait_varnish && varnishncsa -F "$VARNISH_LOG_FORMAT" -P /var/run/varnishncsa.pid -a -w "$VARNISH_LOG_DIR/access_log" -D) &
fi

if [ -f "$VARNISH_SECRET" ]; then
    CMD_ARGS+=("-S" "$VARNISH_SECRET" "-T" "127.0.0.1:6082")
    (wait_varnish && prometheus_varnish_exporter) &
fi

/usr/sbin/varnishd "${CMD_ARGS[@]}"
