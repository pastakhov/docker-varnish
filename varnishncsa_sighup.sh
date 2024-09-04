#!/bin/bash

pid=$(</var/run/varnishncsa.pid)

kill -s SIGHUP "$pid"
