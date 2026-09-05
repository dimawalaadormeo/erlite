-module(erlite_raft_machine).
-behaviour(ra_machine).

-export([init/1, apply/3, entries_after/2, last_index/1]).

-type entry() :: {non_neg_integer(), non_neg_integer(),
                  erlite_raft_command:command()}.
-type state() :: #{entries := [entry()], last_index := non_neg_integer()}.

-spec init(map()) -> state().
init(_Config) ->
    #{entries => [], last_index => 0}.

-spec apply(map(), term(), state()) ->
    {state(), term()} | {state(), term(), [ra_machine:effect()]}.
apply(#{index := Index, term := Term}, Command,
      State = #{entries := Entries}) ->
    case erlite_raft_command:validate(Command) of
        ok ->
            NewState = State#{entries => [{Index, Term, Command} | Entries],
                              last_index => Index},
            %% The machine snapshot contains the full retained command ledger.
            %% Releasing the cursor therefore permits Ra log compaction without
            %% removing the external SQLite applier's recovery source.
            {NewState, {committed, Index},
             [{release_cursor, Index, NewState}]};
        {error, _Reason} = Error ->
            {State, Error}
    end.

-spec entries_after(state(), non_neg_integer()) -> [entry()].
entries_after(#{entries := Entries}, Index) ->
    [Entry || Entry = {EntryIndex, _Term, _Command} <- lists:reverse(Entries),
              EntryIndex > Index].

-spec last_index(state()) -> non_neg_integer().
last_index(#{last_index := Index}) ->
    Index.
