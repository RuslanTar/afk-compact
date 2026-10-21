package skills::core;
# lib/skills/core.pm: the one place where WP-skills calls WP-core's library
# seams (BUILD-PLAN §3.6). Every assumption about a seam's argument or return
# shape is normalised here, so integration changes this file only.
#
# Assumed shapes (provisional until WP-core's code lands):
#   settings::resolve(\%flags)        -> hashref of userConfig keys (MOD §1.2) with the
#                                        effective values; optional {_source}{key}
#   paths::for($settings, $sid)        -> {root, watch, disposable}
#   roots::check($settings)            -> 'ok' | {ok=>1} | undef (ok); a string reason
#                                        or {refused=>reason} (refused)
#   log::row($ev, \%fields, \%ctx)     -> row (hashref or JSON line)
#   log::append($file, $row)           -> appends to the absolute stream file
#   lock::with($path, \%owner, $fn)    -> $fn's return; dies when the lock is live
#   identity::claude_pid()             -> {pid, lstart}
#   identity::lstart($pid)             -> optional; start time in the record format
#   nonce::draw($sid)                  -> 8 lowercase hex
#   secrets::scan($text)               -> [{rule, class}]
#   secrets::classify_file($path)      -> (copy | redact | withhold, [{rule, class}])
#   secrets::redact($text)             -> ($redacted_text, [{rule, class}]) over every rule class
#   evidence::copy($src,$dir,\%caps,$index) -> {status, copy, bytes, sha256, mtime, scan, rules}
#   gsd::read($worktree)               -> arrayref of lines | {lines=>[...]} | undef
#   queue::call(\@argv, $budget_ms)    -> {rc|exit, out|stdout, timed_out|timeout}
#   bucket::resolve($sid, $cwd, $topic, $settings) -> {path, source}; path absolute
#                                        (<root>/<repo>/<bucket>); settings passed as a 4th
#                                        argument because a skill flag can move the root
#   detect::summary($text)             -> {verdict, marker_line, sentinel_from_end, nonce, scope}
use strict;
use warnings;
use POSIX ();
use skills::util;
use settings;
use paths;
use roots;
use log;
use lock;
use identity;
use nonce;
use secrets;
use evidence;
use gsd;
use queue;
use bucket;
use detect;

sub settings {
    my ($flags) = @_;
    # The core libraries read the run context (rc: root, watch, root checks, the row
    # envelope). A skill flag can move the roots, so the context is built from the flags.
    my $r = rc::init(sid => 'unknown', writer => 'helper', actor => 'main', flags => $flags || {});
    my $s = ref $r eq 'HASH' ? $r->{settings} : undef;
    $s = $s->{values} if ref $s eq 'HASH' && ref $s->{values} eq 'HASH';
    die "settings: no result\n" unless ref $s eq 'HASH';
    return $s;
}

# The session id the core context logs and locks under (rc), once a skill knows it.
sub bind_sid {
    my ($sid) = @_;
    rc::set_sid($sid) if defined $sid && $sid ne '' && defined &rc::set_sid;
    return $sid;
}

sub paths {
    my ($s, $sid) = @_;
    my $p = paths::for($s, $sid);
    die "paths: no result\n" unless ref $p eq 'HASH' && $p->{root};
    return $p;
}

