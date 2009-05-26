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
    use Storable('thaw', 'nfreeze');
    use aliased 'POEx::Role::Event';
    use aliased 'MooseX::Method::Signatures::Meta::Method', 'MXMSMethod';
    use aliased 'Moose::Meta::Method';

    has pending =>
    (
        metaclass   => 'MooseX::AttributeHelpers::Collection::Hash',
        is          => 'rw',
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
        is          => 'rw',
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
        is          => 'rw',
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
        $self->send_message({ type => 'listing'}, $self->last_wheel, $self->ID, 'receive_listing'); 
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
                    $self->post($pending->{sender}, $pending->{event_name}, $data, $id);
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
                    my $back = "Unable to post '$event' to '$session'" if !$success;
                    $self->send_result($success, $back // '', $id);
                }
                else
                {
                    warn q|Received a delivery for someone that isn't us|;
                    $self->get_wheel($id)->put
                    (
                        { 
                            type    => 'result', 
                            success => 0, 
                            payload => nfreeze(\${'Recipient unknown'})
                        }
                    );
                    return;
                }
            }
        }
    }

    method subscribe(Str :$to_session, SessionAlias :$return_session?, Str :$return_event) is Event
    {
        if(!$self->has_mapping($to_session))
        {
            $self->post
            (
                $return_session // $self->poe->sender, 
                $return_event,
                { 
                    type => 'result',
                    success => 0,
                    payload => nfreeze(\${'No know session exists'}),
                }
            );
            return;
        }
        
        my $id = $self->get_mapping($to_session);
        my $sender = $return_session // $self->poe->sender;
        my %data = ( type => 'subscribe', payload => nfreeze(\$to_session) );
        $self->set_pending
        (
            $to_session, 
            {
                sender => $sender, 
                event_name => $return_event
            }
        );

        $self->send_message(\%data, $id, $self->ID, 'handle_on_subscribe');
    }

    method unsubscribe() is Event
    {

    }

    method publish(WheelID :$connection_id, 
        SessionAlias :$session_name, 
        DoesSessionInstantiation :$session, 
        SessionAlias :$return_session,  
        Str :$return_event) is Event
    {
        my $meta = $other->meta;

        my %payload = ( session => $alias, meta => $other ); 
        my %data = 
        (
            type => 'register',
            payload => nfreeze(\%payload),
        );

        $self->send_message(\%data, $id, $self->poe->sender, $return_event);
    }

    method unpublish() is Event
    {
    }
    
    method receive_listing(ProxyMessage $data, WheelID $id) is Event
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

    method handle_on_subscribe(ProxyMessage $data, WheelID $id) is Event
    {
        my $payload = thaw($data->{payload});
        my ($alias, $meta) = %{$data}{'session', 'meta'};
        
        bless($meta, 'Moose::Meta::Class');

        my $anon = Moose::Meta::Class->create_anon_class();
        
        foreach my $name ($meta->get_method_list)
        {
            my $method = $meta->get_method($name);
            bless($method, MXMSMethod);

            if($method->can('signature'))
            {
                # We actually have a MXMS Method, \o/

            }
            else
            {
                # Boo. Bless it into a 'normal' method
                bless($method, Method);
            }
        }
    }
    
    method send_result(Bool $success, Ref $payload, WheelID $id)
    {
        $self->get_wheel($id)->put
        (
            {
                type    => 'result', 
                success => $success,
                payload => nfreeze($payload),
            }
        );
    }

    method send_message(ProxyMessage $data, WheelID $id, SessionID $sender, Str $event_name)
    {
        state $my_id = 1;
        $data->{'id'} = $my_id;
        $self->set_pending($my_id++, { sender => $sender, event_name => $event_name });
        $self->get_wheel($id)->put($data);
    }

}
