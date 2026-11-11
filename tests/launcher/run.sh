#!/bin/sh
# tests/launcher/run.sh: the restart launcher's acceptance cases (README.md here,
# AT-RS-30..40 and 43) for plugin/scripts/<brand>-claude, with a stub claude and hand-written
# launch notes (tests/launcher/notes), under every POSIX shell found.
#
#   tests/launcher/run.sh [--shell "SHELL WORDS"]... [--quick] [CASE...]
#
# Shells: by default /bin/sh, bash, dash, zsh (the launcher runs itself as sh) and busybox sh,
# each one found, once (a link to one already listed is skipped). The shells run in parallel.
# CASE limits the run to case ids starting with it (AT-RS-34, AT-RS-36c). --quick skips the
# one slow case (AT-RS-36c, a relaunched claude that fails after 16 s).
# Needs: script(1) for a terminal (BSD script on macOS, util-linux or busybox script on Linux)
# and perl (it starts each launcher with SIGINT at its default, whatever this shell inherited,
# and bounds each case's time). Cases that need a terminal are skipped where script is missing.
# Writes only under one new folder in ${TMPDIR:-/tmp} (kept when a case fails; removed, with
# every run stopped, on INT, TERM or HUP); never into the repo, which may be read-only
# (tests/launcher/docker.sh mounts it so).
# LAUNCHER_TEST_FOREIGN_BASE (set by docker.sh): a cache folder holding <brand> that another
# user owns, for the real foreign-owner case; without it that case uses a stub id. Each case
# has its own HOME (its cache folder HOME/.cache, 0700) and TMPDIR.
# --hg-inner (given by AT-RS-30e and AT-RS-30f to their own inner runs of this file, which print
# `# inner run`): AT-RS-30e checks what claude got, AT-RS-30f passes, instead of starting that
# inner run. An argument, not a variable: a value left in the environment would make both no-ops.
# Output: TAP lines (`ok N - <shell> <case> <title>`), then `# passed N, failed M, skipped K`.
# Exit 0 when nothing failed, else 1.
set -u
# HOME-GUARD: this file writes only under one new folder in ${TMPDIR:-/tmp}, so that folder is
# checked first, before anything is made, while the caller's CLAUDE_CONFIG_DIR and XDG folders are
# still set: a TMPDIR that is relative (read against whatever folder a shell is in), has a `..`
# part (the kernel applies it after links: $T/L/.. with L a link into ~/.claude is ~/.claude),
# lies at or under $HOME/.claude, the CLAUDE_CONFIG_DIR given (a leading ~ read as $HOME),
# $HOME/.local, $HOME/.cache, $HOME/.config, the same four of the account's home (getpwuid) or a
# given XDG_STATE_HOME, XDG_CACHE_HOME, XDG_CONFIG_HOME or XDG_DATA_HOME, or lies at or above
# $HOME or the account's home ends the run,
# exit 2 (XDG_RUNTIME_DIR is no state folder: TMPDIR may lie under it). As the helper runners'
# guard (tests/helper/homeguard.pm) does, perl compares by real path (links resolved) and by
# device and inode, each parent in turn: a case-insensitive file system reads $HOME/.Claude/t as
# $HOME/.claude/t, which pwd -P keeps as typed. A HOME that is not the account's home and lies
# strictly under /tmp or TMPDIR is a throwaway one (tests/launcher/in-docker.sh: HOME and TMPDIR
# /tmp/t; on macOS a HOME made with `mktemp -d` lies under TMPDIR) and is not read as one TMPDIR
# may not hold; the account's home always is. AT-RS-30f.
if ! command -v perl >/dev/null 2>&1; then
  echo "run.sh: perl is needed (it checks TMPDIR and starts each launcher with default signal handling)" >&2
  exit 2
fi
hg_t=${TMPDIR:-/tmp}
case $hg_t in
/*) ;;
*) echo "run.sh: HOME-GUARD: TMPDIR $hg_t is not absolute; nothing written" >&2; exit 2 ;;
esac
case /$hg_t/ in
*/../*) echo "run.sh: HOME-GUARD: TMPDIR $hg_t has a .. part (applied after links); nothing written" >&2; exit 2 ;;
esac
# perl prints `in FOLDER` (the first folder TMPDIR lies at or under), `home HOME` (a home TMPDIR
# is at or above), `root` (TMPDIR is the file system root, by its real path) or `ok` on stdout;
# its stderr is not read (LC_ALL=C: no locale warning either)
hg_hit=$(LC_ALL=C perl -e '
use strict; use warnings; use Cwd ();
my ($t, $home, @dirs) = @ARGV;
my $acct = (getpwuid $<)[7];
$acct = "" unless defined $acct && $acct =~ m{\A/};
push @dirs, map { "$acct/$_" } qw(.claude .local .cache .config) if $acct ne "";
sub id { my @s = stat $_[0]; return @s ? "$s[0]:$s[1]" : "" }
sub real {
  my ($p) = @_;
  $p =~ s{(?<=.)/+\z}{};
  my @tail;
  while ($p ne "/" && !-e $p) { $p =~ s{/+([^/]*)\z}{}; unshift @tail, $1; $p = "/" if $p eq "" }
  my $r = Cwd::abs_path($p);
  $r = $p unless defined $r;
  return @tail ? join("/", ($r eq "/" ? "" : $r), @tail) : $r;
}
sub ups { my @u; for (my $d = $_[0]; $d ne ""; $d =~ s{/[^/]*\z}{}) { push @u, $d } return (@u, "/") }
my $rt = real($t);
# 0.1.3: the file system root holds every home, known or not, and every path (a TMPDIR of /)
if ($rt =~ m{\A/+\z}) { print "root"; exit 0 }
my $tid = id($rt);
for my $d (@dirs) {
  my $x = $d;
  $x =~ s{\A~(?=/|\z)}{$home} if $home ne "";
  next unless $x =~ m{\A/};
  my ($rd, $did) = (real($x), id($x));
  if (grep { $_ eq $rd || ($did ne "" && id($_) eq $did) } ups($rt)) { print "in $d"; exit 0 }
}
my @tw = grep { $_ ne "" } map { (my $x = real($_)) =~ s{/+\z}{}; $x } "/tmp", $t;
my $ra = $acct ne "" ? real($acct) : "";
my $aid = $ra ne "" ? id($ra) : "";
for my $h (grep { m{\A/} } $home, $acct) {
  my $rh = real($h);
  my $own = $ra ne "" && ($rh eq $ra || ($aid ne "" && id($rh) eq $aid));
  next if !$own && grep { index($rh, "$_/") == 0 } @tw;
  if (grep { $_ eq $rt || ($tid ne "" && id($_) eq $tid) } ups($rh)) { print "home $h"; exit 0 }
}
print "ok";
' "$hg_t" "${HOME-}" "${HOME:+$HOME/.claude}" "${CLAUDE_CONFIG_DIR-}" "${HOME:+$HOME/.local}" "${HOME:+$HOME/.cache}" \
  "${HOME:+$HOME/.config}" "${XDG_STATE_HOME-}" "${XDG_CACHE_HOME-}" "${XDG_CONFIG_HOME-}" "${XDG_DATA_HOME-}")
case $hg_hit in
ok) ;;
"in "*)
  echo "run.sh: HOME-GUARD: TMPDIR $hg_t is in ${hg_hit#in } (a real config or state folder); nothing written" >&2
  exit 2 ;;
"home "*)
  echo "run.sh: HOME-GUARD: TMPDIR $hg_t is at or above the real home ${hg_hit#home }; nothing written" >&2
  exit 2 ;;
root)
  echo "run.sh: HOME-GUARD: TMPDIR $hg_t is at or above the real home (it is the file system root: every path would read as temp); nothing written" >&2
  exit 2 ;;
*)
  echo "run.sh: HOME-GUARD: TMPDIR $hg_t could not be checked: $hg_hit; nothing written" >&2
  exit 2 ;;
esac
# HOME-GUARD: none of the caller's Claude Code, XDG, helper or git variables (CLAUDECODE,
# CLAUDE_CONFIG_DIR, CLAUDE_PLUGIN_DATA, CLAUDE_PLUGIN_OPTION_*, CLAUDE_CODE_*, XDG_STATE_HOME,
# XDG_CACHE_HOME, STORE_*, GIT_DIR, ...) reaches a launcher, its claude or its helper: run from a
# Claude Code session, a plugin hook or a git hook they would put state into the owner's folders
# or repo. Nor do the shell start-up files a caller names (BASH_ENV, ENV, ZDOTDIR): a shell under
# test would read them. Each case sets its own HOME and TMPDIR (run_launcher); AT-RS-30e runs this
# file again with some of them set and fails when one reaches claude.
for hg_v in $(env | sed -n 's/^\(CLAUDE[A-Za-z0-9_]*\)=.*/\1/p; s/^\(XDG_[A-Za-z0-9_]*\)=.*/\1/p; s/^\(STORE_[A-Za-z0-9_]*\)=.*/\1/p; s/^\(GIT_[A-Za-z0-9_]*\)=.*/\1/p'); do
  unset "$hg_v"
