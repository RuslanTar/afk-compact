package args;
# lib/args.pm: `--key value` / `--flag` parsing for the subcommands. Owner: WP-core.
# parse(\@argv, bools => [names], multi => [names]) -> (\%opt, \@rest) or dies "usage: ..."
use strict;
use warnings;

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
# stderr line; other dies -> exit 70 (BUILD-PLAN §3.1 exit codes; 2 is never used).
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

# init_sid(opt, writer) -> sid after rc::init with the settings flags of opt
sub init_sid {
    my ($opt, $writer) = @_;
    need($opt, 'sid');
    die "usage: --sid is not a session id\n" unless valid_sid($opt->{sid});
    rc::init(sid => $opt->{sid}, writer => $writer // 'helper', flags => settings::flags_from($opt));
    rc::preamble();
    return $opt->{sid};
}

sub out { print STDOUT map { my $l = $_; utf8::encode($l) if utf8::is_utf8($l); "$l\n" } @_ }

sub valid_sid {
    my ($s) = @_;
    return defined $s && $s =~ /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/ ? 1 : 0;
}

1;
