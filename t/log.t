#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

# We test log_action output by intercepting the syslog call.
# We override Sys::Syslog's syslog() before loading our module.

my @logged;

BEGIN {
    # Stub out Sys::Syslog before it can be loaded, injecting into its namespace
    %Sys::Syslog:: = () unless %Sys::Syslog::;
    $INC{'Sys/Syslog.pm'} = 1;

    no strict 'refs';
    *{'Sys::Syslog::openlog'}  = sub { };
    *{'Sys::Syslog::closelog'} = sub { };
    *{'Sys::Syslog::syslog'}   = sub {
        my ($priority, $fmt, @args) = @_;
        push @logged, { priority => $priority, msg => sprintf($fmt, @args) };
    };
    *{'Sys::Syslog::import'} = sub {
        my $caller = caller(0);
        no strict 'refs';
        for my $fn (qw(openlog closelog syslog)) {
            *{"${caller}::${fn}"} = \&{"Sys::Syslog::${fn}"};
        }
    };
}

use Exec::Log qw();

Exec::Log::init('test-ctrl-exec');

sub last_log { $logged[-1] }
sub clear_log { @logged = () }

subtest 'log_action: ACTION appears first' => sub {
    clear_log();
    Exec::Log::log_action('INFO', { ACTION => 'run', SCRIPT => 'backup', EXIT => 0 });
    my $msg = last_log()->{msg};
    like $msg, qr/^ACTION=run\b/, 'ACTION is first field';
};

subtest 'log_action: all fields present' => sub {
    clear_log();
    Exec::Log::log_action('INFO', {
        ACTION => 'run',
        SCRIPT => 'check-disk',
        EXIT   => 0,
        REQID  => 'abc123',
        TARGET => 'prod-01',
    });
    my $msg = last_log()->{msg};
    like $msg, qr/ACTION=run/,       'ACTION';
    like $msg, qr/SCRIPT=check-disk/, 'SCRIPT';
    like $msg, qr/EXIT=0/,           'EXIT';
    like $msg, qr/REQID=abc123/,     'REQID';
    like $msg, qr/TARGET=prod-01/,   'TARGET';
};

subtest 'log_action: values with spaces are quoted' => sub {
    clear_log();
    Exec::Log::log_action('INFO', {
        ACTION => 'deny',
        ERROR  => 'script not permitted',
    });
    my $msg = last_log()->{msg};
    like $msg, qr/ERROR="script not permitted"/, 'quoted value';
};

subtest 'log_action: missing ACTION dies' => sub {
    eval { Exec::Log::log_action('INFO', { SCRIPT => 'x' }) };
    like $@, qr/ACTION field required/, 'dies without ACTION';
};

subtest 'log_action: non-hashref dies' => sub {
    eval { Exec::Log::log_action('INFO', ['foo']) };
    like $@, qr/fields must be a hashref/, 'dies on arrayref';
};

subtest 'log_action: remaining fields in alphabetical order' => sub {
    clear_log();
    Exec::Log::log_action('INFO', {
        ACTION => 'ping',
        ZZLAST => 'z',
        AAFIRST => 'a',
        MMIDDLE => 'm',
    });
    my $msg = last_log()->{msg};
    # ACTION first, then AAFIRST < MMIDDLE < ZZLAST
    my @positions = map { index($msg, $_) } qw(ACTION= AAFIRST= MMIDDLE= ZZLAST=);
    is_deeply \@positions, [sort { $a <=> $b } @positions], 'alphabetical after ACTION';
};

subtest 'log_action: undef value rendered as empty string' => sub {
    clear_log();
    Exec::Log::log_action('INFO', { ACTION => 'test', FOO => undef });
    my $msg = last_log()->{msg};
    like $msg, qr/FOO=(\s|$)/, 'undef renders as empty';
};

done_testing;