# undef when the roots are safe, else the refusal reason.
sub roots_check {
    my ($s) = @_;
    my $r = roots::check($s);
    return undef if !defined $r;
    if (ref $r eq 'HASH') {
        return undef if $r->{ok};
        # WP-core shape: one result per root key, {ok} or {ok => 0, reason}. The skills
        # write under handoff_root and disposable_root; log_dir falls back in core.
        my @per = grep { ref $r->{$_} eq 'HASH' } qw(handoff_root disposable_root);
        if (@per) {
            for my $k (@per) { return $r->{$k}{reason} // 'root-unsafe' unless $r->{$k}{ok} }
            return undef;
        }
        return $r->{refused} // $r->{reason} // 'root-unsafe';
    }
    return undef if $r eq 'ok' || $r eq '1';
    $r =~ s/\AREFUSED:\s*//;
    $r =~ s/\Arefused\((.*)\)\z/$1/;
    return $r;
}

# One content-free row to <watch>/<sid>.classic.jsonl.
sub log_event {
    my ($ctx, $ev, $fields) = @_;
    my $sid = $ctx->{sid} // 'unknown';
    my $file = "$ctx->{watch}/$sid.classic.jsonl";
    my %c = (
        sid            => $sid,
        actor          => $ctx->{actor} // 'main',
        writer         => 'helper',
        pid            => $$,
        plugin_version => $ctx->{version},
        cc_version     => undef,
        turn_seq       => undef,
    );
    eval {
        skills::util::mkdir_p($ctx->{watch});
        my $row = log::row($ev, $fields || {}, \%c);
        log::append($file, $row);
        1;
    } or return 0;
    return 1;
}

sub host { my @u = POSIX::uname(); return $u[1] // 'unknown' }

sub lock_owner {
    my ($sid, $actor) = @_;
    return { sid => $sid, actor => $actor // 'main', pid => $$, lstart => lstart($$), host => host() };
}

# Returns ($ok, $value_or_error).
sub with_lock {
    my ($path, $owner, $fn) = @_;
    my @r;
    my $ok = eval { @r = lock::with($path, $owner, $fn); 1 };
    return (0, ($@ || 'lock') =~ s/\s+\z//r) unless $ok;
    return (1, $r[0]);
}

sub claude_pid {
    my $r = eval { identity::claude_pid() };
    return undef unless ref $r eq 'HASH' && $r->{pid};
    return $r;
}

# Start time of any pid, in the format the per-process records carry.
sub lstart {
    my ($pid) = @_;
    return undef unless defined $pid && $pid =~ /\A\d+\z/;
    for my $f (qw(start_time lstart)) {
        my $code = identity->can($f) or next;
        my $v = eval { $code->($pid) };
        return $v if defined $v && $v ne '';
    }
    my $r = skills::util::run(['ps', '-o', 'lstart=', '-p', $pid], 2000);
    return undef if $r->{rc} != 0;
    my $v = $r->{out};
    $v =~ s/\s+\z//;
    $v =~ s/\A\s+//;
    $v =~ s/\s+/ /g;
    return $v eq '' ? undef : $v;
}

sub nonce {
    my ($sid) = @_;
    my $n = nonce::draw($sid);
    die "nonce: bad value\n" unless defined $n && $n =~ /\A[0-9a-f]{8}\z/;
    return $n;
}

sub secrets_scan {
    my ($text) = @_;
    my $r = secrets::scan($text);
    return [] unless ref $r eq 'ARRAY';
    return [ map { { rule => $_->{rule} // $_->{id} // 'unknown', class => uc($_->{class} // 'WARN') } } @$r ];
}

sub classify_file {
    my ($path) = @_;
    my ($r) = classify_file_hits($path);
    return $r;
}

# (copy|redact|withhold, [{rule, class}], $scanned): the gate's verdict, its hits (ids,
# never values) and, for copy and redact, the bytes the gate scanned (RRP-06: write those,
# never a second read of the file).
sub classify_file_hits {
    my ($path) = @_;
    my ($r, $hits, $raw) = secrets::classify_file($path);    # WP-core returns (action, \@hits, bytes)
    $r = $r->{action} // $r->{class} if ref $r eq 'HASH';
    return ($r // 'copy', _hits($hits), $raw);
}

# A path the name gate refuses: deny-listed by name, or never copied (transcripts, session
# JSONL, environment dumps); the path and its real target are both checked.
sub denied_path {
    my ($path) = @_;
    return (secrets::denied_name($path) || secrets::never_copy($path)) ? 1 : 0;
}

# (text with each hit replaced by [redacted:<rule>], [{rule, class}]), every rule class.
sub secrets_redact {
    my ($text) = @_;
    my ($red, $hits) = secrets::redact($text);
    die "secrets: redact gave no text\n" unless defined $red;
    return ($red, _hits($hits));
}

sub _hits {
    my ($h) = @_;
    return [] unless ref $h eq 'ARRAY';
    return [ map { { rule => $_->{rule} // $_->{id} // 'unknown', class => uc($_->{class} // 'WARN') } } @$h ];
}

sub evidence_copy {
    my ($src, $dir, $caps, $index) = @_;
    # WP-core keeps the running total behind a scalar ref (caps.used => \$bytes).
    my %c = %{ $caps || {} };
    $c{used} = \(my $u = $c{used} // 0) unless ref $c{used};
    # The skill writes MANIFEST.tsv itself at publish (exclusive create), and its ref-only
    # rows carry no copy (`ref-only - <bytes> <sha8> <origin>`, handoff SKILL Step 4).
    $c{manifest} //= 0;
    $c{ref_file} //= 0;
    my $r = evidence::copy($src, $dir, \%c, $index);
    die "evidence: no row\n" unless ref $r eq 'HASH';
    $r->{status} //= $r->{result} // 'missing';
    $r->{copy}   //= $r->{copy_path} // $r->{path};
    # WP-core does not hash a file withheld by name; the skill's rows and MANIFEST carry
    # its sha256 (a hash, never content).
    $r->{sha256} //= sha::hex256_file($src) if $r->{status} eq 'withheld' && -f $src;
    $r->{sha256} //= '';
    $r->{bytes}  //= 0;
    $r->{scan}   //= $r->{status} eq 'copied' ? 'full' : $r->{status};
    return $r;
}

sub gsd {
    my ($wt) = @_;
    my $r = eval { gsd::read($wt) };
    return undef unless defined $r;
    $r = $r->{lines} if ref $r eq 'HASH';
    $r = [ split /\n/, $r ] unless ref $r;
    return undef unless ref $r eq 'ARRAY' && @$r;
    return $r;
}

sub queue_call {
    my ($argv, $budget) = @_;
    skills::util::trace('queue_cmd');
    my $r = eval { queue::call($argv, $budget) };
    return { rc => -1, out => '', timed_out => 0, error => 1 } unless ref $r eq 'HASH';
    return {
        rc        => $r->{rc} // $r->{exit} // -1,
        out       => $r->{out} // $r->{stdout} // '',
        timed_out => $r->{timed_out} // $r->{timeout} // 0,
    };
}

sub bucket_resolve {
    my ($sid, $cwd, $topic, $s) = @_;
    # WP-core: resolve(sid, cwd, topic [, where]) reads the root from the run context,
    # which settings() built from the same flags; the 4th argument is git facts, not settings.
    my $r = bucket::resolve($sid, $cwd, $topic);
    die "bucket: no result\n" unless ref $r eq 'HASH' && $r->{path};
    return $r;
}

sub detect_summary {
    my ($text) = @_;
    my $r = eval { detect::summary($text) };
    return undef unless ref $r eq 'HASH';
    return $r;
}

1;
