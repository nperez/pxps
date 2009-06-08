use 5.010;
use warnings;
use strict;

use MooseX::Declare;
$Storable::forgive_me = 1;

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
    use Socket;
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

    method subscribe
    (
        WheelID :$connection_id,
        SessionAlias :$to_session, 
        SessionAlias :$return_session?, 
        Str :$return_event
    ) is Event
    {
        $return_session = $return_session // $self->poe->sender;
        
        my %data = ( type => 'subscribe', to => $to_session, payload => nfreeze(\$to_session) );
        
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
                
                use Data::Dumper;
                {
                    no strict 'refs';
                    warn 'STASH: '.Dumper(\%{$self->meta->name.'::'});
                }
                warn 'ARGS: ' . Dumper(\%args);
                $DB::single = 1;
                my $new_meth = MXMSMethod->wrap(%args);
                Event->meta->apply($new_meth) if not does_role($new_meth, Event);
                $anon->add_method($name, $new_meth);
            }

            $self->set_session($session_name, { meta => $meta, wheel => $id});
            
            $anon->add_after_method_modifier
            (
                '_start', 
                sub ($obj) 
                {
                    $obj->post
                    (
                        $tag->{return_session}, 
                        $tag->{return_event},
                        success         => $data->{success},
                        session_name    => $session_name,
                        payload         => $payload,
                    ) 
                } 
            );
            warn "BEFORE HERE";
            $anon->name->new(alias => $session_name);
            warn "AFTER HERE";
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

        my %payload = ( session => $session_name, meta => $meta ); 
        my %data = 
        (
            type => 'publish',
            payload => nfreeze(\%payload),
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
            $self->set_session
            (
                $tag->{session},
                {
                    meta => $tag->{meta},
                    wheel => $id,
                }
            );
        }

        my %args = ( success => $data->{success}, session_name => $tag->{session} );
        $args{payload} = thaw($tag->{payload}) if defined($tag->{payload});

        $self->post
        (
            $tag->{return_session}, 
            $tag->{return_event},
            %args
        );
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
        if($data->{success})
        {
            $self->delete_session($tag->{session});
        }

        my %args = ( success => $data->{success}, session_name => $tag->{session} );
        $args{payload} = thaw($tag->{payload}) if defined($tag->{payload});

        $self->post
        (
            $tag->{return_session}, 
            $tag->{return_event},
            %args
        );
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
