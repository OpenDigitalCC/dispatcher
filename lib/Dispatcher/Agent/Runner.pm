package Dispatcher::Agent::Runner;

use strict;
use warnings;
use POSIX qw(WIFEXITED WEXITSTATUS);

our $VERSION = '0.1';

# Execute a script with no shell, capture stdout/stderr/exit
# Returns hashref: { stdout => '', stderr => '', exit => N }
# script_path must be an absolute path (caller is responsible for allowlist check)
# args is an arrayref (may be empty)
sub run_script {
    my ($script_path, $args) = @_;
    $args //= [];

    # Pipes for stdout and stderr
    pipe my $stdout_r, my $stdout_w or return _error("pipe(stdout): $!");
    pipe my $stderr_r, my $stderr_w or return _error("pipe(stderr): $!");

    my $pid = fork();
    return _error("fork failed: $!") unless defined $pid;

    if ($pid == 0) {
        # Child
        close $stdout_r;
        close $stderr_r;
        open STDOUT, '>&', $stdout_w or POSIX::_exit(127);
        open STDERR, '>&', $stderr_w or POSIX::_exit(127);
        close $stdout_w;
        close $stderr_w;

        # exec without shell - args passed as list
        exec { $script_path } $script_path, @$args
            or POSIX::_exit(127);
    }

    # Parent
    close $stdout_w;
    close $stderr_w;

    my $stdout = _slurp($stdout_r);
    my $stderr = _slurp($stderr_r);
    close $stdout_r;
    close $stderr_r;

    waitpid $pid, 0;
    my $exit = WIFEXITED($?) ? WEXITSTATUS($?) : 126;

    return {
        stdout => $stdout,
        stderr => $stderr,
        exit   => $exit,
    };
}

sub _slurp {
    my ($fh) = @_;
    local $/;
    return scalar <$fh> // '';
}

sub _error {
    my ($msg) = @_;
    return { stdout => '', stderr => $msg, exit => -1 };
}

1;
