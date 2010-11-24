package pf::radius;

=head1 NAME

pf::radius - Module that deals with everything radius related

=head1 SYNOPSIS

The pf::radius module contains the functions necessary for answering radius queries.
Radius is the network access component known as AAA used in 802.1x, MAC authentication, 
MAC authentication bypass (MAB), etc. This module acts as a proxy between our FreeRADIUS 
perl module's SOAP requests (packetfence.pm) and PacketFence core modules.

All the behavior contained here can be overridden in lib/pf/radius/custom.pm.

=cut

use strict;
use warnings;
use diagnostics;

use Log::Log4perl;

use pf::config;
use pf::locationlog;
use pf::node;
use pf::SNMP;
use pf::SwitchFactory;
use pf::util;
use pf::vlan::custom;
# constants used by this module are provided by
use pf::radius::constants;

=head1 SUBROUTINES

=over

=cut

=item * new - get a new instance of the radius object
 
=cut
sub new {
    my $logger = Log::Log4perl::get_logger("pf::radius");
    $logger->debug("instantiating new pf::radius object");
    my ( $class, %argv ) = @_;
    my $this = bless {}, $class;
    return $this;
}

=item * authorize - handling the radius authorize call

Returns an arrayref (tuple) with element 0 being a response code for Radius and second element an hash meant 
to fill the Radius reply (RAD_REPLY). The arrayref is to workaround a quirk in SOAP::Lite and have everything in result()

See http://search.cpan.org/~byrne/SOAP-Lite/lib/SOAP/Lite.pm#IN/OUT,_OUT_PARAMETERS_AND_AUTOBINDING

