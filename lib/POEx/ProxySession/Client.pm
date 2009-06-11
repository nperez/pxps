use 5.010;

use MooseX::Declare;
$Storable::forgive_me = 1;

class POEx::ProxySession::Client with (POEx::Role::TCPClient, POEx::ProxySession::MessageSender) is dirty
{
    use 5.010;
    use POEx::ProxySession::Types(':all');
    use POEx::Types(':all');
    use POE::Filter::Reference;
    use MooseX::Types::Moose(':all');
    use MooseX::AttributeHelpers;
    use Moose::Util('does_role');
    use Storable('thaw', 'nfreeze');
    use signatures;
    use Socket;

    use aliased 'POEx::Role::Event';
    use aliased 'POEx::Role::ProxyEvent';
    use aliased 'MooseX::Method::Signatures::Meta::Method', 'MXMSMethod';
    use aliased 'Moose::Meta::Method';

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

    after _start(@args) is Event
    {
        $self->filter(POE::Filter::Reference->new());
    }

    around connect
    (
        Str :$remote_address, 
        Int :$remote_port, 
        SessionAlias|SessionID|Session|DoesSessionInstantiation :$return_session?, 
        Str :$return_event
    ) is Event
    {
        $orig->($self, remote_address => $remote_address, remote_port => $remote_port);
        
        $self->set_pending
        (
            "$remote_address:$remote_port", 
            {
                address         => $remote_address,
                port            => $remote_port,
                return_session  => $return_session // $self->poe->sender->ID, 
                return_event    => $return_event 
            } 
        );
    }

    after handle_on_connect(GlobRef $socket, Str $address, Int $port, WheelID $id) is Event
    {
        my $addr = inet_ntoa($address);
        my $addr_port = "$addr:$port";
        
        if($self->has_pending($addr_port))
        {
            my $tag = $self->delete_pending($addr_port);
            $self->post
            (
                $tag->{return_session},
                $tag->{return_event},
                connection_id   => $self->last_wheel,
                remote_address  => $addr,
                remote_port     => $port,
            );
        }
        else
        {
            die "Connect finished for unknown address: $addr_port";
        }
    }

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
        }
    }

    method subscribe
    (
        WheelID :$connection_id,
        SessionAlias :$to_session, 
        SessionAlias :$return_session?, 
        Str :$return_event
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
                use POEx::Types(':all');
                use aliased 'POEx::Role::Event';
                use Storable('thaw');
                after _start(@args) is Event
                {
                    $self->post
                    (
                        $tag->{return_session}, 
                        $tag->{return_event},
                        success         => $data->{success},
                        session_name    => $session_name,
                        payload         => $payload,
                    );

                    $self->poe->kernel->detach_myself();
                }

                method proxy_send_failure(ProxyMessage $data, WheelID $id, HashRef $tag) is Event
                {
                    use Data::Dumper;
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
                my $code = sub ($obj, @args)
                {
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
               success          => $data->{success},
               session_name     => $tag->{session},
               payload          => thaw($data->{payload})
            );
        }
    }

    method unsubscribe(SessionAlias :$session_name, SessionAlias :$return_session?, Str :$return_event) is Event
    {
        die "Unknown session '$session_name'"
            if not $self->has_subscription($session_name);

        my $session = to_Session($session_name);
        
        $return_session = $return_session // $self->poe->sender;
        
        if(!$session)
        {
            $self->delete_subscription($session_name);
            $self->post($return_session, $return_event);
            return;
        }
        
        my $meta = $session->meta;
        my $closure = sub { $self->delete_subscription($session_name) };
        $meta->add_after_method_modifer('_stop', sub ($obj) { $obj->post($return_session , $return_event); $closure->(); } );
        $self->post($session_name, 'shutdown');
    }

    method publish
    (
        WheelID :$connection_id, 
        SessionAlias :$session_alias, 
        DoesSessionInstantiation :$session, 
        SessionAlias :$return_session?,  
        Str :$return_event
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

        my %tag = 
        (
            %payload,
            return_session  => $return_session // $self->poe->sender->ID,
            return_event    => $return_event,
        );

        $self->return_to_sender
        (
            message         => \%data, 
            wheel_id        => $connection_id, 
            return_session  => $self->ID, 
            return_event    => 'handle_on_publish', 
            tag             => \%tag
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
            %args
        );
    }

    method rescind(DoesSessionInstantiation :$session, SessionAlias :$return_session?, Str :$return_event) is Event
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
            %args
        );
    }

    method server_listing(WheelID :$connection_id, SessionAlias :$return_session?, Str :$return_event) is Event
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
            %args
        );
    }
    
}
