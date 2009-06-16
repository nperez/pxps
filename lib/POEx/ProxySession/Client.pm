package POEx::ProxySession::Client;
use 5.010;

#ABSTRACT: Proxies remote, published Sessions, or publishes, local Sessions for subscription

use MooseX::Declare;
$Storable::forgive_me = 1;

=head1 SYNOPSIS

    # on the publisher side
    class Foo with POEx::Role::SessionInstantiation
    {
        use aliased 'POEx::Role::Event';
        use aliased 'POEx::Role::ProxyEvent';
        
        # The event we want to expose
        method yarg() {  } is ProxyEvent
        
        after _start(@args) is Event
        {
            POEx::ProxySession::Client->new
            ( 
                alias   => 'Client',
                options => { trace => 1, debug => 1 },
            );

            $self->post
            (
                'Client', 
                'connect', 
                remote_address  => '127.0.0.1', 
                remote_port     => 56789,
                return_event    => 'post_connect'
            );
        }

        method post_connect
        (
            WheelID :$connection_id, 
            Str :$remote_address, 
            Int :$remote_port
        ) is Event
        {
            $self->post
            (
                'Client',
                'publish',
                connection_id   => $connection_id,
                session_alias   => 'FooSession',
                session         => $self,
                return_event    => 'check_publish'
            );
        }

        .....
    }

    # on the subscriber side
    class Bar with POEx::Role::SessionInstantiation
    {
        use aliased 'POEx::Role::Event';
        use aliased 'POEx::Role::ProxyEvent';
        
        after _start(@args) is Event
        {
            POEx::ProxySession::Client->new
            ( 
                alias   => 'Client',
                options => { trace => 1, debug => 1 },
            );

            $self->post
            (
                'Client', 
                'connect', 
                remote_address  => '127.0.0.1', 
                remote_port     => 56789,
                return_event    => 'post_connect'
            );
        }

        method post_connect
        (
            WheelID :$connection_id, 
            Str :$remote_address, 
            Int :$remote_port
        ) is Event
        {
            $self->post
            (
                'Client',
                'subscribe',
                connection_id   => $connection_id,
                to_session      => 'FooSession',
                return_event    => 'post_subscription',
            );
        }
        
        method post_subscription(Bool :$success, Str :$session_name, Ref :$payload?) is Event
        {
            if($success)
            {
                $self->post('FooSession', 'yarg');
            }
        }
    }

=cut

class POEx::ProxySession::Client with (POEx::Role::TCPClient, POEx::ProxySession::MessageSender)
{
    use 5.010;
    use POEx::ProxySession::Types(':all');
    use POEx::Types(':all');
    use POE::Filter::Reference;
    use MooseX::Types::Moose(':all');
    use MooseX::Types::Structured('Tuple');
    use MooseX::AttributeHelpers;
    use Moose::Util('does_role');
    use Storable('thaw', 'nfreeze');
    use signatures;
    use Socket;

    use aliased 'POEx::Role::Event';
    use aliased 'POEx::Role::ProxyEvent';
    use aliased 'MooseX::Method::Signatures::Meta::Method', 'MXMSMethod';

=attr subscriptions metaclass => MooseX::AttributeHelpers::Collection::Hash

This attribute is used to store the various subscriptions made through the
client. It has no accessors beyond what are defined in the provides mechanism.

    provides    => 
    {
        get     => 'get_subscription',
        set     => 'set_subscription',
        delete  => 'delete_subscription',
        count   => 'count_subscriptions',
        keys    => 'all_subscription_names',
        exists  => 'has_subscription',
    }

Each instance of a subscription is actually stored as a hash with the following
keys:

    Subscription =>
    {
        meta    => isa Moose::Meta::Class,
        wheel   => isa WheelID
    }

=cut

