-module(nova_resource_policy).

-include("nova_resource.hrl").

-export([
    authorize/3,
    authorize/4,
    filter_query/3
]).

-spec authorize(module(), atom(), #nr_context{}) -> ok | {error, forbidden}.
authorize(Resource, ActionName, #nr_context{actor = Actor} = _Ctx) ->
    Policies = matching_policies(Resource, ActionName),
    case Policies of
        [] ->
            ok;
        _ when Actor =:= undefined ->
            {error, forbidden};
        _ ->
            evaluate_mutation_policies(Policies, Actor, #{})
    end.

-spec authorize(module(), atom(), map(), #nr_context{}) -> ok | {error, forbidden}.
authorize(Resource, ActionName, Extra, #nr_context{actor = Actor} = _Ctx) ->
    Policies = matching_policies(Resource, ActionName),
    case Policies of
        [] ->
            ok;
        _ when Actor =:= undefined ->
            {error, forbidden};
        _ ->
            evaluate_mutation_policies(Policies, Actor, Extra)
    end.

-spec filter_query(module(), term(), #nr_context{}) -> {ok, term()} | {error, forbidden}.
filter_query(Resource, Query, #nr_context{actor = Actor, action = ActionName} = _Ctx) ->
    Policies = matching_policies(Resource, ActionName),
    case Policies of
        [] ->
            {ok, Query};
        _ when Actor =:= undefined ->
            {error, forbidden};
        _ ->
            apply_read_filters(Policies, Actor, Query)
    end.

matching_policies(Resource, ActionName) ->
    [
        P
     || #nr_policy{action = A} = P <- nova_resource:policies(Resource),
        A =:= ActionName orelse A =:= '_'
    ].

evaluate_mutation_policies([], _Actor, _Extra) ->
    ok;
evaluate_mutation_policies([#nr_policy{condition = Cond} | Rest], Actor, Extra) ->
    case Cond(Actor, Extra) of
        true -> evaluate_mutation_policies(Rest, Actor, Extra);
        _ -> {error, forbidden}
    end.

apply_read_filters([], _Actor, Query) ->
    {ok, Query};
apply_read_filters([#nr_policy{condition = Cond} | Rest], Actor, Query) ->
    case Cond(Actor, #{}) of
        true ->
            apply_read_filters(Rest, Actor, Query);
        false ->
            {error, forbidden};
        FilterFun when is_function(FilterFun, 1) ->
            apply_read_filters(Rest, Actor, FilterFun(Query))
    end.
