package args;
# lib/args.pm: `--key value` / `--flag` parsing for the subcommands.
# parse(\@argv, bools => [names], multi => [names]) -> (\%opt, \@rest) or dies "usage: ..."
use strict;
use warnings;
use utf8;

sub parse {
    my ($argv, %o) = @_;
    my %bool = map { $_ => 1 } @{ $o{bools} || [] };
    my %multi = map { $_ => 1 } @{ $o{multi} || [] };
    my (%opt, @rest);
    my @a = @$argv;
    while (@a) {
        my $x = shift @a;
        if ($x eq '--') { push @rest, @a; last }
        if ($x =~ /^--([A-Za-z0-9][A-Za-z0-9-]*)(?:=(.*))?$/s) {
            my ($k, $v) = ($1, $2);
            if ($bool{$k}) { $opt{$k} = defined $v ? $v : 1; next }
            if (!defined $v) {
                die "usage: --$k needs a value\n" unless @a;
                $v = shift @a;
            }
            if ($multi{$k}) { push @{ $opt{$k} }, $v } else { $opt{$k} = $v }
            next;
        }
        push @rest, $x;
    }
    if ($o{known}) {
        my %k = map { $_ => 1 } @{ $o{known} }, keys %bool, keys %multi;
        for my $k (keys %opt) { die "usage: unknown flag --$k\n" unless $k{$k} || $settings::FLAG_ALIAS{$k} }
    }
    return (\%opt, \@rest);
}

sub need {
    my ($opt, @keys) = @_;
    for my $k (@keys) { die "usage: --$k is required\n" unless defined $opt->{$k} && $opt->{$k} ne '' }
}

# main(\&run, @argv): runs a subcommand body; `usage:` dies -> exit 64 with one
# stderr line; other dies -> exit 70 (2 is never used).
sub main {
    my ($run, @argv) = @_;
    my $code = eval { $run->(@argv) };
    if (!defined $code) {
        my $e = $@ || "internal error\n";
        $e =~ s/\n.*//s;
        if ($e =~ /^usage:/) { print STDERR "$e\n"; return 64 }
        print STDERR "error: $e\n";
        return 70;
    }
    return 70 if $code == 2;
    return $code;
}

# init_sid(opt, writer) -> sid after rc::init with the settings flags of opt. A missing, empty
# or unsubstituted --sid (a Cowork task's skill text kept `${CLAUDE_SESSION_ID}` and its
# Bash had the variable empty) is refused with the reason: these commands work on one
# session's state. Read-only `status` takes no_sid() first and runs without one. A placeholder id
# the helper itself logs under (reserved_sid) is refused too: its folder is a pool of rows from
# many sessions, never one session's state.
sub init_sid {
    my ($opt, $writer) = @_;
    if (no_sid($opt->{sid})) {
        my $why = unsubstituted($opt->{sid}) ? 'the session id was not substituted' : 'no session id';
        die "usage: --sid is required ($why; this command works on one session's state and never runs without its id)\n";
    }
    die "usage: --sid is not a session id\n" unless valid_sid($opt->{sid});
    die "usage: --sid is not a session id ($opt->{sid} is the plugin's placeholder for rows without one)\n"
        if reserved_sid($opt->{sid});
    rc::init(sid => $opt->{sid}, writer => $writer // 'helper', flags => settings::flags_from($opt));
    rc::preamble();
    return $opt->{sid};
}

sub out { print STDOUT map { my $l = $_; utf8::encode($l) if utf8::is_utf8($l); "$l\n" } @_ }

sub valid_sid {
    my ($s) = @_;
    return defined $s && $s =~ /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/ ? 1 : 0;
}

# no_sid(value) -> 1 when --sid was not given, is empty or only spaces, or is a reference left
# unsubstituted (unsubstituted), else 0. The skills' unset rule (lib/skills/util.pm unset_value
# with lib/skills/ctx.pm placeholder_sid) is the same except that it takes a spaces-only value as
# set; such a value is no session id either way (valid_sid refuses spaces).
sub no_sid {
    my ($s) = @_;
    return !defined $s || $s =~ /\A\s*\z/ || unsubstituted($s) ? 1 : 0;
}

# unsubstituted(value) -> 1 for a variable reference the skill text or the shell left as written:
# `${…}`, `$NAME`, or a bare `CLAUDE_*` name (a model that dropped the braces and the dollar),
# else 0
sub unsubstituted {
    my ($s) = @_;
    return defined $s && ($s =~ /\A\s*\$/ || $s =~ /\ACLAUDE_[A-Z0-9_]+\z/) ? 1 : 0;
}

# reserved_sid(value) -> 1 for a placeholder id the helper itself logs under, never a real
# session: `unknown` (rows without a session id: cmd/hook.pl, cmd/notice.pl, cmd/watch.pl,
# lib/skills/core.pm), `smoke` (cmd/smoke.pl without --sid) and `anon-*` (the skills' identity
# without a session id, lib/skills/ctx.pm resolve_sid), else 0
sub reserved_sid {
    my ($s) = @_;
    return defined $s && ($s eq 'unknown' || $s eq 'smoke' || $s =~ /\Aanon-/) ? 1 : 0;
}

1;
