package Agency;

use strict;
use Carp qw/cluck/;
use HTML::TokeParser;
use HTML::TableExtract;
use WWW::Mechanize::Cached;
use WWW::Mechanize::Plugin::Retry;
#use MechanizePluginAgency;
use WWW::Mechanize::Pluggable;
use WWW::Mechanize;
use Cache::FileCache;
use WWW::Mechanize::Link;
use Text::CSV_XS;
use Data::Dumper;
use FileHandle;
use YAML::XS qw/LoadFile/;
use Log::Log4perl;
use HTML::Entities ();
use File::stat;
use DateTimeX::Easy;
use HTML::TreeBuilder::XPath;
use Exception::Class 
    ( 'Agency::Exception',
      'Agency::Exception::AlreadyScraped',
      'Agency::Exception::NothingNewToScrape',
      );

Log::Log4perl::init("$ENV{GOAT_HOME}/scraper/log.conf");
our $logger = Log::Log4perl->get_logger();

use constant AGENCIES_YML => "$ENV{GOAT_HOME}/scraper/agencies.yaml";

$| = 1; # turn on autoflush;

sub new { 
    my ($class, $args) = @_;
    my $self = {};
    
    # agency short name
    $self->{alias} = $args->{alias};
    
    # developer notes for the agency
    $self->{notes} = $args->{notes};
    
    # the starting url for WWW::Mechanize
    $self->{start_url} = $args->{start_url};
    
    # optional array of urls; each element is a link to a list of contracts.
    # if contracts_links is specified, start_url is ignored
    $self->{contracts_links} = $args->{contracts_links};
    
    # whether there is a printable version of the list of contracts
    $self->{printable_version} = $args->{printable_version};
    
    # the url_regex for the quarter links
    $self->{quarter_links_url_regex} = $args->{quarter_links_url_regex};
    
    # the url_regex for the pagination links, if any
    $self->{pagination_link_url_re} = $args->{pagination_link_url_re};
    $self->{pagination_link_text_re} = $args->{pagination_link_text_re};
        
    # headers for the table of contracts, used by HTML::TableExtract
    $self->{headers} = $args->{headers};
    
    # fallback headers for the table of contracts, used by HTML::TableExtract
    $self->{headers_fallback} = $args->{headers_fallback} || $self->{headers};
    
    # the column number (starting from 0) that contains the link to the entity details, usually 2nd column
    $self->{entity_link_column} = defined $args->{entity_link_column} ? $args->{entity_link_column} : 1;
    
    # ordered column names of the Entity, used to create the CSV file
    $self->{entity_keys} = $args->{entity_keys};
    
    # regex to match a unique part of the entity url
    $self->{entity_url_key_re} = $args->{entity_url_key_re};
    
    # the args to pass to HTML::TableExtract for locating the html table of the entity
    $self->{entity_table_constraints} = $args->{entity_table_constraints};
    
    # a way to parse a table using xpath 
    $self->{entity_row_xpath} = $args->{entity_row_xpath};

    $self->{entity_attribute_class} = $args->{entity_attribute_class};
    $self->{entity_value_class} = $args->{entity_value_class};
    
    # the agency name. eg., Parks Canada
    $self->{agency_name} = $args->{agency_name};
    
    $self->{debug} = $args->{debug};
    bless $self, $class;
    return $self;
}

#ARGS: 
# - agency name or alias
sub new_from_yml {
    my ($class, $agency_name) = @_;
    
    my $config = LoadFile(AGENCIES_YML);
    my $agency_config = $config->{$agency_name};
    my $agency;
    if ( $agency_config ) {
        $agency_config->{agency_name} = $agency_name;
        $agency = $class->new($agency_config);
    } else {
        # try by alias
        $agency = $class->new_from_yml_alias($agency_name);
    }
    
    unless ( $agency ) {
        # find closest matches by alias and report
        my @matches = ();
        my $agency_iter = $class->get_iter();
        while ( my($agency) = $agency_iter->() ) {
            if ( $agency->{alias} =~ $agency_name ) {
                push @matches, "$agency->{alias} - $agency->{agency_name}";
            }
        }
        my $message = "Could not find an agency for input '$agency_name'.\n";
        if ( @matches ) {
            $message .= "Did you mean one of these?\n";
            $message .= join("\n", @matches);
            $message .= "\n";
        } else {
            
        }
        Agency::Exception->throw(error=>$message);
    }
    return $agency;
}

