# AT-CAP-02, watcher half (S-SETTINGS A; BUILD-ROUND-9 WCH-02): watch/ctx.pm's fallback
# for every key it reads equals the manifest default (src/plugin.json userConfig), and
# `max_auto_continues_per_hour` defaults to 6: a mod `continue` row with 6 continues in
# the last hour raises no A-19 under default settings; 7 does (WATCHER-SPEC A-19).
use Cwd ();
use File::Basename ();
my $repo = Cwd::abs_path(File::Basename::dirname(__FILE__) . '/../../../../..');
{
    transcript => [ T::prompt(0), T::assistant_text(1) ],
    files => [ { path => '$WATCH/$SID.jsonl', jsonl => [ T::row('continue', 5, result => 'submitted', continues_last_hour => 6) ] } ],
    steps => [
        { call => 'stop', at => 100 },
        { call => 'append', path => '$WATCH/$SID.jsonl',
          rows => [ T::row('continue', 120, result => 'submitted', continues_last_hour => 7) ] },
        { call => 'stop', at => 130 },
    ],
    expect => sub {
        my ($E) = @_;
        my @a = $E->alerts('A-19');
        $E->count(\@a, 1, 'one A-19: 6 continues pass, the 7th breaches the default cap');
        $E->is($a[0]{evidence}{cap}, 6, 'A-19 evidence cap is the default 6') if @a;
        $E->is($a[0]{evidence}{continues_last_hour}, 7, 'A-19 for the 7th continue') if @a;
        my $m = watch::io::read_json_file("$repo/src/plugin.json") || {};
        my $uc = $m->{userConfig} || {};
        my $brand = (watch::io::read_json_file("$repo/brand.json") || {})->{name} // 'plugin';
        local @ENV{ grep { /\ACLAUDE_PLUGIN_OPTION_/ } keys %ENV };
        delete @ENV{ grep { /\ACLAUDE_PLUGIN_OPTION_/ } keys %ENV };
        my $s = watch::ctx::_settings({ settings => {} });
        my $n = 0;
        for my $k (sort keys %$s) {
            next unless ref $uc->{$k} eq 'HASH' && exists $uc->{$k}{default};
            my $want = $uc->{$k}{default};
            my $got = $s->{$k};
            # STATE-ROOT (0.1.2): the default names the plugin ({{plugin}} in src/plugin.json)
            if ($k eq 'handoff_root') { $want =~ s{\A~}{$ENV{HOME}}; $want =~ s/{{plugin}}/$brand/g }
            if ($k eq 'triggers') { $want = $want ? 'true' : 'false' }
            # D-72: an on/off key's manifest default (true or false) is the word the watcher runs
            ($want) = settings::switch_read($k, $want) if defined &settings::switch_read && exists $settings::SWITCH{$k};
            $n++;
            $E->is($got, $want, "ctx default for $k equals plugin.json");
        }
        $E->ok($n >= 10, "compared $n keys");
    },
};
