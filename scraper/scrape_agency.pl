use strict;
use Agency;
use Exception::Class;
use Getopt::Attribute;

$| = 1; # turn on autoflush;

our $force : Getopt(force 0);
our $cache : Getopt(cache 0); #use WWW::Mechanize::Cached
our $all : Getopt(all); 	

my $agency_name = shift @ARGV;
my $agency;

if ( $all ) {
    my $iter = Agency->get_iter({cache_on=>$cache});
    while ( my $agency = $iter->() ) {
        eval {
            $agency->scrape_to_csv(force=>$force);
        };
        if ( my $e = Exception::Class->caught('Agency::Exception::AlreadyScraped') ) {
            print $e->error() . " Skipping to next agency\n";
            next;
        }
    	elsif ( my $e = Exception::Class->caught('Agency::Exception') ) {
    	    print $e->error() . "\n";
    	    next;
    	}
    }
    exit 0;
}


eval {
    $agency = Agency->new_from_yml($agency_name, {cache_on=>$cache});
};
if ( my $e = Exception::Class->caught() ) {
    die $e->error() . "\n";
}
print "Going to scrape " . $agency->{agency_name} . "\n";
eval {
    $agency->scrape_to_csv(force=>$force);
};
if ( my $e = Exception::Class->caught() ) {
    die $e->error() . "\n";
}
