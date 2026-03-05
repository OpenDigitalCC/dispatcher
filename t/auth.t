#!/usr/bin/perl
use strict;
use warnings;
use Test::More tests => 29;
use File::Temp qw(tempdir);
use FindBin    qw($Bin);
use lib "$Bin/../lib";

use Dispatcher::Auth qw();

# Silence syslog during tests - Log falls back to stderr if not init'd,
# redirect stderr to suppress that noise
open my $saved_stderr, '>&', \*STDERR;
open STDERR, '>', '/dev/null';

my $tmpdir = tempdir(CLEANUP => 1);

# Helper: write an executable hook script
sub make_hook {
    my ($name, $content) = @_;
    my $path = "$tmpdir/$name";
    open my $fh, '>', $path or die "Cannot write $path: $!";
    print $fh "#!/bin/bash\n$content\n";
    close $fh;
    chmod 0755, $path;
    return $path;
}

# --- no hook configured ---

{
    my $result = Dispatcher::Auth::check(
        action => 'run',
        config => {},
    );
    ok $result->{ok}, 'no hook: authorised by default';
}

{
    my $result = Dispatcher::Auth::check(
        action => 'ping',
        config => {},
    );
    ok $result->{ok}, 'no hook: ping authorised by default';
}

{
    my $result = Dispatcher::Auth::check(
        action => 'run',
        config => { auth_hook => '' },
    );
    ok $result->{ok}, 'empty hook path: authorised by default';
}

# --- hook not found / not executable ---

{
    my $result = Dispatcher::Auth::check(
        action => 'run',
        config => { auth_hook => "$tmpdir/does-not-exist" },
    );
    ok !$result->{ok}, 'missing hook: denied';
    like $result->{reason}, qr/not found or not executable/, 'missing hook: reason';
}

{
    my $path = "$tmpdir/not-exec";
    open my $fh, '>', $path or die $!;
    print $fh "#!/bin/bash\nexit 0\n";
    close $fh;
    chmod 0644, $path;   # not executable

    my $result = Dispatcher::Auth::check(
        action => 'run',
        config => { auth_hook => $path },
    );
    ok !$result->{ok}, 'non-executable hook: denied';
}

# --- hook exit codes ---

{
    my $hook = make_hook('allow', 'exit 0');
    my $result = Dispatcher::Auth::check(
        action => 'run',
        config => { auth_hook => $hook },
    );
    ok $result->{ok}, 'exit 0: authorised';
}

{
    my $hook = make_hook('deny-generic', 'exit 1');
    my $result = Dispatcher::Auth::check(
        action => 'run',
        config => { auth_hook => $hook },
    );
    ok !$result->{ok},            'exit 1: denied';
    is $result->{code},   1,      'exit 1: code';
    is $result->{reason}, 'denied', 'exit 1: reason';
}

{
    my $hook = make_hook('deny-creds', 'exit 2');
    my $result = Dispatcher::Auth::check(
        action => 'run',
        config => { auth_hook => $hook },
    );
    ok !$result->{ok},                  'exit 2: denied';
    is $result->{code},   2,            'exit 2: code';
    is $result->{reason}, 'bad credentials', 'exit 2: reason';
}

{
    my $hook = make_hook('deny-priv', 'exit 3');
    my $result = Dispatcher::Auth::check(
        action => 'run',
        config => { auth_hook => $hook },
    );
    ok !$result->{ok},                        'exit 3: denied';
    is $result->{code},   3,                  'exit 3: code';
    is $result->{reason}, 'insufficient privilege', 'exit 3: reason';
}

{
    my $hook = make_hook('deny-other', 'exit 99');
    my $result = Dispatcher::Auth::check(
        action => 'run',
        config => { auth_hook => $hook },
    );
    ok !$result->{ok},                    'exit 99: denied';
    like $result->{reason}, qr/hook exited 99/, 'exit 99: reason contains code';
}

# --- environment variables passed to hook ---

{
    my $hook = make_hook('check-env', <<'HOOK');
[[ "$DISPATCHER_ACTION" == "run" ]]   || exit 1
[[ "$DISPATCHER_SCRIPT" == "backup" ]] || exit 2
[[ "$DISPATCHER_HOSTS"  == "host-a,host-b" ]] || exit 3
[[ "$DISPATCHER_USERNAME" == "stuart" ]] || exit 4
[[ "$DISPATCHER_SOURCE_IP" == "10.0.0.1" ]] || exit 5
exit 0
HOOK

    my $result = Dispatcher::Auth::check(
        action    => 'run',
        script    => 'backup',
        hosts     => ['host-a', 'host-b'],
        username  => 'stuart',
        source_ip => '10.0.0.1',
        config    => { auth_hook => $hook },
    );
    ok $result->{ok}, 'env vars: all passed correctly to hook';
}

# --- token passed to hook ---

{
    my $hook = make_hook('check-token', <<'HOOK');
[[ "$DISPATCHER_TOKEN" == "secret123" ]] || exit 2
exit 0
HOOK

    my $result = Dispatcher::Auth::check(
        action => 'run',
        token  => 'secret123',
        config => { auth_hook => $hook },
    );
    ok $result->{ok}, 'token: passed to hook via env';
}

{
    my $hook = make_hook('check-token-bad', <<'HOOK');
[[ "$DISPATCHER_TOKEN" == "secret123" ]] || exit 2
exit 0
HOOK

    my $result = Dispatcher::Auth::check(
        action => 'run',
        token  => 'wrongtoken',
        config => { auth_hook => $hook },
    );
    ok !$result->{ok},               'token: bad token denied';
    is $result->{code}, 2,           'token: bad token returns code 2';
}

# --- JSON stdin passed to hook ---

{
    # Hook reads JSON from stdin and checks a field
    my $hook = make_hook('check-json', <<'HOOK');
input=$(cat)
echo "$input" | grep -q '"action":"run"' || exit 1
echo "$input" | grep -q '"script":"deploy"' || exit 1
exit 0
HOOK

    my $result = Dispatcher::Auth::check(
        action => 'run',
        script => 'deploy',
        config => { auth_hook => $hook },
    );
    ok $result->{ok}, 'JSON stdin: hook reads action and script from stdin';
}

# --- argument validation ---

{
    eval { Dispatcher::Auth::check(config => {}) };
    like $@, qr/action required/, 'check: dies without action';
}

{
    eval { Dispatcher::Auth::check(action => 'run') };
    like $@, qr/config required/, 'check: dies without config';
}

{
    eval { Dispatcher::Auth::check(action => 'run', config => {}, hosts => 'bad') };
    like $@, qr/hosts must be an arrayref/, 'check: dies if hosts not arrayref';
}

# Restore stderr
open STDERR, '>&', $saved_stderr;

done_testing;
