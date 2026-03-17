-module(nova_resource_changeset).

-include("nova_resource.hrl").
-include_lib("kura/include/kura.hrl").

-export([
    build/4
]).

-spec build(module(), map(), map(), #nr_action{}) -> #kura_changeset{}.
build(Resource, Data, Params, #nr_action{
    accept = Accept, require = Require, validations = Validations
}) ->
    EffectiveAccept = effective_accept(Resource, Accept),
    CS0 = kura_changeset:cast(Resource, Data, Params, EffectiveAccept),
    CS1 =
        case Require of
            [] -> CS0;
            _ -> kura_changeset:validate_required(CS0, Require)
        end,
    apply_validations(CS1, Validations).

effective_accept(_Resource, []) ->
    [];
effective_accept(_Resource, Accept) when is_list(Accept), Accept =/= [] ->
    Accept;
effective_accept(Resource, _) ->
    nova_resource:default_accept(Resource).

apply_validations(CS, []) ->
    CS;
apply_validations(CS, [Fun | Rest]) ->
    apply_validations(Fun(CS), Rest).
