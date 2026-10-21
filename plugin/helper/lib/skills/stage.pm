package skills::stage;
# lib/skills/stage.pm: a stage made by `begin` (<bucket>/.staging/<sid8>-<nonce>/).
use strict;
use warnings;
use File::Basename ();
use skills::util;
use skills::cli;
use skills::ctx;

# Load the stage and a context built from the settings stored in it.
# The stage must be <bucket>/.staging/<sid8>-<nonce> of the bucket its
# settings name, so evidence and publish write only next to the stage.
sub open_stage {
    my ($dir) = @_;
    die skills::cli::usage('--stage is required') unless defined $dir && $dir ne '';
    $dir = skills::util::abs_path($dir);
    $dir =~ s{/+\z}{};
    die skills::cli::refuse('no-stage') unless -d $dir && $dir =~ m{/\.staging/[0-9a-z]+-[0-9a-f]{8}\z};
    my $t = skills::util::read_file("$dir/settings.json", 262144);
    my $s = eval { skills::util::json_decode($t) };
    die skills::cli::refuse('no-stage') unless ref $s eq 'HASH' && $s->{session_id};
    my $bucket = defined $s->{bucket} && !ref $s->{bucket} ? skills::util::abs_path($s->{bucket}) : undef;
    die skills::cli::refuse('no-stage')
        unless defined $bucket && $bucket eq File::Basename::dirname(File::Basename::dirname($dir))
            && File::Basename::basename($dir) eq ($s->{sid8} // '') . '-' . ($s->{nonce} // '');
    my %flags = %{ $s->{settings} || {} };
    my $ctx = skills::ctx::new(\%flags);
    skills::ctx::set_sid($ctx, $s->{session_id});
    return ($dir, $s, $ctx);
}

# Times the helper printed for this stage (checked_at plus every stamp).
sub printed_times {
    my ($dir, $s) = @_;
    my %t;
    $t{ $s->{checked_at} } = 1 if $s->{checked_at};
    my $log = skills::util::read_file("$dir/stamps.log") // '';
    for my $l (split /\n/, $log) {
        my (undef, $shown) = split /\t/, $l, 2;
        next unless defined $shown;
        $t{$shown} = 1;
        $t{$1} = 1 if $shown =~ /(\d\d:\d\d)\z/;
    }
    return \%t;
}

# Evidence rows recorded by `evidence` for this stage.
sub evidence_rows {
    my ($dir) = @_;
    my $t = skills::util::read_file("$dir/evidence.jsonl") // '';
    my @rows;
    for my $l (split /\n/, $t) {
        my $d = eval { skills::util::json_decode($l) };
        push @rows, $d if ref $d eq 'HASH';
    }
    return \@rows;
}

1;
