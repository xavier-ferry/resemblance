-module(bin_parser).
-export([read_file_as_list/1, foreach/2, 
	 open_file/1, parse/1, parse/2, parse_binary/1]).
-define(BUFFER_READ_SIZE, 10).

%-----------------------
% public api

% open file handle for passing to parse_file 
open_file(Filename) ->
    case file:open(Filename,[read,binary,raw,compressed]) of
	{ ok,F } -> F;
	E -> io:format("error opening ~p (?) ~p\n",[Filename,E])
    end.

% parse
% returns either
%  eof  
%  { ok, Term, ContinuationData }
%  { error, <reason> }

parse(F) ->
    parse_file(<<>>, <<>>, F).

parse(F, PartialData) ->
    parse_file(<<>>, PartialData, F).

% simple helper to collect entire file as list
read_file_as_list(Filename) ->
    F = open_file(Filename),
    slurp(F, <<>>, []).

slurp(F, PartialData, Acc) -> 
    Next = parse(F, PartialData),
    case Next of
	eof -> lists:reverse(Acc);
	{ ok, Term, Continuation } -> slurp(F, Continuation, [Term|Acc]);
	Other -> Other
    end.	     

foreach(Filename, Fun) ->
    F = open_file(Filename),
    apply_to_each(F, <<>>, Fun).

apply_to_each(F, PartialData, Fun) -> 
    Next = parse(F, PartialData),
    case Next of
	eof -> 
	    done;
	{ ok, Term, Continuation } -> 
	    Fun(Term),
	    apply_to_each(F, Continuation, Fun);
	Other -> 
	    Other
    end.	     

%-----------------------
% internals

parse_file(<<>>, <<>>, F) ->
    Read = file:read(F, ?BUFFER_READ_SIZE),
    case Read of
	{ok, Data} -> parse_file(<<>>, Data, F);
	eof ->        eof
    end;

parse_file(<<>>, Data, F) ->
    Result = parse_binary(Data),
    case Result of
	{ ok, Term, Data2 } -> { ok, Term, Data2 };
	{ partial, Binary } -> parse_file(Binary, <<>>, F)
    end;

parse_file(PartialData, <<>>, F) ->
    Read = file:read(F, ?BUFFER_READ_SIZE),
    case Read of
	{ok, Data} -> parse_file(<<>>, <<PartialData/binary, Data/binary>>, F);
	eof ->        { error, file_ended_with_partial_binary, PartialData }
    end.

	     
parse_binary(Binary) ->
    Result = start_seperator(Binary),
    {ParseResult, TermBinary, Data} = Result,
    case ParseResult of
	ok      -> { ok, binary_to_term(TermBinary), Data};
	partial -> { partial, Binary };
	_       -> Result
    end.


start_seperator(<<>>) ->
    init:stop();

start_seperator(<<131>>) ->	     
    { partial, nil, <<131>> };

start_seperator(<<131, Tag, Data/binary>>) ->
    Parsed = start_term(Tag, Data),
    { Result, Term, Data2 } = Parsed,
    case Result of 
	ok      -> { ok, <<131, Term/binary>>, Data2 };
	partial -> { partial, nil, nil };
	_       -> Parsed
    end;

start_seperator(<<First, Rest/binary>>) ->
    io:format("ERR: expected start of new term, got ~w, try resync\n",[First]),
    parse(Rest).


start_term(97,Data) -> parse_small_integer(Data);
start_term(98,Data) -> parse_integer(Data);
start_term(100,Data) -> parse_atom(Data);
start_term(104,Data) -> parse_small_tuple(Data);
start_term(106,Data) -> {ok, <<106>>, Data}; % empty list
start_term(107,Data) -> parse_string(Data);
start_term(108,Data) -> parse_list(Data);
start_term(110,Data) -> parse_small_big(Data);
start_term(111,Data) -> parse_large_big(Data);
start_term(Tag, Data) -> { error, {unknown_type, Tag}, Data}.


parse_small_integer(<<IntVal, Data/binary>>) ->
    { ok, <<97,IntVal>>, Data};

parse_small_integer(_Data) ->
    { partial, nil, nil }.


parse_integer(<<Length:4/binary, Data/binary>>) ->
    { ok, <<98,Length/binary>>, Data };

parse_integer(_Data) ->
    { partial, nil, nil }.


parse_atom(<<0, Len, Data/binary>>) ->
    % spec implies (and tests show) first byte of atom length is always 0 ??
    AccSeed = <<100,0,Len>>, % first bytes of atom
    accum_binary(Len, Data, AccSeed);

parse_atom(_Data) ->
    { partial, nil, nil }.


parse_small_tuple(<<Arity, Data/binary>>) ->
    Parsed = parse_elements(Arity, Data, [<<Arity>>]),
    {Result, Elements, Data2 } = Parsed,
    case Result of 
	ok      -> { ok, <<104, Elements/binary>>, Data2 };
	partial -> { partial, nil, nil };
	_       -> Parsed
    end;

parse_small_tuple(_Data) ->
    { partial, nil, nil }.

parse_string(<<0, Len, Data/binary>>) ->
    AccSeed = <<107,0,Len>>,
    accum_binary(Len, Data, AccSeed);

parse_string(_Data) ->
    { partial, nil, nil }.


parse_list(<<LengthBinary:4/binary, Data/binary>>) ->
    Len = parse_4_byte_size(LengthBinary), %L1 * (256*256*256) + L2 * (256*256) + L3 * 256 + L4,
    Parsed = parse_elements(Len, Data, [<<LengthBinary/binary>>]),
    {Result, Elements, Data2 } = Parsed,
    case Result of
	ok ->
	    case Data2 of 
		<< 106, Data3/binary >> ->
		    { ok, <<108, Elements/binary, 106>>, Data3 };
		_ ->
		    { partial, nil, nil }
	    end;
	partial ->
	    { partial, nil, nil };
	_ ->
	    Parsed
    end;

parse_list(_Data) ->
    { partial, nil, nil }.

parse_small_big(<<Len, Sign, Data/binary>>) ->
    AccSeed = <<110,Len,Sign>>,
    accum_binary(Len, Data, AccSeed);

parse_small_big(_Data) ->
    { partial, nil, nil }.


parse_large_big(<<Len:4/binary, Sign, Data/binary>>) ->
    AccSeed = <<111, Len/binary, Sign>>,
    accum_binary(Len, Data, AccSeed);

parse_large_big(_Data) ->
    { partial, nil, nil }.


accum_binary(N, Data, Acc) ->
    case size(Data) < N of
	true  -> 
	    { partial, nil, nil };
	false -> 
	    <<Match:N/binary, Data2/binary>> = Data,
	    { ok, <<Acc/binary, Match/binary>>, Data2 }
    end.

parse_elements(0, Data, Acc) ->
    { ok, list_to_binary(lists:reverse(Acc)), Data };

parse_elements(_N, <<>>, _Acc) ->
    { partial, nil, nil };

parse_elements(N, <<Tag, Data/binary>>, Acc) ->
    Parsed = start_term(Tag, Data),
    { Result, ElementData, Data2 } = Parsed,
     case Result of 
	ok      -> parse_elements(N-1, Data2, [ElementData|Acc]);
	partial -> { partial, nil, nil };
	_       -> Parsed
    end.
		   
parse_4_byte_size(<<L1,L2,L3,L4>>) ->    
    L1 * (256*256*256) + L2 * (256*256) + L3 * 256 + L4.
