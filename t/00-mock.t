#!perl -T
use 5.006;
use strict;
use warnings FATAL => 'all';
use Test::MockObject;
use Test::More;

plan tests => 2;

use_ok( 'App::ICalToGCal' ) || print "Bail out!\n";

diag( "Testing App::ICalToGCal $App::ICalToGCal::VERSION, Perl $], $^X" );

# override the Net::Google::Calendar object so we can parse some example feeds
# and check what resulting objects were created.  Implement just enough of the
# interface we expect to use to make things work.
my $mock_gcal = Test::MockObject->new;
$mock_gcal->set_true('login');
$mock_gcal->set_list('calendars',
    map {
        my $calendar = Test::MockObject->new;
        $calendar->set_always('name', $_);
        $calendar;
    } ('Boring calendar', 'Calendar we want', 'Other calendar')
);
$mock_gcal->mock(
    'delete_entry',
    sub {
        my ($self, $entry) = @_;
        $self->{entries} = grep { ref $_ ne ref $entry } @{ $self->{entries} };
    }
);
$mock_gcal->mock(
    'add_entry',
    sub {
        my ($self, $entry) = @_;
        push @{ $self->{entries} }, $entry;
    }
);
# update_entry is a no-op here; the entry objects are references, and the entry
# object will have been updated; update_entry would be called to sync the
# changes to Google, so we do nothing.
$mock_gcal->set_true('update_entry');
$mock_gcal->set_true('is_our_mocked_object');
App::ICalToGCal->gcal_obj($mock_gcal);
is(
    App::ICalToGCal->gcal_obj(),
    $mock_gcal,
    "Got back our mocked Net::Google::Calendar object",
);



