package skills::cli;
# lib/skills/cli.pm: shared entry for the skill subcommands. Exit codes:
# 0 result printed · 3 REFUSED printed · 64 usage · 70
# internal error (one stderr line). Exit 2 is never used.
use strict;
use warnings;
use utf8;
use Getopt::Long ();
use skills::util;

our $OUT = '';

sub say { my ($line) = @_; $OUT .= $line . "\n"; return 1 }

# Die with this to end with a refusal: die skills::cli::refuse('reason'[, lines after]).
sub refuse { my ($why, @after) = @_; return bless { why => $why, after => \@after }, 'skills::cli::Refused' }
sub usage  { my ($why) = @_; return bless { why => $why }, 'skills::cli::Usage' }

# Parse options from @$argv with Getopt::Long specs; dies usage() on error.
sub opts {
    my ($argv, @spec) = @_;
    my %o;
    my @err;
    local $SIG{__WARN__} = sub { push @err, $_[0] };
    my $p = Getopt::Long::Parser->new(config => [qw(no_ignore_case no_auto_abbrev permute)]);
    my $ok = $p->getoptionsfromarray($argv, \%o, @spec);
    die usage(join(' ', map { s/\s+\z//r } @err) || 'bad option') unless $ok;
    return \%o;
}

# Run one subcommand body; prints buffered stdout, returns the exit code. The arguments
# are decoded and the output encoded here, once each.
sub main {
    my ($name, $fn, @argv) = @_;
    umask 077;
    $OUT = '';
    @argv = map { skills::util::text($_) } @argv;
    my $rc = eval { $fn->(\@argv) // 0 };
    if (!defined $rc) {
        my $e = $@;
        if (ref $e eq 'skills::cli::Refused') {
            print skills::util::bytes($OUT . "REFUSED: $e->{why}\n" . join('', map { "$_\n" } @{ $e->{after} || [] }));
            return 3;
        }
        if (ref $e eq 'skills::cli::Usage') {
            print STDERR skills::util::bytes("$name: usage: $e->{why}\n");
            return 64;
        }
        $e = "$e";
        $e =~ s/\s+\z//;
        $e =~ s/\n/ /g;
        print STDERR skills::util::bytes("$name: " . skills::util::text($e) . "\n");
        return 70;
    }
    print skills::util::bytes($OUT);
    return $rc;
}

1;
