%% @author Marc Worrell <marc@worrell.nl>
%% @copyright 2009-2014  Marc Worrell
%% @doc Request context for Zotonic request evaluation.

%% Copyright 2009-2014 Marc Worrell
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

-module(z_context).
-author("Marc Worrell <marc@worrell.nl>").

-export([
    new/1,
    new/2,

    new_tests/0,

    site/1,
    hostname/1,
    hostname_port/1,
    site_protocol/1,

    db_pool/1,
    db_driver/1,

    is_request/1,

    prune_for_spawn/1,
    prune_for_async/1,
    prune_for_template/1,
    prune_for_database/1,
    prune_for_scomp/1,
    output/2,

    abs_url/2,

    pickle/1,
    depickle/1,

    combine_results/2,

    has_session/1,
    has_session_page/1,

    ensure_all/1,
    ensure_session/1,
    ensure_qs/1,

    continue_all/1,
    continue_session/1,

    get_reqdata/1,
    set_reqdata/2,
    get_controller_module/1,
    set_controller_module/2,

    set_q/3,
    get_q/2,
    get_q/3,
    get_q_all/1,
    get_q_all/2,
    get_q_all_noz/1,
    get_q_validated/2,

    add_script_session/1,
    add_script_page/1,
    add_script_session/2,
    add_script_page/2,

    spawn_link_session/4,
    spawn_link_page/4,

    lager_md/1,
    lager_md/2,

    get_value/2,

    set_session/3,
    get_session/2,
    get_session/3,
    incr_session/3,

    set_page/3,
    get_page/2,
    incr_page/3,

    persistent_id/1,
    set_persistent/3,
    get_persistent/2,

    set/3,
    set/2,
    get/2,
    get/3,
    incr/3,
    get_all/1,

    language/1,
    fallback_language/1,
    set_language/2,

    tz/1,
    tz_config/1,
    set_tz/2,

    merge_scripts/2,
    copy_scripts/2,
    clean_scripts/1,

    set_resp_header/3,
    get_resp_header/2,
    get_req_header/2,

    get_req_path/1,

    set_nocache_headers/1,
    set_noindex_header/1,
    set_noindex_header/2,

    set_cookie/3,
    set_cookie/4,
    get_cookie/2,
    get_cookies/2,

    cookie_domain/1,
    websockethost/1,
    has_websockethost/1
]).

-include_lib("zotonic.hrl").