    has subscriptions =>
    (
        metaclass   => 'MooseX::AttributeHelpers::Collection::Hash',
        isa         => HashRef,
        lazy        => 1,
        default     => sub { {} },
        clearer     => 'clear_subscriptions',
        provides    => 
        {
            get     => 'get_subscription',
            set     => 'set_subscription',
            delete  => 'delete_subscription',
            count   => 'count_subscriptions',
            keys    => 'all_subscription_names',
            exists  => 'has_subscription',
        }
    );


=attr publications metaclass => MooseX::AttributeHelpers::Collection::Hash

This attribute is used to store all publications made through the client. It 
has no accessors beyond what are defined in the provides mechanism.
    
    provides    => 
    {
        get     => 'get_publication',
        set     => 'set_publication',
        delete  => 'delete_publication',
        count   => 'count_publications',
        keys    => 'all_publication_names',
        exists  => 'has_publication',
    }

Each instance of a publication is stored as a hash with the following keys:

    Publication =>
    {
        meta            => isa Moose::Meta::Class,
        wheel           => isa WheelID,
        session_alias   => isa SessionAlias,
    }

=cut

    has publications =>
    (
        metaclass   => 'MooseX::AttributeHelpers::Collection::Hash',
        isa         => HashRef,
        lazy        => 1,
        default     => sub { {} },
        clearer     => 'clear_publications',
        provides    => 
        {
            get     => 'get_publication',
            set     => 'set_publication',
            delete  => 'delete_publication',
            count   => 'count_publications',
            keys    => 'all_publication_names',
            exists  => 'has_publication',
        }
    );


=attr unknown_message_event is: 'ro', isa: Tuple[SessionAlias, Str]

Set this attribute to receive unknown messages that were sent to the client. 
This is handy for sending custom message types across the Server.

The event handler must have this signature:
(ProxyMessage $data, WheelID $id)

=cut

    has unknown_message_event =>
    (
        is          => 'ro',
        isa         => Tuple[SessionAlias, Str],
        predicate   => 'has_unknown_message_event',
    );

=method after _start(@args) is Event

The _start method is advised to hardcode the filter to use as a 
POE::Filter::Reference instance.

=cut

    after _start(@args) is Event
    {
        $self->filter(POE::Filter::Reference->new());
    }

=method around connect(Str :$remote_address,Int :$remote_port, SessionAlias|SessionID|Session|DoesSessionInstantiation :$return_session?,Str :$return_event,Ref :$tag?) is Event

The connect method is advised to add additional parameters in the form of a
return session and return event to use once the connection has been 
established.

The return event will need the following signature:
(WheelID :$connection_id, Str :$remote_address, Int :$remote_port, Ref :tag?)

=cut

    around connect
    (
        Str :$remote_address, 
        Int :$remote_port, 
        SessionAlias|SessionID|Session|DoesSessionInstantiation :$return_session?, 
        Str :$return_event,
        Ref :$tag?
    ) is Event
    {
        my $connect_tag = 
        {
            address         => $remote_address,
            port            => $remote_port,
            return_session  => $return_session // $self->poe->sender->ID, 
            return_event    => $return_event,
            inner_tag       => $tag,
        };

        $orig->($self, remote_address => $remote_address, remote_port => $remote_port, tag => $connect_tag);
    }

=method after handle_on_connect(GlobRef $socket, Str $address, Int $port, WheelID $id) is Event

handle_on_connect is advised to find the specified return session and event
and post the message with the paramters received from the socketfactory

=cut

    after handle_on_connect(GlobRef $socket, Str $address, Int $port, WheelID $id) is Event
    {
        if($self->has_connection_tag($id))
        {
            my $tag = $self->delete_connection_tag($id);
            $self->post
            (
                $tag->{return_session},
                $tag->{return_event},
                connection_id   => $self->last_wheel,
                remote_address  => inet_ntoa($address),
                remote_port     => $port,
                tag             => $tag->{inner_tag}
            );
        }
        else
        {
            die "Unknown connection made. No connection tag associated with socket factory '$id'";
        }
    }

=method handle_inbound_data(ProxyMessage $data, WheelID $id) is Event

Our implementation of handle_inbound_data expects a ProxyMessage as data. Here 
is where the handling and routing of messages lives. Only handles two types of
ProxyMessage: result, and deliver. For more information on ProxyMessage types,
see the POD in POEx::ProxySession::Types. If an unknown message type is
encountered and unknown_message_event is set, it will be delivered to there.

=cut