=cut
# WARNING: You cannot change the return structure of this sub unless you also update its clients (like the SOAP 802.1x 
# module). This is because of the way perl mangles a returned hash as a list. Clients would get confused if you add a
# scalar return without updating the clients.
sub authorize {
    my ($this, $nas_port_type, $switch_ip, $eap_type, $mac, $port, $user_name, $ssid) = @_;
    my $logger = Log::Log4perl::get_logger(ref($this));

    $logger->trace("received a radius authorization request with parameters: ".
        "nas port type => $nas_port_type, switch_ip => $switch_ip, EAP-Type => $eap_type, ".
        "mac => $mac, port => $port, username => $user_name, ssid => $ssid");

    my $connection_type = $this->_identifyConnectionType($nas_port_type, $eap_type);

    # TODO maybe it's in there that we should do all the magic that happened in the FreeRADIUS module
    # meaning: the return should be decided by _doWeActOnThisCall, not always $RADIUS::RLM_MODULE_NOOP
    my $weActOnThisCall = $this->_doWeActOnThisCall($connection_type, $switch_ip, $mac, $port, $user_name, $ssid);
    if ($weActOnThisCall == 0) {
        $logger->info("We decided not to act on this radius call. Stop handling request from $switch_ip.");
        return [$RADIUS::RLM_MODULE_NOOP, undef];
    }

    $logger->info("handling radius autz request: from switch_ip => $switch_ip, " 
        . "connection_type => " . connection_type_to_str($connection_type) . " "
        . "mac => $mac, port => $port, username => $user_name, ssid => $ssid");

    #add node if necessary
    if ( !node_exist($mac) ) {
        $logger->info("node $mac does not yet exist in database. Adding it now");
        node_add_simple($mac);
    }

    # There is activity from that mac, call node wakeup
    node_mac_wakeup($mac);

    # TODO: the following statement and the switch instantiation account for a third of the time spent in a radius query
    my $switchFactory = new pf::SwitchFactory(-configFile => $conf_dir.'/switches.conf');

    $logger->debug("instantiating switch");
    my $switch = $switchFactory->instantiate($switch_ip);

    # is switch object correct?
    if (!$switch) {
        $logger->warn(
            "Can't instantiate switch $switch_ip. This request will be failed. "
            ."Are you sure your switches.conf is correct?"
        );
        return [$RADIUS::RLM_MODULE_FAIL, undef];
    }

    # verify if switch supports this connection type
    if (!$this->_isSwitchSupported($switch, $connection_type)) { 
        # if not supported, return
        return $this->_switchUnsupportedReply($switch);
    }
    $port = $this->_translateNasPortToIfIndex($connection_type, $switch, $port);

    # determine if we need to perform automatic registration
    my $isPhone = $switch->isPhoneAtIfIndex($mac);

    my $vlan_obj = new pf::vlan::custom();
    # should we auto-register? let's ask the VLAN object
    if ($vlan_obj->shouldAutoRegister($mac, $switch->isRegistrationMode(), 0, $isPhone, $connection_type, $ssid)) {

        # automatic registration
        my %autoreg_node_defaults = $vlan_obj->getNodeInfoForAutoReg($switch->{_ip}, $port,
            $mac, undef, $switch->isRegistrationMode(), $FALSE, $isPhone, $connection_type, $user_name, $ssid);

        $logger->debug("auto-registering node $mac");
        if (!node_register($mac, $autoreg_node_defaults{'pid'}, %autoreg_node_defaults)) {
            $logger->error("auto-registration of node $mac failed");
        }
    }

    # if it's an IP Phone, let _authorizeVoip decide (extension point)
    if ($isPhone) {
        return $this->_authorizeVoip($connection_type, $switch, $mac, $port, $user_name, $ssid);
    }

    # if switch is not in production, we don't interfere with it: we log and we return OK
    if (!$switch->isProductionMode()) {
        $logger->warn("Should perform access control on switch $switch_ip for mac $mac but the switch "
            ."is not in production -> Returning ACCEPT");
        $switch->disconnectRead();
        $switch->disconnectWrite();
        return [$RADIUS::RLM_MODULE_OK, undef];
    }

    # grab vlan
    my $vlan = $this->_findNodeVlan($vlan_obj, $mac, $switch, $port, $connection_type, $ssid);

    # should this node be kicked out?
    if (defined($vlan) && $vlan == -1) {
        $logger->info("According to rules in _findNodeVlan this node must be kicked out. Returning USERLOCK");
        $switch->disconnectRead();
        $switch->disconnectWrite();
        # FIXME make sure this works before next release
        return [$RADIUS::RLM_MODULE_USERLOCK, undef];
    }

    if (!$switch->isManagedVlan($vlan)) {
        $logger->warn("new VLAN $vlan is not a managed VLAN -> Returning FAIL. "
                     ."Is the target vlan in the vlans=... list?");
        $switch->disconnectRead();
        $switch->disconnectWrite();
        return [$RADIUS::RLM_MODULE_FAIL, undef];
    }

    #closes old locationlog entries and create a new one if required
    locationlog_synchronize($switch_ip, $port, $vlan, $mac, 
        $isPhone ? VOIP : NO_VOIP, $connection_type, $user_name, $ssid
    );

    # cleanup
    $switch->disconnectRead();
    $switch->disconnectWrite();

    my %RAD_REPLY;
    $RAD_REPLY{'Tunnel-Medium-Type'} = 6;
    $RAD_REPLY{'Tunnel-Type'} = 13;
    $RAD_REPLY{'Tunnel-Private-Group-ID'} = $vlan;
    $logger->info("Returning ACCEPT with VLAN: $vlan");
    return [$RADIUS::RLM_MODULE_OK, %RAD_REPLY];
}

=item * _findNodeVlan - what VLAN should a node be put into
        
This sub is meant to be overridden in lib/pf/radius/custom.pm if the default 
version doesn't do the right thing for you. However it is very generic, 
maybe what you are looking for needs to be done in pf::vlan's get_violation_vlan, 
get_registration_vlan or get_normal_vlan.
    
