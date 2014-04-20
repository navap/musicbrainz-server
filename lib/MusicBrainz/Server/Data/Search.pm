package MusicBrainz::Server::Data::Search;

use strict; use warnings;use Data::Dumper;

use Carp;
use Try::Tiny;
use Moose;
use Class::Load qw( load_class );
use JSON;
use Sql;
use Readonly;
use Data::Page;
use URI::Escape qw( uri_escape_utf8 );
use List::UtilsBy qw( partition_by );
use MusicBrainz::Server::Entity::Annotation;
use MusicBrainz::Server::Entity::Area;
use MusicBrainz::Server::Entity::AreaType;
use MusicBrainz::Server::Entity::ArtistType;
use MusicBrainz::Server::Entity::Barcode;
use MusicBrainz::Server::Entity::Gender;
use MusicBrainz::Server::Entity::ISRC;
use MusicBrainz::Server::Entity::ISWC;
use MusicBrainz::Server::Entity::Label;
use MusicBrainz::Server::Entity::LabelType;
use MusicBrainz::Server::Entity::Language;
use MusicBrainz::Server::Entity::Link;
use MusicBrainz::Server::Entity::LinkType;
use MusicBrainz::Server::Entity::Place;
use MusicBrainz::Server::Entity::Medium;
use MusicBrainz::Server::Entity::MediumFormat;
use MusicBrainz::Server::Entity::Relationship;
use MusicBrainz::Server::Entity::Release;
use MusicBrainz::Server::Entity::ReleaseLabel;
use MusicBrainz::Server::Entity::ReleaseGroup;
use MusicBrainz::Server::Entity::ReleaseGroupType;
use MusicBrainz::Server::Entity::ReleaseGroupSecondaryType;
use MusicBrainz::Server::Entity::ReleaseStatus;
use MusicBrainz::Server::Entity::Script;
use MusicBrainz::Server::Entity::SearchResult;
use MusicBrainz::Server::Entity::WorkType;
use MusicBrainz::Server::Exceptions;
use MusicBrainz::Server::Data::Artist;
use MusicBrainz::Server::Data::Area;
use MusicBrainz::Server::Data::Label;
use MusicBrainz::Server::Data::Recording;
use MusicBrainz::Server::Data::Release;
use MusicBrainz::Server::Data::ReleaseGroup;
use MusicBrainz::Server::Data::Tag;
use MusicBrainz::Server::Data::Utils qw( ref_to_type );
use MusicBrainz::Server::Data::Work;
use MusicBrainz::Server::Constants qw( $DARTIST_ID $DLABEL_ID );
use MusicBrainz::Server::Data::Utils qw( type_to_model );
use MusicBrainz::Server::ExternalUtils qw( get_chunked_with_retry );
use DateTime::Format::ISO8601;
use feature "switch";

no if $] >= 5.018, warnings => "experimental::smartmatch";

extends 'MusicBrainz::Server::Data::Entity';

Readonly my %TYPE_TO_DATA_CLASS => (
    artist        => 'MusicBrainz::Server::Data::Artist',
    area          => 'MusicBrainz::Server::Data::Area',
    label         => 'MusicBrainz::Server::Data::Label',
    place         => 'MusicBrainz::Server::Data::Place',
    recording     => 'MusicBrainz::Server::Data::Recording',
    release       => 'MusicBrainz::Server::Data::Release',
    release_group => 'MusicBrainz::Server::Data::ReleaseGroup',
    work          => 'MusicBrainz::Server::Data::Work',
    tag           => 'MusicBrainz::Server::Data::Tag',
    editor        => 'MusicBrainz::Server::Data::Editor'
);

use Sub::Exporter -setup => {
    exports => [qw( escape_query alias_query )]
};

