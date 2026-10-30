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
    # STATE-ROOT (0.1.2): a stage begun before the update stored the old default root ~/.claude/handoffs
    # as its handoff_root. While handoff_root is the default now (the run context reads the old root),
    # the stage takes the current root instead, and its bucket the same <repo>/<bucket> there: the
    # handoff, its evidence, pin, records and .watch rows go to the new root, never the old one. Only
    # the stage's own work folder (its draft, stamps and attempts) stays where begin made it.
    # The settings as they read now, without the stage's value, say whether the old root is read
    # (legacy_path is set only while handoff_root is the default); the context built last is the
    # run context (rc), so the stage's own value is built after the check when it stays.
    my ($ctx, $was);
    my $old = do { no warnings 'once'; defined $paths::LEGACY_ROOT ? skills::util::abs_path($paths::LEGACY_ROOT) : undef };
    if (defined $old && defined $flags{handoff_root} && !ref $flags{handoff_root}
        && (skills::util::abs_path($flags{handoff_root}) // '') eq $old) {
        my %now = %flags;
        delete $now{handoff_root};
        my $c = skills::ctx::new(\%now);
        my ($a, $b) = map { defined $_ ? skills::util::abs_path($_) // '' : '' } ($flags{handoff_root}, $c->{legacy_path});
        ($ctx, $was) = ($c, $a) if $a ne '' && $a eq $b;
    }
    $ctx //= skills::ctx::new(\%flags);
    if (defined $was) {
        my $now = skills::util::abs_path($ctx->{root}) // $ctx->{root};
        $s->{bucket} = $now . substr($bucket, length $was) if index($bucket, "$was/") == 0 && $now ne $was;
    }
    skills::ctx::set_sid($ctx, $s->{session_id});
    return ($dir, $s, $ctx);
}

# Stamps the helper printed for this stage (checked_at plus every stamp), whole:
# date, time and offset (RV-24).
sub printed_times {
    my ($dir, $s) = @_;
    my %t;
    $t{ $s->{checked_at} } = 1 if $s->{checked_at};
    my $log = skills::util::read_text("$dir/stamps.log") // '';
    for my $l (split /\n/, $log) {
        my (undef, $shown) = split /\t/, $l, 2;
        next unless defined $shown;
        $t{$shown} = 1;
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
