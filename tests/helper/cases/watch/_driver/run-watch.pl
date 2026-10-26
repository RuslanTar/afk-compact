#!/usr/bin/perl
# run-watch.pl: library-level driver for the WP-watch cases (WATCHER-SPEC §9).
#
# Usage: run-watch.pl [CASE_DIR...]   (default: every case dir beside _driver)
#
# Each case dir holds `case.pl`, which returns a hash: `files` (records to
# place), `transcript` / `subagents` (synthetic JSONL rows), `steps` (hook,
# stop, append, move, cli calls) and `expect` (a sub given the checker).
# Steps call watch::on_hook / watch::on_stop in-process with the ctx core will
# pass, plus `cli` steps that run the real launcher (`stdin_vars => 1` fills
# $WATCH, $SID, $PROJ, ... in their stdin). Every call's stdout and stderr are
# captured and must be empty unless a step says otherwise.
# A case that returns `skip => <reason>` (its input, e.g. a WP-fix fixture, is not on this
# branch yet) prints `ok - <id> # SKIP <reason>` and runs nothing. A case that needs a tool
# not on PATH (`needs => ["cmd:<name>"]`) prints `not ok - <id> # TODO not run: needs <name>
# ...`, counted as not run, neither passed nor skipped; the run does not fail on it.
# Each case runs in a fresh temp HOME with STORE_TEST_MODE=1.
#
# This driver exists because the core case runner (tests/helper/run.*), the
# core `hook` dispatcher and the shared watcher fixtures are other work
# packages; at integration these cases also run through `hook <Event>`.
use strict;
use warnings;
no warnings q(once);
use Cwd ();
use File::Basename ();
use File::Temp ();
use POSIX ();

my $HERE;
BEGIN { $HERE = File::Basename::dirname(Cwd::abs_path(__FILE__)) }
my $REPO = Cwd::abs_path("$HERE/../../../../..");
use lib "$HERE";
BEGIN { unshift @INC, File::Basename::dirname(Cwd::abs_path(__FILE__)) . '/../../../../../plugin/helper/lib' }
use T;
# core's util and sha, loaded as the helper (main.pl) always loads them: without Digest::SHA
# (Fedora's perl-interpreter) the watcher's sha256 falls back to sha::hex256
BEGIN { require "util.pm"; require "sha.pm" }
use watch;
use watch::json;
use watch::io;
use watch::alerts;

$ENV{TZ} = 'Etc/GMT-3';
POSIX::tzset();

my $brand_json = watch::io::read_json_file("$REPO/brand.json") || {};
$T::BRAND = $brand_json->{name} || 'plugin';
$T::REPO = $REPO;

my @dirs = @ARGV ? @ARGV : map { "$HERE/../$_" } grep { -f "$HERE/../$_/case.pl" } sort(watch::io::list_dir("$HERE/.."));
my ($pass, $fail, $skipped) = (0, 0, 0);
our ($SKIP, $NOTRUN);
my $notrun = 0;
my @failed;

for my $dir (@dirs) {
    my $id = File::Basename::basename(Cwd::abs_path($dir));
    local ($SKIP, $NOTRUN);
    my @errs = eval { run_case(Cwd::abs_path($dir)) };
    push @errs, "died: $@" if $@;
    if (!@errs && defined $NOTRUN) { $notrun++; print "not ok - $id # TODO not run: $NOTRUN\n"; next }
    if (!@errs && defined $SKIP) { $skipped++; print "ok - $id # SKIP $SKIP\n"; next }
    if (@errs) {
        $fail++;
        push @failed, $id;
        print "not ok - $id\n";
        print "#   $_\n" for @errs;
    } else {
        $pass++;
        print "ok - $id\n";
    }
}
print "# watch cases: $pass passed, $fail failed" . ($skipped ? ", $skipped skipped" : '') . ($notrun ? ", $notrun not run" : '') . "\n";
exit($fail ? 1 : 0);

