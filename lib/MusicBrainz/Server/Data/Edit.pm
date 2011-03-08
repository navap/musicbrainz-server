package MusicBrainz::Server::Data::Edit;
use Moose;

use Carp qw( carp croak confess );
use Data::OptList;
use DateTime;
use TryCatch;
use List::MoreUtils qw( uniq zip );
use MusicBrainz::Server::Constants qw( $EDITOR_MODBOT );
use MusicBrainz::Server::Data::Editor;
use MusicBrainz::Server::EditRegistry;
use MusicBrainz::Server::Edit::Exceptions;
use MusicBrainz::Server::Types qw( :edit_status $VOTE_YES $AUTO_EDITOR_FLAG $UNTRUSTED_FLAG );
use MusicBrainz::Server::Data::Utils qw( placeholders query_to_list query_to_list_limited );
use JSON::Any;

use aliased 'MusicBrainz::Server::Entity::EditorSubscription';

extends 'MusicBrainz::Server::Data::Entity';

sub _table
{
    return 'edit';
}

sub _columns
{
    return 'edit.id, edit.editor, edit.open_time, edit.expire_time, edit.close_time,
            edit.data, edit.language, edit.type, edit.yes_votes, edit.no_votes,
            edit.autoedit, edit.status, edit.quality';
}

sub _dbh
{
    return shift->c->raw_dbh;
}

sub sql { return shift->c->raw_sql }

sub _new_from_row
{
    my ($self, $row) = @_;

    # Readd the class marker
    my $class = MusicBrainz::Server::EditRegistry->class_from_type($row->{type})
        or confess"Could not look up class for type ".$row->{type};
    my $data = JSON::Any->new(utf8 => 1)->jsonToObj($row->{data});

    my $edit = $class->new({
        c => $self->c,
        id => $row->{id},
        yes_votes => $row->{yes_votes},
        no_votes => $row->{no_votes},
        editor_id => $row->{editor},
        created_time => $row->{open_time},
        expires_time => $row->{expire_time},
        auto_edit => $row->{autoedit},
        status => $row->{status},
        quality => $row->{quality},
        c => $self->c,
    });
    $edit->language_id($row->{language}) if $row->{language};
    try {
        $edit->restore($data);
    }
    catch {
        $edit->clear_data;
    }
    $edit->close_time($row->{close_time}) if defined $row->{close_time};
    return $edit;
}

# Load an edit from the DB and try to get an exclusive lock on it
sub get_by_id_and_lock
{
    my ($self, $id) = @_;

    my $query =
        "SELECT " . $self->_columns . " FROM " . $self->_table . " " .
        "WHERE id = ? FOR UPDATE NOWAIT";

    my $row = $self->sql->select_single_row_hash($query, $id);
    return unless defined $row;

    my $edit = $self->_new_from_row($row);
    return $edit;
}

