package Dispatcher::Pairing;

use strict;
use warnings;
use File::Path  qw(make_path);
use File::Temp  qw(tempfile);
use JSON        qw(encode_json decode_json);
use POSIX       qw(strftime);
use Carp        qw(croak);

our $VERSION = '0.1';

my $PAIRING_DIR = '/var/lib/dispatcher/pairing';

# Start pairing mode - listen on port for agent CSR requests
# Blocks until interrupted (SIGINT/SIGTERM)
sub run_pairing_mode {
    my (%opts) = @_;
    my $port    = $opts{port}    // 7444;
    my $ca_dir  = $opts{ca_dir}  // '/etc/dispatcher';
    my $cert    = $opts{cert}    or croak "cert required";
    my $key     = $opts{key}     or croak "key required";
    my $log_fn  = $opts{log_fn}  // sub {};

    make_path($PAIRING_DIR) unless -d $PAIRING_DIR;

    require IO::Socket::SSL;

    # Pairing port: TLS server cert only, no client cert required
    my $server = IO::Socket::SSL->new(
        LocalPort       => $port,
        Listen          => 5,
        ReuseAddr       => 1,
        SSL_cert_file   => $cert,
        SSL_key_file    => $key,
        SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE(),
    ) or die "Cannot start pairing server: $IO::Socket::SSL::SSL_ERROR\n";

    $log_fn->({ ACTION => 'pairing-mode-start', PORT => $port });
    print "Pairing mode active on port $port. Ctrl-C to stop.\n";
    print "Use 'dispatcher list-requests' to see pending requests.\n";

    $SIG{INT} = $SIG{TERM} = sub {
        $log_fn->({ ACTION => 'pairing-mode-stop' });
        print "\nPairing mode stopped.\n";
        exit 0;
    };

    while (my $conn = $server->accept) {
        my $peer_ip = $conn->peerhost // 'unknown';
        my $pid = fork();
        if (!defined $pid) {
            warn "fork failed: $!\n";
            $conn->close;
            next;
        }
        if ($pid == 0) {
            $server->close;
            _handle_pair_request($conn, $peer_ip, $log_fn);
            $conn->close;
            exit 0;
        }
        # Close parent copy without SSL shutdown - child still owns the connection
        $conn->close(SSL_no_shutdown => 1);
        waitpid -1, POSIX::WNOHANG();
    }
}

# Return list of pending requests sorted by received time
sub list_requests {
    my (%opts) = @_;
    my $dir = $opts{pairing_dir} // $PAIRING_DIR;
    return [] unless -d $dir;

    my @requests;
    opendir my $dh, $dir or croak "Cannot open '$dir': $!";
    while (my $f = readdir $dh) {
        next unless $f =~ /^([a-f0-9]+)\.json$/;
        my $id   = $1;
        my $path = "$dir/$f";
        my $data = eval { decode_json(_slurp($path)) };
        next if $@;
        push @requests, $data;
    }
    closedir $dh;

    return [ sort { $a->{received} cmp $b->{received} } @requests ];
}

# Approve a pending request: sign CSR, deliver cert to waiting agent
# The agent's connection is held in a response file keyed by reqid
sub approve_request {
    my (%opts) = @_;
    my $reqid       = $opts{reqid}       or croak "reqid required";
    my $ca_dir      = $opts{ca_dir}      // '/etc/dispatcher';
    my $pairing_dir = $opts{pairing_dir} // $PAIRING_DIR;
    my $log_fn      = $opts{log_fn}      // sub {};

    my $req_file = "$pairing_dir/$reqid.json";
    -f $req_file or croak "No pending request '$reqid'";

    my $req = decode_json(_slurp($req_file));

    require Dispatcher::CA;
    my $cert_pem = Dispatcher::CA::sign_csr(
        csr_pem => $req->{csr},
        ca_dir  => $ca_dir,
    );
    my $ca_pem = Dispatcher::CA::read_ca_cert(ca_dir => $ca_dir);

    # Extract cert expiry for the registry record
    my $expiry = _cert_expiry_from_pem($cert_pem);

    # Write approval response - the waiting child process reads this
    my $resp_file = "$pairing_dir/$reqid.approved";
    _write_file($resp_file, encode_json({
        status => 'approved',
        cert   => $cert_pem,
        ca     => $ca_pem,
    }));

    # Persist agent record - source of truth for all paired agents
    require Dispatcher::Registry;
    Dispatcher::Registry::register_agent(
        hostname => $req->{hostname},
        ip       => $req->{ip},
        paired   => strftime('%Y-%m-%dT%H:%M:%SZ', gmtime),
        expiry   => $expiry // '',
        reqid    => $reqid,
    );

    $log_fn->({ ACTION => 'pair-approve', AGENT => $req->{hostname}, REQID => $reqid });
    print "Approved '$req->{hostname}' ($reqid). Cert delivered on next poll.\n";
}