sub spec_for_tests {
    my $o = "\xe2\x9f\xaa";
    my $c = "\xe2\x9f\xab";
    my $b = quotemeta $T::BRAND;
    return {
        # `## Approvals` since the 2026-10-23 scoped-approval ruling (spec §2, AP-3).
        sections_main => ['## Resume here', '## User constraints', '## Approvals', '## Decisions and do-not-re-raise', '## In flight',
                          '## Live state', '## Open questions', '## Location', '## Work done and findings',
                          '## Evidence', '## Next steps'],
        sections_subagent => ['## Task as assigned', '## Constraints from the parent', '## Report', '## Done',
                              '## Findings', '## Produced but not yet delivered', '## Own background tasks',
                              '## Next action'],
        # owner xxxxxxxx-34 ("Stable section ids"): spec_version 2 and the fixed section ids, as shipped
        spec_version => 2,
        section_ids => { '## Resume here' => 'main:resume-here', '## User constraints' => 'main:user-constraints',
                         '## Approvals' => 'main:approvals', '## Decisions and do-not-re-raise' => 'main:decisions',
                         '## In flight' => 'main:in-flight', '## Live state' => 'main:live-state',
                         '## Open questions' => 'main:open-questions', '## Location' => 'main:location',
                         '## Work done and findings' => 'main:work-done', '## Evidence' => 'main:evidence',
                         '## Next steps' => 'main:next-steps', '## Task as assigned' => 'sub:task',
                         '## Constraints from the parent' => 'sub:parent-constraints', '## Report' => 'sub:report',
                         '## Done' => 'sub:done', '## Findings' => 'sub:findings',
                         '## Produced but not yet delivered' => 'sub:undelivered',
                         '## Own background tasks' => 'sub:background-tasks', '## Next action' => 'sub:next-action' },
        time_re => "[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} [+-][0-9]{4}",
        time_legacy_re => "([0-9]{2}-[0-9]{2} )?[0-9]{2}:[0-9]{2}",
        marker_re => "^$o$b v1 n=([0-9a-f]{8}) s=(main|sub|manual)$c\$",
        sentinel_re => "^$o/$b n=([0-9a-f]{8})$c\$",
        instr_marker_re => "$o$b v1 n=([0-9a-f]{8}) s=(main|sub)$c",
        status_words => [qw(proposed queued implemented tested committed pushed merged deployed published installed blocked)],
        none_forms_compaction => ['none stated', 'Nothing in flight as of the last message (not checked)',
                                  'none beyond git (not checked)', 'none'],
        fold_line_re => '(?:[UDX]-[0-9]+, )*[UDX]-[0-9]+ settled; full text in \S+',
        clutter_classes => { abs_path_line => '^\s*/\S+\s*$', tmp_path => '(?:/private)?/tmp/\S+', log_line => '^.*\b(?:WARN|ERROR)\b.*$' },
        outward_classes => { push => '\bgit\s+push\b(?!.*--force)', 'force-push' => '\bgit\s+push\b.*--force',
                             'mcp-write' => '\Amcp__[A-Za-z0-9_-]+__(?:create|update|delete|send)' },
        secret_rules => [ { id => 'jwt', class => 'HARD', re => 'eyJ[A-Za-z0-9_-]{8,}' },
                          { id => 'kv', class => 'WARN', re => '(?:pass|secret|token|key)\s*[=:]\s*\S{6,}' } ],
        alert_texts => { map { sprintf('A-%02d', $_) => sprintf('test text %02d', $_) } 1 .. 29 },
    };
}

sub sub_vars {
    my ($s, $v) = @_;
    $s =~ s/\$(WATCH|SID|PROJ|HOME|ROOT|TMP|BRAND|PLUGIN)\b/$v->{$1}/g;
    return $s;
}

sub write_file {
    my ($path, $content, $mode) = @_;
    watch::io::mkdir_p(watch::io::dirname_of($path));
    open(my $fh, '>:raw', $path) or die "write $path: $!";
    print $fh $content;
    close $fh;
    chmod($mode // 0600, $path);
}

sub jsonl { return join('', map { watch::json::encode($_) . "\n" } @{ $_[0] }) }

# `cli` steps run a staged copy of plugin/, made once per driver run, as the core case
# runner (tests/helper/run.pl stage_plugin) does: the copy holds core's CR-F34 test seam
# mark (settings::$TEST_CONSENT_MARK), so with STORE_TEST_MODE=1 the consent folder is
# the case's $HOME/.claude. The repo's plugin/ never gets the mark.
my $CLI_STAGE;
sub copy_tree {
    my ($src, $dst) = @_;
    watch::io::mkdir_p($dst);
    for my $e (watch::io::list_dir($src)) {
        next if $e eq 'node_modules';
        my ($s, $d) = ("$src/$e", "$dst/$e");
        if (-l $s) { symlink(readlink($s), $d) or die "symlink $d: $!"; next }
        if (-d $s) { copy_tree($s, $d); next }
        write_file($d, watch::io::slurp($s), (stat $s)[2] & 07777);
    }
    chmod((stat $src)[2] & 07777, $dst);
}
sub cli_launcher {
    if (!defined $CLI_STAGE) {
        my $base = File::Temp::tempdir('watchstage-XXXXXX', TMPDIR => 1, CLEANUP => 1);
        copy_tree("$REPO/plugin", "$base/plugin");
        require settings;
        write_file("$base/plugin/$settings::TEST_CONSENT_MARK", "watch driver test stage\n", 0644);
        # WP-watch's `report` command (WCH-09) until WP-core lists it in main.pl's %KNOWN
        # (needs/watch-to-core.md W2C-1): the staged copy only, never the repo's main.pl.
        my $mp = "$base/plugin/helper/main.pl";
        my $m = watch::io::slurp($mp);
        if (defined $m && $m !~ /^\s+watch report\b/m && $m =~ s/^(\s+)watch\n\);/$1watch report\n);/m) {
            write_file($mp, $m, (stat $mp)[2] & 07777);
        }
        $CLI_STAGE = "$base/plugin";
    }
    my $l = "$CLI_STAGE/scripts/$T::BRAND-store";
    die "run-watch.pl: no launcher at plugin/scripts/$T::BRAND-store (run tools/build)\n" unless -x $l;
    return $l;
}

