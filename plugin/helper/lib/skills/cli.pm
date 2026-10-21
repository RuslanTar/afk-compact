package skills::cli;
# lib/skills/cli.pm: shared entry for the WP-skills subcommands. Exit codes
# (BUILD-PLAN §3.1): 0 result printed · 3 REFUSED printed · 64 usage · 70
# internal error (one stderr line). Exit 2 is never used.
use strict;
use warnings;
use Getopt::Long ();

our $OUT = '';

sub say { my ($line) = @_; $OUT .= $line . "\n"; return 1 }

# Die with this to end with a refusal: die skills::cli::refuse('reason').
sub refuse { my ($why) = @_; return bless { why => $why }, 'skills::cli::Refused' }
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

# Run one subcommand body; prints buffered stdout, returns the exit code.
sub main {
    my ($name, $fn, @argv) = @_;
    umask 077;
    $OUT = '';
    my $rc = eval { $fn->(\@argv) // 0 };
    if (!defined $rc) {
        my $e = $@;
        if (ref $e eq 'skills::cli::Refused') {
            print $OUT;
            print "REFUSED: $e->{why}\n";
            return 3;
        }
        if (ref $e eq 'skills::cli::Usage') {
            print STDERR "$name: usage: $e->{why}\n";
            return 64;
        }
        $e = "$e";
        $e =~ s/\s+\z//;
        $e =~ s/\n/ /g;
        print STDERR "$name: $e\n";
        return 70;
    }
    print $OUT;
    return $rc;
}

1;
