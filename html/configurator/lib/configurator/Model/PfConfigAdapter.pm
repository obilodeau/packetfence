package configurator::Model::PfConfigAdapter;
use Moose;
use namespace::autoclean;

extends 'Catalyst::Model';

use pf::config;

=head1 NAME

configurator::Model::PfConfigAdapter - Catalyst Model

=head1 DESCRIPTION

A wrapper above pf::config to expose some of its feature. The longer term
plan is to migrate out of pf::config and all into Web Services.

=over

=item getWebAdminIp

Returns the IP where the Web Administration interface runs.

Will prefer returning the virtual IP if there's one.

=cut
sub getWebAdminIp {
    my ($self) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    my $mgmt_net = $management_network;
    return (defined($mgmt_net->tag('vip'))) ? $mgmt_net->tag('vip') : $mgmt_net->tag('ip');
}

=item getWebAdminPort

Returns the port on which the Web Administration interface runs.

=cut
sub getWebAdminPort {
    my ($self) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    return $Config{'ports'}{'admin'};
}

=head1 AUTHOR

Olivier Bilodeau <obilodeau@inverse.ca>

=head1 COPYRIGHT

Copyright 2012 Inverse inc.

=head1 LICENSE

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301,
USA.

=cut

__PACKAGE__->meta->make_immutable;

1;