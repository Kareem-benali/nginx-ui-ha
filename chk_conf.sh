#!/usr/bin/env bash
# chk_conf.sh — exits 0 when the on-disk nginx configuration is valid.
# Catches "process alive but config broken after a failed sync" cases.
nginx -t >/dev/null 2>&1
exit $?