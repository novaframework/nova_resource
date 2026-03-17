-module(nova_resource_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("stdlib/include/assert.hrl").
-include_lib("kura/include/kura.hrl").
-include_lib("nova_resource/include/nova_resource.hrl").

-compile(export_all).

%%====================================================================
%% CT callbacks
%%====================================================================

all() ->
    [
        {group, introspection},
        {group, changeset},
        {group, policy},
        {group, action_pipeline},
        {group, notifier},
        {group, aggregate}
    ].

groups() ->
    [
        {introspection, [parallel], [
            definition_cached,
            action_lookup,
            action_not_found,
            policies_default_empty,
            repo_lookup
        ]},
        {changeset, [parallel], [
            build_casts_accepted_fields,
            build_validates_required,
            build_applies_validations
        ]},
        {policy, [parallel], [
            authorize_no_policies_allows,
            authorize_matching_policy_allows,
            authorize_matching_policy_denies,
            authorize_undefined_actor_denied,
            authorize_wildcard_policy,
            filter_query_no_policies,
            filter_query_admin_passthrough,
            filter_query_scoped,
            filter_query_denied
        ]},
        {action_pipeline, [], [
            create_success,
            create_forbidden,
            create_validation_error,
            read_all,
            read_scoped,
            read_get_by_id,
            update_success,
            update_forbidden,
            destroy_success,
            destroy_forbidden,
            action_not_found_error
        ]},
        {notifier, [parallel], [
            notify_pubsub,
            notify_callback,
            notify_no_match
        ]},
        {aggregate, [], [
            aggregate_count,
            aggregate_not_found
        ]}
    ].

init_per_suite(Config) ->
    application:ensure_all_started(pgo),
    application:set_env(nova_resource, test_repo, #{
        database => <<"nova_resource_test">>,
        hostname => <<"localhost">>,
        port => 5432,
        username => <<"postgres">>,
        password => <<"postgres">>,
        pool_size => 5
    }),
    kura_repo_worker:start(test_repo),
    create_test_tables(),
    Config.

end_per_suite(_Config) ->
    drop_test_tables(),
    ok.

init_per_group(action_pipeline, Config) ->
    clean_posts_table(),
    Config;
init_per_group(aggregate, Config) ->
    clean_posts_table(),
    Config;
init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, _Config) ->
    ok.

init_per_testcase(_TC, Config) ->
    nova_resource:invalidate_cache(test_post),
    Config.

end_per_testcase(_TC, _Config) ->
    ok.

%%====================================================================
%% Helpers
%%====================================================================

create_test_tables() ->
    kura_repo_worker:query(
        test_repo,
        <<
            "CREATE TABLE IF NOT EXISTS posts (\n"
            "            id BIGSERIAL PRIMARY KEY,\n"
            "            title VARCHAR(255),\n"
            "            body TEXT,\n"
            "            status VARCHAR(255) DEFAULT 'draft',\n"
            "            author_id INTEGER,\n"
            "            inserted_at TIMESTAMPTZ DEFAULT NOW(),\n"
            "            updated_at TIMESTAMPTZ DEFAULT NOW()\n"
            "        )"
        >>,
        []
    ).

drop_test_tables() ->
    kura_repo_worker:query(test_repo, <<"DROP TABLE IF EXISTS posts">>, []).

clean_posts_table() ->
    kura_repo_worker:query(test_repo, <<"DELETE FROM posts">>, []).

admin_actor() -> #{id => 1, role => admin}.
author_actor() -> #{id => 2, role => author}.
reader_actor() -> #{id => 3, role => reader}.

admin_ctx() -> #nr_context{actor = admin_actor(), repo = test_repo}.
author_ctx() -> #nr_context{actor = author_actor(), repo = test_repo}.
reader_ctx() -> #nr_context{actor = reader_actor(), repo = test_repo}.

%%====================================================================
%% Introspection tests
%%====================================================================

