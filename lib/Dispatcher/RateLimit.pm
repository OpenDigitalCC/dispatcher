package Dispatcher::Agent::RateLimit;

use strict;
use warnings;
use Dispatcher::Log qw();

# Volume threshold: connections within the short window
use constant VOLUME_WINDOW   => 60;
use constant VOLUME_LIMIT    => 10;
use constant VOLUME_BLOCK    => 300;   # 5 minutes

# Probe threshold: handshake failures within the long window
use constant PROBE_WINDOW    => 600;
use constant PROBE_LIMIT     => 3;
use constant PROBE_BLOCK     => 3600;  # 1 hour

# Pruning window: the longer of the two windows
use constant PRUNE_WINDOW    => 600;

# Maximum number of distinct IP entries before eviction
use constant MAX_ENTRIES     => 1000;


# check($peer_ip, $rate_state_ref) -> 1 (blocked) or 0 (allow)
#
# Called in the parent accept loop before fork(). Checks both volume and probe
# thresholds. Applies a block and logs on first trigger. Returns 1 silently
# for IPs already under an active block.
sub check {
    my ($peer, $state_ref) = @_;

    my $now = time();

    # Step 1: Already blocked?
    if (exists $state_ref->{$peer} &&
        exists $state_ref->{$peer}{blocked_until} &&
        $state_ref->{$peer}{blocked_until} > $now) {
        return 1;
    }

    # Step 2: Block expired - clear entire entry and continue
    if (exists $state_ref->{$peer} &&
        exists $state_ref->{$peer}{blocked_until}) {
        delete $state_ref->{$peer};
    }

    # Step 3: Evict one entry if at capacity
    if (scalar keys %$state_ref >= MAX_ENTRIES) {
        my @sorted = sort {
            ($state_ref->{$a}{blocked_until} // 0)
            <=>
            ($state_ref->{$b}{blocked_until} // 0)
        } keys %$state_ref;
        delete $state_ref->{ $sorted[0] };
        Dispatcher::Log::log_action('WARNING', {
            ACTION => 'rate-evict',
            COUNT  => MAX_ENTRIES,
        });
    }

    # Ensure entry exists before pruning
    $state_ref->{$peer} //= { connections => [], failures => [] };
    my $entry = $state_ref->{$peer};

    # Step 4: Prune timestamps older than the long window from both arrays
    $entry->{connections} = [ grep { $now - $_ < PRUNE_WINDOW } @{ $entry->{connections} } ];
    $entry->{failures}    = [ grep { $now - $_ < PRUNE_WINDOW } @{ $entry->{failures}    } ];

    # Step 5: Volume check - count connections within the short window only
    my $recent_conns = grep { $now - $_ < VOLUME_WINDOW } @{ $entry->{connections} };
    if ($recent_conns >= VOLUME_LIMIT) {
        $entry->{blocked_until} = $now + VOLUME_BLOCK;
        Dispatcher::Log::log_action('WARNING', {
            ACTION => 'rate-block',
            PEER   => $peer,
            REASON => 'volume',
        });
        return 1;
    }

    # Step 6: Probe check - count failures within the probe window
    my $recent_fails = grep { $now - $_ < PROBE_WINDOW } @{ $entry->{failures} };
    if ($recent_fails >= PROBE_LIMIT) {
        $entry->{blocked_until} = $now + PROBE_BLOCK;
        Dispatcher::Log::log_action('WARNING', {
            ACTION => 'rate-block',
            PEER   => $peer,
            REASON => 'probe',
        });
        return 1;
    }

    return 0;
}


# record_connection($peer_ip, $rate_state_ref) -> void
#
# Called after check() returns 0, before fork(). Records a post-handshake
# connection timestamp for volume tracking.
sub record_connection {
    my ($peer, $state_ref) = @_;

    $state_ref->{$peer} //= { connections => [], failures => [] };
    push @{ $state_ref->{$peer}{connections} }, time();
}


# record_failure($peer_ip, $rate_state_ref) -> void
#
# Called when a TLS handshake failure is detected (item 3 call site). Records
# a failure timestamp for probe tracking.
sub record_failure {
    my ($peer, $state_ref) = @_;

    $state_ref->{$peer} //= { connections => [], failures => [] };
    push @{ $state_ref->{$peer}{failures} }, time();
}

1;