    method handle_inbound_data(ProxyMessage $data, WheelID $id) is Event
    {
        given($data->{type})
        {
            when ('result')
            {
                if($self->has_pending($data->{id}))
                {
                    my $pending = $self->delete_pending($data->{id});
                    $self->post($pending->{return_session}, $pending->{return_event}, $data, $id, $pending->{tag});
                }
                else
                {
                    warn q|Received a result for something we didn't send out|;
                    return;
                }
            }
            when ('deliver')
            {
                if($self->has_publication($data->{to}))
                {
                    my $payload = thaw($data->{payload});
                    my $success = $self->post($data->{to}, $payload->{event}, @{ $payload->{args} });
                    my $back = \${q|Unable to post '| . $payload->{event} . q|' to '| . $data->{to} . q|'|} if !$success;
                    
                    $self->send_result
                    (
                        success     => $success, 
                        original    => $data,
                        payload     => $back // \'', 
                        wheel_id    => $id
                    );
                }
                else
                {
                    warn q|Received a delivery for someone that isn't us|;

                    $self->send_result
                    (
                        success     => 0,
                        original    => $data,
                        payload     => \'Unknown recipient',
                        wheel_id    => $id,
                    );

                }
            }
            default
            {
                if($self->has_unknown_message_event)
                {
                    $self->post
                    (
                        $self->unknown_message_event->[0],
                        $self->unknown_message_event->[1],
                        $data,
                        $id
                    );
                }
            }
        }
    }

=method subscribe(WheelID :$connection_id, SessionAlias :$to_session, SessionAlias|SessionID|Session|DoesSessionInstantiation :$return_session?,Str :$return_event, Ref :$tag?) is Event

subscribe sends a message out to the server, and the handler receives the 
appropriate metadata and constructs a local, persistent session that proxies 
posts back to the publisher. Once the session is finished constructing itself
it will post a message to the provided return event.

The return event must have the following signature:
(WheelID :$connection_id, Bool :$success, SessionAlias :$session_name, Ref :$payload, Ref :$tag?)

Since subscription can fail, $success will indicate whether it succeeded or not
and if not $payload will be a scalar reference to a string explaining why.

Otherwise, if subscription was successful, $payload will contain the original
payload from the server containing the metadata.

=cut
    method subscribe
    (
        WheelID :$connection_id,
        SessionAlias :$to_session, 
        SessionAlias|SessionID|Session|DoesSessionInstantiation :$return_session?, 
        Str :$return_event,
        Ref :$tag?
    ) is Event
    {
        $return_session = $return_session // $self->poe->sender;
        
        my %data = 
        (
            id => -1,
            type => 'subscribe', 
            to => $to_session, 
            payload => nfreeze(\$to_session) 
        );
        
        $self->return_to_sender
        (
            message         => \%data, 
            wheel_id        => $connection_id, 
            return_session  => $self->ID, 
            return_event    => 'handle_on_subscribe',
            tag             =>
            {
                session         => $to_session,
                return_session  => $return_session,
                return_event    => $return_event,
                inner_tag       => $tag,
            }
        );
    }

