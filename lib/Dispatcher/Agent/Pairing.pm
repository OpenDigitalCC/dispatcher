package Dispatcher::Agent::Pairing;

use strict;
use warnings;
use File::Temp qw(tempfile tempdir);
use File::Basename qw(dirname);
use Carp qw(croak);


# Generate a private key and CSR using openssl
# Returns hashref: { key_pem => '...', csr_pem => '...' }
# or dies on failure
sub generate_key_and_csr {
    my (%opts) = @_;
    my $hostname  = $opts{hostname}  or croak "hostname required";
    my $bits      = $opts{bits}      // 4096;

    my $tmpdir = tempdir(CLEANUP => 1);
    my $key_file = "$tmpdir/agent.key";
    my $csr_file = "$tmpdir/agent.csr";

    _run_or_die(
        'openssl', 'genrsa',
        '-out', $key_file,
        $bits
    );

    _run_or_die(
        'openssl', 'req',
        '-new',
        '-key',     $key_file,
        '-out',     $csr_file,
        '-subj',    "/CN=$hostname",
    );

    my $key_pem = _slurp($key_file);
    my $csr_pem = _slurp($csr_file);

    return { key_pem => $key_pem, csr_pem => $csr_pem };
}

# Generate a CSR from the existing agent key, without generating a new key.
# Used for cert renewal - key continuity is preserved.
# Returns hashref: { csr_pem => '...' } or dies on failure.
sub generate_csr_only {
    my (%opts) = @_;
    my $hostname = $opts{hostname}  or croak "hostname required";
    my $key_path = $opts{key_path}  or croak "key_path required";

    croak "Key file not found at '$key_path'" unless -f $key_path;

    my $tmpdir   = tempdir(CLEANUP => 1);
    my $csr_file = "$tmpdir/agent.csr";

    _run_or_die(
        'openssl', 'req',
        '-new',
        '-key',  $key_path,
        '-out',  $csr_file,
        '-subj', "/CN=$hostname",
    );

    my $csr_pem = _slurp($csr_file);
    return { csr_pem => $csr_pem };
}


# cert_dir defaults to /etc/dispatcher-agent
sub store_certs {
    my (%opts) = @_;
    my $cert_pem  = $opts{cert_pem}  or croak "cert_pem required";
    my $ca_pem    = $opts{ca_pem}    or croak "ca_pem required";
    my $key_pem   = $opts{key_pem}   or croak "key_pem required";
    my $cert_dir  = $opts{cert_dir}  // '/etc/dispatcher-agent';
    my $group     = $opts{group}     // 'dispatcher-agent';

    _write_file("$cert_dir/agent.crt", $cert_pem, 0640);
    _write_file("$cert_dir/agent.key", $key_pem,  0640);
    _write_file("$cert_dir/ca.crt",   $ca_pem,   0644);

    # Set group ownership so the service user can read the certs
    my $gid = getgrnam($group);
    if (defined $gid) {
        chown 0, $gid, "$cert_dir/agent.crt",
                       "$cert_dir/agent.key",
                       "$cert_dir/ca.crt";
    }
    else {
        warn "store_certs: group '$group' not found - set ownership manually\n";
    }
}

# Check whether the agent has been paired
# Returns hashref: { paired => 1, expiry => 'YYYY-MM-DD' }
#               or { paired => 0, reason => '...' }
sub pairing_status {
    my (%opts) = @_;
    my $cert_dir = $opts{cert_dir} // '/etc/dispatcher-agent';
    my $cert     = "$cert_dir/agent.crt";
    my $key      = "$cert_dir/agent.key";
    my $ca       = "$cert_dir/ca.crt";

    for my $f ($cert, $key, $ca) {
        unless (-f $f) {
            return { paired => 0, reason => "missing file: $f" };
        }
    }

    # Extract expiry date from cert
    my $expiry = _cert_expiry($cert);
    unless (defined $expiry) {
        return { paired => 0, reason => "cannot parse cert: $cert" };
    }

    return { paired => 1, expiry => $expiry };
}

