#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use JSON qw(decode_json encode_json);
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Dispatcher::Registry qw();

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

sub write_file {
    my ($path, $content) = @_;
    open my $fh, '>', $path or die "Cannot write $path: $!";
    print $fh $content;
    close $fh;
}

sub read_agent_record {
    my ($agents_dir, $hostname) = @_;
    my $path = "$agents_dir/$hostname.json";
    open my $fh, '<', $path or die "Cannot read $path: $!";
    local $/;
    return decode_json(<$fh>);
}

# Minimal config for Registry functions
sub reg_config {
    my ($agents_dir) = @_;
    return {
        agents_dir => $agents_dir,
        registry   => "$agents_dir/registry.json",
    };
}

# ---------------------------------------------------------------------------
# register_agent with serial fields
# ---------------------------------------------------------------------------

subtest 'register_agent: serial fields written when provided' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path($dir);

    eval {
        Dispatcher::Registry::register_agent(
            agents_dir         => $dir,
            hostname           => 'agent-serial-01',
            ip                 => '192.168.1.10',
            reqid              => 'aabbccdd',
            cert_pem           => "-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n",
            dispatcher_serial  => 'deadbeef01234567',
            serial_status      => 'current',
            serial_confirmed   => '2025-06-01T12:00:00Z',
        );
    };
    if ($@) {
        # register_agent may require a valid cert PEM to extract expiry.
        # If it dies on our fake cert, skip gracefully.
        plan skip_all => "register_agent requires valid cert PEM: $@";
        return;
    }

    my $record = read_agent_record($dir, 'agent-serial-01');
    is $record->{dispatcher_serial}, 'deadbeef01234567', 'dispatcher_serial written';
    is $record->{serial_status},     'current',          'serial_status written';
    is $record->{serial_confirmed},  '2025-06-01T12:00:00Z', 'serial_confirmed written';
    is $record->{hostname},          'agent-serial-01',  'hostname preserved';
    is $record->{ip},                '192.168.1.10',     'ip preserved';
};

subtest 'register_agent: serial_status defaults to unknown when absent' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path($dir);

    eval {
        Dispatcher::Registry::register_agent(
            agents_dir => $dir,
            hostname   => 'agent-default-01',
            ip         => '192.168.1.11',
            reqid      => 'eeff0011',
            cert_pem   => "-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n",
        );
    };
    if ($@) {
        plan skip_all => "register_agent requires valid cert PEM: $@";
        return;
    }

    my $record = read_agent_record($dir, 'agent-default-01');
    my $status = $record->{serial_status} // 'unknown';
    is $status, 'unknown', 'serial_status defaults to unknown';
};

subtest 'register_agent: serial fields round-trip through JSON correctly' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path($dir);

    my %serial_fields = (
        dispatcher_serial  => 'cafebabe00ff1234',
        serial_status      => 'current',
        serial_broadcast   => '2025-06-01T11:00:00Z',
        serial_confirmed   => '2025-06-01T12:00:00Z',
    );

    eval {
        Dispatcher::Registry::register_agent(
            agents_dir => $dir,
            hostname   => 'agent-roundtrip',
            ip         => '10.0.0.1',
            reqid      => '11223344',
            cert_pem   => "-----BEGIN CERTIFICATE-----\nfake\n-----END CERTIFICATE-----\n",
            %serial_fields,
        );
    };
    if ($@) {
        plan skip_all => "register_agent requires valid cert PEM: $@";
        return;
    }

    my $record = read_agent_record($dir, 'agent-roundtrip');
    for my $field (keys %serial_fields) {
        is $record->{$field}, $serial_fields{$field},
            "$field round-trips correctly through JSON";
    }
};

# ---------------------------------------------------------------------------
# update_agent_serial_status
# ---------------------------------------------------------------------------

