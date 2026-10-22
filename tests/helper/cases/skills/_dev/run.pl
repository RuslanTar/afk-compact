#!/usr/bin/perl
# tests/helper/cases/skills/_dev/run.pl: WP-skills dev runner for the HT cases.
#
# Usage: /usr/bin/perl tests/helper/cases/skills/_dev/run.pl [CASE_DIR …]
#   (default: every tests/helper/cases/skills/<id>/case.json)
#
# It runs the BUILD-PLAN §3.5 case format against a temporary copy of the
# plugin in which the WP-core seam stubs are replaced by the doubles in
# doubles/doubles.pl and assets/handoff-spec.json comes from
# handoff-spec.json here. It exists only until WP-core's tests/helper/run.*
# and the real libs land; the case files are written for that runner.
#
# Case format used (§3.5 plus the additions marked +):
#   id, argv, stdin (fixture path) | stdin_text (+), env, now, tz, cwd (+), sid (+)
#   setup: [{copy, to} | {write, content | content_parts (+, joined at run
#           time so no file holds a whole secret-shaped string), mode} (+) |
#           {mkdir} (+) | {repo: {branch, commits: [{files, msg}], dirty,
#           untracked, ignored}, at} (+, inline recipe) | {run: argv, env,
#           cwd, capture} (+, a helper call) | {git: argv, cwd, env, var} (+, var keeps stdout) |
#           {age: path, minutes} (+, set mtime) | {bigfile, bytes, fill} (+)]
#   expect: exit, stdout, stdout_re, stdout_max_bytes, stdout_has (+),
#           stdout_lacks (+), json_keys (+), json (+, dotted path → value or
#           {re} | {null} | {len}), files [{path, mode, has, lacks, count}],
#           absent, rows [{file, ev, fields, count}], rows_absent (+),
#           trace_absent, trace_has (+), grep_absent [{dir, text}]
#   capture (+): {VAR: "json:<path>" | "re:<regex with one group>"} → $VAR
#   then: [steps of the same shape, same HOME; a step without argv is a
#          setup step (+)]
# Variables: $TMP $HOME $ROOT $WATCH $DISP $SID $SID8 $PLUGIN $STORE $LSTART1 $CASE
use strict;
use warnings;
use File::Basename ();
use File::Temp ();
use File::Path ();
use Cwd ();
use POSIX ();

my $HERE = File::Basename::dirname(Cwd::abs_path(__FILE__));
my $REPO = Cwd::abs_path("$HERE/../../../../..");
unshift @INC, "$REPO/plugin/helper/lib";
require skills::util;

