package Dispatcher::Agent::Runner;

use strict;
use warnings;
use JSON  qw(encode_json);
use POSIX qw(WIFEXITED WEXITSTATUS);


# Execute a script with no shell, capture stdout/stderr/exit.
# Pipes full request context as JSON to the script's stdin.
#
# Arguments:
#   $script_path  - absolute path to executable (caller does allowlist check)
#   $args         - arrayref of positional arguments (may be empty)
#   $context      - optional hashref piped as JSON to stdin
#                   Keys: script, args, reqid, peer_ip, username, token, timestamp
#                   If undef, stdin is closed immediately (empty).
#
# Returns hashref: { stdout => '', stderr => '', exit => N }
#   exit  0+    script exit code
#   exit  126   killed by signal or exec failed
#   exit  -1    fork or pipe failure (error in stderr)
sub run_script {
    my ($script_path, $args, $context) = @_;
    $args //= [];

    # Pipes for stdin (JSON context), stdout, and stderr
    pipe my $stdin_r,  my $stdin_w  or return _error("pipe(stdin): $!");
    pipe my $stdout_r, my $stdout_w or return _error("pipe(stdout): $!");
    pipe my $stderr_r, my $stderr_w or return _error("pipe(stderr): $!");

    my $pid = fork();
    return _error("fork failed: $!") unless defined $pid;

    if ($pid == 0) {
        # Child
        close $stdin_w;
        close $stdout_r;
        close $stderr_r;
        open STDIN,  '<&', $stdin_r  or POSIX::_exit(127);
        open STDOUT, '>&', $stdout_w or POSIX::_exit(127);
        open STDERR, '>&', $stderr_w or POSIX::_exit(127);
        close $stdin_r;
        close $stdout_w;
        close $stderr_w;

        # exec without shell - args passed as list
        exec { $script_path } $script_path, @$args
            or POSIX::_exit(127);
    }

    # Parent
    close $stdin_r;
    close $stdout_w;
    close $stderr_w;

    # Write context JSON to script stdin, then close to signal EOF
    if ($context) {
        print $stdin_w encode_json($context);
    }
    close $stdin_w;

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
