# WATCH M-09 in-flight elements by the spec's literals (BUILD-PLAN §3.4: the
# watcher hard-codes no regex; finding TF-5): rows are the lines matching
# `inflight_compact_row_re`, the marker is `more_compaction_re`, and "over 8"
# is `inflight_max_rows`, all read from the shipped spec asset. A table line
# (`| B-3 |`), a labelled line (`Row: B-4 ...`) and a bare `+3 more items` are
# not the compaction form. Without the literals the elements are null.
my $spec = watch::io::read_json_file(File::Basename::dirname(Cwd::abs_path(__FILE__))
                                     . '/../../../../../plugin/assets/handoff-spec.json') || {};
my %ts = %{ main::spec_for_tests() };
$ts{$_} = $spec->{$_} for qw(inflight_compact_row_re more_compaction_re inflight_max_rows);
my $mid = "\xc2\xb7";
my $n = '1f1f0001';
my @B = ("- B-1 bash_1 $mid shell $mid running $mid make test", "- B-2 agent_x $mid agent $mid running $mid review",
         '| B-3 | task | running |', "Row: B-4 x $mid shell $mid running", '+3 more items');
my $body = T::main_body(nonce => $n, B => \@B);
my @nine = map { "- B-$_ id_$_ $mid shell $mid running $mid x" } 1 .. 9;
my %direct;
{
    spec => \%ts,
    files => [ { path => "\$WATCH/\$SID/dispatch/$n.json", json => T::dispatch($n, 8) } ],
    steps => [
        { call => 'hook', event => 'PostCompact', at => 13, payload => { trigger => 'auto', compact_summary => $body },
          ctx => { detect => { verdict => 'ok', nonce => $n, scope => 'main', marker_line => 1, sentinel_from_end => 1,
                               normalized => $body } } },
        { call => 'code', code => sub {
              my $over = watch::shape::metrics(body => T::main_body(nonce => $n, B => [ @nine, '+2 more: B-10, B-11' ]),
                                               spec => \%ts, is_main => 1);
              my %bare = %ts;
              delete @bare{qw(inflight_compact_row_re more_compaction_re inflight_max_rows)};
              my $none = watch::shape::metrics(body => $body, spec => \%bare, is_main => 1);
              %direct = (over => $over->{elements}, none => $none->{elements});
          } },
    ],
    expect => sub {
        my ($E) = @_;
        $E->ok(defined $spec->{inflight_compact_row_re} && defined $spec->{more_compaction_re}, 'the shipped spec has both literals');
        my ($p) = $E->rows('classic', 'postcompact');
        my $e = $p->{elements} || {};
        $E->is($e->{inflight_rows}, 2, 'two rows in the compaction form');
        $E->is($e->{inflight_more_marker}, 0, 'a bare "+3 more items" is not the marker');
        $E->is($e->{inflight_over_8}, 0, 'not over the cap');
        my $o = $direct{over} || {};
        $E->is("$o->{inflight_rows}/" . Checker::truthy($o->{inflight_over_8}) . '/' . Checker::truthy($o->{inflight_more_marker}),
               '9/1/1', 'nine rows are over inflight_max_rows, with the marker');
        my $z = $direct{none} || {};
        $E->is(join(',', map { defined $z->{$_} ? 'set' : 'null' } qw(inflight_rows inflight_over_8 inflight_more_marker)),
               'null,null,null', 'no literals, no element');
    },
};