sub capture {
    my ($code) = @_;
    my $tmp = File::Temp->new;
    my $tmpe = File::Temp->new;
    open(my $so, '>&', \*STDOUT) or die;
    open(my $se, '>&', \*STDERR) or die;
    open(STDOUT, '>', $tmp->filename) or die;
    open(STDERR, '>', $tmpe->filename) or die;
    my @r = eval { $code->() };
    my $err = $@;
    close STDOUT; close STDERR;
    open(STDOUT, '>&', $so) or die;
    open(STDERR, '>&', $se) or die;
    die $err if $err;
    return (watch::io::slurp($tmp->filename), watch::io::slurp($tmpe->filename), @r);
}

sub run_case {
    my ($dir) = @_;
    T::reset_ids();
    require watch::sweep;
    $watch::alerts::DELIVERY = q(status-only);
    $watch::sweep::RUN_BYTES = 5 << 20;
    my $case = do "$dir/case.pl";
    die "case.pl: $@" if $@;
    die "case.pl did not return a hash" unless ref $case eq 'HASH';
    # `skip => reason`: a case whose input is not on this branch yet (a WP-fix fixture)
    if (defined $case->{skip}) { $SKIP = $case->{skip}; return () }
    # `needs => [...]`, as in the core runner: "nonroot" skips when this runs as root (uid 0
    # ignores file modes; its user name is a word every bundle holds); "cmd:<name>" is not
    # run while <name> is not on PATH (a missing tool: neither a pass nor a skip).
    # `needs_note` says what the case loses then.
    my @path = split /:/, $ENV{PATH} // '';
    my @cmd = grep { my $c = $_; !grep { -x "$_/$c" } @path } map { /\Acmd:(.+)\z/ ? $1 : () } @{ $case->{needs} || [] };
    my $note = defined $case->{needs_note} ? ": $case->{needs_note}" : '';
    if (@cmd) { $NOTRUN = join(', ', map { "needs $_ (not on PATH)" } @cmd) . $note; return () }
    if ($> == 0 && grep { $_ eq 'nonroot' } @{ $case->{needs} || [] }) { $SKIP = "needs nonroot (running as root)$note"; return () }
    my $tmp = File::Temp::tempdir('watchcase-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    my %v = (TMP => $tmp, HOME => "$tmp/home", SID => $T::SID, BRAND => $T::BRAND, PLUGIN => "$tmp/plugin");
    $v{ROOT} = "$v{HOME}/.claude/handoffs";
    $v{WATCH} = "$v{ROOT}/.watch";
    $v{PROJ} = "$v{HOME}/.claude/projects/-synthetic-proj";
    watch::io::mkdir_p($v{HOME});
    local $ENV{HOME} = $v{HOME};
    local $ENV{STORE_TEST_MODE} = '1';
    # A plugin root of our own: manifest + spec-literals for the test (the
    # real assets are generated from WP-text's handoff-spec.md).
    write_file("$v{PLUGIN}/.claude-plugin/plugin.json", watch::json::encode({ name => $T::BRAND, version => '0.1.0' }));
    my $spec = $case->{spec} || spec_for_tests();
    write_file("$v{PLUGIN}/assets/handoff-spec.json", watch::json::encode($spec)) unless $case->{no_spec};
    my $tpath = "$v{PROJ}/$T::SID.jsonl";
    $v{TRANSCRIPT} = $tpath;
    write_file($tpath, jsonl($case->{transcript} || [])) if $case->{transcript};
    for my $agent (sort keys %{ $case->{subagents} || {} }) {
        write_file("$v{PROJ}/$T::SID/subagents/agent-$agent.jsonl", jsonl($case->{subagents}{$agent}));
    }
    for my $f (@{ $case->{files} || [] }) {
        my $p = sub_vars($f->{path}, \%v);
        my $content = exists $f->{json} ? watch::json::encode($f->{json}) . "\n"
                    : exists $f->{jsonl} ? jsonl($f->{jsonl}) : ($f->{text} // '');
        write_file($p, $content, $f->{mode});
        utime($f->{mtime}, $f->{mtime}, $p) if defined $f->{mtime};
    }
    my @errs;
    my @outputs;
    for my $s (@{ $case->{steps} || [] }) {
        my $now = defined $s->{at} ? $T::BASE + $s->{at} : $T::BASE + 3600;
        local $ENV{STORE_TEST_NOW} = watch::io::iso($now);
        my %ctxbase = (sid => $T::SID, watch => $v{WATCH}, root => $v{ROOT}, plugin_root => $v{PLUGIN},
                       settings => { %{ $case->{settings} || {} } }, now => $now, pid => 4242,
                       pid_lstart => 'Tue Oct 21 13:00:00 2026', cc_version => '2.1.306');
        my $payload_tp = $s->{transcript} ? sub_vars($s->{transcript}, \%v) : $tpath;
        my ($out, $err, $ret);
        if ($s->{call} eq 'hook') {
            my $payload = { session_id => $T::SID, transcript_path => $payload_tp, cwd => "$v{HOME}/work",
                            hook_event_name => $s->{event}, %{ $s->{payload} || {} } };
            my %ctx = (%ctxbase, %{ $s->{ctx} || {} });
            ($out, $err) = capture(sub { watch::on_hook($s->{event}, $payload, \%ctx) });
        } elsif ($s->{call} eq 'stop') {
            my $payload = { session_id => $T::SID, transcript_path => $payload_tp, cwd => "$v{HOME}/work",
                            hook_event_name => 'Stop', stop_hook_active => \0, %{ $s->{payload} || {} } };
            my %ctx = (%ctxbase, payload => $payload, %{ $s->{ctx} || {} });
            ($out, $err, $ret) = capture(sub { watch::on_stop(\%ctx, $s->{deadline}) });
            push @outputs, $ret if $s->{expect_output};
            push @errs, "step stop: returned output in status-only mode" if defined $ret && !$s->{expect_output};
        } elsif ($s->{call} eq 'status') {
            my %ctx = (%ctxbase, %{ $s->{ctx} || {} });
            ($out, $err, $ret) = capture(sub { watch::status_lines($T::SID, \%ctx) });
            push @outputs, $ret;
        } elsif ($s->{call} eq 'append') {
            my $p = $s->{path} ? sub_vars($s->{path}, \%v) : $tpath;
            watch::io::mkdir_p(watch::io::dirname_of($p));
            open(my $fh, '>>:raw', $p) or die;
            print $fh jsonl($s->{rows} || []);
            print $fh $s->{raw} if defined $s->{raw};
            close $fh;
            next;
        } elsif ($s->{call} eq 'write') {
            my $p = sub_vars($s->{path}, \%v);
            write_file($p, exists $s->{json} ? watch::json::encode($s->{json}) . "\n" : jsonl($s->{jsonl} || []), $s->{mode});
            next;
        } elsif ($s->{call} eq q(code)) {
            $s->{code}->(\%v);
            next;
        } elsif ($s->{call} eq 'chmod') {
            chmod($s->{mode}, sub_vars($s->{path}, \%v));
            next;
        } elsif ($s->{call} eq 'cli') {
            my @argv = map { sub_vars($_, \%v) } @{ $s->{argv} };
            my %env = (%{ $s->{env} || {} });
            local @ENV{ keys %env } = map { sub_vars($_, \%v) } values %env;
            my $stdin = defined $s->{stdin} ? $s->{stdin} : '';
            $stdin = sub_vars($stdin, \%v) if $s->{stdin_vars};
            my $inf = File::Temp->new;
            print $inf $stdin;
            close $inf;
            my $of = File::Temp->new;
            my $ef = File::Temp->new;
            my $cmd = join(' ', map { "'" . s/'/'\\''/gr . "'" } (cli_launcher(), @argv));
            system("$cmd < '" . $inf->filename . "' > '" . $of->filename . "' 2> '" . $ef->filename . "'");
            my $code = $? >> 8;
            $out = watch::io::slurp($of->filename);
            $err = watch::io::slurp($ef->filename);
            push @outputs, { exit => $code, stdout => $out, stderr => $err };
            push @errs, "cli @argv: exit $code, want " . ($s->{exit} // 0) if $code != ($s->{exit} // 0);
            if (defined $s->{stdout_re}) {
                push @errs, "cli @argv: stdout '$out' !~ $s->{stdout_re}" unless $out =~ $s->{stdout_re};
            } elsif (!$s->{any_stdout}) {
                push @errs, "cli @argv: stdout not empty" if length $out;
            }
            next;
        } else {
            die "unknown step $s->{call}";
        }
        my $label = "step $s->{call}" . ($s->{event} ? " $s->{event}" : '');
        push @errs, "$label: stdout not empty (" . length($out) . " bytes)" if length($out // '') && $s->{call} ne 'status';
        push @errs, "$label: stderr not empty: $err" if length($err // '');
    }
    if ($ENV{WATCH_CASE_DUMP}) {
        for my $f (sort(watch::io::list_dir($v{WATCH}))) {
            next unless $f =~ /\.jsonl\z/;
            print STDERR "== $f\n", watch::io::slurp("$v{WATCH}/$f");
        }
    }
    my $E = Checker->new(\%v, \@outputs);
    $case->{expect}->($E) if ref $case->{expect} eq 'CODE';
    if (!$case->{allow_canary}) {
        my @hits = grep_tree($v{WATCH}, 'CANARY-TEXT');
        push @errs, "canary text in watch files: @hits" if @hits;
    }
    push @errs, @{ $E->{errs} };
    # The rules may read only the row kinds the incremental cache keeps
    # (watch::rules::KINDS); test mode records any other kind asked for.
    if (%watch::rules::MISSED) {
        push @errs, 'rules read kinds the cache does not keep: ' . join(',', sort keys %watch::rules::MISSED);
        %watch::rules::MISSED = ();
    }
    return @errs;
}

sub grep_tree {
    my ($dir, $needle) = @_;
    my @hits;
    my @q = ($dir);
    while (@q) {
        my $d = shift @q;
        opendir(my $dh, $d) or next;
        for my $e (grep { $_ ne '.' && $_ ne '..' } readdir $dh) {
            my $p = "$d/$e";
            if (-d $p) { push @q, $p; next }
            my $c = watch::io::slurp($p) // '';
            push @hits, $p if index($c, $needle) >= 0;
        }
        closedir $dh;
    }
    return @hits;
}

package Checker;

sub new { my ($c, $v, $o) = @_; return bless { v => $v, errs => [], outputs => $o }, $c }
sub var { return $_[0]{v}{ $_[1] } }
sub outputs { return @{ $_[0]{outputs} } }
sub path {
    my ($s, $f) = @_;
    my $v = $s->{v};
    return "$v->{WATCH}/$v->{SID}.classic.jsonl" if $f eq 'classic';
    return "$v->{WATCH}/$v->{SID}.alerts.jsonl" if $f eq 'alerts';
    return main::sub_vars($f, $v);
}
sub rows {
    my ($s, $f, $ev) = @_;
    my $rows = watch::io::read_jsonl($s->path($f));
    return grep { !defined $ev || ($_->{ev} // '') eq $ev } @$rows;
}
sub alerts {
    my ($s, $rule) = @_;
    return grep { !defined $rule || ($_->{rule} // '') eq $rule } $s->rows('alerts', 'alert');
}
sub boundaries {
    my ($s) = @_;
    return map { @{ $_->{boundaries} || [] } } $s->rows('classic', 'sweep');
}
sub ok {
    my ($s, $cond, $msg) = @_;
    push @{ $s->{errs} }, $msg unless $cond;
    return $cond;
}
sub is {
    my ($s, $got, $want, $msg) = @_;
    my $g = defined $got ? (ref $got eq 'SCALAR' ? ($$got ? 'true' : 'false') : "$got") : 'undef';
    my $w = defined $want ? "$want" : 'undef';
    push @{ $s->{errs} }, "$msg: got $g, want $w" unless $g eq $w;
}
sub count { my ($s, $n, $want, $msg) = @_; $s->is(scalar(@$n), $want, $msg) }
sub truthy { my ($v) = @_; return ref $v eq 'SCALAR' ? $$v : $v }

1;