    method handle_on_subscribe(ProxyMessage $data, WheelID $id, HashRef $tag) is Event
    {
        if($data->{success})
        {
            my $payload = thaw($data->{payload});
            my ($session_name, $meta) = @$payload{'session', 'meta'};
            my $self_address = $self->alias // $self->ID;
            
            bless($meta, 'Moose::Meta::Class');
            
            my $anon = class with POEx::Role::SessionInstantiation
            {
                use Class::MOP;
                use MooseX::Types::Moose(':all');
                use POEx::Types(':all');
                use POEx::ProxySession::Types(':all');
                use Storable('thaw', 'nfreeze');

                use aliased 'POEx::Role::Event';


                after _start(@args) is Event
                {
                    $self->post
                    (
                        $tag->{return_session}, 
                        $tag->{return_event},
                        connection_id   => $id,
                        success         => $data->{success},
                        session_name    => $session_name,
                        payload         => $payload,
                        tag             => $tag->{inner_tag}
                    );

                    $self->poe->kernel->detach_myself();
                }

                method proxy_send_failure(ProxyMessage $data, WheelID $id, HashRef $tag) is Event
                {
                    warn 'A proxy call to '. $tag->{session_name} . ':'. $tag->{event_name} .
                    ' with the arguments [ ' . join(', ', @{ $tag->{args} }) . ' ] failed: '.
                    thaw($data->{payload}) if !$data->{success};
                }

                method shutdown() is Event
                {
                    $self->clear_alias;
                }
            };
            
            my $methods = $meta->{methods};
            foreach my $name (keys %$methods)
            {
                my $method = $methods->{$name};
                if($method->isa('Class::MOP::Method::Wrapped'))
                {
                    my $orig = $method->get_original_method;
                    if(!$orig->meta->isa('Moose::Meta::Class') || !$orig->meta->does_role(ProxyEvent))
                    {
                        next;
                    }
                    else
                    {
                        $method = $orig;
                    }

                }
                elsif(!$method->meta->isa('Moose::Meta::Class') || !$method->meta->does_role(ProxyEvent))
                {
                    next;
                }
                
                # making this assumption is okay for now
                bless($method, MXMSMethod);
                
                # build our closure proxy method
                my $code = sub
                {
                    my ($obj, @args) = @_;
                    my $load = { event => $name, args => \@args };

                    my $msg =
                    {
                        id => -1,
                        type => 'deliver',
                        to => $session_name,
                        payload => nfreeze($load),
                    };

                    $obj->post
                    (
                        $self_address, 
                        'return_to_sender', 
                        message         => $msg, 
                        wheel_id        => $id,
                        return_session  => $obj->ID,
                        return_event    => 'proxy_send_failure',
                        tag             => 
                        {
                            session_name    => $session_name,
                            event_name      => $name,
                            args            => \@args,
                        }
                    );
                };

                
                my %args;
                
                $args{name} = $name;
                $args{package_name} = $self->meta->name;
                $args{signature} = $method->signature // '(@args)';
                $args{return_signature} = $method->return_signature if defined $method->return_signature;
                $args{body} = $code;
                
                if($method->has_traits)
                {
                    # make sure all the method traits are loaded
                    map { Class::MOP::load_class($_) } keys %{$method->traits};
                    $args{traits} = $method->traits;
                }
                
                my $new_meth = MXMSMethod->wrap(%args);
                Event->meta->apply($new_meth) if not does_role($new_meth, Event);
                $anon->add_method($name, $new_meth);
            }

            $self->set_subscription($session_name, { meta => $anon, wheel => $id});
            
            $anon->name->new(alias => $session_name, options => { trace => 1, debug => 1});
        }
        else
        {
            $self->post
            (
               $tag->{return_session},
               $tag->{return_event},
               connection_id    => $id,
               success          => $data->{success},
               session_name     => $tag->{session},
               payload          => thaw($data->{payload}),
               tag              => $tag->{inner_tag},
            );
        }
    }

=method unsubscribe(SessionAlias :$session_name, SessionAlias|SessionID|Session|DoesSessionInstantiation :$return_session?, Str :$return_event, Ref :$tag) is Event

To unsubscribe from a proxied session, use this method. This will destroy the 
session by removing its alias. Only pending events will keep the session alive.

If it happens such that the session no longer exists, the return event will be 
posted right away, other wise, _stop on the proxied session is advised to post
the return event.

The return event must have the following signature:
(Bool :$success, SessionAlias :$session_alias, Ref :$tag?)


=cut

