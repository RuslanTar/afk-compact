# cmd/settings.pl: the plugin's settings, for the onboarding settings flow (0.1.2). Owner: WP-core.
#   settings show [--json] [--tier common|advanced|all] [settings flags]
#     -> settings::view(): every key's section, tier, kind, default, min/max, allowed values,
#        current value and its source (flag|env|settings|default|safe), whether the clamp moves
#        it, consent or protective class; the pluginConfigs key in use and `write_refused`
#        (config-dir-foreign, home-foreign, unreadable, unparseable, inline or ambiguous: why a
#        write there would be refused).
#        --json prints that object on one line; without it, a heading per section and one
#        `  <key> = <value> (<source>)` line per key. Read-only: no row, no file written.
# There is no write verb: whether the plugin writes settings.json from a model-run call is open
# (onboarding OPEN-1). Exit 0; 64 usage.
use strict;
use warnings;
use utf8;

package cmd_settings;

sub _text {
    my ($v) = @_;
    return '(empty)' if !defined $v || (!ref $v && $v eq '');
    return "$v";
}

sub run {
    my $verb = shift // '';
    die "usage: settings show [--json] [--tier common|advanced|all]\n" unless $verb eq 'show';
    my ($opt, $rest) = args::parse(\@_, bools => ['json'], known => [qw(tier)]);
    die "usage: settings show takes no argument ($rest->[0])\n" if @$rest;
    my $tier = $opt->{tier} // 'all';
    die "usage: --tier common|advanced|all\n" unless $tier =~ /\A(?:common|advanced|all)\z/;
    my $view = settings::view(settings::flags_from($opt), $tier);
    if ($opt->{json}) {
        print STDOUT jsonc::encode_bytes($view), "\n";
        return 0;
    }
    my %v = @$view;
    my %rows = @{ $v{settings} };
    my @out;
    for my $s (@{ $v{sections} }) {
        my %s = @$s;
        push @out, $s{title};
        for my $k (@{ $s{keys} }) {
            my %r = @{ $rows{$k} };
            my $why = $r{class} ? "; $r{class} key, settings file only" : '';
            push @out, "  $k = " . _text($r{value}) . " ($r{source}$why)";
        }
    }
    push @out, 'pluginConfigs key: ' . ($v{config_key} // "none ($v{config_key_state})");
    push @out, "writes refused: $v{write_refused}" if defined $v{write_refused};
    push @out, "note: $_" for @{ $v{notes} || [] };
    push @out, 'not in a section: ' . join(', ', @{ $v{unsectioned} }) if @{ $v{unsectioned} };
    print STDOUT map { my $l = $_; utf8::encode($l) if utf8::is_utf8($l); "$l\n" } @out;
    return 0;
}

exit(args::main(\&run, @ARGV));
