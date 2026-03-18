-module(nova_resource_action).

-include("nova_resource.hrl").
-include_lib("kura/include/kura.hrl").

-export([
    run/4
]).

-spec run(module(), atom(), map(), #nr_context{}) -> {ok, term()} | {error, term()}.
run(Resource, ActionName, Input, Ctx0) ->
    Ctx = Ctx0#nr_context{resource = Resource, action = ActionName},
    maybe_set_tenant(Ctx#nr_context.tenant),
    case nova_resource:action(Resource, ActionName) of
        {error, not_found} ->
            {error, {action_not_found, ActionName}};
        {ok, #nr_action{type = Type} = Action} ->
            run_action(Type, Resource, Action, Input, Ctx)
    end.

run_action(create, Resource, Action, Input, Ctx) ->
    run_create(Resource, Action, Input, Ctx);
run_action(read, Resource, Action, Input, Ctx) ->
    run_read(Resource, Action, Input, Ctx);
run_action(update, Resource, Action, Input, Ctx) ->
    run_update(Resource, Action, Input, Ctx);
run_action(destroy, Resource, Action, Input, Ctx) ->
    run_destroy(Resource, Action, Input, Ctx).

%% Create
run_create(Resource, Action, Input, #nr_context{repo = Repo} = Ctx) ->
    case nova_resource_policy:authorize(Resource, Action#nr_action.name, Ctx) of
        {error, _} = Err ->
            Err;
        ok ->
            Params = maps:get(params, Input, #{}),
            CS0 = nova_resource_changeset:build(Resource, #{}, Params, Action),
            CS1 = apply_changes(CS0, Action#nr_action.changes, Ctx),
            case CS1#kura_changeset.valid of
                false ->
                    {error, CS1};
                true ->
                    case kura_repo_worker:insert(Repo, CS1) of
                        {ok, Record} ->
                            nova_resource_notifier:notify(
                                Resource, Action#nr_action.name, Record, Ctx
                            ),
                            {ok, apply_calculations(Resource, Record)};
                        {error, _} = Err ->
                            Err
                    end
            end
    end.

%% Read
run_read(Resource, _Action, Input, #nr_context{repo = Repo} = Ctx) ->
    BaseQuery = kura_query:from(Resource),
    case nova_resource_policy:filter_query(Resource, BaseQuery, Ctx) of
        {error, _} = Err ->
            Err;
        {ok, Q0} ->
            Q1 = apply_input_filters(Q0, Input),
            case maps:get(get, Input, undefined) of
                undefined ->
                    case kura_repo_worker:all(Repo, Q1) of
                        {ok, Records} ->
                            {ok, [apply_calculations(Resource, R) || R <- Records]};
                        {error, _} = Err ->
                            Err
                    end;
                Id ->
                    Q2 = kura_query:where(Q1, {kura_schema:primary_key(Resource), Id}),
                    Q3 = kura_query:limit(Q2, 1),
                    case kura_repo_worker:one(Repo, Q3) of
                        {ok, Record} ->
                            {ok, apply_calculations(Resource, Record)};
                        {error, _} = Err ->
                            Err
                    end
            end
    end.

%% Update
run_update(Resource, Action, Input, #nr_context{repo = Repo} = Ctx) ->
    case maps:get(record, Input, undefined) of
        undefined ->
            {error, {missing_record, "update requires a record in input"}};
        Record ->
            Extra = #{record => Record},
            case nova_resource_policy:authorize(Resource, Action#nr_action.name, Extra, Ctx) of
                {error, _} = Err ->
                    Err;
                ok ->
                    Params = maps:get(params, Input, #{}),
                    CS0 = nova_resource_changeset:build(Resource, Record, Params, Action),
                    CS1 = apply_changes(CS0, Action#nr_action.changes, Ctx),
                    case CS1#kura_changeset.valid of
                        false ->
                            {error, CS1};
                        true ->
                            case kura_repo_worker:update(Repo, CS1) of
                                {ok, Updated} ->
                                    nova_resource_notifier:notify(
                                        Resource, Action#nr_action.name, Updated, Ctx
                                    ),
                                    {ok, apply_calculations(Resource, Updated)};
                                {error, _} = Err ->
                                    Err
                            end
                    end
            end
    end.

%% Destroy
run_destroy(Resource, Action, Input, #nr_context{repo = Repo} = Ctx) ->
    case maps:get(record, Input, undefined) of
        undefined ->
            {error, {missing_record, "destroy requires a record in input"}};
        Record ->
            Extra = #{record => Record},
            case nova_resource_policy:authorize(Resource, Action#nr_action.name, Extra, Ctx) of
                {error, _} = Err ->
                    Err;
                ok ->
                    CS = kura_changeset:cast(Resource, Record, #{}, []),
                    case kura_repo_worker:delete(Repo, CS) of
                        {ok, Deleted} ->
                            nova_resource_notifier:notify(
                                Resource, Action#nr_action.name, Deleted, Ctx
                            ),
                            {ok, Deleted};
                        {error, _} = Err ->
                            Err
                    end
            end
    end.

apply_changes(CS, [], _Ctx) ->
    CS;
apply_changes(CS, [Fun | Rest], Ctx) ->
    apply_changes(Fun(CS, Ctx), Rest, Ctx).

apply_input_filters(Query, Input) ->
    case maps:get(filter, Input, undefined) of
        undefined ->
            Query;
        Filters when is_list(Filters) ->
            lists:foldl(fun(F, Q) -> kura_query:where(Q, F) end, Query, Filters);
        Filter ->
            kura_query:where(Query, Filter)
    end.

maybe_set_tenant(undefined) -> ok;
maybe_set_tenant(Tenant) -> kura_tenant:put_tenant(Tenant).

apply_calculations(Resource, Record) ->
    Calcs = nova_resource:calculations(Resource),
    lists:foldl(
        fun(#nr_calculation{name = Name, fun_ = Fun}, Acc) ->
            Acc#{Name => Fun(Acc)}
        end,
        Record,
        Calcs
    ).
