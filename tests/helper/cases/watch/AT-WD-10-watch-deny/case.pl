# AT-WD-10, watcher half (PKG-RUNTIME E.1; BUILD-ROUND-9 WCH-05): the watcher keeps core's
# `permission_denied` rows in its row cache and reads `turn_kind` (with `post-compaction`
# for the first turn after a deferred PostCompact), `caused_by` and `guard_class` into the
# D-13 counts. Content-free: classes and counts only.
my @rows = (
    T::row('permission_denied', 10, writer => 'classic', tool_name => 'Bash', reason_class => 'rule',
           guard_class => 'sleep-poll', turn_kind => 'post-compaction', caused_by => 'plugin'),
    T::row('permission_denied', 20, writer => 'classic', tool_name => 'Bash', reason_class => 'rule',
           guard_class => 'routing', turn_kind => 'other', caused_by => 'session'),
    T::row('permission_denied', 30, writer => 'classic', tool_name => 'Edit', reason_class => 'classifier-unavailable',
           guard_class => 'other', turn_kind => 'post-compaction', caused_by => 'session'),
    T::row('permission_denied', 40, writer => 'classic', tool_name => 'Bash', reason_class => 'rule',
           guard_class => undef, turn_kind => undef, caused_by => undef),
);
my %got;
{
    transcript => [ T::prompt(0), T::assistant_text(1) ],
    files => [ { path => '$WATCH/$SID.classic.jsonl', jsonl => \@rows } ],
    steps => [
        { call => 'stop', at => 100 },
        { call => 'code', code => sub {
              my ($v) = @_;
              require watch::rules;
              my $ctx = watch::ctx::init({ sid => $T::SID, watch => $v->{WATCH}, root => $v->{ROOT},
                                           plugin_root => $v->{PLUGIN}, settings => {}, now => $T::BASE + 200 });
              $got{d} = watch::rules::deny_summary(watch::rules::load_session($ctx));
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my $d = $got{d} || {};
        $E->is($d->{total}, 4, 'four denials read from the cache');
        $E->is($d->{turn_kind}{'post-compaction'}, 2, 'two in a post-compaction turn');
        $E->is($d->{turn_kind}{other}, 1, 'one other');
        $E->is($d->{turn_kind}{unknown}, 1, 'a row without turn_kind counts as unknown');
        $E->is($d->{post_compaction_plugin}, 1, 'one post-compaction denial caused by the plugin');
        $E->is($d->{caused_by}{session}, 2, 'caused_by session');
        $E->is($d->{guard_class}{'sleep-poll'}, 1, 'guard_class counted');
    },
};