    method unsubscribe
    (
        SessionAlias :$session_name, 
        SessionAlias|SessionID|Session|DoesSessionInstantiation :$return_session?, 
        Str :$return_event,
        Ref :$tag?
    ) is Event
    {
        die "Unknown session '$session_name'"
            if not $self->has_subscription($session_name);

        my $session = to_Session($session_name);
        
        $return_session = $return_session // $self->poe->sender;
        
        if(!$session)
        {
            $self->delete_subscription($session_name);
            $self->post
            (
                $return_session, 
                $return_event,
                success         => 1,
                session_alias   => $session_name,
                tag             => $tag,
            );
            return;
        }
        
        my $meta = $session->meta;
        my $closure = sub { $self->delete_subscription($session_name) };
        $meta->add_after_method_modifer
        (
            '_stop', 
            sub ($obj) 
            { 
                $obj->post
                (
                    $return_session , 
                    $return_event,
                    success         => 1,
                    session_alias   => $obj->alias,
                    tag             => $tag,
                );

                $closure->(); 
            } 
        );

        $self->post($session_name, 'shutdown');
    }

=method publish(WheelID :$connection_id, SessionAlias :$session_alias, DoesSessionInstantiation :$session, SessionAlias|SessionID|Session|DoesSessionInstantiation :$return_session?, Str :$return_event, Ref :$tag?) is Event

This method will publish a particular session to the server, such that other 
clients can then subscribe.

The connection_id is required to know where to send the publish message. Keep
track of each connection_id received from connect() to know where publications
should happen. The session_alias argument is how the session should be 
addressed on the server. The alias will be used by subscribing clients.

Currently, only sessions that are composed of POEx::Role::SessionInstantiation
are supported and as such, a reference a session that does that role is 
required to allow the proper introspection on the subscriber end.

To indicate which methods should be proxied, simply decorate them with the 
POEx::Role::ProxyEvent role. All other methods will be ignored in proxy 
creation.

The return event must have the following signature:
(WheelID :$connection_id, Bool :$success, SessionAlias :$session_alias, Ref :$payload?, Ref :$tag?)

Since publication can fail, $success will indicate whether it succeeded or not
and if not $payload will be a scalar reference to a string explaining why.

Otherwise, if publication was successful, $payload will contain the original
payload from the server containing the metadata.

=cut

