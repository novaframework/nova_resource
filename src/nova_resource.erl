-module(nova_resource).

-include("nova_resource.hrl").

-callback resource() ->
    #{
        repo := module(),
        actions := [#nr_action{}],
        policies => [#nr_policy{}],
        notifiers => [#nr_notifier{}],
        aggregates => [#nr_aggregate{}],
        calculations => [#nr_calculation{}],
        default_accept => [atom()]
    }.

-export([
    definition/1,
    actions/1,
    action/2,
    policies/1,
    notifiers/1,
    aggregates/1,
    calculations/1,
    repo/1,
    default_accept/1,
    invalidate_cache/1
]).

-define(CACHE_KEY(Mod), {nova_resource, Mod}).

-spec definition(module()) -> map().
definition(Resource) ->
    case persistent_term:get(?CACHE_KEY(Resource), undefined) of
        undefined ->
            Def = Resource:resource(),
            persistent_term:put(?CACHE_KEY(Resource), Def),
            Def;
        Cached ->
            Cached
    end.

-spec actions(module()) -> [#nr_action{}].
actions(Resource) ->
    maps:get(actions, definition(Resource)).

-spec action(module(), atom()) -> {ok, #nr_action{}} | {error, not_found}.
action(Resource, Name) ->
    case lists:keyfind(Name, #nr_action.name, actions(Resource)) of
        false -> {error, not_found};
        Action -> {ok, Action}
    end.

-spec policies(module()) -> [#nr_policy{}].
policies(Resource) ->
    maps:get(policies, definition(Resource), []).

-spec notifiers(module()) -> [#nr_notifier{}].
notifiers(Resource) ->
    maps:get(notifiers, definition(Resource), []).

-spec aggregates(module()) -> [#nr_aggregate{}].
aggregates(Resource) ->
    maps:get(aggregates, definition(Resource), []).

-spec calculations(module()) -> [#nr_calculation{}].
calculations(Resource) ->
    maps:get(calculations, definition(Resource), []).

-spec repo(module()) -> module().
repo(Resource) ->
    maps:get(repo, definition(Resource)).

-spec default_accept(module()) -> [atom()].
default_accept(Resource) ->
    maps:get(default_accept, definition(Resource), []).

-spec invalidate_cache(module()) -> boolean().
invalidate_cache(Resource) ->
    persistent_term:erase(?CACHE_KEY(Resource)).
