#!/bin/sh
# tests/launcher/in-docker.sh: docker.sh's step inside the container, started as root. It makes
# /tmp/foreign/<brand> owned by root (mode 0700) for AT-RS-40d (a cache folder whose runtime
# folder another user owns), then runs run.sh as uid 1000 with HOME and TMPDIR in /tmp/t.
set -eu
brand=$(sed -n 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"\([a-z0-9-]*\)".*/\1/p' /repo/brand.json | head -n 1)
mkdir -p /tmp/foreign /tmp/t
chmod 755 /tmp/foreign
mkdir -m 700 "/tmp/foreign/$brand"
chown 1000:1000 /tmp/t
echo "# $(uname -sr), /bin/sh -> $(ls -l /bin/sh | sed 's/.* -> //'), $(script --version 2>&1 | head -n 1)"
exec setpriv --reuid=1000 --regid=1000 --clear-groups \
  env HOME=/tmp/t TMPDIR=/tmp/t LAUNCHER_TEST_FOREIGN_BASE=/tmp/foreign \
  sh /repo/tests/launcher/run.sh "$@"
