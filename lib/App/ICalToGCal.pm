package App::ICalToGCal;

our $VERSION = 0.01;

use strict;
use Data::ICal;
use Date::ICal::Duration;
use DateTime;
use DateTime::Format::ISO8601;
use Net::Google::Calendar;
use Net::Google::Calendar::Entry;
use Net::Netrc;
use LWP::UserAgent;
use Digest::MD5;
use Scalar::Util qw(blessed);

=head1 NAME

App::ICalToGCal - import iCal feeds into a Google Calendar

=head1 DESCRIPTION

A command line script to fetch an iCal calendar feed, and create corresponding
events in a Google Calendar.

=head1 WHY?

Why not just add the iCal feed URL to your Google Calendar directly and let
Google deal with it, I hear you ask?

That would, at first glance, seem the best way - but they tend to update it
horribly slowly (in my experience, about expect about once every 24 hours at
best).

Calendaring is a time-sensitive thing; I don't want to wait a full day for
updates to take effect (by the time Google re-fetch the feed and update your
calendar, it could be too late!).

=head1 SYNOPSIS

Use the included ical-to-gcal script to fetch and parse an iCal feed and
add/update events in your Google Calendar to match it:

  ical-to-gcal --calendar="Google Calendar Name" --ical-url=....

You'll need to have put your login details in C<~/.netrc>...

=head1 CONFIGURATION

Google account details to be used to access your Google Calendar are stored in
the standard C<~/.netrc> file - your C<~/.netrc> file in your home directory
should contain:

    machine calendar.google.com
    login yourgoogleaccountusername
    password hunter2

Of course, you'll want to ensure that file is protected (kept readable by you
only, etc).



=head1 CLASS METHODS


=head2 select_google_calendar

Given a calendar name, reads our Google account details from C<~/.netrc>, logs
in to Google, selects the calendar with the name given using C<set_calendar>, 
and returns the L<Net::Google::Calendar> object.

=cut

sub select_google_calendar {
    my ($class, $calendar_name) = @_;
    # Get our login details, and find the Google calendar in question:
    my $mach = Net::Netrc->lookup('calendar.google.com')
        or die "No login details for calendar.google.com in ~/.netrc";
    my ($user, $pass) = $mach->lpa;


    my $gcal = $class->gcal_obj;
    $gcal->login($user, $pass)
        or die "Google Calendar login failed";

    my ($desired_calendar) = grep { 
        $_->title eq $calendar_name
    } $gcal->get_calendars;

    if (!$desired_calendar) {
        die "No calendar named $calendar_name found!";
    }
    $gcal->set_calendar($desired_calendar);
    return $gcal;
}

=head2 fetch_ical

Given an iCal feed URL, fetches it, parses it using L<iCal::Parser>, and returns
the result.

=cut

sub fetch_ical {
    my ($class, $ical_url) = @_;

    my $ua = LWP::UserAgent->new;
    $ua->agent(__PACKAGE__ . "/" . $VERSION);

    my $response = $ua->get($ical_url);
    if (!$response->is_success) {
        die "Failed to fetch $ical_url - " . $response->status_line;
    }

    my $ical = Data::ICal->new( data => $response->decoded_content )
        or die "Failed to parse iCal data";

    return $ical->entries;

}

=head2 hash_ical_url

Given the iCal feed URL, return a short hash to identify it; we'll use this in
the imported_ical_id tags in event descriptions to record which feed they came
from, so we can later delete them if the event is no longer present in the iCal
feed (i.e. it was deleted from the source).

=cut

sub hash_ical_url {
    my ($class, $ical_url) = @_;
    # Hash the feed URL, so we can use it along with the event ID to uniquely
    # identify events - and when removing events that aren't in the feed any
    # more, remove only those which came from this feed, if the user is using
    # multiple feeds.  (10 characters of the hash should be enough to be
    # reliable enough.)
    return substr(Digest::MD5->md5_hex($ical_url), 0, 10); }

=head2 update_google_calendar

Given a Google calendar object and the parsed iCal calendar data, make the
appropriate updates to the Google Calendar.

=cut

sub update_google_calendar {
    my ($class, $gcal, $ical_entries, $feed_url_hash) = @_;


    # Fetch all events from this Google calendar, parse out the ical feed's UID 
    # and whack them in a hash keyed by the UID; if that UID no longer appears
    # in Ithe ical feed, it's one to delete.
    my %gcal_events;

    gcal_event:
    for my $event ($gcal->get_events) {
        my ($ical_feed_hash, $ical_uid) 
            = $event->content->body =~ m{\[ical_imported_uid:(.+)/(.+)\]};

        # If there's no ical uid, we presumably didn't create this, so leave it
        # alone
        if (!$ical_uid) {
            # Special-case, though: previous versions of this script didn't store
            # the feed hash, so if we have only the event UID, assume it was this
            # feed so the script continues working
            if ($ical_uid 
                = $event->content->body =~ m{\[ical_imported_uid:(.+)\]}
            ) {
                $ical_feed_hash = $feed_url_hash;
            } else {
                warn sprintf "Event %s (%s) ignored as it has no "
                    . "ical_imported_uid property",
                    $event->id,
                    $event->title;
                next gcal_event;
            }
        }

        # OK, if the event isn't for this feed, let it be:
        if ($ical_feed_hash ne $feed_url_hash) {
            next gcal_event;
        }

        # Assemble a hash on event ID of all the events we saw in the iCal feed,
        # so we can quickly check

        # OK, if this event didn't appear in the iCal feed, it has been deleted at
        # the other end, so we should delete it from our Google calendar:
        if (!grep { $_->properties->{uid}->value eq $ical_uid } @$ical_entries)
        {
            printf "Deleting event %s (%s) (no longer found in iCal feed)\n",
                $event->id, $event->title;
            $gcal->delete_entry($event)
                or warn "Failed to delete an event from Google Calendar";
        }

        # Remember that we found this event, so we can refer to it when looking for
        # events we need to create
        $gcal_events{$ical_uid} = $event;
    }


    # Now, walk through the ical events we found, and create/update Google Calendar
    # events
    for my $ical_event (@$ical_entries) {
        
        my ($method, $gcal_event);
        my $ical_uid = get_ical_field($ical_event, 'uid');

        my $gcal_event = $class->ical_event_to_gcal_event(
            $ical_event, $gcal_events{$ical_uid}, $feed_url_hash
        );
        my $ical_uid = $ical_event->properties->{uid}[0]->value;
        my $method = exists $gcal_events{ $ical_uid } 
            ? 'update_entry' : 'add_entry';

        $gcal->$method($gcal_event)
            or warn "Failed to $method for $ical_uid";
    }
}


