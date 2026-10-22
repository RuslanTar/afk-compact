# AT-WB-03 / AT-WB-02 host and account canaries (W-BETA B.3; needs/fix-to-watch.md 1, 7): the
# identity list takes the host name from `hostname -s` run through PATH (as B.3 writes it,
# besides uname) and the account name from USER and LOGNAME (besides the user database). A
# PATH stub `hostname` and USER/LOGNAME canaries put both on the list: a session whose
# word-class field holds one of them is withheld (fail closed), and neither string is in any
# shipped file. This is the hook WP-fix's wb-canary-install recipe relies on (no
# STORE_TEST_HOSTNAME seam is needed).
my ($host, $acct) = ('wbstubhost42', 'wbstubacct42');
my $files = T::beta_install();
push @$files,
    { path => '$WATCH/0e0e0e0e-2222-4222-8222-222222222222.classic.jsonl',
      jsonl => [ T::row('copy_failed', 61, writer => 'classic', nonce => 'f0f00004', reason => $host) ] },
    { path => '$WATCH/0e0e0e0e-3333-4333-8333-333333333333.classic.jsonl',
      jsonl => [ T::row('copy_failed', 62, writer => 'classic', nonce => 'f0f00005', reason => $acct) ] };
my $path = "\$TMP/stubbin:$ENV{PATH}";
my %got;
{
    allow_canary => 1,
    files => $files,
    transcript => [ T::prompt(0) ],
    steps => [
        { call => 'code', code => sub {
              my ($v) = @_;
              watch::io::mkdir_p("$v->{TMP}/out");
              main::write_file("$v->{TMP}/stubbin/hostname", "#!/bin/sh\necho $host\n", 0755);
              require watch::export;
              local $ENV{PATH} = "$v->{TMP}/stubbin:$ENV{PATH}";
              local $ENV{USER} = $acct;
              local $ENV{LOGNAME} = $acct;
              my $ctx = watch::ctx::init({ sid => $T::SID, watch => $v->{WATCH}, root => $v->{ROOT}, plugin_root => $v->{PLUGIN},
                                           settings => {}, now => $T::BASE + 100 });
              $got{list} = watch::export::identity_list($ctx, no_git => 1);
          } },
        { call => 'cli', argv => [ 'report', '--out', '$TMP/out' ],
          env => { STORE_TEST_NO_GIT => '1', PATH => $path, USER => $acct, LOGNAME => $acct }, any_stdout => 1 },
        { call => 'code', code => sub {
              my ($v) = @_;
              my ($z) = T::zips_in("$v->{TMP}/out");
              $got{e} = $z ? T::zip_entries($z) : {};
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my %l = map { $_ => 1 } @{ $got{list} || [] };
        $E->ok(($l{$host} ? 1 : 0), 'hostname -s through PATH is on the identity list');
        $E->ok(($l{$acct} ? 1 : 0), 'USER/LOGNAME is on the identity list');
        my ($out) = $E->outputs;
        $E->is($out->{exit}, 0, 'report exit 0');
        my @wl = $out->{stdout} =~ /^WITHHELD rows\/[0-9a-f]{12}\.jsonl \(identity; please tell the developer\)$/mg;
        $E->is(scalar @wl, 2, 'both canary sessions withheld');
        my $e = $got{e};
        my $all = join("\n", map { $_->{data} // '' } values %$e);
        $E->ok((index(lc $all, $host) < 0 ? 1 : 0), 'the host canary is in no shipped file');
        $E->ok((index(lc $all, $acct) < 0 ? 1 : 0), 'the account canary is in no shipped file');
        my @rows = grep { m{\Arows/} } keys %$e;
        $E->is(scalar @rows, 1, 'the clean session ships');
    },
};
