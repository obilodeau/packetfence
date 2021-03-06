package pf::web;

=head1 NAME

pf::web - module to generate the different web pages.

=cut

=head1 DESCRIPTION

pf::web contains the functions necessary to generate different web pages:
based on pre-defined templates: login, registration, release, error, status.  

It is possible to customize the behavior of this module by redefining its subs in pf::web::custom.
See F<pf::web::custom> for details.

=head1 CONFIGURATION AND ENVIRONMENT

Read the following template files: F<release.html>, 
F<login.html>, F<enabler.html>, F<error.html>, F<status.html>, 
F<register.html>.

=cut

#TODO all template destination should be variables allowing redefinitions by pf::web::custom

use strict;
use warnings;

use Date::Parse;
use File::Basename;
use HTML::Entities;
use JSON;
use Locale::gettext;
use Log::Log4perl;
use POSIX;
use Readonly;
use Template;
use URI::Escape qw(uri_escape uri_unescape);

BEGIN {
    use Exporter ();
    our ( @ISA, @EXPORT );
    @ISA = qw(Exporter);
    # No export to force users to use full package name and allowing pf::web::custom to redefine us
    @EXPORT = qw(i18n ni18n i18n_format);
}

use pf::config;
use pf::enforcement qw(reevaluate_access);
use pf::iplog qw(ip2mac);
use pf::node qw(node_attributes node_modify node_register node_view is_max_reg_nodes_reached);
use pf::os qw(dhcp_fingerprint_view);
use pf::useragent;
use pf::util;
use pf::violation qw(violation_count);
use pf::web::auth; 

Readonly our $LOOPBACK_IPV4 => '127.0.0.1';

=head1 SUBROUTINES

Warning: The list of subroutine is incomplete

=over

=cut

sub i18n {
    my $msgid = shift;

    return gettext($msgid);
}

sub ni18n {
    my $singular = shift;
    my $plural = shift;
    my $category = shift;

    return ngettext($singular, $plural, $category);
}

=item i18n_format

Pass message id through gettext then sprintf it.

Meant to be called from the TT templates.

=cut
sub i18n_format {
    my ($msgid, @args) = @_;

    return sprintf(gettext($msgid), @args);
}

sub web_get_locale {
    my ($cgi,$session) = @_;
    my $logger = Log::Log4perl::get_logger('pf::web');
    my $authorized_locale_txt = $Config{'general'}{'locale'};
    my @authorized_locale_array = split(/\s*,\s*/, $authorized_locale_txt);
    if ( defined($cgi->url_param('lang')) ) {
        $logger->info("url_param('lang') is " . $cgi->url_param('lang'));
        my $user_chosen_language = $cgi->url_param('lang');
        if (grep(/^$user_chosen_language$/, @authorized_locale_array) == 1) {
            $logger->info("setting language to user chosen language "
                 . $user_chosen_language);
            $session->param("lang", $user_chosen_language);
            return $user_chosen_language;
        }
    }
    if ( defined($session->param("lang")) ) {
        $logger->info("returning language " . $session->param("lang")
            . " from session");
        return $session->param("lang");
    }
    return $authorized_locale_array[0];
}

=item _render_template

Cuts in the session cookies and template rendering boiler plate.

=cut
sub _render_template {
    my ($portalSession, $template, $vars_ref, $r) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);
    # so that we will get the calling sub in the logs instead of this utility sub
    local $Log::Log4perl::caller_depth = $Log::Log4perl::caller_depth + 1;

    # add generic components to template's vars
    $vars_ref->{'logo'} = $portalSession->getProfile->getLogo;
    $vars_ref->{'i18n'} = \&i18n;
    $vars_ref->{'i18n_format'} = \&i18n_format;

    my $cgi = $portalSession->getCgi;
    my $session = $portalSession->getSession;

    my $cookie = $cgi->cookie( CGISESSID => $session->id );
    print $cgi->header( -cookie => $cookie );

    $logger->debug("rendering template named $template");
    my $tt = Template->new({ 
        INCLUDE_PATH => [$CAPTIVE_PORTAL{'TEMPLATE_DIR'} . $portalSession->getProfile->getTemplatePath], 
    });
    $tt->process( $template, $vars_ref, $r ) || do {
        $logger->error($tt->error());
        return $FALSE;
    };
    return $TRUE;
}