#ARGS:
# - agency alias
sub new_from_yml_alias {
    my ($class, $agency_alias) = @_;
    #XXX should be refactored into a Agency::Factory
    my $agency_iter = $class->get_iter();
    while ( my($agency) = $agency_iter->() ) {
        if ( $agency->{alias} eq $agency_alias ) {
            return $agency;
        }
    }
    return;
}

# return an iterator of Agency objects
sub get_iter {
    my ($class) = @_;
    my $config = LoadFile(AGENCIES_YML);
    my @agency_names = keys %$config;
    return sub {
        my $agency_name = shift @agency_names or return;
        my $agency_config = $config->{$agency_name};
        $agency_config->{"agency_name"} = $agency_name;
        return $class->new($agency_config);
    }
}

sub get_csv_filename {
    my $self = shift;
    my $filename = $self->{agency_name};
    $filename =~ s/\s/_/g;
    $filename = lc $filename;
    $filename .= '_contracts.csv';
    $filename = "$ENV{GOAT_HOME}/scraper/csv/$filename";
    return $filename;
}

sub scrape_to_csv {
    my $self = shift;
    my (%args) = @_;
    

#   if ( !$self->has_newer_records() && !$args{force} ) {
#       Agency::Exception::NothingNewToScrape->throw(error=>"There are no new records to scrape");
#   }
    
    my $filename = $self->get_csv_filename();
    my $stat = stat($filename);
    Agency::Exception::AlreadyScraped->throw(error=>"$filename exists. Move it out of the way and try again.") 
        if -e $filename && $stat->size() > 0;
    
    open my $csv_fh, ">:utf8", "$filename" or die "$filename: $!";
    $csv_fh->autoflush(1);
    my $csv = Text::CSV_XS->new({
                    binary=>1, # support french accents etc.
                    });
    my @iters = $self->scrape();
    foreach my $iter ( @iters ) {
        while ( defined(my $contract = $iter->()) ) {
            my @contract_values = map { $contract->{$_} } @{$self->{entity_keys}};
            if ( $csv->combine(@contract_values) ) {
                my $string = $csv->string();
                print $csv_fh "$string\n";
            }
            else {
                my $err = $csv->error_input();
                $logger->error("combine () failed on argument: $err");
            }
        }
    }
    $csv_fh->close();
}

# get the latest contract and see if it is newer than the latest we have on disk
sub has_newer_records {
    my $self = shift;
    
    my $contract_date_csv = $self->get_latest_contract_date_from_csv();
    my $contract_date = $self->get_latest_contract_date();
    print "contract_date_csv = $contract_date_csv, contract_date = $contract_date";
}

sub get_latest_contract_date_from_csv {
    my $self = shift;
    
    my $filename = $self->get_csv_filename();
    return undef unless -e $filename;
    open my $fh, $filename or return undef;
    chomp(my $first_line = <$fh>);
    close $fh;
    
    my $csv = Text::CSV_XS->new({
                    binary=>1, # support french accents etc.
                    });
    my $status = $csv->parse($first_line);
    my @columns = $csv->fields();
    # contract_date is 4th column
    my $contract_date = $columns[4];
    return $contract_date;
}

sub get_latest_contract_date {
    my $self = shift;
    
    my @iters = $self->scrape();
    # assume first one is most recent
    my $iter = shift @iters;
    my $contract = $iter->();
    return $contract->{"contract date"};
}

