#!/usr/bin/perl
# helper/main.pl: entry of the plugin helper, started by the launcher in scripts/.
# Owner: WP-core. Dispatches `<subcommand>` to cmd/<subcommand>.pl (BUILD-PLAN §3.1).
#
# The guard below must stay parsable by perl 5.8: it runs before any other
# `use`, so an old perl that reaches this file still takes the fallback. The
# launcher checks no version itself (one perl start per call): a hook runs the
# launcher's fallback (scripts/<name>-store --fallback-hook hook <Event>), which
# reads stdin, writes its one content-free row and exits 0; stdin is left
# unread here for it. Without a launcher to run, a hook drains stdin and exits
# 0. Anything else refuses, exit 3. Test seam (STORE_TEST_MODE only):
# STORE_TEST_PERL_V=5.NNN stands in for $] (a perl older than this host's).
BEGIN {
    my $v = $];
    $v = $ENV{STORE_TEST_PERL_V}
        if ($ENV{STORE_TEST_MODE} || '') eq '1' && ($ENV{STORE_TEST_PERL_V} || '') =~ /\A5\.[0-9]{1,6}\z/;
    if ($v < 5.028) {
        if (@ARGV && $ARGV[0] eq 'hook') {
            my $root = __FILE__;
            $root = './x' unless $root =~ m{/};
            $root =~ s{/[^/]*\z}{};
            $root .= '/..';
            my $name = '';
            if (open(my $mf, '<', "$root/.claude-plugin/plugin.json")) {
                local $/;
                my $m = <$mf>;
                close $mf;
                ($name) = (defined $m ? $m : '') =~ /"name"\s*:\s*"([A-Za-z0-9._-]+)"/;
                $name = '' unless defined $name;
            }
            my $launcher = "$root/scripts/$name-store";
            exec('/bin/sh', $launcher, '--fallback-hook', @ARGV) if $name ne '' && -r $launcher && -x '/bin/sh';
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
    watch report notice trial-measure trial-save restart settings migrate
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

# Core libraries every subcommand may use (BUILD-PLAN §3.6 seams).
for my $lib (qw(util jsonc sha ctx spec settings paths roots log rc identity lock nonce
                git gsd queue bucket frontmatter detect assemble secrets evidence
                dispatch transcript scope sessions sidecar copies measure checkpoint
                sweep reconcile orphans keyset resumeblock args rollup postcompact repomode jobrec handoff_turn notice userre
                restart plugver)) {
    my $ok = eval { require "$lib.pm"; 1 };
    if (!$ok) {
        if ($IS_HOOK) { local $/; my $d = <STDIN>; exit 0 }
        print STDERR "$sub: cannot load $lib: $@";
        exit 70;
    }
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
