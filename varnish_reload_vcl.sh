#!/bin/bash

# Generate a unique timestamp ID for this version of the VCL
TIME=$(date +%s)

# Load the file into memory
varnishadm -S /etc/varnish/secret -T 127.0.0.1:6082 vcl.load varnish_"$TIME" "$VARNISH_CONFIG"

# Active this Varnish config
varnishadm -S /etc/varnish/secret -T 127.0.0.1:6082 vcl.use varnish_"$TIME"
