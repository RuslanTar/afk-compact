#!/bin/sh
# A minimal queue_cmd for afk-compact (assets/queue-contract.md): each queued question is one file,
# <folder>/<session id>/<client id>.json, holding the draft as sent. The folder is $QUEUE_DIR,
# default ~/.local/state/my-questions. Supports list and add; adopt answers "unsupported" (exit 2).
# Copy it, set queue_cmd to the copy's full path, then run `queue check` (README).
umask 077
dir=${QUEUE_DIR:-$HOME/.local/state/my-questions}
cmd=$1 sid= cid=
[ $# -gt 0 ] && shift
while [ $# -gt 0 ]; do
  case $1 in
    --json) ;;
    --session|--client-id|--lane-name) [ $# -ge 2 ] || exit 2
      case $1 in --session) sid=$2 ;; --client-id) cid=$2 ;; esac; shift ;;
    *) exit 2 ;;
  esac
  shift
done
case $sid in ''|*[!A-Za-z0-9_-]*) exit 2 ;; esac
case $cmd in
  list)
    ids= n=0
    for f in "$dir/$sid"/ck-*.json; do
      [ -f "$f" ] || continue
      f=${f##*/}; ids="$ids${ids:+,}\"${f%.json}\""; n=$((n + 1))
    done
    printf '{"schema":"queue-stub/v1","session":"%s","lane":"auto:my-questions/%s","label":"my questions","open":[%s],"pending":%d,"preview":false,"held_by":null,"commands":["list","add"]}\n' \
      "$sid" "$sid" "$ids" "$n" ;;
  add)
    case $cid in ck-????????????) ;; *) echo 'REFUSED: draft: client id'; exit 5 ;; esac
    case ${cid#ck-} in *[!0-9a-f]*) echo 'REFUSED: draft: client id'; exit 5 ;; esac
    f=$dir/$sid/$cid.json st=exists
    if [ ! -f "$f" ]; then
      mkdir -p "$dir/$sid" && cat > "$f.tmp" && mv "$f.tmp" "$f" || { echo 'REFUSED: store: not written'; exit 6; }
      st=queued
    fi
    printf '{"status":"%s","id":"%s"}\n' "$st" "$cid" ;;
  *) exit 2 ;;
esac
