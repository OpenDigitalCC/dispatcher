package Dispatcher::Engine;

use strict;
use warnings;
use JSON  qw(encode_json decode_json);
use Carp  qw(croak);
use POSIX qw(WNOHANG);

use Dispatcher::Log qw();
use Time::HiRes qw();
use Time::Piece qw();

our $VERSION = '0.1';

my $_reqid_counter = 0;

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
#   args    => \@script_args    (default [])
#   reqid   => $id              (generated if absent)
#   port    => $default_port    (default 7443)
#
# Returns arrayref of result hashrefs:
#   { host, script, exit, stdout, stderr, reqid, rtt }
#   { host, script, exit => -1, error, reqid, rtt }
sub dispatch_all {
    my (%opts) = @_;
    my $hosts  = $opts{hosts}  or croak "hosts required";
    my $script = $opts{script} or croak "script required";
    my $config = $opts{config} or croak "config required";
    my $args   = $opts{args}   // [];
    my $reqid  = $opts{reqid}  // gen_reqid();
    my $port   = $opts{port}   // $DEFAULT_PORT;

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
                host   => $host,
                port   => $hport,
                script => $script,
                args   => $args,
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

    # Check each successful ping for cert renewal need.
    # Renewal is triggered when remaining validity < half of cert_days.
    # Failure is logged but not propagated - ping result is unaffected.
    my $cert_days = $config->{cert_days} // 365;
    for my $result (@results) {
        next unless ($result->{status} // '') eq 'ok';
        next unless $result->{expiry};

        if (_renewal_due($result->{expiry}, $cert_days)) {
            my ($host, $hport) = parse_host($result->{host} // '', $port);
            eval {
                _renew_one(
                    host   => $host,
                    port   => $hport,
                    config => $config,
                    reqid  => gen_reqid(),
                );
            };
            if ($@) {
                chomp(my $err = $@);
                Dispatcher::Log::log_action('ERR', {
                    ACTION => 'renew',
                    TARGET => "$host:$hport",
                    ERROR  => $err,
                });
            }
        }
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

# Generate a unique request ID combining timestamp, PID, and per-process counter.
sub gen_reqid {
    my $t   = int(Time::HiRes::time() * 1000) & 0xffff;
    my $pid = $$ & 0xffff;
    my $seq = (++$_reqid_counter) & 0xffff;
    return sprintf '%04x%04x%04x', $t, $pid, $seq;
}

# --- private ---

sub _dispatch_one {
    my (%opts) = @_;
    my $host   = $opts{host};
    my $port   = $opts{port};
    my $config = $opts{config};
    my $reqid  = $opts{reqid};

    my $t0 = Time::HiRes::time();
    my $ua = _build_ua($config);

    my $payload = encode_json({
        script => $opts{script},
        args   => $opts{args} // [],
        reqid  => $reqid,
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

# Return true if the cert expiry date is within half the configured cert lifetime.
# Expiry is an OpenSSL notAfter string: "Jun  7 16:28:00 2028 GMT"
sub _renewal_due {
    my ($expiry_str, $cert_days) = @_;
    my $half_life_secs = (($cert_days // 365) / 2) * 86400;

    my $expiry_epoch = eval {
        local $ENV{TZ} = 'UTC';
        my $t = Time::Piece->strptime($expiry_str, '%b %d %H:%M:%S %Y %Z');
        $t->epoch;
    };
    return 0 unless defined $expiry_epoch;  # cannot parse - skip renewal

    my $remaining = $expiry_epoch - time();
    return $remaining < $half_life_secs;
}

# Perform cert renewal for one agent over mTLS on port 7443.
# POST /renew  -> receive CSR
# Sign CSR via CA
# POST /renew-complete -> deliver new cert+CA
# Update registry expiry
#
# Dies on any failure so the caller can log at ERR.
sub _renew_one {
    my (%opts) = @_;
    my $host   = $opts{host}   or croak "host required";
    my $port   = $opts{port}   or croak "port required";
    my $config = $opts{config} or croak "config required";
    my $reqid  = $opts{reqid}  // gen_reqid();

    require Dispatcher::CA;
    require Dispatcher::Registry;

    my $ua = _build_ua($config);

    Dispatcher::Log::log_action('INFO', {
        ACTION => 'renew',
        TARGET => "$host:$port",
        REQID  => $reqid,
        STATUS => 'starting',
    });

    # Step 1: request CSR from agent
    my $resp = $ua->post(
        "https://$host:$port/renew",
        'Content-Type' => 'application/json',
        Content        => encode_json({ reqid => $reqid }),
    );
    croak "POST /renew failed: " . $resp->status_line
        unless $resp && $resp->is_success;

    my $data = eval { decode_json($resp->content) }
        or croak "Invalid JSON from /renew";
    croak "/renew returned error: $data->{error}"
        if ($data->{status} // '') ne 'ok';
    croak "/renew returned no CSR"
        unless $data->{csr};

    # Step 2: sign the CSR
    my $cert_pem = Dispatcher::CA::sign_csr(
        csr_pem => $data->{csr},
        ca_dir  => $config->{ca_dir} // '/etc/dispatcher',
        days    => $config->{cert_days} // 365,
    );

    my $ca_pem = Dispatcher::CA::read_ca_cert(
        ca_dir => $config->{ca_dir} // '/etc/dispatcher',
    );

    # Step 3: deliver new cert to agent
    my $resp2 = $ua->post(
        "https://$host:$port/renew-complete",
        'Content-Type' => 'application/json',
        Content        => encode_json({
            status => 'ok',
            cert   => $cert_pem,
            ca     => $ca_pem,
            reqid  => $reqid,
        }),
    );
    croak "POST /renew-complete failed: " . $resp2->status_line
        unless $resp2 && $resp2->is_success;

    my $data2 = eval { decode_json($resp2->content) }
        or croak "Invalid JSON from /renew-complete";
    croak "/renew-complete returned error: $data2->{error}"
        if ($data2->{status} // '') ne 'ok';

    # Step 4: update registry expiry
    my $new_expiry = _extract_expiry($cert_pem);
    my $agent      = Dispatcher::Registry::get_agent(hostname => $host);
    if ($agent) {
        Dispatcher::Registry::register_agent(
            hostname => $agent->{hostname},
            ip       => $agent->{ip}     // '',
            paired   => $agent->{paired} // '',
            expiry   => $new_expiry      // '',
            reqid    => $agent->{reqid}  // '',
        );
    }

    Dispatcher::Log::log_action('INFO', {
        ACTION => 'renew-complete',
        TARGET => "$host:$port",
        REQID  => $reqid,
        EXPIRY => $new_expiry // '',
    });
}

# Extract cert expiry from a PEM string using openssl subprocess.
# Returns the notAfter string or undef on failure.
sub _extract_expiry {
    my ($cert_pem) = @_;
    require File::Temp;
    my ($fh, $path) = File::Temp::tempfile(SUFFIX => '.crt', UNLINK => 1);
    print $fh $cert_pem;
    close $fh;
    my $out = `openssl x509 -noout -enddate -in \Q$path\E 2>/dev/null`;
    return unless defined $out && $out =~ /notAfter=(.+)/;
    my $date = $1;
    chomp $date;
    return $date;
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
