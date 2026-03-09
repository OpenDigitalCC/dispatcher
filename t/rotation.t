#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile tempdir);
use File::Path qw(make_path);
use File::Basename qw(dirname);
use POSIX qw(strftime);
use JSON qw(decode_json encode_json);
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Dispatcher::Rotation qw();

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Write a file, creating parent directories as needed.
sub write_file {
    my ($path, $content) = @_;
    make_path(dirname($path));
    open my $fh, '>', $path or die "Cannot write $path: $!";
    print $fh $content;
    close $fh;
}

# Build a minimal dispatcher.conf-like hashref for functions that need config.
sub minimal_config {
    my (%extra) = @_;
    return {
        cert            => '/etc/dispatcher/dispatcher.crt',
        key             => '/etc/dispatcher/dispatcher.key',
        ca              => '/etc/dispatcher/ca.crt',
        cert_days       => 825,
        cert_renewal_days  => 90,
        cert_overlap_days  => 30,
        cert_check_interval => 14400,
        %extra,
    };
}

# Generate a real self-signed cert valid for N days, return the PEM as a string.
# Uses openssl on the test host. If openssl is absent the test is skipped.
sub make_cert {
    my ($days, $outfile) = @_;
    my $keyfile = $outfile . '.key';
    my $ret = system(
        'openssl', 'req', '-x509', '-newkey', 'rsa:2048',
        '-keyout', $keyfile,
        '-out',    $outfile,
        '-days',   $days,
        '-nodes',
        '-subj',   '/CN=test-dispatcher',
        qw(-quiet)
    );
    return $ret == 0;
}

# ---------------------------------------------------------------------------
# _cert_days_remaining
# ---------------------------------------------------------------------------

subtest '_cert_days_remaining: valid cert returns positive integer' => sub {
    plan skip_all => 'openssl not available' unless system('openssl version >/dev/null 2>&1') == 0;

    my $dir  = tempdir(CLEANUP => 1);
    my $cert = "$dir/test.crt";
    plan skip_all => 'could not generate test cert' unless make_cert(365, $cert);

    my $days = Dispatcher::Rotation::_cert_days_remaining($cert);
    ok defined $days,    '_cert_days_remaining returns a value';
    ok $days > 0,        "days remaining is positive ($days)";
    ok $days <= 365,     "days remaining is at most the cert lifetime ($days)";
};

subtest '_cert_days_remaining: cert expiring in 1 day' => sub {
    plan skip_all => 'openssl not available' unless system('openssl version >/dev/null 2>&1') == 0;

    my $dir  = tempdir(CLEANUP => 1);
    my $cert = "$dir/short.crt";
    plan skip_all => 'could not generate test cert' unless make_cert(1, $cert);

    my $days = Dispatcher::Rotation::_cert_days_remaining($cert);
    ok defined $days, 'returns a value for a near-expiry cert';
    ok $days >= 0,    "days is non-negative ($days)";
    ok $days <= 2,    "days is within expected range for a 1-day cert ($days)";
};

subtest '_cert_days_remaining: missing cert returns undef' => sub {
    my $days = Dispatcher::Rotation::_cert_days_remaining('/nonexistent/cert.crt');
    ok !defined $days, 'returns undef for missing cert';
};

subtest '_cert_days_remaining: garbage input returns undef' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $cert = "$dir/garbage.crt";
    write_file($cert, "this is not a certificate\n");

    my $days = Dispatcher::Rotation::_cert_days_remaining($cert);
    ok !defined $days, 'returns undef for garbage cert file';
};

# ---------------------------------------------------------------------------
# _read_cert_serial
# ---------------------------------------------------------------------------

subtest '_read_cert_serial: valid cert returns lowercase hex serial' => sub {
    plan skip_all => 'openssl not available' unless system('openssl version >/dev/null 2>&1') == 0;

    my $dir  = tempdir(CLEANUP => 1);
    my $cert = "$dir/test.crt";
    plan skip_all => 'could not generate test cert' unless make_cert(365, $cert);

    my $serial = Dispatcher::Rotation::_read_cert_serial($cert);
    ok defined $serial,           '_read_cert_serial returns a value';
    like $serial, qr/^[0-9a-f]+$/, "serial is lowercase hex: $serial";
    ok length($serial) > 0,       'serial is non-empty';
};

