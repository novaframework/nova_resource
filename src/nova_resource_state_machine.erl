-module(nova_resource_state_machine).
-moduledoc ~"""
State machine support for nova_resource.

Declares valid states and transitions for a resource field. Validates
transitions in the changeset pipeline and provides hooks for
before/after transition callbacks.

## Example

```erlang
-module(order_resource).
-behaviour(nova_resource).
-include_lib("nova_resource/include/nova_resource.hrl").

resource() ->
    SM = nova_resource_state_machine:new(status, #{
        states => [pending, confirmed, shipped, delivered, cancelled],
        transitions => [
            {pending, confirmed},
            {confirmed, shipped},
            {shipped, delivered},
            {pending, cancelled},
            {confirmed, cancelled}
        ]
    }),
    #{
        repo => my_repo,
        actions => [
            #nr_action{
                name = transition,
                type = update,
                accept = [status],
                changes = [nova_resource_state_machine:changeset_fun(SM)]
            }
        ]
    }.
```
""".

-include("nova_resource.hrl").
-include_lib("kura/include/kura.hrl").

-export([
    new/2,
    changeset_fun/1,
    valid_transition/3,
    valid_transitions_from/2,
    states/1
]).

-ignore_xref([valid_transition/3, valid_transitions_from/2, states/1]).

-export_type([state_machine/0]).

-opaque state_machine() :: #{
    field := atom(),
    states := [atom()],
    transitions := [{atom(), atom()}],
    before_transition := [{atom(), atom(), fun()}],
    after_transition := [{atom(), atom(), fun()}]
}.

-doc "Create a new state machine configuration.".
-spec new(atom(), map()) -> state_machine().
new(Field, Opts) ->
    #{
        field => Field,
        states => maps:get(states, Opts, []),
        transitions => maps:get(transitions, Opts, []),
        before_transition => maps:get(before_transition, Opts, []),
        after_transition => maps:get(after_transition, Opts, [])
    }.

-doc "Return a changeset change function that validates state transitions.".
-spec changeset_fun(state_machine()) -> fun().
changeset_fun(SM) ->
    fun(CS, _Ctx) -> validate_transition(CS, SM) end.

-doc "Check if a transition from `From` to `To` is valid.".
-spec valid_transition(state_machine(), atom(), atom()) -> boolean().
valid_transition(#{transitions := Transitions}, From, To) ->
    lists:member({From, To}, Transitions).

-doc "Return all valid target states from a given state.".
-spec valid_transitions_from(state_machine(), atom()) -> [atom()].
valid_transitions_from(#{transitions := Transitions}, From) ->
    [To || {F, To} <- Transitions, F =:= From].

-doc "Return all defined states.".
-spec states(state_machine()) -> [atom()].
states(#{states := States}) ->
    States.

%%----------------------------------------------------------------------
%% Internal
%%----------------------------------------------------------------------

validate_transition(CS, #{field := Field, transitions := Transitions} = SM) ->
    CurrentValue = maps:get(Field, CS#kura_changeset.data, undefined),
    case kura_changeset:get_change(CS, Field) of
        undefined ->
            CS;
        NewValue ->
            case lists:member({CurrentValue, NewValue}, Transitions) of
                true ->
                    run_before_hooks(CS, CurrentValue, NewValue, SM);
                false ->
                    Msg = iolist_to_binary(
                        io_lib:format(
                            "invalid transition from ~p to ~p", [CurrentValue, NewValue]
                        )
                    ),
                    kura_changeset:add_error(CS, Field, Msg)
            end
    end.

run_before_hooks(CS, From, To, #{before_transition := Hooks}) ->
    lists:foldl(
        fun
            ({F, T, Fun}, Acc) when F =:= From, T =:= To -> Fun(Acc);
            ({F, '_', Fun}, Acc) when F =:= From -> Fun(Acc);
            ({'_', T, Fun}, Acc) when T =:= To -> Fun(Acc);
            ({'_', '_', Fun}, Acc) -> Fun(Acc);
            (_, Acc) -> Acc
        end,
        CS,
        Hooks
    ).