sub search
{
    my ($self, $type, $query_str, $limit, $offset, $where) = @_;
    return ([], 0) unless $query_str && $type;

    $offset ||= 0;

    my $query;
    my $use_hard_search_limit = 1;
    my $hard_search_limit;
    my $deleted_entity = undef;

    my @where_args;

    if ($type eq "artist" || $type eq "label" || $type eq "area") {

        my $where_deleted = "WHERE entity.id != ?";
        if ($type eq "artist") {
            $deleted_entity = $DARTIST_ID;
        } elsif ($type eq "label") {
            $deleted_entity = $DLABEL_ID;
        } else {
            $where_deleted = "";
        }

        my $extra_columns = '';
        $extra_columns .= 'entity.label_code, entity.area,' if $type eq 'label';
        $extra_columns .= 'entity.gender, entity.area, entity.begin_area, entity.end_area,' if $type eq 'artist';
        $extra_columns .= 'iso_3166_1s.codes AS iso_3166_1, iso_3166_2s.codes AS iso_3166_2, iso_3166_3s.codes AS iso_3166_3,' if $type eq 'area';

        my $extra_groupby_columns = $extra_columns;
        $extra_groupby_columns =~ s/[^ ,]+ AS //g;

        my $extra_joins = '';
        if ($type eq 'area') {
            $extra_joins .= 'LEFT JOIN (SELECT area, array_agg(code) AS codes FROM iso_3166_1 GROUP BY area) iso_3166_1s ON iso_3166_1s.area = entity.id ' .
                            'LEFT JOIN (SELECT area, array_agg(code) AS codes FROM iso_3166_2 GROUP BY area) iso_3166_2s ON iso_3166_2s.area = entity.id ' .
                            'LEFT JOIN (SELECT area, array_agg(code) AS codes FROM iso_3166_3 GROUP BY area) iso_3166_3s ON iso_3166_3s.area = entity.id';
        }

        $query = "
            SELECT
                entity.id,
                entity.gid,
                entity.name,
                entity.comment,
                entity.sort_name,
                entity.type,
                entity.begin_date_year, entity.begin_date_month, entity.begin_date_day,
                entity.end_date_year, entity.end_date_month, entity.end_date_day,
                entity.ended,
                $extra_columns
                MAX(rank) AS rank
            FROM
                (
                    SELECT name, ts_rank_cd(to_tsvector('mb_simple', name), query, 2) AS rank
                    FROM
                        (SELECT name              FROM ${type}       UNION ALL
                         SELECT sort_name AS name FROM ${type}       UNION ALL
                         SELECT name              FROM ${type}_alias UNION ALL
                         SELECT sort_name AS name FROM ${type}_alias) names,
                        plainto_tsquery('mb_simple', ?) AS query
                    WHERE to_tsvector('mb_simple', name) @@ query OR name = ?
                    ORDER BY rank DESC
                    LIMIT ?
                ) AS r
                LEFT JOIN ${type}_alias AS alias ON (alias.name = r.name OR alias.sort_name = r.name)
                JOIN ${type} AS entity ON (r.name = entity.name OR r.name = entity.sort_name OR alias.${type} = entity.id)
                $extra_joins
                $where_deleted
            GROUP BY
                $extra_groupby_columns entity.id, entity.gid, entity.comment, entity.name, entity.sort_name, entity.type,
                entity.begin_date_year, entity.begin_date_month, entity.begin_date_day,
                entity.end_date_year, entity.end_date_month, entity.end_date_day, entity.ended
            ORDER BY
                rank DESC, sort_name, name
            OFFSET
                ?
        ";

        $hard_search_limit = $offset * 2;
    }
    elsif ($type eq "recording" || $type eq "release" || $type eq "release_group") {
        my $extra_columns = "";
        $extra_columns .= 'entity.type AS primary_type_id,'
            if ($type eq 'release_group');

        $extra_columns = "entity.length, entity.video,"
            if ($type eq "recording");

        $extra_columns .= 'entity.language, entity.script, entity.barcode,
                           entity.release_group, entity.status,'
            if ($type eq 'release');

        my $extra_ordering = '';
        $extra_columns .= 'entity.artist_credit AS artist_credit_id,';
        $extra_ordering = ', entity.artist_credit';

        my ($join_sql, $where_sql)
            = ("JOIN ${type} entity ON r.name = entity.name", '');

        if ($type eq 'release' && $where && defined $where->{track_count}) {
            $join_sql .= ' JOIN medium ON medium.release = entity.id';
            $where_sql = 'WHERE medium.track_count = ?';
            push @where_args, $where->{track_count};
        }
        elsif ($type eq 'recording') {
            if ($where && defined $where->{artist})
            {
                $join_sql .= " JOIN artist_credit ON artist_credit.id = entity.artist_credit";
                $where_sql = 'WHERE artist_credit.name LIKE ?';
                push @where_args, "%".$where->{artist}."%";
            }
        }

        $query = "
            SELECT DISTINCT
                entity.id,
                entity.gid,
                entity.comment,
                $extra_columns
                r.name,
                r.rank
            FROM
                (
                    SELECT name, ts_rank_cd(to_tsvector('mb_simple', name), query, 2) as rank
                    FROM ${type},
                        plainto_tsquery('mb_simple', ?) AS query
                    WHERE to_tsvector('mb_simple', name) @@ query OR name = ?
                    ORDER BY rank DESC
                    LIMIT ?
                ) AS r
                $join_sql
                $where_sql
            ORDER BY
                r.rank DESC, r.name
                $extra_ordering
            OFFSET
                ?
        ";

        $hard_search_limit = int($offset * 1.2);
    }

    elsif ($type eq "work" || $type eq "place") {

        my $extra_columns = '';
        $extra_columns .= 'entity.language,' if $type eq 'work';
        $extra_columns .= 'entity.address, entity.area, entity.begin_date_year, entity.begin_date_month, entity.begin_date_day,
                entity.end_date_year, entity.end_date_month, entity.end_date_day, entity.ended,' if $type eq 'place';

        $query = "
            SELECT
                entity.id,
                entity.gid,
                entity.name,
                entity.comment,
                entity.type,
                $extra_columns
                MAX(rank) AS rank
            FROM
                (
                    SELECT name, ts_rank_cd(to_tsvector('mb_simple', name), query, 2) AS rank
                    FROM
                        (SELECT name              FROM ${type}       UNION ALL
                         SELECT name              FROM ${type}_alias UNION ALL
                         SELECT sort_name AS name FROM ${type}_alias) names,
                        plainto_tsquery('mb_simple', ?) AS query
                    WHERE to_tsvector('mb_simple', name) @@ query OR name = ?
                    ORDER BY rank DESC
                    LIMIT ?
                ) AS r
                LEFT JOIN ${type}_alias AS alias ON (alias.name = r.name OR alias.sort_name = r.name)
                JOIN ${type} AS entity ON (r.name = entity.name OR alias.${type} = entity.id)
            GROUP BY
                entity.id, entity.gid, entity.name, entity.comment, $extra_columns entity.type
            ORDER BY
                rank DESC, entity.name
            OFFSET
                ?
        ";

        $hard_search_limit = $offset * 2;
    }

    elsif ($type eq "tag") {
        $query = "
            SELECT id, name, ts_rank_cd(to_tsvector('mb_simple', name), query, 2) AS rank
            FROM tag, plainto_tsquery('mb_simple', ?) AS query
            WHERE to_tsvector('mb_simple', name) @@ query OR name = ?
            ORDER BY rank DESC, tag.name
            OFFSET ?
        ";
        $use_hard_search_limit = 0;
    }
    elsif ($type eq 'editor') {
        $query = "SELECT id, name, ts_rank_cd(to_tsvector('mb_simple', name), query, 2) AS rank,
                    email
                  FROM editor, plainto_tsquery('mb_simple', ?) AS query
                  WHERE to_tsvector('mb_simple', name) @@ query OR name = ?
                  ORDER BY rank DESC
                  OFFSET ?";
        $use_hard_search_limit = 0;
    }

    if ($use_hard_search_limit) {
        $hard_search_limit += $limit * 3;
    }

    my $fuzzy_search_limit = 10000;
    my $search_timeout = 60 * 1000;

    $self->sql->auto_commit;
    $self->sql->do('SET SESSION gin_fuzzy_search_limit TO ?', $fuzzy_search_limit);
    $self->sql->auto_commit;
    $self->sql->do('SET SESSION statement_timeout TO ?', $search_timeout);

    my @query_args = ();
    push @query_args, $hard_search_limit if $use_hard_search_limit;
    push @query_args, $deleted_entity if $deleted_entity;
    push @query_args, @where_args;
    push @query_args, $offset;

    my @result;
    my $pos = $offset + 1;
    my @rows = @{
        $self->sql->select_list_of_hashes($query, $query_str, $query_str, @query_args)
    };

    for my $row (@rows) {
        last unless ($limit--);

        my $res = MusicBrainz::Server::Entity::SearchResult->new(
            position => $pos++,
            score => int(1000 * $row->{rank}),
            entity => $TYPE_TO_DATA_CLASS{$type}->_new_from_row($row)
        );
        push @result, $res;
    }

    my $hits = @rows + $offset;

    return (\@result, $hits);

}

