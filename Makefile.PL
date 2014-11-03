use 5.006;
use strict;
use warnings FATAL => 'all';
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'App::ICalToGCal',
    AUTHOR           => q{David Precious <davidp@preshweb.co.uk>},
    VERSION_FROM     => 'lib/App/ICalToGCal.pm',
    ABSTRACT_FROM    => 'lib/App/ICalToGCal.pm',
    LICENSE          => 'Artistic_2_0',
    PL_FILES         => {},
    EXE_FILES        => [ 'bin/ical-to-gcal' ],
    MIN_PERL_VERSION => 5.010,
    CONFIGURE_REQUIRES => {
        'ExtUtils::MakeMaker' => 0,
    },
    BUILD_REQUIRES => {
        'Test::MockObject' => 0,
        'Test::More' => 0,
    },
    PREREQ_PM => {
        'Net::Google::Calendar' => 0,
        'Net::Netrc' => 0,
        'LWP::UserAgent' => 0,
        'Data::ICal' => 0,
        'Date::ICal::Duration' => 0,
        'DateTime' => 0,
        'DateTime::Format::ISO8601' => 0,
        'Digest::MD5' => 0,
        'Scalar::Util' => 0,
    },
    dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean => { FILES => 'App-ICalToGCal-*' },
);