sub generate_release_page {
    my ( $portalSession, $r ) = @_;
    my $logger = Log::Log4perl::get_logger('pf::web');

    # First blast at consuming portalSession object
    my $cgi             = $portalSession->getCgi();
    my $session         = $portalSession->getSession();

    setlocale( LC_MESSAGES, web_get_locale($cgi, $session) );
    bindtextdomain( "packetfence", "$conf_dir/locale" );
    textdomain("packetfence");

    my $vars = {
        logo            => $portalSession->getProfile->getLogo,
        timer           => $Config{'trapping'}{'redirtimer'},
        destination_url => encode_entities($portalSession->getDestinationUrl),
        redirect_url => $Config{'trapping'}{'redirecturl'},
        i18n => \&i18n,
        initial_delay => $CAPTIVE_PORTAL{'NET_DETECT_INITIAL_DELAY'},
        retry_delay => $CAPTIVE_PORTAL{'NET_DETECT_RETRY_DELAY'},
        external_ip => $Config{'captive_portal'}{'network_detection_ip'},
        auto_redirect => $Config{'captive_portal'}{'network_detection'},
        list_help_info  => [
            { name => i18n('IP'),  value => $portalSession->getClientIp },
            { name => i18n('MAC'), value => $portalSession->getClientMac }
        ],
    };

    # override destination_url if we enabled the always_use_redirecturl option
    if (isenabled($Config{'trapping'}{'always_use_redirecturl'})) {
        $vars->{'destination_url'} = $Config{'trapping'}{'redirecturl'};
    }

    my $html_txt;
    my $template = Template->new({ 
        INCLUDE_PATH => [$CAPTIVE_PORTAL{'TEMPLATE_DIR'} . $portalSession->getProfile->getTemplatePath],
    });
    $template->process( "release.html", $vars, \$html_txt ) || $logger->error($template->error());
    
    my $cookie = $cgi->cookie( CGISESSID => $session->id );
    print $cgi->header(
        -cookie         => $cookie,
        -Content_length => length($html_txt),
        -Connection     => 'Close'
    );
    if ($r) { print $r->print($html_txt); }
    else    { print STDOUT $html_txt; }
}

=item supports_mobileconfig_provisioning

Validating that the node supports mobile configuration provisioning, that it's configured 
and that the node's category matches the configuration.

=cut
sub supports_mobileconfig_provisioning {
    my ( $portalSession ) = @_;
    my $logger = Log::Log4perl::get_logger('pf::web');

    return $FALSE if (isdisabled($Config{'provisioning'}{'autoconfig'}));

    # is this an iDevice?
    # TODO get rid of hardcoded targets like that
    my $node_attributes = node_attributes($portalSession->getClientMac);
    my @fingerprint = dhcp_fingerprint_view($node_attributes->{'dhcp_fingerprint'});
    return $FALSE if (!defined($fingerprint[0]->{'os'}) || $fingerprint[0]->{'os'} !~ /Apple iPod, iPhone or iPad/); 

    # do we perform provisioning for this category?
    my $config_category = $Config{'provisioning'}{'category'};
    my $node_cat = $node_attributes->{'category'};

    # validating that the node is under the proper category for mobile config provioning
    return $TRUE if ( $config_category eq 'any' || (defined($node_cat) && $node_cat eq $config_category));

    # otherwise
    return $FALSE;
}

=item generate_mobileconfig_provisioning_page

Offers a page that links to the proper provisioning XML.

=cut
sub generate_mobileconfig_provisioning_page {
    my ( $portalSession ) = @_;
    my $logger = Log::Log4perl::get_logger('pf::web');

    # First blast at portalSession object consumption
    my $cgi     = $portalSession->getCgi;
    my $session = $portalSession->getSession;

    setlocale( LC_MESSAGES, web_get_locale($cgi, $session) );
    bindtextdomain( "packetfence", "$conf_dir/locale" );
    textdomain("packetfence");

    my $vars = {
        list_help_info  => [
            { name => i18n('IP'),  value => $portalSession->getClientIp },
            { name => i18n('MAC'), value => $portalSession->getClientMac }
        ],
    };

    _render_template($portalSession, 'release_with_xmlconfig.html', $vars);
}

=item generate_apple_mobileconfig_provisioning_xml

