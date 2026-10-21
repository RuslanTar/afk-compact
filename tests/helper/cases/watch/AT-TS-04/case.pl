# AT-TS-04 (small-rulings §3a, M-10): watch::shape::fabricated against a measured block,
# with stamp and legacy tokens. A token counts unless measured:true and its whole text is
# one of the measured block's stamps; `listed` never counts.
require watch::shape;
my %got;
my $S = '2026-10-21 14:05 +0300';
{
    steps => [
        { call => 'code', code => sub {
            my $spec = { time_re => '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} [+-][0-9]{4}',
                         time_legacy_re => '([0-9]{2}-[0-9]{2} )?[0-9]{2}:[0-9]{2}' };
            my $iso = "Measured facts (2026-10-21T14:05:12+03:00):\nIn flight (sidecar 2026-10-21 13:58 +0300)\ncwd: x\n";
            my @st = watch::shape::measured_stamps($iso, $spec);
            $got{stamps} = join('|', @st);
            $got{neg} = join('|', watch::shape::measured_stamps("Measured facts (2026-03-08T14:05:12-05:00):\n", $spec));
            $got{head_stamp} = join('|', watch::shape::measured_stamps("Measured facts ($S):\nIn flight (sidecar 2026-10-21 13:58 +0300)\n", $spec));
            $got{legacy_block} = join('|', watch::shape::measured_stamps("Measured facts (14:05)\ncwd: x\n", $spec));
            $got{none} = scalar(() = watch::shape::measured_stamps(undef, $spec));
            my $f = sub { my ($body, $measured, $stamps) = @_; return watch::shape::fabricated($body, $measured, $stamps, $spec) };
            $got{plain_stamp} = $f->("checked $S", 0, []);
            $got{plain_legacy} = $f->("checked 14:05 and checked 10-21 14:05", 0, []);
            $got{measured_same} = $f->("checked $S", 1, \@st);
            $got{measured_other_min} = $f->("checked 2026-10-21 14:06 +0300", 1, \@st);
            $got{measured_other_zone} = $f->("checked 2026-10-21 14:05 +0200", 1, \@st);
            $got{measured_sidecar} = $f->("checked 2026-10-21 13:58 +0300", 1, \@st);
            $got{measured_legacy_vs_full} = $f->("checked 14:05", 1, \@st);
            $got{verified_same} = $f->("[verified $S: git status]", 1, \@st);
            $got{verified_other} = $f->("[verified 2026-10-21 15:00 +0300: git status]", 1, \@st);
            $got{verified_legacy} = $f->("[verified 14:05: git status]", 1, \@st);
            $got{verified_none} = $f->("[verified earlier: git status]", 1, \@st);
            $got{legacy_equal} = $f->("checked 14:05 [verified 14:05: x]", 1, ['14:05']);
            $got{listed} = $f->("listed $S and listed 14:07", 0, []);
            $got{unmeasured_stamps_ignored} = $f->("checked $S", 0, \@st);
            $got{two} = $f->("checked $S, checked 2026-10-21 15:15 +0300, [verified 14:07: a]", 1, \@st);
            $got{no_spec_keys} = watch::shape::fabricated("checked $S checked 14:05", 0, [], {});
        } },
    ],
    expect => sub {
        my ($E) = @_;
        $E->is($got{stamps}, "$S|2026-10-21 13:58 +0300", 'ISO header turned into a stamp, then the other stamps');
        $E->is($got{neg}, '2026-03-08 14:05 -0500', 'a negative offset keeps its sign');
        $E->is($got{head_stamp}, "$S|2026-10-21 13:58 +0300", 'a stamp header is taken whole');
        $E->is($got{legacy_block}, '14:05', 'a block with only a legacy time gives it');
        $E->is($got{none}, 0, 'no block, no stamps');
        $E->is($got{plain_stamp}, 1, 'stamp, unmeasured');
        $E->is($got{plain_legacy}, 2, 'both legacy forms count');
        $E->is($got{measured_same}, 0, 'the measured stamp');
        $E->is($got{measured_other_min}, 1, 'another minute');
        $E->is($got{measured_other_zone}, 1, 'another offset: the whole stamp differs');
        $E->is($got{measured_sidecar}, 0, 'the sidecar stamp in the block');
        $E->is($got{measured_legacy_vs_full}, 1, 'a legacy token never equals a whole stamp');
        $E->is($got{verified_same}, 0, '[verified <measured stamp>');
        $E->is($got{verified_other}, 1, '[verified <other stamp>');
        $E->is($got{verified_legacy}, 1, '[verified HH:MM against a stamp');
        $E->is($got{verified_none}, 1, '[verified with no time');
        $E->is($got{legacy_equal}, 0, 'legacy token equal to a legacy measured time');
        $E->is($got{listed}, 0, 'listed is never counted');
        $E->is($got{unmeasured_stamps_ignored}, 1, 'stamps count only with measured:true');
        $E->is($got{two}, 2, 'one other stamp and one legacy verified');
        $E->is($got{no_spec_keys}, 2, 'a spec without the keys uses the RV-24 forms');
    },
};
