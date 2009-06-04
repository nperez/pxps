use 5.010;

use MooseX::Declare;

class POEx::ProxySession::Client with POEx::Role::TCPClient
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
    use aliased 'POEx::Role::Event';
    use aliased 'MooseX::Method::Signatures::Meta::Method', 'MXMSMethod';
    use aliased 'Moose::Meta::Method';

    has pending =>
    (
        metaclass   => 'MooseX::AttributeHelpers::Collection::Hash',
        isa         => HashRef,
        lazy        => 1,
        default     => sub { {} },
        clearer     => 'clear_pending',
        provides    => 
        {
            get     => 'get_pending',
            set     => 'set_pending',
            delete  => 'delete_pending',
            count   => 'count_pending',
            exists  => 'has_pending',
        }

    );

    has sessions =>
    (
        metaclass   => 'MooseX::AttributeHelpers::Collection::Hash',
        isa         => HashRef,
        lazy        => 1,
        default     => sub { {} },
        clearer     => 'clear_sessions',
        provides    => 
        {
            get     => 'get_session',
            set     => 'set_session',
            delete  => 'delete_session',
            count   => 'count_sessions',
            keys    => 'all_session_names',
            exists  => 'has_session',
        }
    );

    has mapping =>
    (
        metaclass   => 'MooseX::AttributeHelpers::Collection::Hash',
        isa         => HashRef,
        lazy        => 1,
        default     => sub { {} },
        clearer     => 'clear_mappings',
        provides    => 
        {
            get     => 'get_mapping',
            set     => 'set_mapping',
            delete  => 'delete_mapping',
            count   => 'count_mappings',
            keys    => 'all_mapping_names',
            exists  => 'has_mapping',
        }

    );

    after _start(@args) is Event
    {
        $self->filter(POE::Filter::Reference->new());
    }

    after handle_on_connect(GlobRef $socket, Str $address, Int $port, WheelID $id) is Event
    {
        $self->return_to_sender
        (
            message         => { type => 'listing'}, 
            wheel_id        => $self->last_wheel, 
            return_session  => $self->ID, 
            return_event    => 'receive_listing'); 
    }

    method handle_inbound_data(ProxyMessage $data, WheelID $id) is Event
    {
        given($data->{type})
        {
            when ('result')
            {
                if($self->has_pending($data->{id}))
                {
                    my $pending = $self->get_pending($data->{id});
                    $self->post($pending->{return_session}, $pending->{return_event}, $pending->{tag}, $data, $id);
                }
                else
                {
                    warn q|Received a result for something we didn't send out|;
                    return;
                }
            }
            when ('deliver')
            {
                if($self->has_session($data->{to}))
                {
                    my $payload = thaw($data->{payload});
                    my ($event, @args) = ($payload->{event}, @{ $payload->{args} });
                    my $session = $self->get_session($data->{to});

                    my $success = $self->post($session, $event, @args);
                    my $back = \${"Unable to post '$event' to '$session'"} if !$success;
                    
                    $self->send_result
                    (
                        success     => $success, 
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
                        payload     => nfreeze(\'Unknown recipient'),
                        wheel_id    => $id,
                    );

                }
            }
        }
    }

    method subscribe(Str :$to_session, SessionAlias :$return_session?, Str :$return_event) is Event
    {
        $return_session = $return_session // $self->poe->sender;
        
        if(!$self->has_mapping($to_session))
        {
            $self->post
            (
                $return_session,
                $return_event,
                { 
                    type    => 'result',
                    success => 0,
                    payload => nfreeze(\${'No known session exists'}),
                }
            );
            return;
        }
        
        my $id = $self->get_mapping($to_session);
        my %data = ( type => 'subscribe', payload => nfreeze(\$to_session) );
        
        $self->return_to_sender
        (
            message         => \%data, 
            wheel_id        => $id, 
            return_session  => $self->ID, 
            return_event    => 'handle_on_subscribe',
            tag             =>
            {
                return_session  => $return_session,
                return_event    => $return_event,
            }
        );
    }

    method unsubscribe(SessionAlias :$session_name, SessionAlias :$return_session?, Str :$return_event) is Event
    {
        my $session = to_Session($session_name);
        
        die "Unknown session '$session_name'"
            if not $session or not $self->has_session;

        my $meta = $session->meta;
        my $closure = sub { $self->delete_session($session_name) };
        $meta->add_after_method_modifer('_stop', sub ($obj) { $obj->post($return_session, $return_event); $closure->(); } );
        $self->post($session_name, '_stop');
    }

    method publish
    (
        WheelID :$connection_id, 
        SessionAlias :$session_name, 
        DoesSessionInstantiation :$session, 
        SessionAlias :$return_session?,  
        Str :$return_event
    ) is Event
    {
        my $meta = $session->meta;

        my %payload = ( session => $session_name, meta => $session ); 
        my %data = 
        (
            type => 'register',
            payload => nfreeze(\%payload),
        );

        my %tag = 
        (
            %payload,
            return_session  => $return_session // $self->poe->sender,
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
            $self->set_session
            (
                $tag->{session},
                {
                    meta => $tag->{meta},
                    wheel => $id,
                }
            );

            $self->post($tag->{return_session}, $tag->{return_event}, $tag->{session});
        }
        else
        {
            $self->post($tag->{return_session}, $tag->{return_event}, thaw($data->{payload}));
        }
    }

    method rescind(SessionAlias :$session_name, SessionAlias :$return_session?, Str :$return_event) is Event
    {
        die "Session '$session_name' is not currently published"
            if not $self->has_session($session_name);

        my $hash = $self->get_session($session_name);
        
        $self->return_to_sender
        (
            message         => { type => 'rescind', payload => nfreeze(\$session_name) }, 
            wheel_id        => $hash->{wheel},
            return_session  => $self->ID,
            return_event    => 'handle_on_rescind',
            tag             =>
            {
                session         => $session_name,
                return_session  => $return_session // $self->poe->sender,
                return_event    => $return_event,
            }
        );
    }

    method handle_on_rescind(ProxyMessage $data, WheelID $id, HashRef $tag) is Event
    {
        $self->delete_session($tag->{session});
    }
    
    method receive_listing(ProxyMessage $data, WheelID $id, Ref $tag?) is Event
    {
        my $payload = thaw($data->{payload});

        foreach my $listing (@$payload)
        {
            warn "Listing clash. Overwriting previous entry '$listing'"
                if $self->has_mapping($listing);

            $self->set_mapping($listing, $id);
        }
        
        $self->set_mapping($id, $payload);
    }

    method handle_on_subscribe(ProxyMessage $data, WheelID $id, HashRef $tag) is Event
    {
        my $payload = thaw($data->{payload});
        my ($session_name, $meta) = @$payload{'session', 'meta'};
        my $self_address = $self->alias // $self->ID;
        
        bless($meta, 'Moose::Meta::Class');

        my $anon = Moose::Meta::Class->create_anon_class();
        
        foreach my $name ($meta->get_method_list)
        {
            # build our closure proxy method
            my $code = sub ($obj, @args)
            {
                my $payload = { event => $name, args => \@args };

                my $msg =
                {
                    type => 'deliver',
                    to => $session_name,
                    payload => nfreeze($payload),
                };

                $obj->post
                (
                    $self_address, 
                    'send_message', 
                    message     => $msg, 
                    wheel_id    => $id
                );
            };

            my $method = $meta->get_method($name);
            
            my %args;

            # making this assumption is okay for now
            bless($method, MXMSMethod);
                    
            $args{signature} = $method->signature // '(@args)';
            $args{return_signature} = $method->return_signature if defined $method->return_signature;

            if($method->has_traits)
            {
                # make sure all the method traits are loaded
                map { Class::MOP::load_class($_) } keys %{$method->traits};
                $args{traits} = $method->traits;
            }

            $args{body} = $code;

            my $new_meth = MXMSMethod->wrap(%args);
            $new_meth->_set_name($name);
            $new_meth->_set_package($anon->name);
            Event->apply($new_meth) if not does_role($new_meth, Event);
            $anon->add_method($name, $new_meth);
        }

        $self->set_session($session_name, { meta => $meta, wheel => $id});
        
        $anon->add_after_method_modifer('_start', sub ($obj) { $obj->post($tag->{return_session}, $tag->{return_event}) } );
        $anon->name->new(alias => $session_name);
    }
    
    method send_result(Bool :$success, Ref :$payload, WheelID :$wheel_id)
    {
        $self->get_wheel($wheel_id)->put
        (
            {
                type    => 'result', 
                success => $success,
                payload => nfreeze($payload),
            }
        );
    }

    method return_to_sender
    (   ProxyMessage :$message, 
        WheelID :$wheel_id, 
        SessionID :$return_session, 
        Str :$return_event, 
        Ref :$tag?
    ) is Event
    {
        state $my_id = 1;
        $message->{'id'} = $my_id;
        $self->set_pending($my_id++, { tag => $tag, return_session => $return_session, return_event => $return_event });
        $self->get_wheel($wheel_id)->put($message);
    }

    method send_message(ProxyMessage :$message, WheelID :$wheel_id) is Event
    {
        $self->get_wheel($wheel_id)->put($message);
    }

}
