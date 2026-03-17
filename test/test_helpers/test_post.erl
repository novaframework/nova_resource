-module(test_post).

-behaviour(kura_schema).
-behaviour(nova_resource).

-include_lib("kura/include/kura.hrl").
-include_lib("nova_resource/include/nova_resource.hrl").

-export([
    table/0,
    fields/0,
    resource/0
]).

table() -> <<"posts">>.

fields() ->
    [
        #kura_field{name = id, type = id, primary_key = true},
        #kura_field{name = title, type = string},
        #kura_field{name = body, type = text},
        #kura_field{name = status, type = string, default = <<"draft">>},
        #kura_field{name = author_id, type = integer},
        #kura_field{name = inserted_at, type = utc_datetime},
        #kura_field{name = updated_at, type = utc_datetime}
    ].

resource() ->
    #{
        repo => test_repo,
        actions => [
            #nr_action{
                name = create,
                type = create,
                accept = [title, body],
                require = [title],
                changes = [fun set_author/2]
            },
            #nr_action{
                name = read,
                type = read
            },
            #nr_action{
                name = update,
                type = update,
                accept = [title, body]
            },
            #nr_action{
                name = publish,
                type = update,
                accept = [],
                changes = [fun set_published/2]
            },
            #nr_action{
                name = destroy,
                type = destroy
            }
        ],
        policies => [
            #nr_policy{
                action = create,
                condition = fun
                    (#{role := admin}, _) -> true;
                    (#{role := author}, _) -> true;
                    (_, _) -> false
                end
            },
            #nr_policy{
                action = read,
                condition = fun
                    (#{role := admin}, _) ->
                        true;
                    (#{id := Uid}, _) ->
                        fun(Q) -> kura_query:where(Q, {author_id, Uid}) end;
                    (_, _) ->
                        false
                end
            },
            #nr_policy{
                action = update,
                condition = fun
                    (#{role := admin}, _) -> true;
                    (#{id := Uid}, #{record := #{author_id := Uid}}) -> true;
                    (_, _) -> false
                end
            },
            #nr_policy{
                action = destroy,
                condition = fun
                    (#{role := admin}, _) -> true;
                    (_, _) -> false
                end
            }
        ],
        notifiers => [
            #nr_notifier{action = publish, type = pubsub, target = posts}
        ],
        aggregates => [
            #nr_aggregate{name = total_count, type = count, field = '*'},
            #nr_aggregate{
                name = published_count,
                type = count,
                field = '*',
                filter = {status, <<"published">>}
            }
        ],
        calculations => []
    }.

set_author(CS, #nr_context{actor = #{id := Uid}}) ->
    kura_changeset:put_change(CS, author_id, Uid).

set_published(CS, _Ctx) ->
    kura_changeset:put_change(CS, status, <<"published">>).
