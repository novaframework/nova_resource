-ifndef(NOVA_RESOURCE_HRL).
-define(NOVA_RESOURCE_HRL, true).

-record(nr_context, {
    actor = undefined :: term(),
    repo :: module(),
    resource :: module(),
    action :: atom(),
    tenant = undefined :: term(),
    opts = #{} :: map()
}).

-record(nr_action, {
    name :: atom(),
    type :: create | read | update | destroy,
    accept = [] :: [atom()],
    require = [] :: [atom()],
    changes = [] :: [
        fun((kura_changeset:changeset(), #nr_context{}) -> kura_changeset:changeset())
    ],
    validations = [] :: [fun((kura_changeset:changeset()) -> kura_changeset:changeset())]
}).

-record(nr_policy, {
    action :: atom() | '_',
    condition :: fun((term(), map()) -> true | false | fun((term()) -> term()))
}).

-record(nr_notifier, {
    action :: atom() | '_',
    type :: pubsub | callback,
    target :: atom() | fun()
}).

-record(nr_aggregate, {
    name :: atom(),
    type :: count | sum | avg | min | max,
    field :: atom() | '*',
    filter = undefined :: term()
}).

-record(nr_calculation, {
    name :: atom(),
    type :: atom(),
    fun_ :: fun((map()) -> term())
}).

-endif.
