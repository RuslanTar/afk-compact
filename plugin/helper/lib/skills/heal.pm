package skills::heal;
# lib/skills/heal.pm: `heal-check --origin SID --item ID [--bump]` (resume R5
# restart gate; TPL §4.4; S-11; MOD §7 heal counters). Prints `ok <recipe>`
# or `REFUSED: counter|sha|class`. At most 1 restart per resume and 2 per
# chain; the recipe script's sha256 must equal its MANIFEST row. --bump
# counts the restart before it starts (locked read-modify-write).
use strict;
use warnings;
use skills::util;
use skills::cli;
use skills::ctx;
use skills::core;
use skills::store;
use skills::gitfacts;
use Cwd ();

our $PER_RESUME = 1;
our $PER_CHAIN  = 2;

# Recipes under <evidence dir>/restart/: [{bn, rid, class, path, script, text}]
sub recipes_in {
    my ($edir) = @_;
    my @out;
    for my $f (skills::util::list_dir("$edir/restart")) {
        next unless $f =~ /\.md\z/;
        my $p = "$edir/restart/$f";
        my $t = skills::util::read_file($p, 65536) // next;
        my %r = (path => $p, text => $t);
        if ($t =~ /^\s*item:\s*(B-\d+)(.*)$/m) {
            my ($bn, $rest) = ($1, $2);
            $r{bn} = $bn;
            ($r{rid}) = $rest =~ /runtime id\s+([^\s\x{c2}]+)/;
            ($r{class}) = $rest =~ /class\s+(auto|ask|never)\b/;
        }
        ($r{script}) = $t =~ /^\s*script:\s*(\S+)/m;
        undef $r{script} if defined $r{script} && $r{script} =~ /\Anone\z/i;
        push @out, \%r if $r{bn};
    }
    return \@out;
}

# match | differs | missing | none — the script against its MANIFEST row.
sub script_state {
    my ($r, $edir) = @_;
    return 'none' unless $r->{script};
    my $bucket = $edir =~ s{/evidence/[^/]+\z}{}r;
    my $abs = $r->{script} =~ m{\A/} ? $r->{script} : "$bucket/$r->{script}";
    my $rows = skills::store::read_manifest("$edir/MANIFEST.tsv") || [];
    my ($row) = grep { ($_->{copy_path} // '') eq $abs } @$rows;
    return 'missing' unless $row && -f $abs;
    my $sha = skills::util::sha256_file($abs) // '';
    return $sha eq ($row->{sha256} // '') ? 'match' : 'differs';
}

sub recipe_state {
    my ($r, $edir) = @_;
    my $rows = skills::store::read_manifest("$edir/MANIFEST.tsv") || [];
    my ($row) = grep { ($_->{copy_path} // '') eq $r->{path} } @$rows;
    return 'missing' unless $row;
    return (skills::util::sha256_hex($r->{text}) eq ($row->{sha256} // '')) ? 'match' : 'differs';
}

sub run {
    my ($argv) = @_;
    my $o = skills::cli::opts($argv, 'origin=s', 'item=s', 'bump');
    die skills::cli::usage('unexpected argument ' . $argv->[0]) if @$argv;
    die skills::cli::usage('--origin <session id>') unless skills::ctx::valid_sid($o->{origin});
    die skills::cli::usage('--item <runtime id>') unless defined $o->{item} && $o->{item} =~ /\A[A-Za-z0-9._:-]{1,64}\z/;
    my ($origin, $item) = ($o->{origin}, $o->{item});
    my $ctx = skills::ctx::new({});
    my $id = skills::ctx::resolve_sid($ctx, undef);
    my $row = { origin_sid => $origin, item => $item, bumped => ($o->{bump} ? \1 : \0), count => undef };

    my ($recipe, $edir) = find_recipe($ctx, $origin, $item);
    my $refuse = sub {
        my ($why) = @_;
        $row->{result} = "REFUSED:$why";
        $ctx->log('heal', $row);
        die skills::cli::refuse($why);
    };
    $refuse->('class') unless $recipe && ($recipe->{class} // 'ask') eq 'auto';
    # `auto` holds only in the same session; a new session treats every row
    # as `ask` (TPL §4.4).
    $refuse->('class') if $id->{degraded} || $id->{sid} ne $origin;
    $refuse->('sha') if recipe_state($recipe, $edir) ne 'match';
    my $ss = script_state($recipe, $edir);
    $refuse->('sha') unless $ss eq 'match' || $ss eq 'none';

    # Counter: {chain: n, by_resume: {key: n}}; one resume = one Claude Code
    # process (pid and start time), so a --resume in a new process counts anew.
    my $key = $id->{pid} ? "pid:$id->{pid}:" . ($id->{lstart} // '') : $id->{sid};
    my $dir = "$ctx->{watch}/heal/$origin";
    skills::util::mkdir_p($dir);
    my $file = "$dir/$item.count";
    my ($ok, $res) = skills::core::with_lock("$file.lock", skills::core::lock_owner($id->{sid}, 'main'), sub {
        my $c = eval { skills::util::json_decode(skills::util::read_file($file, 65536)) };
        $c = {} unless ref $c eq 'HASH';
        $c->{chain} //= 0;
        $c->{by_resume} = {} unless ref $c->{by_resume} eq 'HASH';
        my $mine = $c->{by_resume}{$key} // 0;
        return { refused => 1, chain => $c->{chain} } if $c->{chain} >= $PER_CHAIN || $mine >= $PER_RESUME;
        if ($o->{bump}) {
            $c->{chain}++;
            $c->{by_resume}{$key} = $mine + 1;
            skills::util::write_replace($file, skills::util::json_encode($c) . "\n", 0600);
        }
        return { refused => 0, chain => $c->{chain} };
    });
    $refuse->('counter') unless $ok;
    $row->{count} = $res->{chain};
    $refuse->('counter') if $res->{refused};
    $row->{result} = 'ok';
    $ctx->log('heal', $row);
    skills::cli::say("ok $recipe->{path}");
    return 0;
}

# The newest handoff of the origin session that has a recipe for the item
# (B-n or runtime id). Returns ($recipe, $evidence_dir).
sub find_recipe {
    my ($ctx, $origin, $item) = @_;
    my %b;
    my $pin = skills::ctx::pin_read($ctx, $origin);
    $b{ $pin->{bucket_path} } = 1 if $pin && $pin->{bucket_path};
    my $w = skills::gitfacts::where(Cwd::getcwd());
    $b{$_} = 1 for @{ skills::store::buckets($ctx->{root}, $w->{repo}) };
    my @docs = sort { ($b->{epoch} // 0) <=> ($a->{epoch} // 0) }
               grep { ($_->{fm}{session_id} // '') eq $origin } map { @{ skills::store::docs_in($_) } } sort keys %b;
    for my $d (@docs) {
        my $edir = skills::store::bucket_of($d->{path}) . '/evidence/' . skills::store::stem_of($d->{path});
        for my $r (@{ recipes_in($edir) }) {
            return ($r, $edir) if $r->{bn} eq $item || (defined $r->{rid} && $r->{rid} eq $item);
        }
    }
    return (undef, undef);
}

1;
