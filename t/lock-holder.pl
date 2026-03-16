#!/usr/bin/perl
# Acquires a lock, signals "locked" to stdout, holds until stdin closes
use strict;
use Fcntl qw(LOCK_EX LOCK_NB);
use FindBin qw($Bin);
use lib "$Bin/../lib";
use Exec::Lock;
open STDERR, '>', '/dev/null';

my ($dir, $host, $script) = @ARGV;

my $result = Exec::Lock::acquire(
    hosts    => [$host],
    script   => $script,
    lock_dir => $dir,
);

if ($result->{ok}) {
    # Signal parent: lock held
    syswrite STDOUT, "locked\n";
    # Hold until parent closes our stdin
    <STDIN>;
    Exec::Lock::release(
        handles => $result->{handles},
        hosts   => [$host],
        script  => $script,
    );
    exit 0;
} else {
    syswrite STDOUT, "failed\n";
    exit 1;
}
