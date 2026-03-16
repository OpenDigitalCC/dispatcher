#!/usr/bin/perl
# t/reqid-entropy.t
#
# Tests for the /dev/urandom-based reqid generators introduced in Item 6.
#
# Exec::Engine::gen_reqid        - public, 16 hex chars
# Exec::Pairing::_gen_reqid      - private, 16 hex chars
#
# Tests:
#   - Output format: matches /^[0-9a-f]{16}$/
#   - No duplicates in 1000 calls
#   - No repeated prefixes in first 100 calls (structural bias check)

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

use Exec::Engine  qw();
use Exec::Pairing qw();
use Exec::Log     qw();

Exec::Log::init('test');

# Suppress any log output during tests
{
    no warnings 'redefine';
    *Exec::Log::log_action = sub {};
}

# ---------------------------------------------------------------------------
# gen_reqid (Engine)
# ---------------------------------------------------------------------------

subtest 'gen_reqid: output is 16 lowercase hex characters' => sub {
    for my $i (1..20) {
        my $id = Exec::Engine::gen_reqid();
        like $id, qr/^[0-9a-f]{16}$/, "call $i: '$id' matches /^[0-9a-f]{16}\$/";
    }
};

subtest 'gen_reqid: 1000 calls produce no duplicates' => sub {
    my %seen;
    my $collisions = 0;
    for my $i (1..1000) {
        my $id = Exec::Engine::gen_reqid();
        $collisions++ if exists $seen{$id};
        $seen{$id} = 1;
    }
    is $collisions, 0, 'no duplicate reqids in 1000 calls';
    is scalar keys %seen, 1000, '1000 distinct values generated';
};

subtest 'gen_reqid: no repeated 4-char prefixes in first 100 calls' => sub {
    my %prefixes;
    for my $i (1..100) {
        my $id     = Exec::Engine::gen_reqid();
        my $prefix = substr($id, 0, 4);
        $prefixes{$prefix}++;
    }
    # With 16-bit prefix space (65536 values) and 100 samples the probability
    # of any collision by chance is ~7% (birthday). Allow up to 3 collisions
    # before flagging structural bias; zero is expected but not required.
    my $max_prefix_count = (sort { $b <=> $a } values %prefixes)[0] // 0;
    cmp_ok $max_prefix_count, '<=', 3,
        'no prefix appears more than 3 times in 100 calls (no structural bias)';
};

subtest 'gen_reqid: successive calls differ' => sub {
    my $a = Exec::Engine::gen_reqid();
    my $b = Exec::Engine::gen_reqid();
    isnt $a, $b, 'two successive calls return different values';
};

# ---------------------------------------------------------------------------
# _gen_reqid (Pairing - private)
# ---------------------------------------------------------------------------

# Access the private function directly via its full package path.
# It is not exported, but it is callable as Exec::Pairing::_gen_reqid.

subtest '_gen_reqid: output is 16 lowercase hex characters' => sub {
    for my $i (1..20) {
        my $id = Exec::Pairing::_gen_reqid();
        like $id, qr/^[0-9a-f]{16}$/, "call $i: '$id' matches /^[0-9a-f]{16}\$/";
    }
};

subtest '_gen_reqid: 1000 calls produce no duplicates' => sub {
    my %seen;
    my $collisions = 0;
    for my $i (1..1000) {
        my $id = Exec::Pairing::_gen_reqid();
        $collisions++ if exists $seen{$id};
        $seen{$id} = 1;
    }
    is $collisions, 0, 'no duplicate reqids in 1000 calls';
    is scalar keys %seen, 1000, '1000 distinct values generated';
};

subtest '_gen_reqid: no repeated 4-char prefixes in first 100 calls' => sub {
    my %prefixes;
    for my $i (1..100) {
        my $id     = Exec::Pairing::_gen_reqid();
        my $prefix = substr($id, 0, 4);
        $prefixes{$prefix}++;
    }
    my $max_prefix_count = (sort { $b <=> $a } values %prefixes)[0] // 0;
    cmp_ok $max_prefix_count, '<=', 3,
        'no prefix appears more than 3 times in 100 calls (no structural bias)';
};

subtest '_gen_reqid: successive calls differ' => sub {
    my $a = Exec::Pairing::_gen_reqid();
    my $b = Exec::Pairing::_gen_reqid();
    isnt $a, $b, 'two successive calls return different values';
};

# ---------------------------------------------------------------------------
# Cross-generator: gen_reqid and _gen_reqid share no output
# ---------------------------------------------------------------------------

subtest 'gen_reqid and _gen_reqid outputs do not overlap (50 calls each)' => sub {
    my %engine_ids  = map { Exec::Engine::gen_reqid()  => 1 } 1..50;
    my %pairing_ids = map { Exec::Pairing::_gen_reqid() => 1 } 1..50;
    my @overlap = grep { exists $pairing_ids{$_} } keys %engine_ids;
    is scalar @overlap, 0,
        'no overlap between 50 Engine reqids and 50 Pairing reqids';
};

done_testing;