Generate the proper .mobileconfig XML to automatically configure Wireless for iOS devices.

=cut
sub generate_apple_mobileconfig_provisioning_xml {
    my ( $portalSession ) = @_;
    my $logger = Log::Log4perl::get_logger('pf::web');

    # First blast at consuming portalSession object
    my $cgi     = $portalSession->getCgi();
    my $session = $portalSession->getSession();

    # if not logged in, disallow access
    if (!defined($session->param('username'))) {
        pf::web::generate_error_page(
            $portalSession,
            i18n("You need to be authenticated to access this page.")
        );
        exit(0);
    }

    my $vars = {
        username => $session->param('username'),
        ssid => $Config{'provisioning'}{'ssid'},
    };

    # Some required headers
    # http://www.rootmanager.com/iphone-ota-configuration/iphone-ota-setup-with-signed-mobileconfig.html
    print $cgi->header( 'Content-type: application/x-apple-aspen-config; chatset=utf-8' );
    print $cgi->header( 'Content-Disposition: attachment; filename="wireless-profile.mobileconfig"' );

    # Using TT to render the XML with correct variables populated
    my $template = Template->new({ 
        INCLUDE_PATH => [$CAPTIVE_PORTAL{'TEMPLATE_DIR'} . $portalSession->getProfile->getTemplatePath],
    });
    $template->process( "wireless-profile.xml", $vars ) || $logger->error($template->error());
}

sub generate_scan_start_page {
    my ( $portalSession, $r ) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    # First blast at portalSession object consumption
    my $cgi             = $portalSession->getCgi;
    my $session         = $portalSession->getSession;

    setlocale( LC_MESSAGES, web_get_locale($cgi, $session) );
    bindtextdomain( "packetfence", "$conf_dir/locale" );
    textdomain("packetfence");

    my $vars = {
        logo            => $portalSession->getProfile->getLogo,
        timer           => $Config{'scan'}{'duration'},
        destination_url => encode_entities($portalSession->getDestinationUrl),
        i18n => \&i18n,
        txt_message     => sprintf(
            i18n("system scan in progress"),
            $Config{'scan'}{'duration'}
        ),
        list_help_info  => [
            { name => i18n('IP'),  value => $portalSession->getClientIp },
            { name => i18n('MAC'), value => $portalSession->getClientMac }
        ],
    };
    # Once the progress bar is over, try redirecting
    my $html_txt;
    my $template = Template->new({ 
        INCLUDE_PATH => [$CAPTIVE_PORTAL{'TEMPLATE_DIR'} . $portalSession->getProfile->getTemplatePath],
    });
    $template->process( "scan.html", $vars, \$html_txt ) || $logger->error($template->error());
    my $cookie = $cgi->cookie( CGISESSID => $session->id );
    print $cgi->header(
        -cookie         => $cookie,
        -Content_length => length($html_txt),
        -Connection     => 'Close'
    );
    if ($r) { $r->print($html_txt); }
    else    { print STDOUT $html_txt; }
}

sub generate_login_page {
    my ( $portalSession, $err ) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    # First blast at consuming portalSession object
    my $cgi             = $portalSession->getCgi();
    my $session         = $portalSession->getSession();

    setlocale( LC_MESSAGES, web_get_locale($cgi, $session) );
    bindtextdomain( "packetfence", "$conf_dir/locale" );
    textdomain("packetfence");

    my $vars = {
        destination_url => encode_entities($portalSession->getDestinationUrl),
        list_help_info  => [
            { name => i18n('IP'),  value => $portalSession->getClientIp },
            { name => i18n('MAC'), value => $portalSession->getClientMac }
        ],
    };

    $vars->{'guest_allowed'} = isenabled($portalSession->getProfile->getGuestSelfReg);
    $vars->{'txt_auth_error'} = i18n($err) if (defined($err)); 

    # return login
    $vars->{'username'} = encode_entities($cgi->param("username"));

    # authentication
    $vars->{selected_auth} = encode_entities($cgi->param("auth")) || $portalSession->getProfile->getDefaultAuth; 
    $vars->{list_authentications} = pf::web::auth::list_enabled_auth_types();

    _render_template($portalSession, 'login.html', $vars);
}