done
unset BASH_ENV ENV ZDOTDIR
here=$(cd "$(dirname "$0")" && pwd -P)
repo=$(cd "$here/../.." && pwd -P)
brand=$(sed -n 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"\([a-z0-9-]*\)".*/\1/p' "$repo/brand.json" | head -n 1)
if [ -z "$brand" ]; then
  echo "run.sh: no plugin name in $repo/brand.json" >&2
  exit 2
fi
launcher=$repo/plugin/scripts/$brand-claude
if [ ! -f "$launcher" ]; then
  echo "run.sh: no launcher at $launcher (run tools/build)" >&2
  exit 2
fi
envname=$(printf '%s' "$brand" | tr 'abcdefghijklmnopqrstuvwxyz-' 'ABCDEFGHIJKLMNOPQRSTUVWXYZ_')_LAUNCH
host=$(uname -s)
uid=$(id -u)
SID=5c3d7e1f-1111-4222-8333-444455556666
quick=
only=
shells=
hg_inner=
while [ $# -gt 0 ]; do
  case $1 in
  --shell) shells="$shells$2
"; shift 2 ;;
  --quick) quick=1; shift ;;
  --hg-inner) hg_inner=1; shift ;;
  -*) echo "run.sh: unknown option $1" >&2; exit 2 ;;
  *) only="$only $1"; shift ;;
  esac
done
[ -z "$hg_inner" ] || echo "# inner run (--hg-inner: AT-RS-30e and AT-RS-30f check it)"
have_pty=
if command -v script >/dev/null 2>&1; then have_pty=1; fi

work=$(mktemp -d "${TMPDIR:-/tmp}/launcher-tests.XXXXXX") || exit 2
pids=

# INT, TERM or HUP (a Ctrl+C, a timeout): stop every shell's run and the case each one is in
# (its pid file), then remove the work folder.
interrupted() {
  trap '' INT TERM HUP
  for p in $pids; do
    kill -TERM "$p" 2>/dev/null
  done
  for f in "$work"/*/case.pid; do
    [ -f "$f" ] || continue
    p=$(cat "$f" 2>/dev/null)
    case $p in
    ''|*[!0-9]*) ;;
    *) kill -TERM "$p" 2>/dev/null ;;
    esac
  done
  wait
  sleep 1
  rm -rf "${work:?}"
  echo "# interrupted: the runs were stopped and the work folder removed" >&2
  exit "$1"
}
trap 'interrupted 130' INT
trap 'interrupted 143' TERM
trap 'interrupted 129' HUP

# ---- shells

shell_key() {
  # The file a shell command runs (links resolved), as dev:inode, to skip duplicates.
  set -- $1
  p=$(command -v "$1" 2>/dev/null) || return 1
  [ -n "$p" ] || return 1
  k=$(ls -Lid "$p" 2>/dev/null | awk '{print $1}') || return 1
  [ $# -gt 1 ] && k="$k:$2"
  printf '%s\n' "$k"
}

if [ -z "$shells" ]; then
  for s in /bin/sh /bin/bash bash /bin/dash dash /bin/zsh zsh "busybox sh"; do
    set -- $s
    command -v "$1" >/dev/null 2>&1 || continue
    shells="$shells$s
"
  done
fi
list=
keys=' '
IFS_SAVE=$IFS
nl='
'
IFS=$nl
for s in $shells; do
  IFS=$IFS_SAVE
  k=$(shell_key "$s") || { IFS=$nl; continue; }
  case $keys in
  *" $k "*) ;;
  *) keys="$keys$k "; list="$list$s$nl" ;;
  esac
  IFS=$nl
done
IFS=$IFS_SAVE

# ---- helpers (one shell's run; $SH is the shell under test, $T its tag)

q() {
  # Single-quote one word for the generated command files.
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

new_case() {
  # new_case ID TITLE [needs-pty]
  CID=$1
  CTITLE=$2
  CSKIP=
  CQUIET=
  C=$WS/$CID
  if [ -n "$only" ]; then
    # A case of a selected group that the CASE arguments do not name: not run, not listed.
    CQUIET=1
    for o in $only; do
      case $CID in
      "$o"*) CQUIET= ;;
      esac
    done
    [ -z "$CQUIET" ] || CSKIP=unselected
  fi
  mkdir -p "$C/work" "$C/tmp" "$C/home/.cache" "$C/bin"
  chmod 700 "$C/tmp" "$C/home/.cache"
  : >"$C/scenario"
  CWD=$(cd "$C/work" && pwd -P)
  if [ "${3-}" = needs-pty ] && [ -z "$have_pty" ]; then
    CSKIP="no script(1) for a terminal"
  fi
}

want_case() {
  # want_case ID: 0 when a case (or a group of cases, AT-RS-34 for AT-RS-34a..y) is selected.
  [ -n "$only" ] || return 0
  for o in $only; do
    case $1 in
    "$o"*) return 0 ;;
    esac
    case $o in
    "$1"*) return 0 ;;
    esac
  done
  return 1
}

scen() {
  printf '%s\n' "$@" >>"$C/scenario"
}

fail() {
  printf '%s\n' "$*" >>"$C/fail"
}

# run_launcher [--notty-in] [--notty-out] [--env NAME=VALUE]... [--stub-os] [--no-pty]
#              [--limit SECS] [--self WORD] -- ARGS...
# --self: the word the shell gets for the launcher file (default: its absolute path).
run_launcher() {
  r_in= r_out= r_env= r_os= r_pty=1 r_limit=30 r_self=$launcher
  while [ $# -gt 0 ]; do
    case $1 in
    --notty-in) r_in=1; shift ;;
    --notty-out) r_out=1; shift ;;
    --env) r_env="$r_env export $(q "$2");"; shift 2 ;;
    --stub-os) r_os=1; shift ;;
    --no-pty) r_pty=; shift ;;
    --limit) r_limit=$2; shift 2 ;;
    --self) r_self=$2; shift 2 ;;
    --) shift; break ;;
    *) echo "run_launcher: bad option $1" >&2; return 2 ;;
    esac
  done
  [ -z "$CSKIP" ] || return 0
  r_path=$C/bin:$here/stub
  [ -z "$r_os" ] || r_path=$here/stub-os:$r_path
  {
    printf 'cd %s || exit 99\n' "$(q "$C/work")"
    # HOME-GUARD: no CLAUDE_CONFIG_DIR of the caller's reaches the launcher or its claude (the
    # caller's Claude Code and XDG variables went at start; this line holds for a case on its own)
    printf 'unset CLAUDECODE CLAUDE_CONFIG_DIR XDG_RUNTIME_DIR XDG_CACHE_HOME %s\n' "$envname"
    printf 'export PATH=%s:"$PATH" TMPDIR=%s HOME=%s STUB_DIR=%s STUB_LAUNCH_ENV=%s STUB_NOTES=%s\n' \
      "$(q "$r_path")" "$(q "$C/tmp")" "$(q "$C/home")" "$(q "$C")" "$envname" "$(q "$here/notes")"
    printf '%s\n' "$r_env"
    printf 'exec 2>%s\n' "$(q "$C/err")"
    [ -z "$r_in" ] || printf 'exec </dev/null\n'
    printf "perl -e '\$SIG{INT} = \$SIG{QUIT} = \"DEFAULT\"; exec {\$ARGV[0]} @ARGV or exit 127' %s %s" "$SH" "$(q "$r_self")"
    for r_a in "$@"; do
      printf ' %s' "$(q "$r_a")"
    done
    [ -z "$r_out" ] || printf ' >%s' "$(q "$C/out")"
    printf '\necho $? >%s\n' "$(q "$C/rc")"
  } >"$C/cmd"
  # A terminal: BSD script takes the command as words, util-linux and busybox script as one
  # string. perl's alarm bounds the case (SIGALRM ends script; the terminal's session gets
  # SIGHUP). Its pid is in $WS/case.pid while it runs, for the runner's INT/TERM/HUP trap.
  if [ -z "$r_pty" ]; then
    set -- /bin/sh "$C/cmd"
  else
    case $host in
    Darwin|*BSD) set -- script -q /dev/null /bin/sh "$C/cmd" ;;
    *) set -- script -qc "/bin/sh '$C/cmd'" /dev/null ;;
    esac
  fi
  perl -e '$SIG{ALRM} = "DEFAULT"; alarm shift; exec @ARGV or exit 127' "$r_limit" "$@" \
    >"$C/screen" 2>&1 </dev/null &
  r_pid=$!
  echo "$r_pid" >"$WS/case.pid"
  wait "$r_pid"
  rm -f "$WS/case.pid"
  if [ ! -f "$C/rc" ]; then
    fail "the launcher did not finish within ${r_limit}s (no exit code)"
  fi
}

val() {
  # val RUN KEY: a key=value line of the stub's record of run RUN.
  sed -n "s/^$2=//p" "$C/run$1.env" 2>/dev/null | head -n 1
}

want_rc() {
  w=$(cat "$C/rc" 2>/dev/null)
  [ "$w" = "$1" ] || fail "exit code: want $1, got ${w:-none}"
}

want_runs() {
  w=$(cat "$C/runs" 2>/dev/null) || w=0
  [ "$w" = "$1" ] || fail "claude runs: want $1, got $w"
}

want_argv() {
  # want_argv RUN WORD...: the exact arguments of that claude run, one word per line (nothing for
  # a case not run: it has no run file to read).
  [ -z "$CSKIP" ] || return 0
  w_run=$1
  shift
  printf '%s\n' "$@" >"$C/want$w_run.argv"
  [ $# -gt 0 ] || : >"$C/want$w_run.argv"
  if ! cmp -s "$C/want$w_run.argv" "$C/run$w_run.argv"; then
    fail "argv of run $w_run: want [$(tr '\n' ' ' <"$C/want$w_run.argv")] got [$(tr '\n' ' ' <"$C/run$w_run.argv" 2>/dev/null)]"
  fi
}

want_val() {
  w=$(val "$1" "$2")
  [ "$w" = "$3" ] || fail "run $1 $2: want '$3', got '$w'"
}

want_err() {
  grep -F -- "$1" "$C/err" >/dev/null 2>&1 || fail "stderr lacks: $1 [$(tr '\n' '|' <"$C/err" 2>/dev/null)]"
}

want_no_err() {
  if grep -F -- "$1" "$C/err" >/dev/null 2>&1; then fail "stderr has: $1"; fi
}

want_err_lines() {
  w=$(grep -c '' "$C/err" 2>/dev/null) || w=0
  [ "$w" = "$1" ] || fail "stderr lines: want $1, got $w [$(tr '\n' '|' <"$C/err" 2>/dev/null)]"
}

want_lj() {
  # want_lj RUN TEXT: launcher.json as run RUN saw it holds TEXT.
  grep -F -- "$2" "$C/run$1.lj" >/dev/null 2>&1 || fail "launcher.json (run $1) lacks $2: $(cat "$C/run$1.lj" 2>/dev/null)"
}

want_no_lj() {
  if grep -F -- "$2" "$C/run$1.lj" >/dev/null 2>&1; then fail "launcher.json (run $1) has $2"; fi
}

rt() {
  # The runtime folder: <cache>/<brand>, the cache folder being $HOME/.cache in every case
  # that does not set XDG_CACHE_HOME.
  printf '%s\n' "$C/home/.cache/$brand"
}

want_gone() {
  # want_gone: the launch folder of run 1 no longer exists.
  w=$(val 1 launch)
  [ -n "$w" ] || { fail "run 1 saw no launch folder"; return; }
  [ ! -e "$w" ] || fail "the launch folder is still there: $(ls -a "$w" | tr '\n' ' ')"
}

want_passthrough() {
  # want_passthrough REASON: one stderr line naming REASON, one claude run with no launch
  # folder, and no folder made under the runtime base.
  want_runs 1
  want_val 1 launchset no
  want_err "restart on update is not available for this launch ($1)"
  want_err_lines 1
}

refusal() {
  # refusal REASON [nosid]: the launcher's line for a refused note.
  if [ "${2-}" = nosid ]; then
    want_err "$brand: not restarting ($1)."
    want_no_err "Resume with"
  else
    want_err "$brand: not restarting ($1). Resume with: claude --resume $SID"
  fi
}

want_last_refusal() {
  # want_last_refusal REASON: last-refusal-<token> holds exactly proto, reason, sid and at.
  w_tok=$(sed -n 's/.*"token":"\([0-9a-f]*\)".*/\1/p' "$C/run1.lj" 2>/dev/null)
  w_f=$(rt)/last-refusal-$w_tok
  if [ ! -f "$w_f" ]; then fail "no last-refusal-$w_tok"; return; fi
  w=$(sed 's/=.*//' "$w_f" | tr '\n' ' ')
  [ "$w" = "proto reason sid at " ] || fail "last-refusal keys: $w"
  grep -qx "reason=$1" "$w_f" || fail "last-refusal reason: want $1, got $(grep '^reason=' "$w_f")"
  w=$(ls -ln "$w_f" | awk '{print $1}')
  case $w in
  -rw-------*) ;;
  *) fail "last-refusal mode $w" ;;
  esac
}