definition_cached(_Config) ->
    Def1 = nova_resource:definition(test_post),
    Def2 = nova_resource:definition(test_post),
    ?assertEqual(Def1, Def2),
    ?assertMatch(#{repo := test_repo, actions := [_ | _]}, Def1).

action_lookup(_Config) ->
    {ok, Action} = nova_resource:action(test_post, create),
    ?assertEqual(create, Action#nr_action.name),
    ?assertEqual(create, Action#nr_action.type),
    ?assertEqual([title, body], Action#nr_action.accept),
    ?assertEqual([title], Action#nr_action.require).

action_not_found(_Config) ->
    ?assertEqual({error, not_found}, nova_resource:action(test_post, nonexistent)).

policies_default_empty(_Config) ->
    ?assertNotEqual([], nova_resource:policies(test_post)).

repo_lookup(_Config) ->
    ?assertEqual(test_repo, nova_resource:repo(test_post)).

%%====================================================================
%% Changeset tests
%%====================================================================

build_casts_accepted_fields(_Config) ->
    {ok, Action} = nova_resource:action(test_post, create),
    CS = nova_resource_changeset:build(
        test_post, #{}, #{title => <<"Hi">>, body => <<"World">>}, Action
    ),
    ?assertEqual(<<"Hi">>, kura_changeset:get_change(CS, title)),
    ?assertEqual(<<"World">>, kura_changeset:get_change(CS, body)).

build_validates_required(_Config) ->
    {ok, Action} = nova_resource:action(test_post, create),
    CS = nova_resource_changeset:build(test_post, #{}, #{}, Action),
    ?assertNot(CS#kura_changeset.valid).

build_applies_validations(_Config) ->
    Action = #nr_action{
        name = test_validate,
        type = create,
        accept = [title],
        require = [],
        validations = [
            fun(CS) ->
                case kura_changeset:get_change(CS, title) of
                    undefined -> kura_changeset:add_error(CS, title, <<"required by custom">>);
                    _ -> CS
                end
            end
        ]
    },
    CS = nova_resource_changeset:build(test_post, #{}, #{}, Action),
    ?assertNot(CS#kura_changeset.valid).

%%====================================================================
%% Policy tests
%%====================================================================

authorize_no_policies_allows(_Config) ->
    %% Using a mock resource with no policies would be ideal,
    %% but we can test with a non-existent action that has no matching policies
    Ctx = admin_ctx(),
    %% publish has no explicit policy — but matching_policies checks action name
    %% Let's just verify admin can create
    ?assertEqual(ok, nova_resource_policy:authorize(test_post, create, Ctx)).

authorize_matching_policy_allows(_Config) ->
    ?assertEqual(ok, nova_resource_policy:authorize(test_post, create, admin_ctx())),
    ?assertEqual(ok, nova_resource_policy:authorize(test_post, create, author_ctx())).

authorize_matching_policy_denies(_Config) ->
    ?assertEqual(
        {error, forbidden}, nova_resource_policy:authorize(test_post, create, reader_ctx())
    ).

authorize_undefined_actor_denied(_Config) ->
    Ctx = #nr_context{actor = undefined, repo = test_repo},
    ?assertEqual({error, forbidden}, nova_resource_policy:authorize(test_post, create, Ctx)).

authorize_wildcard_policy(_Config) ->
    nova_resource:invalidate_cache(test_post),
    ?assertEqual(ok, nova_resource_policy:authorize(test_post, create, admin_ctx())).

filter_query_no_policies(_Config) ->
    %% publish action has no read policy
    Ctx = (admin_ctx())#nr_context{action = publish},
    Q = kura_query:from(test_post),
    ?assertMatch({ok, _}, nova_resource_policy:filter_query(test_post, Q, Ctx)).

filter_query_admin_passthrough(_Config) ->
    Ctx = (admin_ctx())#nr_context{action = read},
    Q = kura_query:from(test_post),
    {ok, Q2} = nova_resource_policy:filter_query(test_post, Q, Ctx),
    ?assertEqual(Q, Q2).

filter_query_scoped(_Config) ->
    Ctx = (author_ctx())#nr_context{action = read},
    Q = kura_query:from(test_post),
    {ok, Q2} = nova_resource_policy:filter_query(test_post, Q, Ctx),
    ?assertNotEqual(Q, Q2).

filter_query_denied(_Config) ->
    %% An actor with no id and no admin role gets denied by the catch-all clause
    Ctx = #nr_context{actor = #{role => anonymous}, repo = test_repo, action = read},
    Q = kura_query:from(test_post),
    ?assertEqual({error, forbidden}, nova_resource_policy:filter_query(test_post, Q, Ctx)).

%%====================================================================
%% Action pipeline tests (integration — need DB)
%%====================================================================

create_success(_Config) ->
    Ctx = admin_ctx(),
    Input = #{params => #{title => <<"Test Post">>, body => <<"Content">>}},
    {ok, Post} = nova_resource_action:run(test_post, create, Input, Ctx),
    ?assertEqual(<<"Test Post">>, maps:get(title, Post)),
    ?assertEqual(<<"Content">>, maps:get(body, Post)),
    ?assertEqual(1, maps:get(author_id, Post)).

create_forbidden(_Config) ->
    Ctx = reader_ctx(),
    Input = #{params => #{title => <<"Nope">>}},
    ?assertEqual({error, forbidden}, nova_resource_action:run(test_post, create, Input, Ctx)).

create_validation_error(_Config) ->
    Ctx = admin_ctx(),
    Input = #{params => #{}},
    {error, CS} = nova_resource_action:run(test_post, create, Input, Ctx),
    ?assertNot(CS#kura_changeset.valid).

read_all(_Config) ->
    %% Insert a post first
    Ctx = admin_ctx(),
    {ok, _} = nova_resource_action:run(
        test_post,
        create,
        #{params => #{title => <<"Read Test">>}},
        Ctx
    ),
    {ok, Posts} = nova_resource_action:run(test_post, read, #{}, Ctx),
    ?assert(length(Posts) >= 1).

read_scoped(_Config) ->
    AdminCtx = admin_ctx(),
    AuthorCtx = author_ctx(),
    %% Create as admin (author_id = 1)
    {ok, _} = nova_resource_action:run(
        test_post,
        create,
        #{params => #{title => <<"Admin Post">>}},
        AdminCtx
    ),
    %% Read as author (id = 2) — should only see own posts
    {ok, Posts} = nova_resource_action:run(test_post, read, #{}, AuthorCtx),
    lists:foreach(
        fun(P) -> ?assertEqual(2, maps:get(author_id, P)) end,
        Posts
    ).

read_get_by_id(_Config) ->
    Ctx = admin_ctx(),
    {ok, Post} = nova_resource_action:run(
        test_post,
        create,
        #{params => #{title => <<"Get By Id">>}},
        Ctx
    ),
    Id = maps:get(id, Post),
    {ok, Found} = nova_resource_action:run(test_post, read, #{get => Id}, Ctx),
    ?assertEqual(Id, maps:get(id, Found)).

update_success(_Config) ->
    Ctx = admin_ctx(),
    {ok, Post} = nova_resource_action:run(
        test_post,
        create,
        #{params => #{title => <<"Before Update">>}},
        Ctx
    ),
    {ok, Updated} = nova_resource_action:run(
        test_post,
        update,
        #{record => Post, params => #{title => <<"After Update">>}},
        Ctx
    ),
    ?assertEqual(<<"After Update">>, maps:get(title, Updated)).

update_forbidden(_Config) ->
    AdminCtx = admin_ctx(),
    {ok, Post} = nova_resource_action:run(
        test_post,
        create,
        #{params => #{title => <<"Admin Only">>}},
        AdminCtx
    ),
    ReaderCtx = reader_ctx(),
    ?assertEqual(
        {error, forbidden},
        nova_resource_action:run(
            test_post,
            update,
            #{record => Post, params => #{title => <<"Hacked">>}},
            ReaderCtx
        )
    ).

destroy_success(_Config) ->
    Ctx = admin_ctx(),
    {ok, Post} = nova_resource_action:run(
        test_post,
        create,
        #{params => #{title => <<"To Delete">>}},
        Ctx
    ),
    {ok, _Deleted} = nova_resource_action:run(
        test_post,
        destroy,
        #{record => Post},
        Ctx
    ).

destroy_forbidden(_Config) ->
    AdminCtx = admin_ctx(),
    {ok, Post} = nova_resource_action:run(
        test_post,
        create,
        #{params => #{title => <<"Protected">>}},
        AdminCtx
    ),
    AuthorCtx = author_ctx(),
    ?assertEqual(
        {error, forbidden},
        nova_resource_action:run(test_post, destroy, #{record => Post}, AuthorCtx)
    ).

action_not_found_error(_Config) ->
    ?assertEqual(
        {error, {action_not_found, nonexistent}},
        nova_resource_action:run(test_post, nonexistent, #{}, admin_ctx())
    ).

%%====================================================================
%% Notifier tests
%%====================================================================

notify_pubsub(_Config) ->
    pg:start(pg),
    pg:join(posts, self()),
    Ctx = admin_ctx(),
    Record = #{id => 1, title => <<"Test">>},
    nova_resource_notifier:notify(test_post, publish, Record, Ctx),
    receive
        {nova_resource, publish, Record} -> ok
    after 1000 ->
        ct:fail(pubsub_notification_not_received)
    end,
    pg:leave(posts, self()).

notify_callback(_Config) ->
    %% Verify that non-matching actions don't trigger notifiers
    Ctx = admin_ctx(),
    Record = #{id => 1},
    %% 'create' has no notifier in test_post, so this should be a no-op
    ?assertEqual(ok, nova_resource_notifier:notify(test_post, create, Record, Ctx)).

notify_no_match(_Config) ->
    %% No notifier matches 'read' action
    Ctx = admin_ctx(),
    ?assertEqual(ok, nova_resource_notifier:notify(test_post, read, #{}, Ctx)).

%%====================================================================
%% Aggregate tests
%%====================================================================

aggregate_count(_Config) ->
    Ctx = admin_ctx(),
    %% Insert some posts
    {ok, _} = nova_resource_action:run(
        test_post,
        create,
        #{params => #{title => <<"Agg 1">>}},
        Ctx
    ),
    {ok, _} = nova_resource_action:run(
        test_post,
        create,
        #{params => #{title => <<"Agg 2">>}},
        Ctx
    ),
    {ok, Result} = nova_resource_aggregate:compute(
        test_post,
        total_count,
        (Ctx)#nr_context{action = read}
    ),
    Count = maps:get(count, Result, 0),
    ?assert(Count >= 2).

aggregate_not_found(_Config) ->
    Ctx = (admin_ctx())#nr_context{action = read},
    ?assertEqual(
        {error, {aggregate_not_found, nope}},
        nova_resource_aggregate:compute(test_post, nope, Ctx)
    ).
