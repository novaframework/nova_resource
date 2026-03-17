-module(nova_resource_api).
-moduledoc ~"""
Auto-generates Nova route entries for a resource's CRUD actions.

Given a resource module, generates a Nova route group map with REST
endpoints for the resource's defined actions.

## Generated Routes

| Action Type | Method | Path                    |
|-------------|--------|-------------------------|
| read        | GET    | /resources              |
| read (by id)| GET    | /resources/:id          |
| create      | POST   | /resources              |
| update      | PUT    | /resources/:id          |
| destroy     | DELETE | /resources/:id          |

## Example

```erlang
%% In your router:
nova_resource_api:routes(my_user_resource, #{
    prefix => <<"/api/users">>,
    security => fun my_auth:require_authenticated/1,
    fields => [id, email, name]
})
```
""".

-include("nova_resource.hrl").
-include_lib("kura/include/kura.hrl").

-export([routes/2, handle/3]).

-doc "Generate a Nova route group map for a resource.".
-spec routes(module(), map()) -> map().
routes(Resource, Opts) ->
    Prefix = maps:get(prefix, Opts, resource_prefix(Resource)),
    Security = maps:get(security, Opts, false),
    Plugins = maps:get(plugins, Opts, []),
    Actions = nova_resource:actions(Resource),
    Routes = lists:filtermap(
        fun(#nr_action{name = Name, type = Type}) ->
            route_for_action(Resource, Name, Type, Opts)
        end,
        Actions
    ),
    #{
        prefix => Prefix,
        security => Security,
        plugins => Plugins,
        routes => Routes
    }.

-doc "Generic handler that dispatches to nova_resource_action.".
-spec handle(module(), atom(), cowboy_req:req()) -> term().
handle(Resource, ActionName, Req) ->
    Repo = nova_resource:repo(Resource),
    Actor = maps:get(auth_data, Req, undefined),
    Ctx = #nr_context{
        actor = Actor,
        repo = Repo,
        resource = Resource,
        action = ActionName
    },
    {ok, Action} = nova_resource:action(Resource, ActionName),
    case Action#nr_action.type of
        read -> handle_read(Resource, ActionName, Req, Ctx);
        create -> handle_create(Resource, ActionName, Req, Ctx);
        update -> handle_update(Resource, ActionName, Req, Ctx);
        destroy -> handle_destroy(Resource, ActionName, Req, Ctx)
    end.

%%----------------------------------------------------------------------
%% Internal: route generation
%%----------------------------------------------------------------------