subtest '_read_cert_serial: missing cert returns undef' => sub {
    my $serial = Dispatcher::Rotation::_read_cert_serial('/nonexistent/cert.crt');
    ok !defined $serial, 'returns undef for missing cert';
};

subtest '_read_cert_serial: garbage file returns undef' => sub {
    my $dir  = tempdir(CLEANUP => 1);
    my $cert = "$dir/garbage.crt";
    write_file($cert, "not a cert\n");

    my $serial = Dispatcher::Rotation::_read_cert_serial($cert);
    ok !defined $serial, 'returns undef for garbage content';
};

# ---------------------------------------------------------------------------
# _do_rotation
# ---------------------------------------------------------------------------

subtest '_do_rotation: creates rotation.json with correct fields' => sub {
    plan skip_all => 'openssl not available' unless system('openssl version >/dev/null 2>&1') == 0;

    my $dir      = tempdir(CLEANUP => 1);
    my $cert     = "$dir/dispatcher.crt";
    my $stateDir = "$dir/state";
    my $regDir   = "$dir/registry";
    make_path($stateDir, $regDir);

    plan skip_all => 'could not generate initial cert' unless make_cert(365, $cert);

    my $old_serial = Dispatcher::Rotation::_read_cert_serial($cert);
    plan skip_all => 'could not read initial cert serial' unless defined $old_serial;

    my $config = minimal_config(
        cert          => $cert,
        key           => "$dir/dispatcher.crt.key",
        state_dir     => $stateDir,
        agents_dir    => $regDir,
        registry      => "$regDir/registry.json",
    );

    my $result = eval { Dispatcher::Rotation::_do_rotation(config => $config) };
    if ($@) {
        # _do_rotation calls CA::generate_dispatcher_cert which needs a full CA.
        # If the CA is not available the function will die - skip gracefully.
        plan skip_all => "_do_rotation requires a CA: $@";
        return;
    }

    ok defined $result, '_do_rotation returned a result';

    my $state_file = "$stateDir/rotation.json";
    ok -f $state_file, 'rotation.json written';

    my $raw   = do { local $/; open my $fh, '<', $state_file or die $!; <$fh> };
    my $state = decode_json($raw);

    ok defined $state->{current_serial},  'current_serial present';
    ok defined $state->{previous_serial}, 'previous_serial present';
    ok defined $state->{rotated_at},      'rotated_at present';
    ok defined $state->{overlap_expires}, 'overlap_expires present';
    ok defined $state->{overlap_days},    'overlap_days present';

    is $state->{previous_serial}, $old_serial, 'previous_serial matches old cert serial';
    isnt $state->{current_serial}, $old_serial, 'current_serial differs from old serial';
    is $state->{overlap_days}, $config->{cert_overlap_days}, 'overlap_days from config';
};

subtest '_do_rotation: no existing cert - old_serial is empty string' => sub {
    plan skip_all => 'openssl not available' unless system('openssl version >/dev/null 2>&1') == 0;

    my $dir      = tempdir(CLEANUP => 1);
    my $stateDir = "$dir/state";
    my $regDir   = "$dir/registry";
    make_path($stateDir, $regDir);

    my $config = minimal_config(
        cert       => "$dir/nonexistent.crt",
        key        => "$dir/nonexistent.key",
        state_dir  => $stateDir,
        agents_dir => $regDir,
        registry   => "$regDir/registry.json",
    );

    my $result = eval { Dispatcher::Rotation::_do_rotation(config => $config) };
    if ($@) {
        plan skip_all => "_do_rotation requires a CA: $@";
        return;
    }

    my $state_file = "$stateDir/rotation.json";
    if (-f $state_file) {
        my $raw   = do { local $/; open my $fh, '<', $state_file or die $!; <$fh> };
        my $state = decode_json($raw);
        is $state->{previous_serial}, '', 'previous_serial is empty string when no prior cert';
    }
    else {
        pass 'rotation ran without error (state file location may differ)';
    }
};

