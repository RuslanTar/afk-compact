package settings_reset;
# lib/settings_reset.pm: what `settings reset` asks the settings writer for (0.1.2 visible
# defaults). The plan, the checks, the edit and the write are
# lib/settings_write.pm's, the one writer of the user's settings file: a reset is a removal of
# the named members of the plugin's options, refused for a consent key (on every path) and for a
# protective list or resume_proceed when the removal loosens it.
# --all leaves %settings::RESET_KEEP (the consent and protective keys and resume_proceed)
# and keys the plugin does not know.
use strict;
use warnings;
use utf8;

# requests(\@keys | 'all', saved options or undef) -> ([writer requests], [keys --all kept])
sub requests {
    my ($want, $opts) = @_;
    return ([ map { { key => $_, kind => 'remove' } } @$want ], []) if ref $want;
    my (@r, @kept);
    for my $k (map { $_->[0] } @settings::KEYS) {
        next unless ref $opts eq 'HASH' && exists $opts->{$k};
        if ($settings::RESET_KEEP{$k}) { push @kept, $k; next }
        push @r, { key => $k, kind => 'remove' };
    }
    return (\@r, \@kept);
}

# notes(plan) -> what the default of each protective key or resume_proceed being removed does.
# The writer removes one only when that loosens nothing (a saved empty list, a saved auto).
sub notes {
    my ($p) = @_;
    my @l;
    for my $c (grep { $_->{kind} eq 'remove' && $settings::RESET_KEEP{ $_->{key} } } @{ $p->{changes} }) {
        my $e = $settings::RESET_EFFECT{ $c->{key} } // next;
        $e =~ s/ \(looser than now\)\z//;
        push @l, "  note: $c->{key}: $e";
    }
    return @l;
}

1;