# Given an iCal event hash (from iCal::Parser) (and possibly a
# Net::Google::Calender event object to update), return an appropriate Google
# Calendar event object (either the one given, after updating it, or a newly
# populated one)
# Note: does not actually add/update the event on the calendar, just returns the
# event object.
sub ical_event_to_gcal_event {
    my ($class, $ical_event, $gcal_event, $feed_url_hash) = @_;
    
    if (!blessed($ical_event)  || !$ical_event->isa('Data::ICal::Entry::Event')) {
        die "Given invalid iCal event";
    }
    if (defined $gcal_event && (!blessed($gcal_event) ||
        !$gcal_event->isa('Net::Google::Calendar::Event')))
    {
        die "Given invalid Google Calendar event - what is it?";
    }

    $gcal_event ||= Net::Google::Calendar::Entry->new;

    my $ical_uid = get_ical_field($ical_event, 'uid');
    $gcal_event->title(    get_ical_field($ical_event, 'summary'  )  );
    $gcal_event->location( get_ical_field($ical_event, 'location' )  );
    $gcal_event->when( 
        get_ical_field($ical_event, 'dtstart'),
        get_ical_field($ical_event, 'dtend'),
    );
    $gcal_event->content("[ical_imported_uid:$feed_url_hash/$ical_uid]");

    return $gcal_event;
}

# Wrap the nastyness of Data::ICal::Property stuff away
sub get_ical_field {
    my ($ical_event, $field) = @_;
    my $value;

    if (!blessed($ical_event) || !$ical_event->isa('Data::ICal::Entry::Event')) {
        die "get_ical_field called without iCal event (got [$ical_event])";
    }

    my $properties = $ical_event->properties;
    if (my $prop = $properties->{$field}) {
        $value = $prop->[0]->value;
    }

    # Auto-inflate dtstart/dtend properties into DateTime objects
    if ($field =~ /^dt(start|end)$/ && $value) {
        my $dt = DateTime::Format::ISO8601->parse_datetime($value)
            or die "Failed to parse '$value' into a DateTime object!";
        my $tz = $properties->{$field}[0]{'_parameters'}{TZID};
        warn "Timezone for $field is '$tz'";
        # TODO: if we didn't find a timezone, should we bail, or just leave the
        # DT object in the flatong timezone and hope for the best?
        if ($tz) {
            $dt->set_time_zone($properties->{$field}[0]{'_parameters'}{TZID});
        }
        $value = $dt;
    }

    # If we wanted dtend and didn't find a value, but did find a duration, then
    # we can calculate the value for dtend (as that's what we need to provide to
    # Net::Google::Calendar::Entry->when() )
    if ($field eq 'dtend' && !$value && exists $properties->{duration}) {
        my $duration = $properties->{duration}[0]->value;
        my $dur_obj = Date::ICal::Duration->new( ical => $duration );
        my $elements = $dur_obj->as_elements;
        delete $elements->{sign};
        my $dtstart = get_ical_field($ical_event, 'dtstart');
        my $dtend = $dtstart->clone->add(
            map  { $_ => $elements->{$_} } 
            grep { $elements->{$_} } keys %$elements
        );
        warn "Calculated end $dtend from $dtstart + $duration";
        $value = $dtend;
    }


    warn "returning value '$value' for $field";
    return $value;
}

# Allow the Net::Google::Calendar object to be overriden (e.g. for mocked tests)
{
    my $gcal;
    sub gcal_obj {
        my $class = shift;
        if (@_) {
            $gcal = shift;
        }

        return $gcal ||= Net::Google::Calendar->new;
    }
}

1; # That's all, folks!

=head1 AUTHOR

David Precious C<< <davidp@preshweb.co.uk> >>

=head1 BUGS / FEATURE REQUESTS

If you've found a bug, or have a feature request or wish to contribute a patch,
this module is developed on GitHub - please feel free to raise issues or pull
requests against the repo at:
L<https://github.com/bigpresh/Net-Joker-DMAPI>


=head1 LICENSE AND COPYRIGHT

Copyright 2014 David Precious.

This program is free software; you can redistribute it and/or modify it
under the terms of either: the GNU General Public License as published
by the Free Software Foundation; or the Artistic License.

See http://dev.perl.org/licenses/ for more information.

