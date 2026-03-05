#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Dispatcher::Agent::Pairing qw();

# Skip all if openssl not available
unless (system('openssl version >/dev/null 2>&1') == 0) {
    plan skip_all => 'openssl not available';
}

subtest 'generate_key_and_csr: returns key and CSR PEM' => sub {
    my $result = eval {
        Dispatcher::Agent::Pairing::generate_key_and_csr(hostname => 'test-host.example.com')
    };
    ok !$@, "no error: $@";
    like $result->{key_pem}, qr/-----BEGIN.*PRIVATE KEY-----/, 'key is PEM';
    like $result->{csr_pem}, qr/-----BEGIN CERTIFICATE REQUEST-----/, 'CSR is PEM';
};

subtest 'generate_key_and_csr: CSR contains hostname as CN' => sub {
    my $result = Dispatcher::Agent::Pairing::generate_key_and_csr(
        hostname => 'prod-dns-01'
    );
    # Verify CSR CN using openssl
    my $text = `echo '$result->{csr_pem}' | openssl req -noout -subject 2>/dev/null`;
    like $text, qr/prod-dns-01/, 'hostname in CSR CN';
};

subtest 'generate_key_and_csr: missing hostname dies' => sub {
    eval { Dispatcher::Agent::Pairing::generate_key_and_csr() };
    like $@, qr/hostname required/, 'dies without hostname';
};

subtest 'store_certs: writes all three files' => sub {
    my $dir = tempdir(CLEANUP => 1);

    Dispatcher::Agent::Pairing::store_certs(
        cert_pem => "FAKE CERT\n",
        ca_pem   => "FAKE CA\n",
        key_pem  => "FAKE KEY\n",
        cert_dir => $dir,
    );

    ok -f "$dir/agent.crt", 'agent.crt written';
    ok -f "$dir/agent.key", 'agent.key written';
    ok -f "$dir/ca.crt",    'ca.crt written';
};

subtest 'store_certs: key file is mode 0600' => sub {
    my $dir = tempdir(CLEANUP => 1);
    Dispatcher::Agent::Pairing::store_certs(
        cert_pem => "CERT\n",
        ca_pem   => "CA\n",
        key_pem  => "KEY\n",
        cert_dir => $dir,
    );
    my $mode = (stat "$dir/agent.key")[2] & 07777;
    is $mode, 0600, 'key is mode 0600';
};

subtest 'store_certs: cert content correct' => sub {
    my $dir = tempdir(CLEANUP => 1);
    Dispatcher::Agent::Pairing::store_certs(
        cert_pem => "MY CERT DATA\n",
        ca_pem   => "MY CA DATA\n",
        key_pem  => "MY KEY DATA\n",
        cert_dir => $dir,
    );
    open my $fh, '<', "$dir/agent.crt" or die $!;
    my $content = do { local $/; <$fh> };
    is $content, "MY CERT DATA\n", 'cert content preserved';
};

subtest 'store_certs: missing required arg dies' => sub {
    eval { Dispatcher::Agent::Pairing::store_certs(cert_pem => 'x', ca_pem => 'y') };
    like $@, qr/key_pem required/, 'dies on missing key_pem';
};

subtest 'pairing_status: not paired when files missing' => sub {
    my $dir = tempdir(CLEANUP => 1);
    my $status = Dispatcher::Agent::Pairing::pairing_status(cert_dir => $dir);
    is $status->{paired}, 0, 'not paired';
    like $status->{reason}, qr/missing file/, 'reason given';
};

subtest 'pairing_status: paired when all files present and valid cert' => sub {
    my $dir = tempdir(CLEANUP => 1);

    # Generate a real self-signed cert for testing expiry parsing
    system(
        'openssl', 'req', '-x509', '-newkey', 'rsa:2048',
        '-keyout', "$dir/agent.key",
        '-out',    "$dir/agent.crt",
        '-days',   '365',
        '-nodes',
        '-subj',   '/CN=test',
    ) == 0 or plan skip_all => 'openssl cert generation failed';

    open my $fh, '>', "$dir/ca.crt" or die $!;
    print $fh "placeholder\n";
    close $fh;

    my $status = Dispatcher::Agent::Pairing::pairing_status(cert_dir => $dir);
    is $status->{paired}, 1, 'paired';
    ok defined $status->{expiry}, 'expiry present';
};

done_testing;
