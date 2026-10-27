#!/bin/sh
# tests/launcher/docker.sh: the launcher cases (tests/launcher/run.sh) on Linux, in Docker:
# no network, no credentials, the repo mounted read-only, a read-only root and a fresh /tmp.
#
#   tests/launcher/docker.sh [IMAGE...] [-- RUN.SH ARGS...]
#   tests/launcher/docker.sh --build-alpine
#
# IMAGE defaults to two images:
#   debian:bookworm-slim     dash as /bin/sh, bash, util-linux script, perl (docker pull it once)
#   launcher-test-alpine:1   busybox ash as /bin/sh, zsh, util-linux script, perl: built here from
#                            tests/launcher/alpine.Dockerfile with --build-alpine (the one step
#                            that uses the network: it pulls alpine and its packages)
# Another image needs sh, perl, script(1) and setpriv(1). Nothing is pulled while the cases
# run: an image that is not present locally is an error. Inside, a root step makes a folder
# owned by root for the real foreign-owner case (AT-RS-40d), then the suite runs as uid 1000 so
# file modes count. Arguments after `--` go to run.sh (case ids, --quick).
# Exit: 0 every image passed; 1 a case failed; 2 docker or an image is missing.
set -u
repo=$(cd "$(dirname "$0")/../.." && pwd -P)
here=$repo/tests/launcher
alpine=launcher-test-alpine:1
if [ "${1-}" = --build-alpine ]; then
  docker build -t "$alpine" -f "$here/alpine.Dockerfile" "$here"
  exit $?
fi
images=
while [ $# -gt 0 ]; do
  case $1 in
  --) shift; break ;;
  *) images="$images $1"; shift ;;
  esac
done
[ -n "$images" ] || images="debian:bookworm-slim $alpine"
if ! docker info >/dev/null 2>&1; then
  echo "docker.sh: docker is not running or not installed" >&2
  exit 2
fi
for img in $images; do
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    if [ "$img" = "$alpine" ]; then
      echo "docker.sh: image $img is not present locally (tests/launcher/docker.sh --build-alpine)" >&2
    else
      echo "docker.sh: image $img is not present locally (docker pull $img)" >&2
    fi
    exit 2
  fi
done
status=0
for img in $images; do
  echo "# image $img"
  docker run --rm --network none --read-only --tmpfs /tmp:rw,exec,nosuid,size=256m \
    -v "$repo:/repo:ro" --entrypoint /bin/sh "$img" /repo/tests/launcher/in-docker.sh "$@"
  rc=$?
  if [ $rc -ne 0 ]; then
    echo "# image $img: exit $rc"
    status=1
  fi
done
exit $status