want_no_last_refusal() {
  for w_f in "$(rt)"/last-refusal-*; do
    [ ! -e "$w_f" ] || fail "unexpected $(basename "$w_f"): $(tr '\n' ' ' <"$w_f")"
  done
}

end_case() {
  [ -z "$CQUIET" ] || return 0
  N=$((N + 1))
  if [ -n "$CSKIP" ]; then
    echo "ok $N - $T $CID $CTITLE # SKIP $CSKIP"
    return
  fi
  if [ -f "$C/fail" ]; then
    echo "not ok $N - $T $CID $CTITLE"
    sed 's/^/#   /' "$C/fail"
    echo "#   folder: $C"
  else
    echo "ok $N - $T $CID $CTITLE"
  fi
}

go_scen() {
  # The plugin's side of a restart in run 1: bind the sid, write the note, exit 0.
  scen "1 sid" "1 note ${1:-go.note}" "1 exit 0"
}

STATE_FLAGS="--resume $SID --model claude-opus-5-5[1m] --effort high --permission-mode acceptEdits"

# ---- cases

case_30() {
  new_case AT-RS-30 "plain run: claude's exit code, the token exported, a 0700 folder removed at exit" needs-pty
  scen "1 exit 3"
  run_launcher -- --verbose
  want_rc 3
  want_runs 1
  want_argv 1 --verbose
  want_val 1 tty yes
  want_val 1 launchset yes
  # macOS adds @ (extended attributes) and SELinux adds . to the mode; neither grants access.
  case $(val 1 perm) in
  drwx------|drwx------@|drwx------.) ;;
  *) fail "launch folder mode $(val 1 perm)" ;;
  esac
  case $(val 1 ljperm) in
  -rw-------|-rw-------@|-rw-------.) ;;
  *) fail "launcher.json mode $(val 1 ljperm)" ;;
  esac
  w=$(val 1 launch)
  case $w in
  "$(rt)"/L-????????????????) ;;
  *) fail "launch folder $w is not $(rt)/L-<16 hex>" ;;
  esac
  w_tok=${w##*/L-}
  want_lj 1 "{\"proto\":1,\"launcher_version\":\""
  want_lj 1 "\"token\":\"$w_tok\""
  want_lj 1 "\"cwd\":\"$CWD\""
  want_lj 1 "\"uname\":\"$host\""
  want_lj 1 "\"relaunches\":0,\"bypass_ok\":false,\"file_flags\":[],\"stamps\":\"stamps\",\"launch_mode\":\"\"}"
  want_gone
  want_err_lines 0
  end_case
}

case_30b() {
  new_case AT-RS-30b "the cache folder: XDG_CACHE_HOME when absolute, else HOME/.cache; never TMPDIR or XDG_RUNTIME_DIR" needs-pty
  mkdir -m 700 "$C/xdg" "$C/run"
  run_launcher --env "XDG_CACHE_HOME=$C/xdg/" --env "XDG_RUNTIME_DIR=$C/run" --
  want_rc 0
  case $(val 1 launch) in
  "$C/xdg/$brand"/L-*) ;;
  *) fail "launch folder $(val 1 launch) is not under XDG_CACHE_HOME" ;;
  esac
  # A relative XDG_CACHE_HOME is ignored (the XDG rule): HOME/.cache.
  rm -f "$C/runs" "$C/err"
  run_launcher --env "XDG_CACHE_HOME=rel/cache" --
  case $(val 1 launch) in
  "$(rt)"/L-*) ;;
  *) fail "relative XDG_CACHE_HOME: launch folder $(val 1 launch) is not under HOME/.cache" ;;
  esac
  [ ! -e "$C/work/rel" ] || fail "a relative XDG_CACHE_HOME was used"
  [ -z "$(ls -A "$C/tmp" "$C/run" 2>/dev/null | grep -v ':$' | grep -v '^$')" ] || fail "something was made under TMPDIR or XDG_RUNTIME_DIR"
  # HOME/.cache missing: made 0700; HOME relative: pass-through.
  rm -f "$C/runs" "$C/err"
  rm -rf "${C:?}/home/.cache"
  scen "1 exit 0"
  run_launcher --
  want_val 1 launchset yes
  case $(ls -ldn "$C/home/.cache" 2>/dev/null | awk '{print $1}') in
  drwx------*) ;;
  *) fail "HOME/.cache made with mode $(ls -ldn "$C/home/.cache" 2>/dev/null | awk '{print $1}')" ;;
  esac
  rm -f "$C/runs" "$C/err"
  run_launcher --env "HOME=relhome" -- --verbose
  want_passthrough "no cache folder (HOME is not an absolute path)"
  end_case
}

