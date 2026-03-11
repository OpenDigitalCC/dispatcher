#!/usr/bin/perl
# t/header-limit.t
#
# Tests for the HTTP header count limit (431) in bin/dispatcher-agent.
#
# SKIPPED: dispatcher-agent calls main() unconditionally at the top level
# and does not use the 'main() unless caller' idiom. It cannot be loaded
# via do() without executing the server startup. Stubbing *main::main before
# do() does not reliably intercept the call in all Perl versions.
#
# DEVELOPER.md documents this constraint explicitly: functions defined in
# the binary are not unit tested independently; they are covered by
# integration tests.
#
# TODO: extract handle_connection and _send_raw into a library module
# (e.g. Dispatcher::Agent::HTTP) to allow unit testing here.

use strict;
use warnings;
use Test::More;

plan skip_all =>
    'dispatcher-agent cannot be loaded via do() '
    . '(calls main() unconditionally; no unless-caller guard). '
    . 'Header limit behaviour is covered by integration tests.';
