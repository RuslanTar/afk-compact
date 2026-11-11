# M-10 `fabricated` counts with numbered captures
# give the counts the named-capture version gave (expected values recorded from main
# 7d9efdd), with the spec time regexes (one of which has its own capture group) and with
# the built-in fallbacks. Columns: no measured block; measured with stamps; empty spec.
my $spec = { time_re => "[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} [+-][0-9]{4}",
             time_legacy_re => "([0-9]{2}-[0-9]{2} )?[0-9]{2}:[0-9]{2}" };
my @B = (
  [ "checked 2026-10-21 14:05 +0300 and checked 14:05 and checked 10-21 14:05", 3, 1, 3 ],
  [ "checked 2026-10-21 14:05 then checked 2026-10-21T14:05:12Z, checked 2026-10-21 14:05 +03:00", 3, 3, 3 ],
  [ "checked later; checked 123:45; checked 12:345; checked notatime checked 09:30", 1, 1, 1 ],
  [ "[verified 2026-10-21 14:05 +0300] [verified by run at 14:05] [verified 10-21 09:00] [verified no time] [verified "
    . ("x" x 50) . " 12:00]", 5, 3, 5 ],
  [ "- U-1 keep [verified 2026-10-21 14:05 +0300]\n- D-2 checked 2026-10-21 14:05 +0300 listed 14:05\n[verified 14:0512]", 3, 1, 3 ],
);
my $stamps = ['2026-10-21 14:05 +0300', '14:05'];
{
    steps => [],
    expect => sub {
        my ($E) = @_;
        require watch::shape;
        my $i = 0;
        for my $b (@B) {
            $i++;
            $E->is(watch::shape::fabricated($b->[0], 0, [], $spec), $b->[1], "body $i: no measured block");
            $E->is(watch::shape::fabricated($b->[0], 1, $stamps, $spec), $b->[2], "body $i: measured stamps excluded");
            $E->is(watch::shape::fabricated($b->[0], 0, [], {}), $b->[3], "body $i: built-in regexes");
        }
    },
};
