-module(erlite_node_health).

-export([healthy/1]).

-spec healthy(node()) -> boolean().
healthy(Node) when Node =:= node() -> true;
healthy(Node) -> net_adm:ping(Node) =:= pong.