sub generate_enabler_page {
    my ( $portalSession, $violation_id, $enable_text ) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    # First blast of portalSession object consumption
    my $cgi = $portalSession->getCgi();
    my $session = $portalSession->getSession();

    setlocale( LC_MESSAGES, web_get_locale($cgi, $session) );
    bindtextdomain( "packetfence", "$conf_dir/locale" );
    textdomain("packetfence");

    my $vars = {
        destination_url => encode_entities($portalSession->getDestinationUrl),
        violation_id    => $violation_id,
        enable_text     => $enable_text,
    };

    _render_template($portalSession, 'enabler.html', $vars);
}

sub generate_redirect_page {
    my ( $portalSession, $violation_url ) = @_;
    my $logger = Log::Log4perl::get_logger('pf::web');

    # First blast of portalSession object consumption
    my $cgi = $portalSession->getCgi();
    my $session = $portalSession->getSession();

    setlocale( LC_MESSAGES, web_get_locale($cgi, $session) );
    bindtextdomain( "packetfence", "$conf_dir/locale" );
    textdomain("packetfence");

    my $vars = {
        violation_url   => $violation_url,
        destination_url => encode_entities($portalSession->getDestinationUrl),
    };

    _render_template($portalSession, 'redirect.html', $vars);
}

=item generate_aup_standalone_page

Called when someone clicked on /aup which is the pop=up URL for mobile phones.

=cut
sub generate_aup_standalone_page {
    my ( $portalSession ) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    # First blast at consuming portalSession object
    my $cgi     = $portalSession->getCgi();
    my $session = $portalSession->getSession();

    setlocale( LC_MESSAGES, web_get_locale($cgi, $session) );
    bindtextdomain( "packetfence", "$conf_dir/locale" );
    textdomain("packetfence");

    my $vars = {
        list_help_info  => [
            { name => i18n('IP'),  value => $portalSession->getClientIp },
            { name => i18n('MAC'), value => $portalSession->getClientMac }
        ],
    };

    _render_template($portalSession, 'aup.html', $vars);
}

sub generate_scan_status_page {
    my ( $portalSession, $scan_start_time, $r ) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    my $refresh_timer = 10; # page will refresh each 10 seconds

    # First blast of portalSession object consumption
    my $cgi = $portalSession->getCgi();
    my $session = $portalSession->getSession();

    setlocale( LC_MESSAGES, web_get_locale($cgi, $session) );
    bindtextdomain( "packetfence", "$conf_dir/locale" );
    textdomain("packetfence");

    my $vars = {
        txt_message      => i18n_format('scan in progress contact support if too long', $scan_start_time),
        txt_auto_refresh => i18n_format('automatically refresh', $refresh_timer),
        destination_url  => encode_entities($portalSession->getDestinationUrl),
        refresh_timer    => $refresh_timer,
        list_help_info  => [
            { name => i18n('IP'),  value => $portalSession->getClientIp },
            { name => i18n('MAC'), value => $portalSession->getClientMac }
        ],
    };

    _render_template($portalSession, 'scan-in-progress.html', $vars, $r);
}

sub generate_error_page {
    my ( $portalSession, $error_msg, $r ) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    # First blast of portalSession object consumption
    my $cgi = $portalSession->getCgi();
    my $session = $portalSession->getSession();

    setlocale( LC_MESSAGES, web_get_locale($cgi, $session) );
    bindtextdomain( "packetfence", "$conf_dir/locale" );
    textdomain("packetfence");

    my $vars = {
        txt_message => $error_msg,
        list_help_info  => [
            { name => i18n('IP'),   value => $portalSession->getClientIp },
            { name => i18n('MAC'),  value => $portalSession->getClientMac },
        ],
    };

    _render_template($portalSession, 'error.html', $vars, $r);
}

=item generate_admin_error_page

Same behavior of pf::web::generate_error_page but consume old cgi/session paramaters rather than the new portalSession
object since this one is used in the admin portion of the web management and we didn't implement the portalSession
object in this part.

