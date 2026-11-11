# Zip writer: STORE always works; DEFLATE is used only
# when the optional raw-deflate module loads (inside an eval) and the deflated body is smaller.
# An entry that would deflate more than $DEFLATE_RATIO_MAX times stays STORE, so a bundle never
# trips the analyzer's ratio-bomb refusal (tools/beta-analyze RATIO_MAX 100). The reader inflates
# DEFLATE entries when the raw-inflate module loads, else reports `method`. Python's zipfile
# (what tools/beta-analyze uses) reads the archive and its CRCs check. The reader (`report
# verify`) never inflates an entry past the size its header declares.
my %got;
my $rows = join('', map { qq({"v":1,"ev":"compaction","compaction_seq":$_,"verdict":"ok","trigger":"auto","pre_tokens":) . (200000 + $_ * 37) . "}\n" } 1 .. 300);
my @entries = ([ 'rows/0123456789ab.jsonl', $rows ], [ 'tiny.txt', 'ab' ], [ 'flat.txt', 'a' x 200000 ]);
{
    needs => [q(cmd:python3)], needs_note => q(the Python zipfile read; the whole case is not run, its perl zip checks too),
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              require watch::bundle;
              my $have = eval { require IO::Compress::RawDeflate; require IO::Uncompress::RawInflate; 1 } ? 1 : 0;
              $got{have} = $have;
              {
                  local $watch::bundle::DEFLATE;
                  local $watch::bundle::INFLATE;
                  my $z = watch::bundle::zip(\@entries, 1792580400);
                  $got{z} = $z;
                  $got{u} = watch::bundle::unzip($z);
                  my $f = "$v->{TMP}/d.zip";
                  open(my $h, '>:raw', $f) or die "open: $!";
                  print $h $z;
                  close $h;
                  $got{py} = `python3 -I -c 'import sys, zipfile; z = zipfile.ZipFile(sys.argv[1]); print(z.testzip() or "OK", ",".join(str(i.compress_type) for i in z.infolist()), len(z.read("rows/0123456789ab.jsonl")))' '$f' 2>&1`;
                  local $watch::bundle::INFLATE = 0;
                  $got{u_noinflate} = watch::bundle::unzip($z);
              }
              if ($have) {
                  # A bomb: 1 MB of one byte deflated past the ratio cap, then the declared size
                  # in the central directory set to 10. The reader stops at 10 bytes.
                  local $watch::bundle::DEFLATE;
                  local $watch::bundle::INFLATE;
                  local $watch::bundle::DEFLATE_RATIO_MAX = 1e9;
                  my $z = watch::bundle::zip([ [ 'bomb.txt', 'a' x 1_000_000 ] ], 1792580400);
                  my $cd = rindex($z, pack('V', 0x02014b50));
                  substr($z, $cd + 24, 4) = pack('V', 10);
                  $got{bomb} = watch::bundle::unzip($z);
              }
              {
                  local $watch::bundle::DEFLATE = 0;
                  my $z = watch::bundle::zip(\@entries, 1792580400);
                  $got{zs} = $z;
                  $got{us} = watch::bundle::unzip($z);
              }
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my %e = map { $_->{name} => $_ } @{ $got{u}{entries} || [] };
        $E->ok((!$got{u}{error} ? 1 : 0), 'the archive reads back');
        for my $x (@entries) {
            $E->is($e{ $x->[0] }{error} // '', '', "$x->[0]: no read error");
            $E->ok((defined $e{ $x->[0] }{data} && $e{ $x->[0] }{data} eq $x->[1] ? 1 : 0), "$x->[0]: bytes round-trip");
        }
        $E->is($e{'tiny.txt'}{method}, 0, 'an entry deflate does not shrink stays STORE');
        $E->is($e{'flat.txt'}{method}, 0, 'an entry over the ratio cap stays STORE');
        if ($got{have}) {
            $E->is($e{'rows/0123456789ab.jsonl'}{method}, 8, 'rows deflated when the module is present');
            $E->ok(($e{'rows/0123456789ab.jsonl'}{csize} < $e{'rows/0123456789ab.jsonl'}{size} ? 1 : 0), 'deflated body is smaller');
            $E->ok((length($got{z}) < length($got{zs}) ? 1 : 0), 'the DEFLATE archive is smaller than the STORE one');
            $E->ok(($got{py} =~ /\AOK 8,0,0 \Q${\ length $rows}\E\s*\z/ ? 1 : 0), "python zipfile reads it ($got{py})");
            my %n = map { $_->{name} => $_ } @{ $got{u_noinflate}{entries} || [] };
            $E->is($n{'rows/0123456789ab.jsonl'}{error}, 'method', 'no inflate module: the deflated entry is a method error');
            my ($b) =@{ $got{bomb}{entries} || [] };
            $E->ok(($b && $b->{error} && !defined $b->{data} ? 1 : 0), 'an entry inflating past its declared size is an error, no data (' . ($b ? $b->{error} // 'none' : 'no entry') . ')');
        }
        my %s = map { $_->{name} => $_ } @{ $got{us}{entries} || [] };
        $E->is(join(',', map { $s{ $_->[0] }{method} } @entries), '0,0,0', 'deflate off: every entry STORE');
        $E->ok((join('', map { $s{ $_->[0] }{data} // '' } @entries) eq join('', map { $_->[1] } @entries) ? 1 : 0), 'STORE round-trips');
    },
};