case_30d() {
  new_case AT-RS-30d "launch_mode: the launch's own mode (internal name), bypass from --dangerously-skip-permissions, the note's mode after a relaunch" needs-pty
  for w_pair in "plan:--permission-mode plan" "default:--permission-mode=manual" \
    "bypassPermissions:--dangerously-skip-permissions --permission-mode plan" \
    ":--allow-dangerously-skip-permissions" ":--inherit-permission-mode plan" \
    "acceptEdits:--permission-mode plan --permission-mode acceptEdits" ":--permission-mode nonsense" ":--verbose"; do
    rm -f "$C/runs" "$C/err" "$C"/run*.lj
    : >"$C/scenario"
    scen "1 exit 0"
    set -f
    run_launcher -- ${w_pair#*:}
    set +f
    want_lj 1 "\"launch_mode\":\"${w_pair%%:*}\"}"
  done
  rm -f "$C/runs" "$C/err" "$C"/run*.lj
  : >"$C/scenario"
  go_scen
  run_launcher -- --permission-mode plan
  want_lj 1 "\"launch_mode\":\"plan\"}"
  want_lj 2 "\"relaunches\":1"
  want_lj 2 "\"launch_mode\":\"acceptEdits\"}"
  end_case
}

case_30e() {
  new_case AT-RS-30e "HOME-GUARD: the caller's Claude Code, XDG, helper and git variables never reach claude (run.sh unsets them at start)" needs-pty
  x_vars="CLAUDE_PLUGIN_DATA CLAUDE_PLUGIN_OPTION_HANDOFF_ROOT XDG_STATE_HOME STORE_TEST_NOW GIT_DIR BASH_ENV ENV ZDOTDIR"
  if [ -n "$hg_inner" ]; then
    # the inner run (below): this file started with each name set; the stub records what claude got
    scen "1 exit 0"
    run_launcher --env "STUB_VARS=$x_vars" -- --verbose
    want_runs 1
    for x_v in $x_vars; do
      w=$(sed -n "s/^$x_v=//p" "$C/run1.vars" 2>/dev/null)
      [ "$w" = unset ] || fail "$x_v reached claude as '${w:-nothing}', want unset"
    done
  elif [ -z "$CSKIP" ]; then
    # this file again, on this case alone in this shell, started with each name at a folder of
    # this case: the inner case passes only when every one was unset at start, and nothing lands
    # in those folders
    mkdir -p "$C/sd"
    CLAUDE_PLUGIN_DATA=$C/sd/data CLAUDE_PLUGIN_OPTION_HANDOFF_ROOT=$C/sd/handoffs \
      XDG_STATE_HOME=$C/sd/state STORE_TEST_NOW=2026-10-21T09:00:00Z GIT_DIR=$C/sd/git TMPDIR=$C/tmp \
      BASH_ENV=$C/sd/bash_env ENV=$C/sd/env ZDOTDIR=$C/sd/zdotdir \
      /bin/sh "$here/run.sh" --hg-inner --shell "$SH" AT-RS-30e >"$C/inner.out" 2>&1
    grep -q '^# passed 1, failed 0, skipped 0$' "$C/inner.out" ||
      fail "the inner run of run.sh started with $x_vars set: $(tail -n 8 "$C/inner.out" | tr '\n' '|')"
    [ -z "$(ls -A "$C/sd")" ] || fail "files landed in the stand-in folders: $(ls -A "$C/sd" | tr '\n' ' ')"
  fi
  end_case
}

case_30f() {
  new_case AT-RS-30f "HOME-GUARD: a TMPDIR that is relative, has a .. part, lies in a real config or state folder or at or above a real home ends run.sh at start, nothing written"
  if [ -n "$hg_inner" ]; then
    # the inner run (below) with a TMPDIR run.sh takes: nothing to check here
    :
  elif [ -z "$CSKIP" ]; then
    # this file again, on this case alone in this shell, with HOME a stand-in real home and each
    # TMPDIR: refused ones end it, exit 2, with its line and no launcher-tests folder anywhere in
    # the stand-in; one under the stand-in home outside its config and state folders runs, and so
    # does one that holds a HOME made in it
    x_h=$C/fh
    mkdir -p "$x_h/.claude/t" "$x_h/.local/state/t" "$x_h/.cache/t" "$x_h/.config/t" "$x_h/tmp" "$x_h/cfg2/t" \
      "$C/cfg/t" "$C/xs/t" "$C/xc/t" "$C/xk/t" "$C/xd/t"
    ln -s "$x_h/.claude/t" "$C/L"
    ln -s "$x_h/.cache" "$C/lc"
    ln -s / "$C/lroot"
    x_rows="rel/tmp|is not absolute
$C/L/..|has a .. part
$x_h/.claude/t|is in $x_h/.claude 
$x_h/.local/state/t|is in $x_h/.local 
$x_h/.cache/t|is in $x_h/.cache 
$x_h/.config/t|is in $x_h/.config 
$C/lc|is in $x_h/.cache 
$C/cfg/t|is in $C/cfg 
$C/xs/t|is in $C/xs 
$C/xc/t|is in $C/xc 
$C/xk/t|is in $C/xk 
$C/xd/t|is in $C/xd 
/|is at or above the real home (it is the file system root:
$C/lroot|is at or above the real home (it is the file system root:"
    # another case of the names, the same folders where the file system folds case (pwd -P keeps
    # the case as typed: only the device and inode compare sees them)
    if [ -d "$C/FH" ] && [ "$C/FH" -ef "$x_h" ]; then
      x_rows="$x_rows
$C/FH/.Claude/t|is in $x_h/.claude 
$x_h/.LOCAL/state/t|is in $x_h/.local "
    fi
    # TMPDIR at the home, also by another case of its name (a stand-in under /tmp is a throwaway
    # home, which TMPDIR may hold)
    x_rh=$(cd -P "$x_h" && pwd -P)
    x_rtmp=$(cd -P /tmp && pwd -P)
    case $x_rh/ in
    "$x_rtmp"/*) ;;
    *) x_rows="$x_rows
$x_h|is at or above the real home $x_h;"
      if [ -d "$C/FH" ] && [ "$C/FH" -ef "$x_h" ]; then
        x_rows="$x_rows
$C/FH|is at or above the real home $x_h;"
      fi ;;
    esac
    # the account's home (getpwuid), whatever HOME is: a TMPDIR in a missing folder of its .claude
    # (mktemp cannot make a work folder there, so nothing is written even past the guard), and its
    # parent where this user cannot write there (the account's home is never a throwaway one)
    x_acct=$(perl -e 'my $h = (getpwuid $<)[7]; print $h if defined $h && $h =~ m{\A/}')
    if [ -n "$x_acct" ] && [ ! -e "$x_acct/.claude/launcher-hg-none" ]; then
      x_rows="$x_rows
$x_acct/.claude/launcher-hg-none/t|is in $x_acct/.claude "
    fi
    x_ap=$(dirname "$x_acct")
    if [ -n "$x_acct" ] && [ -d "$x_ap" ] && [ ! -w "$x_ap" ]; then
      x_rows="$x_rows
$x_ap|is at or above the real home $x_acct;"
    fi
    x_n=0
    IFS_SAVE=$IFS
    IFS=$nl
    for x_row in $x_rows; do
      IFS=$IFS_SAVE
      x_n=$((x_n + 1))
      x_td=${x_row%%|*}
      x_want=${x_row#*|}
      (cd "$C/work" && env HOME="$x_h" CLAUDE_CONFIG_DIR="$C/cfg" XDG_STATE_HOME="$C/xs" XDG_CONFIG_HOME="$C/xc" \
        XDG_CACHE_HOME="$C/xk" XDG_DATA_HOME="$C/xd" TMPDIR="$x_td" \
        /bin/sh "$here/run.sh" --hg-inner --shell "$SH" AT-RS-30f >"$C/inner.out" 2>&1)
      x_rc=$?
      [ "$x_rc" = 2 ] || fail "TMPDIR $x_td: exit $x_rc, want 2: $(tail -n 4 "$C/inner.out" | tr '\n' '|')"
      grep -F "run.sh: HOME-GUARD: TMPDIR $x_td $x_want" "$C/inner.out" >/dev/null 2>&1 ||
        fail "TMPDIR $x_td: no HOME-GUARD line ($x_want): $(tr '\n' '|' <"$C/inner.out")"
      IFS=$nl
    done
    IFS=$IFS_SAVE
    [ "$x_n" -ge 12 ] || fail "TMPDIR rows tried: $x_n, want at least 12"
    # CLAUDE_CONFIG_DIR given as ~/cfg2: read as the home's cfg2
    (cd "$C/work" && env HOME="$x_h" CLAUDE_CONFIG_DIR='~/cfg2' TMPDIR="$x_h/cfg2/t" \
      /bin/sh "$here/run.sh" --hg-inner --shell "$SH" AT-RS-30f >"$C/inner.out" 2>&1)
    x_rc=$?
    [ "$x_rc" = 2 ] || fail "CLAUDE_CONFIG_DIR ~/cfg2, TMPDIR in it: exit $x_rc, want 2: $(tail -n 4 "$C/inner.out" | tr '\n' '|')"
    grep -F "run.sh: HOME-GUARD: TMPDIR $x_h/cfg2/t is in ~/cfg2 " "$C/inner.out" >/dev/null 2>&1 ||
      fail "CLAUDE_CONFIG_DIR ~/cfg2, TMPDIR in it: no HOME-GUARD line: $(tr '\n' '|' <"$C/inner.out")"
    x_left=$(find "$x_h" "$C/cfg" "$C/xs" "$C/xc" "$C/xk" "$C/xd" "$C/work" -name 'launcher-tests.*' 2>/dev/null;
      find "$C" -maxdepth 1 -name 'launcher-tests.*' 2>/dev/null)
    [ -z "$x_left" ] || fail "a work folder was made: $x_left"
    (cd "$C/work" && env HOME="$x_h" CLAUDE_CONFIG_DIR="$C/cfg" XDG_STATE_HOME="$C/xs" TMPDIR="$x_h/tmp" \
      /bin/sh "$here/run.sh" --hg-inner --shell "$SH" AT-RS-30f >"$C/inner.out" 2>&1) ||
      fail "TMPDIR under the home outside its config and state folders: $(tail -n 4 "$C/inner.out" | tr '\n' '|')"
    grep -q '^# passed 1, failed 0, skipped 0$' "$C/inner.out" || fail "the inner run did not pass: $(tail -n 4 "$C/inner.out" | tr '\n' '|')"
    grep -q '^# inner run ' "$C/inner.out" || fail "the inner run given --hg-inner has no '# inner run' line: $(head -n 2 "$C/inner.out" | tr '\n' '|')"
    # a HOME made in TMPDIR (as mktemp -d makes one under TMPDIR on macOS), TMPDIR unchanged: runs
    x_mh=$(mktemp -d "$C/home.XXXXXX")
    (cd "$C/work" && env HOME="$x_mh" TMPDIR="$C" \
      /bin/sh "$here/run.sh" --hg-inner --shell "$SH" AT-RS-30f >"$C/inner.out" 2>&1) ||
      fail "HOME made in TMPDIR: $(tail -n 4 "$C/inner.out" | tr '\n' '|')"
    grep -q '^# passed 1, failed 0, skipped 0$' "$C/inner.out" || fail "HOME made in TMPDIR: the inner run did not pass: $(tail -n 4 "$C/inner.out" | tr '\n' '|')"
    # a LAUNCHER_TEST_HG_INNER left in the environment (the inner mode's variable before 0.1.2's
    # review) starts no inner run: the mode is an argument
    (cd "$C/work" && env LAUNCHER_TEST_HG_INNER=1 TMPDIR="$C/tmp" \
      /bin/sh "$here/run.sh" --shell "$SH" AT-RS-none >"$C/inner.out" 2>&1)
    if grep -q '^# inner run ' "$C/inner.out"; then fail "LAUNCHER_TEST_HG_INNER in the environment started an inner run"; fi
  fi
  end_case
}

case_30c() {
  new_case AT-RS-30c "the person's exported variables reach claude unchanged; every launcher variable starts with _" needs-pty
  # A shell keeps the export flag of a variable it got from the environment, so a launcher
  # variable with a name the person exported would change what claude and its tools see.
  x_vars="a c f n os rc rt ld me nl ff tab tok uid cwd via why base proto started self0 m0 e0 bypass_ok"
  x_env=
  for x_v in $x_vars; do
    x_env="$x_env --env $x_v=ORIG"
  done
  go_scen
  set -f
  run_launcher $x_env --env "STUB_VARS=$x_vars" -- --verbose
  set +f
  want_runs 2
  for x_run in 1 2; do
    for x_v in $x_vars; do
      w=$(sed -n "s/^$x_v=//p" "$C/run$x_run.vars" 2>/dev/null)
      [ "$w" = ORIG ] || fail "run $x_run: $x_v reached claude as '${w:-nothing}', want ORIG"
    done
  done
  # Every name the launcher assigns (comments and quoted text left out) starts with _, except
  # IFS and the launch env.
  w=$(X_ENVNAME="$envname" perl -ne 'next if /^\s*#/; s/\x27[^\x27]*\x27//g; s/"(?:[^"\\]|\\.)*"//g;
    while (/(?:^|[\s;&|(){}])([A-Za-z_]\w*)=/g) { $n{$1} = 1 }
    while (/\bfor\s+(\w+)\s+in\b/g) { $n{$1} = 1 }
    if (/\bread\s+(?:-r\s+)?([\w ]+)/) { $n{$_} = 1 for grep { length } split / /, $1 }
    END { print join(" ", grep { !/^_/ && $_ ne "IFS" && $_ ne $ENV{X_ENVNAME} } sort keys %n) }' \
    "$launcher" 2>&1)
  [ -z "$w" ] || fail "launcher variables without the _ prefix: $w"
  end_case
}

case_31a() {
  new_case AT-RS-31a "argument classes: kept verbatim in order, state replaced, session selection and prompts dropped" needs-pty
  : >"$C/work/s.json"
  : >"$C/work/m.json"
  : >"$C/work/sp.txt"
  go_scen
  run_launcher -- --add-dir /a /b --model opus --verbose -d api --settings ./s.json \
    --mcp-config '{"mcpServers":{}}' m.json -n myname --effort low --permission-mode plan \
    --resume abc -c --session-id "$SID" --fork-session "fix the bug" --allowedTools Bash Edit \
    --disallowedTools=Write --debug-file /tmp/dbg.log --system-prompt-file sp.txt \
    --prompt-suggestions -- "after dashdash"
  want_rc 0
  want_runs 2
  want_argv 2 --add-dir /a /b --verbose -d api --settings ./s.json \
    --mcp-config '{"mcpServers":{}}' m.json -n myname --allowedTools Bash Edit \
    --disallowedTools=Write --debug-file /tmp/dbg.log --system-prompt-file sp.txt \
    --prompt-suggestions $STATE_FLAGS
  want_lj 1 "\"file_flags\":[\"$CWD/s.json\",\"$CWD/m.json\",\"$CWD/sp.txt\"]"
  want_no_lj 1 mcpServers
  want_no_lj 1 myname
  want_val 2 used yes
  want_val 2 note no
  want_lj 2 "\"relaunches\":1"
  want_err "$brand: restarting session 5c3d7e1f on Claude Code 2.1.312 in 3 s (Ctrl+C stops it)"
  want_no_last_refusal
  end_case
}

case_31b() {
  new_case AT-RS-31b "pass-through: an unknown flag (named, its value never printed)" needs-pty
  run_launcher -- --frobnicate=s3cr3tvalue --verbose
  want_passthrough "unknown flag --frobnicate"
  want_no_err s3cr3tvalue
  want_argv 1 --frobnicate=s3cr3tvalue --verbose
  want_rc 0
  [ -z "$(ls -A "$(rt)" 2>/dev/null)" ] || fail "the runtime base holds $(ls -A "$(rt)")"
  end_case
}

case_31c() {
  new_case AT-RS-31c "pass-through: combined short flags, a value given to a boolean flag" needs-pty
  run_launcher -- -pc
  want_passthrough "combined short flags"
  want_argv 1 -pc
  rm -f "$C/runs" "$C/err"
  run_launcher -- --verbose=yes
  want_passthrough "a value given to --verbose"
  end_case
}

case_31d() {
  new_case AT-RS-31d "pass-through: a subcommand as the first positional word (also after options or --)" needs-pty
  for w_args in "doctor" "--verbose doctor" "-- respawn" "--model opus agents"; do
    rm -f "$C/runs" "$C/err"
    set -f
    run_launcher -- $w_args
    set +f
    set -- $w_args
    for w_last; do :; done
    want_passthrough "subcommand $w_last"
  done
  rm -f "$C/runs" "$C/err"
  scen "1 exit 0"
  run_launcher -- "fix the doctor"
  want_runs 1
  want_val 1 launchset yes
  end_case
}

case_31e() {
  new_case AT-RS-31e "pass-through: every refuse flag" needs-pty
  for w_args in "-p" "--print" "--bg" "--background" "-w" "--worktree=feat" "--remote-control" \
    "--no-session-persistence" "--tmux=classic" "-h" "--version" "--output-format json" \
    "--from-pr 12" "--teleport" "--cloud" "--desktop" "--file f:x" "--input-format text" \
    "--include-hook-events" "--include-partial-messages" "--replay-user-messages" \
    "--json-schema {}" "--max-budget-usd 1" "--forward-subagent-text" "--environment e" \
    "--remote-control-session-name-prefix p" "-v"; do
    rm -f "$C/runs" "$C/err"
    set -f
    run_launcher -- --verbose $w_args
    set +f
    set -- $w_args
    want_passthrough "${1%%=*}"
  done
  end_case
}

case_31f() {
  new_case AT-RS-31f "a variadic flag in the = form takes its one value only; in the space form it takes the following words (as commander does)" needs-pty
  go_scen
  run_launcher -- --add-dir=/x "first words" --allowedTools='Bash(git:*)' "fix the failing tests"
  want_runs 2
  want_argv 2 --add-dir=/x '--allowedTools=Bash(git:*)' $STATE_FLAGS
  rm -f "$C/runs" "$C/err"
  : >"$C/scenario"
  go_scen
  run_launcher -- --allowedTools 'Bash(git:*)' "fix the failing tests"
  want_runs 2
  want_argv 2 --allowedTools 'Bash(git:*)' "fix the failing tests" $STATE_FLAGS
  end_case
}

case_32a() {
  new_case AT-RS-32a "relaunch through --via: the wrapper words first, then claude, the note consumed" needs-pty
  go_scen
  run_launcher -- --via "via run --" --verbose
  want_rc 0
  want_runs 2
  w=$(cat "$C/vias" 2>/dev/null)
  [ "$w" = 2 ] || fail "via runs: want 2, got ${w:-0}"
  printf '%s\n' run -- claude --verbose >"$C/want.via1"
  cmp -s "$C/want.via1" "$C/via1.argv" || fail "via run 1: $(tr '\n' ' ' <"$C/via1.argv")"
  printf '%s\n' run -- claude --verbose $STATE_FLAGS >"$C/want.via2"
  cmp -s "$C/want.via2" "$C/via2.argv" || fail "via run 2: $(tr '\n' ' ' <"$C/via2.argv")"
  want_argv 2 --verbose $STATE_FLAGS
  want_val 2 used yes
  want_val 2 note no
  end_case
}

case_32b() {
  new_case AT-RS-32b "no model or effort in the note: the launch --model/--effort are kept, else none" needs-pty
  go_scen go-no-model.note
  run_launcher -- --model sonnet --effort=low --verbose
  want_argv 2 --verbose --resume "$SID" --model sonnet --effort low --permission-mode acceptEdits
  rm -f "$C/runs" "$C/err"
  run_launcher -- --verbose
  want_argv 2 --verbose --resume "$SID" --permission-mode acceptEdits
  # A launch value starting with - comes back in the = form, never as a word of its own.
  rm -f "$C/runs" "$C/err"
  run_launcher -- --model -x --effort=-y --verbose
  want_argv 2 --verbose --resume "$SID" --model=-x --effort=-y --permission-mode acceptEdits
  end_case
}

case_32c() {
  new_case AT-RS-32c "restart.used a symlink to a folder: no relaunch (consume), the note not moved into it" needs-pty
  scen "1 sid" "1 note go.note" "1 usedlink" "1 exit 0"
  run_launcher --
  want_rc 0
  want_runs 1
  refusal consume
  want_last_refusal consume
  [ -z "$(ls -A "$C/elsewhere" 2>/dev/null)" ] || fail "the note was moved into the symlinked folder: $(ls -A "$C/elsewhere")"
  want_gone
  end_case
}

case_33a() {
  new_case AT-RS-33a "never widen: bypass in the note without bypass at launch is refused" needs-pty
  go_scen go-bypass.note
  run_launcher -- --verbose
  want_rc 0
  want_runs 1
  refusal bypass
  want_last_refusal bypass
  want_gone
  end_case
}

case_33b() {
  new_case AT-RS-33b "never widen: launched with --dangerously-skip-permissions, now acceptEdits" needs-pty
  go_scen
  run_launcher -- --dangerously-skip-permissions --verbose
  want_lj 1 "\"bypass_ok\":true"
  want_argv 2 --verbose --resume "$SID" --allow-dangerously-skip-permissions \
    --model "claude-opus-5-5[1m]" --effort high --permission-mode acceptEdits
  end_case
}

case_33c() {
  new_case AT-RS-33c "default is written as manual" needs-pty
  go_scen go-default-mode.note
  run_launcher --
  want_argv 2 --resume "$SID" --model "claude-opus-5-5[1m]" --effort high --permission-mode manual
  end_case
}

case_33d() {
  new_case AT-RS-33d "bypass carried only when available at launch (each of the three flags, once)" needs-pty
  for w_flag in "--permission-mode=bypassPermissions" "--allow-dangerously-skip-permissions" \
    "--dangerously-skip-permissions"; do
    rm -f "$C/runs" "$C/err" "$C"/run*.lj
    go_scen go-bypass.note
    run_launcher -- "$w_flag" --verbose
    want_lj 1 "\"bypass_ok\":true"
    want_argv 2 --verbose --resume "$SID" --allow-dangerously-skip-permissions \
      --model "claude-opus-5-5[1m]" --effort high --permission-mode bypassPermissions
    # The countdown names a relaunch into bypass.
    want_err "$brand: restarting session 5c3d7e1f on Claude Code 2.1.312 in 3 s, permission mode bypassPermissions (Ctrl+C stops it)"
    : >"$C/scenario"
  done
  rm -f "$C/runs" "$C/err" "$C"/run*.lj
  scen "1 exit 0"
  run_launcher -- --inherit-permission-mode bypassPermissions
  want_lj 1 "\"bypass_ok\":false"
  # A repeated --permission-mode: the last one counts (commander keeps the last value).
  rm -f "$C/runs" "$C/err" "$C"/run*.lj
  : >"$C/scenario"
  go_scen go-bypass.note
  run_launcher -- --permission-mode bypassPermissions --permission-mode=default --verbose
  want_lj 1 "\"bypass_ok\":false"
  want_runs 1
  refusal bypass
  rm -f "$C/runs" "$C/err" "$C"/run*.lj
  run_launcher -- --permission-mode default --permission-mode=bypassPermissions --verbose
  want_lj 1 "\"bypass_ok\":true"
  want_runs 2
  end_case
}

refused_note() {
  # refused_note ID NOTE REASON [nosid]: run 1 writes NOTE and exits 0; no relaunch.
  new_case "$1" "refused note $2 ($3)" needs-pty
  go_scen "$2"
  run_launcher -- --verbose
  want_rc 0
  want_runs 1
  refusal "$3" "${4-}"
  want_err_lines 1
  want_last_refusal "$3"
  [ ! -e "$C/work/pwned" ] || fail "a note value ran as a command"
  want_gone
  end_case
}

case_34() {
  refused_note AT-RS-34a bad-age.note age
  refused_note AT-RS-34b bad-future.note age
  refused_note AT-RS-34c bad-token.note token
  refused_note AT-RS-34d bad-sid.note pattern nosid
  refused_note AT-RS-34e bad-sid-dashes.note pattern nosid
  refused_note AT-RS-34f bad-model-chars.note pattern
  refused_note AT-RS-34g bad-model-subst.note pattern
  refused_note AT-RS-34h bad-model-backtick.note pattern
  refused_note AT-RS-34i bad-model-quote.note pattern
  refused_note AT-RS-34j bad-model-blank.note pattern
  refused_note AT-RS-34k bad-newline.note pattern
  refused_note AT-RS-34l bad-effort.note pattern
  refused_note AT-RS-34m bad-mode.note pattern
  refused_note AT-RS-34n bad-proto.note proto
  refused_note AT-RS-34o bad-window.note window
  refused_note AT-RS-34p bad-window-empty.note window
  refused_note AT-RS-34q bad-dup.note pattern
  refused_note AT-RS-34r bad-missing.note pattern
  refused_note AT-RS-34s bad-nonce.note pattern
  refused_note AT-RS-34t bad-version.note pattern
  refused_note AT-RS-34u bad-cr.note pattern
  refused_note AT-RS-34z bad-model-dash.note pattern

  new_case AT-RS-34v "a note in a state other than go relaunches nothing and says nothing" needs-pty
  for w_note in armed.note exiting.note cancelled.note; do
    rm -f "$C/runs" "$C/err"
    : >"$C/scenario"
    go_scen "$w_note"
    run_launcher -- --verbose
    want_rc 0
    want_runs 1
    want_err_lines 0
  done
  want_no_last_refusal
  end_case

  new_case AT-RS-34w "an unreadable state: one line, no last-refusal (not a plugin exit)" needs-pty
  go_scen bad-state.note
  run_launcher --
  want_runs 1
  refusal pattern
  want_no_last_refusal
  end_case

  new_case AT-RS-34x "a go note but claude exited non-zero: no relaunch, its exit code kept" needs-pty
  scen "1 sid" "1 note go.note" "1 exit 5"
  run_launcher --
  want_rc 5
  want_runs 1
  refusal exit-code
  want_last_refusal exit-code
  end_case

  new_case AT-RS-34y "the launch folder bound to another session, or not bound" needs-pty
  scen "1 sid 11111111-2222-4333-8444-555555555555" "1 note go.note" "1 exit 0"
  run_launcher --
  want_runs 1
  refusal other-session
  : >"$C/scenario"
  rm -f "$C/runs" "$C/err"
  scen "1 note go.note" "1 exit 0"
  run_launcher --
  want_runs 1
  refusal other-session
  end_case
}

case_35a() {
  new_case AT-RS-35a "Ctrl+C in the countdown: no relaunch, exit 130" needs-pty
  scen "1 sid" "1 note go.note" "1 bg-int 1" "1 exit 0"
  run_launcher --
  want_rc 130
  want_runs 1
  refusal cancelled
  want_last_refusal cancelled
  want_gone
  end_case
}

case_35d() {
  new_case AT-RS-35d "Ctrl+C right after claude exits, before the countdown line: no relaunch, exit 130" needs-pty
  # A date that takes a second (first on PATH) holds the launcher in its checks after claude
  # exits, so a SIGINT sent 0.3 s after the exit lands there, before the countdown. (Sent at
  # the very instant of the reap it can land in the shell's own bookkeeping before the
  # launcher's next command, where bash still runs the no-op trap of the child's run.)
  printf '#!/bin/sh\nsleep 1\nexec /bin/date "$@"\n' >"$C/bin/date"
  chmod 755 "$C/bin/date"
  scen "1 sid" "1 note go.note" "1 int-at-exit 0.3" "1 exit 0"
  run_launcher --
  want_rc 130
  want_runs 1
  refusal cancelled
  want_last_refusal cancelled
  want_gone
  end_case
}

case_35b() {
  new_case AT-RS-35b "SIGINT while claude runs: the launcher stays, claude keeps the default action" needs-pty
  scen "1 int-launcher" "1 selfint" "1 exit 7"
  run_launcher --
  want_rc 7
  want_runs 1
  want_val 1 alive yes
  want_val 1 childint default
  want_gone
  end_case
}

case_35c() {
  new_case AT-RS-35c "SIGTERM or SIGHUP to the launcher (a closed terminal): never a relaunch" needs-pty
  scen "1 sid" "1 note go.note" "1 term-launcher" "1 exit 0"
  run_launcher --
  want_rc 143
  want_runs 1
  want_gone
  rm -f "$C/runs" "$C/err"
  : >"$C/scenario"
  scen "1 sid" "1 note go.note" "1 hup-launcher" "1 exit 0"
  run_launcher --
  want_rc 129
  want_runs 1
  want_gone
  end_case
}

case_36a() {
  new_case AT-RS-36a "crash guard: a relaunched claude failing within 15 s stops the loop" needs-pty
  scen "1 sid" "1 note go.note" "1 exit 0" "2 exit 1" "3 exit 0"
  run_launcher --
  want_rc 1
  want_runs 2
  want_err "$brand: Claude Code 2.1.312 did not start (exit 1). Your session is saved; start it the way you usually do with --resume $SID."
  want_last_refusal start-failed
  want_gone
  end_case
}

case_36b() {
  new_case AT-RS-36b "at most 3 relaunches an hour: the 4th is refused" needs-pty
  scen "1 sid" "1 note go.note" "1 exit 0" "2 note go.note" "2 exit 0" "3 note go.note" "3 exit 0" \
    "4 note go.note" "4 exit 0"
  run_launcher --limit 45 --
  want_rc 0
  want_runs 4
  want_lj 4 "\"relaunches\":3"
  refusal cap
  want_last_refusal cap
  end_case
}

case_36c() {
  new_case AT-RS-36c "a relaunched claude failing after 15 s is not a crash: no crash line" needs-pty
  scen "1 sid" "1 note go.note" "1 exit 0" "2 sleep 16" "2 exit 1"
  run_launcher --limit 45 --
  want_rc 1
  want_runs 2
  want_no_err "did not start"
  end_case
}

case_37() {
  new_case AT-RS-37a "inside a Claude Code session (CLAUDECODE set, even empty): refuses, exit 2"
  run_launcher --no-pty --env CLAUDECODE=1 -- --verbose
  want_rc 2
  want_runs 0
  want_err "$brand: not starting: this is already inside a Claude Code session"
  rm -f "$C/rc" "$C/err"
  run_launcher --no-pty --env CLAUDECODE= -- --verbose
  want_rc 2
  rm -f "$C/rc" "$C/err"
  run_launcher --no-pty --env CLAUDECODE=1 -- --install "$C/inst"
  want_rc 2
  [ ! -e "$C/inst" ] || fail "--install ran inside a session"
  end_case

  new_case AT-RS-37b "stdin or stdout not a terminal: pass-through" needs-pty
  run_launcher --notty-in -- --verbose
  want_passthrough "not a terminal"
  rm -f "$C/runs" "$C/err"
  run_launcher --notty-out -- --verbose
  want_passthrough "not a terminal"
  end_case
}

case_38() {
  new_case AT-RS-38a "--install: copies itself 0755, prints the alias line, is idempotent"
  run_launcher --no-pty -- --install "$C/inst"
  want_rc 0
  x_dest=$C/inst/$brand-claude
  cmp -s "$launcher" "$x_dest" || fail "the installed file differs from the launcher"
  case $(ls -ln "$x_dest" 2>/dev/null | awk '{print $1}') in
  -rwxr-xr-x*) ;;
  *) fail "installed mode: $(ls -ln "$x_dest" 2>/dev/null | awk '{print $1}')" ;;
  esac
  want_err "$brand: installed $x_dest"
  want_err "alias cl='$x_dest'"
  x_ino=$(ls -i "$x_dest" | awk '{print $1}')
  rm -f "$C/err"
  run_launcher --no-pty -- --install "$C/inst/"
  want_rc 0
  want_err "already installed: $x_dest"
  [ "$(ls -i "$x_dest" | awk '{print $1}')" = "$x_ino" ] || fail "a second install replaced the file"
  end_case

  new_case AT-RS-38b "--install: a different file needs --force"
  mkdir -p "$C/inst"
  echo "other" >"$C/inst/$brand-claude"
  run_launcher --no-pty -- --install "$C/inst"
  want_rc 1
  want_err "exists and differs from this launcher; run again with --force to replace it"
  [ "$(cat "$C/inst/$brand-claude")" = other ] || fail "the different file was replaced"
  rm -f "$C/err"
  run_launcher --no-pty -- --install --force "$C/inst"
  want_rc 0
  cmp -s "$launcher" "$C/inst/$brand-claude" || fail "--force did not replace the file"
  end_case

  new_case AT-RS-38c "--install: ~/.local/bin by default; the bare name in the alias when on PATH"
  run_launcher --no-pty --env "PATH=$C/home/.local/bin:$PATH" -- --install
  want_rc 0
  [ -x "$C/home/.local/bin/$brand-claude" ] || fail "nothing in ~/.local/bin"
  want_err "alias cl='$brand-claude'"
  end_case

  new_case AT-RS-38d "--install run by its bare file name from its own folder (sh <name> --install)"
  cp "$launcher" "$C/work/$brand-claude"
  run_launcher --no-pty --self "$brand-claude" -- --install "$C/inst"
  want_rc 0
  cmp -s "$launcher" "$C/inst/$brand-claude" 2>/dev/null || fail "nothing installed, or a different file"
  want_err "$brand: installed $C/inst/$brand-claude"
  end_case
}

case_39() {
  new_case AT-RS-39a "Windows (MINGW, MSYS, CYGWIN): pass-through with the Windows line" needs-pty
  for w_u in MINGW64_NT-10.0-19045 MSYS_NT-10.0 CYGWIN_NT-10.0; do
    rm -f "$C/runs" "$C/err"
    run_launcher --stub-os --env "STUB_UNAME=$w_u" -- --verbose
    want_rc 0
    want_runs 1
    want_val 1 launchset no
    want_err "$brand: restart on update: not supported on Windows"
    want_err_lines 1
  done
  end_case

  new_case AT-RS-39b "another system: pass-through" needs-pty
  run_launcher --stub-os --env STUB_UNAME=SunOS -- --verbose
  want_passthrough "not supported on this system"
  end_case
}

case_40() {
  new_case AT-RS-40a "runtime folder is a symlink: pass-through" needs-pty
  mkdir -m 700 "$C/elsewhere"
  ln -s "$C/elsewhere" "$(rt)"
  run_launcher -- --verbose
  want_passthrough "the runtime folder is not private (a symlink, another owner or not 0700)"
  [ -z "$(ls -A "$C/elsewhere")" ] || fail "something was written through the symlink"
  end_case

  new_case AT-RS-40b "runtime folder with a wrong mode: pass-through" needs-pty
  mkdir -m 755 "$(rt)"
  run_launcher -- --verbose
  want_passthrough "the runtime folder is not private (a symlink, another owner or not 0700)"
  end_case

  new_case AT-RS-40c "runtime folder owned by someone else (stub id): pass-through" needs-pty
  run_launcher --stub-os --env STUB_UID=4242 --env "STUB_UNAME=$host" -- --verbose
  want_passthrough "the runtime folder is not private (a symlink, another owner or not 0700)"
  end_case

  new_case AT-RS-40d "runtime folder owned by another user (real chown)" needs-pty
  if [ -z "${LAUNCHER_TEST_FOREIGN_BASE-}" ]; then
    CSKIP="no LAUNCHER_TEST_FOREIGN_BASE (docker.sh sets it)"
  fi
  run_launcher --env "XDG_CACHE_HOME=${LAUNCHER_TEST_FOREIGN_BASE-}" -- --verbose
  [ -n "$CSKIP" ] || want_passthrough "the runtime folder is not private (a symlink, another owner or not 0700)"
  end_case

  new_case AT-RS-40f "runtime folder with an ACL (macOS, where ls may show @ for it): pass-through" needs-pty
  if [ "$host" != Darwin ]; then
    CSKIP="macOS ACL case"
  else
    mkdir -m 700 "$(rt)"
    chmod +a "group:everyone allow list" "$(rt)" 2>/dev/null || CSKIP="chmod +a failed"
  fi
  run_launcher -- --verbose
  [ -n "$CSKIP" ] || want_passthrough "the runtime folder is not private (a symlink, another owner or not 0700)"
  end_case

  new_case AT-RS-40g "a cache folder others may write to without the sticky bit: pass-through; with it: arms" needs-pty
  for w_m in 777 770 757; do
    rm -rf "${C:?}/shared"
    mkdir "$C/shared"
    chmod "$w_m" "$C/shared"
    rm -f "$C/runs" "$C/err"
    run_launcher --env "XDG_CACHE_HOME=$C/shared" -- --verbose
    want_passthrough "the cache folder is writable by others and not sticky"
    [ ! -e "$C/shared/$brand" ] || fail "mode $w_m: a runtime folder was made in the shared cache folder"
  done
  rm -rf "${C:?}/shared"
  mkdir "$C/shared"
  chmod 1777 "$C/shared"
  rm -f "$C/runs" "$C/err"
  scen "1 exit 0"
  run_launcher --env "XDG_CACHE_HOME=$C/shared" -- --verbose
  want_runs 1
  want_val 1 launchset yes
  end_case

  new_case AT-RS-40h "Linux with getfacl: an ACL entry beyond user::, group::, other:: on the runtime folder: pass-through" needs-pty
  run_launcher --stub-os --env STUB_UNAME=Linux --env "STUB_UID=$uid" --env "STUB_FACL=user:4242:rwx
mask::rwx" -- --verbose
  want_passthrough "the runtime folder is not private (a symlink, another owner or not 0700)"
  rm -f "$C/runs" "$C/err"
  scen "1 exit 0"
  run_launcher --stub-os --env STUB_UNAME=Linux --env "STUB_UID=$uid" -- --verbose
  want_runs 1
  want_val 1 launchset yes
  end_case

  new_case AT-RS-40e "stale launch folders of dead launchers are swept; a live one is kept" needs-pty
  mkdir -m 700 "$(rt)"
  /bin/sh -c 'exit 0' &
  w_dead=$!
  wait "$w_dead"
  mkdir -m 700 "$(rt)/L-dddddddddddddddd" "$(rt)/L-aaaaaaaaaaaaaaaa"
  printf '{"proto":1,"pid":%s,"token":"dddddddddddddddd"}\n' "$w_dead" >"$(rt)/L-dddddddddddddddd/launcher.json"
  : >"$(rt)/L-dddddddddddddddd/stamps"
  printf '{"proto":1,"pid":%s,"token":"aaaaaaaaaaaaaaaa"}\n' "$$" >"$(rt)/L-aaaaaaaaaaaaaaaa/launcher.json"
  run_launcher -- --verbose
  want_runs 1
  [ ! -e "$(rt)/L-dddddddddddddddd" ] || fail "the dead launcher's folder was kept"
  [ -d "$(rt)/L-aaaaaaaaaaaaaaaa" ] || fail "the live launcher's folder was removed"
  end_case
}

case_43() {
  new_case AT-RS-43a "file_flags: path values only, absolute; inline JSON never written" needs-pty
  scen "1 exit 0"
  run_launcher -- --settings '{"apiKeyHelper":"s3cr3t"}' --mcp-config ' {"a":1}' '[]' \
    --append-system-prompt-file /etc/hosts --settings ./x/../s.json
  want_lj 1 "\"file_flags\":[\"/etc/hosts\",\"$CWD/x/../s.json\"]"
  want_no_lj 1 s3cr3t
  end_case

  new_case AT-RS-43b "a file path with a quote, a backslash or a newline: pass-through" needs-pty
  for w_p in 'a"b.json' 'a\b.json' "a
b.json"; do
    rm -f "$C/runs" "$C/err"
    run_launcher -- --settings "$w_p"
    want_passthrough "a file path with a quote, backslash or control character"
  done
  end_case

  new_case AT-RS-43c "a launch file removed after arming: no relaunch, launch-file, no value recorded" needs-pty
  : >"$C/work/s.json"
  scen "1 sid" "1 note go.note" "1 rmfile work/s.json" "1 exit 0"
  run_launcher -- --settings s.json
  want_runs 1
  refusal launch-file
  want_last_refusal launch-file
  w_tok=$(sed -n 's/.*"token":"\([0-9a-f]*\)".*/\1/p' "$C/run1.lj" 2>/dev/null)
  if grep -F s.json "$(rt)/last-refusal-$w_tok" >/dev/null 2>&1; then fail "last-refusal names the file"; fi
  end_case

  new_case AT-RS-43d "restart.mode-end: different from the note's mode refuses; equal relaunches" needs-pty
  scen "1 sid" "1 note go.note" "1 modeend plan" "1 exit 0"
  run_launcher --
  want_runs 1
  refusal mode-changed
  want_last_refusal mode-changed
  rm -f "$C/runs" "$C/err"
  : >"$C/scenario"
  scen "1 sid" "1 note go.note" "1 modeend acceptEdits" "1 exit 0" "2 exit 0"
  run_launcher --
  want_runs 2
  want_val 2 modeend no
  end_case
}

run_shell() {
  SH=$1
  T=$(printf '%s' "$SH" | tr -c 'A-Za-z0-9\n' '_' | sed 's/^_*//')
  WS=$work/$T
  mkdir -p "$WS"
  N=0
  for w_c in 30 30b 30c 30d 30e 30f 31a 31b 31c 31d 31e 31f 32a 32b 32c 33a 33b 33c 33d 34 35a 35b 35c 35d 36a 36b 36c 37 38 39 40 43; do
    want_case "AT-RS-$w_c" || continue
    [ -z "$quick" ] || [ "$w_c" != 36c ] || continue
    "case_$w_c"
  done
}

# ---- main

echo "# launcher $launcher"
echo "# shells: $(printf '%s' "$list" | tr '\n' ',' | sed 's/,$//')"
[ -n "$have_pty" ] || echo "# no script(1): the cases that need a terminal are skipped"
IFS=$nl
for s in $list; do
  IFS=$IFS_SAVE
  t=$(printf '%s' "$s" | tr -c 'A-Za-z0-9\n' '_' | sed 's/^_*//')
  run_shell "$s" >"$work/$t.tap" 2>&1 &
  pids="$pids $!"
  IFS=$nl
done
IFS=$IFS_SAVE
for p in $pids; do
  wait "$p"
done
passed=0
failed=0
skipped=0
k=0
IFS=$nl
for s in $list; do
  IFS=$IFS_SAVE
  t=$(printf '%s' "$s" | tr -c 'A-Za-z0-9\n' '_' | sed 's/^_*//')
  while IFS= read -r line; do
    case $line in
    "not ok "*) k=$((k + 1)); failed=$((failed + 1)); echo "not ok $k ${line#not ok * }" ;;
    "ok "*"# SKIP"*) k=$((k + 1)); skipped=$((skipped + 1)); echo "ok $k ${line#ok * }" ;;
    "ok "*) k=$((k + 1)); passed=$((passed + 1)); echo "ok $k ${line#ok * }" ;;
    *) echo "$line" ;;
    esac
  done <"$work/$t.tap"
  IFS=$nl
done
IFS=$IFS_SAVE
echo "1..$k"
echo "# passed $passed, failed $failed, skipped $skipped"
if [ "$failed" -eq 0 ] && [ "$k" -gt 0 ]; then
  rm -rf "${work:?}"
  exit 0
fi
echo "# work folder kept: $work"
exit 1