=cut
sub generate_admin_error_page {
    my ( $cgi, $session, $error_msg, $r ) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    setlocale( LC_MESSAGES, web_get_locale($cgi, $session) );
    bindtextdomain( "packetfence", "$conf_dir/locale" );
    textdomain("packetfence");

    my $vars = {
        logo => $Config{'general'}{'logo'},
        i18n => \&i18n,
        i18n_format => \&i18n_format,
        txt_message => $error_msg,
    };

    my $ip = get_client_ip($cgi);
    my $mac = ip2mac($ip);
    push @{ $vars->{list_help_info} }, { name => i18n('IP'), value => $ip };
    if ($mac) {
        push @{ $vars->{list_help_info} }, { name => i18n('MAC'), value => $mac };
    }

    my $cookie = $cgi->cookie( CGISESSID => $session->id );
    print $cgi->header( -cookie => $cookie );

    my $template = Template->new({ 
        INCLUDE_PATH => [$CAPTIVE_PORTAL{'TEMPLATE_DIR'}],
    });
    $template->process( "error.html", $vars, $r ) || $logger->error($template->error());
}

=item web_node_register

This sub is meant to be redefined by pf::web::custom to fit your specific needs.
See F<pf::web::custom> for examples.

=cut
sub web_node_register {
    my ( $portalSession, $pid, %info ) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    # First blast at consuming portalSession object
    my $cgi     = $portalSession->getCgi();
    my $session = $portalSession->getSession();

    # FIXME quick and hackish fix for #1505. A proper, more intrusive, API changing, fix should hit devel.
    my $mac;
    if (defined($portalSession->getGuestNodeMac)) {
        $mac = $portalSession->getGuestNodeMac;
    }
    else {
        $mac = $portalSession->getClientMac;
    }

    if ( is_max_reg_nodes_reached($mac, $pid, $info{'category'}) ) {
        pf::web::generate_error_page(
            $portalSession, 
            i18n("You have reached the maximum number of devices you are able to register with this username.")
        );
        exit(0);
    }

    # we are good, push the registration
    return _sanitize_and_register($session, $mac, $pid, %info);
}

sub _sanitize_and_register {
    my ( $session, $mac, $pid, %info ) = @_;
    my $logger = Log::Log4perl::get_logger('pf::web');

    $logger->info("performing node registration MAC: $mac pid: $pid");
    node_register( $mac, $pid, %info );

    unless ( defined($session->param("do_not_deauth")) && $session->param("do_not_deauth") == $TRUE ) {
        reevaluate_access( $mac, 'manage_register' );
    }

    return $TRUE;
}

=item web_node_record_user_agent

Records User-Agent for the provided node and triggers violations.

=cut
sub web_node_record_user_agent {
    my ( $mac, $user_agent ) = @_;
    my $logger = Log::Log4perl::get_logger('pf::web');
    
    # caching useragents, if it's the same don't bother triggering violations
    my $cached_useragent = $main::useragent_cache->get($mac);

    # Cache hit
    return if (defined($cached_useragent) && $user_agent eq $cached_useragent);

    # Caching and updating node's info
    $logger->trace("adding $mac user-agent to cache");
    $main::useragent_cache->set( $mac, $user_agent, "5 minutes");

    # Recording useragent
    $logger->info("Updating node $mac user_agent with useragent: '$user_agent'");
    node_modify($mac, ('user_agent' => $user_agent));

    # updates the node_useragent information and fires relevant violations triggers
    return pf::useragent::process_useragent($mac, $user_agent);
}

=item validate_form

    return (0, 0) for first attempt
    return (1) for valid form
    return (0, "Error string" ) on form validation problems

=cut
sub validate_form {
    my ( $portalSession ) = @_;
    my $logger = Log::Log4perl::get_logger('pf::web');
    $logger->trace("form validation attempt");

    # First blast at consuming portalSession object
    my $cgi     = $portalSession->getCgi();
    my $session = $portalSession->getSession();

    if ( $cgi->param("username") && $cgi->param("password") && $cgi->param("auth") ) {

        # acceptable use pocliy accepted?
        if (!defined($cgi->param("aup_signed")) || !$cgi->param("aup_signed")) {
            return ( 0 , 'You need to accept the terms before proceeding any further.' );
        }

        # validates if supplied auth type is allowed by configuration
        my $auth = $cgi->param("auth");
        my @auth_choices = split( /\s*,\s*/, $portalSession->getProfile->getAuth );
        if ( grep( { $_ eq $auth } @auth_choices ) == 0 ) {
            return ( 0, 'Unable to validate credentials at the moment' );
        }

        return (1);
    }
    return (0, 'Invalid login or password');
}