route_for_action(Resource, Name, read, _Opts) ->
    Handler = fun(Req) -> handle(Resource, Name, Req) end,
    {true, {<<>>, Handler, #{methods => [get]}}};
route_for_action(Resource, Name, create, _Opts) ->
    Handler = fun(Req) -> handle(Resource, Name, Req) end,
    {true, {<<>>, Handler, #{methods => [post]}}};
route_for_action(Resource, Name, update, _Opts) ->
    Handler = fun(Req) -> handle(Resource, Name, Req) end,
    {true, {<<"/:id">>, Handler, #{methods => [put]}}};
route_for_action(Resource, Name, destroy, _Opts) ->
    Handler = fun(Req) -> handle(Resource, Name, Req) end,
    {true, {<<"/:id">>, Handler, #{methods => [delete]}}}.

%%----------------------------------------------------------------------
%% Internal: request handling
%%----------------------------------------------------------------------

handle_read(Resource, ActionName, Req, Ctx) ->
    Input =
        case maps:get(bindings, Req, #{}) of
            #{id := Id} -> #{get => Id};
            _ -> #{}
        end,
    Fields = resource_fields(Resource),
    case nova_resource_action:run(Resource, ActionName, Input, Ctx) of
        {ok, Records} when is_list(Records) ->
            {json, #{<<"data">> => [serialize(R, Fields) || R <- Records]}};
        {ok, Record} when is_map(Record) ->
            {json, #{<<"data">> => serialize(Record, Fields)}};
        {error, not_found} ->
            {json, 404, #{}, #{<<"error">> => <<"not found">>}};
        {error, forbidden} ->
            {json, 403, #{}, #{<<"error">> => <<"forbidden">>}};
        {error, _} ->
            {json, 500, #{}, #{<<"error">> => <<"internal error">>}}
    end.

handle_create(Resource, ActionName, Req, Ctx) ->
    Params = maps:get(json, Req, #{}),
    Fields = resource_fields(Resource),
    case nova_resource_action:run(Resource, ActionName, #{params => Params}, Ctx) of
        {ok, Record} ->
            {json, 201, #{}, #{<<"data">> => serialize(Record, Fields)}};
        {error, #kura_changeset{} = CS} ->
            Errors = format_changeset_errors(CS),
            {json, 422, #{}, #{<<"errors">> => Errors}};
        {error, forbidden} ->
            {json, 403, #{}, #{<<"error">> => <<"forbidden">>}};
        {error, _} ->
            {json, 500, #{}, #{<<"error">> => <<"internal error">>}}
    end.

handle_update(Resource, ActionName, Req, Ctx) ->
    #{id := Id} = maps:get(bindings, Req, #{}),
    Params = maps:get(json, Req, #{}),
    Repo = nova_resource:repo(Resource),
    Fields = resource_fields(Resource),
    case kura_repo_worker:get(Repo, Resource, Id) of
        {ok, Record} ->
            case
                nova_resource_action:run(
                    Resource, ActionName, #{record => Record, params => Params}, Ctx
                )
            of
                {ok, Updated} ->
                    {json, #{<<"data">> => serialize(Updated, Fields)}};
                {error, #kura_changeset{} = CS} ->
                    Errors = format_changeset_errors(CS),
                    {json, 422, #{}, #{<<"errors">> => Errors}};
                {error, forbidden} ->
                    {json, 403, #{}, #{<<"error">> => <<"forbidden">>}};
                {error, _} ->
                    {json, 500, #{}, #{<<"error">> => <<"internal error">>}}
            end;
        {error, not_found} ->
            {json, 404, #{}, #{<<"error">> => <<"not found">>}}
    end.

handle_destroy(Resource, ActionName, Req, Ctx) ->
    #{id := Id} = maps:get(bindings, Req, #{}),
    Repo = nova_resource:repo(Resource),
    case kura_repo_worker:get(Repo, Resource, Id) of
        {ok, Record} ->
            case
                nova_resource_action:run(
                    Resource, ActionName, #{record => Record}, Ctx
                )
            of
                {ok, _} ->
                    {status, 204};
                {error, forbidden} ->
                    {json, 403, #{}, #{<<"error">> => <<"forbidden">>}};
                {error, _} ->
                    {json, 500, #{}, #{<<"error">> => <<"internal error">>}}
            end;
        {error, not_found} ->
            {json, 404, #{}, #{<<"error">> => <<"not found">>}}
    end.

%%----------------------------------------------------------------------
%% Internal: serialization
%%----------------------------------------------------------------------

serialize(Record, []) ->
    maps:fold(
        fun(K, V, Acc) ->
            Acc#{atom_to_binary(K, utf8) => to_json_value(V)}
        end,
        #{},
        Record
    );
serialize(Record, Fields) ->
    lists:foldl(
        fun(F, Acc) ->
            case maps:get(F, Record, undefined) of
                undefined -> Acc;
                V -> Acc#{atom_to_binary(F, utf8) => to_json_value(V)}
            end
        end,
        #{},
        Fields
    ).

to_json_value(V) when is_binary(V) -> V;
to_json_value(V) when is_integer(V) -> V;
to_json_value(V) when is_float(V) -> V;
to_json_value(V) when is_boolean(V) -> V;
to_json_value(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_json_value(V) when is_list(V) -> [to_json_value(E) || E <- V];
to_json_value(V) when is_map(V) -> V;
to_json_value(V) -> iolist_to_binary(io_lib:format("~p", [V])).

format_changeset_errors(#kura_changeset{errors = Errors}) ->
    maps:from_list([{atom_to_binary(F, utf8), M} || {F, M} <- Errors]).

resource_prefix(Resource) ->
    Table = Resource:table(),
    <<"/", Table/binary>>.

resource_fields(_Resource) ->
    [].