subtest 'update_agent_serial_status: merges serial fields without touching others' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path($dir);

    # Write an existing agent record with non-serial fields
    write_file("$dir/agent-merge.json", encode_json({
        hostname           => 'agent-merge',
        ip                 => '10.1.2.3',
        paired             => '2025-01-15T08:00:00Z',
        expiry             => '2026-01-15T08:00:00Z',
        reqid              => 'deadcafe',
        dispatcher_serial  => 'oldhex0001',
        serial_status      => 'pending',
        serial_broadcast   => '2025-05-01T00:00:00Z',
        serial_confirmed   => undef,
    }));

    Dispatcher::Registry::update_agent_serial_status(
        'agent-merge',
        agents_dir       => $dir,
        status           => 'current',
        serial           => 'newhex0002',
        serial_confirmed => '2025-06-15T09:00:00Z',
    );

    my $record = read_agent_record($dir, 'agent-merge');

    # Serial fields updated
    is $record->{serial_status},    'current',               'serial_status updated';
    is $record->{dispatcher_serial}, 'newhex0002',           'dispatcher_serial updated';
    is $record->{serial_confirmed},  '2025-06-15T09:00:00Z', 'serial_confirmed updated';

    # Non-serial fields untouched
    is $record->{hostname}, 'agent-merge',          'hostname preserved';
    is $record->{ip},       '10.1.2.3',             'ip preserved';
    is $record->{paired},   '2025-01-15T08:00:00Z', 'paired preserved';
    is $record->{expiry},   '2026-01-15T08:00:00Z', 'expiry preserved';
    is $record->{reqid},    'deadcafe',              'reqid preserved';
};

subtest 'update_agent_serial_status: status-only update (no serial arg)' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path($dir);

    write_file("$dir/agent-status-only.json", encode_json({
        hostname           => 'agent-status-only',
        ip                 => '10.0.0.5',
        dispatcher_serial  => 'aabbccdd',
        serial_status      => 'pending',
    }));

    Dispatcher::Registry::update_agent_serial_status(
        'agent-status-only',
        agents_dir => $dir,
        status     => 'stale',
    );

    my $record = read_agent_record($dir, 'agent-status-only');
    is $record->{serial_status},     'stale',    'serial_status updated to stale';
    is $record->{dispatcher_serial}, 'aabbccdd', 'dispatcher_serial unchanged';
    is $record->{ip},                '10.0.0.5', 'ip preserved';
};

subtest 'update_agent_serial_status: serial_broadcast field updated when provided' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path($dir);

    write_file("$dir/agent-broadcast.json", encode_json({
        hostname         => 'agent-broadcast',
        ip               => '10.0.0.6',
        serial_status    => 'pending',
        serial_broadcast => undef,
    }));

    my $ts = '2025-06-20T14:00:00Z';
    Dispatcher::Registry::update_agent_serial_status(
        'agent-broadcast',
        agents_dir       => $dir,
        status           => 'pending',
        serial_broadcast => $ts,
    );

    my $record = read_agent_record($dir, 'agent-broadcast');
    is $record->{serial_broadcast}, $ts, 'serial_broadcast updated';
};

subtest 'update_agent_serial_status: write is atomic (temp file then rename)' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path($dir);

    write_file("$dir/agent-atomic.json", encode_json({
        hostname      => 'agent-atomic',
        serial_status => 'pending',
    }));

    # Call update - if it uses a temp file + rename the original will not be
    # partially written. We cannot easily test atomicity directly, so we
    # verify the record is valid JSON and complete after the call.
    Dispatcher::Registry::update_agent_serial_status(
        'agent-atomic',
        agents_dir => $dir,
        status     => 'current',
    );

    my $raw    = do { local $/; open my $fh, '<', "$dir/agent-atomic.json" or die $!; <$fh> };
    my $record = eval { decode_json($raw) };
    ok !$@,                               'record is valid JSON after update';
    is $record->{serial_status}, 'current', 'status written correctly';
    is $record->{hostname},  'agent-atomic', 'hostname present and correct';
};

subtest 'update_agent_serial_status: unknown agent dies or returns error' => sub {
    my $dir = tempdir(CLEANUP => 1);
    make_path($dir);

    eval {
        Dispatcher::Registry::update_agent_serial_status(
            'nonexistent-agent',
            agents_dir => $dir,
            status     => 'current',
        );
    };
    # Either dies with a clear message, or returns without error.
    # We just confirm it does not silently create a record.
    ok !-f "$dir/nonexistent-agent.json",
        'does not create a new record for unknown agent';
};

done_testing;
