package Dispatcher::Engine;

use strict;
use warnings;
use JSON  qw(encode_json decode_json);
use Carp  qw(croak);
use POSIX qw(WNOHANG);

use Dispatcher::Log qw();


my $DEFAULT_PORT = 7443;

# Run a script on one or more hosts in parallel.
# Each host gets a forked child; results are collected via pipes.
#
# Required opts:
#   hosts   => \@host_strings   (may include host:port)
#   script  => $name
#   config  => \%config         (cert, key, ca, optional timeout)
#
# Optional opts:
#   args     => \@script_args   (default [])
#   reqid    => $id             (generated if absent)
#   port     => $default_port   (default 7443)
#   username => $str            (forwarded to agent for downstream use)
#   token    => $str            (forwarded to agent for downstream use)
#
# Returns arrayref of result hashrefs:
#   { host, script, exit, stdout, stderr, reqid, rtt }
#   { host, script, exit => -1, error, reqid, rtt }
sub dispatch_all {
    my (%opts) = @_;
    my $hosts    = $opts{hosts}    or croak "hosts required";
    my $script   = $opts{script}   or croak "script required";
    my $config   = $opts{config}   or croak "config required";
    my $args     = $opts{args}     // [];
    my $reqid    = $opts{reqid}    // gen_reqid();
    my $port     = $opts{port}     // $DEFAULT_PORT;
    my $username = $opts{username} // '';
    my $token    = $opts{token}    // '';

    croak "hosts must be an arrayref" unless ref $hosts eq 'ARRAY';
    croak "args must be an arrayref"  unless ref $args  eq 'ARRAY';

    Dispatcher::Log::log_action('INFO', {
        ACTION => 'dispatch',
        SCRIPT => $script,
        HOSTS  => join(',', @$hosts),
        REQID  => $reqid,
    });

    my @results;
    my %pipes;

    for my $host_str (@$hosts) {
        my ($host, $hport) = parse_host($host_str, $port);
        pipe my $r, my $w or die "pipe: $!";

        my $pid = fork();
        die "fork: $!" unless defined $pid;

        if ($pid == 0) {
            close $r;
            my $result = _dispatch_one(
                host     => $host,
                port     => $hport,
                script   => $script,
                args     => $args,
                reqid    => $reqid,
                config   => $config,
                username => $username,
                token    => $token,
            );
            print $w encode_json($result);
            close $w;
            exit 0;
        }

        close $w;
        $pipes{$pid} = { fh => $r, host => $host_str };
    }

    while (%pipes) {
        my $pid = waitpid -1, 0;
        last if $pid <= 0;
        next unless exists $pipes{$pid};

        my $fh   = $pipes{$pid}{fh};
        my $host = $pipes{$pid}{host};
        my $raw  = do { local $/; <$fh> };
        close $fh;

        my $result = eval { decode_json($raw) }
            // { host => $host, script => $script, exit => -1,
                 error => 'no response from child', reqid => $reqid };
        push @results, $result;
        delete $pipes{$pid};
    }

    return \@results;
}

# Ping one or more hosts in parallel.
#
# Required opts:
#   hosts   => \@host_strings
#   config  => \%config
#
# Optional opts:
#   reqid   => $id
#   port    => $default_port
#
# Returns arrayref of result hashrefs:
#   { host, status => 'ok', version, expiry, rtt, reqid }
#   { host, status => 'error', error, rtt }
sub ping_all {
    my (%opts) = @_;
    my $hosts  = $opts{hosts}  or croak "hosts required";
    my $config = $opts{config} or croak "config required";
    my $reqid  = $opts{reqid}  // gen_reqid();
    my $port   = $opts{port}   // $DEFAULT_PORT;

    croak "hosts must be an arrayref" unless ref $hosts eq 'ARRAY';

    my @results;
    my %pipes;

    for my $host_str (@$hosts) {
        my ($host, $hport) = parse_host($host_str, $port);
        pipe my $r, my $w or die "pipe: $!";

        my $pid = fork();
        die "fork: $!" unless defined $pid;

        if ($pid == 0) {
            close $r;
            my $result = _ping_one(
                host   => $host,
                port   => $hport,
                reqid  => $reqid,
                config => $config,
            );
            print $w encode_json($result);
            close $w;
            exit 0;
        }

        close $w;
        $pipes{$pid} = { fh => $r, host => $host_str };
    }

    while (%pipes) {
        my $pid = waitpid -1, 0;
        last if $pid <= 0;
        next unless exists $pipes{$pid};

        my $fh  = $pipes{$pid}{fh};
        my $raw = do { local $/; <$fh> };
        close $fh;

        my $result = eval { decode_json($raw) }
            // { host => $pipes{$pid}{host}, status => 'error',
                 error => 'no response from child' };
        push @results, $result;
        delete $pipes{$pid};
    }

    return \@results;
}

