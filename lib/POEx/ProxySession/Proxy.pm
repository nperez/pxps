package POEx::ProxySession::Proxy;

use 5.010;

#ABSTRACT: This is the proxy class

use MooseX::Declare;

class POEx::ProxySession::Proxy with POEx::Role::SessionInstantiation is mutable
{
    use Class::MOP;
    use MooseX::Types::Moose(':all');
    use POEx::Types(':all');
    use POEx::ProxySession::Types(':all');
    use Storable('thaw', 'nfreeze');
    use Moose::Util('does_role');

    use aliased 'POEx::Role::Event';
    use aliased 'MooseX::Method::Signatures::Meta::Method', 'MXMSMethod';

    has parent_id => ( is => 'ro', isa => SessionID );
    has parent_startup => ( is => 'ro', isa => Str );

    after _start(ProxyMessage $data, WheelID $id, HashRef $tag) is Event
    {
        my $payload = thaw($data->{payload});
        my ($session_name, $methods) = @$payload{'session', 'methods'};
        my $parent_id = $self->parent_id;
        my $meta = $self->_clone_self->meta;
        
        $self->alias($session_name);

        while(my ($method_name, $method_args) = each %$methods)
        {
            # build our closure proxy method
            my $code = sub
            {
                my ($obj, @args) = @_;
                my $load = { event => $method_name, args => \@args };

                my $msg =
                {
                    id => -1,
                    type => 'deliver',
                    to => $session_name,
                    payload => nfreeze($load),
                };

                $obj->post
                (
                    $parent_id, 
                    'return_to_sender', 
                    message         => $msg, 
                    wheel_id        => $id,
                    return_session  => $obj->ID,
                    return_event    => 'proxy_send_check',
                    tag             => 
                    {
                        session_name    => $session_name,
                        event_name      => $method_name,
                        args            => \@args,
                    }
                );
            };

            
            my %args;
            
            $args{name} = $method_name;
            $args{package_name} = $meta->name;
            $args{signature} = $method_args->{signature} // '(@args)';
            $args{return_signature} = $method_args->{return_signature} if defined($method_args->{return_signature});
            $args{body} = $code;
            
            if(exists($method_args->{traits}))
            {
                # make sure all the method traits are loaded
                map { Class::MOP::load_class($_) } keys %{$method_args->{traits}};
                $args{traits} = $method_args->{traits};
            }
            
            my $new_meth = MXMSMethod->wrap(%args);
            Event->meta->apply($new_meth) if not does_role($new_meth, Event);
            $meta->add_method($method_name, $new_meth);
        }
        
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

        $self->post
        (
            $self->parent_id,
            $self->parent_startup,
            $session_name,
            $meta,
            $id
        );

        $self->poe->kernel->detach_myself();
    }

    method proxy_send_check(ProxyMessage $data, WheelID $id, HashRef $tag) is Event
    {
        warn 'A proxy call to '. $tag->{session_name} . ':'. $tag->{event_name} .
        ' with the arguments [ ' . join(', ', @{ $tag->{args} }) . ' ] failed: '.
        thaw($data->{payload}) if !$data->{success};
    }

    method shutdown() is Event
    {
        $self->clear_alias;
    }
}
1;
__END__
=head1 DESCRIPTION
POEx::ProxySession::Proxy is the light weight proxy class that is instantiated
when a successful subscribe is executed. Consider this class private.