=cut    
sub _findNodeVlan {
    my ($this, $vlan_obj, $mac, $switch, $port, $connection_type, $ssid) = @_;
    my $logger = Log::Log4perl::get_logger(ref($this));

    # violation handling
    my $violation = $vlan_obj->get_violation_vlan($mac, $switch);
    if (defined($violation) && $violation != 0) {
        # returning proper violation vlan
        return $violation;
    } elsif (!defined($violation)) {
        $logger->warn("There was a problem identifying vlan for violation. Will act as if there was no violation.");
    }

    # there were no violation, now onto registration handling
    my $node_info = node_view($mac);
    my $registration = $vlan_obj->get_registration_vlan($mac, $switch, $node_info);
    if (defined($registration) && $registration != 0) {
        return $registration;
    }

    # no violation, not unregistered, we are now handling a normal vlan
    my $vlan = $vlan_obj->get_normal_vlan($switch, $port, $mac, $node_info, $connection_type, $ssid);
    $logger->info("MAC: $mac, PID: " .$node_info->{pid}. ", Status: " .$node_info->{status}. ". Returned VLAN: $vlan");
    return $vlan;
}

=item * _doWeActOnThisCall - is this request of any interest?

Pass all the info you can

returns 0 for no, 1 for yes

=cut
sub _doWeActOnThisCall {
    my ($this, $connection_type, $switch_ip, $mac, $port, $user_name, $ssid) = @_;
    my $logger = Log::Log4perl::get_logger(ref($this));
    $logger->trace("_doWeActOnThisCall called");

    # lets assume we don't act
    my $do_we_act = 0;

    # TODO we could implement some way to know if the same request is being worked on and drop right here

    # is it wired or wireless? call sub accordingly
    if (defined($connection_type)) {

        if (($connection_type & WIRELESS) == WIRELESS) {
            $do_we_act = $this->_doWeActOnThisCallWireless($connection_type, $switch_ip, $mac, 
                $port, $user_name, $ssid);

        } elsif (($connection_type & WIRED) == WIRED) {
            $do_we_act = $this->_doWeActOnThisCallWired($connection_type, $switch_ip, $mac, $port, $user_name, $ssid);
        } else {
            $do_we_act = 0;
        } 

    } else {
        # we won't act on an unknown request type
        $do_we_act = 0;
    }
    return $do_we_act;
}

=item * _doWeActOnThisCallWireless - is this wireless request of any interest?

Pass all the info you can

returns 0 for no, 1 for yes

=cut
sub _doWeActOnThisCallWireless {
    my ($this, $connection_type, $switch_ip, $mac, $port, $user_name, $ssid) = @_;
    my $logger = Log::Log4perl::get_logger(ref($this));
    $logger->trace("_doWeActOnThisCallWireless called");

    # for now we always act on wireless radius authorize
    return 1;
}

=item * _doWeActOnThisCallWired - is this wired request of any interest?

Pass all the info you can
        
returns 0 for no, 1 for yes
    
=cut
sub _doWeActOnThisCallWired {
    my ($this, $connection_type, $switch_ip, $mac, $port, $user_name, $ssid) = @_;
    my $logger = Log::Log4perl::get_logger(ref($this));
    $logger->trace("_doWeActOnThisCallWired called");

    # for now we always act on wired radius authorize
    return 1;
}


=item * _identifyConnectionType - identify the connection type based information provided by radius call

Need radius' NAS-Port-Type and EAP-Type

Returns the constants WIRED or WIRELESS. Undef if unable to identify.

=cut
sub _identifyConnectionType {
    my ($this, $nas_port_type, $eap_type) = @_;
    my $logger = Log::Log4perl::get_logger(ref($this));

    $eap_type = 0 if (not defined($eap_type));
    if (defined($nas_port_type)) {
    
        if ($nas_port_type =~ /^Wireless-802\.11$/) {

            if ($eap_type) {
                return WIRELESS_802_1X;
            } else {
                return WIRELESS_MAC_AUTH;
            }
    
        } elsif ($nas_port_type =~ /^Ethernet$/) {

            if ($eap_type) {
                return WIRED_802_1X;
            } else {
                return WIRED_MAC_AUTH_BYPASS;
            }

        } else {
            # we didn't recognize request_type, this is a problem
            $logger->warn("Unknown connection_type. NAS-Port-Type: $nas_port_type, EAP-Type: $eap_type.");
            return;
        }
    } else {
        $logger->warn("Request type was not set. There is a problem with the NAS, your radius config "
            ."or rlm_perl packetfence.pm FreeRADIUS module.");
        return;
    }
}