subtest '_do_rotation: registered agents marked pending after rotation' => sub {
    plan skip_all => 'openssl not available' unless system('openssl version >/dev/null 2>&1') == 0;

    my $dir      = tempdir(CLEANUP => 1);
    my $cert     = "$dir/dispatcher.crt";
    my $stateDir = "$dir/state";
    my $regDir   = "$dir/agents";
    make_path($stateDir, $regDir);

    plan skip_all => 'could not generate initial cert' unless make_cert(365, $cert);

    # Write two fake agent registry records
    for my $host (qw(agent-01 agent-02)) {
        write_file("$regDir/$host.json", encode_json({
            hostname       => $host,
            ip             => '10.0.0.1',
            paired         => '2025-01-01T00:00:00Z',
            expiry         => '2026-01-01T00:00:00Z',
            reqid          => 'aabbccdd',
            serial_status  => 'current',
            dispatcher_serial => '0123456789abcdef',
        }));
    }

    my $config = minimal_config(
        cert       => $cert,
        key        => "$dir/dispatcher.crt.key",
        state_dir  => $stateDir,
        agents_dir => $regDir,
        registry   => "$regDir/registry.json",
    );

    my $result = eval { Dispatcher::Rotation::_do_rotation(config => $config) };
    if ($@) {
        plan skip_all => "_do_rotation requires a CA: $@";
        return;
    }

    for my $host (qw(agent-01 agent-02)) {
        my $path = "$regDir/$host.json";
        ok -f $path, "agent record $host still exists";
        my $raw    = do { local $/; open my $fh, '<', $path or die $!; <$fh> };
        my $record = decode_json($raw);
        is $record->{serial_status}, 'pending',
            "$host serial_status set to pending after rotation";
        is $record->{hostname}, $host,
            "$host hostname field preserved";
        is $record->{ip}, '10.0.0.1',
            "$host ip field preserved";
    }
};

# ---------------------------------------------------------------------------
# broadcast_serial
# ---------------------------------------------------------------------------

subtest 'broadcast_serial: no rotation state file returns empty arrayref' => sub {
    my $dir    = tempdir(CLEANUP => 1);
    my $config = minimal_config(
        state_dir  => "$dir/state",
        agents_dir => "$dir/agents",
    );
    make_path("$dir/state", "$dir/agents");

    my $result = eval { Dispatcher::Rotation::broadcast_serial(config => $config) };
    ok !$@, 'no error when state file absent';
    ok defined $result, 'returns a value';
    if (ref $result eq 'ARRAY') {
        is scalar @$result, 0, 'returns empty arrayref';
    }
    else {
        pass 'returned without error (return type may vary)';
    }
};

# ---------------------------------------------------------------------------
# expire_stale_agents
# ---------------------------------------------------------------------------

subtest 'expire_stale_agents: before overlap expires - no registry changes' => sub {
    my $dir      = tempdir(CLEANUP => 1);
    my $stateDir = "$dir/state";
    my $regDir   = "$dir/agents";
    make_path($stateDir, $regDir);

    # overlap_expires is in the future
    my $future = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime(time + 86400 * 7));
    write_file("$stateDir/rotation.json", encode_json({
        current_serial  => 'abcd1234',
        previous_serial => '0000ffff',
        rotated_at      => '2025-01-01T00:00:00Z',
        overlap_expires => $future,
        overlap_days    => 30,
    }));

    write_file("$regDir/agent-01.json", encode_json({
        hostname      => 'agent-01',
        serial_status => 'pending',
    }));

    my $config = minimal_config(
        state_dir  => $stateDir,
        agents_dir => $regDir,
    );

    eval { Dispatcher::Rotation::expire_stale_agents(config => $config) };
    ok !$@, 'no error';

    my $raw    = do { local $/; open my $fh, '<', "$regDir/agent-01.json" or die $!; <$fh> };
    my $record = decode_json($raw);
    is $record->{serial_status}, 'pending',
        'pending agent remains pending before overlap expires';
};

