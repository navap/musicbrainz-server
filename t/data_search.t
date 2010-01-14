#!/usr/bin/perl
use strict;
use warnings;
use HTTP::Response;
use Test::More;
use Test::Moose;
use MusicBrainz::Server::Context;
use MusicBrainz::Server::Test;
use Test::Mock::Class ':all';

use_ok 'MusicBrainz::Server::Data::Search';

sub load_data
{
    my ($type) = @_;

    return MusicBrainz::Server::Data::Search->new()->external_search(
            MusicBrainz::Server::Test->create_test_context(), 
            $type, 
            'love',  # "Love" always has tons of hits
            25,      # items per page
            0,       # paging offset
            0,       # advanced search
            MusicBrainz::Server::Test::mock_search_server($type)
    );
}

MusicBrainz::Server::Test->prepare_test_server();

my $data = load_data('artist');

is ( @{$data->{results} }, 25 );

my $artist = $data->{results}->[0]->{entity};

ok ( defined $artist->name );
is ( $artist->name, 'Love' );
is ( $artist->sort_name, 'Love' );
is ( $artist->comment, 'folk-rock/psychedelic band' );
is ( $artist->gid, '34ec9a8d-c65b-48fd-bcdd-aad2f72fdb47' );
is ( $artist->type->name, 'group' );



$data = load_data('release-group');

is ( @{$data->{results} }, 25 );

my $release_group = $data->{results}->[0]->{entity};

ok ( defined $release_group->name );
is ( $release_group->name, 'Love' );
is ( $release_group->gid, '1b545f10-b62e-370b-80fc-dba87834836b' );
is ( $release_group->type->name, 'single' );
is ( $release_group->artist_credit->names->[0]->artist->name, 'Anouk' );
is ( $release_group->artist_credit->names->[0]->artist->sort_name, 'Anouk' );
is ( $release_group->artist_credit->names->[0]->artist->gid, '5e8da504-c75b-4bf5-9dfc-119057c1a9c0' );
is ( $release_group->artist_credit->names->[0]->artist->comment, 'Dutch rock singer' );



$data = load_data('release');

is ( @{$data->{results} }, 25 );

my $release = $data->{results}->[0]->{entity};

is ( $release->name, 'LOVE' );
is ( $release->gid, '64ea1dca-db9a-4945-ae68-78e02a27b158' );
is ( $release->script->iso_code, 'latn' );
is ( $release->language->iso_code_3t, 'eng' );
is ( $release->artist_credit->names->[0]->artist->name, 'HOUND DOG' );
is ( $release->artist_credit->names->[0]->artist->sort_name, 'HOUND DOG' );
is ( $release->artist_credit->names->[0]->artist->gid, 'bd21b7a2-c6b5-45d6-bdb7-18e5de8bfa75' );
is ( $release->mediums->[0]->tracklist->track_count, 9 );




$data = load_data('recording');

is ( @{$data->{results} }, 25 );

my $recording = $data->{results}->[0]->{entity};
my $extra = $data->{results}->[0]->{extra};

is ( $recording->name, 'Love' );
is ( $recording->gid, '701d080c-e2c4-4aca-930e-212960bda76e' );
is ( $recording->length, 236666 );
is ( $recording->artist_credit->names->[0]->artist->name, 'Sixpence None the Richer' );
is ( $recording->artist_credit->names->[0]->artist->sort_name, 'Sixpence None the Richer' );
is ( $recording->artist_credit->names->[0]->artist->gid, 'c2c70ed6-5f10-445c-969f-2c16bc9a4c2e' );

ok ( defined $extra );
is ( @{$extra}, 3 );
is ( $extra->[0]->release_group->type->name, "album" );
is ( $extra->[0]->name, "Sixpence None the Richer" );
is ( $extra->[0]->gid, "24efdbe1-a15d-4cc0-a6d7-59bd1ebbdcc3" );
is ( $extra->[0]->mediums->[0]->tracklist->tracks->[0]->position, 10 );
is ( $extra->[0]->mediums->[0]->tracklist->track_count, 12 );


$data = load_data('label');

is ( @{$data->{results} }, 25 );
my $label = $data->{results}->[0]->{entity};

is ( $label->name, 'Love Records' );
is ( $label->sort_name, 'Love Records' );
is ( $label->comment, 'Finnish label' );
is ( $label->gid, 'e24ca2f9-416e-42bd-a223-bed20fa409d0' );
is ( $label->type->name, 'production' );



$data = load_data('annotation');
is ( @{$data->{results} }, 25 );

my $annotation = $data->{results}->[0]->{entity};
is ( $annotation->parent->name, 'Priscilla Angelique' );
is ( $annotation->parent->gid, 'f3834a4c-5615-429e-b74d-ab3bc400186c' );
is ( $annotation->text, "<p>Soul Love</p>\n" );



$data = load_data('cdstub');

is ( @{$data->{results} }, 25 );
my $cdstub = $data->{results}->[0]->{entity};

is ( $cdstub->artist, 'Love' );
is ( $cdstub->discid, 'BsPKnQO8AqLGwGV4_8RuU9cKYN8-' );
is ( $cdstub->title,  'Out Here');
is ( $cdstub->barcode, '1774209312');
is ( $cdstub->track_count, '17');



$data = load_data('freedb');

is ( @{$data->{results} }, 25 );
my $freedb = $data->{results}->[0]->{entity};

is ( $freedb->artist, 'Love' );
is ( $freedb->discid, '2a123813' );
is ( $freedb->title,  'Love');
is ( $freedb->category, 'misc');
is ( $freedb->year, '');
is ( $freedb->track_count, '19');
done_testing;

1;
