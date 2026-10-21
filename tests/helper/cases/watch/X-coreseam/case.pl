# The core -> watcher seam through the real launcher (BUILD-PLAN §3.6; the
# T9 incidental "AT-M3-07 shows watch_error 1"). Core's `hook` decodes the
# payload into character strings and passes its own results: PostCompact
# `detect` = {scan => {nonce, normalized, marker_line, ...}, verdict, scope,
# ...}, PreCompact `instructions` = {found, nonce, scope, has_record}. The
# watcher works on UTF-8 bytes (its codec and the spec literals), so it takes
# both in that form. An unmarked summary with a non-ASCII heading no longer
# dies in the arm fingerprint (sha256 of wide characters): its `postcompact`
# row is written with `arm_fp`, and no `watch_error` row. A marked summary
# keeps its nonce and marker positions; the PreCompact row keeps `ci_nonce`.
my $n = '6c6c0001';
my $o = "\xe2\x9f\xaa";
my $c = "\xe2\x9f\xab";
my $dash = "\xe2\x80\x94";
my $base = { session_id => '$SID', transcript_path => '$PROJ/$SID.jsonl', cwd => '$HOME/work' };
my $pre = watch::json::encode({ %$base, hook_event_name => 'PreCompact', trigger => 'auto',
                                custom_instructions => "${o}$T::BRAND v1 n=$n s=main${c}\nKeep the shape." });
my $marked = watch::json::encode({ %$base, hook_event_name => 'PostCompact', trigger => 'auto',
    compact_summary => "<summary>\n${o}$T::BRAND v1 n=$n s=main${c}\n# LAB-42 $dash retry window fix in review\n"
                     . "## Resume here\nStep 1: `git status` $dash for \"finish\"\n## Next steps\n1. git status\n"
                     . "${o}/$T::BRAND n=$n${c}\n</summary>" });
my $unmarked = watch::json::encode({ %$base, hook_event_name => 'PostCompact', trigger => 'auto',
    compact_summary => "<summary>\n# LAB-43 $dash an unmarked summary\n## Resume here\nStep 1: `make` $dash for \"x\"\n</summary>" });
{
    files => [ { path => "\$WATCH/\$SID/dispatch/$n.json", json => T::dispatch($n, 5) } ],
    transcript => [ T::prompt(0), T::assistant_text(1), T::boundary(9, trigger => 'auto'), T::summary(9.1) ],
    steps => [
        { call => 'cli', at => 6, argv => ['hook', 'PreCompact'], stdin => $pre, stdin_vars => 1 },
        { call => 'cli', at => 10, argv => ['hook', 'PostCompact'], stdin => $marked, stdin_vars => 1 },
        { call => 'cli', at => 40, argv => ['hook', 'PostCompact'], stdin => $unmarked, stdin_vars => 1 },
    ],
    expect => sub {
        my ($E) = @_;
        my @e = map { "$_->{stage}/$_->{error_class}" } $E->rows('classic', 'watch_error');
        $E->is(join(',', @e), '', 'no watch_error row');
        my ($q) = $E->rows('classic', 'precompact');
        $E->is($q->{ci_nonce}, $n, 'the PreCompact row keeps the nonce');
        my @p = $E->rows('classic', 'postcompact');
        $E->count(\@p, 2, 'two postcompact rows');
        $E->is(join('/', map { $_ // 'undef' } @{ $p[0] || {} }{qw(nonce_found marker_line verdict)}), "$n/1/ok",
               "the marked summary: nonce and marker line from core's scan");
        $E->is($p[1]{nonce_found}, undef, 'the unmarked summary has no nonce');
        $E->ok(($p[1]{arm_fp} // '') =~ /\A[0-9a-f]{12}\z/, 'the unmarked summary has its arm fingerprint');
    },
};