# Query one or more hosts for their capabilities (allowlisted scripts) in parallel.
#
# Required opts:
#   hosts   => \@host_strings
#   config  => \%config
#
# Optional opts:
#   port    => $default_port
#
# Returns arrayref of result hashrefs:
#   { host, status => 'ok', version, scripts => [{name, path, executable},...] }
#   { host, status => 'error', error }
sub capabilities_all {
    my (%opts) = @_;
    my $hosts  = $opts{hosts}  or croak "hosts required";
    my $config = $opts{config} or croak "config required";
    my $port   = $opts{port}   // $DEFAULT_PORT;

    croak "hosts must be an arrayref" unless ref $hosts eq 'ARRAY';

    my @results;
    my %pipes;

    for my $host_str (@$hosts) {
        my ($host, $hport) = parse_host($host_str, $port);
        pipe my $r, my $w or die "pipe: $!";

        my $pid = fork();
        die "fork: $!" unless defined $pid;

        if ($pid == 0) {
            close $r;
            my $result = _capabilities_one(
                host   => $host,
                port   => $hport,
                config => $config,
            );
            print $w encode_json($result);
            close $w;
            exit 0;
        }

        close $w;
        $pipes{$pid} = { fh => $r, host => $host_str };
    }

    while (%pipes) {
        my $pid = waitpid -1, 0;
        last if $pid <= 0;
        next unless exists $pipes{$pid};

        my $fh  = $pipes{$pid}{fh};
        my $raw = do { local $/; <$fh> };
        close $fh;

        my $result = eval { decode_json($raw) }
            // { host => $pipes{$pid}{host}, status => 'error',
                 error => 'no response from child' };
        push @results, $result;
        delete $pipes{$pid};
    }

    return \@results;
}

