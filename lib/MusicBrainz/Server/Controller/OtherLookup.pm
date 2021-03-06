package MusicBrainz::Server::Controller::OtherLookup;
use Moose;
BEGIN { extends 'MusicBrainz::Server::Controller' }

use Moose::Util qw( find_meta );
use MusicBrainz::Server::Translation qw( l );
use MusicBrainz::Server::Constants qw( entities_with );
use MusicBrainz::Server::Entity::Util::JSON qw( to_json_array );

sub lookup_handler {
    my ($name, $code) = @_;

    my $method = sub {
        my ($self, $c) = @_;
        my $form = $c->form(other_lookup => 'OtherLookup');
        $form->field($name)->required(1);

        if ($c->form_submitted_and_valid($form, $c->req->query_params)) {
            $self->$code($c, $form->field($name)->value);
        }
        else {
            $c->stash(
                current_view => 'Node',
                component_path => 'otherlookup/OtherLookupIndex',
                component_props => {form => $form->TO_JSON},
            );
        }
    };

    # Add the method
    find_meta(__PACKAGE__)->add_method(
        $name => $method
    );

    # Add the ':Local' attribute
    find_meta(__PACKAGE__)->register_method_attributes($method, [qw( Local )]);
}

lookup_handler 'catno' => sub {
    my ($self, $c, $cat_no) = @_;

    $c->response->redirect(
        $c->uri_for_action('/search/search', {
            query => 'catno:' . $cat_no,
            type => 'release',
            advanced => '1',
        }));

    $c->detach;
};

lookup_handler 'barcode' => sub {
    my ($self, $c, $barcode) = @_;

    $c->response->redirect(
        $c->uri_for_action('/search/search', {
            query => 'barcode:' . $barcode,
            type => 'release',
            advanced => '1',
        }));

    $c->detach;
};

lookup_handler 'mbid' => sub {
    my ($self, $c, $gid) = @_;

    $c->forward('/mbid/show', [$gid]);
};

lookup_handler 'url' => sub {
    my ($self, $c, $url) = @_;

    my ($entity) = $c->model('URL')->find_by_url($url);
    if (defined $entity) {
        $c->response->redirect(
            $c->uri_for_action(
                $c->controller('URL')->action_for('show'),
                [ $entity->gid ]));
        $c->detach;
    } else {
        $self->not_found($c);
    }
};

lookup_handler 'isrc' => sub {
    my ($self, $c, $isrc) = @_;

    $c->response->redirect($c->uri_for_action('/isrc/show', [ $isrc ]));
    $c->detach;
};

lookup_handler 'iswc' => sub {
    my ($self, $c, $iswc) = @_;

    $c->response->redirect($c->uri_for_action('/iswc/show', [ $iswc ]));
    $c->detach;
};

lookup_handler 'artist-ipi' => sub {
    my ($self, $c, $ipi) = @_;

    $c->response->redirect(
        $c->uri_for_action('/search/search', {
            query => 'ipi:' . $ipi,
            type => 'artist',
            advanced => '1',
        }));

    $c->detach;
};

lookup_handler 'artist-isni' => sub {
    my ($self, $c, $isni) = @_;

    $c->response->redirect(
        $c->uri_for_action('/search/search', {
            query => 'isni:' . $isni,
            type => 'artist',
            advanced => '1',
        }));

    $c->detach;
};

lookup_handler 'label-ipi' => sub {
    my ($self, $c, $ipi) = @_;

    $c->response->redirect(
        $c->uri_for_action('/search/search', {
            query => 'ipi:' . $ipi,
            type => 'label',
            advanced => '1',
        }));

    $c->detach;
};

lookup_handler 'label-isni' => sub {
    my ($self, $c, $isni) = @_;

    $c->response->redirect(
        $c->uri_for_action('/search/search', {
            query => 'isni:' . $isni,
            type => 'label',
            advanced => '1',
        }));

    $c->detach;
};

lookup_handler 'discid' => sub {
    my ($self, $c, $discid) = @_;

    $c->response->redirect($c->uri_for_action('/cdtoc/show', [ $discid ]));
    $c->detach;
};

lookup_handler 'freedbid' => sub {
    my ($self, $c, $freedbid) = @_;

    my @cdtocs = $c->model('CDTOC')->find_by_freedbid(lc($freedbid));

    my @medium_cdtocs = map {
        $c->model('MediumCDTOC')->find_by_discid($_->discid);
    } @cdtocs;

    my @mediums = $c->model('Medium')->load(@medium_cdtocs);
    my @releases = $c->model('Release')->load(@mediums);

    $c->model('ArtistCredit')->load(@releases);
    $c->model('Release')->load_related_info(@releases);
    $c->model('Language')->load(@releases);
    $c->model('Script')->load(@releases);

    $c->model('ReleaseStatus')->load(@releases);
    $c->model('ReleaseGroup')->load(@releases);
    $c->model('ReleaseGroupType')->load(map { $_->release_group } @releases);

    $c->stash(
        current_view => 'Node',
        component_path => 'otherlookup/OtherLookupReleaseResults',
        component_props => {results => to_json_array(\@releases)},
    )
};

sub index : Path('')
{
    my ($self, $c) = @_;
    my $form = $c->form( other_lookup => 'OtherLookup' );

    $c->stash(
        current_view => 'Node',
        component_path => 'otherlookup/OtherLookupIndex',
        component_props => {form => $form->TO_JSON},
    );
}

1;

=head1 LICENSE

Copyright (C) 2010 MetaBrainz Foundation

This software is provided "as is", without warranty of any kind, express or
implied, including  but not limited  to the warranties of  merchantability,
fitness for a particular purpose and noninfringement. In no event shall the
authors or  copyright  holders be  liable for any claim,  damages or  other
liability, whether  in an  action of  contract, tort  or otherwise, arising
from,  out of  or in  connection with  the software or  the  use  or  other
dealings in the software.

GPL - The GNU General Public License    http://www.gnu.org/licenses/gpl.txt
Permits anyone the right to use and modify the software without limitations
as long as proper  credits are given  and the original  and modified source
code are included. Requires  that the final product, software derivate from
the original  source or any  software  utilizing a GPL  component, such  as
this, is also licensed under the GPL license.

=cut
