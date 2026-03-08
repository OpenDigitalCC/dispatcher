package Dispatcher::API;

use strict;
use warnings;
use JSON       qw(encode_json decode_json);
use File::Path qw(make_path);
use POSIX      qw(WNOHANG);
use Carp       qw(croak);

use Dispatcher::Log      qw();
use Dispatcher::Engine   qw();
use Dispatcher::Auth     qw();
use Dispatcher::Lock     qw();
use Dispatcher::Registry qw();


# Start the API server. Blocks until SIGTERM or SIGINT.
#
# Required opts:
#   config => \%config    (cert, key, ca, and optional api_port, api_cert, api_key)
#
# The server listens on api_port (default 7445).
# TLS is enabled if api_cert and api_key are both present in config.
# Plain HTTP is used otherwise.
sub run {
    my (%opts) = @_;
    my $config = $opts{config} or croak "config required";

    my $port     = $config->{api_port} // 7445;
    my $api_cert = $config->{api_cert} // '';
    my $api_key  = $config->{api_key}  // '';
    my $use_tls  = ($api_cert && $api_key && -f $api_cert && -f $api_key);

    my $server = _make_server($port, $use_tls, $api_cert, $api_key);

    Dispatcher::Log::log_action('INFO', {
        ACTION   => 'api-start',
        PORT     => $port,
        TLS      => ($use_tls ? 'yes' : 'no'),
    });

    print "Dispatcher API listening on port $port"
        . ($use_tls ? " (TLS)" : " (plain HTTP)") . "\n";

    $SIG{INT} = $SIG{TERM} = sub {
        Dispatcher::Log::log_action('INFO', { ACTION => 'api-stop' });
        print "\nAPI server stopped.\n";
        exit 0;
    };

    # Reap children as they finish
    $SIG{CHLD} = sub {
        while (waitpid(-1, WNOHANG) > 0) {}
    };

    while (1) {
        my $conn = $server->accept or next;
        my $peer = $use_tls ? $conn->peerhost : $conn->peerhost;
        $peer //= 'unknown';

        my $pid = fork();
        unless (defined $pid) {
            warn "fork failed: $!\n";
            _send_error($conn, 500, 'server error', 'fork failed');
            $conn->close;
            next;
        }

        if ($pid == 0) {
            # Child: handle request and exit
            $server->close;
            _handle_connection($conn, $peer, $config);
            if ($use_tls) {
                $conn->close(SSL_no_shutdown => 1);
            } else {
                $conn->close;
            }
            exit 0;
        }

        # Parent: release our copy of the connection
        if ($use_tls) {
            $conn->close(SSL_no_shutdown => 1);
        } else {
            $conn->close;
        }
    }
}

# --- private ---

sub _make_server {
    my ($port, $use_tls, $cert, $key) = @_;

    if ($use_tls) {
        require IO::Socket::SSL;
        my $srv = IO::Socket::SSL->new(
            LocalPort       => $port,
            Listen          => 10,
            ReuseAddr       => 1,
            SSL_cert_file   => $cert,
            SSL_key_file    => $key,
            SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
        ) or die "Cannot start TLS API server on port $port: "
               . "$IO::Socket::SSL::SSL_ERROR\n";
        return $srv;
    }
    else {
        require IO::Socket::INET;
        my $srv = IO::Socket::INET->new(
            LocalPort => $port,
            Listen    => 10,
            ReuseAddr => 1,
            Proto     => 'tcp',
        ) or die "Cannot start API server on port $port: $!\n";
        return $srv;
    }
}

sub _handle_connection {
    my ($conn, $peer, $config) = @_;

    # Read request line
    my $request_line = <$conn>;
    unless ($request_line) {
        _send_error($conn, 400, 'bad request', 'empty request');
        return;
    }
    chomp $request_line;
    $request_line =~ s/\r$//;

    my ($method, $path) = split ' ', $request_line;
    $method = uc($method // '');
    $path   = $path // '/';

    # Read headers
    my $content_length = 0;
    while (my $line = <$conn>) {
        $line =~ s/\r?\n$//;
        last if $line eq '';
        if ($line =~ /^Content-Length:\s*(\d+)/i) {
            $content_length = $1;
        }
    }

    # Read body
    my $body = '';
    if ($content_length > 0) {
        read $conn, $body, $content_length;
    }

    Dispatcher::Log::log_action('INFO', {
        ACTION => 'api-request',
        METHOD => $method,
        PATH   => $path,
        PEER   => $peer,
        LEN    => $content_length,
    });

    # Route
    if ($path eq '/' && $method eq 'GET') {
        _handle_index($conn, $config);
    }
    elsif ($path eq '/openapi.json' && $method eq 'GET') {
        _handle_openapi($conn, $config);
    }
    elsif ($path eq '/openapi-live.json' && $method eq 'GET') {
        _handle_openapi_live($conn, $peer, $config);
    }
    elsif ($path eq '/health' && $method eq 'GET') {
        _handle_health($conn);
    }
    elsif ($path eq '/ping' && $method eq 'POST') {
        _handle_ping($conn, $peer, $body, $config);
    }
    elsif ($path eq '/run' && $method eq 'POST') {
        _handle_run($conn, $peer, $body, $config);
    }
    elsif ($path eq '/discovery' && $method =~ /^(GET|POST)$/) {
        _handle_discovery($conn, $peer, $body, $config);
    }
    else {
        _send_error($conn, 404, 'not found', "no route for $method $path");
    }
}

sub _handle_health {
    my ($conn) = @_;
    _send_json($conn, 200, { ok => JSON::true, version => $VERSION });
}

sub _handle_ping {
    my ($conn, $peer, $body, $config) = @_;

    my $req = _parse_body($conn, $body) or return;

    my $hosts = $req->{hosts};
    unless (ref $hosts eq 'ARRAY' && @$hosts) {
        _send_error($conn, 400, 'bad request', 'hosts must be a non-empty array');
        return;
    }

    my $username = $req->{username} // '';
    my $token    = $req->{token}    // '';

    my $auth = Dispatcher::Auth::check(
        action    => 'ping',
        hosts     => $hosts,
        username  => $username,
        token     => $token,
        source_ip => $peer,
        config    => $config,
    );
    unless ($auth->{ok}) {
        _send_json($conn, 403, {
            ok    => JSON::false,
            error => $auth->{reason},
            code  => $auth->{code},
        });
        return;
    }

    my $results = Dispatcher::Engine::ping_all(
        hosts  => $hosts,
        config => $config,
    );

    _send_json($conn, 200, { ok => JSON::true, results => $results });
}

sub _handle_run {
    my ($conn, $peer, $body, $config) = @_;

    my $req = _parse_body($conn, $body) or return;

    my $hosts  = $req->{hosts};
    my $script = $req->{script};
    my $args   = $req->{args} // [];

    unless (ref $hosts eq 'ARRAY' && @$hosts) {
        _send_error($conn, 400, 'bad request', 'hosts must be a non-empty array');
        return;
    }
    unless ($script && $script =~ /^[\w-]+$/) {
        _send_error($conn, 400, 'bad request', 'script name required (alphanumeric and hyphens only)');
        return;
    }
    unless (ref $args eq 'ARRAY') {
        _send_error($conn, 400, 'bad request', 'args must be an array');
        return;
    }

    my $username = $req->{username} // '';
    my $token    = $req->{token}    // '';

    my $auth = Dispatcher::Auth::check(
        action    => 'run',
        script    => $script,
        hosts     => $hosts,
        args      => $args,
        username  => $username,
        token     => $token,
        source_ip => $peer,
        config    => $config,
    );
    unless ($auth->{ok}) {
        _send_json($conn, 403, {
            ok    => JSON::false,
            error => $auth->{reason},
            code  => $auth->{code},
        });
        return;
    }

    my $lock = Dispatcher::Lock::check_available(
        hosts  => $hosts,
        script => $script,
    );
    unless ($lock->{ok}) {
        _send_json($conn, 409, {
            ok        => JSON::false,
            error     => 'locked',
            code      => 4,
            conflicts => $lock->{conflicts},
        });
        return;
    }

    my $results = Dispatcher::Engine::dispatch_all(
        hosts  => $hosts,
        script => $script,
        args   => $args,
        config => $config,
    );

    _send_json($conn, 200, { ok => JSON::true, results => $results });
}

sub _handle_discovery {
    my ($conn, $peer, $body, $config) = @_;

    # Optional body: { "hosts": [...], "username": "...", "token": "..." }
    # If no hosts specified, use the full agent registry
    my $req = {};
    if ($body && length $body) {
        $req = eval { decode_json($body) } // {};
    }

    my $hosts    = $req->{hosts};
    my $username = $req->{username} // '';
    my $token    = $req->{token}    // '';

    # Default to all registered agents
    unless (ref $hosts eq 'ARRAY' && @$hosts) {
        $hosts = Dispatcher::Registry::list_hostnames();
    }

    unless (@$hosts) {
        _send_json($conn, 200, { ok => JSON::true, hosts => {} });
        return;
    }

    my $auth = Dispatcher::Auth::check(
        action    => 'ping',    # discovery uses ping privilege level
        hosts     => $hosts,
        username  => $username,
        token     => $token,
        source_ip => $peer,
        config    => $config,
    );
    unless ($auth->{ok}) {
        _send_json($conn, 403, {
            ok    => JSON::false,
            error => $auth->{reason},
            code  => $auth->{code},
        });
        return;
    }

    my $results = Dispatcher::Engine::capabilities_all(
        hosts  => $hosts,
        config => $config,
    );

    # Reshape from array to hash keyed by hostname for easy lookup
    my %by_host;
    for my $r (@$results) {
        my $h = $r->{host} or next;
        $by_host{$h} = $r;
    }

    _send_json($conn, 200, { ok => JSON::true, hosts => \%by_host });
}

sub _handle_index {
    my ($conn, $config) = @_;
    _send_json($conn, 200, {
        name      => 'dispatcher-api',
        version   => $VERSION,
        spec      => '/openapi.json',
        live_spec => '/openapi-live.json',
        endpoints => [
            { method => 'GET',  path => '/health'           },
            { method => 'POST', path => '/ping'              },
            { method => 'POST', path => '/run'               },
            { method => 'GET',  path => '/discovery'         },
            { method => 'POST', path => '/discovery'         },
            { method => 'GET',  path => '/openapi.json'      },
            { method => 'GET',  path => '/openapi-live.json' },
        ],
    });
}

my $OPENAPI_PATH = '/usr/local/lib/dispatcher/Dispatcher/openapi.json';

sub _handle_openapi {
    my ($conn, $config) = @_;
    unless (-f $OPENAPI_PATH) {
        _send_error($conn, 404, 'not found', 'openapi.json not installed');
        return;
    }
    open my $fh, '<', $OPENAPI_PATH
        or do { _send_error($conn, 500, 'server error', "cannot read spec: $!"); return; };
    local $/;
    my $body = <$fh>;
    close $fh;
    print $conn
        "HTTP/1.0 200 OK\r\n",
        "Content-Type: application/json\r\n",
        "Content-Length: ", length($body), "\r\n",
        "\r\n",
        $body;
}

sub _handle_openapi_live {
    my ($conn, $peer, $config) = @_;

    # Load the base spec from disk
    unless (-f $OPENAPI_PATH) {
        _send_error($conn, 404, 'not found', 'openapi.json not installed');
        return;
    }
    my $spec = eval {
        open my $fh, '<', $OPENAPI_PATH or die "cannot read: $!";
        local $/;
        decode_json(scalar <$fh>);
    };
    if ($@ || !$spec) {
        _send_error($conn, 500, 'server error', "cannot parse base spec: $@");
        return;
    }

    # Hostnames: always from registry (no network)
    my $hostnames = Dispatcher::Registry::list_hostnames();

    # Script names: live capabilities scan; unreachable hosts silently omitted
    my @scripts;
    if (@$hostnames) {
        my $results = Dispatcher::Engine::capabilities_all(
            hosts  => $hostnames,
            config => $config,
        );
        my %seen;
        for my $r (@$results) {
            next unless ($r->{status} // '') eq 'ok';
            next unless ref $r->{scripts} eq 'ARRAY';
            for my $s (@{ $r->{scripts} }) {
                my $name = $s->{name} or next;
                $seen{$name}++ unless $seen{$name};
            }
        }
        @scripts = sort keys %seen;
    }

    # Inject enum values into the spec
    # hosts field appears in /ping, /run, /discovery request bodies
    for my $path_key (qw(/ping /run /discovery)) {
        for my $method_key (qw(post get)) {
            my $op = $spec->{paths}{$path_key}{$method_key} or next;
            my $body_schema = eval {
                $op->{requestBody}{content}{'application/json'}{schema}
            } or next;
            # Resolve $ref if needed
            if (my $ref = $body_schema->{'$ref'}) {
                my $name = (split '/', $ref)[-1];
                $body_schema = $spec->{components}{schemas}{$name} or next;
            }
            if (ref $body_schema->{properties}{hosts} eq 'HASH') {
                $body_schema->{properties}{hosts}{items}{enum} =
                    @$hostnames ? $hostnames : undef;
            }
        }
    }

    # script field in /run
    if (@scripts) {
        my $run_schema_name = eval {
            my $ref = $spec->{paths}{'/run'}{post}{requestBody}
                          {content}{'application/json'}{schema}{'$ref'};
            (split '/', $ref)[-1];
        };
        if ($run_schema_name &&
            ref $spec->{components}{schemas}{$run_schema_name} eq 'HASH') {
            $spec->{components}{schemas}{$run_schema_name}
                  {properties}{script}{enum} = \@scripts;
        }
    }

    # Stamp live version: base_version+epoch
    my $base_version = $spec->{info}{version} // $VERSION;
    $base_version =~ s/\+\d+$//;   # strip any previous epoch suffix
    $spec->{info}{version} = $base_version . '+' . time();

    my $body = encode_json($spec);
    print $conn
        "HTTP/1.0 200 OK\r\n",
        "Content-Type: application/json\r\n",
        "Content-Length: ", length($body), "\r\n",
        "\r\n",
        $body;
}

sub _parse_body {
    my ($conn, $body) = @_;
    unless ($body && length $body) {
        _send_error($conn, 400, 'bad request', 'request body required');
        return undef;
    }
    my $req = eval { decode_json($body) };
    if ($@ || ref $req ne 'HASH') {
        _send_error($conn, 400, 'bad request', 'invalid JSON body');
        return undef;
    }
    return $req;
}

sub _send_json {
    my ($conn, $status, $data) = @_;
    my $body   = encode_json($data);
    my $phrase = _status_phrase($status);
    print $conn
        "HTTP/1.0 $status $phrase\r\n",
        "Content-Type: application/json\r\n",
        "Content-Length: ", length($body), "\r\n",
        "\r\n",
        $body;
}

sub _send_error {
    my ($conn, $status, $error, $detail) = @_;
    _send_json($conn, $status, {
        ok    => JSON::false,
        error => $error,
        ($detail ? (detail => $detail) : ()),
    });
}

sub _status_phrase {
    my ($code) = @_;
    my %phrases = (
        200 => 'OK',
        400 => 'Bad Request',
        403 => 'Forbidden',
        404 => 'Not Found',
        409 => 'Conflict',
        500 => 'Internal Server Error',
    );
    return $phrases{$code} // 'Unknown';
}

1;