sub scrape {
    my $self = shift;
    
    my $retry = WWW::Mechanize::Plugin::Retry->new();
    $retry->retry(5, 10, 30, 60, 120, 240);

	#my $getter = WWW::Mechanize::Plugin::Agency->new({ agency_alias=>$self->{alias} });

    $self->{mech} = WWW::Mechanize::Cached->new(
        agent=>'Mozilla/5.0 (Macintosh; U; Intel Mac OS X; en-US; rv:1.8.1.13) Gecko/20080311 Firefox/2.0.0.13',
        stack_depth=>1, #  reduce memory usage: don't keep history of urls visited
		cache=>Cache::FileCache->new( { cache_root => "$ENV{GOAT_HOME}/scraper/tmp/FileCache" } ),
        );
    
    $logger->info("starting scrape of $self->{agency_name}");
    # get lists of contracts
    my @contract_links = $self->get_contract_links();
    my @iters = ();
    foreach my $link ( @contract_links ) {
		my $url = $link->url_abs();
		$url = $self->_fixup_agr_url($url);
        $logger->info("following link to " . $link->text() . " (url: $url)\n");
        $self->{mech}->get($url);
        if ( $self->{printable_version} ) {
            $self->{mech}->follow_link(text_regex=>qr/Printable Version/i);
        }
        if ( $self->{pagination_link_url_re} ) {
            my @more_contract_links = $self->parse_pagination_links();
            push @contract_links, @more_contract_links;
        }
        my $contract_iter = $self->parse_contracts($self->{mech}->{content});
        push @iters, $contract_iter;
    }
    return @iters;
}

sub get_contract_links {
    my $self = shift;
    
    my @links = ();
    if ( $self->{contracts_links} ) {
        @links = map { WWW::Mechanize::Link->new({url=>$_->{url}, tag=>'a', text=>$_->{text}}) } 
                    @{ $self->{contracts_links} };
    }
    else {
        $logger->info("getting $self->{start_url}");
        $self->{mech}->get($self->{start_url});
        #   if ( $self->{mech}->find_link(text_regex=>qr/Reports/) ) {
        #       $logger->info("following link to Reports");
        #       $self->{mech}->follow_link(text_regex=>qr/Reports/);
        #   }
        if ( $self->{quarter_links_url_regex} ) {
            @links = $self->{mech}->find_all_links(url_regex=>qr/$self->{quarter_links_url_regex}/i);
        }
        else {
            @links = $self->{mech}->find_all_links(text_regex=>qr/Quarter/i);
        }
    }
    return @links;
}

sub parse_pagination_links {
    my $self = shift;
    
    my @links = ();
    
    # don't parse if we are on a pagination url
    my $current_url = $self->{mech}->uri();
    $logger->debug("current_url is $current_url");
    return @links if $self->{found_pagination_urls}->{$current_url};
    
    @links = $self->{mech}->find_all_links(url_regex=>qr/$self->{pagination_link_url_re}/,
                                                text_regex=>qr/$self->{pagination_link_text_re}/);
    my $links_pretty = join ", ", map { $_->text() } @links;
    $logger->debug("pagination links: $links_pretty") if @links;

    # exclude links we already found before. (keep links that we haven't found before)
    #@links = grep { !exists $self->{found_pagination_urls}->{ $_->url() } } @links;
    #$links_pretty = join ", ", map { $_->text() } @links;
    #$logger->debug("pagination links after grep found_pagination_urls: $links_pretty") if @links;
    
    # keep track of found pagination urls so that we don't follow them repeatedly
    $self->{found_pagination_urls}->{ $_->url_abs() }++ for @links;
    $logger->debug(Dumper $self->{found_pagination_urls});
    
    # stringify links for logging
    $links_pretty = join ", ", map { $_->url() } @links;
    $logger->info("found pagination links: $links_pretty") if @links;
    
    return @links;
}


sub _parse_entity_link {
	my ($self, $link_cell) = @_;
	my $parser = HTML::TokeParser->new(\$link_cell);
	my $token = $parser->get_tag('a');
	my $attrs = $token->[1];
	my $url = $attrs->{"href"};
	#$link_cell =~ s/[\n\r]//g;
	#my ($url) = $link_cell =~ /a .+? href\s*?=\s*?["']? (.+?) ["'\>]/xi;  # some links aren't quoted at all
	return $url;
}

