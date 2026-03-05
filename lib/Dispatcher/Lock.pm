package Dispatcher::Lock;

use strict;
use warnings;
use Fcntl  qw(LOCK_EX LOCK_NB);
use File::Path qw(make_path);
use Carp   qw(croak);

use Dispatcher::Log qw();

our $VERSION = '0.1';

my $LOCK_DIR = '/var/lib/dispatcher/locks';

# Check whether all host:script pairs are available to lock.
# Does NOT acquire locks - only tests availability.
# Use this before forking so the parent can reject early.
#
# Required opts:
#   hosts  => \@hosts
#   script => $name
#
# Optional opts:
#   lock_dir => $path   (default /var/lib/dispatcher/locks)
#
# Returns:
#   { ok => 1 }
#   { ok => 0, conflicts => \@locked_pairs }
sub check_available {
    my (%opts) = @_;
    my $hosts   = $opts{hosts}   or croak "hosts required";
    my $script  = $opts{script}  or croak "script required";
    my $dir     = $opts{lock_dir} // $LOCK_DIR;

    croak "hosts must be an arrayref" unless ref $hosts eq 'ARRAY';

    _ensure_dir($dir);

    my @conflicts;

    for my $host (@$hosts) {
        my $path = _lock_path($dir, $host, $script);
        my $fh   = _open_lock_file($path);

        # Non-blocking attempt - if we can't get it, it's held
        unless (flock $fh, LOCK_EX | LOCK_NB) {
            push @conflicts, "$host:$script";
        }
        # We don't hold the lock - release immediately
        flock $fh, 8;   # LOCK_UN = 8
        close $fh;
    }

    return @conflicts
        ? { ok => 0, conflicts => \@conflicts }
        : { ok => 1 };
}

# Acquire locks for all host:script pairs.
# Call this in the child process after forking, once check_available has
# confirmed all pairs are free in the parent.
#
# There is a small TOCTOU window between check_available and acquire - if
# another request sneaks in between, acquire will detect the conflict and
# return it. The caller should treat this as a lock error.
#
# Required opts:
#   hosts    => \@hosts
#   script   => $name
#
# Optional opts:
#   lock_dir => $path
#
# Returns:
#   { ok => 1,  handles => \@fh_list }   - locks held; keep handles in scope
#   { ok => 0,  conflicts => \@pairs }   - could not acquire all locks
sub acquire {
    my (%opts) = @_;
    my $hosts   = $opts{hosts}   or croak "hosts required";
    my $script  = $opts{script}  or croak "script required";
    my $dir     = $opts{lock_dir} // $LOCK_DIR;

    croak "hosts must be an arrayref" unless ref $hosts eq 'ARRAY';

    _ensure_dir($dir);

    my @handles;
    my @conflicts;

    for my $host (@$hosts) {
        my $path = _lock_path($dir, $host, $script);
        my $fh   = _open_lock_file($path);

        if (flock $fh, LOCK_EX | LOCK_NB) {
            push @handles, $fh;
            Dispatcher::Log::log_action('INFO', {
                ACTION => 'lock-acquire',
                HOST   => $host,
                SCRIPT => $script,
            });
        }
        else {
            push @conflicts, "$host:$script";
        }
    }

    if (@conflicts) {
        # Release any we did acquire before failing
        for my $fh (@handles) {
            flock $fh, 8;
            close $fh;
        }
        Dispatcher::Log::log_action('WARNING', {
            ACTION    => 'lock-conflict',
            CONFLICTS => join(',', @conflicts),
        });
        return { ok => 0, conflicts => \@conflicts };
    }

    return { ok => 1, handles => \@handles };
}

# Release all locks acquired by acquire().
# Closing the filehandles releases the flocks automatically, but this
# function makes the intent explicit and logs the release.
#
# Required opts:
#   handles => \@fh_list   (from acquire result)
#   hosts   => \@hosts     (for logging only)
#   script  => $name       (for logging only)
sub release {
    my (%opts) = @_;
    my $handles = $opts{handles} or croak "handles required";
    my $hosts   = $opts{hosts}   // [];
    my $script  = $opts{script}  // '';

    croak "handles must be an arrayref" unless ref $handles eq 'ARRAY';

    for my $fh (@$handles) {
        flock $fh, 8;   # LOCK_UN
        close $fh;
    }

    Dispatcher::Log::log_action('INFO', {
        ACTION => 'lock-release',
        HOSTS  => join(',', @$hosts),
        SCRIPT => $script,
    }) if @$hosts;
}

# --- private ---

sub _lock_path {
    my ($dir, $host, $script) = @_;
    # Sanitise host and script for use in filename
    # Replace anything that isn't alphanumeric, hyphen, or dot with _
    (my $safe_host   = $host)   =~ s/[^\w.\-]/_/g;
    (my $safe_script = $script) =~ s/[^\w.\-]/_/g;
    return "$dir/${safe_host}--${safe_script}.lock";
}

sub _open_lock_file {
    my ($path) = @_;
    open my $fh, '>>', $path
        or croak "Cannot open lock file '$path': $!";
    return $fh;
}

sub _ensure_dir {
    my ($dir) = @_;
    make_path($dir) unless -d $dir;
}

1;
