# AT-WB-08, watcher half (W-BETA B.5, D; needs/core-to-watch.md §4; BUILD-ROUND-9 WCH-09):
# `report` writes config.json from core's `settings::export_view`, which returns an ordered
# object (`jsonc::obj`, a blessed array of key/value pairs) of exported values. The watcher
# wraps it: {available: true, keys: {<key>: {class, value, default, clamped}}}. `class` comes
# from `%settings::EXPORT`; `default` compares the exported value with core's export of the
# key's default (`export_view({values => defaults})`); `clamped` marks a number the clamp
# would move (the manifest's min/max, the window floor, the handoff-turn token bounds, and
# the MOD-SPEC §1.2 soft max and target clamp). `report` runs without rc::init, so the
# watcher passes the resolved settings (settings::resolve) instead of relying on export_view's
# no-argument rc::settings() read. A failing export_view gives
# {available: false, why: export-view-failed}. The file passes the identity and secret scans
# (not withheld) and holds no path.
my %got;
my @K = ([handoff_root => 'dir', "~/.local/state/$T::BRAND/handoffs", 'path'], [disposable_keep_days => 'num', 0, 'num'],
         [triggers => 'bool', 1, 'bool'], [compact_target_tokens => 'num', 400000, 'num'],
         [compact_soft_max_tokens => 'num', 600000, 'num'], [native_window_tokens => 'num', 0, 'num'],
         [handoff_turn => 'str', 'halt', 'enum'], [handoff_turn_max_tokens => 'num', 64000, 'num'],
         [watcher => 'str', 'shadow', 'enum'], [deny_class_patterns => 'str', '', 'list']);
my %cur;
# A stand-in for core's export_view (wp/core settings.pm): the same return type and classes;
# a path is `default` when it ends like the default (the defaults may arrive tilde-expanded).
# With no argument core reads rc::settings(), which `report` never initialises: no values.
my $stub = sub {
    my ($r) = @_;
    my $v = $r ? $r->{values} : {};
    my @kv;
    for my $k (@K) {
        my ($key, undef, $fb, $class) = @$k;
        my $x = $v->{$key};
        my $out = $class eq 'num' ? 0 + $x : $class eq 'bool' ? jsonc::bool($x) : $class eq 'enum' ? $x
                : $class eq 'list' ? scalar(grep { length } split /;/, $x // '')
                : (($x // '') =~ m{/\.local/state/[^/]+/handoffs\z} ? 'default' : 'custom-in-home');
        push @kv, $key => $out;
    }
    return jsonc::obj(@kv);
};
{
    allow_canary => 1,
    files => T::beta_install(),
    transcript => [ T::prompt(0) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              require settings;
              require jsonc;
              require ctx;
              require watch::export;
              no warnings qw(redefine once);
              local @settings::KEYS = @K;
              local %settings::EXPORT = map { $_->[0] => $_->[3] } @K;
              local *settings::export_view = $stub;
              local *ctx::user_config = sub { return {} };
              local *settings::resolve = sub { return { values => {%cur}, source => {}, notes => [] } };
              my $ctx = watch::ctx::init({ sid => $T::SID, watch => $v->{WATCH}, root => $v->{ROOT},
                                           plugin_root => $v->{PLUGIN}, settings => {}, now => $T::BASE + 100 });
              %cur = (handoff_root => "$v->{HOME}/notes", disposable_keep_days => 3, triggers => 1,
                      compact_target_tokens => 400000, compact_soft_max_tokens => 900000, native_window_tokens => 800000,
                      handoff_turn => 'halt', handoff_turn_max_tokens => 10000, watcher => 'shadow', deny_class_patterns => 'a;b');
              $got{c1} = watch::export::_config($ctx);
              $got{vocab} = watch::export::vocabulary('brandx');
              my $res = watch::export::build($ctx, salt => 'k' x 32, install_id => '0123456789abcdef', now => $T::BASE + 100,
                                             identity => watch::export::identity_list($ctx, no_git => 1));
              $got{withheld} = [ map { $_->{file} } @{ $res->{withheld} } ];
              ($got{file}) = map { $_->[1] } grep { $_->[0] eq 'config.json' } @{ $res->{entries} };
              $got{home} = $v->{HOME};
              $cur{native_window_tokens} = 50000;
              $got{c2} = watch::export::_config($ctx);
              local *settings::export_view = sub { die "boom\n" };
              $got{c3} = watch::export::_config($ctx);
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my $c = $got{c1} || {};
        my $k = ref $c->{keys} eq 'HASH' ? $c->{keys} : {};
        my $b = sub { my $x = shift; return ref $x eq 'SCALAR' ? ($$x ? 'true' : 'false') : defined $x ? "$x" : 'undef' };
        $E->is($b->($c->{available}), 'true', 'config.json is available');
        $E->is(join(',', sort keys %$k), join(',', sort map { $_->[0] } @K), 'every exported key, nothing else');
        my %want = (
            triggers                => [ 'bool', 'true', 'true', 'false' ],
            disposable_keep_days    => [ 'num', 3, 'false', 'false' ],
            compact_soft_max_tokens => [ 'num', 900000, 'false', 'true' ],
            compact_target_tokens   => [ 'num', 400000, 'true', 'false' ],
            handoff_turn_max_tokens => [ 'num', 10000, 'false', 'true' ],
            native_window_tokens    => [ 'num', 800000, 'false', 'false' ],
            handoff_root            => [ 'path', 'custom-in-home', 'false', 'false' ],
            handoff_turn            => [ 'enum', 'halt', 'true', 'false' ],
            watcher                 => [ 'enum', 'shadow', 'true', 'false' ],
            deny_class_patterns     => [ 'list', 2, 'false', 'false' ],
        );
        for my $key (sort keys %want) {
            my $e = ref $k->{$key} eq 'HASH' ? $k->{$key} : {};
            my ($cl, $val, $def, $clamp) = @{ $want{$key} };
            $E->is($e->{class} // '', $cl, "$key class");
            $E->is($b->($e->{value}), "$val", "$key value");
            $E->is($b->($e->{default}), $def, "$key default mark");
            $E->is($b->($e->{clamped}), $clamp, "$key clamped mark");
        }
        $E->is(join(',', @{ $got{withheld} || [] }), '', 'nothing withheld');
        my $f = $got{file} // '';
        $E->ok(($f =~ /"keys":\{/ && $f =~ /"default":(?:true|false)/ ? 1 : 0), 'config.json in the bundle has the marks');
        $E->ok((index($f, $got{home} // "\0") < 0 && $f !~ m{/U[s]ers/} ? 1 : 0), 'no path in config.json');
        my $k2 = ref $got{c2}{keys} eq 'HASH' ? $got{c2}{keys} : {};
        $E->is($b->($k2->{native_window_tokens}{clamped}), 'true', 'a window below the floor is clamped');
        $E->is($b->($got{c3}{available}), 'false', 'a failing export_view: not available');
        $E->is($got{c3}{why} // '', 'export-view-failed', 'and says why');
        # E-W-1 (provisional): config.json's own words are bundle vocabulary, so an identity
        # string that is exactly one of them (a repo folder named `default` or `clamped`) does
        # not withhold the file.
        my $vo = $got{vocab} || {};
        $E->ok(($vo->{$_} ? 1 : 0), "vocabulary has config.json's word $_")
            for qw(keys class value default clamped custom-in-home unset disposable_keep_days handoff_turn_max_tokens);
    },
};
