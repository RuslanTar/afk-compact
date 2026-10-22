package watch;
# AT-WF-01 test double for plugin/helper/lib/watch.pm: records the ctx core passes to the
# watcher seams (PKG-RUNTIME D.1) as one row per call in <sid_dir>/wf-ctx.jsonl.
use strict;
use warnings;

my @BASE = qw(sid event settings paths watch sid_dir plugin_root brand version now cc_version cc_version_src);
my %TYPE = (sid => 'str', event => 'str', settings => 'HASH', paths => 'HASH', watch => 'str', sid_dir => 'str',
            plugin_root => 'str', brand => 'str', version => 'str', now => 'num', cc_version => 'str', cc_version_src => 'str');
my %EXTRA = (PreCompact => [qw(instructions fallback_nonce)], PostCompact => ['detect'], SessionStart => [qw(dispatch resume_bytes)],
             SessionEnd => ['reconcile'], SubagentStop => ['reconcile'], Stop => ['payload']);

sub _type { my ($v) = @_; return 'null' unless defined $v; return ref $v if ref $v; return $v =~ /^-?\d+(\.\d+)?$/ ? 'num' : 'str' }

sub _record {
    my ($seam, $event, $ctx) = @_;
    my %allowed = map { $_ => 1 } @BASE, @{ $EXTRA{$event} || [] };
    my @missing = grep { !exists $ctx->{$_} } @BASE;
    my @extra = grep { !$allowed{$_} } sort keys %$ctx;
    my @bad = grep { exists $ctx->{$_} && defined $ctx->{$_} && _type($ctx->{$_}) ne $TYPE{$_}
                     && !($TYPE{$_} eq 'str' && _type($ctx->{$_}) eq 'num') } @BASE;
    my $d = $ctx->{sid_dir} // return;
    util::append("$d/wf-ctx.jsonl", jsonc::encode_bytes(jsonc::obj(ev => 'wf_ctx', seam => $seam, event => $event,
        missing => join(',', @missing), extra => join(',', @extra), bad_types => join(',', @bad),
        cc_version => $ctx->{cc_version}, cc_version_src => $ctx->{cc_version_src},
        has_cc_version => jsonc::bool(exists $ctx->{cc_version}), has_cc_version_src => jsonc::bool(exists $ctx->{cc_version_src}))) . "\n");
}

sub on_hook { my ($event, $payload, $ctx) = @_; _record('on_hook', $event, $ctx); return 1 }
sub on_stop { my ($ctx, $left) = @_; _record('on_stop', $ctx->{event} // 'Stop', $ctx); return 1 }
sub status_lines { return [] }

1;
