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
}

# Load and parse scripts.conf allowlist
# Returns hashref: { script_name => /absolute/path }
# Dies on parse errors; unknown/bad entries are skipped with a warning
sub load_allowlist {
    my ($path) = @_;
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
sub validate_script {
    my ($name, $allowlist) = @_;
    return unless defined $name && $name =~ /^[\w-]+$/;
    return $allowlist->{$name};
}

1;
