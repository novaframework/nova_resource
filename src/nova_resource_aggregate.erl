-module(nova_resource_aggregate).

-include("nova_resource.hrl").
-include_lib("kura/include/kura.hrl").

-export([
    compute/3,
    compute/4
]).

-spec compute(module(), atom(), #nr_context{}) -> {ok, term()} | {error, term()}.
compute(Resource, AggregateName, Ctx) ->
    compute(Resource, AggregateName, #{}, Ctx).

-spec compute(module(), atom(), map(), #nr_context{}) -> {ok, term()} | {error, term()}.
compute(Resource, AggregateName, _Input, #nr_context{repo = Repo} = Ctx) ->
    case find_aggregate(Resource, AggregateName) of
        {error, not_found} ->
            {error, {aggregate_not_found, AggregateName}};
        {ok, #nr_aggregate{type = Type, field = Field, filter = Filter}} ->
            BaseQuery = kura_query:from(Resource),
            case nova_resource_policy:filter_query(Resource, BaseQuery, Ctx) of
                {error, _} = Err ->
                    Err;
                {ok, Q1} ->
                    Q2 = maybe_apply_filter(Q1, Filter),
                    Q3 = apply_aggregate(Q2, Type, Field),
                    kura_repo_worker:one(Repo, Q3)
            end
    end.

find_aggregate(Resource, Name) ->
    case lists:keyfind(Name, #nr_aggregate.name, nova_resource:aggregates(Resource)) of
        false -> {error, not_found};
        Agg -> {ok, Agg}
    end.

maybe_apply_filter(Query, undefined) ->
    Query;
maybe_apply_filter(Query, Filter) when is_function(Filter, 1) ->
    Filter(Query);
maybe_apply_filter(Query, Filter) ->
    kura_query:where(Query, Filter).

apply_aggregate(Query, count, '*') ->
    kura_query:count(Query);
apply_aggregate(Query, count, Field) ->
    kura_query:count(Query, Field);
apply_aggregate(Query, sum, Field) ->
    kura_query:sum(Query, Field);
apply_aggregate(Query, avg, Field) ->
    kura_query:avg(Query, Field);
apply_aggregate(Query, min, Field) ->
    kura_query:min(Query, Field);
apply_aggregate(Query, max, Field) ->
    kura_query:max(Query, Field).
