#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Dispatcher::Agent::Config qw();

# --- load_config ---

sub write_temp {
    my ($content) = @_;
    my ($fh, $path) = tempfile(UNLINK => 1, SUFFIX => '.conf');
    print $fh $content;
    close $fh;
    return $path;
}

subtest 'load_config: valid config' => sub {
    my $path = write_temp(<<'END');
port = 7443
cert = /etc/dispatcher-agent/agent.crt
key  = /etc/dispatcher-agent/agent.key
ca   = /etc/dispatcher-agent/ca.crt
END
    my $c = Dispatcher::Agent::Config::load_config($path);
    is $c->{port}, '7443',                          'port parsed';
    is $c->{cert}, '/etc/dispatcher-agent/agent.crt', 'cert parsed';
    is $c->{key},  '/etc/dispatcher-agent/agent.key', 'key parsed';
    is $c->{ca},   '/etc/dispatcher-agent/ca.crt',    'ca parsed';
};

subtest 'load_config: comments and blanks ignored' => sub {
    my $path = write_temp(<<'END');
# This is a comment
port = 7443

cert = /tmp/a.crt
key  = /tmp/a.key
ca   = /tmp/ca.crt
END
    my $c = eval { Dispatcher::Agent::Config::load_config($path) };
    ok !$@, 'no error';
    is $c->{port}, '7443', 'port correct';
};

subtest 'load_config: missing required key dies' => sub {
    my $path = write_temp("port = 7443\ncert = /a.crt\nkey = /a.key\n");
    eval { Dispatcher::Agent::Config::load_config($path) };
    like $@, qr/Missing required config key 'ca'/, 'dies on missing ca';
};

subtest 'load_config: non-numeric port dies' => sub {
    my $path = write_temp("port = abc\ncert=/a\nkey=/b\nca=/c\n");
    eval { Dispatcher::Agent::Config::load_config($path) };
    like $@, qr/port must be numeric/, 'dies on bad port';
};

subtest 'load_config: malformed line dies' => sub {
    my $path = write_temp("port = 7443\ncert=/a\nkey=/b\nca=/c\nthis is bad\n");
    eval { Dispatcher::Agent::Config::load_config($path) };
    like $@, qr/Malformed config line/, 'dies on bad line';
};

subtest 'load_config: missing file dies' => sub {
    eval { Dispatcher::Agent::Config::load_config('/nonexistent/path.conf') };
    like $@, qr/Cannot open config/, 'dies on missing file';
};

# --- load_allowlist ---

subtest 'load_allowlist: valid entries' => sub {
    my $path = write_temp(<<'END');
# comment
backup-mysql = /opt/scripts/backup.sh
rotate-logs  = /opt/scripts/rotate.sh
END
    my $al = Dispatcher::Agent::Config::load_allowlist($path);
    is $al->{'backup-mysql'}, '/opt/scripts/backup.sh', 'backup-mysql path';
    is $al->{'rotate-logs'},  '/opt/scripts/rotate.sh', 'rotate-logs path';
};

subtest 'load_allowlist: relative path skipped with warning' => sub {
    my $path = write_temp("bad-script = relative/path.sh\ngood = /abs/path.sh\n");
    my $warn = '';
    local $SIG{__WARN__} = sub { $warn .= $_[0] };
    my $al = Dispatcher::Agent::Config::load_allowlist($path);
    ok !exists $al->{'bad-script'}, 'relative path not in allowlist';
    ok  exists $al->{'good'},       'absolute path accepted';
    like $warn, qr/must be absolute/, 'warning issued';
};

subtest 'load_allowlist: malformed line skipped with warning' => sub {
    my $path = write_temp("good = /abs/path.sh\nthis line is junk!!\n");
    my $warn = '';
    local $SIG{__WARN__} = sub { $warn .= $_[0] };
    my $al = Dispatcher::Agent::Config::load_allowlist($path);
    is scalar keys %$al, 1, 'only valid entry kept';
    like $warn, qr/malformed/, 'warning issued';
};

subtest 'load_allowlist: empty file returns empty hashref' => sub {
    my $path = write_temp("# only comments\n\n");
    my $al = Dispatcher::Agent::Config::load_allowlist($path);
    is ref $al, 'HASH',       'returns hashref';
    is scalar keys %$al, 0,   'empty';
};

# --- validate_script ---

subtest 'validate_script: permitted script returns path' => sub {
    my $al = { 'check-disk' => '/opt/check-disk.sh' };
    my $path = Dispatcher::Agent::Config::validate_script('check-disk', $al);
    is $path, '/opt/check-disk.sh', 'correct path returned';
};

subtest 'validate_script: unknown script returns undef' => sub {
    my $al = { 'check-disk' => '/opt/check-disk.sh' };
    my $r = Dispatcher::Agent::Config::validate_script('rm-rf', $al);
    ok !defined $r, 'undef for unknown script';
};

subtest 'validate_script: invalid characters returns undef' => sub {
    my $al = { 'check-disk' => '/opt/check-disk.sh' };
    for my $bad ('', '../etc/passwd', 'foo;bar', 'a b', 'foo/bar') {
        my $r = Dispatcher::Agent::Config::validate_script($bad, $al);
        ok !defined $r, "undef for bad name '$bad'";
    }
};

subtest 'validate_script: undef name returns undef' => sub {
    my $al = { 'check-disk' => '/opt/check-disk.sh' };
    my $r = Dispatcher::Agent::Config::validate_script(undef, $al);
    ok !defined $r, 'undef for undef name';
};

done_testing;
