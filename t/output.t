#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Dispatcher::Output qw();

sub capture_stdout {
    my ($code) = @_;
    open my $old, '>&', \*STDOUT or die "Cannot dup STDOUT: $!";
    close STDOUT;
    open STDOUT, '>', \my $buf or die "Cannot redirect STDOUT: $!";
    $code->();
    close STDOUT;
    open STDOUT, '>&', $old or die "Cannot restore STDOUT: $!";
    return $buf;
}

# --- format_run_results ---

{
    my $out = capture_stdout(sub {
        Dispatcher::Output::format_run_results([{
            host   => 'host-a',
            exit   => 0,
            stdout => "hello\n",
            stderr => '',
            rtt    => '42ms',
        }]);
    });
    like $out, qr/==> host-a/,  'run: host in output';
    like $out, qr/OK/,           'run: OK for exit 0';
    like $out, qr/exit:0/,       'run: exit code shown';
    like $out, qr/42ms/,         'run: rtt shown';
    like $out, qr/hello/,        'run: stdout shown';
}

{
    my $out = capture_stdout(sub {
        Dispatcher::Output::format_run_results([{
            host   => 'host-b',
            exit   => 1,
            stdout => '',
            stderr => 'something failed',
            rtt    => '10ms',
        }]);
    });
    like $out, qr/FAIL/,             'run: FAIL for non-zero exit';
    like $out, qr/something failed/, 'run: stderr shown';
}

{
    my $out = capture_stdout(sub {
        Dispatcher::Output::format_run_results([{
            host  => 'host-c',
            exit  => -1,
            error => 'connection refused',
            rtt   => '5ms',
        }]);
    });
    like $out, qr/FAIL/,              'run: FAIL for error result';
    like $out, qr/connection refused/, 'run: error message shown';
}

{
    # stdout with no trailing newline gets one added
    my $out = capture_stdout(sub {
        Dispatcher::Output::format_run_results([{
            host   => 'host-d',
            exit   => 0,
            stdout => 'no newline',
            rtt    => '1ms',
        }]);
    });
    like $out, qr/no newline\n/, 'run: newline appended to stdout without one';
}

{
    # whitespace-only stdout is suppressed
    my $out = capture_stdout(sub {
        Dispatcher::Output::format_run_results([{
            host   => 'host-e',
            exit   => 0,
            stdout => "   \n",
            rtt    => '1ms',
        }]);
    });
    unlike $out, qr/\s{3}/, 'run: whitespace-only stdout suppressed';
}

{
    # multiple hosts in one call
    my $out = capture_stdout(sub {
        Dispatcher::Output::format_run_results([
            { host => 'host-a', exit => 0, rtt => '10ms' },
            { host => 'host-b', exit => 2, rtt => '20ms' },
        ]);
    });
    like $out, qr/host-a/, 'run: first host present in multi-host output';
    like $out, qr/host-b/, 'run: second host present in multi-host output';
    like $out, qr/OK/,     'run: OK present in multi-host output';
    like $out, qr/FAIL/,   'run: FAIL present in multi-host output';
}

# --- format_ping_results ---

{
    my $out = capture_stdout(sub {
        Dispatcher::Output::format_ping_results([{
            host    => 'host-a',
            status  => 'ok',
            rtt     => '55ms',
            expiry  => 'Jun  7 2028',
            version => '0.1',
        }]);
    });
    like $out, qr/HOST/,       'ping: header row present';
    like $out, qr/host-a/,     'ping: host shown';
    like $out, qr/ok/,         'ping: status shown';
    like $out, qr/55ms/,       'ping: rtt shown';
    like $out, qr/Jun.*2028/,  'ping: expiry shown';
    like $out, qr/0\.1/,       'ping: version shown';
}

{
    my $out = capture_stdout(sub {
        Dispatcher::Output::format_ping_results([{
            host   => 'host-b',
            status => 'error',
            rtt    => '999ms',
        }]);
    });
    like $out, qr/error/, 'ping: error status shown';
    like $out, qr/\?/,    'ping: missing fields shown as ?';
}

# --- format_agent_list ---

{
    my $out = capture_stdout(sub {
        Dispatcher::Output::format_agent_list([{
            hostname => 'agent-1',
            ip       => '10.0.0.1',
            paired   => '2025-01-01T00:00:00Z',
            expiry   => 'Jun  7 2028',
        }]);
    });
    like $out, qr/HOSTNAME/,            'agents: header row present';
    like $out, qr/agent-1/,             'agents: hostname shown';
    like $out, qr/10\.0\.0\.1/,         'agents: ip shown';
    like $out, qr/2025-01-01/,          'agents: paired date shown';
    like $out, qr/Jun.*2028/,           'agents: expiry shown';
}

{
    my $out = capture_stdout(sub {
        Dispatcher::Output::format_agent_list([{
            hostname => undef,
            ip       => undef,
            paired   => undef,
            expiry   => undef,
        }]);
    });
    my @questions = ($out =~ /\?/g);
    ok scalar(@questions) >= 4, 'agents: undef fields shown as ?';
}

# --- format_discovery ---

{
    my $out = capture_stdout(sub {
        Dispatcher::Output::format_discovery({
            'host-a' => {
                host    => 'host-a',
                status  => 'ok',
                version => '0.1',
                rtt     => '68ms',
                scripts => [
                    { name => 'backup', path => '/opt/dispatcher-scripts/backup.sh', executable => 1 },
                    { name => 'check',  path => '/opt/dispatcher-scripts/check.sh',  executable => 1 },
                ],
            },
        });
    });
    like $out, qr/host-a/,   'discovery: hostname shown';
    like $out, qr/ok/,        'discovery: status shown';
    like $out, qr/68ms/,      'discovery: rtt shown';
    like $out, qr/2 script/,  'discovery: script count shown';
    like $out, qr/backup/,    'discovery: script name shown';
}

{
    my $out = capture_stdout(sub {
        Dispatcher::Output::format_discovery({
            'host-b' => {
                host    => 'host-b',
                status  => 'ok',
                scripts => [],
            },
        });
    });
    like $out, qr/0 script/, 'discovery: zero scripts shown correctly';
}

done_testing;