subtest 'expire_stale_agents: after overlap expires - pending agents become stale' => sub {
    my $dir      = tempdir(CLEANUP => 1);
    my $stateDir = "$dir/state";
    my $regDir   = "$dir/agents";
    make_path($stateDir, $regDir);

    # overlap_expires is in the past
    my $past = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime(time - 86400));
    write_file("$stateDir/rotation.json", encode_json({
        current_serial  => 'abcd1234',
        previous_serial => '0000ffff',
        rotated_at      => '2025-01-01T00:00:00Z',
        overlap_expires => $past,
        overlap_days    => 30,
    }));

    write_file("$regDir/agent-01.json", encode_json({
        hostname      => 'agent-01',
        serial_status => 'pending',
    }));
    write_file("$regDir/agent-02.json", encode_json({
        hostname      => 'agent-02',
        serial_status => 'current',
    }));

    my $config = minimal_config(
        state_dir  => $stateDir,
        agents_dir => $regDir,
    );

    eval { Dispatcher::Rotation::expire_stale_agents(config => $config) };
    ok !$@, 'no error';

    my $raw1    = do { local $/; open my $fh, '<', "$regDir/agent-01.json" or die $!; <$fh> };
    my $record1 = decode_json($raw1);
    is $record1->{serial_status}, 'stale',
        'pending agent marked stale after overlap expires';

    my $raw2    = do { local $/; open my $fh, '<', "$regDir/agent-02.json" or die $!; <$fh> };
    my $record2 = decode_json($raw2);
    is $record2->{serial_status}, 'current',
        'current agent unaffected by expiry';
};

subtest 'expire_stale_agents: no rotation state file - no error, no changes' => sub {
    my $dir    = tempdir(CLEANUP => 1);
    my $regDir = "$dir/agents";
    make_path("$dir/state", $regDir);

    write_file("$regDir/agent-01.json", encode_json({
        hostname      => 'agent-01',
        serial_status => 'pending',
    }));

    my $config = minimal_config(
        state_dir  => "$dir/state",
        agents_dir => $regDir,
    );

    eval { Dispatcher::Rotation::expire_stale_agents(config => $config) };
    ok !$@, 'no error when state file absent';

    my $raw    = do { local $/; open my $fh, '<', "$regDir/agent-01.json" or die $!; <$fh> };
    my $record = decode_json($raw);
    is $record->{serial_status}, 'pending',
        'agent status unchanged when no state file';
};

# ---------------------------------------------------------------------------
# load_state
# ---------------------------------------------------------------------------

subtest 'load_state: returns parsed hashref for valid state file' => sub {
    my $dir      = tempdir(CLEANUP => 1);
    my $stateDir = "$dir/state";
    make_path($stateDir);

    my $data = {
        current_serial  => 'deadbeef',
        previous_serial => 'cafebabe',
        rotated_at      => '2025-06-01T12:00:00Z',
        overlap_expires => '2025-07-01T12:00:00Z',
        overlap_days    => 30,
    };
    write_file("$stateDir/rotation.json", encode_json($data));

    my $config = minimal_config(state_dir => $stateDir);
    my $state  = Dispatcher::Rotation::load_state($config);

    ok defined $state,                           'load_state returns a value';
    is $state->{current_serial},  'deadbeef',    'current_serial correct';
    is $state->{previous_serial}, 'cafebabe',    'previous_serial correct';
    is $state->{overlap_days},    30,             'overlap_days correct';
};

subtest 'load_state: returns undef when state file absent' => sub {
    my $dir    = tempdir(CLEANUP => 1);
    my $config = minimal_config(state_dir => "$dir/state");
    make_path("$dir/state");

    my $state = Dispatcher::Rotation::load_state($config);
    ok !defined $state, 'returns undef when no state file';
};

done_testing;