%% @doc Return a new empty context, no request is initialized.
-spec new( #context{} | atom() | cowboy_req:req() ) -> #context{}.
new(#context{} = C) ->
    #context{
        site=C#context.site,
        language=C#context.language,
        tz=C#context.tz,
        depcache=C#context.depcache,
        notifier=C#context.notifier,
        session_manager=C#context.session_manager,
        dispatcher=C#context.dispatcher,
        template_server=C#context.template_server,
        scomp_server=C#context.scomp_server,
        dropbox_server=C#context.dropbox_server,
        pivot_server=C#context.pivot_server,
        module_indexer=C#context.module_indexer,
        db=C#context.db,
        translation_table=C#context.translation_table
    };
new(undefined) ->
    case z_sites_dispatcher:get_fallback_site() of
        undefined -> throw({error, no_site_enabled});
        Site -> new(Site)
    end;
new(Site) when is_atom(Site) ->
    set_default_language_tz(
        set_server_names(#context{site=Site}));
new(Req) when is_map(Req) ->
    %% This is the requesting thread, enable simple memo functionality.
    z_memo:enable(),
    z_depcache:in_process(true),
    Context = set_server_names(#context{req=Req, site=site(Req)}),
    set_dispatch_from_path(set_default_language_tz(Context)).

%% @doc Create a new context record for a site with a certain language
-spec new( atom() | cowboy_req:req(), atom() ) -> #context{}.
new(Site, Lang) when is_atom(Site), is_atom(Lang) ->
    Context = set_server_names(#context{site=Site}),
    Context#context{
        language=[Lang],
        tz=tz_config(Context)
    };
%% @doc Create a new context record for the current request and resource module
new(Req, Module) when is_map(Req) ->
    Context = new(Req),
    Context#context{controller_module=Module}.


set_default_language_tz(Context) ->
    F = fun() -> {z_language:default_language(Context), tz_config(Context)} end,
    {DefaultLang, TzConfig} = z_depcache:memo(F, default_language_tz, ?DAY, [config], Context),
    Context#context{
        language= [DefaultLang],
        tz= TzConfig
    }.

% @doc Create a new context used when testing parts of zotonic
new_tests() ->
    Context = z_trans_server:set_context_table(
            #context{
                site=test,
                language=[en],
                tz= <<"UTC">>,
                notifier='z_notifier$test'
            }),
    case ets:info(Context#context.translation_table) of
        undefined ->
            ets:new(Context#context.translation_table,
                    [named_table, set, protected,  {read_concurrency, true}]);
        _TabInfo ->
            ok
    end,
    Context.


%% @doc Set the dispatch rule for this request to the context var 'zotonic_dispatch'
set_dispatch_from_path(Context) ->
    Bindings = cowmachine_req:path_info(Context),
    case lists:keyfind(zotonic_dispatch, 1, Bindings) of
        {zotonic_dispatch, Dispatch} -> set(zotonic_dispatch, Dispatch, Context);
        false -> Context
    end.

%% @doc Set all server names for the given site.
-spec set_server_names(#context{}) -> #context{}.
set_server_names(#context{site=Site} = Context) ->
    SiteAsList = [$$ | atom_to_list(Site)],
    Depcache = list_to_atom("z_depcache"++SiteAsList),
    Context#context{
        depcache=Depcache,
        notifier=list_to_atom("z_notifier"++SiteAsList),
        session_manager=list_to_atom("z_session_manager"++SiteAsList),
        dispatcher=list_to_atom("z_dispatcher"++SiteAsList),
        template_server=list_to_atom("z_template"++SiteAsList),
        scomp_server=list_to_atom("z_scomp"++SiteAsList),
        dropbox_server=list_to_atom("z_dropbox"++SiteAsList),
        pivot_server=list_to_atom("z_pivot_rsc"++SiteAsList),
        module_indexer=list_to_atom("z_module_indexer"++SiteAsList),
        db={z_db_pool:db_pool_name(Site), z_db_pool:db_driver(Context#context{depcache=Depcache})},
        translation_table=z_trans_server:table(Site)
    }.


%% @doc Maps the site in the request to a site in the sites folder.
-spec site(#context{}|cowboy_req:req()) -> atom().
site(#context{site=Site}) ->
    Site;
site(Req) when is_map(Req) ->
    case maps:get(cowmachine_site, Req, undefined) of
        undefined -> z_sites_dispatcher:get_fallback_site();
        Site when is_atom(Site) -> Site
    end.


%% @doc Return the preferred hostname from the site configuration
-spec hostname(#context{}) -> binary().
hostname(Context) ->
    case z_dispatcher:hostname(Context) of
        Empty when Empty == undefined; Empty == <<>> ->
            <<"localhost">>;
        Hostname ->
            Hostname
    end.

%% @doc Return the preferred hostname, including port, from the site configuration
-spec hostname_port(#context{}) -> binary().
hostname_port(Context) ->
    case z_dispatcher:hostname_port(Context) of
        Empty when Empty =:= undefined; Empty =:= <<>> ->
            <<"localhost">>;
        Hostname ->
            Hostname
    end.


%% @doc Check if the current context is a request context
is_request(#context{req=undefined}) -> false;
is_request(_Context) -> true.


%% @doc Minimal prune, for ensuring that the context can safely used in two processes
prune_for_spawn(#context{} = Context) ->
    Context#context{
        dbc=undefined
    }.

%% @doc Make the context safe to use in a async message. This removes buffers and the db transaction.
prune_for_async(#context{} = Context) ->
    #context{
        req=Context#context.req,
        site=Context#context.site,
        user_id=Context#context.user_id,
        session_pid=Context#context.session_pid,
        page_pid=Context#context.page_pid,
        acl=Context#context.acl,
        props=Context#context.props,
        depcache=Context#context.depcache,
        notifier=Context#context.notifier,
        session_manager=Context#context.session_manager,
        dispatcher=Context#context.dispatcher,
        template_server=Context#context.template_server,
        scomp_server=Context#context.scomp_server,
        dropbox_server=Context#context.dropbox_server,
        pivot_server=Context#context.pivot_server,
        module_indexer=Context#context.module_indexer,
        db=Context#context.db,
        translation_table=Context#context.translation_table,
        language=Context#context.language,
        tz=Context#context.tz
    }.


%% @doc Cleanup a context for the output stream
prune_for_template(#context{}=Context) ->
    #context{
        req=undefined,
        props=undefined,
        updates=Context#context.updates,
        actions=Context#context.actions,
        content_scripts=Context#context.content_scripts,
        scripts=Context#context.scripts,
        wire=Context#context.wire,
        validators=Context#context.validators,
        render=Context#context.render
    };
prune_for_template(Output) -> Output.


%% @doc Cleanup a context so that it can be used exclusively for database connections
prune_for_database(Context) ->
    #context{
        site=Context#context.site,
        dbc=Context#context.dbc,
        depcache=Context#context.depcache,
        notifier=Context#context.notifier,
        session_manager=Context#context.session_manager,
        dispatcher=Context#context.dispatcher,
        template_server=Context#context.template_server,
        scomp_server=Context#context.scomp_server,
        dropbox_server=Context#context.dropbox_server,
        pivot_server=Context#context.pivot_server,
        module_indexer=Context#context.module_indexer,
        db=Context#context.db
    }.


%% @doc Cleanup a context for cacheable scomp handling.  Resets most of the accumulators to prevent duplicating
%% between different (cached) renderings.
prune_for_scomp(Context) ->
    Context#context{
        dbc=undefined,
        req=prune_reqdata(Context#context.req),
        updates=[],
        actions=[],
        content_scripts=[],
        scripts=[],
        wire=[],
        validators=[],
        render=[]
    }.

prune_reqdata(undefined) ->
    undefined;
prune_reqdata(Req) ->
    %% @todo: prune this better, also used by the websocket connection.
    Req#{
        bindings => [],
        cowmachine_cookies => [],
        cowmachine_resp_body => <<>>,
        headers => #{},
        path => <<>>,
        qs => <<>>,
        pid => undefined,
        streamid => undefined
    }.
    % #wm_reqdata{
    %     socket=ReqData#wm_reqdata.socket,
    %     peer=ReqData#wm_reqdata.peer,
    %     resp_headers=mochiweb_headers:empty(),
    %     req_cookie=[],
    %     req_headers=[]
    % }.

%% @doc Make the url an absolute url by prepending the hostname.
%% @spec abs_url(iolist(), Context) -> binary()
abs_url(<<"http:", _/binary>> = Url, _Context) ->
    Url;
abs_url(<<"https", _/binary>> = Url, _Context) ->
    Url;
abs_url(<<"//", _/binary>> = Url, Context) ->
    <<(site_protocol(Context))/binary, $:, Url/binary>>;
abs_url(Url, Context) when is_list(Url) ->
    abs_url(iolist_to_binary(Url), Context);
abs_url(Url, Context) ->
    case has_url_protocol(Url) of
        true ->
            Url;
        false ->
            case z_notifier:first(#url_abs{url=Url}, Context) of
                undefined ->
                    z_convert:to_binary([site_protocol(Context), "://", hostname_port(Context), Url]);
                AbsUrl ->
                    AbsUrl
            end
    end.

    has_url_protocol(<<>>) ->
        false;
    has_url_protocol(<<H, T/binary>>) when H >= $a andalso H =< $z ->
        has_url_protocol(T);
    has_url_protocol(<<$:, _/binary>>) ->
        true;
    has_url_protocol(_) ->
        false.


%% @doc Fetch the pid of the database worker pool for this site
db_pool(#context{db={Pool, _Driver}}) ->
    Pool.

%% @doc Fetch the database driver module for this site
db_driver(#context{db={_Pool, Driver}}) ->
    Driver.

%% @doc Fetch the protocol for absolute urls referring to the site (defaults to http).
%%      Useful when the site is behind a https proxy.
site_protocol(Context) ->
    case z_convert:to_binary(m_config:get_value(site, protocol, Context)) of
        <<>> -> <<"http">>;
        P -> P
    end.

%% @doc Pickle a context for storing in the database
%% @todo pickle/depickle the visitor id (when any)
%% @spec pickle(Context) -> tuple()
pickle(Context) ->
    {pickled_context,
        Context#context.site,
        Context#context.user_id,
        Context#context.language,
        Context#context.tz,
        undefined}.

%% @doc Depickle a context for restoring from a database
%% @todo pickle/depickle the visitor id (when any)
depickle({pickled_context, Site, UserId, Language, _VisitorId}) ->
    depickle({pickled_context, Site, UserId, Language, 0, _VisitorId});
depickle({pickled_context, Site, UserId, Language, Tz, _VisitorId}) ->
    Context = set_server_names(#context{site=Site, language=Language, tz=Tz}),
    case UserId of
        undefined -> Context;
        _ -> z_acl:logon(UserId, Context)
    end.

%% @spec output(list(), Context) -> {io_list(), Context}
%% @doc Replace the contexts in the output with their rendered content and collect all scripts
output(<<>>, Context) ->
    {[], Context};
output(B, Context) when is_binary(B) ->
    {B, Context};
output(List, Context) ->
    output1(List, Context, []).

%% @doc Recursively walk through the output, replacing all context placeholders with their rendered output
output1(B, Context, Acc) when is_binary(B) ->
    {[lists:reverse(Acc),B], Context};
output1([], Context, Acc) ->
    {lists:reverse(Acc), Context};
output1([#context{}=C|Rest], Context, Acc) ->
    {Rendered, Context1} = output1(C#context.render, Context, []),
    output1(Rest, merge_scripts(C, Context1), [Rendered|Acc]);
output1([{script, Args}|Rest], Context, Acc) ->
    output1(Rest, Context, [render_script(Args, Context)|Acc]);
output1([List|Rest], Context, Acc) when is_list(List) ->
    {Rendered, Context1} = output1(List, Context, []),
    output1(Rest, Context1, [Rendered|Acc]);
output1([undefined|Rest], Context, Acc) ->
    output1(Rest, Context, Acc);
output1([C|Rest], Context, Acc) when is_atom(C) ->
    output1(Rest, Context, [list_to_binary(atom_to_list(C))|Acc]);
output1([{trans, _} = Trans|Rest], Context, Acc) ->
    output1(Rest, Context, [z_trans:lookup_fallback(Trans, Context)|Acc]);
output1([{{_,_,_},{_,_,_}} = D|Rest], Context, Acc) ->
    output1([filter_date:date(D, "Y-m-d H:i:s", Context)|Rest], Context, Acc);
output1([{javascript, Script}|Rest], Context, Acc) ->
    Context1 = Context#context{
              content_scripts=combine(Context#context.content_scripts, [Script])
           },
    output1(Rest, Context1, Acc);
output1([T|Rest], Context, Acc) when is_tuple(T) ->
    output1([iolist_to_binary(io_lib:format("~p", [T]))|Rest], Context, Acc);
output1([C|Rest], Context, Acc) ->
    output1(Rest, Context, [C|Acc]).

render_script(Args, Context) ->
    NoStartup = z_convert:to_bool(z_utils:get_value(nostartup, Args, false)),
    NoStream = z_convert:to_bool(z_utils:get_value(nostream, Args, false)),
    Extra = [ S || S <- z_notifier:map(#scomp_script_render{is_nostartup=NoStartup, args=Args}, Context), S /= undefined ],
    Script = case NoStartup of
        false ->
            [ z_script:get_page_startup_script(Context),
              Extra,
              z_script:get_script(Context),
              case NoStream of
                  false ->
                      z_script:get_stream_start_script(Context);
                  true ->
                      []
              end];
        true ->
            [z_script:get_script(Context), Extra]
    end,
    case z_utils:get_value(format, Args, <<"html">>) of
        <<"html">> ->
            [ <<"\n\n<script type='text/javascript'>\n$(function() {\n">>, Script, <<"\n});\n</script>\n">> ];
        <<"js">> ->
            [ $\n, Script, $\n ];
        <<"escapejs">> ->
            z_utils:js_escape(Script)
    end.


%% @spec combine_results(Context1, Context2) -> Context
%% @doc Merge the scripts and the rendered content of two contexts into Context1
combine_results(C1, C2) ->
    Merged = merge_scripts(C2, C1),
    Merged#context{
        render=combine(C1#context.render, C2#context.render)
    }.

%% @spec merge_scripts(Context, ContextAcc) -> Context
%% @doc Merge the scripts from context C into the context accumulator, used when collecting all scripts in an output stream
merge_scripts(C, Acc) ->
    Acc#context{
        updates=combine(Acc#context.updates, C#context.updates),
        actions=combine(Acc#context.actions, C#context.actions),
        content_scripts=combine(Acc#context.content_scripts, C#context.content_scripts),
        scripts=combine(Acc#context.scripts, C#context.scripts),
        wire=combine(Acc#context.wire, C#context.wire),
        validators=combine(Acc#context.validators, C#context.validators)
    }.

combine([],X) -> X;
combine(X,[]) -> X;
combine(X,Y) -> [X,Y].

%% @doc Remove all scripts from the context
%% @spec clean_scripts(Context) -> Context
clean_scripts(C) ->
    z_script:clean(C).


%% @doc Overwrite the scripts in Context with the scripts in From
%% @spec copy_scripts(From, Context) -> Context
copy_scripts(From, Context) ->
    Context#context{
        updates=From#context.updates,
        actions=From#context.actions,
        content_scripts=From#context.content_scripts,
        scripts=From#context.scripts,
        wire=From#context.wire,
        validators=From#context.validators
    }.


%% @doc Continue an existing session, if the session id is in the request.
continue_session(Context) ->
    case z_session_manager:continue_session(Context) of
        {ok, #context{session_pid=Pid} = Context1} when is_pid(Pid) ->
            maybe_logon_from_session(Context1);
        {ok, Context1} ->
            Context1;
        {error, _} ->
            Context
    end.


%% @doc Check if the current context has a session page attached
has_session_page(#context{page_pid=PagePid}) when is_pid(PagePid) ->
    true;
has_session_page(_) ->
    false.

%% @doc Check if the current context has a session attached
has_session(#context{session_pid=SessionPid}) when is_pid(SessionPid) ->
    true;
has_session(_) ->
    false.


%% @doc Ensure session and page session. Fetches and parses the query string.
ensure_all(Context) ->
    case get(no_session, Context, false) of
        false -> ensure_page_session(ensure_session(ensure_qs(Context)));
        true -> continue_all(Context)
    end.

continue_all(Context) ->
    ensure_page_session(continue_session(ensure_qs(Context))).


%% @doc Ensure that we have a session, start a new session process when needed
ensure_session(#context{session_pid=undefined}=Context) ->
    {ok, Context1} = z_session_manager:ensure_session(Context),
    maybe_logon_from_session(Context1);
ensure_session(Context) ->
    Context.


%% @doc After ensuring a session, try to log on from the user-id stored in the session
maybe_logon_from_session(#context{user_id=undefined} = Context) ->
    Context1 = z_auth:logon_from_session(Context),
    Context2 = z_notifier:foldl(#session_context{}, Context1, Context1),
    set_nocache_headers(Context2);
maybe_logon_from_session(Context) ->
    Context.

%% @doc Ensure that we have a page session process for this request.
ensure_page_session(#context{session_pid=undefined} = Context) ->
    Context;

ensure_page_session(Context) ->
    z_session:ensure_page_session(Context).


%% @doc Ensure that we have parsed the query string, fetch body if necessary.
%%      If this is a POST then the session/page-session might be continued after this call.
ensure_qs(Context) ->
    case proplists:lookup('q', Context#context.props) of
        {'q', _Qs} ->
            Context;
        none ->
            Query = cowmachine_req:req_qs(Context),
            PathInfo = cowmachine_req:path_info(Context),
            PathArgs = [ {z_convert:to_binary(T), V} || {T,V} <- PathInfo ],
            QPropsUrl = z_utils:prop_replace('q', PathArgs++Query, Context#context.props),
            {Body, ContextParsed} = parse_post_body(Context#context{props=QPropsUrl}),
            QPropsAll = z_utils:prop_replace('q', PathArgs++Body++Query, ContextParsed#context.props),
            ContextQs = ContextParsed#context{props=QPropsAll},
            z_notifier:foldl(#request_context{}, ContextQs, ContextQs)
    end.


%% @doc Return the webmachine request data of the context
-spec get_reqdata(#context{}) -> cowboy_req:req() | undefined.
get_reqdata(Context) ->
    Context#context.req.

%% @doc Set the webmachine request data of the context
-spec set_reqdata(cowboy_req:req() | undefined, #context{}) -> #context{}.
set_reqdata(Req, Context) when is_map(Req); Req =:= undefined ->
    Context#context{req=Req}.


%% @doc Get the resource module handling the request.
-spec get_controller_module(#context{}) -> atom() | undefined.
get_controller_module(Context) ->
    Context#context.controller_module.

-spec set_controller_module(Module::atom(), #context{}) -> #context{}.
set_controller_module(Module, Context) ->
    Context#context{controller_module=Module}.


%% @doc Set the value of a request parameter argument
-spec set_q(string(), any(), #context{}) -> #context{}.
set_q(Key, Value, Context) ->
    Qs = get_q_all(Context),
    Qs1 = proplists:delete(Key, Qs),
    z_context:set('q', [{Key,Value}|Qs1], Context).


%% @doc Get a request parameter, either from the query string or the post body.  Post body has precedence over the query string.
-spec get_q(string()|atom()|binary()|list(), #context{}) -> binary() | string() | #upload{} | undefined | list().
get_q([Key|_] = Keys, Context) when is_list(Key); is_atom(Key); is_binary(Key) ->
    lists:foldl(fun(K, Acc) ->
                    case get_q(K, Context) of
                        undefined -> Acc;
                        Value -> [{K, Value}|Acc]
                    end
                end,
                [],
                Keys);
get_q(Key, Context) when is_list(Key) ->
    case get_q(list_to_binary(Key), Context) of
        Value when is_binary(Value) -> binary_to_list(Value);
        Value -> Value
    end;
get_q(Key, Context) ->
    case proplists:lookup('q', Context#context.props) of
        {'q', Qs} -> proplists:get_value(z_convert:to_binary(Key), Qs);
        none -> undefined
    end.


%% @doc Get a request parameter, either from the query string or the post body.  Post body has precedence over the query string.
-spec get_q(binary()|string()|atom(), #context{}, term()) -> binary() | string() | #upload{} | term().
get_q(Key, Context, Default) when is_list(Key) ->
    case get_q(list_to_binary(Key), Context, Default) of
        Value when is_binary(Value) -> binary_to_list(Value);
        Value -> Value
    end;
get_q(Key, Context, Default) ->
    case proplists:lookup('q', Context#context.props) of
        {'q', Qs} -> proplists:get_value(z_convert:to_binary(Key), Qs, Default);
        none -> Default
    end.


%% @doc Get all parameters.
-spec get_q_all(#context{}) -> list({binary(), binary()|#upload{}}).
get_q_all(Context) ->
    case proplists:lookup('q', Context#context.props) of
        {'q', Qs} -> Qs;
        none -> []
    end.


%% @doc Get the all the parameters with the same name, returns the empty list when non found.
-spec get_q_all(string()|atom()|binary(), #context{}) -> list().
get_q_all(Key, Context) when is_list(Key) ->
    Values = get_q_all(z_convert:to_binary(Key), Context),
    [
        case is_binary(V) of
            true -> binary_to_list(V);
            false -> V
        end
        || V <- Values
    ];
get_q_all(Key, Context) ->
    case proplists:lookup('q', Context#context.props) of
        none -> [];
        {'q', Qs} -> proplists:get_all_values(z_convert:to_binary(Key), Qs)
    end.


%% @doc Get all query/post args, filter the zotonic internal args.
-spec get_q_all_noz(#context{}) -> list({string(), term()}).
get_q_all_noz(Context) ->
    lists:filter(fun({X,_}) -> not is_zotonic_arg(X) end, z_context:get_q_all(Context)).

is_zotonic_arg(<<"zotonic_host">>) -> true;  % backwards compatibility
is_zotonic_arg(<<"zotonic_site">>) -> true;
is_zotonic_arg(<<"zotonic_dispatch">>) -> true;
is_zotonic_arg(<<"zotonic_dispatch_path">>) -> true;
is_zotonic_arg(<<"zotonic_dispatch_path_rewrite">>) -> true;
is_zotonic_arg(<<"postback">>) -> true;
is_zotonic_arg(<<"triggervalue">>) -> true;
is_zotonic_arg(<<"z_trigger_id">>) -> true;
is_zotonic_arg(<<"z_target_id">>) -> true;
is_zotonic_arg(<<"z_delegate">>) -> true;
is_zotonic_arg(<<"z_sid">>) -> true;
is_zotonic_arg(<<"z_pageid">>) -> true;
is_zotonic_arg(<<"z_v">>) -> true;
is_zotonic_arg(<<"z_msg">>) -> true;
is_zotonic_arg(<<"z_comet">>) -> true;
is_zotonic_arg(_) -> false.


%% @doc Fetch a query parameter and perform the validation connected to the parameter. An exception {not_validated, Key}
%%      is thrown when there was no validator, when the validator is invalid or when the validation failed.
-spec get_q_validated(string()|atom()|binary(), #context{}) -> string() | term() | undefined.
get_q_validated([Key|_] = Keys, Context) when is_list(Key); is_atom(Key) ->
    lists:foldl(fun (K, Acc) ->
                    case get_q_validated(K, Context) of
                        undefined -> Acc;
                        Value -> [{K, Value}|Acc]
                    end
                end,
                [],
                Keys);
get_q_validated(Key, Context) when is_list(Key) ->
    case get_q_validated(list_to_binary(Key), Context) of
        V when is_binary(V) -> binary_to_list(V);
        V -> V
    end;
get_q_validated(Key, Context) ->
    case proplists:lookup('q_validated', Context#context.props) of
        {'q_validated', Qs} ->
            case proplists:lookup(z_convert:to_binary(Key), Qs) of
                {_Key, Value} -> Value;
                none -> throw({not_validated, Key})
            end
    end.


%% ------------------------------------------------------------------------------------
%% Communicate with pages, session and user processes
%% ------------------------------------------------------------------------------------

%% @doc Add the script from the context to all pages of the session.
add_script_session(Context) ->
    Script = z_script:get_script(Context),
    add_script_session(Script, Context).


%% @doc Add the script from the context to the page in the user agent.
add_script_page(Context) ->
    Script = z_script:get_script(Context),
    add_script_page(Script, Context).


%% @doc Add a script to the all pages of the session. Used for comet feeds.
add_script_session(Script, Context) ->
    z_session:add_script(Script, Context#context.session_pid).


%% @doc Add a script to the page in the user agent.  Used for comet feeds.
add_script_page(Script, Context) ->
    z_session_page:add_script(Script, Context#context.page_pid).


%% @doc Spawn a new process, link it to the session process.
spawn_link_session(Module, Func, Args, Context) ->
    z_session:spawn_link(Module, Func, Args, Context).

%% @doc Spawn a new process, link it to the page process.  Used for comet feeds.
spawn_link_page(Module, Func, Args, Context) ->
    z_session_page:spawn_link(Module, Func, Args, Context).


%% ------------------------------------------------------------------------------------
%% Set lager metadata for the current process
%% ------------------------------------------------------------------------------------

lager_md(ContextOrReq) ->
    lager_md([], ContextOrReq).

lager_md(MD, #context{} = Context) when is_list(MD) ->
    RD = get_reqdata(Context),
    lager:md([
            {site, site(Context)},
            {user_id, Context#context.user_id},
            {controller, Context#context.controller_module},
            {dispatch, get(zotonic_dispatch, Context)},
            {method, m_req:get(method, RD)},
            {remote_ip, m_req:get(peer, RD)},
            {is_ssl, m_req:get(is_ssl, RD)},
            {session_id, Context#context.session_id},
            {page_id, Context#context.page_id},
            {req_id, m_req:get(req_id, RD)}
            | MD
        ]);
lager_md(MD, Req) when is_map(Req) ->
    PathInfo = cowmachine_req:path_info(Req),
    lager:md([
            {site, z_context:site(Req)},
            {dispatch, proplists:get_value(zotonic_dispatch, PathInfo)},
            {method, m_req:get(method, Req)},
            {remote_ip, m_req:get(peer, Req)},
            {is_ssl, m_req:get(is_ssl, Req)},
            {req_id, m_req:get(req_id, Req)}
            | MD
        ]).

%% ------------------------------------------------------------------------------------
%% Set/get/modify state properties
%% ------------------------------------------------------------------------------------


%% @spec get_value(Key::string(), Context) -> Value | undefined
%% @doc Find a key in the context, page, session or persistent state.
%% @todo Add page and user lookup
get_value(Key, Context) ->
    case get(Key, Context) of
        undefined ->
            case get_page(Key, Context) of
                undefined ->
                    case get_session(Key, Context) of
                        undefined -> get_persistent(Key, Context);
                        Value -> Value
                    end;
                Value ->
                    Value
            end;
        Value ->
            Value
    end.


%% @doc Ensure that we have an id for the visitor
persistent_id(Context) ->
    z_session:persistent_id(Context).

%% @spec set_persistent(Key, Value, Context) -> Context
%% @doc Set the value of the visitor variable Key to Value
set_persistent(Key, Value, Context) ->
    z_session:set_persistent(Key, Value, Context).


%% @spec get_persistent(Key, Context) -> Value
%% @doc Fetch the value of the visitor variable Key
get_persistent(_Key, #context{session_pid=undefined}) ->
    undefined;
get_persistent(Key, Context) ->
    z_session:get_persistent(Key, Context).


%% @spec set_session(Key, Value, Context) -> Context
%% @doc Set the value of the session variable Key to Value
set_session(Key, Value, Context) ->
    z_session:set(Key, Value, Context#context.session_pid),
    Context.

%% @spec get_session(Key, Context) -> Value
%% @doc Fetch the value of the session variable Key
get_session(_Key, #context{session_pid=undefined}) ->
    undefined;
get_session(Key, Context) ->
    z_session:get(Key, Context#context.session_pid).

%% @spec get_session(Key, Context, DefaultValue) -> Value
%% @doc Fetch the value of the session variable Key, falling back to default.
get_session(_Key, #context{session_pid=undefined}, DefaultValue) ->
    DefaultValue;
get_session(Key, Context, DefaultValue) ->
    z_session:get(Key, Context#context.session_pid, DefaultValue).

%% @spec incr_session(Key, Increment, Context) -> {NewValue, NewContext}
%% @doc Increment the session variable Key
incr_session(Key, Value, Context) ->
    {z_session:incr(Key, Value, Context#context.session_pid), Context}.

%% @spec set_page(Key, Value, Context) -> Context
%% @doc Set the value of the page variable Key to Value
set_page(Key, Value, Context) ->
    z_session_page:set(Key, Value, Context#context.page_pid),
    Context.

%% @spec get_page(Key, Context) -> Value
%% @doc Fetch the value of the page variable Key
get_page(_Key, #context{page_pid=undefined}) ->
    undefined;
get_page(Key, Context) ->
    z_session_page:get(Key, Context#context.page_pid).


%% @spec incr_page(Key, Increment, Context) -> {NewValue, NewContext}
%% @doc Increment the page variable Key
incr_page(Key, Value, Context) ->
    {z_session_page:incr(Key, Value, Context#context.session_pid), Context}.


%% @spec set(Key, Value, Context) -> Context
%% @doc Set the value of the context variable Key to Value
set(Key, Value, Context) ->
    Props = z_utils:prop_replace(Key, Value, Context#context.props),
    Context#context{props = Props}.


%% @spec set(PropList, Context) -> Context
%% @doc Set the value of the context variables to all {Key, Value} properties.
set(PropList, Context) when is_list(PropList) ->
    NewProps = lists:foldl(
        fun ({Key,Value}, Props) ->
            z_utils:prop_replace(Key, Value, Props)
        end, Context#context.props, PropList),
    Context#context{props = NewProps}.


%% @spec get(Key, Context) -> Value | undefined
%% @doc Fetch the value of the context variable Key, return undefined when Key is not found.
get(Key, Context) ->
    case proplists:lookup(Key, Context#context.props) of
        {Key, Value} -> Value;
        none -> undefined
    end.

%% @spec get(Key, Context, Default) -> Value | Default
%% @doc Fetch the value of the context variable Key, return Default when Key is not found.
get(Key, Context, Default) ->
    case proplists:lookup(Key, Context#context.props) of
        {Key, Value} -> Value;
        none -> Default
    end.


%% @spec get_all(Context) -> PropList
%% @doc Return a proplist with all context variables.
get_all(Context) ->
    Context#context.props.


%% @spec incr(Key, Increment, Context) -> {NewValue,NewContext}
%% @doc Increment the context variable Key
incr(Key, Value, Context) ->
    R = case z_convert:to_integer(get(Key, Context)) of
	    undefined -> Value;
	    N -> N + Value
	end,
    {R, set(Key, R, Context)}.

%% @doc Return the selected language of the Context
-spec language(#context{}) -> atom().
language(Context) ->
    % A check on atom must exist because the language setting may be stored in mnesia and
    % passed to the context when the site starts
    case Context#context.language of
        [Language|_] -> Language;
        Language -> Language
    end.

%% @doc Return the first fallback language of the Context
-spec fallback_language(#context{}) -> atom().
fallback_language(Context) ->
    % Take the second item of the list, if it exists
    case Context#context.language of
        [_|[Fallback|_]] -> Fallback;
        _ -> undefined
    end.

%% @doc Set the language of the context, either an atom (language) or a list (language and fallback languages)
-spec set_language(atom()|binary()|string()|list(), #context{}) -> #context{}.
set_language(Lang, Context) when is_atom(Lang) ->
    Context#context{language=[Lang]};
set_language(Langs, Context) when is_list(Langs) ->
    Context#context{language=Langs};
set_language(Lang, Context) ->
    case z_language:is_valid(Lang) of
        true -> set_language(z_convert:to_atom(Lang), Context);
        false -> Context
    end.

%% @doc Return the selected timezone of the Context; defaults to the site's timezone
-spec tz(#context{}) -> binary().
tz(#context{tz=TZ}) when TZ =/= undefined; TZ =/= <<>> ->
    TZ;
tz(Context) ->
    tz_config(Context).

%% @doc Return the site's configured timezone.
-spec tz_config(#context{}) -> binary().
tz_config(Context) ->
    case m_config:get_value(mod_l10n, timezone, Context) of
        None when None =:= undefined; None =:= <<>> ->
            z_config:get(timezone);
        TZ ->
            TZ
    end.

%% @doc Set the timezone of the context.
-spec set_tz(string()|binary(), #context{}) -> #context{}.
set_tz(Tz, Context) when is_list(Tz) ->
    set_tz(z_convert:to_binary(Tz), Context);
set_tz(Tz, Context) when is_binary(Tz), Tz =/= <<>> ->
    Context#context{tz=z_convert:to_binary(Tz)};
set_tz(true, Context) ->
    Context#context{tz= <<"UTC">>};
set_tz(1, Context) ->
    Context#context{tz= <<"UTC">>};
set_tz(Tz, Context) ->
    lager:error("Unknown timezone ~p", [Tz]),
    Context.

%% @doc Set a response header for the request in the context.
%% @spec set_resp_header(Header, Value, Context) -> NewContext
-spec set_resp_header(binary(), binary(), #context{}) -> #context{}.
set_resp_header(Header, Value, #context{req=Req} = Context) when is_map(Req) ->
    cowmachine_req:set_resp_header(Header, Value, Context).

%% @doc Get a response header
-spec get_resp_header(binary(), #context{}) -> binary() | undefined.
get_resp_header(Header, #context{req=Req} = Context) when is_map(Req) ->
    cowmachine_req:get_resp_header(Header, Context).

%% @doc Get a request header. The header MUST be in lower case.
-spec get_req_header(binary(), #context{}) -> binary() | undefined.
get_req_header(Header, #context{req=Req} = Context) when is_map(Req) ->
    cowmachine_req:get_req_header(Header, Context).


%% @doc Return the request path
-spec get_req_path(#context{}) -> binary().
get_req_path(#context{req=Req} = Context) when is_map(Req) ->
    cowmachine_req:raw_path(Context).


%% @doc Fetch the cookie domain, defaults to 'undefined' which will equal the domain
%% to the domain of the current request.
-spec cookie_domain(#context{}) -> binary() | undefined.
cookie_domain(Context) ->
    case m_site:get(cookie_domain, Context) of
        Empty when Empty == undefined; Empty == []; Empty =:= <<>> ->
            undefined;
        Domain ->
            z_convert:to_binary(Domain)
    end.

%% @doc Fetch the domain and port for websocket connections
-spec websockethost(#context{}) -> binary().
websockethost(Context) ->
    case m_site:get(websockethost, Context) of
        Empty when Empty == undefined; Empty == []; Empty == <<>> ->
            hostname_port(Context);
        Domain ->
            Domain
    end.

%% @doc Return true iff this site has a separately configured websockethost
-spec has_websockethost(#context{}) -> boolean().
has_websockethost(Context) ->
    not z_utils:is_empty(m_site:get(websockethost, Context)).


%% ------------------------------------------------------------------------------------
%% Local helper functions
%% ------------------------------------------------------------------------------------

%% @doc Return the keys in the body of the request, only if the request is application/x-www-form-urlencoded
-spec parse_post_body(#context{}) -> {list({binary(),binary()}), #context{}}.
parse_post_body(Context) ->
    case cowmachine_req:get_req_header(<<"content-type">>, Context) of
        <<"application/x-www-form-urlencoded", _/binary>> ->
            case cowmachine_req:req_body(Context) of
                {undefined, Context1} ->
                    {[], Context1};
                {Body, Context1} ->
                    {cowmachine_util:parse_qs(Body), Context1}
            end;
        <<"multipart/form-data", _/binary>> ->
            {Form, ContextRcv} = z_parse_multipart:recv_parse(Context),
            FileArgs = [ {Name, #upload{filename=Filename, tmpfile=TmpFile}} || {Name, Filename, TmpFile} <- Form#multipart_form.files ],
            {Form#multipart_form.args ++ FileArgs, ContextRcv};
        _Other ->
            {[], Context}
    end.


%% @doc Some user agents have too aggressive client side caching.
%% These headers prevent the caching of content on the user agent iff
%% the content generated has a session. You can prevent addition of
%% these headers by not calling z_context:ensure_session/1, or
%% z_context:ensure_all/1.
-spec set_nocache_headers(#context{}) -> #context{}.
set_nocache_headers(Context = #context{req=Req}) when is_map(Req) ->
    C1 = cowmachine_req:set_resp_header(<<"cache-control">>, <<"no-store, no-cache, must-revalidate, post-check=0, pre-check=0">>, Context),
    C2 = cowmachine_req:set_resp_header(<<"expires">>, <<"Wed, 10 Dec 2008 14:30:00 GMT">>, C1),
    % This let IE accept our cookies, basically we tell IE that our cookies do not contain any private data.
    cowmachine_req:set_resp_header(<<"p3p">>, <<"CP=\"NOI ADM DEV PSAi COM NAV OUR OTRo STP IND DEM\"">>, C2).

%% @doc Set the noindex header if the config is set, or the webmachine resource opt is set.
-spec set_noindex_header(#context{}) -> #context{}.
set_noindex_header(Context) ->
    set_noindex_header(false, Context).

%% @doc Set the noindex header if the config is set, the webmachine resource opt is set or Force is set.
-spec set_noindex_header(Force::term(), #context{}) -> #context{}.
set_noindex_header(Force, Context) ->
    case z_convert:to_bool(m_config:get_value(seo, noindex, Context))
         orelse get(seo_noindex, Context, false)
         orelse z_convert:to_bool(Force)
    of
       true -> set_resp_header(<<"x-robots-tag">>, <<"noindex">>, Context);
       _ -> Context
    end.

%% @doc Set a cookie value with default options.
-spec set_cookie(binary(), binary(), #context{}) -> #context{}.
set_cookie(Key, Value, Context) ->
    set_cookie(Key, Value, [], Context).

%% @doc Set a cookie value with cookie options.
-spec set_cookie(binary(), binary(), list(), #context{}) -> #context{}.
set_cookie(Key, Value, Options, Context) ->
    case controller_websocket:is_websocket_request(Context) of
        true ->
            %% Store the cookie in the session and trigger an ajax cookie fetch.
            z_session:add_cookie(Key, Value, Options, Context),
            add_script_page(<<"z_fetch_cookies();">>, Context),
            Context;
        false ->
            % Add domain to cookie if not set
            ValueBin = z_convert:to_binary(Value),
            Options1 = case proplists:lookup(domain, Options) of
                           {domain, _} -> Options;
                           none -> [{domain, z_context:cookie_domain(Context)}|Options]
                       end,
            Options2 = z_notifier:foldl(#cookie_options{name=Key, value=ValueBin}, Options1, Context),
            cowmachine_req:set_resp_cookie(Key, ValueBin, Options2, Context)
    end.


%% @doc Read a cookie value from the current request.
-spec get_cookie(binary(), #context{}) -> binary() | undefined.
get_cookie(Key, #context{req=Req} = Context) when is_map(Req) ->
    cowmachine_req:get_cookie_value(Key, Context).

%% @doc Read all cookie values with a certain key from the current request.
-spec get_cookies(binary(), #context{}) -> [ binary() ].
get_cookies(Key, #context{req=Req} = Context) when is_map(Req), is_binary(Key) ->
    proplists:get_all_values(Key, cowmachine_req:req_cookie(Context)).
