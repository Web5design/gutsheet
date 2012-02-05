package gutsheet;
use Dancer ':syntax';
use JSON qw/encode_json/;
use Spreadsheet::Read;
use DateTime::Format::Excel;
use Text::CSV_XS;
use LWP::UserAgent;
use IO::Scalar;

our $VERSION = '0.1';

get '/' => sub {
    template 'index';
};

post '/to/json' => sub {
    my $data = eval { parse_sheet() };
    if ($@) {
        status 'bad_request';
        return "Error parsing the spreadsheet data: $@";
    }
    return gut_response('application/json' => encode_json $data);
};

post '/to/csv' => sub {
    my $data = eval { parse_sheet() };
    if ($@) {
        status 'bad_request';
        return "Error parsing the spreadsheet data: $@";
    }
    my $str;
    eval { 
        header 'Content-Type' => 'text/csv';
        my $csv = Text::CSV_XS->new;
        my @headers = map { $_->{name} } @{ $data->{headers} };
        $csv->combine(@headers );
        $str = $csv->string . "\n";
        for my $row (@{ $data->{rows} }) {
            $csv->combine(map { $row->{$_} } @headers);
            $str .= $csv->string . "\n";
        }
    };
    if ($@) {
        status 'bad_request';
        return "Error composing CSV: $@";
    }
    return gut_response('text/csv' => \$str);
};

sub gut_response {
    my ($ct, $body) = @_;
    if (my $url = request->header('X-callback')) {
        my $ua = LWP::UserAgent->new(agent => "gutsheet-$VERSION");
        my $resp = $ua->post($url, 'Content-Type' => $ct, Content => $body);
        header 'Content-Type' => 'text/plain';
        if ($resp->is_success) {
            return "KTHX";
        }
        return "ONOES: " . $resp->status_line;
    }
    header 'Content-Type' => 'application/json';
    return $body;
}


sub parse_sheet {
    my $body = request->body;
    my $is_csv = $body =~ m/^"?[\w\d_\-]+"?,/ ? 1 : 0;
    my $data = ReadData(IO::Scalar->new(\$body),
        ($is_csv ? (parser => 'csv') : ()),
        # Control the generation of named cells ("A1" etc)
        cells => 0,
        # Control the generation of the {cell}[c][r] entries
        rc    => 1,
        # Remove all trailing lines and columns that have no visual data
        clip  => 1,
    );
    die "Couldn't parse spreadsheet data!" unless $data;

    # This is hardcoded to only extract the first sheet.
    my $cells = $data->[1]{cell};
    shift @$cells; # 0 col is empty
    my ($headers, $start_row, $row_max) = extract_headers($cells);

    # Now pivot the table from Col/Row to Row/Col
    my @rows;
    for my $i (0 .. $row_max) {
        my %row;
        my $c = 0;
        for my $col (@$cells) {
            my $header = $headers->[$c++]->{name};
            my $val = shift @$col;
            if ($val and $header =~ m/date|time/i and $val =~ m/^\d+$/) {
                my $dt = DateTime::Format::Excel->parse_datetime($val);
                $val = $dt->iso8601;
            }
            $row{$header} = $val;
        }
        push @rows, \%row;
    }
    $data = {
        headers => $headers,
        rows => \@rows,
    };
}

sub extract_headers {
    my $cells = shift;
    my $starting_row = shift || 0;
    my $row_max = $starting_row;
    my @headers;
    my $default_name = "A";
    my $found_a_header = 0;
    for my $col (@$cells) {
        my $name = shift(@$col);
        if ($name) {
            $found_a_header++;
        }
        else {
            $name = "Column $default_name";
        }
        $default_name++;
        push @headers, { name => $name };
        $row_max = @$col if $row_max < @$col;
    }
    return extract_headers($cells, $starting_row+1) unless $found_a_header;

    return \@headers, $starting_row, $row_max;
}

true;
