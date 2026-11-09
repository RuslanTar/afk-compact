#!/usr/bin/perl
# helper/main.pl: entry of the plugin helper, started by the launcher in scripts/.
# Owner: WP-core. Dispatches `<subcommand>` to cmd/<subcommand>.pl (BUILD-PLAN §3.1).
#
# The guard below must stay parsable by perl 5.8: it runs before any other
# `use`, so an old perl that reaches this file still takes the fallback. The
# launcher checks no version itself (one perl start per call): a hook runs the
# launcher's fallback (the launcher file again, with --fallback-hook hook
# <Event>), which reads stdin, writes its one content-free row and exits 0;
# stdin is left unread here for it. The launcher's hook wrapper hands over its
# own path in $main::STORE_LAUNCHER. Without a launcher to run, a hook drains
# stdin and exits 0. Anything else refuses, exit 3. Test seam (STORE_TEST_MODE
# only): STORE_TEST_PERL_V=5.NNN stands in for $] (a perl older than this host's).
BEGIN {
    my $v = $];
    $v = $ENV{STORE_TEST_PERL_V}
        if ($ENV{STORE_TEST_MODE} || '') eq '1' && ($ENV{STORE_TEST_PERL_V} || '') =~ /\A5\.[0-9]{1,6}\z/;
    if ($v < 5.028) {
        if (@ARGV && $ARGV[0] eq 'hook') {
            my $launcher = defined $main::STORE_LAUNCHER ? $main::STORE_LAUNCHER : '';
            exec('/bin/sh', $launcher, '--fallback-hook', @ARGV) if $launcher =~ m{\A/} && -f $launcher && -r _ && -x '/bin/sh';
            local $/;
            my $drain = <STDIN>;
            exit 0;
        }
        print "REFUSED: helper-runtime\n";
        exit 3;
    }
}

# The helper's start (util::clock_ms's clock), before its libraries compile: a hook's budget
# that must cover the whole process (Stop's) counts from here.
our $T_START_MS;
BEGIN { $T_START_MS = eval { require Time::HiRes; int(Time::HiRes::time() * 1000) } }