# Deny and remove a pending request
sub deny_request {
    my (%opts) = @_;
    my $reqid       = $opts{reqid}       or croak "reqid required";
    my $pairing_dir = $opts{pairing_dir} // $PAIRING_DIR;
    my $log_fn      = $opts{log_fn}      // sub {};

    my $req_file = "$pairing_dir/$reqid.json";
    -f $req_file or croak "No pending request '$reqid'";

    my $req = eval { decode_json(_slurp($req_file)) } // {};

    # Write denial so any waiting child can respond to agent
    my $resp_file = "$pairing_dir/$reqid.denied";
    _write_file($resp_file, encode_json({
        status => 'denied',
        reason => 'rejected by operator',
    }));

    unlink $req_file;

    $log_fn->({ ACTION => 'pair-deny', AGENT => $req->{hostname} // '?', REQID => $reqid });
    print "Denied request '$reqid'.\n";
}

# --- private ---

sub _handle_pair_request {
    my ($conn, $peer_ip, $log_fn) = @_;

    # Read raw HTTP request
    my $raw = '';
    while (my $line = <$conn>) {
        $raw .= $line;
        last if $raw =~ /\r\n\r\n/;
    }

    my ($content_length) = $raw =~ /Content-Length:\s*(\d+)/i;
    my $body = '';
    if ($content_length) {
        read $conn, $body, $content_length;
    }

    my $data = eval { decode_json($body) };
    unless ($data && $data->{csr} && $data->{hostname}) {
        _send_raw($conn, encode_json({ status => 'error', reason => 'invalid request' }));
        return;
    }

    my $reqid    = _gen_reqid();
    my $hostname = $data->{hostname};
    my $csr      = $data->{csr};
    my $received = strftime('%Y-%m-%dT%H:%M:%SZ', gmtime);

    # Queue the request
    make_path($PAIRING_DIR) unless -d $PAIRING_DIR;
    _write_file("$PAIRING_DIR/$reqid.json", encode_json({
        id       => $reqid,
        hostname => $hostname,
        ip       => $peer_ip,
        csr      => $csr,
        received => $received,
    }));

    $log_fn->({ ACTION => 'pair-request', AGENT => $hostname, IP => $peer_ip, REQID => $reqid, STATUS => 'pending' });
    print "Pairing request queued: $hostname ($peer_ip) - ID: $reqid\n";

    # Poll for approval or denial (max 10 minutes)
    my $resp_approved = "$PAIRING_DIR/$reqid.approved";
    my $resp_denied   = "$PAIRING_DIR/$reqid.denied";
    my $deadline      = time + 600;

    while (time < $deadline) {
        if (-f $resp_approved) {
            my $resp = _slurp($resp_approved);
            _send_raw($conn, $resp);
            unlink $resp_approved;
            unlink "$PAIRING_DIR/$reqid.json";
            return;
        }
        if (-f $resp_denied) {
            my $resp = _slurp($resp_denied);
            _send_raw($conn, $resp);
            unlink $resp_denied;
            return;
        }
        sleep 2;
    }

    # Timeout
    _send_raw($conn, encode_json({ status => 'denied', reason => 'approval timeout' }));
    unlink "$PAIRING_DIR/$reqid.json";
}

sub _send_raw {
    my ($conn, $body) = @_;
    print $conn
        "HTTP/1.0 200 OK\r\n",
        "Content-Type: application/json\r\n",
        "Content-Length: ", length($body), "\r\n",
        "\r\n",
        $body;
}

sub _gen_reqid {
    return sprintf '%08x', int(rand(0xffffffff));
}

sub _slurp {
    my ($path) = @_;
    open my $fh, '<', $path or croak "Cannot read '$path': $!";
    local $/;
    return scalar <$fh>;
}

sub _write_file {
    my ($path, $content) = @_;
    open my $fh, '>', $path or croak "Cannot write '$path': $!";
    print $fh $content;
    close $fh;
}

# Extract the notAfter date from a PEM cert string.
# Writes to a temp file, calls openssl x509 -noout -enddate.
# Returns the date string, or undef on failure.
sub _cert_expiry_from_pem {
    my ($cert_pem) = @_;
    my ($fh, $path) = tempfile(SUFFIX => '.crt', UNLINK => 1);
    print $fh $cert_pem;
    close $fh;
    my $out = `openssl x509 -noout -enddate -in \Q$path\E 2>/dev/null`;
    return unless defined $out && $out =~ /notAfter=(.+)/;
    my $date = $1;
    chomp $date;
    return $date;
}

1;