sub get_max_id
{
    my ($self) = @_;

    return $self->sql->select_single_value("SELECT id FROM edit ORDER BY id DESC
                                    LIMIT 1");
}

sub find
{
    my ($self, $p, $limit, $offset) = @_;

    my (@pred, @args);
    for my $type (qw( artist label release release_group recording work url)) {
        next unless exists $p->{$type};
        my $ids = delete $p->{$type};

        my @ids = ref $ids ? @$ids : $ids;
        push @args, @ids;

        my $subquery;
        if (@ids == 1) {
            $subquery = "SELECT edit FROM edit_$type WHERE $type = ?";
        }
        else {
            my $placeholders = placeholders(@ids);
            $subquery = "SELECT edit FROM edit_$type
                          WHERE $type IN ($placeholders)
                       GROUP BY edit HAVING count(*) = ?";
            push @args, scalar @ids;
        }

        push @pred, "id IN ($subquery)";
    }

    my @params = keys %$p;
    while (my ($param, $value) = each %$p) {
        my @values = ref($value) ? @$value : ($value);
        next unless @values;
        push @pred, (join " OR ", (("$param = ?") x @values));
        push @args, @values;
    }

    my $query = 'SELECT ' . $self->_columns . ' FROM ' . $self->_table;
    $query .= ' WHERE ' . join ' AND ', map { "($_)" } @pred if @pred;
    $query .= ' ORDER BY id DESC OFFSET ?';

    return query_to_list_limited($self->c->raw_sql, $offset, $limit, sub {
            return $self->_new_from_row(shift);
        }, $query, @args, $offset);
}

sub find_for_subscription
{
    my ($self, $subscription) = @_;
    if($subscription->isa(EditorSubscription)) {
        my $query = 'SELECT ' . $self->_columns . ' FROM edit 
                      WHERE id > ? AND editor = ?';

        return query_to_list(
            $self->c->raw_sql,
            sub { $self->_new_from_row(shift) },
            $query, $subscription->last_edit_sent,
            $subscription->subscribed_editor_id
        );
    }
    else {
        my $type = $subscription->type;
        my $query = 'SELECT ' . $self->_columns . ' FROM ' . $self->_table .
            " WHERE id IN (SELECT edit FROM edit_$type WHERE $type = ?) " .
            "   AND id > ?";
        return query_to_list(
            $self->c->raw_sql,
            sub { $self->_new_from_row(shift) },
            $query, $subscription->target_id, $subscription->last_edit_sent);
    }
}

sub find_by_voter
{
    my ($self, $voter_id, $limit, $offset) = @_;
    my $query =
        'SELECT ' . $self->_columns . '
           FROM ' . $self->_table . '
           JOIN vote ON vote.edit = edit.id
          WHERE vote.editor = ? AND vote.superseded = FALSE
       ORDER BY id DESC
         OFFSET ?';

    return query_to_list_limited(
        $self->sql, $offset, $limit,
        sub { $self->_new_from_row(shift) },
        $query, $voter_id, $offset
    );
}

sub merge_entities
{
    my ($self, $type, $new_id, @old_ids) = @_;
    my @ids = ($new_id, @old_ids);
    $self->sql->do(
        "DELETE FROM edit_$type
          WHERE $type IN (" . placeholders(@ids) . ")
            AND (edit, $type) NOT IN (
                   SELECT DISTINCT ON (edit) edit, $type
                     FROM edit_$type
                    WHERE $type IN (" . placeholders(@ids) . ")
                )",
        @ids, @ids);

    $self->sql->do("UPDATE edit_$type SET $type = ?
              WHERE $type IN (".placeholders(@old_ids).")", $new_id, @old_ids);
}

sub preview
{
    my ($self, %opts) = @_;
    
    my $type = delete $opts{edit_type} or croak "edit_type required";
    my $editor_id = delete $opts{editor_id} or croak "editor_id required";
    my $privs = delete $opts{privileges} || 0;
    my $class = MusicBrainz::Server::EditRegistry->class_from_type($type)
        or confess "Could not lookup edit type for $type";

    unless ($class->does ('MusicBrainz::Server::Edit::Role::Preview'))
    {
        warn "FIXME: $class does not support previewing.\n";
        return undef;
    }

    my $edit = $class->new( editor_id => $editor_id, c => $self->c, preview => 1 );
    try {
        $edit->initialize(%opts);
    }
    catch (MusicBrainz::Server::Edit::Exceptions::NoChanges $e) {
        confess $e;
    }
    catch ($err) {
        use Data::Dumper;
        croak join "\n\n", "Could not create error", Dumper(\%opts), $err;
    }

    my $quality = $edit->determine_quality;
    my $conditions = $edit->edit_conditions->{$quality};

    # Edit conditions allow auto edit and the edit requires no votes
    $edit->auto_edit(1)
        if ($conditions->{auto_edit} && $conditions->{votes} == 0);

    $edit->auto_edit(1)
        if ($conditions->{auto_edit} && $edit->allow_auto_edit);

    # Edit conditions allow auto edit and the user is autoeditor
    $edit->auto_edit(1)
        if ($conditions->{auto_edit} && ($privs & $AUTO_EDITOR_FLAG));

    # Unstrusted user, always go through the edit queue
    $edit->auto_edit(0)
        if ($privs & $UNTRUSTED_FLAG);

    # Save quality level
    $edit->quality($quality);

    return $edit;
}

sub create
{
    my ($self, %opts) = @_;

    my $type = delete $opts{edit_type} or croak "edit_type required";
    my $editor_id = delete $opts{editor_id} or croak "editor_id required";
    my $privs = delete $opts{privileges} || 0;
    my $class = MusicBrainz::Server::EditRegistry->class_from_type($type)
        or confess "Could not lookup edit type for $type";

    my $edit = $class->new( editor_id => $editor_id, c => $self->c );
    try {
        $edit->initialize(%opts);
    }
    catch (MusicBrainz::Server::Edit::Exceptions::NoChanges $e) {
        confess $e;
    }
    catch ($err) {
        use Data::Dumper;
        croak join "\n\n", "Could not create error", Dumper(\%opts), $err;
    }

    my $quality = $edit->determine_quality;
    my $conditions = $edit->edit_conditions->{$quality};

    # Edit conditions allow auto edit and the edit requires no votes
    $edit->auto_edit(1)
        if ($conditions->{auto_edit} && $conditions->{votes} == 0);

    $edit->auto_edit(1)
        if ($conditions->{auto_edit} && $edit->allow_auto_edit);

    # Edit conditions allow auto edit and the user is autoeditor
    $edit->auto_edit(1)
        if ($conditions->{auto_edit} && ($privs & $AUTO_EDITOR_FLAG));

    # Unstrusted user, always go through the edit queue
    $edit->auto_edit(0)
        if ($privs & $UNTRUSTED_FLAG);

    # Save quality level
    $edit->quality($quality);

    Sql::run_in_transaction(sub {
        $edit->insert;

        my $now = DateTime->now;
        my $duration = DateTime::Duration->new( days => $conditions->{duration} );

        # Automatically accept auto-edits on insert
        if ($edit->auto_edit) {
            my $st = $self->_do_accept($edit);
            $edit->status($st);
            $self->c->model('Editor')->credit($edit->editor_id, $st, 1);
            $edit->close_time($now)
        };

        my $row = {
            editor => $edit->editor_id,
            data => JSON::Any->new( utf8 => 1 )->objToJson($edit->to_hash),
            status => $edit->status,
            type => $edit->edit_type,
            open_time => $now,
            expire_time => $now + $duration,
            autoedit => $edit->auto_edit,
            quality => $edit->quality,
            close_time => $edit->close_time
        };

        my $edit_id = $self->c->raw_sql->insert_row('edit', $row, 'id');
        $edit->id($edit_id);

        my $ents = $edit->related_entities;
        while (my ($type, $ids) = each %$ents) {
            $ids = [ uniq @$ids ];
            @$ids or next;
            my $query = "INSERT INTO edit_$type (edit, $type) VALUES ";
            $query .= join ", ", ("(?, ?)") x @$ids;
            my @all_ids = ($edit_id) x @$ids;
            $self->c->raw_sql->do($query, zip @all_ids, @$ids);
        }

        if ($edit->is_open) {
            $edit->adjust_edit_pending(+1);
        }
    }, $self->c->sql, $self->c->raw_sql);

    return $edit;
}

sub load_all
{
    my ($self, @edits) = @_;

    @edits = grep { $_->has_data } @edits;

    my $objects_to_load  = {}; # Objects loaded with get_by_id
    my $post_load_models = {}; # Objects loaded with ->load (after get_by_id)

    for my $edit (@edits) {
        my $edit_references = $edit->foreign_keys;
        while (my ($model, $ids) = each %$edit_references) {
            $objects_to_load->{$model} ||= [];
            if (ref($ids) eq 'ARRAY') {
                $ids = [ uniq grep { defined } @$ids ];
            }
            $ids = Data::OptList::mkopt_hash($ids);
            while (my ($object_id, $extra_models) = each %$ids) {
                push @{ $objects_to_load->{$model} }, $object_id;
                $post_load_models->{$model}->{$object_id} = $extra_models
                    if $extra_models && @$extra_models;
            }
        }
    }

    my $loaded = {};
    my $load_arguments = {};
    while (my ($model, $ids) = each %$objects_to_load) {
        my $m = ref $model ? $model : $self->c->model($model);
        $loaded->{$model} = $m->get_by_ids(@$ids);

        # Now we need to load any extra information about each object
        for my $id (@$ids) {
            for my $extra (@{ $post_load_models->{$model}->{$id} }) {
                $load_arguments->{$extra} ||= [];
                push @{ $load_arguments->{$extra} }, $loaded->{$model}->{$id};
            }
        }
    }

    while (my ($model, $objs) = each %$load_arguments) {
        $self->c->model($model)->load(@$objs);
    }

    for my $edit (@edits) {
        $edit->display_data($edit->build_display_data($loaded));
    }
}

# Runs it's own transaction
sub approve
{
    my ($self, $edit, $editor_id) = @_;

    Sql::run_in_transaction(sub {
        # Load the edit again, but this time lock it for updates
        $edit = $self->get_by_id_and_lock($edit->id);

        $self->c->model('Vote')->enter_votes(
            $editor_id,
            {
                vote    => $VOTE_YES,
                edit_id => $edit->id
            }
        );

        # Apply the changes and close the edit
        $self->accept($edit);
    }, $self->c->sql, $self->c->raw_sql);
}

sub _do_accept
{
    my ($self, $edit) = @_;

    try {
        $edit->accept;
    }
    catch (MusicBrainz::Server::Edit::Exceptions::FailedDependency $err) {
        $self->c->model('EditNote')->add_note(
            $edit->id => {
                editor_id => $EDITOR_MODBOT,
                text => $err->message
            }
        );
        return $STATUS_FAILEDDEP;
    }
    catch ($err) {
        carp("Could not accept " . $edit->id . ": $err");
        return $STATUS_ERROR;
    };
    return $STATUS_APPLIED;
}

sub _do_reject
{
    my ($self, $edit, $status) = @_;

    try {
        $edit->reject;
    }
    catch ($err) {
        carp("Could not reject " . $edit->id . ": $err");
        return $STATUS_ERROR;
    };
    return $status;
}

# Must be called in a transaction
sub accept
{
    my ($self, $edit) = @_;

    confess "The edit is not open anymore." if $edit->status != $STATUS_OPEN;
    $self->_close($edit, sub { $self->_do_accept(shift) });
}

# Must be called in a transaction
sub reject
{
    my ($self, $edit, $status) = @_;

    $status ||= $STATUS_FAILEDVOTE;
    my $expected_status = ($status == $STATUS_DELETED)
        ? $STATUS_TOBEDELETED
        : $STATUS_OPEN;
    confess "The edit is not open anymore." if $edit->status != $expected_status;
    $self->_close($edit, sub { $self->_do_reject(shift, $status) });
}

# Runs it's own transaction
sub cancel
{
    my ($self, $edit) = @_;

    Sql::run_in_transaction(sub {
        my $query = "UPDATE edit SET status = ? WHERE id = ?";
        $self->c->raw_sql->do($query, $STATUS_TOBEDELETED, $edit->id);
        $edit->adjust_edit_pending(-1);
   }, $self->c->sql, $self->c->raw_sql);
}

sub _close
{
    my ($self, $edit, $close_sub) = @_;
    my $status = &$close_sub($edit);
    my $query = "UPDATE edit SET status = ?, close_time = NOW() WHERE id = ?";
    $self->c->raw_sql->do($query, $status, $edit->id);
    $edit->adjust_edit_pending(-1);
    $edit->status($status);
    $self->c->model('Editor')->credit($edit->editor_id, $status);
}

sub insert_votes_and_notes {
    my ($self, $user_id, %data) = @_;
    my @votes = @{ $data{votes} || [] };
    my @notes = @{ $data{notes} || [] };

    Sql::run_in_transaction(sub {
        $self->c->model('Vote')->enter_votes($user_id, @votes);
        for my $note (@notes) {
            $self->c->model('EditNote')->add_note(
                $note->{edit_id},
                {
                    editor_id => $user_id,
                    text => $note->{edit_note},
                });
        }
    }, $self->c->raw_sql);
}

__PACKAGE__->meta->make_immutable;
no Moose;

1;

=head1 COPYRIGHT

Copyright (C) 2009 Oliver Charles

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