use strict;
use warnings;
use utf8;
use File::Basename ();
use Cwd ();
my $HELPER_DIR;
BEGIN { $HELPER_DIR = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
use lib "$HELPER_DIR/lib";

umask 077;
binmode STDOUT;
binmode STDIN;

# Subcommands of the §3.1 table. Each one lives in cmd/<sub>.pl.
my %KNOWN = map { $_ => 1 } qw(
    hook ident dispatch prev-copy checkpoint save-copy sweep claim measure log
    reconcile status smoke handoff-turn handoff-state queue-add
    begin stamp evidence publish locate inventory heal-check verify
    restore-evidence stash lane pin receipt risk wait project
    watch report notice trial-measure trial-save restart settings migrate prune
    queue cache
);

my $sub = shift @ARGV;
if (!defined $sub || !$KNOWN{$sub}) {
    print STDERR "usage: <subcommand> [args]\n";
    exit 64;
}

my $IS_HOOK = $sub eq 'hook';
if ($IS_HOOK) {
    # Hooks never write stderr, and nothing but our text reaches stdout.
    open(STDERR, '>', '/dev/null');
    $SIG{__WARN__} = sub { };
    $SIG{PIPE} = 'IGNORE';
}

# Core libraries every subcommand may use (BUILD-PLAN §3.6 seams), in load order.
our @CORE = qw(util jsonc sha ctx spec settings paths roots log rc identity lock nonce
               git gsd queue bucket frontmatter detect assemble secrets evidence
               dispatch transcript scope sessions sidecar ledger copies measure checkpoint
               sweep reconcile orphans keyset resumeblock args rollup postcompact repomode jobrec handoff_turn notice userre
               restart plugver cachestate);
# 0.1.4 (T-12): `hook <Event>` loads the base set and its event's table, not all of @CORE
# (compiling every library was the largest part of a hook's start under load). A table holds
# the libraries the event's handler in cmd/hook.pl calls and what they call in turn (a file-level
# reading; reconcile, which the cross-session finish calls only for an ended session, is left out
# where nothing else needs it), every library whose package variables a loaded one reads, and every
# library behind a `defined &pkg::fn` guard a loaded one, or the watcher, holds (detect::summary,
# secrets::scan, identity::claude_pid): such a guard would skip its feature, not fail, if its
# library were left out. A call into a library still left out loads all the rest of @CORE first
# (the AUTOLOAD below), so a call no table foresaw costs the full start, never the feature. Any
# other subcommand, and an unknown event, loads @CORE. Test seams (STORE_TEST_MODE only):
# STORE_TEST_LAZY=full loads @CORE for a hook too; STORE_TEST_INC_OUT=<file> gets one line, the
# libraries loaded by the end (HOOK-LAZY-01).
our @HOOK_BASE = qw(util jsonc sha ctx spec settings paths roots log rc identity git detect secrets transcript args repomode userre);
our %HOOK_EVENT = (
    PreCompact       => [qw(lock nonce bucket frontmatter assemble dispatch sessions ledger copies keyset)],
    PostCompact      => [qw(lock nonce queue bucket frontmatter evidence dispatch scope sessions sidecar ledger copies sweep orphans keyset
                            rollup postcompact jobrec restart)],
    SessionStart     => [qw(lock nonce gsd queue assemble evidence dispatch sessions sidecar measure sweep orphans keyset resumeblock
                            rollup jobrec restart plugver cachestate)],
    SessionEnd       => [qw(lock nonce gsd queue bucket frontmatter assemble evidence dispatch scope sessions sidecar ledger copies measure
                            sweep reconcile orphans resumeblock rollup postcompact jobrec restart plugver cachestate)],
    Stop             => [qw(lock nonce gsd queue bucket frontmatter assemble evidence dispatch scope sessions sidecar ledger copies measure
                            sweep reconcile orphans resumeblock rollup postcompact jobrec restart plugver)],
    SubagentStop     => [qw(sessions sidecar jobrec)],
    StopFailure      => [],
    PermissionDenied => [qw(dispatch rollup reconcile ledger copies)],
);
# 0.1.7 (D-81): `cache` runs from a status line every few seconds and writes nothing: it loads only
# these, not settings, paths, rc or identity (whose setup, args::init_sid, writes once-notes and
# config rows). CACHE-04 holds the set (STORE_TEST_INC_OUT).
our %SUB_LIBS = (cache => [qw(util jsonc ctx args cachestate)]);
my $TEST = ($ENV{STORE_TEST_MODE} || '') eq '1';
my %load = map { ($_ => 1) } @CORE;
if ($IS_HOOK && defined $ARGV[0] && $HOOK_EVENT{ $ARGV[0] } && !($TEST && ($ENV{STORE_TEST_LAZY} || '') eq 'full')) {
    %load = map { ($_ => 1) } @HOOK_BASE, @{ $HOOK_EVENT{ $ARGV[0] } };
} elsif ($SUB_LIBS{$sub}) {
    %load = map { ($_ => 1) } @{ $SUB_LIBS{$sub} };
}
for my $lib (grep { $load{$_} } @CORE) {
    my $ok = eval { require "$lib.pm"; 1 };
    if (!$ok) {
        if ($IS_HOOK) { local $/; my $d = <STDIN>; exit 0 }
        print STDERR "$sub: cannot load $lib: $@";
        exit 70;
    }
}
my @LATER = grep { !$load{$_} } @CORE;
# (perl sets the $AUTOLOAD of the package a sub was compiled in: main's, for these)
our $AUTOLOAD;
for my $pkg (@LATER) {
    no strict 'refs';
    *{"${pkg}::AUTOLOAD"} = sub {
        my $name = $AUTOLOAD;
        return if $name =~ /::DESTROY\z/;
        util::trace("hook-lazy-load $name");
        require "$_.pm" for grep { !$INC{"$_.pm"} } @LATER;
        die "Undefined subroutine &$name called\n" unless defined &$name;
        goto &$name;
    };
}
END {
    my $f = $TEST ? $ENV{STORE_TEST_INC_OUT} : undef;
    if (defined $f && $f =~ m{\A/} && open(my $fh, '>>', $f)) {
        print $fh join(' ', sort map { /\A([a-z_]+)\.pm\z/ ? $1 : () } keys %INC), "\n";
        close $fh;
    }
}
# T-14: SessionStart writes this session's classic-alive.json, so it reads Claude Code's start time
# itself (identity::claude_pid); every other call may take it from that record
{
    # (identity.pm declares it, but loads after main.pl compiles: no "used only once" warning on stderr)
    no warnings 'once';
    $identity::OWN_START = 1 if $IS_HOOK && defined $ARGV[0] && $ARGV[0] eq 'SessionStart';
}
ctx::init($HELPER_DIR);
# U-06: the time bound of the user's patterns for a subcommand the mod calls with a short timeout
userre::limits(@{ $userre::SUB_S{$sub} }) if $userre::SUB_S{$sub};

my $file = "$HELPER_DIR/cmd/$sub.pl";
if (!-f $file) {
    if ($IS_HOOK) { local $/; my $d = <STDIN>; exit 0 }
    print STDERR "$sub: not implemented\n";
    exit 70;
}
my $ok = do $file;
if (!defined $ok && $@) {
    exit 0 if $IS_HOOK;
    print STDERR "$sub: $@";
}
exit($IS_HOOK ? 0 : 70);
