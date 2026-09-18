#!/usr/bin/perl
use strict;
use warnings;
use JSON::PP;

$| = 1;

my @drop_fields = qw(file_content file_yara_scope file_yara_status file_yara_matches);

while (my $line = <STDIN>) {
    chomp $line;
    next unless $line =~ /\S/;

    my $data = eval { decode_json($line) };
    if ($@) {
        print STDERR "bzt-filter: skip invalid json: $@";
        next;
    }
    next unless ref($data) eq 'HASH';

    delete $data->{$_} for @drop_fields;
    print encode_json($data), "\n";
}
exit 0;
