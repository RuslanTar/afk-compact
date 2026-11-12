# AT-WD-10 / AT-WD-11, watcher half on the S-21 sequences.
# Core's cases run the sequences and assert the rows they write
# (tests/fixtures/sequences/<id>/expected.json). This case reads those asserted rows as the
# watcher would find them and checks the watcher's view:
# - AT-WD-10: S-21-pd (step 5 post-compaction caused_by plugin, step 7 other), S-21-pd-512k
#   (post-compaction), and the negatives S-21-pd-noboundary, S-21-pd-sub, S-21-pd-stale
#   (other): the D-13 counts (watch::rules::deny_summary) match the asserted turn_kind.
# - AT-WD-11: S-21-mod step 6 (rollup with null sizes + the compaction_boundary row) and
#   S-21-mod-conflict (rollup pre_tokens 198000 kept, one join_conflict): the watcher's join
#   (watch::rules::join_rollup) equals the sequence's `joined` reader view.
# Skipped until the sequences are on the branch.
my @PD = qw(S-21-pd S-21-pd-512k S-21-pd-noboundary S-21-pd-sub S-21-pd-stale);
my @MOD = qw(S-21-mod S-21-mod-conflict);
my %x;
for my $id (@PD, @MOD) {
    my $e = T::fixture_json("sequences/$id/expected.json");
    return { skip => "needs tests/fixtures/sequences/$id" } unless $e;
    $x{$id} = $e;
}
my %got;
my $last = sub { my ($e) = @_; my @a = @{ $e->{step_asserts} || [] }; return $a[-1] };
{
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              require watch::rules;
              # AT-WD-10: the permission_denied rows each sequence asserts (count and fields; a
              # row assert with fields adds that many rows of that kind, the rest are `other`).
              for my $id (@PD) {
                  my @rows;
                  my $t = 10;
                  for my $a (@{ $x{$id}{step_asserts} }) {
                      my @r = grep { ($_->{ev} // '') eq 'permission_denied' && $_->{fields} } @{ $a->{rows} || [] };
                      for my $r (@r) {
                          push @rows, T::row('permission_denied', $t++, writer => 'classic', tool_name => 'Bash',
                                             reason_class => 'rule', guard_class => 'other', %{ $r->{fields} }) for 1 .. ($r->{count} // 1);
                      }
                  }
                  my $W = "$v->{TMP}/$id/.watch";
                  main::write_file("$W/$T::SID.classic.jsonl", main::jsonl(\@rows));
                  my $ctx = watch::ctx::init({ sid => $T::SID, watch => $W, root => "$v->{TMP}/$id", plugin_root => $v->{PLUGIN},
                                               settings => {}, now => $T::BASE + 200 });
                  $got{pd}{$id} = { d => watch::rules::deny_summary(watch::rules::load_session($ctx)), n => scalar @rows };
              }
              # AT-WD-11: the rollup row and the compaction_boundary row as the steps assert them.
              for my $id (@MOD) {
                  my (%roll, %bd);
                  for my $a (@{ $x{$id}{step_asserts} }) {
                      for my $r (@{ $a->{rows} || [] }) {
                          next unless $r->{fields};
                          my $f = { %{ $r->{fields} } };
                          $f->{precomputed} = ($f->{precomputed} ? 1 : 0) if exists $f->{precomputed};
                          if (($r->{ev} // '') eq 'compaction') { %roll = (%roll, %$f) }
                          elsif (($r->{ev} // '') eq 'compaction_boundary') { %bd = (%bd, %$f) }
                      }
                  }
                  my ($j) = @{ $last->($x{$id})->{joined} || [] };
                  $roll{nonce} //= $j->{nonce};
                  my @rows = (T::row('compaction', 10, writer => 'helper', actor => 'main', id6 => substr($roll{nonce}, 0, 6),
                                     pre_tokens => undef, post_tokens => undef, duration_ms => undef, %roll),
                              T::row('compaction_boundary', 11, writer => 'helper', actor => 'main', %bd));
                  my ($r, undef, $n) = watch::rules::join_rollup(\@rows);
                  $got{mod}{$id} = { row => $r->{ $roll{nonce} }, conflicts => $n, want => $j };
              }
          } },
    ],
    expect => sub {
        my ($E) = @_;
        for my $id (@PD) {
            my ($d, $n) = @{ $got{pd}{$id} }{qw(d n)};
            $E->ok(($n >= 1 ? 1 : 0), "$id: rows asserted ($n)");
            $E->is($d->{total}, $n, "$id: every asserted denial counted");
            my %want;
            for my $a (@{ $x{$id}{step_asserts} }) {
                for my $r (grep { ($_->{ev} // '') eq 'permission_denied' && $_->{fields} } @{ $a->{rows} || [] }) {
                    $want{ $r->{fields}{turn_kind} } += $r->{count} // 1;
                    $want{_plugin} += $r->{count} // 1 if ($r->{fields}{turn_kind} // '') eq 'post-compaction'
                                                          && ($r->{fields}{caused_by} // '') eq 'plugin';
                }
            }
            $E->is($d->{turn_kind}{$_} // 0, $want{$_}, "$id: turn_kind $_") for grep { !/\A_/ } sort keys %want;
            $E->is($d->{post_compaction_plugin} // 0, $want{_plugin} // 0, "$id: post-compaction caused by the plugin");
        }
        $E->is($got{pd}{'S-21-pd'}{d}{turn_kind}{'post-compaction'}, 1, 'S-21-pd: one post-compaction denial');
        $E->is($got{pd}{'S-21-pd-stale'}{d}{turn_kind}{'post-compaction'} // 0, 0, 'S-21-pd-stale: none post-compaction');
        for my $id (@MOD) {
            my ($r, $n, $j) = @{ $got{mod}{$id} }{qw(row conflicts want)};
            $E->ok((ref $r eq 'HASH' ? 1 : 0), "$id: the joined rollup row") or next;
            for my $k (grep { $_ ne 'join_conflict' && $_ ne 'nonce' } sort keys %$j) {
                $E->is($r->{$k}, $j->{$k}, "$id: joined $k");
            }
            $E->is(($r->{_join_conflict} ? 1 : 0), $j->{join_conflict}, "$id: join_conflict as the reader view says");
            $E->is($n, $j->{join_conflict}, "$id: join_conflict count");
        }
    },
};