sub parse_contract_urls {
    my $self = shift;
    my $html = shift;
    my $te;
    foreach my $headers ( $self->{headers}, $self->{headers_fallback} ) {
        # we need to keep_html because we're going to parse the link url
        $te = HTML::TableExtract->new( headers=>$headers, decode => 0, keep_html => 1, strip_html_on_match => 1, debug => $self->{debug} );
        $te->parse($html);
        last if $te->first_table_found();
    }
    unless ( $te->first_table_found() ) {
        $logger->error("no tables were matched for headers or headers_fallback");
    }
    
    my @urls = ();
    foreach my $ts ( $te->tables() ) {
        foreach my $row ( $ts->rows() ) {
            my $url;
            my $link_cell = $row->[$self->{entity_link_column}];
			$logger->debug("link_cell = $link_cell");
            if ( $url = $self->_parse_entity_link($link_cell) ) {
				$logger->debug("parsed url $url out of entity_link_column");
            }
            else {
                $logger->warn("failed to parse url to entity details out of column # $self->{entity_link_column}. "
                    . "cell contents: $link_cell");
            }

            if ( $url ) {
				$url = WWW::Mechanize::Link->new({url=>$url, tag=>'a', text=>'nada', base=>$self->{mech}->base()});
                $url = $self->_fixup_contract_link($url);
                push @urls, $url;
            }
        }
    }
    
    # if no urls found, try matching the whole page for a link regex
    unless ( @urls ) {
        $logger->info("no urls found using entity_link_column method, falling back to entity_url_key_re");
        if ( $self->{entity_url_key_re} ) {
            my $links = $self->{mech}->find_all_links(url_regex=>qr/$self->{entity_url_key_re}/);
            @urls = map { $self->_fixup_contract_link($_) } @$links;
        }
    }
    
    return \@urls;
}

sub parse_contracts {
    my $self = shift;
    my $html = shift;
    my $urls = $self->parse_contract_urls($html);

    return sub {
        while ( my $url = shift @$urls ) {
            my $contract = undef;
            if ( $url ) {
				$logger->debug("going to get a contract at " . $url->url_abs());
                $self->{mech}->get($url->url_abs());
                if ( $self->{mech}->success() ) {
					$logger->info("parsing uri " . $self->{mech}->uri());
					$contract = $self->parse_contract($self->{mech}->content(), $self->{mech}->uri());
				}
				else {
                    $logger->error("Failed to get url " . $url->url_abs()
                        . ", skipping to next one. HTTP status code was: " 
                        . $self->{mech}->status());
                }
                $self->{mech}->back(); # our history stack depth is 1 so we can go back once
            }
            if ( !$contract ) {
                $logger->error("parsing url " . $url->url_abs() . ": no contract could be parsed, skipping to next one");
                next;
            }
            return $contract;
        }
        return;
    }
}