# Parse a host string into (host, port).
# Accepts "hostname" or "hostname:port".
sub parse_host {
    my ($host_str, $default_port) = @_;
    if ($host_str =~ /^(.+):(\d+)$/) {
        return ($1, $2);
    }
    return ($host_str, $default_port // $DEFAULT_PORT);
}

# Generate a random 8-hex-digit request ID.
sub gen_reqid {
    return sprintf '%08x', int(rand(0xffffffff));
}

# --- private ---

sub _dispatch_one {
    my (%opts) = @_;
    my $host   = $opts{host};
    my $port   = $opts{port};
    my $config = $opts{config};
    my $reqid  = $opts{reqid};

    require Time::HiRes;
    my $t0 = Time::HiRes::time();
    my $ua = _build_ua($config);

    my $payload = encode_json({
        script   => $opts{script},
        args     => $opts{args} // [],
        reqid    => $reqid,
        username => $opts{username} // '',
        token    => $opts{token}    // '',
    });

    my $resp = eval {
        $ua->post(
            "https://$host:$port/run",
            'Content-Type' => 'application/json',
            Content        => $payload,
        );
    };

    my $rtt = sprintf '%.0fms', (Time::HiRes::time() - $t0) * 1000;

    if ($@ || !$resp || !$resp->is_success) {
        my $err = $@ || ($resp ? $resp->status_line : 'no response');
        Dispatcher::Log::log_action('ERR', {
            ACTION => 'run',
            SCRIPT => $opts{script},
            TARGET => "$host:$port",
            ERROR  => $err,
            RTT    => $rtt,
            REQID  => $reqid,
        });
        return {
            host   => $host,
            script => $opts{script},
            exit   => -1,
            error  => $err,
            rtt    => $rtt,
            reqid  => $reqid,
        };
    }

    my $result = eval { decode_json($resp->content) }
        // { host => $host, exit => -1, error => 'invalid JSON response' };

    $result->{host}  //= $host;
    $result->{rtt}     = $rtt;
    $result->{reqid} //= $reqid;

    Dispatcher::Log::log_action('INFO', {
        ACTION => 'run',
        SCRIPT => $opts{script},
        TARGET => "$host:$port",
        EXIT   => $result->{exit},
        RTT    => $rtt,
        REQID  => $reqid,
    });

    return $result;
}

sub _ping_one {
    my (%opts) = @_;
    my $host   = $opts{host};
    my $port   = $opts{port};
    my $config = $opts{config};
    my $reqid  = $opts{reqid};

    require Time::HiRes;
    my $t0 = Time::HiRes::time();
    my $ua = _build_ua($config);

    my $resp = eval {
        $ua->post(
            "https://$host:$port/ping",
            'Content-Type' => 'application/json',
            Content        => encode_json({ reqid => $reqid }),
        );
    };

    my $rtt = sprintf '%.0fms', (Time::HiRes::time() - $t0) * 1000;

    if ($@ || !$resp || !$resp->is_success) {
        my $err = $@ || ($resp ? $resp->status_line : 'no response');
        Dispatcher::Log::log_action('ERR', {
            ACTION => 'ping',
            TARGET => "$host:$port",
            ERROR  => $err,
            RTT    => $rtt,
            REQID  => $reqid,
        });
        return { host => $host, status => 'error', error => $err, rtt => $rtt };
    }

    my $result = eval { decode_json($resp->content) }
        // { host => $host, status => 'error', error => 'invalid JSON' };

    $result->{rtt}  = $rtt;
    $result->{host} //= $host;

    Dispatcher::Log::log_action('INFO', {
        ACTION => 'ping',
        TARGET => "$host:$port",
        RESULT => 'ok',
        RTT    => $rtt,
        REQID  => $reqid,
    });

    return $result;
}

sub _capabilities_one {
    my (%opts) = @_;
    my $host   = $opts{host};
    my $port   = $opts{port};
    my $config = $opts{config};

    require Time::HiRes;
    my $t0 = Time::HiRes::time();
    my $ua = _build_ua($config);

    my $resp = eval {
        $ua->get("https://$host:$port/capabilities");
    };

    my $rtt = sprintf '%.0fms', (Time::HiRes::time() - $t0) * 1000;

    if ($@ || !$resp || !$resp->is_success) {
        my $err = $@ || ($resp ? $resp->status_line : 'no response');
        Dispatcher::Log::log_action('ERR', {
            ACTION => 'capabilities',
            TARGET => "$host:$port",
            ERROR  => $err,
            RTT    => $rtt,
        });
        return { host => $host, status => 'error', error => $err, rtt => $rtt };
    }

    my $result = eval { decode_json($resp->content) }
        // { host => $host, status => 'error', error => 'invalid JSON' };

    $result->{rtt}  = $rtt;
    $result->{host} //= $host;

    Dispatcher::Log::log_action('INFO', {
        ACTION  => 'capabilities',
        TARGET  => "$host:$port",
        SCRIPTS => scalar @{ $result->{scripts} // [] },
        RTT     => $rtt,
    });

    return $result;
}

sub _build_ua {
    my ($config) = @_;
    require LWP::UserAgent;

    my $ua = LWP::UserAgent->new(
        ssl_opts => {
            SSL_cert_file   => $config->{cert},
            SSL_key_file    => $config->{key},
            SSL_ca_file     => $config->{ca},
            SSL_verify_mode => 0x01,
            verify_hostname => 0,   # verified by CA, not hostname
        },
        timeout => $config->{timeout} // 60,
    );
    return $ua;
}

1;
