#!perl
use 5.006;
use strict;
use warnings FATAL => 'all';
use Cwd;
use File::Spec;
use Test::Differences::Color;
use Test::MockObject;
use Test::More;

#plan tests => 2;
#plan tests => 'no_plan';
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
$mock_gcal->mock(
    'get_events',
    sub {
        return @{ shift->{entries} || [] };
    },
);
# update_entry is a no-op here; the entry objects are references, and the entry
# object will have been updated; update_entry would be called to sync the
# changes to Google, so we do nothing.
$mock_gcal->set_true('update_entry');
$mock_gcal->mock(
    'wipe_entries',
    sub {
        shift->{entries} = [];
    }
);


App::ICalToGCal->gcal_obj($mock_gcal);
is(
    App::ICalToGCal->gcal_obj(),
    $mock_gcal,
    "Got back our mocked Net::Google::Calendar object",
);

# We have some sample iCal data shipped with the dist; if we work out the
# absolute path to them, we should be able to give a file:// URL to fetch_ical
# and expect it to work.
my @tests = (
    {
        test_title => "Basic tests",
        ical_file => 'test1.ical',
        expect_entries => [
            {
                all_day  => 1,
                location => "San Francisco",
                rrule    => "",
                status   => undef,
                title    => "Apple WWDC",
                when     => "2015-06-06T00:00:00 => 2015-06-12T00:00:00",
            },
            {
                all_day  => 0,
                location => "Home",
                rrule    => "",
                status   => undef,
                title    => "Set up File Server",
                when     => "2015-06-15T21:00:00 => 2015-06-15T22:00:00",
            },
        ]
    },
    {
        test_title => "One all-day event",
        ical_file => 'allday.ical',
        expect_entries => [
            {
                all_day => 1,
                location => '',
                rrule => '',
                status => undef,
                title => 'all day',
                when => '2004-11-15T00:00:00 => 2004-11-16T00:00:00'
            },
        ],
    },
    {
        # This test is based on Issue 6:
        # https://github.com/bigpresh/ical-to-google-calendar/issues/6
        test_title => "Recurring events (Issue #6)",
        ical_file => 'recurring.ical',
        expect_entries => [
            {
                all_day => 0,
                location => '',
                rrule => '',
                status => undef,
                title => 'Test event',
                when => '2015-11-18T02:00:00 => 2015-11-18T03:00:00'
            },
            {
                all_day => 0,
                location => '',
                rrule => 'FREQ=WEEKLY;INTERVAL=1;UNTIL=20150207T065959Z;BYDAY=SA',
                status => undef,
                title => 'Tuesday SwingTime2',
                when => '2015-02-04T02:00:00 => 2015-02-04T05:00:00'
            },
        ],
    },
    
    # Now, process test1.ical again, but this time, don't clear the mock gcal
    # object, so we can check the events from the previous test are still 
    # present in addition to the events from test1.ical (i.e. test that we can
    # process multiple iCal feeds and have the events all end up on the same
    # Google Calendar...)
    {
        keep_previous => 1,
        ical_file => 'test1.ical',
        test_title => 'Adding items from another feed to previous',
        expect_entries => [
            {
                all_day => 0,
                location => '',
                rrule => '',
                status => undef,
                title => 'Test event',
                when => '2015-11-18T02:00:00 => 2015-11-18T03:00:00'
            },
            {
                all_day => 0,
                location => '',
                rrule => 'FREQ=WEEKLY;INTERVAL=1;UNTIL=20150207T065959Z;BYDAY=SA',
                status => undef,
                title => 'Tuesday SwingTime2',
                when => '2015-02-04T02:00:00 => 2015-02-04T05:00:00'
            },
            {
                all_day  => 1,
                location => "San Francisco",
                rrule    => "",
                status   => undef,
                title    => "Apple WWDC",
                when     => "2015-06-06T00:00:00 => 2015-06-12T00:00:00",
            },
            {
                all_day  => 0,
                location => "Home",
                rrule    => "",
                status   => undef,
                title    => "Set up File Server",
                when     => "2015-06-15T21:00:00 => 2015-06-15T22:00:00",
            },
        ]
    },
);

for my $test_spec (@tests) {
    diag($test_spec->{test_title}) if $test_spec->{test_title};
    my $ical_file = File::Spec->catfile(
        Cwd::cwd(), 't', 'ical-data', $test_spec->{ical_file}
    );

    # Unless this test expects to be building upon the results of a previous
    # test, wipe the contents of the mock gcal object, so we can compare the
    # entries with what we expect to see, and not see things we didn't expect:
    if (!$test_spec->{keep_previous}) {
        $mock_gcal->wipe_entries;
    }

    my $ical_data = App::ICalToGCal->fetch_ical("file://$ical_file");
    ok(
        ref $ical_data, 
        "Got a parsed iCal result from $test_spec->{ical_file}"
    );

    App::ICalToGCal->update_google_calendar(
        $mock_gcal, $ical_data, App::ICalToGCal->hash_ical_url($ical_file)
    );

    eq_or_diff(
        summarise_events([ $mock_gcal->get_events() ]),
        $test_spec->{expect_entries},
        "Entries for $test_spec->{ical_file} look correct",
    );

}


done_testing();


# Given a set of Net::Google::Calendar::Entry objects, turn them into simple 
# concise hashrefs we can give to Test::Differences to compare with
# what the test says we should have got.
sub summarise_events {
    my $events = shift;

    return [
        map {
            my $entry = $_;
            my ($start, $end, $all_day) = $entry->when;
            +{
                # The simpler stuff:
                (
                    map { $_ => $entry->$_() }
                        qw(title location status)
                ),
                # deflate datetimes:
                when => join(' => ',
                    (map { $_->iso8601 } ($start, $end))
                ),
                all_day => $all_day,
                ( rrule => $_->recurrence
                    ? $_->recurrence->entries->[0]->properties->{rrule}[0]->value
                    : '' )
            }
        } @$events
    ];
}

