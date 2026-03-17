-module(nova_resource_notifier).

-include("nova_resource.hrl").

-export([
    notify/4
]).

-spec notify(module(), atom(), term(), #nr_context{}) -> ok.
notify(Resource, ActionName, Record, Ctx) ->
    Notifiers = matching_notifiers(Resource, ActionName),
    lists:foreach(
        fun(Notifier) ->
            spawn(fun() -> dispatch(Notifier, ActionName, Record, Ctx) end)
        end,
        Notifiers
    ),
    ok.

matching_notifiers(Resource, ActionName) ->
    [
        N
     || #nr_notifier{action = A} = N <- nova_resource:notifiers(Resource),
        A =:= ActionName orelse A =:= '_'
    ].

dispatch(#nr_notifier{type = pubsub, target = Channel}, ActionName, Record, _Ctx) ->
    Msg = {nova_resource, ActionName, Record},
    [Pid ! Msg || Pid <- pg:get_members(Channel)],
    ok;
dispatch(#nr_notifier{type = callback, target = Fun}, ActionName, Record, Ctx) when
    is_function(Fun, 3)
->
    Fun(ActionName, Record, Ctx);
dispatch(_Notifier, _ActionName, _Record, _Ctx) ->
    ok.
