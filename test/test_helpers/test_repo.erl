-module(test_repo).

-behaviour(kura_repo).

-export([otp_app/0]).

otp_app() -> nova_resource.
