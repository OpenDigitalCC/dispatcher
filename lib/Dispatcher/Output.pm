package Dispatcher::Output;

use strict;
use warnings;

our $VERSION = '0.1';

# Format run results for human-readable terminal output.
#
# Args:
#   $results  - arrayref of result hashrefs from Dispatcher::Engine::dispatch_all
#
# Each result hashref:
#   { host, script, exit, stdout, stderr, rtt, error }
sub format_run_results {
    my ($results) = @_;
    for my $r (@$results) {
        my $host   = $r->{host}  // '?';
        my $exit   = $r->{exit}  // -1;
        my $rtt    = $r->{rtt}   // '';
        my $status = $exit == 0 ? 'OK' : 'FAIL';

        printf "==> %s  [%s  exit:%d  %s]\n", $host, $status, $exit, $rtt;

        if ($r->{error}) {
            print "    ERROR: $r->{error}\n";
        }
        if ($r->{stdout} && $r->{stdout} =~ /\S/) {
            print $r->{stdout};
            print "\n" unless $r->{stdout} =~ /\n$/;
        }
        if ($r->{stderr} && $r->{stderr} =~ /\S/) {
            print "    STDERR: $r->{stderr}\n";
        }
    }
}

# Format ping results as an aligned table.
#
# Args:
#   $results  - arrayref of result hashrefs from Dispatcher::Engine::ping_all
#
# Each result hashref:
#   { host, status, rtt, expiry, version, error }
sub format_ping_results {
    my ($results) = @_;
    printf "%-30s  %-8s  %-8s  %-28s  %s\n",
        'HOST', 'STATUS', 'RTT', 'CERT EXPIRY', 'VERSION';
    printf "%s\n", '-' x 85;
    for my $r (@$results) {
        printf "%-30s  %-8s  %-8s  %-28s  %s\n",
            $r->{host}    // '?',
            $r->{status}  // 'error',
            $r->{rtt}     // '?',
            $r->{expiry}  // '?',
            $r->{version} // '?';
    }
}

# Format agent list as an aligned table.
#
# Args:
#   $agents  - arrayref of agent hashrefs from Dispatcher::Registry::list_agents
#
# Each agent hashref:
#   { hostname, ip, paired, expiry }
sub format_agent_list {
    my ($agents) = @_;
    printf "%-30s  %-16s  %-22s  %s\n",
        'HOSTNAME', 'IP', 'PAIRED', 'CERT EXPIRY';
    printf "%s\n", '-' x 85;
    for my $a (@$agents) {
        printf "%-30s  %-16s  %-22s  %s\n",
            $a->{hostname} // '?',
            $a->{ip}       // '?',
            $a->{paired}   // '?',
            $a->{expiry}   // '?';
    }
}

# Format discovery results as an aligned table.
#
# Args:
#   $hosts  - hashref keyed by hostname, from the /discovery API response
#
# Each value hashref:
#   { host, status, version, rtt, scripts => [{name, path, executable},...] }
sub format_discovery {
    my ($hosts) = @_;
    for my $hostname (sort keys %$hosts) {
        my $h       = $hosts->{$hostname};
        my $status  = $h->{status}  // 'error';
        my $version = $h->{version} // '?';
        my $rtt     = $h->{rtt}     // '?';
        my @scripts = @{ $h->{scripts} // [] };

        printf "%-30s  %-6s  %-8s  %d script(s)\n",
            $hostname, $status, $rtt, scalar @scripts;

        for my $s (@scripts) {
            printf "    %-20s  %s\n", $s->{name} // '?', $s->{path} // '?';
        }
    }
}

1;
