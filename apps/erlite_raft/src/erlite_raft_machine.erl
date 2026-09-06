-module(erlite_raft_machine).
-behaviour(ra_machine).

-export([init/1, apply/3, entries_after/2, recovery_after/3,
         last_index/1, barrier/2]).

-type entry() :: {non_neg_integer(), non_neg_integer(),
                  erlite_raft_command:command()}.
-type state() :: map().

-spec init(map()) -> state().
init(#{runtime_identity := RuntimeIdentity}) ->
    #{entries => [], last_index => 0, last_term => 0, checkpoint => none,
      runtime_identity => RuntimeIdentity}.

-spec apply(map(), term(), state()) ->
    {state(), term()} | {state(), term(), [ra_machine:effect()]}.
apply(Meta, {checkpoint, ThroughIndex, Manifests}, State) ->
    apply_checkpoint(Meta, ThroughIndex, Manifests, State);
apply(#{index := Index, term := Term}, Command,
      State = #{entries := Entries}) ->
    case erlite_raft_command:validate(Command) of
        ok ->
            NewState = State#{entries => [{Index, Term, Command} | Entries],
                              last_index => Index, last_term => Term},
            %% The machine snapshot contains the full retained command ledger.
            %% Releasing the cursor therefore permits Ra log compaction without
            %% removing the external SQLite applier's recovery source.
            {NewState, {committed, Index},
             [{release_cursor, Index, NewState}]};
        {error, _Reason} = Error ->
            {State, Error}
    end.

apply_checkpoint(#{index := RaftIndex}, ThroughIndex, Manifests,
                 State = #{entries := Entries, last_index := LastIndex,
                           checkpoint := Current})
  when is_integer(ThroughIndex), ThroughIndex >= 0,
       ThroughIndex =< LastIndex, is_map(Manifests), map_size(Manifests) > 0 ->
    CurrentIndex = checkpoint_index(Current),
    case ThroughIndex >= CurrentIndex of
        true ->
            Retained = [Entry || Entry = {Index, _, _} <- Entries,
                                  Index > ThroughIndex],
            Checkpoint = #{through_index => ThroughIndex,
                           manifests => Manifests},
            NewState = State#{entries => Retained, checkpoint => Checkpoint},
            {NewState, {checkpointed, ThroughIndex},
             [{release_cursor, RaftIndex, NewState}]};
        false ->
            {State, {error, {checkpoint_regression,
                             CurrentIndex, ThroughIndex}}}
    end;
apply_checkpoint(_Meta, ThroughIndex, _Manifests, State) ->
    {State, {error, {invalid_checkpoint, ThroughIndex}}}.

checkpoint_index(none) -> 0;
checkpoint_index(#{through_index := Index}) -> Index.

-spec entries_after(state(), non_neg_integer()) -> [entry()].
entries_after(#{entries := Entries}, Index) ->
    [Entry || Entry = {EntryIndex, _Term, _Command} <- lists:reverse(Entries),
              EntryIndex > Index].

-spec recovery_after(non_neg_integer(), term(), state()) ->
    {ok, [entry()]} | {snapshot_required, map()} | {error, term()}.
recovery_after(Index, ServerId,
               #{checkpoint := #{through_index := Floor,
                                 manifests := Manifests}})
  when Index < Floor ->
    case maps:find(ServerId, Manifests) of
        {ok, Manifest} -> {snapshot_required, Manifest};
        error -> {error, {checkpoint_manifest_unavailable, ServerId}}
    end;
recovery_after(Index, _ServerId, State) ->
    {ok, entries_after(State, Index)}.

-spec last_index(state()) -> non_neg_integer().
last_index(#{last_index := Index}) ->
    Index.

-spec barrier(map(), state()) -> map().
barrier(#{index := RaftIndex, term := Term}, State) ->
    #{raft_index => RaftIndex,
      term => Term,
      command_index => last_index(State),
      command_term => maps:get(last_term, State),
      checkpoint => maps:get(checkpoint, State),
      runtime_identity => maps:get(runtime_identity, State)}.
