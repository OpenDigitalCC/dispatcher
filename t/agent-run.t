#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Dispatcher::Agent::Runner qw();

sub make_script {
    my ($content) = @_;
    my ($fh, $path) = tempfile(UNLINK => 1, SUFFIX => '.sh');
    print $fh "#!/bin/sh\n$content\n";
    close $fh;
    chmod 0755, $path;
    return $path;
}

subtest 'run_script: stdout captured' => sub {
    my $s = make_script('echo hello');
    my $r = Dispatcher::Agent::Runner::run_script($s, []);
    is $r->{exit},   0,         'exit 0';
    like $r->{stdout}, qr/hello/, 'stdout captured';
    is $r->{stderr}, '',          'stderr empty';
};

subtest 'run_script: stderr captured separately' => sub {
    my $s = make_script('echo oops >&2');
    my $r = Dispatcher::Agent::Runner::run_script($s, []);
    is   $r->{exit},   0,      'exit 0';
    is   $r->{stdout}, '',     'stdout empty';
    like $r->{stderr}, qr/oops/, 'stderr captured';
};

subtest 'run_script: non-zero exit code returned' => sub {
    my $s = make_script('exit 42');
    my $r = Dispatcher::Agent::Runner::run_script($s, []);
    is $r->{exit}, 42, 'exit 42 returned';
};

subtest 'run_script: args passed to script' => sub {
    my $s = make_script('echo "arg=$1"');
    my $r = Dispatcher::Agent::Runner::run_script($s, ['testvalue']);
    like $r->{stdout}, qr/arg=testvalue/, 'arg passed correctly';
};

subtest 'run_script: multiple args' => sub {
    my $s = make_script('echo "$1 $2 $3"');
    my $r = Dispatcher::Agent::Runner::run_script($s, ['a', 'b', 'c']);
    like $r->{stdout}, qr/a b c/, 'multiple args passed';
};

subtest 'run_script: args with spaces not interpreted as shell' => sub {
    my $s = make_script('echo "$1"');
    my $r = Dispatcher::Agent::Runner::run_script($s, ['hello world']);
    like $r->{stdout}, qr/hello world/, 'space in arg preserved';
};

subtest 'run_script: both stdout and stderr populated' => sub {
    my $s = make_script('echo out; echo err >&2; exit 1');
    my $r = Dispatcher::Agent::Runner::run_script($s, []);
    like $r->{stdout}, qr/out/, 'stdout present';
    like $r->{stderr}, qr/err/, 'stderr present';
    is   $r->{exit},   1,       'exit 1';
};

subtest 'run_script: nonexistent script returns error' => sub {
    my $r = Dispatcher::Agent::Runner::run_script('/nonexistent/script.sh', []);
    isnt $r->{exit}, 0, 'non-zero exit for missing script';
};

subtest 'run_script: no shell injection via args' => sub {
    # If args were passed to a shell, this would execute 'id'
    my $s = make_script('printf "%s" "$1"');
    my $r = Dispatcher::Agent::Runner::run_script($s, ['$(id)']);
    like $r->{stdout}, qr/\$\(id\)/, 'literal string, not executed';
};

subtest 'run_script: large output handled' => sub {
    my $s = make_script('seq 1 10000');
    my $r = Dispatcher::Agent::Runner::run_script($s, []);
    is $r->{exit}, 0, 'exit 0 for large output';
    my @lines = split /\n/, $r->{stdout};
    is scalar @lines, 10000, '10000 lines captured';
};

# --- JSON context on stdin ---

subtest 'run_script: context JSON piped to stdin' => sub {
    my $s = make_script('cat');   # echo stdin to stdout
    my $context = {
        script    => 'test-script',
        args      => ['--db', 'myapp'],
        reqid     => 'abc1230001',
        peer_ip   => '10.0.0.1',
        username  => 'stuart',
        token     => 'tok123',
        timestamp => '2026-03-06T12:00:00Z',
    };
    my $r = Dispatcher::Agent::Runner::run_script($s, [], $context);
    is   $r->{exit}, 0, 'exit 0';
    like $r->{stdout}, qr/"script"\s*:\s*"test-script"/, 'script in JSON';
    like $r->{stdout}, qr/"username"\s*:\s*"stuart"/,    'username in JSON';
    like $r->{stdout}, qr/"token"\s*:\s*"tok123"/,       'token in JSON';
    like $r->{stdout}, qr/"peer_ip"\s*:\s*"10\.0\.0\.1"/, 'peer_ip in JSON';
};

subtest 'run_script: args array preserved in context JSON' => sub {
    my $s = make_script('cat');
    my $context = {
        script    => 'test',
        args      => ['--db', 'myapp'],
        reqid     => 'x',
        peer_ip   => '127.0.0.1',
        username  => '',
        token     => '',
        timestamp => '2026-03-06T12:00:00Z',
    };
    my $r = Dispatcher::Agent::Runner::run_script($s, [], $context);
    like $r->{stdout}, qr/"args"/, 'args key present in JSON';
    like $r->{stdout}, qr/myapp/,  'args value present in JSON';
};

subtest 'run_script: no context means empty stdin' => sub {
    # Script exits non-zero if it reads anything from stdin
    my $s = make_script('read -t 0.1 line && exit 1; exit 0');
    my $r = Dispatcher::Agent::Runner::run_script($s, [], undef);
    is $r->{exit}, 0, 'no context: stdin empty, script exits 0';
};

subtest 'run_script: script can ignore stdin via redirect' => sub {
    my $s = make_script('exec 0</dev/null; echo done');
    my $context = {
        script    => 'test',
        args      => [],
        reqid     => 'x',
        peer_ip   => '127.0.0.1',
        username  => '',
        token     => '',
        timestamp => '2026-03-06T12:00:00Z',
    };
    my $r = Dispatcher::Agent::Runner::run_script($s, [], $context);
    is   $r->{exit},   0,      'exit 0 after redirecting stdin away';
    like $r->{stdout}, qr/done/, 'script ran to completion';
};

subtest 'run_script: positional args unchanged when context present' => sub {
    my $s = make_script('echo "arg=$1"');
    my $context = { script => 'test', args => [], reqid => 'x',
                    peer_ip => '127.0.0.1', username => '', token => '',
                    timestamp => '2026-03-06T12:00:00Z' };
    my $r = Dispatcher::Agent::Runner::run_script($s, ['myvalue'], $context);
    like $r->{stdout}, qr/arg=myvalue/, 'positional arg passed with context present';
};

done_testing;
