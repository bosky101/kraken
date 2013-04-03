%% @doc Synchronous TCP Client Interface based on the Memcached protocol so that
%% we can use existing Memcached clients. This protocol may seem a little
%% counter intuitive but that is because we want it to map cleanly to the
%% Memcached protocol. For example, our own protocol would have single line
%% SUBSCRIBE and UNSUBSCRIBE operations such that we wouldn't need to include
%% the number of bytes.

%%
%% Supported Operations:
%%
%% ---------------------------------------------------------------------------
%% Request: "set subscribe 0 0 <bytes>\r\n<Topic1> <Topic2> ... <TopicN>\r\n"
%%
%% Description:
%%    Subscribes the client to new topics without changing the existing
%%    subscriptions the client may have.
%%
%%    - <bytes> is the number of bytes in the data block to follow, *not*
%%      including the delimiting \r\n.
%%    - <Topic*> is the name of a topic to subscribe to.
%%
%% Response:
%%    "STORED\r\n"
%%
%% ---------------------------------------------------------------------------
%% Request: "set unsubscribe 0 0 <bytes>\r\n<Topic1> <Topic2> ... <TopicN>\r\n"
%%
%% Description:
%%    Unsubscribes the client from the specified topics.
%%
%%    - <bytes> is the number of bytes in the data block to follow, *not*
%%      including the delimiting \r\n.
%%    - <Topic*> is the name of a topic to unsubscribe from.
%%
%% Response:
%%    "STORED\r\n"
%%
%% ---------------------------------------------------------------------------
%% Request: "quit\r\n"
%%
%% Description:
%%    Disconnects the client. Note that clients can also just close the
%%    the connection. This exists primarly to make testing with telnet better.
%%
%% Response:
%%    The client's TCP connection will be closed on the kraken server.
%%
%% ---------------------------------------------------------------------------
%% Request: "get messages\r\n"
%%
%% Description:
%%    Returns all messages that have been published to any of the queues that
%%    the client was subscribed to when the messages were published.
%%
%% Response:
%%    If there are any messages in the client's queue the server will send a
%%    single memcached item in response to the get request. The value of the
%%    item itself must be parsed to break out the individual messages.
%%
%%    A memcached item looks like this:
%%    "VALUE messages 0 <bytes>\r\n<data block>\r\n"
%%
%%    - <bytes> is the length of the data block to follow, *not* including
%%      its delimiting \r\n
%%    - <data block> is the data for the messages. Each message will look like
%%      this:
%%
%%      "MESSAGE <topic*> <bytes>\r\n<message data block>\r\n"
%%
%%      - <topic*> is a space delimited set of topic names the message matched.
%%      - <bytes> is the number of bytes in the message data block to follow,
%%        *not* including its delimiting "\r\n".
%%      - <message data block> is the payload message data.
%%
%% ---------------------------------------------------------------------------
%% Request: "set publish 0 0 <bytes>\r\n<data block>\r\n"
%%
%% Description:
%%    Publishes a message to all subscribers of the topics it is published to.
%%
%%    - <bytes> is the length of the data block to follow, *not* including
%%      its delimiting \r\n
%%    - <data block> is the data for the messages. Each message will look like
%%      this:
%%
%%      "MESSAGE <topic*> <bytes>\r\n<message data block>\r\n"
%%
%%      - <topic*> is a space delimited set of topic names the message matched.
%%      - <bytes> is the number of bytes in the message data block to follow,
%%        *not* including its delimiting "\r\n".
%%      - <message data block> is the payload message data.
%%
%% Response:
%%    "STORED\r\n"
-module(kraken_memcached).

-behavior(kraken_tcp_connection).

%%%-----------------------------------------------------------------
%%% Exports
%%%-----------------------------------------------------------------

%% Callbacks
-export([init/1, handle_client_disconnect/2, handle_data/3,
         handle_server_busy/1, handle_client_timeout/2]).

%% Utility
-export([serialize_message_entries/1, serialize_topics/1,
         parse_publish_entries/1]).

%%%-----------------------------------------------------------------
%%% Definitions
%%%-----------------------------------------------------------------

-record(state, {
    command,           % The name of the command
    bytes_remaining=0, % The number of bytes that remain in the command
    buffer=[],         % List of lines that make up a partial request
    request_count=0,   % The number of requests this connection processed
    qpid               % The kraken_queue process
    }).

%% Responses
-define(STORED_RESP, <<"STORED\r\n">>).
-define(BAD_COMMAND_RESP, <<"ERROR\r\n">>).
-define(CLIENT_ERROR_RESP_PREFIX, <<"CLIENT_ERROR ">>).
-define(SERVER_ERROR_RESP_PREFIX, <<"SERVER_ERROR ">>).