# Connect to dispatcher pairing port, send CSR, wait for approval
# Returns hashref: { ok => 1, cert_pem => '...', ca_pem => '...' }
#               or { ok => 0, error => '...' }
sub request_pairing {
    my (%opts) = @_;
    my $dispatcher_host = $opts{dispatcher} or croak "dispatcher required";
    my $port            = $opts{port}       // 7444;
    my $csr_pem         = $opts{csr_pem}    or croak "csr_pem required";
    my $hostname        = $opts{hostname}   or croak "hostname required";
    my $ca_cert         = $opts{ca_cert};   # optional: verify dispatcher cert

    require IO::Socket::SSL;
    require JSON;

    # Generate a per-request nonce to verify the response is for this specific
    # request and not a replayed or misrouted one.
    my $nonce = _gen_nonce();

    my %ssl_opts = (
        PeerHost        => $dispatcher_host,
        PeerPort        => $port,
        Timeout         => 660,    # 11 minutes - longer than dispatcher's 10 min poll window
        SSL_verify_mode => $ca_cert
            ? IO::Socket::SSL::SSL_VERIFY_PEER()
            : IO::Socket::SSL::SSL_VERIFY_NONE(),
    );
    $ssl_opts{SSL_ca_file} = $ca_cert if $ca_cert;

    my $sock = IO::Socket::SSL->new(%ssl_opts)
        or return { ok => 0, error => "connect failed: $IO::Socket::SSL::SSL_ERROR" };

    my $payload = JSON::encode_json({
        hostname => $hostname,
        csr      => $csr_pem,
        nonce    => $nonce,
    });

    print $sock "POST /pair HTTP/1.0\r\n",
                "Content-Type: application/json\r\n",
                "Content-Length: ", length($payload), "\r\n",
                "\r\n",
                $payload;

    # Read HTTP response headers line by line
    my $status_line = <$sock>;
    return { ok => 0, error => "no response from dispatcher" } unless $status_line;

    my $content_length;
    while (my $line = <$sock>) {
        $line =~ s/\r\n$//;
        $line =~ s/\n$//;
        last if $line eq '';   # blank line = end of headers
        if ($line =~ /^Content-Length:\s*(\d+)/i) {
            $content_length = $1;
        }
    }

    return { ok => 0, error => "no Content-Length in pairing response" }
        unless defined $content_length;

    # Read exactly content_length bytes - no waiting for EOF
    my $body = '';
    read $sock, $body, $content_length;
    close $sock;

    return { ok => 0, error => "empty response body" } unless length $body;

    my $data = eval { JSON::decode_json($body) };
    return { ok => 0, error => "bad JSON: $@" } if $@;

    if ($data->{status} eq 'approved') {
        if (($data->{nonce} // '') ne $nonce) {
            return { ok => 0, error => 'nonce mismatch in pairing response' };
        }
        return {
            ok       => 1,
            cert_pem => $data->{cert},
            ca_pem   => $data->{ca},
        };
    }

    return { ok => 0, error => $data->{reason} // 'denied' };
}

# --- private helpers ---

sub _gen_nonce {
    return sprintf '%08x%08x%08x%08x',
        int(rand(0xffffffff)), int(rand(0xffffffff)),
        int(rand(0xffffffff)), $$;
}

sub _run_or_die {
    my @cmd = @_;
    system(@cmd) == 0
        or croak "Command failed (@cmd): $?";
}

sub _slurp {
    my ($path) = @_;
    open my $fh, '<', $path or croak "Cannot read '$path': $!";
    local $/;
    return scalar <$fh>;
}

sub _write_file {
    my ($path, $content, $mode) = @_;
    my $dir = dirname($path);
    croak "Directory '$dir' does not exist" unless -d $dir;

    my ($tmp_fh, $tmp_path) = tempfile(DIR => $dir, UNLINK => 0);
    print $tmp_fh $content;
    close $tmp_fh;

    chmod $mode, $tmp_path;
    rename $tmp_path, $path
        or do { unlink $tmp_path; croak "rename failed for '$path': $!" };
}

sub _cert_expiry {
    my ($cert_path) = @_;
    my $out = `openssl x509 -noout -enddate -in \Q$cert_path\E 2>/dev/null`;
    return unless defined $out && $out =~ /notAfter=(.+)/;
    my $date_str = $1;
    chomp $date_str;
    return $date_str;
}

1;
