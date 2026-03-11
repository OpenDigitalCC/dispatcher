#!/usr/bin/perl
# t/header-limit.t
#
# Unit tests for the HTTP header count limit in bin/dispatcher-agent.
#
# handle_connection reads from whatever filehandle is passed as $conn.
# We load the agent source via do() after stubbing main() to prevent
# execution, then pass a pipe pair as the mock connection.
#
# The limit is 32 headers. A 33rd header triggers a 431 response and
# handle_connection returns without processing the body or route.

use strict;
use warnings;
use Test::More;
use FindBin qw($Bin);
use lib "$Bin/../lib";

# Stub out modules the agent loads that we do not need for this test
use Dispatcher::Log qw();
{
    no warnings 'redefine';
    *Dispatcher::Log::init       = sub {};
    *Dispatcher::Log::log_action = sub {};
}

# Load the agent source. This defines handle_connection and _send_raw
# in the main:: namespace. Stub main() first so the unconditional
# main() call at the top of the script does not execute.
my $agent = "$Bin/../bin/dispatcher-agent";
unless (-f $agent) {
    plan skip_all => "dispatcher-agent not found at $agent";
}
{
    no warnings 'redefine';
    *main::main = sub {};
}
do $agent;
die $@ if $@;

# Verify the functions we need were loaded
unless (defined &main::handle_connection && defined &main::_send_raw) {
    plan skip_all => 'handle_connection or _send_raw not loaded from agent';
}

# ---------------------------------------------------------------------------
# Helper: build a raw HTTP request string
# ---------------------------------------------------------------------------

sub make_request {
    my (%opts) = @_;
    my $method       = $opts{method}       // 'POST';
    my $path         = $opts{path}         // '/ping';
    my $header_count = $opts{header_count} // 2;
    my $body         = $opts{body}         // '{}';

    my @lines;
    push @lines, "$method $path HTTP/1.0\r\n";
    push @lines, "Content-Type: application/json\r\n";
    # Add extra headers to reach the desired count (Content-Type is already 1)
    for my $i (2 .. $header_count) {
        push @lines, "X-Filler-$i: value\r\n";
    }
    push @lines, "Content-Length: " . length($body) . "\r\n";
    push @lines, "\r\n";
    push @lines, $body;

    return join('', @lines);
}

# ---------------------------------------------------------------------------
# Helper: run handle_connection with a crafted request, return response
# ---------------------------------------------------------------------------

sub run_handle {
    my ($request_str) = @_;

    # Create a pipe. Write the request to the write end, read the response
    # from the same handle (handle_connection both reads and writes $conn).
    # We need a bidirectional pipe; use a socketpair.
    require IO::Socket;
    my ($client, $server);
    IO::Socket->socketpair($client, $server,
        IO::Socket::AF_UNIX(),
        IO::Socket::SOCK_STREAM(),
        0
    ) or die "socketpair: $!";

    # Write the request to the server side
    print $server $request_str;
    $server->shutdown(1);  # no more writing from server side

    # Call handle_connection with the server socket as $conn
    # Minimal args: revoked={}, disp_serial='', peer_serial=''
    main::handle_connection(
        $server,
        '127.0.0.1',    # peer
        {},             # allowlist
        {},             # config
        {},             # revoked
        '',             # disp_serial
        '',             # peer_serial
    );
    $server->close;

    # Read back whatever handle_connection wrote to the client side
    local $/;
    my $response = <$client>;
    $client->close;
    return $response // '';
}

# ---------------------------------------------------------------------------
# 32 headers: should not trigger the limit
# ---------------------------------------------------------------------------

{
    # 32 non-blank headers (including Content-Type and Content-Length)
    # make_request adds Content-Type (1) + fillers to reach header_count,
    # then Content-Length. So header_count=30 gives 32 headers total.
    my $req      = make_request(header_count => 30, path => '/ping', body => '{}');
    my $response = run_handle($req);

    unlike $response, qr{HTTP/1\.0 431}, '32 headers: no 431 response';
    like   $response, qr{HTTP/1\.0 [^4]}, '32 headers: non-4xx response received';
}

# ---------------------------------------------------------------------------
# 33 headers: should trigger 431
# ---------------------------------------------------------------------------

{
    # header_count=31 gives Content-Type + 30 fillers + Content-Length = 32,
    # then one more filler makes 33 total before the blank line.
    # Actually simpler: craft the raw string directly.
    my @lines;
    push @lines, "POST /ping HTTP/1.0\r\n";
    for my $i (1..33) {
        push @lines, "X-Header-$i: value\r\n";
    }
    push @lines, "Content-Length: 2\r\n";
    push @lines, "\r\n";
    push @lines, "{}";
    my $req = join('', @lines);

    my $response = run_handle($req);

    like $response, qr{HTTP/1\.0 431}, '33 headers: 431 response returned';
    like $response, qr{too many headers}i, '33 headers: error body mentions too many headers';
}

# ---------------------------------------------------------------------------
# 34 headers: still 431 (not a different error)
# ---------------------------------------------------------------------------

{
    my @lines;
    push @lines, "POST /ping HTTP/1.0\r\n";
    for my $i (1..34) {
        push @lines, "X-Header-$i: value\r\n";
    }
    push @lines, "\r\n";
    my $req = join('', @lines);

    my $response = run_handle($req);
    like $response, qr{HTTP/1\.0 431}, '34 headers: still returns 431';
}

# ---------------------------------------------------------------------------
# Exactly 0 extra headers (minimal request): accepted
# ---------------------------------------------------------------------------

{
    my $req = "POST /ping HTTP/1.0\r\nContent-Length: 2\r\n\r\n{}";
    my $response = run_handle($req);
    unlike $response, qr{HTTP/1\.0 431}, 'minimal request (2 headers): no 431';
}

# ---------------------------------------------------------------------------
# 431 response has correct Content-Type
# ---------------------------------------------------------------------------

{
    my @lines;
    push @lines, "POST /ping HTTP/1.0\r\n";
    for my $i (1..33) {
        push @lines, "X-Excess-$i: v\r\n";
    }
    push @lines, "\r\n";
    my $req = join('', @lines);

    my $response = run_handle($req);
    like $response, qr{Content-Type: application/json}i,
        '431 response has application/json content-type';
}

done_testing;
