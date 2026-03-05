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

done_testing;
