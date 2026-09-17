#!/usr/bin/perl
#
# bzt-filter.pl — фильтрует JSON-строки от bz_triage перед отправкой в Graylog.
#
#   - читает JSON Lines со stdin;
#   - удаляет тяжёлые поля (file_content, YARA);
#   - пропускает строки, которые не являются JSON-объектами
#     (bz_triage иногда отдаёт числа/строки в потоке — раньше это ломало
#      фильтр на `delete $data->{...}`);
#   - пишет очищенный JSON в stdout.
#
# $| = 1 отключает буферизацию — критично, когда сообщений мало
# и нужно гарантировать отправку до закрытия nc.
#
use strict;
use warnings;
use JSON::PP;

$| = 1;

my @drop_fields = qw(
    file_content
    file_yara_scope
    file_yara_status
    file_yara_matches
);

while (my $line = <STDIN>) {
    chomp $line;
    next unless $line =~ /\S/;

    my $data = eval { decode_json($line) };
    if ($@) {
        print STDERR "bzt-filter: skip invalid json: $@";
        next;
    }

    # Строки/числа в потоке — пропускаем без ошибок
    next unless ref($data) eq 'HASH';

    delete $data->{$_} for @drop_fields;

    print encode_json($data), "\n";
}

exit 0;