=item web_user_authenticate

    return (1, pf::web::auth subclass) for successfull authentication
    return (0, undef) for inability to check credentials
    return (0, pf::web::auth subclass) otherwise (pf::web::auth can give detailed error)

=cut
sub web_user_authenticate {
    my ( $portalSession, $auth_module ) = @_;
    my $logger = Log::Log4perl::get_logger('pf::web');
    $logger->trace("authentication attempt");

    # First blast at consuming portalSession object
    my $cgi     = $portalSession->getCgi();
    my $session = $portalSession->getSession();

    my $authenticator = pf::web::auth::instantiate($auth_module);
    return (0, undef) if (!defined($authenticator));

    # validate login and password
    my $return = $authenticator->authenticate( $cgi->param("username"), $cgi->param("password") );

    if (defined($return) && $return == 1) {
        #save login into session
        $session->param( "username", $cgi->param("username") );
        $session->param( "authType", $auth_module );
    }
    return ($return, $authenticator);
}

sub generate_registration_page {
    my ( $portalSession, $pagenumber ) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    # First blast of portalSession object consumption
    my $cgi = $portalSession->getCgi();
    my $session = $portalSession->getSession();

    $pagenumber = 1 if (!defined($pagenumber));

    setlocale( LC_MESSAGES, web_get_locale($cgi, $session) );
    bindtextdomain( "packetfence", "$conf_dir/locale" );
    textdomain("packetfence");

    my $vars = {
        deadline        => $Config{'registration'}{'skip_deadline'},
        destination_url => encode_entities($portalSession->getDestinationUrl),
        list_help_info  => [
            { name => i18n('IP'),  value => $portalSession->getClientIp },
            { name => i18n('MAC'), value => $portalSession->getClientMac }
        ],
        reg_page_content_file => "register_$pagenumber.html",
    };

    # generate list of locales
    my $authorized_locale_txt = $Config{'general'}{'locale'};
    my @authorized_locale_array = split(/,/, $authorized_locale_txt);
    if ( scalar(@authorized_locale_array) == 1 ) {
        push @{ $vars->{list_locales} },
            { name => 'locale', value => $authorized_locale_array[0] };
    } else {
        foreach my $authorized_locale (@authorized_locale_array) {
            push @{ $vars->{list_locales} },
                { name => 'locale', value => $authorized_locale };
        }
    }

    if ( $pagenumber == $Config{'registration'}{'nbregpages'} ) {
        $vars->{'button_text'} = i18n($Config{'registration'}{'button_text'});
        $vars->{'form_action'} = '/authenticate';
    } else {
        $vars->{'button_text'} = i18n("Next page");
        $vars->{'form_action'} = '/authenticate?mode=next_page&page=' . ( int($pagenumber) + 1 );
    }

    _render_template($portalSession, 'register.html', $vars);
}

=item generate_pending_page

Shows a page to user saying registration is pending.

=cut
sub generate_pending_page {
    my ( $portalSession ) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    # First blast of portalSession object consumption
    my $cgi = $portalSession->getCgi();
    my $session = $portalSession->getSession();

    setlocale( LC_MESSAGES, web_get_locale($cgi, $session) );
    bindtextdomain( "packetfence", "$conf_dir/locale" );
    textdomain("packetfence");

    my $vars = {
        list_help_info  => [
            { name => i18n('IP'),  value => $portalSession->getClientIp },
            { name => i18n('MAC'), value => $portalSession->getClientMac }
        ],
        destination_url => encode_entities($portalSession->getDestinationUrl),
        redirect_url => $Config{'trapping'}{'redirecturl'},
        initial_delay => $CAPTIVE_PORTAL{'NET_DETECT_PENDING_INITIAL_DELAY'},
        retry_delay => $CAPTIVE_PORTAL{'NET_DETECT_PENDING_RETRY_DELAY'},
        external_ip => $Config{'captive_portal'}{'network_detection_ip'},
    };

    # override destination_url if we enabled the always_use_redirecturl option
    if (isenabled($Config{'trapping'}{'always_use_redirecturl'})) {
        $vars->{'destination_url'} = $Config{'trapping'}{'redirecturl'};
    }

    _render_template($portalSession, 'pending.html', $vars);
}

=item get_client_ip

Returns IP address of the client reaching the captive portal. 
Either directly connected or through a proxy.

