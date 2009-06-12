package POEx::ProxySession::Types;
use 5.010;

#ABSTRACT: Types for use within the ProxySession environment

use MooseX::Types -declare => [ qw/ ProxySession / ];
use MooseX::Types::Moose(':all');
use MooseX::Types::Structured('Dict', 'Optional');

=head1 Types

=head2 ProxyMessage

ProxyMessage is a Dict with the following structure:

    type => Str,
    id => Int,
    payload => Optional[Str],
    to => Optional[Str],
    success => Optional[Bool],

type can be any of the following: deliver, result, subscribe, publish, listing,
and rescind. Each type has some light validation. Deliver requires 'to' to be
set. Result requires 'success' to be set. Subscribe requires 'to'. Publish and
rescind both require 'payload' to be set. 

This type does not validate the contents of the payload.

=cut

subtype 'ProxyMessage',
    as Dict
    [
        type => Str,
        id => Int,
        payload => Optional[Str],
        to => Optional[Str],
        success => Optional[Bool],
    ],
    where 
    { 
        ( $_->{type} eq 'deliver'   && defined($_->{to})        )   ||
        ( $_->{type} eq 'result'    && defined($_->{success})   )   ||
        ( $_->{type} eq 'subscribe' && defined($_->{to})        )   ||
        ( $_->{type} eq 'publish'   && defined($_->{payload})   )   ||
        ( $_->{type} eq 'rescind'   && defined($_->{payload})   )   ||
        ( $_->{type} eq 'listing' )
    };
        
1;
__END__
=head1 DESCRIPTION

POEx::ProxySession::Types provides types for use within the ProxySession
environment that are self validating.

