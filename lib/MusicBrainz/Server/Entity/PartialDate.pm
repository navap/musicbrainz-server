package MusicBrainz::Server::Entity::PartialDate;
use Moose;

use List::AllUtils qw( any first_index zip );
use Date::Calc;

use overload '<=>' => \&_cmp, fallback => 1;

has 'year' => (
    is => 'rw',
    isa => 'Int',
    predicate => 'has_year',
);

has 'month' => (
    is => 'rw',
    isa => 'Int'
);

has 'day' => (
    is => 'rw',
    isa => 'Int'
);

around BUILDARGS => sub {
    my $orig = shift;
    my $class = shift;

    return $class->$orig( @_ ) unless @_ == 1;

    my $info = shift;
    if (!ref($info) && $info && $info =~ /(\d{4})?-?(\d{1,2})?-?(\d{1,2})?/)
    {
        $info = {};
        $info->{year} = $1 if ($1 && $1 > 0);
        $info->{month} = $2 if ($2 && $2 > 0);
        $info->{day} = $3 if ($3 && $3 > 0);
        return $class->$orig( $info );
    }

    my %info = map { $_ => $info->{$_} }
        grep { defined($info->{$_}) } keys %$info;

    return $class->$orig( %info );
};


sub is_empty
{
    my ($self) = @_;
    return !($self->year || $self->month || $self->day);
}

sub format
{
    my ($self) = @_;

    # Take as many values as possible, but drop any trailing undefined values
    my @comp = ($self->day, $self->month, $self->year);
    return '' unless any { defined } @comp;

    splice(@comp, 0, first_index { defined } @comp);
    my @significant_components = reverse(@comp);

    # Attempt to display each significant date component, but if it's undefined
    # replace by an appropriate number of '?' characters
    my @len = (4, 2, 2);
    my @res;
    for my $i (0..$#significant_components) {
        my $len = $len[$i];
        my $val = $significant_components[$i];

        push @res, defined($val) ? sprintf "%0${len}d", $val : '?' x $len;
    }

    return join('-', @res);
}

sub _cmp
{
    my ($a, $b) = @_;

    # Stuff without a year sorts first too
    return  0 if (!defined($a->year) && !defined($b->year));
    return  1 if ( defined($a->year) && !defined($b->year));
    return -1 if (!defined($a->year) &&  defined($b->year));

    # We have years for both dates, we can now assume real sorting
    my @begin = ($a->year, $a->month || 1, $a->day || 1);
    my @end =   ($b->year, $b->month || 1, $b->day || 1);

    my ($days) = Date::Calc::Delta_Days(@begin, @end);

    return $days > 0 ? -1
         : $days < 0 ?  1
         :              0;
}

__PACKAGE__->meta->make_immutable;
no Moose;
1;

=head1 COPYRIGHT

Copyright (C) 2009 Lukas Lalinsky
Copyright (C) 2012 MetaBrainz Foundation

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