#XXX this needs a proper name or a different namespace 
# parse a space (Canadian Space Agency) type contract out of a div based html table.
# eg. 
# <div class="$entity_attribute_class">Description of Work:</div>
# <div class="$entity_value_class">OTHER PROFESSIONAL SERVICES </div>
# </div>
sub parse_space_contract_via_xpath {
    my $self = shift;
    my $html = shift;
    my $uri = shift;
    
    my $p = HTML::TreeBuilder::XPath->new();
    $p->parse_content($html);
    my @attributes =  map { $_->getValue() } $p->findnodes(qq{//div[\@class="$self->{entity_attribute_class}"]});
    my @values =  map { $_->getValue() } $p->findnodes(qq{//div[\@class="$self->{entity_value_class}"]});
    #print Dumper \@list;
    # turn the list of key/value pairs into a list of lists
    my @lol = ();
    while ( @attributes ) {
		my @cols = ();
        push @cols, shift @attributes;
        push @cols, shift @values;
        push @lol, \@cols;
    }
    return @lol;
}


# parse a contract out of a div based html table.
# eg. 
# <div class="row">
# <div class="cols2">Description of Work:</div>
# <div class="cols2">OTHER PROFESSIONAL SERVICES </div>
# </div>
sub parse_contract_via_xpath {
    my $self = shift;
    my $html = shift;
    my $uri = shift;
    
    my $entity_row_xpath = $self->{entity_row_xpath};
    
    my $p = HTML::TreeBuilder::XPath->new();
    $p->parse_content($html);
    my @list =  map { $_->getValue() } $p->findnodes($entity_row_xpath);
    #print Dumper \@list;
    # turn the list of key/value pairs into a list of lists
    my @lol = ();
    while ( @list ) {
        my @cols = splice @list, 0, 2;
        push @lol, \@cols;
    }
    return @lol;
}

# useful for finding which depth/count a table is at
sub find_table {
    my $self = shift;
    my $html = shift;
    my $te = HTML::TableExtract->new( decode=>0, keep_html=>0 );
    $te->parse($html);
    # Examine all matching tables
    foreach my $ts ($te->tables) {
      print "Table (", join(',', $ts->coords), "):\n";
      foreach my $row ($ts->rows) {
         print join(',', @$row), "\n";
      }
    }
}

# ARGS: html
# RETURN: depth, count, matching key of the contract table.
# loop through all the tables in the given html and look for a key containing string 'vendor'. 
# that's probably the contract table.
sub find_contract_table {
    my $self = shift;
    my $html = shift;
    my $te = HTML::TableExtract->new( decode=>1, keep_html=>0, debug=>$self->{debug} );
    $te->parse($html);
    # Examine all tables
    my $key = '';
    my @coords = (undef, undef);
    MAIN: foreach my $ts ($te->tables) {
        foreach my $row ($ts->rows) {
            $key = $row->[0];
            if ( $key && $key =~ /vendor/i ) {
                @coords = $ts->coords();
                last MAIN;
            }
        }
    }
    return @coords, $key;
}

sub parse_contract_via_tableextract {
    my ($self, $html, $uri) = @_;
    
    my %entity_table_constraints = ();
    if ( $self->{entity_table_constraints} ) {
        %entity_table_constraints = %{$self->{entity_table_constraints}};
    }
    else {
        my ($depth, $count) = $self->find_contract_table($html);
        unless ( defined $depth && defined $count ) {
            $logger->error("No contract table found in $uri");
            return;
        }
        %entity_table_constraints = ( depth => $depth, count => $count );
    }
    
    #print "html is $html\n";
    #$html =~ /Reference number/i or return;
    #print "constructing HTML::TableExtract with constraints: " . Dumper $self->{entity_table_constraints};
    
	# decode=>1 runs HTML::Entities::decode_entities. Later we run encode_entities. This is to prevent double encoding entities.
	my $te = HTML::TableExtract->new( decode=>1, keep_html=>0, debug=>$self->{debug}, %entity_table_constraints );
	$te->parse($html);
	unless ( $te->first_table_found() ) {
		$logger->error("No contract table found in $uri");
		return;
	}
	my @rows = $te->rows();
	
	return @rows;
}

sub parse_contract {
    my $self = shift;
    my $html = shift;
    my $uri = shift;
    
    my @rows = ();
    if ( $self->{entity_row_xpath} ) {
        @rows = $self->parse_contract_via_xpath($html, $uri);
    }
	elsif ( $self->{entity_attribute_class} ) {
        @rows = $self->parse_space_contract_via_xpath($html, $uri);
	}
    else {
        @rows = $self->parse_contract_via_tableextract($html, $uri);
    }

    my $contract = {};
    my $nbsp = HTML::Entities::decode_entities('&nbsp;');
    foreach my $row ( @rows ) {
        #print Dumper $row;
        my $key = $row->[0];
        $key =~ s/&nbsp;/ /g;
        $key =~ s/$nbsp/ /g;
        $key =~ s/^\s*//;
        $key =~ s/\s*$//;
        $key =~ s/\s{0,}\:\s{0,}//;
        $key =~ s/[\n\r]/ /g;
        $key =~ s/\*//g; # CSBS has "*Contract Period"
        $key =~ s/\s{2,}/ /; # replace two or more spaces with one space
        my $value = $row->[1] || $row->[2]; #XXX: not sure why it's element 2 for Environment Canada
        if ( $value ) {
            $value =~ s/[\n\r]/ /g;
            $value =~ s/$nbsp/ /g;
            $value =~ s/\s{2,}/ /; # replace two or more spaces with one space
            $value =~ s/^\s*//;
            $value =~ s/\s*$//;
        }
        #print "key=$key, value=$value\n";
        $contract->{lc $key} = HTML::Entities::encode_entities($value);
    }
    #print Dumper $contract;
    
    $contract->{'contract date'} = $self->parse_contract_date($contract->{'contract date'});
    
    #XXX refactor into subclasses?
    # XXX fixup for some contracts of National Parole Board
    if ( exists $contract->{'contrat period'} ) {
        $logger->warn("fixing 'contrat period'");
        $contract->{'contract period'} = delete $contract->{'contrat period'}; # spelling error in some contracts of National Parole Board
    }
    if ( $contract->{'contract period'} && !grep { $_ eq 'contract period' } @{ $self->{entity_keys} } ) {
        $contract->{'contract period / delivery date'} = delete $contract->{'contract period'};
    }
    #XXX fixup for PWGSC
    if ( $contract->{"contract period - from"} ) {
        $contract->{"contract period"} = $contract->{"contract period - from"} . ' to ' . $contract->{"contract period - to"};
    }
    $contract->{"contract period"} = $self->fix_contract_period($contract->{"contract period"});
    
    # fix contract value
    if ( $contract->{"contract value"} ) {
        $contract->{"contract value"} =~ s/\$//g;
        $contract->{"contract value"} =~ s/\s//g;
        $contract->{"contract value"} =~ s/\*//g;
        $contract->{"contract value"} =~ s/,(\d{2})$/.$1/; # 16133,98 => 16133.98
        $contract->{"contract value"} =~ s/,//g;
        # some values are:  $24,969.00(txincl.)
        $contract->{"contract value"} =~ s/[^\d\.]//g;
        $contract->{"contract value"} =~ s/\.$//g;
    }
    
    # extraneous properties (not explicitly in the contract): agency name, uri
    $contract->{"agency name"} = $self->{agency_name};
    $contract->{"uri"} = $uri;
    
    return $contract;
}

sub parse_contract_date {
    my ($self, $dt) = @_;
    return $dt unless $dt;
    
    return DateTimeX::Easy->new($dt)->ymd();
}

sub fix_contract_period {
    my $self = shift;
    my $period = shift;
    # fix contract period
    return $period unless $period;

    $period =~ m/(\d{4}.\d{1,}.\d{1,})   # YYYY-MM-DD or YYYY-M-D
                 .+?              
                 (\d{4}.\d{1,}.\d{1,})  # YYYY-MM-DD or YYYY-M-D
                 /x
                 ||
    $period =~ m/([A-z]{3,}\.\s?\d{1,},\s?\d{4}) # Apr. 1, 2004
                 to
                 ([A-z]{3,}\.\s?\d{1,},\s?\d{4})
                 /x;
    my ($dt1, $dt2) = ($1, $2);
    if ( $dt1 ) {
        $period = "$dt1 to $dt2";
    } else {
        # couldn't match, warn
        $logger->warn("failed to parse contract period: " . $period);
    }

    return $period;
}

sub _fixup_contract_link {
	my ($self, $link) = @_;

	my $url;
	eval {
		$url = $link->url_abs();
	};
	if ( $@ ) {
		cluck $@,  "\n";
	}
	$url = $self->_fixup_contract_url($url);
	my $text = $link->text();
	my $base = $link->base();
	$link = WWW::Mechanize::Link->new({ url=>$url, tag=>'a', text=>$text, base=>$base });
	return $link;
}

sub _fixup_contract_url {
    my $self = shift;
    my $url = shift;

    $url =~ s/[\s\n\r]//g;
    $url =~ s/&amp;/&/g;
    $url =~ s{\\}{/}g; # fixup for National Parole Board

	$url = $self->_fixup_agr_url($url);
    
    return $url;
}

sub _fixup_agr_url {
	my ($self, $url) = @_;

	#XXX hack for Agriculture and Agri-Food Canada
	# transform http://www4.agr.gc.ca:7778/AAFC-AAC/jsp/display-afficher.do?id=1207677963000&lang=e
	# to
	# http://www4.agr.gc.ca:AAFC-AAC/display-afficher.do?id=1207677963000&lang=e
	if ( $self->{alias} eq 'agr' ) {
		$logger->debug("agr gave us url $url");
		$url =~ s{:7778/AAFC-AAC/jsp}{/AAFC-AAC};
	}

	return $url;
}

1;

