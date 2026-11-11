# F2-4: the rows the rules read come from the
# persisted incremental cache under <watch>/<sid>/watch-cache/ (state.json,
# written atomically, 0600; rows.jsonl). A Stop decodes only the stream lines
# that are new since the last Stop and whose kind the rules read, never the
# whole classic and mod streams. A row appended between Stops is read once; a
# half-written last line waits for its newline; a replaced (shorter) stream is
# read again from the start.
my @noise_c = map { T::row('measure', 1 + $_ / 100, writer => 'classic', note => 'n' x 200) } 1 .. 300;
my @noise_m = map { T::row('skip', 1 + $_ / 100, why => 'cooldown') } 1 .. 300;
my $late = watch::json::encode(T::row('thrash', 140));
my $cut = int(length($late) / 2);
my $decode = \&watch::json::decode;
my ($calls, $stop2) = (0, undef);
my %st;
{
    transcript => [ T::prompt(0), T::assistant_text(1) ],
    files => [
        { path => '$WATCH/$SID.classic.jsonl', jsonl => \@noise_c },
        { path => '$WATCH/$SID.jsonl', jsonl => [ @noise_m, T::row('thrash', 5) ] },
    ],
    steps => [
        { call => 'stop', at => 100 },
        { call => 'code', code => sub {
              no warnings 'redefine';
              *watch::json::decode = sub { $calls++; goto &$decode };
          } },
        { call => 'stop', at => 110 },
        { call => 'code', code => sub {
              no warnings 'redefine';
              *watch::json::decode = $decode;
              $stop2 = $calls;
          } },
        { call => 'append', path => '$WATCH/$SID.jsonl',
          rows => [ T::row('continue', 120, result => 'submitted', continues_last_hour => 9) ] },
        { call => 'stop', at => 130 },
        { call => 'append', path => '$WATCH/$SID.jsonl', raw => substr($late, 0, $cut) },
        { call => 'stop', at => 150 },
        { call => 'append', path => '$WATCH/$SID.jsonl', raw => substr($late, $cut) . "\n" },
        { call => 'stop', at => 160 },
        { call => 'stop', at => 170 },
        { call => 'code', code => sub {
              my ($v) = @_;
              my $p = "$v->{WATCH}/$T::SID.jsonl";
              open(my $fh, '>:raw', "$p.new") or die;
              print $fh watch::json::encode(T::row('continue', 175, result => 'submitted', continues_last_hour => 7)), "\n";
              close $fh;
              rename("$p.new", $p) or die;
          } },
        { call => 'stop', at => 180 },
        { call => 'code', code => sub {
              my ($v) = @_;
              my $d = "$v->{WATCH}/$T::SID/watch-cache";
              %st = (mode => (stat "$d/state.json")[2] & 07777, state => watch::io::read_json_file("$d/state.json"),
                     rows => [ map { watch::json::decode($_) } grep { /\S/ } split /\n/, (watch::io::slurp("$d/rows.jsonl") // '') ]);
          } },
    ],
    expect => sub {
        my ($E) = @_;
        $E->ok(defined $stop2 && $stop2 < 60, 'Stop 2 decoded ' . ($stop2 // 'undef') . ' JSON texts, not the 600 stream rows');
        $E->count([ $E->alerts('A-19') ], 2, 'A-19 for the appended continue row, then for the replaced stream');
        $E->count([ grep { $_->{evidence}{mod_thrash} } $E->alerts('A-07') ], 2,
                  'A-07 for the first thrash row, and once for the one whose line was completed later');
        $E->is(sprintf('%o', $st{mode} // 0), '600', 'state.json is 0600');
        my $s = $st{state} || {};
        $E->is($s->{v}, 2, 'state version (2: the alerts log keeps its alert_closed rows)');
        my @k = map { $_->{r}{ev} // 'none' } @{ $st{rows} || [] };
        $E->count([ grep { /\A(?:measure|skip|sweep)\z/ } @k ], 0, 'no row of a kind the rules do not read is kept');
        $E->count([ grep { $_ eq 'continue' } @k ], 1, 'the replaced stream was read again from the start, its old rows dropped');
        my $size = -s ($E->var('WATCH') . '/' . $E->var('SID') . '.jsonl');
        $E->is($s->{src}{mod}{off}, $size, 'the mod offset is at the end of the new stream');
    },
};
