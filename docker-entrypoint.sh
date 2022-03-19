#!/bin/bash

set -x

if [ -z "$VARNISH_STORAGE_SPECIFICATION" ]; then
    if [ "$VARNISH_STORAGE_KIND" == "file" ]; then
        chown vcache "$VARNISH_STORAGE_FILE"
        VARNISH_STORAGE_SPECIFICATION="$VARNISH_STORAGE_KIND,$VARNISH_STORAGE_FILE,$VARNISH_SIZE"
    else
        VARNISH_STORAGE_SPECIFICATION="$VARNISH_STORAGE_KIND,$VARNISH_SIZE"
    fi
fi

/usr/sbin/varnishd -F \
    -P /var/run/varnishd.pid \
    -f "$VARNISH_CONFIG" \
    -S /etc/varnish/secret \
    -T 127.0.0.1:6082 \
    -s "$VARNISH_STORAGE_SPECIFICATION" \
    & (sleep 15 && prometheus_varnish_exporter)