    method publish
    (
        WheelID :$connection_id, 
        SessionAlias :$session_alias, 
        DoesSessionInstantiation :$session, 
        SessionAlias|SessionID|Session|DoesSessionInstantiation :$return_session?, 
        Str :$return_event,
        Ref :$tag?
    ) is Event
    {
        my $meta = $session->meta;

        my %payload = ( session_name => $session->alias // $session->ID, session_alias => $session_alias, meta => $meta ); 
        my $frozen;
        {
            local $SIG{__WARN__} = sub { };
            $frozen = nfreeze(\%payload);
        }
        my %data = 
        (
            id => -1,
            type => 'publish',
            payload => $frozen,
        );

        my %rtstag = 
        (
            %payload,
            return_session  => $return_session // $self->poe->sender->ID,
            return_event    => $return_event,
            inner_tag       => $tag,
        );

        $self->return_to_sender
        (
            message         => \%data, 
            wheel_id        => $connection_id, 
            return_session  => $self->ID, 
            return_event    => 'handle_on_publish', 
            tag             => \%rtstag
        );
    }

    method handle_on_publish(ProxyMessage $data, WheelID $id, HashRef $tag) is Event
    {
        if($data->{success})
        {
            $self->set_publication
            (
                $tag->{session_name},
                {
                    meta => $tag->{meta},
                    wheel => $id,
                    alias => $tag->{session_alias},
                }
            );
        }

        my %args = ( success => $data->{success}, session_alias => $tag->{session_alias} );
        $args{payload} = thaw($data->{payload}) if defined($data->{payload});

        $self->post
        (
            $tag->{return_session}, 
            $tag->{return_event},
            connection_id => $id,
            %args,
            tag => $tag->{inner_tag}
        );
    }

=method rescind(DoesSessionInstantiation :$session, SessionAlias|SessionID|Session|DoesSessionInstantiation :$return_session?, Str :$return_event, Ref :$tag?) is Event

To take back a publication, use this method and pass it the session reference.

The return event must have the following signature:
(WheelID :$connection_id, Bool :$success, SessionAlias :$session_name, Ref :$payload?, Ref :$tag?)

Since rescinding can fail, $success will let you know if it did. And if it did,
$payload will be a reference a string explaining why. Otherwise, payload will
be undef.

=cut

    method rescind
    (
        DoesSessionInstantiation :$session, 
        SessionAlias|SessionID|Session|DoesSessionInstantiation :$return_session?, 
        Str :$return_event,
        Ref :$tag?
    ) is Event
    {
        my $name = $session->alias // $session->ID;
        die "Session '$name' is not currently published"
            if not $self->has_publication($name);

        my $hash = $self->get_publication($name);
        
        $self->return_to_sender
        (
            message         => 
            {
                id => -1,
                type => 'rescind', 
                payload => nfreeze( { session_alias => $hash->{alias} } ) 
            }, 
            wheel_id        => $hash->{wheel},
            return_session  => $self->ID,
            return_event    => 'handle_on_rescind',
            tag             =>
            {
                session         => $name,
                return_session  => $return_session // $self->poe->sender,
                return_event    => $return_event,
                inner_tag       => $tag,
            }
        );
    }

    method handle_on_rescind(ProxyMessage $data, WheelID $id, HashRef $tag) is Event
    {
        if($data->{success})
        {
            $self->delete_publication($tag->{session});
        }

        my %args = ( success => $data->{success}, session_name => $tag->{session} );
        $args{payload} = thaw($data->{payload}) if defined($data->{payload});

        $self->post
        (
            $tag->{return_session}, 
            $tag->{return_event},
            connection_id => $id,
            %args,
            tag => $tag->{inner_tag}
        );
    }

=method server_listing(WheelID :$connection_id, SessionAlias|SessionID|Session|DoesSessionInstantiation :$return_session?, Str :$return_event, Ref :$tag?) is Event

server_listing will query a particular server for a list of all published 
sessions that it knows about. It returns it as an array of session aliases
suitable for subscription.

The return event must have the following signature:
(WheelID :$connection_id, Bool :$success, ArrayRef :$payload, Ref :$tag?)

=cut

    method server_listing
    (
        WheelID :$connection_id, 
        SessionAlias|SessionID|Session|DoesSessionInstantiation :$return_session?, 
        Str :$return_event,
        Ref :$tag?
    ) is Event
    {
        $self->return_to_sender
        (
            message         =>
            {
                id      => -1,
                type    => 'listing',
            },
            wheel_id        => $connection_id,
            return_session  => $self->ID,
            return_event    => 'handle_on_listing',
            tag             =>
            {
                return_session  => $return_session // $self->poe->sender,
                return_event    => $return_event,
                inner_tag       => $tag,
            },
        );
    }

    method handle_on_listing(ProxyMessage $data, WheelID $id, HashRef $tag) is Event
    {
        my %args = ( success => $data->{success}, payload => thaw($data->{payload}) );
        $self->post
        (
            $tag->{return_session},
            $tag->{return_event},
            connection_id => $id,
            %args,
            tag => $tag->{inner_tag},
        );
    }
}
1;
__END__
=head1 DESCRIPTION

POEx::ProxySession::Client enables remote sessions to interact with one another
via a system of subscription and publication. Client works via introspection on
Moose::Meta::Classes to build local, persistent sessions that proxy posts back
to the publisher with the attendant method signatures.

=head1 CAVEATS

It should be noted that the transport mechanism makes use of Storable. That
means that all of the various end points in a spawling system need to use the
same version of Storable to make sure things serialize/deserialize correctly.

Since Moose::Meta::Classes contain a lot of coderefs, and since MooseX::Declare
does a lot of coderef munging, the choice was made to forego using the Storable
ability to serialize coderefs via B::Deparse and just discard them. This means
that encapsulation is broken on Moose::Meta::Class to access methods.

