package sweep;
# lib/sweep.pm: the automatic evidence sweep (MOD-SPEC §10, §5.3 step 5; OD-9).
# Owner: WP-core. Scope: temp paths the mod recorded this session
# (<watch>/<sid>/paths.jsonl), else temp paths found in the last 5 MB of the
# transcript; plus in-flight outputs from the sidecar. Destination
# <disposable_root>/<YYYY-MM-DD>/<stem>-evidence/ (never <bucket>/evidence/).
# Claims <watch>/<sid>/swept/<id6> first, so one compaction is swept once.
use strict;
use warnings;

our @STATUSES = qw(copied dup ref-only redacted withheld missing referenced-budget);

sub _in_scope {
    my ($p) = @_;
    return 0 unless defined $p && $p =~ m{^/};
    # macOS paths also come in their realpath form (/tmp and /var are links into /private)
    return 1 if $p =~ m{^(?:/private)?/tmp/};
    return 1 if $p =~ m{^(?:/private)?/var/folders/};
    my $t = $ENV{TMPDIR};
    if (defined $t && $t =~ m{^/.+}) { $t =~ s{/+$}{}; return 1 if index($p, "$t/") == 0 }
    return 1 if $p =~ m{/scratchpad/};
    return 1 if $p =~ m{/tasks/[^/]+\.output$};
    return 0;
}

sub candidates {
    my ($sid_dir, $transcript) = @_;
    my (@c, %seen);
    my $pj = "$sid_dir/paths.jsonl";
    if (-f $pj) {
        open(my $fh, '<:raw', $pj);
        while (my $l = <$fh>) {
            my $j = eval { jsonc::decode($l) } or next;
            next unless ref $j eq 'HASH';
            my @p = ref $j->{paths} eq 'ARRAY' ? @{ $j->{paths} } : ();
            push @p, $j->{path} if defined $j->{path};
            for my $p (@p) { next if ref $p; push @c, $p if _in_scope($p) && !$seen{$p}++ }
        }
        close $fh;
    } else {
        for my $p (@{ transcript::temp_paths($transcript, $ENV{TMPDIR}) }) { push @c, $p if _in_scope($p) && !$seen{$p}++ }
    }
    my $slot = sidecar::newest($sid_dir);
    if ($slot && ref $slot->{tasks} eq 'ARRAY') {
        for my $t (@{ $slot->{tasks} }) {
            my $p = ref $t eq 'HASH' ? $t->{output_path} : undef;
            push @c, $p if defined $p && !$seen{$p}++;
        }
    }
    return \@c;
}

# run(sid => S, id6 => X, stem => STEM, transcript => P, budget_ms => N, bucket => path, nonce => N)
# -> {exit, lines => [..], totals => {..}, rows => [..], dest}
sub run {
    my (%a) = @_;
    my $sid_dir = rc::sid_dir();
    my %tot = map { $_ => 0 } @STATUSES;
    my @lines;
    my $total_line = sub {
        return sprintf('TOTAL copied=%d dup=%d ref_only=%d redacted=%d withheld=%d referenced_budget=%d',
                       @tot{qw(copied dup ref-only redacted withheld referenced-budget)});
    };
    if (!rc::val('auto_evidence')) {
        return { exit => 0, lines => [$total_line->()], totals => \%tot, rows => [], skipped => 'off' };
    }
    return { exit => 3, lines => ['REFUSED: ' . (rc::root_reason('disposable_root') // 'root-unsafe')], totals => \%tot, rows => [] }
        unless rc::root_ok('disposable_root');
    return { exit => 3, lines => ['REFUSED: no-watch'], totals => \%tot, rows => [] } unless defined $sid_dir;
    my $disp = rc::paths()->{disposable};
    my $dest = "$disp/" . util::day(util::now()) . "/$a{stem}-evidence";
    # The claim also names the destination, so `measure --nonce` finds this sweep's MANIFEST.
    my $claimed = eval { util::write_excl("$sid_dir/swept/$a{id6}", ($a{nonce} // '') . "\t$dest\n", 0600) };
    if (!$claimed) {
        return { exit => 0, lines => [$total_line->()], totals => \%tot, rows => [], skipped => 'swept' };
    }
    util::trace('sweep');
    my $t0 = util::clock_ms();
    my $deadline = $t0 + ($a{budget_ms} // 8000);
    my $index = rc::watch() . '/evidence-index.tsv';
    my $used = 0;
    my (@rows, %rules, $bytes);
    $bytes = 0;
    for my $p (@{ candidates($sid_dir, $a{transcript}) }) {
        my $r;
        if (util::clock_ms() >= $deadline) {
            $r = { status => 'referenced-budget', origin => $p, copy => undef, bytes => (-f $p ? -s _ : undef),
                   sha8 => undef, rules => [] };
        } else {
            $r = eval { evidence::copy($p, $dest, { used => \$used }, $index) }
                 || { status => 'missing', origin => $p, rules => [] };
        }
        $tot{ $r->{status} }++;
        $rules{$_}++ for @{ $r->{rules} || [] };
        $bytes += $r->{bytes} // 0 if $r->{status} =~ /^(copied|redacted)$/;
        push @rows, $r;
        push @lines, join("\t", $r->{status}, $r->{origin}, (defined $r->{copy} ? util::abbrev($r->{copy}) : '-'),
                          $r->{bytes} // '-', $r->{sha8} // '-');
    }
    chmod 0700, util::dirname($dest), $dest if -d $dest;
    push @lines, $total_line->();
    my $ms = util::clock_ms() - $t0;
    my @warn;
    if (defined $a{bucket}) {
        my $sum = evidence::du("$a{bucket}/evidence") + evidence::du("$a{bucket}/compact");
        my $q = rc::val('evidence_quota_mb') // 500;
        my $mb = int($sum / (1024 * 1024) + 0.5);
        if ($q > 0 && $sum > $q * 1024 * 1024) {
            my $rel = index($a{bucket}, rc::root() . '/') == 0 ? substr($a{bucket}, length(rc::root()) + 1) : util::abbrev($a{bucket});
            push @lines, "WARN quota $rel $mb";
            rc::emit('warn_quota', [bucket => $rel, mb => $mb, quota_mb => $q]);
        }
    }
    rc::emit('sweep_evidence', [nonce => $a{nonce}, id6 => $a{id6}, copied => $tot{copied}, dup => $tot{dup},
                                ref_only => $tot{'ref-only'}, redacted => $tot{redacted}, withheld => $tot{withheld},
                                missing => $tot{missing}, referenced_budget => $tot{'referenced-budget'},
                                bytes => $bytes, ms => $ms, rules => [sort keys %rules],
                                dest => (-d $dest ? util::abbrev($dest) : undef)]);
    return { exit => 0, lines => \@lines, totals => \%tot, rows => \@rows, dest => $dest, ms => $ms };
}

1;
