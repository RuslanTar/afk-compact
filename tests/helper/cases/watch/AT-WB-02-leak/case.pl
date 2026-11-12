# AT-WB-02 leak canary, AT-WB-07 zip shape, AT-WB-01 drop counts.
# A fixture install plants unique canaries in the home path, the repo,
# branch and bucket names, a ticket id, summary and handoff text, a jobs command, evidence
# paths, a queue question, a draft, unknown fields and an unknown event, plus secret-shaped
# values. `report` builds a zip; every entry is unpacked and none holds any canary, the raw
# session id, agent id or ht, the user name or the host name. The zip holds only the B.5
# names, mode 0600, the manifest's sha256 values match, `report verify` passes, and a zip with
# a changed byte or a `..` name fails verify.
my %got;
{
    needs => [q(nonroot)], needs_note => q(the user name root is a word the bundle holds, so the user-name canary cannot be checked; the whole case skips),
    allow_canary => 1,
    files => T::beta_install(),
    transcript => [ T::prompt(0) ],
    steps => [
        { call => 'code', code => sub { my ($v) = @_; watch::io::mkdir_p("$v->{TMP}/out") } },
        { call => 'cli', argv => [ 'report', '--out', '$TMP/out' ], env => { STORE_TEST_NO_GIT => '1' },
          stdout_re => qr/\AREPORT \S+\.zip \d/ },
        { call => 'code', code => sub {
              my ($v) = @_;
              my @z = T::zips_in("$v->{TMP}/out");
              $got{zips} = \@z;
              return unless @z == 1;
              $got{mode} = (stat $z[0])[2] & 07777;
              $got{e} = T::zip_entries($z[0]);
              $got{raw} = watch::io::slurp($z[0]);
              my $l = main::cli_launcher();
              $got{verify} = `'$l' report verify --zip '$z[0]' 2>&1`;
              $got{verify_exit} = $? >> 8;
              # A changed byte inside an entry, and a `..` name: both must fail verify.
              my $bad = $got{raw};
              # the first entry (README.txt) starts after its 30-byte header and 10-byte name
              substr($bad, 50, 1) = chr(ord(substr($bad, 50, 1)) ^ 0x20);
              main::write_file("$v->{TMP}/bad1.zip", $bad, 0600);
              $got{bad1} = `'$l' report verify --zip '$v->{TMP}/bad1.zip' 2>&1`;
              $got{bad1_exit} = $? >> 8;
              (my $b2 = $got{raw}) =~ s/config\.json/..\/..\/x.jso/g;
              main::write_file("$v->{TMP}/bad2.zip", $b2, 0600);
              $got{bad2} = `'$l' report verify --zip '$v->{TMP}/bad2.zip' 2>&1`;
              $got{bad2_exit} = $? >> 8;
          } },
    ],
    expect => sub {
        my ($E) = @_;
        my ($out) = $E->outputs;
        $E->is(scalar @{ $got{zips} || [] }, 1, 'one zip written to --out') or return;
        $E->is(sprintf('%o', $got{mode}), '600', 'zip mode 0600');
        my $e = $got{e};
        my @names = sort keys %$e;
        my @rows = grep { m{\Arows/} } @names;
        $E->is(join(',', grep { !m{\Arows/} } @names), 'README.txt,config.json,keep-warm.json,manifest.json,probes.json,sizes.json',
               'the fixed B.5 names');
        $E->is(scalar @rows, 1, 'one rows file (one session)');
        $E->ok(($rows[0] =~ m{\Arows/[0-9a-f]{12}\.jsonl\z} ? 1 : 0), "rows file named by a 12-hex hash ($rows[0])") if @rows;
        $E->ok((!grep { $_->{symlink} || $_->{error} } values %$e) ? 1 : 0, 'no symlink entries, every CRC good');
        my $all = join("\n", map { $_->{data} // '' } values %$e);
        my @canaries = (@T::BETA_CANARIES, $E->var('HOME'), $E->var('TMP'), (getpwuid($<))[0], (POSIX::uname())[1]);
        for my $c (@canaries) {
            next unless defined $c && length $c >= 4;
            $E->ok((index(lc $all, lc $c) < 0 ? 1 : 0), "no '$c' in the bundle");
            $E->ok((index($got{raw}, $c) < 0 ? 1 : 0), "no '$c' in the zip bytes");
        }
        my $m = eval { watch::json::decode($e->{'manifest.json'}{data}) } || {};
        $E->ok(($m->{schema} =~ /\A[a-z0-9-]+-report\/1\z/ ? 1 : 0), "manifest schema ($m->{schema})");
        $E->ok(($m->{install_id} =~ /\A[0-9a-f]{16}\z/ ? 1 : 0), 'install id in the manifest');
        $E->is($m->{dropped}{mystery_event}, 1, 'the unknown event is dropped and counted');
        $E->is($m->{dropped}{'dispatch.cwd'}, 1, 'an unknown field is dropped and counted');
        $E->is($m->{dropped}{'heal.command'}, 1, 'a heal command is never exported');
        my %sha = map { $_->{name} => $_->{sha256} } @{ $m->{files} || [] };
        for my $n (grep { $_ ne 'manifest.json' } @names) {
            $E->is($sha{$n}, sha::hex256($e->{$n}{data}), "manifest sha256 of $n");
        }
        my @r = map { watch::json::decode($_) } grep { /\S/ } split /\n/, ($e->{ $rows[0] }{data} // '');
        my ($copy) = grep { $_->{ev} eq 'copy' } @r;
        $E->is($copy->{rel_path}, 'main', 'copy rel_path becomes its slot');
        my ($cf) = grep { $_->{ev} eq 'copy_failed' } @r;
        $E->is($cf->{reason}, 'other', 'a value outside its class becomes other');
        my ($al) = grep { $_->{ev} eq 'alert' } @r;
        $E->ok(($al->{key}{actor} =~ /\A[0-9a-f]{12}\z/ ? 1 : 0), 'an agent id is hashed');
        $E->is($al->{key}{session_id}, $al->{sid}, 'one sid hashes to one value');
        my ($pc) = grep { $_->{ev} eq 'postcompact' } @r;
        # fixed section ids (spec_version 2), never a position or a slug
        $E->is(join(',', map { "$_=$pc->{section_chars}{$_}" } sort keys %{ $pc->{section_chars} || {} }),
               'main:decisions=40,main:resume-here=300,other=8,preamble=7,sub:task=20',
               'section_chars: slugs and literals become fixed section ids, an unknown heading or slug other');
        $E->is($m->{spec_version}, 2, 'manifest spec_version 2');
        $E->ok((!exists $pc->{ledger}{excerpt} ? 1 : 0), 'an unknown nested field is dropped');
        my ($roll) = grep { $_->{ev} eq 'compaction' } @r;
        $E->is($roll->{copy_path}, 'main', 'rollup copy path becomes its slot');
        $E->is(scalar(grep { $_->{ev} eq 'skip' } @r), 1, 'events/*.json rows are included');
        $E->ok(($out->{stdout} =~ /^FILES 7: README\.txt, manifest\.json, config\.json, probes\.json, sizes\.json, keep-warm\.json, rows\/ \(1 sessions, \d+ rows, 2026-10-21\.\.2026-10-21\)$/m ? 1 : 0),
               "FILES line ($out->{stdout})");
        $E->ok(($out->{stdout} =~ /^NOT INCLUDED: conversation text, summaries, handoffs, commands, file paths, repo and branch names, settings paths$/m ? 1 : 0), 'NOT INCLUDED line');
        $E->ok(($out->{stdout} =~ /^SEND: attach this file to a message to the developer\. Nothing was uploaded\.$/m ? 1 : 0), 'SEND line');
        $E->ok(($out->{stdout} =~ /^REVEAL: ! / ? 1 : 0) || ($out->{stdout} =~ /^REVEAL: ! /m ? 1 : 0), 'REVEAL line shown');
        $E->is($got{verify_exit}, 0, "report verify passes ($got{verify})");
        $E->is($got{bad1_exit}, 1, "a changed byte fails verify ($got{bad1})");
        $E->is($got{bad2_exit}, 1, "a `..` name fails verify ($got{bad2})");
        $E->ok(($got{bad2} =~ /VERIFY FAIL name: \.\.\/\.\.\/x\.jso/ ? 1 : 0), 'the bad name is named');
    },
};