=cut
sub get_client_ip {
    my ($cgi) = @_;
    my $logger = Log::Log4perl::get_logger('pf::web');
    $logger->trace("request for client IP");

    # we fetch CGI's remote address
    # if user is behind a proxy it's not sufficient since we'll get the proxy's IP
    my $directly_connected_ip = $cgi->remote_addr();

    # every source IP in this table are considered to be from a proxied source
    my %proxied_lookup = %{$CAPTIVE_PORTAL{'loadbalancers_ip'}}; #load balancers first
    $proxied_lookup{$LOOPBACK_IPV4} = 1; # loopback (proxy-bypass)
    # adding virtual IP if one is present (proxy-bypass w/ high-avail.)
    $proxied_lookup{$management_network->tag('vip')} = 1 if ($management_network->tag('vip'));

    # if this is NOT from one of the expected proxy IPs return the IP
    if (!$proxied_lookup{$directly_connected_ip}) {
        return $directly_connected_ip;
    }

    # behind a proxy?
    if (defined($ENV{'HTTP_X_FORWARDED_FOR'})) {
        my $proxied_ip = $ENV{'HTTP_X_FORWARDED_FOR'};
        $logger->debug(
            "Remote Address is $directly_connected_ip. Client is behind proxy? "
            . "Returning: $proxied_ip according to HTTP Headers"
        );
        return $proxied_ip;
    }

    $logger->debug("Remote Address is $directly_connected_ip but no further hints of client IP in HTTP Headers");
    return $directly_connected_ip;
}

=item end_portal_session

Call after you made your changes to the user / node. 
This takes care of handling violations, bouncing back to http for portal 
network access detection or handling mobile provisionning.

This was done in several different locations making maintenance more difficult than it should.
It was regrouped here.

=cut
sub end_portal_session {
    my ( $portalSession ) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    # First blast at handling portalSession object
    my $cgi             = $portalSession->getCgi();
    my $session         = $portalSession->getSession();
    my $mac             = $portalSession->getClientMac();
    my $destination_url = $portalSession->getDestinationUrl();

    # violation handling
    my $count = violation_count($mac);
    if ($count != 0) {
      print $cgi->redirect('/captive-portal?destination_url=' . uri_escape($destination_url));
      $logger->info("more violations yet to come for $mac");
      exit(0);
    }

    # handle mobile provisioning if relevant
    if (pf::web::supports_mobileconfig_provisioning($portalSession)) {
        pf::web::generate_mobileconfig_provisioning_page($portalSession);
        exit(0);
    }

    # we drop HTTPS so we can perform our Internet detection and avoid all sort of certificate errors
    if ($cgi->https()) {
        print $cgi->redirect(
            "http://".$Config{'general'}{'hostname'}.".".$Config{'general'}{'domain'}
            .'/access?destination_url=' . uri_escape($destination_url)
        );
        exit(0);
    } 

    pf::web::generate_release_page($portalSession);
    exit(0);
}

=item generate_generic_page

Present a generic page. Template and arguments provided to template passed as arguments

=cut
sub generate_generic_page {
    my ( $portalSession, $template, $template_args ) = @_;
    my $logger = Log::Log4perl::get_logger(__PACKAGE__);

    # First blast at consuming portalSession object
    my $cgi     = $portalSession->getCgi();
    my $session = $portalSession->getSession();

    setlocale( LC_MESSAGES, pf::web::web_get_locale($cgi, $session) );
    bindtextdomain( "packetfence", "$conf_dir/locale" );
    textdomain("packetfence");

    my $vars = $template_args;
    $vars->{'list_help_info'} = [
        { name => i18n('IP'),  value => $portalSession->getClientIp },
        { name => i18n('MAC'), value => $portalSession->getClientMac }
    ];

    _render_template($portalSession, $template, $vars);
}

=back

=head1 AUTHOR

David LaPorte <david@davidlaporte.org>

Kevin Amorin <kev@amorin.org>

Dominik Gehl <dgehl@inverse.ca>

Olivier Bilodeau <obilodeau@inverse.ca>

Derek Wuelfrath <dwuelfrath@inverse.ca>

=head1 COPYRIGHT

Copyright (C) 2005 David LaPorte

Copyright (C) 2005 Kevin Amorin

Copyright (C) 2008-2012 Inverse inc.

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

1;
