package FakeXS;
# Cygwin::win_to_posix_path as Git for Windows' perl has it, for the drive-path cases on any host
# (loaded with -MFakeXS; it replaces the real sub on the PC too): C:\x or C:/x reads as
# $FAKE_CYGDRIVE/c/x. FAKE_XS_ABORT=flagged ends perl as the real sub did on the PC (sitting 4,
# P4: "Out of memory!", exit 1, which no eval catches) when it is given a UTF8-flagged string;
# FAKE_XS_ABORT=nonascii also when it is given a byte string holding a non-ASCII byte.
use strict;
use warnings;
use POSIX ();

{
    no warnings 'redefine';
    sub Cygwin::win_to_posix_path {
        my ($p) = @_;
        my $m = $ENV{FAKE_XS_ABORT} // '';
        if ((($m eq 'flagged' || $m eq 'nonascii') && utf8::is_utf8($p)) || ($m eq 'nonascii' && $p =~ /[^\x00-\x7f]/)) {
            print STDERR "Out of memory!\n";
            POSIX::_exit(1);
        }
        my $top = $ENV{FAKE_CYGDRIVE};
        die "FAKE_CYGDRIVE is not set\n" unless defined $top && $top ne '';
        (my $x = $p) =~ tr{\\}{/};
        $x =~ s{\A([A-Za-z]):}{$top . '/' . lc $1}e;
        return $x;
    }
}

1;
