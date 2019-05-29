-module(fcm_api).

-export([push/3]).

-define(HTTP_OPTIONS, [{body_format, binary}]).
-define(BASEURL, "https://fcm.googleapis.com/fcm/send").

-define(HEADERS(ApiKey), [{"Authorization", ApiKey}]).
-define(CONTENT_TYPE, "application/json").

-define(HTTP_REQUEST(ApiKey, Message),
        {?BASEURL, ?HEADERS(ApiKey), ?CONTENT_TYPE, Message}).

push(RegIds, Message, ApiKey) when is_list(Message) ->
    MessageMap = maps:from_list(Message),
    push(RegIds, MessageMap, ApiKey);

push(RegId, Message, ApiKey) when is_binary(RegId) ->
    push([RegId], Message, ApiKey);

push([RegId], Message, ApiKey) ->
    Request = maps:put(<<"to">>, RegId, Message),
    push(jsx:encode(Request), ApiKey);

push(RegIds, Message, ApiKey) ->
    Request = maps:put(<<"registration_ids">>, RegIds, Message),
    push(jsx:encode(Request), ApiKey).

push(Message, ApiKey) ->
    try httpc:request(post, ?HTTP_REQUEST(ApiKey, Message), [], ?HTTP_OPTIONS) of
        {ok, {{_, 200, _}, _Headers, Body}} ->
            Json = jsx:decode(Body),
            logger:info("{~p:~p ~p}: Result was: ~p", [?MODULE, ?LINE, self(), Json]),
            {ok, result_from(Json)};
        {ok, {{_, 400, _}, _, Body}} ->
            logger:error("{~p:~p ~p}: Error in request. Reason was: Bad Request - ~p", [?MODULE, ?LINE, self(), Body]),
            {error, Body};
        {ok, {{_, 401, _}, _, _}} ->
            logger:error("{~p:~p ~p}: Error in request. Reason was: authorization error", [?MODULE, ?LINE, self()]),
            {error, auth_error};
        {ok, {{_, Code, _}, Headers, _}} when Code >= 500 andalso Code =< 599 ->
            RetryTime = retry_after_from(Headers),
            logger:error("{~p:~p ~p}: Error in request. Reason was: retry. Will retry in: ~p", [?MODULE, ?LINE, self(), RetryTime]),
            {error, {retry, RetryTime}};
        {ok, {{_StatusLine, _, _}, _, _Body}} ->
            logger:error("{~p:~p ~p}: Error in request. Reason was: timeout", [?MODULE, ?LINE, self()]),
            {error, timeout};
        {error, Reason} ->
            logger:error("{~p:~p ~p}: Error in request. Reason was: ~p", [?MODULE, ?LINE, self(), Reason]),
            {error, Reason};
        OtherError ->
            logger:error("{~p:~p ~p}: Error in request. Reason was: ~p", [?MODULE, ?LINE, self(), OtherError]),
            {noreply, unknown}
    catch
        Exception ->
            logger:error("{~p:~p ~p}: Error in request. Exception ~p while calling URL: ~p", [?MODULE, ?LINE, self(), Exception, ?BASEURL]),
            {error, Exception}
    end.

result_from(Json) ->
    {
      proplists:get_value(<<"multicast_id">>, Json),
      proplists:get_value(<<"success">>, Json),
      proplists:get_value(<<"failure">>, Json),
      proplists:get_value(<<"canonical_ids">>, Json),
      proplists:get_value(<<"results">>, Json)
    }.

retry_after_from(Headers) ->
    case proplists:get_value("retry-after", Headers) of
        undefined ->
            no_retry;
        RetryTime ->
            case string:to_integer(RetryTime) of
                {Time, _} when is_integer(Time) ->
                    Time;
                {error, no_integer} ->
                   Date = httpd_util:convert_request_date(RetryTime),
                   Now = calendar:universal_time(),
                   calendar:datetime_to_gregorian_seconds(Date) - calendar:datetime_to_gregorian_seconds(Now)
            end
    end.
