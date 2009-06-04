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
        $self->return_to_sender({ type => 'listing'}, $self->last_wheel, $self->ID, 'receive_listing'); 
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

        $self->return_to_sender(\%data, $id, $self->ID, 'handle_on_subscribe');
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

        $self->return_to_sender(\%data, $id, $self->poe->sender, $return_event);
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
        my ($session_name, $meta) = %{$data}{'session', 'meta'};
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

                $obj->post($self_address, 'send_message', $msg, $id);
            };

            my $method = $meta->get_method($name);
            
            my %args;

            # making this assumption is okay for now
            bless($method, MXMSMethod);
                    
            $args{signature} = $method->signature // '(@args)';
            $args{return_signature} = $method->return_signature if defined $method->return_signature;

            # traits accessor isn't commited yet;
            $args{traits} = [ map { Class::MOP::load_class($_); [$_, undef] } @{$method->traits} ] 
                if $method->can('traits') and defined $method->traits;

            $args{body} = $code;

            $new_meth = MXMSMethod->wrap(%args);
            $new_meth->_set_name($name);
            $new_meth->_set_package($anon->name);
            Event->apply($new_meth) if not does_role(Event);
            $anon->add_method($name, $new_meth);
        }

        my $return = $self->delete_pending($session_name);
        
        $anon->add_after_method_modifer('_start', sub ($obj) { $obj->post($return->{sender}, $return->{event_name}) } );
        $anon->name->new(alias => $session_name);
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

    method return_to_sender(ProxyMessage $data, WheelID $id, SessionID $sender, Str $event_name) as Event
    {
        state $my_id = 1;
        $data->{'id'} = $my_id;
        $self->set_pending($my_id++, { sender => $sender, event_name => $event_name });
        $self->get_wheel($id)->put($data);
    }

    method send_message(ProxyMessage $data, WheelID $id) as Event
    {
        $self->get_wheel($id)->put($data);
    }

}
