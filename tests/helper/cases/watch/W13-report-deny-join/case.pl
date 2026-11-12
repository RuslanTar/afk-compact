# Report and status half of the denials and the boundary join:
# `watch report` reads the `permission_denied`
# rows' `turn_kind` and `caused_by` into a Denials section, keeps the `classifier-unavailable`
# reason apart as the control (out of the FR-14 guard classes, into the control bar), and
# joins core's `compaction_boundary` rows to the rollup rows by nonce on the rollup path (no
# swept boundary): a null rollup size takes the boundary value, a non-null rollup value is
# kept and the disagreement is counted as a join conflict. `status` shows the session's join
# conflicts. The same lines come from a `report` bundle's rows through `--input`.
my ($na, $nb) = ('ab000021', 'ab000022');
my @classic = (
    T::row('permission_denied', 10, writer => 'classic', tool_name => 'Bash', reason_class => 'rule',
           guard_class => 'sleep-poll', turn_kind => 'post-compaction', caused_by => 'plugin'),
    T::row('permission_denied', 20, writer => 'classic', tool_name => 'Bash', reason_class => 'rule',
           guard_class => 'routing', turn_kind => 'other', caused_by => 'session'),
    T::row('permission_denied', 30, writer => 'classic', tool_name => 'Edit', reason_class => 'classifier-unavailable',
           guard_class => 'other', turn_kind => 'post-compaction', caused_by => 'session'),
    T::row('permission_denied', 40, writer => 'classic', tool_name => 'Bash', reason_class => 'rule',
           guard_class => 'sleep-poll', turn_kind => 'nudge', caused_by => 'plugin'),
);
my @roll = (
    T::row('compaction', 100, writer => 'helper', nonce => $na, id6 => 'aaaaaa', trigger => 'auto', verdict => 'ok',
           channel => 'mod-hook', copy => 'saved', pre_tokens => undef, post_tokens => undef, duration_ms => undef,
           precomputed => \0),
    T::row('compaction_boundary', 101, writer => 'helper', nonce => $na, id6 => 'aaaaaa', boundary_uuid => 'b-a',
           pre_tokens => 790000, post_tokens => 41000, duration_ms => 31000, precomputed => \0),
    T::row('compaction', 200, writer => 'helper', nonce => $nb, id6 => 'bbbbbb', trigger => 'auto', verdict => 'ok',
           channel => 'mod-hook', copy => 'saved', pre_tokens => 450000, post_tokens => undef, duration_ms => undef,
           precomputed => \0),
    T::row('compaction_boundary', 201, writer => 'helper', nonce => $nb, id6 => 'bbbbbb', boundary_uuid => 'b-b',
           pre_tokens => 460000, post_tokens => 42000, duration_ms => 32000, precomputed => \0),
);
my @mod = (T::row('config_effective', 0, window => 800000, native_trigger => 767000, soft_max => 600000, target => 400000));
my %got;
{
    files => [
        { path => '$WATCH/$SID.classic.jsonl', jsonl => \@classic },
        { path => '$WATCH/$SID.jsonl', jsonl => \@mod },
        { path => '$WATCH/$SID/compactions.jsonl', jsonl => \@roll },
    ],
    transcript => [ T::prompt(0) ],
    steps => [
        { call => 'cli', argv => [ 'watch', 'report', '--since', 'all' ], stdout_re => qr/\AWATCH-REPORT \S+\/reports\/\S+\.md\n\z/ },
        { call => 'status', at => 300 },
        { call => 'code', code => sub { my ($v) = @_; watch::io::mkdir_p("$v->{TMP}/out") } },
        { call => 'cli', argv => [ 'report', '--out', '$TMP/out' ], env => { STORE_TEST_NO_GIT => '1' }, stdout_re => qr/\AREPORT / },
        { call => 'code', code => sub {
              my ($v) = @_;
              my ($f) = grep { /\.md\z/ } watch::io::list_dir("$v->{WATCH}/reports");
              $got{md} = watch::io::slurp("$v->{WATCH}/reports/$f") // '';
              my ($z) = T::zips_in("$v->{TMP}/out");
              my $e = T::zip_entries($z);
              for my $n (grep { m{\Arows/} } keys %$e) { main::write_file("$v->{TMP}/in/$n", $e->{$n}{data}) }
          } },
        { call => 'cli', argv => [ 'watch', 'report', '--input', '$TMP/in' ], any_stdout => 1 },
    ],
    expect => sub {
        my ($E) = @_;
        my @o = $E->outputs;
        my ($status) = grep { ref $_ eq 'ARRAY' } @o;
        my ($remote) = map { $_->{stdout} } grep { ref $_ eq 'HASH' && ($_->{stdout} // '') =~ /\A# Watch report/ } @o;
        for my $c ([ 'live', $got{md} ], [ 'remote', $remote // '' ]) {
            my ($k, $md) = @$c;
            my $has = sub { my ($re, $msg) = @_; $E->ok(($md =~ $re ? 1 : 0), "$k: $msg") };
            $has->(qr/^## Denials \(permission_denied rows\)$/m, 'Denials section');
            $has->(qr/^- Total: 4; control \(reason classifier-unavailable, kept apart\): 1$/m, 'total and control');
            $has->(qr/^- By turn kind: nudge 1, other 1, post-compaction 2$/m, 'turn_kind counts');
            $has->(qr/^- By cause: plugin 2, session 2$/m, 'caused_by counts');
            $has->(qr/^- In a post-compaction turn caused by the plugin: 1$/m, 'post-compaction plugin denials');
            $has->(qr/^- By guard class \(control excluded\): routing 1, sleep-poll 2$/m, 'guard classes without the control');
            $has->(qr/^- FR-14 Guard friction: routing 1 denials, sleep-poll 2 denials$/m, 'FR-14 leaves the control out');
            $has->(qr/^\| Deny rate, classifier-unavailable \(control\) \| within \+-50% of baseline \| 1 denials \| n\/a /m,
                  'the control bar measures the control rows');
            $has->(qr/^ 750K- 800K \| #{40} +1 <- native_trigger 767000$/m, 'the null rollup size takes the boundary value');
            $has->(qr/^ 450K- 500K \| #{40} +1 $/m, 'a non-null rollup size is kept');
            $has->(qr/^\| auto \| 2 \| 32000 \| 32000 \|$/m, 'durations from the join');
            $has->(qr/^Size join conflicts \(rollup vs compaction_boundary, the rollup value kept\): 1$/m, 'join conflict counted');
        }
        my $all = join("\n", @{ $status || [] });
        $E->ok(($all =~ /^Compaction size join conflicts this session: 1 \(the rollup value is kept\)$/m ? 1 : 0),
               "status shows the join conflict ($all)");
    },
};