my $DEF_SID = '11111111-2222-4333-8444-555555555555';
# Under the repo's ignored tmp/: a system temp folder is an ephemeral path for
# the publish lint, so drafts citing case paths would fail there.
File::Path::make_path("$REPO/tmp");
my $tmpbase = File::Temp::tempdir('skills-ht-XXXXXX', DIR => "$REPO/tmp", CLEANUP => ($ENV{KEEP} ? 0 : 1));
my $PLUGIN = build_plugin("$tmpbase/plugin");
my $BRAND = skills::util::json_decode(skills::util::read_file("$PLUGIN/.claude-plugin/plugin.json"))->{name};
my $STORE = "$PLUGIN/scripts/$BRAND-store";
my $LSTART1 = do { my $r = skills::util::run(['ps', '-o', 'lstart=', '-p', '1'], 2000); (my $v = $r->{out}) =~ s/\s+/ /g; $v =~ s/\A | \z//g; $v };

my @cases = @ARGV ? @ARGV : map { File::Basename::dirname($_) } sort glob("$REPO/tests/helper/cases/skills/*/case.json");
my ($pass, $fail) = (0, 0);
for my $dir (@cases) {
    $dir = Cwd::abs_path($dir);
    my $c = skills::util::json_decode(skills::util::read_file("$dir/case.json"));
    my @err = eval { run_case($c, $dir) };
    push @err, "runner: $@" if $@;
    if (@err) { $fail++; print "FAIL $c->{id}\n"; print "  - $_\n" for @err }
    else { $pass++; print "PASS $c->{id}\n" }
}
print "RESULT: $pass passed, $fail failed\n";
exit($fail ? 1 : 0);

sub build_plugin {
    my ($dst) = @_;
    copy_tree("$REPO/plugin/helper", "$dst/helper");
    copy_tree("$REPO/plugin/.claude-plugin", "$dst/.claude-plugin");
    copy_tree("$REPO/plugin/scripts", "$dst/scripts");
    chmod 0755, glob("$dst/scripts/*");
    my $brand = skills::util::json_decode(skills::util::read_file("$dst/.claude-plugin/plugin.json"))->{name};
    File::Path::make_path("$dst/assets");
    (my $spec = skills::util::read_file("$HERE/handoff-spec.json")) =~ s/\@BRAND\@/$brand/g;
    write_file("$dst/assets/handoff-spec.json", $spec);
    my $d = skills::util::read_file("$HERE/doubles/doubles.pl");
    for my $blk (split /^#### /m, $d) {
        next unless $blk =~ /\A(\S+\.pm)\n(.*)\z/s;
        write_file("$dst/helper/lib/$1", $2);
    }
    if (!-f "$REPO/plugin/helper/cmd/measure.pl") {
        write_file("$dst/helper/cmd/measure.pl", <<'PL');
# dev-runner shim for the `measure <handoff>` form (cmd/measure.pl is WP-core's)
use strict; use warnings;
use skills::measure_handoff;
my $h = shift @ARGV;
my $l = skills::measure_handoff::run($h, undef);
print "$_\n" for @$l;
exit 0;
PL
    }
    return $dst;
}

sub copy_tree {
    my ($s, $d) = @_;
    File::Path::make_path($d);
    for my $e (skills::util::list_dir($s)) {
        if (-d "$s/$e") { copy_tree("$s/$e", "$d/$e") }
        else { write_file("$d/$e", skills::util::read_file("$s/$e")); chmod((stat "$s/$e")[2] & 07777, "$d/$e") }
    }
}

sub write_file {
    my ($p, $t, $mode) = @_;
    File::Path::make_path(File::Basename::dirname($p));
    open(my $fh, '>:raw', $p) or die "write $p: $!\n";
    print $fh $t;
    close $fh;
    chmod oct($mode), $p if $mode;
}

sub subst {
    my ($v, $vars) = @_;
    if (ref $v eq 'HASH') { return { map { subst($_, $vars) => subst($v->{$_}, $vars) } keys %$v } }
    if (ref $v eq 'ARRAY') { return [ map { subst($_, $vars) } @$v ] }
    return $v unless defined $v;
    $v =~ s/\$([A-Z][A-Z0-9_]*)/exists $vars->{$1} ? $vars->{$1} : "\$$1"/ge;
    return $v;
}

sub run_case {
    my ($c, $dir) = @_;
    my $tmp = File::Temp::tempdir('case-XXXXXX', DIR => $tmpbase);
    my $home = "$tmp/home";
    File::Path::make_path($home);
    my $sid = $c->{sid} // $DEF_SID;
    my %vars = (TMP => $tmp, HOME => $home, SID => $sid, SID8 => lc(substr($sid =~ s/[^0-9a-zA-Z]//gr, 0, 8)),
                PLUGIN => $PLUGIN, STORE => $STORE, LSTART1 => $LSTART1, CASE => $dir, BRAND => $BRAND);
    $vars{ROOT} = "$home/.claude/handoffs";
    $vars{DISP} = "$home/.claude/trash-staging";
    my $cenv = subst($c->{env} || {}, \%vars);
    $vars{ROOT} = $cenv->{CLAUDE_PLUGIN_OPTION_HANDOFF_ROOT} if $cenv->{CLAUDE_PLUGIN_OPTION_HANDOFF_ROOT};
    $vars{WATCH} = "$vars{ROOT}/.watch";
    $cenv = subst($c->{env} || {}, \%vars);
    my %base_env = (
        HOME => $home, PATH => '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin',
        TZ => $c->{tz} // 'Etc/GMT-3', STORE_TEST_MODE => '1', STORE_TEST_TRACE => "$tmp/trace.log",
        SKILLS_DOUBLE_WATCH => $vars{WATCH}, GIT_CONFIG_NOSYSTEM => '1',
        GIT_AUTHOR_NAME => 'Test', GIT_AUTHOR_EMAIL => 'test@example.invalid',
        GIT_COMMITTER_NAME => 'Test', GIT_COMMITTER_EMAIL => 'test@example.invalid',
    );
    $base_env{STORE_TEST_NOW} = $c->{now} if $c->{now};
    my @err;
    for my $st (@{ $c->{setup} || [] }) { setup_step(subst($st, \%vars), \%vars, { %base_env, %$cenv }, \@err) }
    return @err if @err;
    for my $step ($c, @{ $c->{then} || [] }) {
        my $s = subst($step, \%vars);
        if (!$s->{argv}) {
            setup_step($s, \%vars, { %base_env, %$cenv }, \@err);
            last if @err;
            next;
        }
        my %env = (%base_env, %$cenv, %{ $s->{env} || {} });
        $env{STORE_TEST_NOW} = $s->{now} if $s->{now};
        my $label = $step == $c ? 'main' : 'then[' . join(' ', @{ $s->{argv} }) . ']';
        my $r = helper($s->{argv}, \%env, $s->{cwd} // $tmp, stdin_of($s));
        print "  [$label exit $r->{rc}]\n$r->{out}" if $ENV{SHOW};
        push @err, map { "$label: $_" } check($s->{expect} || {}, $r, \%vars, $tmp);
        capture($s->{capture}, $r->{out}, \%vars) if $s->{capture};
        last if @err;
    }
    return @err;
}

sub stdin_of {
    my ($s) = @_;
    return $s->{stdin_text} if defined $s->{stdin_text};
    return skills::util::read_file("$REPO/tests/fixtures/$s->{stdin}") if $s->{stdin};
    return '';
}

sub helper {
    my ($argv, $env, $cwd, $stdin) = @_;
    my $in = File::Temp->new(DIR => $tmpbase);
    print $in $stdin;
    close $in;
    my $out = File::Temp->new(DIR => $tmpbase);
    my $pid = fork;
    if ($pid == 0) {
        %ENV = %$env;
        chdir $cwd or POSIX::_exit(127);
        open(STDIN, '<', $in->filename);
        open(STDOUT, '>', $out->filename);
        open(STDERR, '>>', "$tmpbase/stderr.log");
        exec($STORE, @$argv) or POSIX::_exit(127);
    }
    waitpid($pid, 0);
    return { rc => $? >> 8, out => skills::util::read_file($out->filename) // '' };
}

sub setup_step {
    my ($st, $vars, $env, $err) = @_;
    if (exists $st->{write}) {
        my $t = exists $st->{content_parts} ? join('', @{ $st->{content_parts} }) : ($st->{content} // '');
        write_file($st->{write}, $t, $st->{mode} // '0600');
    } elsif (exists $st->{copy}) {
        write_file($st->{to}, skills::util::read_file("$REPO/tests/fixtures/$st->{copy}"), '0600');
    } elsif (exists $st->{mkdir}) {
        File::Path::make_path($st->{mkdir});
    } elsif (exists $st->{repo}) {
        make_repo($st->{repo}, $st->{at}, $env);
    } elsif (exists $st->{git}) {
        my $r = run_env(['git', @{ $st->{git} }], { %$env, %{ $st->{env} || {} } }, $st->{cwd} // $vars->{TMP});
        push @$err, "setup git @{ $st->{git} }: exit $r->{rc}" if $r->{rc} != 0;
        ($vars->{ $st->{var} } = $r->{out}) =~ s/\s+\z// if $st->{var};
    } elsif (exists $st->{run}) {
        my %e = (%$env, %{ $st->{env} || {} });
        my $r = helper($st->{run}, \%e, $st->{cwd} // $vars->{TMP}, '');
        push @$err, "setup run @{ $st->{run} }: exit $r->{rc}" if defined $st->{exit} && $r->{rc} != $st->{exit};
        capture($st->{capture}, $r->{out}, $vars) if $st->{capture};
    } elsif (exists $st->{bigfile}) {
        File::Path::make_path(File::Basename::dirname($st->{bigfile}));
        open(my $fh, '>:raw', $st->{bigfile}) or die "bigfile: $!\n";
        my $left = $st->{bytes};
        my $chunk = ($st->{fill} // 'b') x 65536;
        while ($left > 0) { my $n = $left < 65536 ? $left : 65536; print $fh substr($chunk, 0, $n); $left -= $n }
        close $fh;
    } elsif (exists $st->{age}) {
        my $t = time - 60 * ($st->{minutes} // 0);
        utime $t, $t, $st->{age};
    } else {
        push @$err, 'setup: unknown step ' . join(',', keys %$st);
    }
}

sub run_env {
    my ($argv, $env, $cwd) = @_;
    local %ENV = %$env;
    return skills::util::run($argv, 10000, cwd => $cwd);
}

sub make_repo {
    my ($rc, $at, $env) = @_;
    File::Path::make_path($at);
    my $g = sub { my $r = run_env(['git', '-C', $at, @_], $env, $at); die "git @_: exit $r->{rc}\n" if $r->{rc} != 0; $r->{out} };
    $g->('init', '-q', '-b', $rc->{base} // 'main');
    for my $cm (@{ $rc->{commits} || [ { files => { 'README.md' => "seed\n" }, msg => 'seed' } ] }) {
        for my $f (sort keys %{ $cm->{files} || {} }) { write_file("$at/$f", $cm->{files}{$f}) }
        $g->('add', '-A');
        $g->('commit', '-q', '--allow-empty', '-m', $cm->{msg} // 'commit');
    }
    $g->('checkout', '-q', '-b', $rc->{branch}) if $rc->{branch} && $rc->{branch} ne ($rc->{base} // 'main');
    if (@{ $rc->{ignored} || [] }) { write_file("$at/.gitignore", join("\n", @{ $rc->{ignored} }) . "\n"); $g->('add', '.gitignore'); $g->('commit', '-q', '-m', 'ignore') }
    write_file("$at/$_", $rc->{dirty}{$_}) for sort keys %{ $rc->{dirty} || {} };
    write_file("$at/$_", $rc->{untracked}{$_}) for sort keys %{ $rc->{untracked} || {} };
}

sub jpath {
    my ($d, $path) = @_;
    for my $k (split /\./, $path) {
        if (ref $d eq 'ARRAY' && $k =~ /\A\d+\z/) { $d = $d->[$k] }
        elsif (ref $d eq 'HASH') { return (0, undef) unless exists $d->{$k}; $d = $d->{$k} }
        else { return (0, undef) }
    }
    return (1, $d);
}

sub capture {
    my ($cap, $out, $vars) = @_;
    for my $k (keys %$cap) {
        my $how = $cap->{$k};
        if ($how =~ /\Ajson:(.*)\z/) {
            my $d = eval { skills::util::json_decode($out) };
            my (undef, $v) = jpath($d, $1);
            $vars->{$k} = $v;
        } elsif ($how =~ /\Are:(.*)\z/s) {
            my $re = $1;
            $vars->{$k} = $1 if $out =~ /$re/m;
        }
    }
}

sub rows_of {
    my ($file) = @_;
    my $t = skills::util::read_file($file) // '';
    return [ map { my $d = eval { skills::util::json_decode($_) }; $d ? $d : { _bad => $_ } } grep { /\S/ } split /\n/, $t ];
}

sub check {
    my ($e, $r, $vars, $tmp) = @_;
    my @err;
    my $out = $r->{out};
    push @err, "exit $r->{rc} != $e->{exit}; stdout: " . substr($out, 0, 600) if defined $e->{exit} && $r->{rc} != $e->{exit};
    push @err, "stdout mismatch: [$out]" if defined $e->{stdout} && $out ne $e->{stdout};
    push @err, "stdout !~ /$e->{stdout_re}/: [$out]" if defined $e->{stdout_re} && $out !~ /$e->{stdout_re}/m;
    push @err, 'stdout ' . length($out) . " B > $e->{stdout_max_bytes}" if defined $e->{stdout_max_bytes} && length($out) > $e->{stdout_max_bytes};
    for my $re (@{ $e->{stdout_has} || [] }) { push @err, "stdout lacks /$re/: [" . substr($out, 0, 1500) . ']' unless $out =~ /$re/m }
    for my $re (@{ $e->{stdout_lacks} || [] }) { push @err, "stdout has /$re/" if $out =~ /$re/m }
    if ($e->{json_keys} || $e->{json}) {
        my $d = eval { skills::util::json_decode($out) };
        if (!ref $d) { push @err, "stdout is not JSON: [$out]" }
        else {
            if ($e->{json_keys}) {
                my $got = join ',', sort keys %$d;
                my $want = join ',', sort @{ $e->{json_keys} };
                push @err, "json keys [$got] != [$want]" if $got ne $want;
            }
            for my $p (sort keys %{ $e->{json} || {} }) {
                my ($ok, $v) = jpath($d, $p);
                my $w = $e->{json}{$p};
                if (ref $w eq 'HASH') {
                    if (exists $w->{re}) { push @err, "json $p !~ /$w->{re}/: " . (defined $v ? (ref $v ? skills::util::json_encode($v) : $v) : 'null') unless $ok && defined $v && !ref $v && $v =~ /$w->{re}/ }
                    if (exists $w->{null}) { push @err, "json $p not null" if $ok && defined $v }
                    if (exists $w->{len}) { push @err, "json $p len != $w->{len}" unless ref $v eq 'ARRAY' && @$v == $w->{len} }
                    if (exists $w->{present}) { push @err, "json $p missing" unless $ok }
                } else {
                    my $g = defined $v ? (ref $v ? skills::util::json_encode($v) : "$v") : 'null';
                    my $ws = defined $w ? (ref $w ? skills::util::json_encode($w) : "$w") : 'null';
                    push @err, "json $p = $g, want $ws" if $g ne $ws;
                }
            }
        }
    }
    for my $f (@{ $e->{files} || [] }) {
        my @m = glob($f->{path});
        @m = grep { -e } @m;
        if (defined $f->{count}) { push @err, "files $f->{path}: " . scalar(@m) . " != $f->{count}" if @m != $f->{count}; next unless @m }
        if (!@m) { push @err, "missing file $f->{path}"; next }
        for my $p (@m) {
            if ($f->{mode}) { my $md = sprintf('%04o', (stat $p)[2] & 07777); push @err, "$p mode $md != $f->{mode}" if $md ne $f->{mode} }
            my $t = -f $p ? (skills::util::read_file($p) // '') : '';
            for my $re (@{ $f->{has} || [] }) { push @err, "$p lacks /$re/" unless $t =~ /$re/m }
            for my $re (@{ $f->{lacks} || [] }) { push @err, "$p has /$re/" if $t =~ /$re/m }
        }
    }
    for my $a (@{ $e->{absent} || [] }) {
        if ($a =~ /\A(.*):count>(\d+)\z/) { my @m = grep { -e } glob($1); push @err, "$1: " . scalar(@m) . " > $2" if @m > $2 }
        else { my @m = grep { -e } glob($a); push @err, "present: @m" if @m }
    }
    for my $rw (@{ $e->{rows} || [] }) {
        my @hit = grep {
            my $row = $_;
            ($row->{ev} // '') eq $rw->{ev} && !grep {
                my $k = $_;
                my $w = $rw->{fields}{$k};
                my $g = $row->{$k};
                my $gs = defined $g ? (ref $g ? skills::util::json_encode($g) : "$g") : 'null';
                my $ws = defined $w ? (ref $w ? skills::util::json_encode($w) : "$w") : 'null';
                $gs ne $ws;
            } keys %{ $rw->{fields} || {} };
        } @{ rows_of($rw->{file}) };
        if (defined $rw->{count}) { push @err, "rows $rw->{ev}: " . scalar(@hit) . " != $rw->{count}" if @hit != $rw->{count} }
        elsif (!@hit) { push @err, "no row $rw->{ev} " . skills::util::json_encode($rw->{fields} || {}) . ' in ' . (skills::util::read_file($rw->{file}) // '(no file)') }
    }
    for my $rw (@{ $e->{rows_absent} || [] }) {
        push @err, "row $rw->{ev} present" if grep { ($_->{ev} // '') eq $rw->{ev} } @{ rows_of($rw->{file}) };
    }
    my $trace = skills::util::read_file("$tmp/trace.log") // '';
    for my $t (@{ $e->{trace_absent} || [] }) { push @err, "trace has $t" if $trace =~ /^\Q$t\E$/m }
    for my $t (@{ $e->{trace_has} || [] }) { push @err, "trace lacks $t" unless $trace =~ /^\Q$t\E$/m }
    for my $g (@{ $e->{grep_absent} || [] }) {
        my $hit = grep_dir($g->{dir}, $g->{text});
        push @err, "found '$g->{text}' in $hit" if $hit;
    }
    return @err;
}

sub grep_dir {
    my ($d, $text) = @_;
    my @stack = ($d);
    while (@stack) {
        my $x = pop @stack;
        if (-d $x) { push @stack, map { "$x/$_" } skills::util::list_dir($x); next }
        my $t = skills::util::read_file($x) // next;
        return $x if index($t, $text) >= 0;
    }
    return undef;
}