=item * _authorizeVoip - radius authorization of VoIP

All of the parameters from the authorize method call are passed just in case someone who override this sub 
need it. However, connection_type is passed instead of nas_port_type and eap_type and the switch object 
instead of switch_ip.

Returns the same structure as authorize(), see it's POD doc for details.

=cut
sub _authorizeVoip {
    my ($this, $connection_type, $switch, $mac, $port, $user_name, $ssid) = @_;
    my $logger = Log::Log4perl::get_logger(ref($this));

    # we got Avaya phones working on Cisco switches with the following
    # if you want to do it, copy this whole sub into radius/custom.pm and uncomment the following lines
    # FIXME watch out for translated port in the below locationlog sync
    #locationlog_synchronize($switch->{_ip}, $port, $switch->{_voiceVlan}, $mac, 
    #    VOIP, $connection_type, $user_name, $ssid
    #);
    #my %RAD_REPLY; 
    #$RAD_REPLY{'Cisco-AVPair'} = "device-traffic-class=voice";
    #$switch->disconnectRead();
    #$switch->disconnectWrite();
    #return [$RADIUS::RLM_MODULE_OK, %RAD_REPLY];

    # TODO IP Phones authentication over Radius not supported by default because it seems vendor dependent
    $logger->warn("Radius authentication of IP Phones is not enabled by default. Returning failure. See pf::radius's _authorizeVoip for details on how to activate it.");

    $switch->disconnectRead();
    $switch->disconnectWrite();
    return [$RADIUS::RLM_MODULE_FAIL, undef];
}

=item * _translateNasPortToIfIndex - convert the number in NAS-Port into an ifIndex only when relevant

=cut
sub _translateNasPortToIfIndex {
    my ($this, $conn_type, $switch, $port) = @_;
    my $logger = Log::Log4perl::get_logger(ref($this));

    if (($conn_type & WIRED) == WIRED) {
        $logger->trace("translating NAS-Port to ifIndex for proper accounting");
        return $switch->NasPortToIfIndex($port);
    }
    return $port;
}

=item * _isSwitchSupported - determines if switch is supported by current connection type

=cut
sub _isSwitchSupported {
    my ($this, $switch, $conn_type) = @_;
    my $logger = Log::Log4perl::get_logger(ref($this));

    if ($conn_type == WIRED_MAC_AUTH_BYPASS) {
        return $switch->supportsMacAuthBypass();
    } elsif ($conn_type == WIRED_802_1X) {
        return $switch->supportsWiredDot1x();
    } elsif ($conn_type == WIRELESS_MAC_AUTH) {
        # TODO implement supportsWirelessMacAuth (or supportsWireless)
        $logger->trace("Wireless doesn't have a supports...() call for now, always say it's supported");
        return $TRUE;
    } elsif ($conn_type == WIRELESS_802_1X) {
        # TODO implement supportsWirelessMacAuth (or supportsWireless)
        $logger->trace("Wireless doesn't have a supports...() call for now, always say it's supported");
        return $TRUE;
    }
}

=item * _switchUnsupportedReply - what is sent to RADIUS when a switch is unsupported

=cut
sub _switchUnsupportedReply {
    my ($this, $switch) = @_;
    my $logger = Log::Log4perl::get_logger(ref($this));

    $logger->warn("Sending REJECT since switch is unspported");
    $switch->disconnectRead();
    $switch->disconnectWrite();
    return [$RADIUS::RLM_MODULE_FAIL, undef];
}

=back

=head1 BUGS AND LIMITATIONS

Authentication of IP Phones (VoIP) over radius is not supported yet.

=head1 AUTHOR

Olivier Bilodeau <obilodeau@inverse.ca>

=head1 COPYRIGHT

Copyright (C) 2009, 2010 Inverse inc.

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

1;

# vim: set shiftwidth=4:
# vim: set expandtab:
# vim: set tabstop=4:
# vim: set backspace=indent,eol,start: