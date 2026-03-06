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
    if ($path eq '/health' && $method eq 'GET') {
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
