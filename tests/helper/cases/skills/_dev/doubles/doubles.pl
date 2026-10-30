# tests/helper/cases/skills/_dev/doubles/doubles.pl
# Test doubles for the WP-core seams (BUILD-PLAN §3.6) in the shapes that
# plugin/helper/lib/skills/core.pm assumes. The dev runner writes each
# package below over the matching Phase 0 stub in a TEMPORARY copy of the
# plugin; nothing here ships, and the real core libs replace them at
# integration (then the cases run through WP-core's tests/helper/run.*).
# Each block starts with a line "#### <file>".
#### settings.pm
package settings;
use strict; use warnings;
use skills::util;
my %DEF = (handoff_root => '~/.local/state/afk-compact/handoffs', log_dir => '', disposable_root => '~/.claude/trash-staging',
           disposable_keep_days => 0, evidence_quota_mb => 500, queue_cmd => '', watcher => 'shadow', auto_evidence => 1);
sub resolve {
    my ($f) = @_;
    $f ||= {};
    my (%s, %src);
    for my $k (keys %DEF) {
        my $env = $ENV{ 'CLAUDE_PLUGIN_OPTION_' . uc $k };
        if (defined $f->{$k} && !skills::util::unset_value($f->{$k})) { $s{$k} = $f->{$k}; $src{$k} = 'flag' }
        elsif (defined $env && !skills::util::unset_value($env)) { $s{$k} = $env; $src{$k} = 'env' }
        else { $s{$k} = $DEF{$k}; $src{$k} = 'default' }
        $s{$k} = skills::util::expand_tilde($s{$k}) if $k =~ /_root\z|_dir\z|_cmd\z/;
    }
    $s{_source} = \%src;
    return \%s;
}
1;
#### paths.pm
package paths;
use strict; use warnings;
sub for {
    my ($s, $sid) = @_;
    my $root = $s->{handoff_root};
    my $watch = ($s->{log_dir} // '') ne '' ? $s->{log_dir} : "$root/.watch";
    return { root => $root, watch => $watch, disposable => $s->{disposable_root} };
}
1;
#### roots.pm
package roots;
use strict; use warnings;
use File::Basename ();
use skills::util;
sub check {
    my ($s) = @_;
    for my $k (qw(handoff_root disposable_root)) {
        my $p = $s->{$k} // next;
        return 'root-in-planning' if $p =~ m{(?:\A|/)\.planning(?:/|\z)};
        my $d = $p;
        $d = File::Basename::dirname($d) while !-d $d && $d ne '/';
        my $r = skills::util::run(['git', '-C', $d, 'rev-parse', '--show-toplevel'], 2000);
        next if $r->{rc} != 0;
        my $ig = skills::util::run(['git', '-C', $d, 'check-ignore', '-q', $p], 2000);
        return 'root-in-git' if $ig->{rc} != 0;
    }
    return 'ok';
}
1;
#### log.pm
package log;
use strict; use warnings;
use skills::util;
sub row {
    my ($ev, $f, $c) = @_;
    return { v => 1, ts => skills::util::iso_local(), ev => $ev, %{ $c || {} }, %{ $f || {} } };
}
sub append {
    my ($file, $row) = @_;
    my $j = ref $row ? skills::util::json_encode($row) : $row;
    skills::util::append_line($file, "$j\n");
}
1;
#### lock.pm
package lock;
use strict; use warnings;
use Fcntl qw(O_RDWR O_CREAT LOCK_EX LOCK_UN);
use skills::util;
sub _live {
    my ($o) = @_;
    return 0 unless ref $o eq 'HASH' && $o->{pid};
    return 0 unless kill(0, $o->{pid}) || $!{EPERM};
    my $r = skills::util::run(['ps', '-o', 'lstart=', '-p', $o->{pid}], 2000);
    (my $now = $r->{out}) =~ s/\s+/ /g; $now =~ s/\A | \z//g;
    (my $rec = $o->{lstart} // '') =~ s/\s+/ /g; $rec =~ s/\A | \z//g;
    return $now eq $rec ? 1 : 0;
}
sub with {
    my ($path, $owner, $fn) = @_;
    sysopen(my $fh, $path, O_RDWR | O_CREAT, 0600) or die "lock $path: $!\n";
    flock($fh, LOCK_EX) or die "lock $path: $!\n";
    my $cur = skills::util::read_file($path) // '';
    if ($cur =~ /\S/) {
        my $o = eval { skills::util::json_decode($cur) };
        if (_live($o) && $o->{pid} != $$) { flock($fh, LOCK_UN); close $fh; die "lock-busy\n" }
        my $row = { v => 1, ts => skills::util::iso_local(), ev => 'lock_stale', sid => $owner->{sid}, actor => $owner->{actor},
                    writer => 'helper', pid => $$, path => $path };
        my $watch = $ENV{SKILLS_DOUBLE_WATCH};
        if ($watch) { skills::util::mkdir_p($watch); skills::util::append_line("$watch/$owner->{sid}.classic.jsonl", skills::util::json_encode($row) . "\n") }
    }
    seek($fh, 0, 0); truncate($fh, 0);
    syswrite($fh, skills::util::json_encode($owner));
    my @r = eval { $fn->() };
    my $err = $@;
    seek($fh, 0, 0); truncate($fh, 0);
    flock($fh, LOCK_UN); close $fh;
    die $err if $err;
    return $r[0];
}
1;
#### identity.pm
package identity;
use strict; use warnings;
sub claude_pid {
    my $v = $ENV{STORE_TEST_CLAUDE_PID} // '';
    return undef unless ($ENV{STORE_TEST_MODE} // '') eq '1' && $v =~ /\A(\d+):(.+)\z/;
    return { pid => $1, lstart => $2 };
}
1;
#### nonce.pm
package nonce;
use strict; use warnings;
use skills::util;
sub draw { return skills::util::rand_hex(4) }
1;
#### secrets.pm
package secrets;
use strict; use warnings;
use File::Basename ();
use skills::util;
my @RULES = (
    [ 'pem',          'HARD', qr/-----BEGIN [A-Z ]*PRIVATE KEY-----/ ],
    [ 'jwt',          'HARD', qr/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/ ],
    [ 'bearer',       'HARD', qr/\b(?:Bearer|Basic)\s+[A-Za-z0-9._~+\/=-]{16,}/ ],
    [ 'url-userinfo', 'HARD', qr{\b[a-z][a-z0-9+.-]*://[^\s/:@]+:[^\s/@]+@} ],
    [ 'kv',           'WARN', qr/\b(?:pass\w*|secret|token|key)\s*[=:]\s*\S{6,}/i ],
);
sub scan {
    my ($t) = @_;
    my @h;
    for my $r (@RULES) { push @h, { rule => $r->[0], class => $r->[1] } if defined $t && $t =~ $r->[2] }
    return \@h;
}
sub classify_file {
    my ($p) = @_;
    my $b = File::Basename::basename($p);
    return 'withhold' if $b =~ /\A\.env(?!\.(?:example|sample|template|dist)\z)/ || $b =~ /\A(?:\.netrc|\.npmrc|\.claude\.json|id_rsa|id_ed25519)\z/ || $b =~ /\.(?:har|sqlite)\z/ || $b =~ /_history\z/;
    my $t = skills::util::read_file($p, 1024 * 1024) // '';
    my $h = scan($t);
    return 'copy' unless @$h;
    return 'redact' if $b =~ /\.(?:log|json|jsonl)\z/;
    return (grep { $_->{class} eq 'HARD' } @$h) ? 'withhold' : 'redact';
}
1;
#### evidence.pm
package evidence;
use strict; use warnings;
use File::Basename ();
use skills::util;
use secrets;
sub copy {
    my ($src, $dir, $caps, $index) = @_;
    my @st = stat $src;
    return { status => 'missing' } unless @st;
    my $data = skills::util::read_file($src) // '';
    my $sha = skills::util::sha256_hex($data);
    my %base = (bytes => $st[7], sha256 => $sha, mtime => skills::util::iso_local($st[9]));
    my $cls = secrets::classify_file($src);
    if ($cls eq 'withhold') {
        return { %base, status => 'withheld', rules => [ map { $_->{rule} } @{ secrets::scan($data) } ] };
    }
    if ($st[7] > ($caps->{file_max} // 1e12) || ($caps->{used} // 0) + $st[7] > ($caps->{total_max} // 1e12)) {
        return { %base, status => 'ref-only' };
    }
    for my $l (split /\n/, (skills::util::read_file($index) // '')) {
        my ($s, $c) = split /\t/, $l;
        return { %base, status => 'dup', copy => $c } if $s && $s eq $sha && defined $c && -f $c;
    }
    my $name = File::Basename::basename($src);
    my ($stem, $ext) = $name =~ /\A(.*?)((?:\.[^.]+)?)\z/;
    my $dest = skills::util::unique_path($dir, $stem, $ext);
    my $status = 'copied';
    if ($cls eq 'redact') {
        $data =~ s/(\b(?:pass\w*|secret|token|key)\s*[=:]\s*)\S{6,}/$1\[REDACTED:kv\]/gi;
        $data =~ s/\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/[REDACTED:jwt]/g;
        $status = 'redacted';
    }
    skills::util::write_excl($dest, $data, 0600) or return { %base, status => 'missing' };
    skills::util::append_line($index, "$sha\t$dest\n");
    return { %base, status => $status, copy => $dest, scan => ($status eq 'redacted' ? 'redacted' : 'full') };
}
1;
#### gsd.pm
package gsd;
use strict; use warnings;
use skills::util;
sub read {
    my ($wt) = @_;
    my $p = "$wt/.planning/STATE.md";
    my $t = skills::util::read_file($p) // return undef;
    my @l = ("STATE.md $p · worktree $wt");
    push @l, grep { /\A(?:Phase|Plan|Status|Last activity)\b/i } split /\n/, $t;
    return [ @l[0 .. ($#l < 7 ? $#l : 7)] ];
}
1;
#### queue.pm
package queue;
use strict; use warnings;
use skills::util;
sub call { my ($argv, $ms) = @_; return skills::util::run($argv, $ms) }
1;
#### bucket.pm
package bucket;
use strict; use warnings;
use skills::util;
use skills::gitfacts;
sub resolve {
    my ($sid, $cwd, $topic, $s) = @_;
    my $root = $s->{handoff_root};
    my $w = skills::gitfacts::facts($cwd);
    my $pin = eval { skills::util::json_decode(skills::util::read_file("$root/.sessions/$sid.json")) };
    return { path => "$root/$pin->{bucket}", source => 'pin' } if ref $pin eq 'HASH' && $pin->{bucket};
    my $lin = eval { skills::util::json_decode(skills::util::read_file("$root/.sessions/$sid.lineage.json")) };
    if (ref $lin eq 'HASH' && $lin->{previous_session_id}) {
        my $pp = eval { skills::util::json_decode(skills::util::read_file("$root/.sessions/$lin->{previous_session_id}.json")) };
        return { path => "$root/$pp->{bucket}", source => 'pin-lineage' } if ref $pp eq 'HASH' && $pp->{bucket};
    }
    my $t = skills::gitfacts::ticket($w->{branch});
    return { path => "$root/$w->{repo}/$t", source => 'branch' } if $t;
    return { path => "$root/$w->{repo}/$topic", source => 'topic' } if defined $topic && $topic ne '';
    return { path => "$root/$w->{repo}/general", source => 'general' };
}
1;
#### detect.pm
package detect;
use strict; use warnings;
use skills::ctx;
sub summary {
    my ($text) = @_;
    my $b = skills::ctx::brand();
    my @l = split /\n/, ($text // '');
    my %r = (verdict => 'unshaped', marker_line => '-', sentinel_from_end => '-', nonce => undef, scope => undef);
    my $n = 0;
    for my $i (0 .. $#l) {
        last if $n >= 5;
        next unless $l[$i] =~ /\S/;
        $n++;
        if ($l[$i] =~ /\A\x{e2}\x{9f}\x{aa}\Q$b\E v1 n=([0-9a-f]{8}) s=(main|sub|manual)\x{e2}\x{9f}\x{ab}\z/) {
            @r{qw(marker_line nonce scope)} = ($n, $1, $2);
            last;
        }
    }
    my @nb = grep { $l[$_] =~ /\S/ } 0 .. $#l;
    for my $k (1 .. 3) {
        last if $k > @nb;
        if ($l[ $nb[-$k] ] =~ /\A\x{e2}\x{9f}\x{aa}\/\Q$b\E n=([0-9a-f]{8})\x{e2}\x{9f}\x{ab}\z/) { $r{sentinel_from_end} = $k; last }
    }
    if ($r{marker_line} ne '-') {
        $r{verdict} = $r{sentinel_from_end} eq '-' ? 'truncated' : ($r{sentinel_from_end} == 1 ? 'ok' : 'ok-trailer');
    }
    return \%r;
}
1;