%% Commands
-define(SUBSCRIBE_COMMAND, <<"subscribe">>).
-define(UNSUBSCRIBE_COMMAND, <<"unsubscribe">>).
-define(PUBLISH_COMMAND, <<"publish">>).
-define(MESSAGES_COMMAND, <<"messages">>).
-define(QUIT_COMMAND, <<"quit">>).

%%%-----------------------------------------------------------------
%%% Callbacks
%%%-----------------------------------------------------------------

init(Socket) ->
  lager:debug("(~p) Client connected.", [self()]),
  QueueName = client_name(Socket),
  {ok, QPid} = kraken_router:start_queue_link(QueueName),
  {ok, #state{qpid=QPid}}.

handle_data(<<"quit\r\n">>, Socket, State=#state{bytes_remaining=0}) ->
  handle_and_log_command(?QUIT_COMMAND, empty, Socket, State);

handle_data(<<"get messages\r\n">>, Socket, State=#state{bytes_remaining=0}) ->
  handle_and_log_command(?MESSAGES_COMMAND, empty, Socket, State);
% Some clients append a space too
handle_data(<<"get messages \r\n">>, Socket, State=#state{bytes_remaining=0}) ->
  handle_and_log_command(?MESSAGES_COMMAND, empty, Socket, State);

handle_data(<<"set ", Rest/binary>>, _Socket,
            State=#state{
              bytes_remaining=0,
              request_count=RequestCount}) ->
  {Command, BytesRemaining} = parse_command(Rest),
  {ok, State#state{
         bytes_remaining=BytesRemaining+2,
         command=Command,
         request_count=RequestCount+1}};

handle_data(Other, Socket, State=#state{bytes_remaining=0}) ->
  log_command(Other, bad_command),
  Start = erlang:now(),
  TimeMs = timer:now_diff(erlang:now(), Start) / 1000,
  lager:warning(
      "(~p) [~p ms] Got bad response with no bytes remaining in Command ~s",
      [self(), TimeMs, bad_command]),
  gen_tcp:send(Socket, ?BAD_COMMAND_RESP),
  {stop, State};

% When bytes_remaining is greater than 0 then we are processing the datablock
% segment of the request.
handle_data(Data, Socket,
            State=#state{
              command=Command,
              bytes_remaining=BytesRemaining,
              buffer=Buffer}) ->
  Bytes = size(Data),
  if
    Bytes =:= BytesRemaining ->
      BinData = list_to_binary([lists:reverse(Buffer), Data]),
      BinDataWithoutEndl = binary_part(BinData, 0, size(BinData)-2),
      NewState = State#state{
          buffer=[],
          bytes_remaining=0,
          command=undefined},
      handle_and_log_command(Command, BinDataWithoutEndl, Socket, NewState);
    Bytes > BytesRemaining ->
      lager:warning(
          "Memcached server received too many bytes from client ~p > ~p",
          [Bytes, BytesRemaining]),
      gen_tcp:send(Socket, ?BAD_COMMAND_RESP),
      {stop, State};
    true ->
      {ok, State#state{
            buffer=[Data|Buffer],
            bytes_remaining=BytesRemaining-Bytes}}
  end.

