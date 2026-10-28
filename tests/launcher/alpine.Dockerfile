# tests/launcher/alpine.Dockerfile: the Linux image of the launcher cases with busybox ash as
# /bin/sh and zsh (tests/launcher/docker.sh --build-alpine builds it; the one step that needs
# the network). perl starts each launcher with default signals, util-linux script gives it a
# terminal, setpriv drops to uid 1000. No getfacl: busybox ls shows no ACL, the stated limit.
FROM alpine:3.20
RUN apk add --no-cache perl util-linux-misc setpriv zsh
