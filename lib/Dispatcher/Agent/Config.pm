package Dispatcher::Agent::Config;

use strict;
use warnings;
use Carp qw(croak);

our $VERSION = '0.1';

# Load and validate agent.conf
# Returns hashref of config values or dies with error
sub load_config {
    my ($path) = @_;
    $path //= '/etc/dispatcher-agent/agent.conf';

    open my $fh, '<', $path
        or croak "Cannot open config '$path': $!";

    my %config;
    my $section = '';   # current section name; '' means top-level

    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*#/;   # skip comments
        next if $line =~ /^\s*$/;   # skip blank lines

        if ($line =~ /^\s*\[(\w+)\]\s*$/) {
            $section = lc $1;
            next;
        }

        if ($line =~ /^\s*(\w+[\w-]*)\s*=\s*(.+?)\s*$/) {
            my ($k, $v) = ($1, $2);
            if ($section eq 'tags') {
                $config{tags}{$k} = $v;
            }
            elsif ($section eq '') {
                $config{$k} = $v;
            }
            # silently ignore keys in unrecognised sections
        }
        else {
            croak "Malformed config line in '$path': $line";
        }
    }
    close $fh;

    _validate_config(\%config, $path);
    return \%config;
}

sub _validate_config {
    my ($config, $path) = @_;
    my @required = qw(port cert key ca);
    for my $key (@required) {
        croak "Missing required config key '$key' in '$path'"
            unless exists $config->{$key};
    }
    croak "port must be numeric in '$path'"
        unless $config->{port} =~ /^\d+$/;

    # Parse script_dirs from colon-separated string into arrayref
    if (defined $config->{script_dirs} && length $config->{script_dirs}) {
        $config->{script_dirs} = [
            grep { length $_ } split /:/, $config->{script_dirs}
        ];
    }
    else {
        delete $config->{script_dirs};   # absent = no restriction
    }
}

# Load and parse scripts.conf allowlist
# Returns hashref: { script_name => /absolute/path }
# Dies on parse errors; unknown/bad entries are skipped with a warning
#
# Optional opts:
#   script_dirs => \@dirs   (arrayref of approved directories; undef = no restriction)
sub load_allowlist {
    my ($path, $script_dirs) = @_;
    $path //= '/etc/dispatcher-agent/scripts.conf';

    open my $fh, '<', $path
        or croak "Cannot open allowlist '$path': $!";

    my %allowlist;
    while (my $line = <$fh>) {
        chomp $line;
        next if $line =~ /^\s*#/;
        next if $line =~ /^\s*$/;
        if ($line =~ /^\s*([\w-]+)\s*=\s*(\S+)\s*$/) {
            my ($name, $script_path) = ($1, $2);
            unless ($script_path =~ m{^/}) {
                warn "Allowlist: skipping '$name' - path must be absolute: $script_path\n";
                next;
            }
            if ($script_dirs && !_path_in_dirs($script_path, $script_dirs)) {
                warn "Allowlist: skipping '$name' - path not in approved script_dirs: $script_path\n";
                next;
            }
            $allowlist{$name} = $script_path;
        }
        else {
            warn "Allowlist: skipping malformed line: $line\n";
        }
    }
    close $fh;

    return \%allowlist;
}

# Check whether a script name is permitted
# Returns the script path if permitted, undef otherwise
#
# Optional: script_dirs => \@dirs  re-validates path at execution time
sub validate_script {
    my ($name, $allowlist, $script_dirs) = @_;
    return unless defined $name && $name =~ /^[\w-]+$/;
    my $path = $allowlist->{$name};
    return unless defined $path;
    if ($script_dirs && !_path_in_dirs($path, $script_dirs)) {
        warn "validate_script: '$name' path rejected at execution time - not in script_dirs: $path\n";
        return;
    }
    return $path;
}

# Return true if $path is under any directory in @$dirs.
# Uses string prefix matching after normalising trailing slashes.
sub _path_in_dirs {
    my ($path, $dirs) = @_;
    for my $dir (@$dirs) {
        $dir =~ s{/+$}{};   # strip trailing slash
        return 1 if index($path, "$dir/") == 0;
    }
    return 0;
}

1;