handle_client_disconnect(_Socket, State=#state{qpid=QPid}) ->
  lager:debug("(~p) Client disconnected.", [self()]),
  kraken_queue:stop(QPid),
  {stop, State}.

handle_client_timeout(Socket, State=#state{qpid=Qpid}) ->
  lager:error("(~p) Client ~s timed out", [self(), client_name(Socket)]),
  kraken_queue:stop(Qpid),
  {stop, State}.

handle_server_busy(Socket) ->
  lager:info("Server reached max clients. Rejecting connection."),
  gen_tcp:send(Socket,
      [?SERVER_ERROR_RESP_PREFIX, <<"Too many clients\r\n">>]),
  ok.

handle_and_log_command(Command, Data, Socket, State) ->
  Start = erlang:now(),
  case handle_command(Command, Data, Socket, State) of
    {Term, State, LogData} ->
      log_command(Start, Command, LogData),
      {Term, State};
    {Term, State} ->
      log_command(Start, Command),
      {Term, State}
  end.

%%%-----------------------------------------------------------------
%%% Command Handlers
%%%-----------------------------------------------------------------

handle_command(?QUIT_COMMAND, empty, _Socket, State) ->
  {stop, State};

handle_command(?SUBSCRIBE_COMMAND, Data, Socket, State=#state{qpid=QPid}) ->
  Topics = binary:split(Data, <<" ">>, [global]),
  kraken_router:subscribe(QPid, Topics),
  gen_tcp:send(Socket, ?STORED_RESP),
  {ok, State, Topics};

handle_command(?UNSUBSCRIBE_COMMAND, Data, Socket, State=#state{qpid=QPid}) ->
  Topics = binary:split(Data, <<" ">>, [global]),
  kraken_router:unsubscribe(QPid, Topics),
  gen_tcp:send(Socket, ?STORED_RESP),
  {ok, State, Topics};

handle_command(?PUBLISH_COMMAND, Data, Socket, State=#state{qpid=QPid}) ->
  Entries = parse_publish_entries(Data),
  lists:foreach(fun({Topics, Message}) ->
    kraken_router:publish(QPid, Topics, Message)
  end, Entries),
  gen_tcp:send(Socket, ?STORED_RESP),
  {ok, State, Entries};

handle_command(?MESSAGES_COMMAND, empty, Socket, State=#state{qpid=QPid}) ->
  Messages = kraken_queue:receive_messages(QPid),
  case Messages of
    [] ->
      gen_tcp:send(Socket, <<"END\r\n">>);
    _ ->
      {DataBytes, DataBlock} = serialize_message_entries(Messages),
      gen_tcp:send(Socket, [
          <<"VALUE messages 0 ">>,
          list_to_binary(integer_to_list(DataBytes-2)),
          <<"\r\n">>,
          DataBlock,
          <<"END\r\n">>])
  end,
  {ok, State, Messages};

handle_command(Command, _Data, Socket, State) ->
  lager:warning("(~p) Bad command ~s", [self(), Command]),
  gen_tcp:send(Socket, ?BAD_COMMAND_RESP),
  {stop, State, bad_command}.

%%%-----------------------------------------------------------------
%%% Utility
%%%-----------------------------------------------------------------

serialize_topics(Topics) ->
  list_to_binary(lists:flatten(lists:map(fun(Topic) ->
    [Topic, <<" ">>]
  end, Topics))).

serialize_message_entries(MessageEntries) ->
  DataBlock = lists:flatten(lists:map(fun({Topics, Message}) ->
    [<<"MESSAGE ">>,
     serialize_topics(Topics),
     list_to_binary(integer_to_list(size(Message))),
     <<"\r\n">>,
     Message,
     <<"\r\n">>]
  end, MessageEntries)),
  DataBytes = lists:foldl(fun(Part, Sum) ->
    size(Part) + Sum
  end, 0, DataBlock),
  {DataBytes, DataBlock}.

log_command(Start, Command) ->
  log_command(Start, Command, []).

log_command(Start, Command, Details) ->
  TimeMs = timer:now_diff(erlang:now(), Start) / 1000,
  lager:debug(
      "(~p) [~p ms] Command ~s ~p", [self(), TimeMs, Command, Details]).

parse_command(Bin) ->
  [Command, _, _, SBytesRemaining] =
      binary:split(Bin, [<<" ">>, <<"\r\n">>], [global, trim]),
  {Command, list_to_integer(binary_to_list(SBytesRemaining))}.

parse_publish_entries(<<>>) ->
  [];
parse_publish_entries(Bin) ->
  parse_publish_entries([], Bin).

parse_publish_entries(Acc, <<"MESSAGE ", Rest/binary>>) ->
  {Entry, More} = parse_publish_entry([], 0, Rest),
  parse_publish_entries([Entry|Acc], More);
parse_publish_entries(Acc, <<>>) ->
  lists:reverse(Acc).

parse_publish_entry(Topics, Idx, Bin) ->
  case Bin of
    <<Topic:Idx/binary, " ", Tail/binary>> ->
      parse_publish_entry([Topic|Topics], 0, Tail);
    <<SBytes:Idx/binary, "\r\n", Tail/binary>> ->
      Bytes = list_to_integer(binary_to_list(SBytes)),
      <<Message:Bytes/binary, "\r\n", Rest/binary>> = Tail,
      {{lists:reverse(Topics), Message}, Rest};
    _ ->
      parse_publish_entry(Topics, Idx+1, Bin)
  end.

%%%-----------------------------------------------------------------
%%% Tests
%%%-----------------------------------------------------------------

-include_lib("eunit/include/eunit.hrl").
-ifdef(TEST).

client_name(Socket) ->
  {ok, {Ip, Port}} = inet:peername(Socket),
  list_to_binary(io_lib:format("~p:~p (memcached)", [Ip, Port])).

parse_command_test() ->
  ?assertMatch({<<"SUBSCRIBE">>, 123}, parse_command(<<"SUBSCRIBE 0 0 123\r\n">>)).

parse_publish_entries_test() ->
  ?assertMatch(
      [{[<<"a">>], <<"m1">>}],
      parse_publish_entries(<<"MESSAGE a 2\r\nm1\r\n">>)),
  ?assertMatch(
      [{[<<"a">>, <<"b">>], <<"m1">>},
       {[<<"c">>], <<"a\r\nb\nc">>}],
      parse_publish_entries(<<"MESSAGE a b 2\r\nm1\r\nMESSAGE c 6\r\na\r\nb\nc\r\n">>)).

-endif.