# ---------------- External (Indexed) Search ----------------------

# The XML schema uses a slightly different terminology for things
# and the schema defines how data is passed between the main
# server and the search server. In order to shove the dat back into
# the object model, we need to do some ugly ass tweaking....

# The mapping of XML/JSON centric terms to object model terms.
my %mapping = (
    'disambiguation' => 'comment',
    'sort-name'      => 'sort_name',
    'title'          => 'name',
    'artist-credit'  => 'artist_credit',
    'label-code'     => 'label_code',
);

# Fix up the key names so that the data returned from the JSON service
# matches up with the data returned from the DB for easy object creation
sub schema_fixup
{
    my ($self, $data, $type) = @_;

    return unless (ref($data) eq 'HASH');

    if (defined $data->{id} && $type eq 'freedb')
    {
        $data->{discid} = $data->{id};
        delete $data->{name};
    }

    # Special case to handle the ids
    $data->{gid} = $data->{id};
    $data->{id} = 1;

    # MusicBrainz::Server::Entity::Role::Taggable expects 'tags' to contain an ArrayRef[AggregatedTag].
    # If tags are required in search results they will need to be listed under a different key value.
    delete $data->{tags};

    foreach my $k (keys %mapping)
    {
        if (defined $data->{$k})
        {
            $data->{$mapping{$k}} = $data->{$k} if ($mapping{$k});
            delete $data->{$k};
        }
    }

    if ($type eq 'artist' && defined $data->{type})
    {
        $data->{type} = MusicBrainz::Server::Entity::ArtistType->new( name => $data->{type} );
    }
    if ($type eq 'area' && defined $data->{type})
    {
        $data->{type} = MusicBrainz::Server::Entity::AreaType->new( name => $data->{type} );
    }
    if ($type eq 'place' && defined $data->{type})
    {
        $data->{type} = MusicBrainz::Server::Entity::PlaceType->new( name => $data->{type} );
    }
    if ($type eq 'place' && defined $data->{coordinates})
    {
        $data->{coordinates} = MusicBrainz::Server::Entity::Coordinates->new( $data->{coordinates} );
    }
    if (($type eq 'artist' || $type eq 'label' || $type eq 'area' || $type eq 'place') && defined $data->{'life-span'})
    {
        $data->{begin_date} = MusicBrainz::Server::Entity::PartialDate->new($data->{'life-span'}->{begin})
            if (defined $data->{'life-span'}->{begin});
        $data->{end_date} = MusicBrainz::Server::Entity::PartialDate->new($data->{'life-span'}->{end})
            if (defined $data->{'life-span'}->{end});
        $data->{ended} = $data->{'life-span'}->{ended} eq 'true'
            if defined $data->{'life-span'}->{ended};
    }
    if ($type eq 'area') {
        for my $prop (qw( iso_3166_1 iso_3166_2 iso_3166_3 )) {
            my $json_prop = $prop . '-codes';
            $json_prop =~ s/_/-/g;
            if (defined $data->{$json_prop}) {
                $data->{$prop} = $data->{$json_prop};
                delete $data->{$json_prop};
            }
        }
    }
    if ($type eq 'artist' || $type eq 'label' || $type eq 'place') {
        for my $prop (qw( area begin_area end_area )) {
            my $json_prop = $prop;
            $json_prop =~ s/_/-/;
            if (defined $data->{$json_prop})
            {
                my $area = delete $data->{$json_prop};
                $area->{gid} = $area->{id};
                $area->{id} = 1;
                $data->{$prop} = MusicBrainz::Server::Entity::Area->new($area);
            }
        }
    }
    if($type eq 'artist' && defined $data->{gender}) {
        $data->{gender} = MusicBrainz::Server::Entity::Gender->new( name => ucfirst($data->{gender}) );
    }
    if ($type eq 'label' && defined $data->{type})
    {
        $data->{type} = MusicBrainz::Server::Entity::LabelType->new( name => $data->{type} );
    }
    if ($type eq 'release-group' && defined $data->{'primary-type'})
    {
        $data->{primary_type} = MusicBrainz::Server::Entity::ReleaseGroupType->new( name => $data->{'primary-type'} );
    }
    if ($type eq 'cdstub' && defined $data->{gid})
    {
        $data->{discid} = $data->{gid};
        delete $data->{gid};
        $data->{title} = $data->{name};
        delete $data->{name};
    }
    if ($type eq 'annotation' && defined $data->{entity})
    {
        my $parent_type = $data->{type};
        $parent_type =~ s/-/_/g;
        my $entity_model = $self->c->model( type_to_model($parent_type) )->_entity_class;
        $data->{parent} = $entity_model->new( { name => $data->{name}, gid => $data->{entity} });
        delete $data->{entity};
        delete $data->{type};
    }
    if ($type eq 'freedb' && defined $data->{name})
    {
        $data->{title} = $data->{name};
        delete $data->{name};
    }
    if (($type eq 'cdstub' || $type eq 'freedb')
        && (defined $data->{"count"}))
    {
        if (defined $data->{barcode})
        {
            $data->{barcode} = MusicBrainz::Server::Entity::Barcode->new( $data->{barcode} );
        }

        $data->{track_count} = $data->{"count"};
        delete $data->{"count"};
    }
    if ($type eq 'release')
    {
        if (defined $data->{"release-events"})
        {
            $data->{events} = [];
            for my $release_event_data (@{$data->{"release-events"}})
            {
                my $release_event = MusicBrainz::Server::Entity::ReleaseEvent->new(
                    country => defined($release_event_data->{area}) ?
                        MusicBrainz::Server::Entity::Area->new( gid => $release_event_data->{area}->{id},
                                                                iso_3166_1 => $release_event_data->{area}->{"iso-3166-1-codes"},
                                                                name => $release_event_data->{area}->{name},
                                                                sort_name => $release_event_data->{area}->{'sort-name'} )
                        : undef,
                    date => MusicBrainz::Server::Entity::PartialDate->new( $release_event_data->{date} ));

                push @{$data->{events}}, $release_event;
            }
            delete $data->{"release-events"};
        }
        if (defined $data->{barcode})
        {
            $data->{barcode} = MusicBrainz::Server::Entity::Barcode->new( $data->{barcode} );
        }
        if (defined $data->{"text-representation"} &&
            defined $data->{"text-representation"}->{language})
        {
            $data->{language} = MusicBrainz::Server::Entity::Language->new( {
                iso_code_3 => $data->{"text-representation"}->{language}
            } );
        }
        if (defined $data->{"text-representation"} &&
            defined $data->{"text-representation"}->{script})
        {
            $data->{script} = MusicBrainz::Server::Entity::Script->new(
                    { iso_code => $data->{"text-representation"}->{script} }
            );
        }

        if (defined $data->{'label-info'}) {
            $data->{labels} = [
                map {
                    MusicBrainz::Server::Entity::ReleaseLabel->new(
                        label => $_->{label}->{id} &&
                            MusicBrainz::Server::Entity::Label->new(
                                name => $_->{label}->{name},
                                gid => $_->{label}->{id}
                            ),
                        catalog_number => $_->{'catalog-number'}
                    )
                } @{ $data->{'label-info'}}
            ];
        }

        if (defined $data->{"media"})
        {
            $data->{mediums} = [];
            for my $medium_data (@{$data->{"media"}})
            {
                my $format = $medium_data->{format};
                my $medium = MusicBrainz::Server::Entity::Medium->new(
                    track_count => $medium_data->{"track-count"},
                    format => $format &&
                        MusicBrainz::Server::Entity::MediumFormat->new(
                            name => $format
                        )
                );

                push @{$data->{mediums}}, $medium;
            }
            delete $data->{"media"};
        }

        my $release_group = delete $data->{'release-group'};

        my %rg_args;
        if ($release_group->{'primary-type'}) {
            $rg_args{primary_type} =
                MusicBrainz::Server::Entity::ReleaseGroupType->new(
                    name => $release_group->{'primary-type'}
                );
        }

        if ($release_group->{'secondary-types'}) {
            $rg_args{secondary_types} = [
                map {
                    MusicBrainz::Server::Entity::ReleaseGroupSecondaryType->new(
                        name => $_
                    )
                } @{ $release_group->{'secondary-types'} }
            ]
        }

        $data->{release_group} = MusicBrainz::Server::Entity::ReleaseGroup->new(
            %rg_args
        );

        if ($data->{status}) {
            $data->{status} = MusicBrainz::Server::Entity::ReleaseStatus->new(
                name => delete $data->{status}
            )
        }
    }
    if ($type eq 'recording' &&
        defined $data->{"releases"} &&
        defined $data->{"releases"}->[0] &&
        defined $data->{"releases"}->[0]->{"media"} &&
        defined $data->{"releases"}->[0]->{"media"}->[0])
    {
        my @releases;

        foreach my $release (@{$data->{"releases"}})
        {
            my $medium = MusicBrainz::Server::Entity::Medium->new(
                position  => $release->{"media"}->[0]->{"position"},
                track_count => $release->{"media"}->[0]->{"track-count"},
                tracks => [ MusicBrainz::Server::Entity::Track->new(
                    position => $release->{"media"}->[0]->{"track-offset"} + 1,
                    recording => MusicBrainz::Server::Entity::Recording->new(
                        gid => $data->{gid}
                    )
                ) ]
            );
            my $release_group = MusicBrainz::Server::Entity::ReleaseGroup->new(
                primary_type => MusicBrainz::Server::Entity::ReleaseGroupType->new(
                    name => $release->{"release-group"}->{'primary-type'} || ''
                )
            );
            push @releases, MusicBrainz::Server::Entity::Release->new(
                gid     => $release->{id},
                name    => $release->{title},
                mediums => [ $medium ],
                release_group => $release_group
            );
        }
        $data->{_extra} = \@releases;
    }

    if ($type eq 'recording' && defined $data->{'isrcs'}) {
        $data->{isrcs} = [
            map { MusicBrainz::Server::Entity::ISRC->new( isrc => $_->{id} ) } @{ $data->{'isrcs'} }
        ];
    }

    if ($type eq 'recording') {
        $data->{video} = defined $data->{video} && $data->{video} eq 'true';
    }

    if (defined $data->{"relations"} &&
        defined $data->{"relations"}->[0])
    {
        my @relationships;

        foreach my $rel (@{ $data->{"relations"} })
        {
            # TODO: How do we know what the target is using jsonnew?
            my $entity_type = 'artist';

            my %entity = %{ $rel->{$entity_type} };

            # The search server returns the MBID in the 'id' attribute, so we
            # need to rename that.
            $entity{gid} = delete $entity{id};

            my $entity = $self->c->model( type_to_model ($entity_type) )->
                _entity_class->new (%entity);

            push @relationships, MusicBrainz::Server::Entity::Relationship->new(
                entity1 => $entity,
                link => MusicBrainz::Server::Entity::Link->new(
                    type => MusicBrainz::Server::Entity::LinkType->new(
                        name => $rel->{type}
                    )
                )
            );

        }

        $data->{relationships} = \@relationships;
    }


    foreach my $k (keys %{$data})
    {
        if (ref($data->{$k}) eq 'HASH')
        {
            $self->schema_fixup($data->{$k}, $type);
        }
        if (ref($data->{$k}) eq 'ARRAY')
        {
            foreach my $item (@{$data->{$k}})
            {
                $self->schema_fixup($item, $type);
            }
        }
    }

    if (defined $data->{'artist_credit'} &&
        ref($data->{'artist_credit'}) eq 'ARRAY')       #TODO: Nested AC object in recording>releases>media>track>artist-credit>artist-credit
    {
        my @credits;
        foreach my $namecredit (@{$data->{"artist_credit"}})
        {
            my $artist = MusicBrainz::Server::Entity::Artist->new($namecredit->{artist});
            push @credits, MusicBrainz::Server::Entity::ArtistCreditName->new( {
                    artist => $artist,
                    name => $namecredit->{name} || $artist->{name},
                    join_phrase => $namecredit->{joinphrase} || '' } );
        }
        $data->{'artist_credit'} = MusicBrainz::Server::Entity::ArtistCredit->new( { names => \@credits } );
    }

    if ($type eq 'work') {
        if (defined $data->{relationships}) {
            my %relationship_map = partition_by { $_->entity1->gid }
                @{ $data->{relationships} };

            $data->{writers} = [
                map {
                    my @relationships = @{ $relationship_map{$_} };
                    {
                        entity => $relationships[0]->entity1,
                            roles  => [ map { $_->link->type->name } @relationships ]
                        }
                } keys %relationship_map
            ];
        }

        if(defined $data->{type}) {
            $data->{type} = MusicBrainz::Server::Entity::WorkType->new( name => $data->{type} );
        }

        if (defined $data->{language}) {
            $data->{language} = MusicBrainz::Server::Entity::Language->new({
                iso_code_3 => $data->{language}
            });
        }

        if(defined $data->{'iswcs'}) {
            $data->{iswcs} = [
                map {
                    MusicBrainz::Server::Entity::ISWC->new( iswc => $_ )
                } @{ $data->{'iswcs'} }
            ]
        }
    }
}

