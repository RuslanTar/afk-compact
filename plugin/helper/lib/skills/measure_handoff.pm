package skills::measure_handoff;
# lib/skills/measure_handoff.pm: the `measure <handoff>` form (RDN helper
# table, resume R3; D-2, D-21, D-22 resume remaining 4). Called by
# cmd/measure.pl (WP-core), which prints the returned lines.
# It measures and never runs a command taken from the handoff. Approvals (AP-5, D-2
# replaced by scoped carry): `Approvals (checked)` lists the own handoff's approvals whose ids
# publish wrote to approvals_checked, unused and not a gate; `Approvals (gate, re-ask)` the gate
# ones (skills/approvals.pm); one content-free approvals_carry row. Commits are "ours" only when the
# chain names the hash or the commit lies between two git_commit values the
# chain recorded; every other commit is one "foreign" line (D-21).
# Re-check commands in Live state and In flight are linted against the
# outward/destructive classes and the secret rules; a hit prints
# `needs-ask <class> line <n>`.
use strict;
use warnings;
use utf8;
use Cwd ();
use skills::util;
use skills::ctx;
use skills::core;
use skills::store;
use skills::spec;
use skills::gitfacts;
use skills::approvals;

# run(handoff, settings) → [lines]. $settings is accepted for the seam and
# not needed: the context resolves the same settings order itself.
sub run {
    my ($handoff, $settings, %o) = @_;
    skills::util::trace('measure');
    my @out;
    my $now = skills::util::now();
    push @out, 'Measured facts (' . skills::util::stamp($now) . ')';
    my $path = skills::util::abs_path($handoff);
    my $d = (defined $path && -f $path) ? skills::store::read_doc($path) : undef;
    if (!$d) {
        push @out, 'handoff: not found ' . ($handoff // '');
        return \@out;
    }
    my $ctx = skills::ctx::new({});
    my $id = skills::ctx::resolve_sid($ctx, $o{sid});
    my $fm = $d->{fm};
    my $cwd = skills::util::abs_path($o{cwd} // skills::util::cwd());
    push @out, "cwd: $cwd";
    my $g = skills::gitfacts::facts($cwd);
    my $gc = $fm->{git_commit};
    if ($g->{in_git}) {
        my $rel = 'git_commit unknown';
        if ($gc) {
            my $gc_ok = skills::gitfacts::rev_ok($gc)
                && skills::gitfacts::git($g->{worktree}, 'cat-file', '-e', "$gc^{commit}")->{rc} == 0;
            if (!$gc_ok) { $rel = 'git_commit ' . substr($gc, 0, 8) . ' not found here' }
            elsif (($g->{head_full} // '') eq $gc || index($g->{head_full} // '', $gc) == 0) { $rel = 'same as git_commit' }
            elsif (skills::gitfacts::is_ancestor($g->{worktree}, $gc, 'HEAD')) { $rel = 'ahead of git_commit ' . substr($gc, 0, 8) }
            elsif (skills::gitfacts::is_ancestor($g->{worktree}, 'HEAD', $gc)) { $rel = 'behind git_commit ' . substr($gc, 0, 8) }
            else { $rel = 'diverged from git_commit ' . substr($gc, 0, 8) }
        }
        push @out, sprintf('worktree: %s · branch %s · HEAD %s (%s)', $g->{worktree}, $g->{branch} // '?', $g->{head} // '?', $rel);
        if (!$g->{porcelain_measured}) { push @out, 'dirty: not measured' }
        elsif ($g->{dirty_count}) {
            push @out, "dirty: $g->{dirty_count} files";
            push @out, "  $_" for @{ $g->{porcelain} };
        } else { push @out, 'dirty: clean' }
        push @out, defined $g->{ahead} ? "upstream: ahead $g->{ahead}, behind $g->{behind}" : 'upstream: none';
        push @out, _commits($ctx, $g, $d) if $gc && ($rel =~ /\Aahead|\Adiverged/);
    } else {
        push @out, 'worktree: not a git work tree' . (skills::gitfacts::usable() ? '' : ' (git not available)');
    }
    my @chain = chain_docs($d, $ctx);
    if (@chain > 1) {
        push @out, 'chain: ' . join(' <- ', map {
            skills::store::stem_of($_->{path}) . ($_->{foreign} ? ' (foreign ' . skills::ctx::sid8($_->{fm}{session_id}) . ')' : '')
        } @chain);
    }
    if (my $wt = $fm->{worktree}) {
        push @out, "handoff worktree: $wt " . (-d $wt ? 'exists' : 'missing');
    }
    if ($g->{in_git}) {
        my $gsd = skills::core::gsd($g->{worktree});
        if ($gsd) { push @out, 'GSD:'; push @out, "  $_" for @$gsd[0 .. ($#$gsd < 7 ? $#$gsd : 7)] }
        for my $wt (@{ skills::gitfacts::worktrees($g->{worktree}) }) {
            next if $wt eq $g->{worktree};
            push @out, "other STATE.md: $wt/.planning/STATE.md" if -f "$wt/.planning/STATE.md";
        }
        for my $p (@{ skills::ctx::live_peers($ctx, $g->{worktree}, $id->{sid}) }) {
            push @out, "live session: $p->{sid8} pid $p->{pid} on this checkout";
        }
    }
    my $hs = $fm->{session_id};
    if ($hs) {
        my $cp = skills::core::claude_pid();
        my $all = skills::ctx::records($ctx);
        for my $r (grep { $_->{state} eq 'live' && ($_->{data}{session_id} // '') eq $hs } @$all) {
            next if $cp && $r->{pid} eq $cp->{pid};
            push @out, "handoff session live in another process: pid $r->{pid}" if skills::ctx::record_live($ctx, $r, $all);
        }
    }
    my ($al, $arow) = skills::approvals::handoff_lines($d, $ctx, $id->{sid});
    push @out, @$al;
    $ctx->log('approvals_carry', $arow) if $arow;
    push @out, @{ needs_ask($d) };
    return \@out;
}

# D-21 commit ownership.
sub _commits {
    my ($ctx, $g, $d) = @_;
    my $gc = $d->{fm}{git_commit};
    my $cs = skills::gitfacts::commits_since($g->{worktree}, $gc) or return ('commits: not measured');
    # Only the handoff's own chain names "our" commits: a foreign hop (another session's
    # handoff carried as the base, small-rulings §2.5) never does.
    my @chain = grep { !$_->{foreign} } chain_docs($d, $ctx);
    my $named = join "\n", map { $_->{body} } @chain;
    my %in_range;
    my @gcs = grep { defined } map { $_->{fm}{git_commit} } reverse @chain;
    for my $i (1 .. $#gcs) {
        my $r = skills::gitfacts::commits_since($g->{worktree}, $gcs[ $i - 1 ]) or next;
        my $upto = skills::gitfacts::commits_since($g->{worktree}, $gcs[$i]) || [];
        my %after = map { $_->{hash} => 1 } @$upto;
        $in_range{ $_->{hash} } = 1 for grep { !$after{ $_->{hash} } } @$r;
    }
    my (@ours, @foreign);
    for my $c (@$cs) {
        if ($in_range{ $c->{hash} } || index($named, substr($c->{hash}, 0, 7)) >= 0) { push @ours, $c } else { push @foreign, $c }
    }
    my @l = (sprintf('commits since %s: %d (ours %d)', substr($gc, 0, 8), scalar @$cs, scalar @ours));
    push @l, "  $_->{short} $_->{author} ours" for @ours[0 .. ($#ours < 9 ? $#ours : 9)];
    if (@foreign) {
        my %a = map { $_->{author} => 1 } @foreign;
        push @l, sprintf('foreign: %d commits this chain did not make: %s (authors: %s)', scalar @foreign,
            join(' ', map { $_->{short} } @foreign[0 .. ($#foreign < 4 ? $#foreign : 4)]), join(', ', sort keys %a));
    }
    return @l;
}

# The handoff and its predecessors by previous_handoff, newest first (≤10), across
# foreign hops: a predecessor whose session is neither the handoff's nor in its lineage
# (A-6, 3 hops) is marked {foreign} (small-rulings §2.5).
sub chain_docs {
    my ($d, $ctx) = @_;
    my $hs = $d->{fm}{session_id} // '';
    my %own = ($hs => 1);
    if ($ctx && skills::ctx::valid_sid($hs)) { $own{ $_->{sid} } = 1 for @{ skills::ctx::chain($ctx, $hs) } }
    my @c = ($d);
    my %seen = ($d->{path} => 1);
    while (@c < 10) {
        my $p = $c[-1]{fm}{previous_handoff} or last;
        last if $seen{$p}++ || !-f $p;
        my $n = skills::store::read_doc($p) or last;
        $n->{foreign} = $own{ $n->{fm}{session_id} // '' } ? 0 : 1;
        push @c, $n;
    }
    return @c;
}

# Lint the re-check and probe commands (backticked spans in Live state and
# In flight) without running them.
sub needs_ask {
    my ($d) = @_;
    my @out;
    my $classes = eval { skills::spec::outward_classes() } || [];
    my @want = grep { /\A(?:Live state|In flight)/ } map { $_->{name} } @{ (eval { skills::spec::sections_main() } || []) };
    return [] unless @want;
    my @lines = split /\n/, $d->{text};
    my $in = 0;
    for my $i (0 .. $#lines) {
        my $l = $lines[$i];
        if ($l =~ /\A##\s/ && $l !~ /\A###/) {
            $in = grep { index($l, "## $_") == 0 } @want;
            next;
        }
        next unless $in;
        while ($l =~ /`([^`]+)`/g) {
            my $cmd = $1;
            my %hit;
            for my $c (@$classes) { $hit{ $c->{class} } = 1 if $cmd =~ $c->{re} }
            $hit{secret} = 1 if @{ skills::core::secrets_scan($cmd) };
            push @out, "needs-ask $_ line " . ($i + 1) for sort keys %hit;
        }
    }
    return \@out;
}

1;
