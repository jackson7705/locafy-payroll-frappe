#!/bin/bash
# Runs as root: fixes volume ownership, then runs everything as the frappe user.
set -e
BENCH=/home/frappe/frappe-bench
mkdir -p $BENCH/sites $BENCH/logs
chown -R frappe:frappe $BENCH/sites $BENCH/logs
exec runuser -u frappe -- /usr/local/bin/frappe-boot.sh