# Escape special characters in a Lucene search query
sub escape_query
{
    my $str = shift;

    return "" unless $str;

    $str =~  s/([+\-&|!(){}\[\]\^"~*?:\\\/])/\\$1/g;
    return $str;
}

# add alias/sortname queries for entity
sub alias_query
{
    my ($type, $query) = @_;

    return "$type:\"$query\"^1.6 " .
        "(+sortname:\"$query\"^1.6 -$type:\"$query\") " .
        "(+alias:\"$query\" -$type:\"$query\" -sortname:\"$query\") " .
        "(+($type:($query)^0.8) -$type:\"$query\" -sortname:\"$query\" -alias:\"$query\") " .
        "(+(sortname:($query)^0.8) -$type:($query) -sortname:\"$query\" -alias:\"$query\") " .
        "(+(alias:($query)^0.4) -$type:($query) -sortname:($query) -alias:\"$query\")";
}

sub external_search
{
    my ($self, $type, $query, $limit, $page, $adv, $ua) = @_;

    my $entity_model = $self->c->model( type_to_model($type) )->_entity_class;
    load_class($entity_model);
    my $offset = ($page - 1) * $limit;

    $query = uri_escape_utf8($query);
    $type =~ s/release_group/release-group/;
    my $search_url = sprintf("http://%s/ws/2/%s/?query=%s&offset=%s&max=%s&fmt=jsonnew&dismax=%s",
                                 DBDefs->LUCENE_SERVER,
                                 $type,
                                 $query,
                                 $offset,
                                 $limit,
                                 $adv ? 'false' : 'true',
                                 );
    print $search_url . "\n";

    if (DBDefs->_RUNNING_TESTS)
    {
        $ua = MusicBrainz::Server::Test::mock_search_server($type);
    }
    else
    {
        $ua = LWP::UserAgent->new if (!defined $ua);
    }

    $ua->timeout (5);
    $ua->env_proxy;

    # Dispatch the search request.
    my $response = get_chunked_with_retry($ua, $search_url);
    if (!defined $response) {
        return { code => 500, error => 'We could not fetch the document from the search server. Please try again.' };
    }
    elsif (!$response->is_success)
    {
        return { code => $response->code, error => $response->content };
    }
    elsif ($response->status_line eq "200 Assumed OK")
    {
        if ($response->content =~ /<title>([0-9]{3})/)
        {
            return { code => $1, error => $response->content };
        }
        else
        {
            return { code => 500, error => $response->content };
        }
    }
    else
    {
        my $data;
        try {
            $data = JSON->new->utf8->decode($response->content);
        }
        catch {
            use Data::Dumper;
            croak "Failed to decode JSON search data:\n" .
                  Dumper($response->content) . "\n" .
                  "Exception:\n" . Dumper($_) . "\n" .
                  "Response headers:\n" .
                  Dumper($response->headers->as_string);
        };

        my @results;

        my $xmltype = $type;
        $xmltype =~ s/freedb/freedb-disc/;
        my $pos = 0;
        my $last_updated = $data->{created} ?
            DateTime::Format::ISO8601->parse_datetime($data->{created}) :
            undef;

        # search server bug fixes...
        $xmltype =~ s/annotation/annotations/;
        $xmltype =~ s/area/areas/;
        $xmltype =~ s/cdstub/cdstubs/;
        $xmltype =~ s/freedb-disc/freedb-discs/;
        $xmltype =~ s/label/labels/;
        $xmltype =~ s/place/places/;
        $xmltype =~ s/release$/releases/;
        $xmltype =~ s/release-group/release-groups/;

        foreach my $t (@{$data->{$xmltype}})
        {
            $self->schema_fixup($t, $type);
            push @results, MusicBrainz::Server::Entity::SearchResult->new(
                    position => $pos++,
                    score  => $t->{score},
                    entity => $entity_model->new($t),
                    extra  => $t->{_extra} || []   # Not all data fits into the object model, this is for those cases
                );
        }
        my ($total_hits) = $data->{count};

        # If the user searches for annotations, they will get the results in wikiformat - we need to
        # convert this to HTML.
        if ($type eq 'annotation')
        {
            foreach my $result (@results)
            {
                $result->{type} = ref_to_type($result->{entity}->{parent});
            }
        }

        if ($type eq 'work')
        {
            my @entities = map { $_->entity } @results;
            $self->c->model('Work')->load_ids(@entities);
            $self->c->model('Work')->load_recording_artists(@entities);
        }

        my $pager = Data::Page->new;
        $pager->current_page($page);
        $pager->entries_per_page($limit);
        $pager->total_entries($total_hits);

        return { pager => $pager, offset => $offset, results => \@results, last_updated => $last_updated, raw_data => $data };
        # TODO: Remove raw_data
    }
}

sub unified_search
{
    my ($self, $type, $query, $limit, $adv, $ua) = @_;

    $query = uri_escape_utf8($query);

    my $search_url = sprintf("http://%s/ws/2/%s/?query=%s&max=%s&fmt=jsonnew&dismax=%s",
                                 DBDefs->LUCENE_SERVER,
                                 $type,
                                 $query,
                                 $limit,
                                 $adv ? 'false' : 'true',
                                 );
    print $search_url . "\n";
    if (DBDefs->_RUNNING_TESTS)
    {
        $ua = MusicBrainz::Server::Test::mock_search_server($type);
    }
    else
    {
        $ua = LWP::UserAgent->new if (!defined $ua);
    }

    $ua->timeout (5);
    $ua->env_proxy;

    # Dispatch the search request.
    my $response = get_chunked_with_retry($ua, $search_url);
    if (!defined $response) {
        return { code => 500, error => 'We could not fetch the document from the search server. Please try again.' };
    }
    elsif (!$response->is_success)
    {
        return { code => $response->code, error => $response->content };
    }
    elsif ($response->status_line eq "200 Assumed OK")
    {
        if ($response->content =~ /<title>([0-9]{3})/)
        {
            return { code => $1, error => $response->content };
        }
        else
        {
            return { code => 500, error => $response->content };
        }
    }
    else
    {
        my $data;
        try {
            $data = JSON->new->utf8->decode($response->content);
        }
        catch {
            use Data::Dumper;
            croak "Failed to decode JSON search data:\n" .
                  Dumper($response->content) . "\n" .
                  "Exception:\n" . Dumper($_) . "\n" .
                  "Response headers:\n" .
                  Dumper($response->headers->as_string);
        };

        my $results;

        foreach my $entity (qw(artist label recording release-group work)) {
            my $model_name = $entity;
            $model_name =~ s/release-group/release_group/;
            my $entity_model = $self->c->model( type_to_model($model_name) )->_entity_class;
            load_class($entity_model);

            my @entity_results;

            if (defined $data->{"entity-list"}->{$entity}) {
                foreach my $t (@{$data->{"entity-list"}->{$entity}})
                {
                    if ($t->{score} > 80) {
                        my $pos = 0;
                        $self->schema_fixup($t, $entity);
                        push @entity_results, MusicBrainz::Server::Entity::SearchResult->new(
                                position => $pos++,
                                score  => $t->{score},
                                entity => $entity_model->new($t),
                                extra  => $t->{_extra} || []   # Not all data fits into the object model, this is for those cases
                            );
                    }
                }
            }

            $results->{$entity . 's'} = \@entity_results;
        }

        return { results => $results, raw_data => $data };
        # TODO: Remove raw_data
    }
}

sub combine_rules
{
    my ($inputs, %rules) = @_;

    my @parts;
    for my $key (keys %rules) {
        my $spec = $rules{$key};
        my $parameter = $spec->{parameter} || $key;
        next unless defined $inputs->{$parameter};

        my $input = $inputs->{$parameter};
        next if defined $spec->{check} && !$spec->{check}->($input);

        $input = escape_query($input) if $spec->{escape};
        my $process = $spec->{process} || sub { shift };
        $input = $process->($input);
        $input = join(' AND ', split /\s+/, $input) if $spec->{split};

        my $predicate = $spec->{predicate} || sub { "$key:($input)" };
        push @parts, $predicate->($input);
    }

    return join(' AND ', map { "($_)" } @parts);
}

sub xml_search
{
    my ($self, %options) = @_;

    my $die = sub {
        MusicBrainz::Server::Exceptions::InvalidSearchParameters->throw( message => shift );
    };

    my $query   = $options{query};
    my $limit   = $options{limit} || 25;
    my $offset  = $options{offset} || 0;
    my $type    = $options{type} or $die->('type is a required parameter');
    my $version = $options{version} || 2;

    $type =~ s/release_group/release-group/;

    unless ($query) {
        given ($type) {
            when ('artist') {
                my $name = escape_query($options{name}) or $die->('name is a required parameter');
                $name =~ tr/A-Z/a-z/;
                $name =~ s/\s*(.*?)\s*$/$1/;
                $query = "artist:($name)(sortname:($name) alias:($name) !artist:($name))";
            }
            when ('label') {
                my $term = escape_query($options{name}) or $die->('name is a required parameter');
                $term =~ tr/A-Z/a-z/;
                $term =~ s/\s*(.*?)\s*$/$1/;
                $query = "label:($term)(sortname:($term) alias:($term) !label:($term))";
            }

            when ('release') {
                $query = combine_rules(
                    \%options,
                    DEFAULT => {
                        parameter => 'title',
                        escape    => 1,
                        process => sub {
                            my $term = shift;
                            $term =~ s/\s*(.*?)\s*$/$1/;
                            $term =~ tr/A-Z/a-z/;
                            $term;
                        },
                        split     => 1,
                        predicate => sub { shift }
                    },
                    arid => {
                        parameter => 'artistid',
                        escape    => 1
                    },
                    artist => {
                        parameter => 'artist',
                        escape    => 1,
                        split     => 1,
                        process   => sub { my $term = shift; $term =~ s/\s*(.*?)\s*$/$1/; $term }
                    },
                    type => {
                        parameter => 'releasetype',
                    },
                    status => {
                        parameter => 'releasestatus',
                        check     => sub { shift() =~ /^\d+$/ },
                        process   => sub { shift() . '^0.0001' }
                    },
                    tracks => {
                        parameter => 'count',
                        check     => sub { shift > 0 },
                    },
                    discids => {
                        check     => sub { shift > 0 },
                    },
                    date   => {},
                    asin   => {},
                    lang   => {},
                    script => {}
                );
            }

            when ('release-group') {
                $query = combine_rules(
                    \%options,
                    DEFAULT => {
                        parameter => 'title',
                        escape    => 1,
                        process => sub {
                            my $term = shift;
                            $term =~ s/\s*(.*?)\s*$/$1/;
                            $term =~ tr/A-Z/a-z/;
                            $term;
                        },
                        split     => 1,
                        predicate => sub { shift }
                    },
                    arid => {
                        parameter => 'artistid',
                        escape    => 1
                    },
                    artist => {
                        parameter => 'artist',
                        escape    => 1,
                        split     => 1,
                        process   => sub { my $term = shift; $term =~ s/\s*(.*?)\s*$/$1/; $term }
                    },
                    type => {
                        parameter => 'releasetype',
                        check     => sub { shift =~ /^\d+$/ },
                        process   => sub { my $type = shift; return $type . '^.0001' }
                    },
                );
            }

            when ('recording') {
                $query = combine_rules(
                    \%options,
                    DEFAULT => {
                        parameter => 'title',
                        escape    => 1,
                        process => sub {
                            my $term = shift;
                            $term =~ s/\s*(.*?)\s*$/$1/;
                            $term =~ tr/A-Z/a-z/;
                            $term;
                        },
                        predicate => sub { shift },
                        split     => 1,
                    },
                    arid => {
                        parameter => 'artistid',
                        escape    => 1
                    },
                    artist => {
                        parameter => 'artist',
                        escape    => 1,
                        split     => 1,
                        process   => sub { my $term = shift; $term =~ s/\s*(.*?)\s*$/$1/; $term }
                    },
                    reid => {
                        parameter => 'releaseid',
                        escape    => 1
                    },
                    release => {
                        parameter => 'release',
                        process   => sub { my $term = shift; $term =~ s/\s*(.*?)\s*$/$1/; $term; },
                        split     => 1,
                        escape    => 1
                    },
                    duration => {
                        predicate => sub {
                            my $dur = int(shift() / 2000);
                            return "qdur:$dur OR qdur:(" . ($dur - 1) . ") OR qdur:(" . ($dur + 1) . ")";
                        }
                    },
                    tnum => {
                        parameter => 'tracknumber',
                        check => sub { shift() >= 0 },
                    },
                    type   => { parameter => 'releasetype' },
                    tracks => { parameter => 'count' },
                );
            }
        }
    }

    $query = uri_escape_utf8($query);
    my $search_url = sprintf("http://%s/ws/%d/%s/?query=%s&offset=%s&max=%s&fmt=xml",
                                 DBDefs->LUCENE_SERVER,
                                 $version,
                                 $type,
                                 $query,
                                 $offset,
                                 $limit,);

    my $ua = LWP::UserAgent->new;
    $ua->timeout (5);
    $ua->env_proxy;

    # Dispatch the search request.
    my $response = $ua->get($search_url);
    unless ($response->is_success)
    {
        die $response;
    }
    else
    {
        return $response->decoded_content;
    }
}

__PACKAGE__->meta->make_immutable;
no Moose;
1;

=head1 NAME

MusicBrainz::Server::Data::Search

=head1 COPYRIGHT

Copyright (C) 2009 Lukas Lalinsky

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.

=cut
