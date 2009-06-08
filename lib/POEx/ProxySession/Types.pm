use 5.010;
use MooseX::Types -declare => [ qw/ ProxySession / ];
use MooseX::Types::Moose(':all');
use MooseX::Types::Structured('Dict', 'Optional');

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
        
        
