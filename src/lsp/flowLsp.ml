(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* This gets shadowed by Lsp.Exit *)
module FlowExit = Exit
open CommandUtils
open Lsp
open Lsp_fmt
module List = Base.List

(************************************************************************)
(** Protocol orchestration & helpers                                   **)

(************************************************************************)

(* LSP exit codes are specified at https://microsoft.github.io/language-server-protocol/specification#exit *)
let lsp_exit_ok () = exit 0

let lsp_exit_bad () = exit 1

(** Given an ID that came from the server, we have to wrap it when we pass it
  on to the client, to encode which instance of the server it came from.
  That way, if a response comes back later from the client after the server
  has died, we'll know to discard it. We wrap it as "serverid:#id" for
  numeric ids, and "serverid:'id" for strings. *)
type wrapped_id = {
  server_id: int;
  message_id: lsp_id;
}

let encode_wrapped (wrapped_id : wrapped_id) : lsp_id =
  let { server_id; message_id } = wrapped_id in
  match message_id with
  | NumberId id -> StringId (Printf.sprintf "%d:#%d" server_id id)
  | StringId id -> StringId (Printf.sprintf "%d:'%s" server_id id)

let decode_wrapped (lsp : lsp_id) : wrapped_id =
  let s =
    match lsp with
    | NumberId _ -> failwith "not a wrapped id"
    | StringId s -> s
  in
  try
    Scanf.sscanf s "%d:%['#]%s" (fun server_id kind message_str ->
        let message_id =
          if kind = "#" then
            NumberId (int_of_string message_str)
          else
            StringId message_str
        in
        { server_id; message_id }
    )
  with
  | Scanf.Scan_failure _
  | Failure _
  | End_of_file ->
    failwith (Printf.sprintf "Invalid message id %s" s)

module WrappedKey = struct
  type t = wrapped_id

  let compare (x : t) (y : t) =
    if x.server_id <> y.server_id then
      IntKey.compare x.server_id y.server_id
    else
      IdKey.compare x.message_id y.message_id
end

module WrappedMap = WrappedMap.Make (WrappedKey)

type server_conn = {
  ic: Timeout.in_channel;
  oc: out_channel;
}

type show_status_t =
  | Never_shown
  | Shown of lsp_id option * ShowStatus.showStatusParams
      (** Shown (Some id, params) -- means it is currently shown
          Shown (None, params) - means it was shown but user dismissed it *)

type open_file_info = {
  o_open_doc: Lsp.TextDocumentItem.t;
      (** o_open_doc is guaranteed to be up-to-date with respect to the editor *)
  o_ast: ((Loc.t, Loc.t) Flow_ast.Program.t * Lsp.PublishDiagnostics.diagnostic list option) option;
      (** o_ast, if present, is guaranteed to be up-to-date. It gets computed lazily. *)
  o_unsaved: bool;
      (** o_unsaved if true means that this open file has unsaved changes to the buffer. *)
}

type initialized_env = {
  i_initialize_params: Lsp.Initialize.params;
  i_connect_params: connect_params;
  i_root: File_path.t;
  i_version: string option;
  i_server_id: int;
  i_can_autostart_after_version_mismatch: bool;
  i_outstanding_local_handlers: server_state lsp_handler IdMap.t;
  i_outstanding_local_requests: lsp_request IdMap.t;
  i_outstanding_requests_from_server: Lsp.lsp_request WrappedMap.t;
  i_isConnected: bool;
  i_status: show_status_t;  (** what we've told the client about our connection status *)
  i_open_files: open_file_info Lsp.UriMap.t;
  i_errors: LspErrors.t;
  i_config: Hh_json.json;
  i_flowconfig: FlowConfig.config;
}

and disconnected_env = {
  d_ienv: initialized_env;
  d_autostart: bool;
  d_server_status: (ServerStatus.status * FileWatcherStatus.status) option;
}

and connected_env = {
  c_ienv: initialized_env;
  c_conn: server_conn;
  c_server_status: ServerStatus.status * FileWatcherStatus.status option;
  c_recent_summaries: (float * LspProt.telemetry_from_server) list;  (** newest at head of list *)
  c_about_to_exit_code: FlowExit.t option;
  c_is_rechecking: bool;  (** stateful handling of Errors+status from server... *)
  c_lazy_stats: ServerProt.Response.lazy_stats option;
  c_outstanding_requests_to_server: Lsp.IdSet.t;
      (** if server gets disconnected, we will tidy up these things... *)
}

and server_state =
  | Disconnected of disconnected_env  (** we'll attempt to reconnect once a tick. *)
  | Connected of connected_env  (** we have a working connection to both server and client. *)

and state =
  | Pre_init of connect_params  (** we haven't yet received the initialize request. *)
  | Initialized of server_state  (** client has initialized, server may or may not be connected *)
  | Post_shutdown  (** we received the shutdown request. *)

exception Client_fatal_connection_exception of Marshal_tools.remote_exception_data

exception Client_recoverable_connection_exception of Marshal_tools.remote_exception_data

exception Server_fatal_connection_exception of Marshal_tools.remote_exception_data

exception Changed_file_not_open of Lsp.DocumentUri.t

type event =
  | Server_message of LspProt.message_from_server
  | Client_message of Lsp.lsp_message * LspProt.metadata
  | Tick  (** once per second, on idle *)

(** Reads the flowconfig directly from disk, and without enforcing warnings.
    We only care about connecting to the server, and will let the server
    enforce warnings.  *)
let read_flowconfig_from_disk flowconfig_name root =
  Server_files_js.config_file flowconfig_name root
  |> read_config_or_exit ~enforce_warnings:false ~allow_cache:false

let string_of_server_state (state : server_state) : string =
  match state with
  | Disconnected _ -> "Disconnected"
  | Connected _ -> "Connected"

let string_of_state (state : state) : string =
  match state with
  | Pre_init _ -> "Pre_init"
  | Initialized server_state -> string_of_server_state server_state
  | Post_shutdown -> "Post_shutdown"

let to_stdout (json : Hh_json.json) : unit =
  (* Extra \r\n purely for easier logfile reading; not required by protocol. *)
  let s = Hh_json.json_to_string json ^ "\r\n\r\n" in
  Http_lite.write_message stdout s

let get_ienv (state : server_state) : initialized_env =
  match state with
  | Connected cenv -> cenv.c_ienv
  | Disconnected denv -> denv.d_ienv

let update_ienv f state =
  match state with
  | Connected cenv -> Connected { cenv with c_ienv = f cenv.c_ienv }
  | Disconnected denv -> Disconnected { denv with d_ienv = f denv.d_ienv }

(** We keep a log of typecheck summaries over the past 2mins. *)
let update_recent_summaries cenv summary =
  let new_time = Unix.gettimeofday () in
  let c_recent_summaries =
    (new_time, summary) :: cenv.c_recent_summaries
    |> List.filter ~f:(fun (t, _) -> t >= new_time -. 120.0)
  in
  { cenv with c_recent_summaries }

let log_of_summaries ~(root : File_path.t) (summaries : LspProt.telemetry_from_server list) :
    FlowEventLogger.persistent_delay =
  FlowEventLogger.(
    let init =
      {
        init_duration = 0.0;
        command_count = 0;
        command_duration = 0.0;
        command_worst = None;
        command_worst_duration = None;
        recheck_count = 0;
        recheck_dependent_files = 0;
        recheck_changed_files = 0;
        recheck_duration = 0.0;
        recheck_worst_duration = None;
        recheck_worst_dependent_file_count = None;
        recheck_worst_changed_file_count = None;
        recheck_worst_cycle_leader = None;
        recheck_worst_cycle_size = None;
      }
    in
    let f acc event =
      match event with
      | LspProt.Init_summary { duration } ->
        let acc = { acc with init_duration = acc.init_duration +. duration } in
        acc
      | LspProt.Command_summary { name = cmd; duration } ->
        let is_worst =
          match acc.command_worst_duration with
          | None -> true
          | Some d -> duration >= d
        in
        let acc =
          if not is_worst then
            acc
          else
            { acc with command_worst = Some cmd; command_worst_duration = Some duration }
        in
        let acc =
          {
            acc with
            command_count = acc.command_count + 1;
            command_duration = acc.command_duration +. duration;
          }
        in
        acc
      | LspProt.Recheck_summary
          { stats = { LspProt.dependent_file_count; changed_file_count; top_cycle }; duration } ->
        let is_worst =
          match acc.recheck_worst_duration with
          | None -> true
          | Some d -> duration >= d
        in
        let acc =
          if not is_worst then
            acc
          else
            {
              acc with
              recheck_worst_duration = Some duration;
              recheck_worst_dependent_file_count = Some dependent_file_count;
              recheck_worst_changed_file_count = Some changed_file_count;
              recheck_worst_cycle_size = Base.Option.map top_cycle ~f:(fun (_, size) -> size);
              recheck_worst_cycle_leader =
                Base.Option.map top_cycle ~f:(fun (f, _) ->
                    f |> File_key.to_string |> Files.relative_path (File_path.to_string root)
                );
            }
        in
        let acc =
          {
            acc with
            recheck_count = acc.recheck_count + 1;
            recheck_dependent_files = acc.recheck_dependent_files + dependent_file_count;
            recheck_changed_files = acc.recheck_changed_files + changed_file_count;
            recheck_duration = acc.recheck_duration +. duration;
          }
        in
        acc
    in
    Base.List.fold summaries ~init ~f
  )

let get_root (state : server_state) : File_path.t = (get_ienv state).i_root

let get_flowconfig (state : server_state) : FlowConfig.config = (get_ienv state).i_flowconfig

let get_initialize_params (state : server_state) : Lsp.Initialize.params =
  (get_ienv state).i_initialize_params

(** Returns a key that is appended to command names to make them "unique".

    Why? If we register a command named just "foo", and VS Code starts two
    clients (perhaps two Flows for different workspace folders, or even
    different languages that both have "foo" commands), it would be
    ambiguous to which server to send the command and so VS Code errors.

    For now, we use the root URI, under the assumption that one editor will
    never start two LSPs for the same workspace. This is slightly
    complicated by symlinks; if we used `ienv.i_root` for this, which has
    resolved symlinks, then this invariant is violated. So we use the
    raw `rootUri`/`rootPath` sent by the client. It would probably
    be safer to use a UUID. *)
let command_key_of_ienv (ienv : initialized_env) : string =
  let path = Lsp_helpers.get_root ienv.i_initialize_params in
  "org.flow:" ^ File_url.create path

let command_key_of_server_state (state : server_state) : string =
  command_key_of_ienv (get_ienv state)

let command_key_of_state (state : state) : string =
  match state with
  | Pre_init _
  | Post_shutdown ->
    ""
  | Initialized server_state -> command_key_of_server_state server_state

let get_open_files (state : server_state) : open_file_info Lsp.UriMap.t =
  (get_ienv state).i_open_files

let update_open_file
    (uri : Lsp.DocumentUri.t) (open_file_info : open_file_info option) (state : server_state) :
    server_state =
  let f ienv =
    match open_file_info with
    | Some open_file_info ->
      { ienv with i_open_files = Lsp.UriMap.add uri open_file_info ienv.i_open_files }
    | None -> { ienv with i_open_files = Lsp.UriMap.remove uri ienv.i_open_files }
  in
  update_ienv f state

let update_errors f state = update_ienv (fun ienv -> { ienv with i_errors = f ienv.i_errors }) state

let new_metadata (state : state) (message : Jsonrpc.message) : LspProt.metadata =
  let (start_lsp_state, start_lsp_state_reason, start_server_status, start_watcher_status) =
    match state with
    | Initialized (Connected { c_server_status = (s, w); _ }) -> (None, None, Some s, w)
    | Initialized (Disconnected { d_server_status = Some (s, w); _ }) ->
      (Some (string_of_state state), None, Some s, Some w)
    | Initialized (Disconnected { d_server_status = None; d_ienv; _ }) ->
      (Some (string_of_state state), Some d_ienv.i_status, None, None)
    | Pre_init _
    | Post_shutdown ->
      (Some (string_of_state state), None, None, None)
  in
  let start_lsp_state_reason =
    match start_lsp_state_reason with
    | None
    | Some Never_shown ->
      None
    | Some (Shown (_, params)) -> Some params.ShowStatus.request.ShowMessageRequest.message
  in
  let lsp_id = message.Jsonrpc.id |> Base.Option.map ~f:Lsp_fmt.parse_id in
  (* Meta-specific property that is set on requests and notifications by our
     internal VS Code extension to provide end-to-end telemetry.
     https://fburl.com/code/wdoqo479 *)
  let activity_key = Hh_json_helpers.Jget.obj_opt (Some message.Jsonrpc.json) "activityKey" in
  {
    LspProt.empty_metadata with
    LspProt.start_wall_time = message.Jsonrpc.timestamp;
    start_server_status;
    start_watcher_status;
    start_json_truncated =
      Hh_json.json_truncate message.Jsonrpc.json ~max_string_length:256 ~max_child_count:4;
    start_lsp_state;
    start_lsp_state_reason;
    lsp_method_name = Jsonrpc.(message.method_);
    lsp_id;
    activity_key;
  }

let edata_of_exception exn =
  let message = Exception.get_ctor_string exn in
  let stack = Exception.get_backtrace_string exn in
  { Marshal_tools.message; stack }

let selectively_omit_errors (request_name : string) (response : lsp_message) =
  match response with
  | ResponseMessage (id, ErrorResult _) ->
    let new_response =
      match request_name with
      (* Autocomplete requests are rarely manually-requested, so let's suppress errors from them to
         avoid spamming users if something isn't working. Once we reduce the error rate, we can undo
         this, but right now there are some known problems with the code in `members.ml` that often
         lead to errors. Once we migrate off of that, we will likely be able to display errors to
         users without degrading the experience.

         Another option would be to inspect the `completionTriggerKind` field, but `Invoked` doesn't
         actually mean that it was manually invoked. Typing an identifier char also results in an
         `Invoked` trigger.

         See https://microsoft.github.io/language-server-protocol/specification#textDocument_completion *)
      | "textDocument/completion" ->
        Some Completion.(CompletionResult { isIncomplete = false; items = [] })
      | "textDocument/signatureHelp" -> Some (SignatureHelpResult None)
      (* Like autocomplete requests, users rarely request these explicitly. The IDE sends them when
         people are simply moving the cursor around. For the same reasons, let's suppress errors here
         for now. *)
      | "textDocument/documentHighlight" -> Some (DocumentHighlightResult [])
      | _ -> None
    in
    Base.Option.map ~f:(fun response -> ResponseMessage (id, response)) new_response
    |> Base.Option.value ~default:response
  | _ -> response

let get_next_event_from_server (fd : Unix.file_descr) : event =
  try Server_message (Marshal_tools.from_fd_with_preamble fd) with
  | e ->
    let e = Exception.wrap e in
    let edata = edata_of_exception e in
    raise (Server_fatal_connection_exception edata)

let get_next_event_from_client
    (state : state) (client : Jsonrpc.queue) (parser : Jsonrpc.message -> Lsp.lsp_message) :
    event Lwt.t =
  let%lwt message = Jsonrpc.get_message client in
  match message with
  | `Message message -> Lwt.return (Client_message (parser message, new_metadata state message))
  | `Fatal_exception edata -> raise (Client_fatal_connection_exception edata)
  | `Recoverable_exception edata -> raise (Client_recoverable_connection_exception edata)

let get_next_event
    (state : state) (client : Jsonrpc.queue) (parser : Jsonrpc.message -> Lsp.lsp_message) :
    event Lwt.t =
  if Jsonrpc.has_message client then
    get_next_event_from_client state client parser
  else
    let client_fd = Jsonrpc.get_read_fd client in
    match state with
    | Initialized (Connected { c_conn; _ }) ->
      let server_fd = Timeout.descr_of_in_channel c_conn.ic in
      let (fds, _, _) =
        try Sys_utils.select_non_intr [server_fd; client_fd] [] [] 1.0 with
        | Unix.Unix_error (Unix.EBADF, _, _) as e ->
          (* Either the server died or the Jsonrpc died. Figure out which one *)
          let exn = Exception.wrap e in
          let edata = edata_of_exception exn in
          let server_died =
            try
              let _ = Sys_utils.select_non_intr [server_fd] [] [] 0.0 in
              false
            with
            | Unix.Unix_error (Unix.EBADF, _, _) -> true
          in
          if server_died then
            raise (Server_fatal_connection_exception edata)
          else
            raise (Client_fatal_connection_exception edata)
      in
      if fds = [] then
        Lwt.return Tick
      else if List.mem ~equal:( = ) fds server_fd then
        Lwt.return (get_next_event_from_server server_fd)
      else
        let%lwt event = get_next_event_from_client state client parser in
        Lwt.return event
    | _ ->
      let (fds, _, _) =
        try Sys_utils.select_non_intr [client_fd] [] [] 1.0 with
        | Unix.Unix_error (Unix.EBADF, _, _) as e ->
          (* Jsonrpc process died. This is unrecoverable *)
          let exn = Exception.wrap e in
          let edata = edata_of_exception exn in
          raise (Client_fatal_connection_exception edata)
      in
      if fds = [] then
        Lwt.return Tick
      else
        let%lwt event = get_next_event_from_client state client parser in
        Lwt.return event

(** Un-realpath's all of the [Lsp.DocumentUri.t] in [event].

    All of the URIs received from the server represent realpaths (symlinks have been resolved away).
    However, the client (e.g. VS Code) is expecting URIs within the project (children of [rootUri]).
    So this function converts any [DocumentUri] that points to the realpath'd root back to the
    client's [rootUri]. *)
let convert_to_client_uris =
  let server_message_mapper ~client_root ~server_root =
    let replace_prefix str =
      if String.starts_with ~prefix:server_root str then
        let prefix_len = String.length server_root in
        let relative = String.sub str prefix_len (String.length str - prefix_len) in
        client_root ^ relative
      else
        str
    in
    let replace_uri uri =
      uri |> Lsp.DocumentUri.to_string |> replace_prefix |> Lsp.DocumentUri.of_string
    in
    let lsp_mapper =
      { Lsp_mapper.default_mapper with Lsp_mapper.of_document_uri = (fun _mapper -> replace_uri) }
    in
    LspProt.default_message_from_server_mapper ~lsp_mapper
  in
  fun (state : state) (event : event) ->
    match state with
    | Pre_init _
    | Post_shutdown ->
      (* nothing to do *)
      event
    | Initialized (Disconnected { d_ienv = { i_initialize_params; i_root; _ }; _ })
    | Initialized (Connected { c_ienv = { i_initialize_params; i_root; _ }; _ }) ->
      (match event with
      | Server_message msg ->
        let client_root =
          let path = Lsp_helpers.get_root i_initialize_params in
          File_url.create path ^ "/"
        in
        let server_root =
          let path = File_path.to_string i_root in
          File_url.create path ^ "/"
        in
        let mapper = server_message_mapper ~client_root ~server_root in
        Server_message (mapper.LspProt.of_message_from_server mapper msg)
      | Client_message (msg, metadata) -> Client_message (msg, metadata)
      | Tick -> Tick)

let convert_to_server_uris =
  let server_uri_of_client_uri uri =
    uri
    |> Lsp.DocumentUri.to_string
    |> File_url.parse
    |> File_path.make
    |> File_path.to_string
    |> File_url.create
    |> Lsp.DocumentUri.of_string
  in
  let client_to_server_mapper =
    {
      Lsp_mapper.default_mapper with
      Lsp_mapper.of_document_uri = (fun _mapper -> server_uri_of_client_uri);
    }
  in
  let of_client_message msg =
    client_to_server_mapper.Lsp_mapper.of_lsp_message client_to_server_mapper msg
  in
  function
  | LspProt.Subscribe -> LspProt.Subscribe
  | LspProt.LspToServer msg -> LspProt.LspToServer (of_client_message msg)
  | LspProt.LiveErrorsRequest uri -> LspProt.LiveErrorsRequest (server_uri_of_client_uri uri)

let send_request_to_client
    id
    request
    ~(on_response : server_state Lsp.lsp_result_handler)
    ~on_error
    (ienv : initialized_env) =
  let json =
    let key = command_key_of_ienv ienv in
    Lsp_fmt.print_lsp ~key (RequestMessage (id, request))
  in
  to_stdout json;

  let handlers = (on_response, on_error) in
  let i_outstanding_local_requests = IdMap.add id request ienv.i_outstanding_local_requests in
  let i_outstanding_local_handlers = IdMap.add id handlers ienv.i_outstanding_local_handlers in

  { ienv with i_outstanding_local_requests; i_outstanding_local_handlers }

(** What should we display/hide? It's a tricky question... *)
let should_send_status (ienv : initialized_env) (status : ShowStatus.params) =
  let use_status = Lsp_helpers.supports_status ienv.i_initialize_params in
  let (will_dismiss_old, will_show_new) =
    match (use_status, ienv.i_status, status) with
    (* If the new status is identical to the old, then no-op *)
    | (_, Shown (_, existingStatus), status) when existingStatus = status -> (false, false)
    (* If the client supports status reporting, then we'll blindly send everything *)
    | (true, _, _) -> (false, true)
    (* If the client only supports dialog boxes, then we'll be very limited:
       only every display failures; and if there was already an error up even
       a different one then leave it undisturbed. *)
    | ( false,
        Shown
          (_, { ShowStatus.request = { ShowMessageRequest.type_ = MessageType.ErrorMessage; _ }; _ }),
        { ShowStatus.request = { ShowMessageRequest.type_ = MessageType.ErrorMessage; _ }; _ }
      ) ->
      (false, false)
    | ( false,
        Shown (id, _),
        { ShowStatus.request = { ShowMessageRequest.type_ = MessageType.ErrorMessage; _ }; _ }
      ) ->
      (Base.Option.is_some id, true)
    | (false, Shown (id, _), _) -> (Base.Option.is_some id, false)
    | ( false,
        Never_shown,
        { ShowStatus.request = { ShowMessageRequest.type_ = MessageType.ErrorMessage; _ }; _ }
      ) ->
      (false, true)
    | (false, Never_shown, _) -> (false, false)
  in
  (will_dismiss_old, will_show_new)

let show_status
    ?(titles = [])
    ?(handler = (fun _title state -> state))
    ~(type_ : MessageType.t)
    ~(message : string)
    ~(shortMessage : string option)
    ~(progress : int option)
    ~(total : int option)
    ?(backgroundColor : [ `error | `warning ] option)
    (ienv : initialized_env) : initialized_env =
  let use_status = Lsp_helpers.supports_status ienv.i_initialize_params in
  let actions = List.map titles ~f:(fun title -> { ShowMessageRequest.title }) in
  let params =
    {
      ShowStatus.request = { ShowMessageRequest.type_; message; actions };
      shortMessage;
      progress;
      total;
      backgroundColor;
    }
  in
  let (will_dismiss_old, will_show_new) = should_send_status ienv params in
  (* dismiss the old one *)
  let ienv =
    match (will_dismiss_old, ienv.i_status) with
    | (true, Shown (id, existingParams)) ->
      let id = Base.Option.value_exn id in
      let notification = CancelRequestNotification { CancelRequest.id } in
      let json =
        let key = command_key_of_ienv ienv in
        Lsp_fmt.print_lsp ~key (NotificationMessage notification)
      in
      to_stdout json;
      { ienv with i_status = Shown (None, existingParams) }
    | (_, _) -> ienv
  in
  (* show the new one *)
  if not will_show_new then
    ienv
  else
    let id = NumberId (Jsonrpc.get_next_request_id ()) in
    let request =
      if use_status then
        ShowStatusRequest params
      else
        ShowMessageRequestRequest params.ShowStatus.request
    in

    let mark_ienv_shown future_ienv =
      match future_ienv.i_status with
      | Shown (Some future_id, future_params) when future_id = id ->
        { future_ienv with i_status = Shown (None, future_params) }
      | _ -> future_ienv
    in
    let mark_state_shown state = update_ienv mark_ienv_shown state in
    let on_error _e state = mark_state_shown state in
    let handle_result (r : ShowMessageRequest.result) state =
      let state = mark_state_shown state in
      match r with
      | Some { ShowMessageRequest.title } -> handler title state
      | None -> state
    in
    let on_response : server_state Lsp.lsp_result_handler =
      if use_status then
        ShowStatusHandler handle_result
      else
        ShowMessageHandler handle_result
    in

    let ienv = send_request_to_client id request ~on_response ~on_error ienv in
    { ienv with i_status = Shown (Some id, params) }

let send_to_server (env : connected_env) (request : LspProt.request) (metadata : LspProt.metadata) :
    unit =
  (* calls realpath on every DocumentUri, because we want the server to only run once, on
     the canonical files, even if there are multiple clients operating on various symlinks. *)
  let request = convert_to_server_uris request in
  let _bytesWritten =
    Marshal_tools.to_fd_with_preamble (Unix.descr_of_out_channel env.c_conn.oc) (request, metadata)
  in
  ()

let send_lsp_to_server (cenv : connected_env) (metadata : LspProt.metadata) (message : lsp_message)
    : unit =
  send_to_server cenv (LspProt.LspToServer message) metadata

let send_configuration_to_server method_name settings cenv =
  let metadata =
    {
      LspProt.empty_metadata with
      LspProt.start_wall_time = Unix.gettimeofday ();
      start_json_truncated = Hh_json.(JSON_Object [("method", JSON_String method_name)]);
      lsp_method_name = method_name;
    }
  in
  let msg =
    NotificationMessage (DidChangeConfigurationNotification { Lsp.DidChangeConfiguration.settings })
  in
  send_lsp_to_server cenv metadata msg

let request_configuration (ienv : initialized_env) : initialized_env =
  let id = NumberId (Jsonrpc.get_next_request_id ()) in
  let request =
    ConfigurationRequest
      (* request all flow settings. we could request the individual keys we care about,
         but that hits a bug in vscode-languageclient < 7.0.0, where falsy individual
         values are converted to `null`, which also means "i don't understand this config".
         since we want to use the default for unknown configs, this bug would prevent us
         from having configs that default to `true` because we couldn't distinguish `false`
         from `null` (== `true`) *)
      { Lsp.Configuration.items = [{ Lsp.Configuration.section = Some "flow"; scope_uri = None }] }
  in
  let on_response =
    ConfigurationHandler
      (fun result state ->
        match result with
        | [i_config] ->
          (* update the lsp process's cache *)
          let state = update_ienv (fun ienv -> { ienv with i_config }) state in
          (* forward the notification to the server process *)
          (match state with
          | Connected cenv ->
            send_configuration_to_server "synthetic/didChangeConfiguration" i_config cenv
          | Disconnected _ -> ());
          state
        | _ -> state)
  in
  let on_error _e state = state in
  send_request_to_client id request ~on_response ~on_error ienv

let subscribe_to_config_changes (ienv : initialized_env) : initialized_env =
  let id = NumberId (Jsonrpc.get_next_request_id ()) in
  let request =
    RegisterCapabilityRequest
      RegisterCapability.{ registrations = [make_registration DidChangeConfiguration] }
  in
  let on_response = VoidHandler in
  let on_error _e state = state in
  send_request_to_client id request ~on_response ~on_error ienv

(************************************************************************)
(** Protocol                                                           **)

(************************************************************************)

let do_initialize params : Initialize.result =
  let open Initialize in
  let codeActionProvider =
    let supports_quickfixes =
      Lsp_helpers.supports_codeActionKinds params |> List.exists ~f:(( = ) CodeActionKind.quickfix)
    in
    let supports_refactor_extract =
      Lsp_helpers.supports_codeActionKinds params
      |> List.exists ~f:(( = ) CodeActionKind.refactor_extract)
    in
    let supports_source_actions =
      Lsp_helpers.supports_codeActionKinds params |> List.exists ~f:(( = ) CodeActionKind.source)
    in
    let supported_code_action_kinds =
      if supports_quickfixes then
        [CodeActionKind.quickfix]
      else
        []
    in
    let supported_code_action_kinds =
      if supports_refactor_extract then
        CodeActionKind.refactor_extract :: supported_code_action_kinds
      else
        supported_code_action_kinds
    in
    let supported_code_action_kinds =
      if supports_source_actions then
        CodeActionKind.kind_of_string "source.addMissingImports.flow"
        :: CodeActionKind.kind_of_string "source.organizeImports.flow"
        :: supported_code_action_kinds
      else
        supported_code_action_kinds
    in
    if not (List.is_empty supported_code_action_kinds) then
      CodeActionOptions { codeActionKinds = supported_code_action_kinds }
    else
      CodeActionBool false
  in
  let textDocumentSync =
    {
      TextDocumentSyncOptions.openClose = true;
      change = TextDocumentSyncKind.IncrementalSync;
      willSave = false;
      willSaveWaitUntil = false;
      save = Some { TextDocumentSyncOptions.includeText = false };
    }
  in

  let server_snippetTextEdit = Lsp_helpers.supports_experimental_snippet_text_edit params in
  {
    server_capabilities =
      {
        textDocumentSync;
        hoverProvider = true;
        completionProvider =
          Some
            {
              CompletionOptions.resolveProvider = false;
              triggerCharacters =
                [
                  "." (* member expressions *);
                  "[" (* bracket notation *);
                  " " (* before JSX attributes *);
                  "<" (* JSX opening tags *);
                  "/" (* inside JSX closing tags *);
                  "\"" (* JSX attribute value *);
                  "'" (* JSX attribute value *);
                  "#" (* private identifiers *);
                  "*" (* JSDoc opening /** *);
                ];
              completionItem = { CompletionOptions.labelDetailsSupport = true };
            };
        signatureHelpProvider = Some { sighelp_triggerCharacters = ["("; ","; "{"] };
        definitionProvider = true;
        typeDefinitionProvider = false;
        referencesProvider = true;
        documentHighlightProvider = true;
        documentSymbolProvider = true;
        workspaceSymbolProvider = true;
        codeActionProvider;
        codeLensProvider = None;
        documentFormattingProvider = false;
        documentRangeFormattingProvider = false;
        documentOnTypeFormattingProvider = None;
        renameProvider = Some { prepareProvider = Some true };
        documentLinkProvider = None;
        executeCommandProvider =
          Some
            {
              commands =
                [
                  Command.Command "log";
                  Command.Command "source.addMissingImports";
                  Command.Command "source.organizeImports";
                ];
            };
        implementationProvider = false;
        selectionRangeProvider = true;
        typeCoverageProvider = true;
        rageProvider = true;
        linkedEditingRangeProvider = true;
        server_workspace = { fileOperations = FileOperationOptions.{ willRename = None } };
        server_experimental =
          {
            server_snippetTextEdit;
            strictCompletionOrder = true;
            autoCloseJsx = true;
            pasteProvider = true;
            renameFileImports = true;
          };
      };
    server_info = { name = "Flow"; version = Flow_version.version };
  }

let message_with_flow_and_root_name_prefix flowconfig msg =
  match FlowConfig.root_name flowconfig with
  | None -> "Flow: " ^ msg
  | Some root -> "Flow (" ^ root ^ "): " ^ msg

let show_connected_status (cenv : connected_env) : connected_env =
  let message_with_prefix = message_with_flow_and_root_name_prefix cenv.c_ienv.i_flowconfig in
  let (type_, message, shortMessage, progress, total) =
    if cenv.c_is_rechecking then
      let (server_status, _) = cenv.c_server_status in
      if not (ServerStatus.is_free server_status) then
        let (shortMessage, progress, total) = ServerStatus.get_progress server_status in
        let message =
          message_with_prefix @@ ServerStatus.string_of_status ~use_emoji:false server_status
        in
        ( MessageType.WarningMessage,
          message,
          Base.Option.map ~f:message_with_prefix shortMessage,
          progress,
          total
        )
      else
        (MessageType.WarningMessage, message_with_prefix "Server is rechecking...", None, None, None)
    else
      let (_, watcher_status) = cenv.c_server_status in
      match watcher_status with
      | Some (_, FileWatcherStatus.Deferred { reason }) ->
        let message = Printf.sprintf "Waiting for %s to finish" reason in
        let short_message = Some (message_with_prefix "blocked") in
        (MessageType.WarningMessage, message, short_message, None, None)
      | Some (_, FileWatcherStatus.Initializing)
      | Some (_, FileWatcherStatus.Ready)
      | None ->
        let message =
          match cenv.c_lazy_stats with
          | Some { ServerProt.Response.lazy_mode; checked_files; total_files }
            when checked_files < total_files && lazy_mode ->
            Printf.sprintf
              "Flow is ready. (lazy mode let it check only %d/%d files [[more...](%s)])"
              checked_files
              total_files
              "https://flow.org/en/docs/lang/lazy-modes/"
          | _ -> "Flow is ready."
        in
        let short_message = Some (message_with_prefix "ready") in
        (MessageType.InfoMessage, message, short_message, None, None)
  in
  let c_ienv = show_status ~type_ ~message ~shortMessage ~progress ~total cenv.c_ienv in
  { cenv with c_ienv }

let show_connected (env : connected_env) : server_state =
  (* report that we're connected to telemetry/connectionStatus *)
  let i_isConnected =
    Lsp_writers.notify_connectionStatus
      env.c_ienv.i_initialize_params
      to_stdout
      env.c_ienv.i_isConnected
      true
  in
  let env = { env with c_ienv = { env.c_ienv with i_isConnected } } in
  (* show green status *)
  let env = show_connected_status env in
  Connected env

let show_connecting (reason : CommandConnectSimple.error) (env : disconnected_env) : server_state =
  if reason = CommandConnectSimple.Server_missing then
    Lsp_writers.log_info to_stdout "Starting Flow server";

  let (message, shortMessage, progress, total) =
    let message_with_prefix = message_with_flow_and_root_name_prefix env.d_ienv.i_flowconfig in
    match (reason, env.d_server_status) with
    | (CommandConnectSimple.Server_missing, _) ->
      (message_with_prefix "Server starting", None, None, None)
    | (CommandConnectSimple.Server_socket_missing, _) ->
      (message_with_prefix "Server starting?", None, None, None)
    | (CommandConnectSimple.(Build_id_mismatch Server_exited), _) ->
      (message_with_prefix "Server was wrong version and exited", None, None, None)
    | (CommandConnectSimple.(Build_id_mismatch (Client_should_error _)), _) ->
      (message_with_prefix "Server is wrong version", None, None, None)
    | (CommandConnectSimple.Server_busy CommandConnectSimple.Too_many_clients, _) ->
      (message_with_prefix "Server busy", None, None, None)
    | (CommandConnectSimple.Server_busy _, None) ->
      (message_with_prefix "Server busy", None, None, None)
    | (CommandConnectSimple.Server_busy _, Some (server_status, watcher_status)) ->
      if not (ServerStatus.is_free server_status) then
        let (shortMessage, progress, total) = ServerStatus.get_progress server_status in
        ( message_with_prefix @@ ServerStatus.string_of_status ~use_emoji:false server_status,
          shortMessage,
          progress,
          total
        )
      else
        (message_with_prefix @@ FileWatcherStatus.string_of_status watcher_status, None, None, None)
  in
  let d_ienv =
    show_status ~type_:MessageType.WarningMessage ~message ~shortMessage ~progress ~total env.d_ienv
  in
  Disconnected { env with d_ienv }

let show_disconnected (code : FlowExit.t option) (message : string option) (env : disconnected_env)
    : server_state =
  (* report that we're disconnected to telemetry/connectionStatus *)
  let i_isConnected =
    Lsp_writers.notify_connectionStatus
      env.d_ienv.i_initialize_params
      to_stdout
      env.d_ienv.i_isConnected
      false
  in
  let env = { env with d_ienv = { env.d_ienv with i_isConnected } } in
  let message_with_prefix = message_with_flow_and_root_name_prefix env.d_ienv.i_flowconfig in
  (* show red status *)
  let message = Base.Option.value message ~default:(message_with_prefix "server is stopped") in
  let message =
    match code with
    | Some code -> Printf.sprintf "%s [%s]" message (FlowExit.to_string code)
    | None -> message
  in
  let handler r state =
    match (state, r) with
    | (Disconnected e, "Restart") -> Disconnected { e with d_autostart = true }
    | _ -> state
  in
  let d_ienv =
    show_status
      ~handler
      ~titles:["Restart"]
      ~type_:MessageType.ErrorMessage
      ~message
      ~shortMessage:None
      ~progress:None
      ~total:None
      ~backgroundColor:`error
      env.d_ienv
  in
  Disconnected { env with d_ienv }

let close_conn (env : connected_env) : unit =
  (try Timeout.shutdown_connection env.c_conn.ic with
  | _ -> ());
  try Timeout.close_in_noerr env.c_conn.ic with
  | _ -> ()

(************************************************************************
 ** Tracking                                                           **
 ************************************************************************
    The goal of tracking is that, if a server goes down, then all errors
    and dialogs and things it created should be taken down with it.

    "track_to_server" is called for client->lsp messages when they get
      sent to the current server.
    "track_from_server" is called for server->lsp messages which
      immediately get passed on to the client.
    "dismiss_tracks" is called when a server gets disconnected.

    EDITOR_OPEN_FILES - we keep the current contents of all editor open
      files. Updated in response to client->lsp notifications
      didOpen/Change/Save/Close. When a new server starts, we synthesize
      didOpen messages to the new server.
    OUTSTANDING_REQUESTS_TO_SERVER - for all client->lsp requests that
      have been sent to the server. Added to this list when we
      track_to_server(request); removed on track_from_server(response).
      When a server dies, we synthesize RequestCancelled responses
      ourselves since the server will no longer do that.
    OUTSTANDING_REQUESTS_FROM_SERVER - for all server->lsp requests. We
      generate a "wrapped-id" that encodes which server it came from,
      and send immediately to the client. Added to this list when we
      track_from_server(request), removed in track_to_server(response).
      When a server dies, we emit CancelRequest notifications to the
      client so it can dismiss dialogs or similar. When any response
      comes back from the client, we ignore ones that are destined for
      now-defunct servers, and only forward on the ones for the current
      server.
 *)

type track_effect = { changed_live_uri: Lsp.DocumentUri.t option }

let track_to_server (state : server_state) (c : Lsp.lsp_message) : server_state * track_effect =
  let (state, changed_live_uri) =
    match (get_open_files state, c) with
    | (_, NotificationMessage (DidOpenNotification params)) ->
      let o_open_doc = params.DidOpen.textDocument in
      let uri = params.DidOpen.textDocument.TextDocumentItem.uri in
      let state =
        update_open_file uri (Some { o_open_doc; o_ast = None; o_unsaved = false }) state
      in
      (state, Some uri)
    | (_, NotificationMessage (DidCloseNotification params)) ->
      let uri = params.DidClose.textDocument.TextDocumentIdentifier.uri in
      let state =
        state
        |> update_open_file uri None
        |> update_errors (LspErrors.clear_all_live_errors_and_send to_stdout uri)
      in
      (state, None)
    | (open_files, NotificationMessage (DidChangeNotification params)) ->
      let uri = params.DidChange.textDocument.VersionedTextDocumentIdentifier.uri in
      let { o_open_doc; _ } =
        try Lsp.UriMap.find uri open_files with
        | Not_found -> raise (Changed_file_not_open uri)
      in
      let text = o_open_doc.TextDocumentItem.text in
      let text = Lsp_helpers.apply_changes_unsafe text params.DidChange.contentChanges in
      let o_open_doc =
        {
          Lsp.TextDocumentItem.uri;
          languageId = o_open_doc.TextDocumentItem.languageId;
          version = params.DidChange.textDocument.VersionedTextDocumentIdentifier.version;
          text;
        }
      in
      let state =
        update_open_file uri (Some { o_open_doc; o_ast = None; o_unsaved = true }) state
      in
      (* update errors... we don't need to send updated squiggle locations
         right now ourselves, since all editors take care of that; but if ever we
         re-send the server's existing diagnostics for this file then that should take
         into account any user edits since then. This isn't perfect - e.g. if the user
         modifies a file we'll update squiggles, but if the user subsquently closes the
         file unsaved and then re-opens it then we'll be left with wrong squiggles.
         It also doesn't compensate if the flow server starts a typecheck, then receives
         a DidChange, then sends error spans from as it was at the start of the typecheck.
         Still, at least we're doing better on the common case -- where the server has sent
         diagnostics, then the user types, then we re-send live syntax errors. *)
      let state =
        match state with
        | Connected _ ->
          state |> update_errors (LspErrors.update_errors_due_to_change_and_send to_stdout params)
        | Disconnected _ -> state
      in
      (state, Some uri)
    | (open_files, NotificationMessage (DidSaveNotification params)) ->
      let uri = params.DidSave.textDocument.TextDocumentIdentifier.uri in
      let open_file = Lsp.UriMap.find uri open_files in
      let state = update_open_file uri (Some { open_file with o_unsaved = false }) state in
      (state, Some uri)
    | (_, _) -> (state, None)
  in
  (* update cenv.c_outstanding_requests*... *)
  let state =
    match (state, c) with
    (* client->server requests *)
    | (Connected env, RequestMessage (id, _)) ->
      Connected
        {
          env with
          c_outstanding_requests_to_server = IdSet.add id env.c_outstanding_requests_to_server;
        }
    (* client->server responses *)
    | (Connected env, ResponseMessage (id, _)) ->
      let wrapped = decode_wrapped id in
      let c_ienv =
        {
          env.c_ienv with
          i_outstanding_requests_from_server =
            WrappedMap.remove wrapped env.c_ienv.i_outstanding_requests_from_server;
        }
      in
      Connected { env with c_ienv }
    | _ -> state
  in
  (state, { changed_live_uri })

let track_from_server (state : server_state) (c : Lsp.lsp_message) : server_state =
  match (state, c) with
  (* server->client response *)
  | (Connected env, ResponseMessage (id, _)) ->
    Connected
      {
        env with
        c_outstanding_requests_to_server = IdSet.remove id env.c_outstanding_requests_to_server;
      }
  (* server->client request *)
  | (Connected env, RequestMessage (id, params)) ->
    let wrapped = { server_id = env.c_ienv.i_server_id; message_id = id } in
    let c_ienv =
      {
        env.c_ienv with
        i_outstanding_requests_from_server =
          WrappedMap.add wrapped params env.c_ienv.i_outstanding_requests_from_server;
      }
    in
    Connected { env with c_ienv }
  | (_, _) -> state

let lsp_DocumentItem_to_flow (open_doc : Lsp.TextDocumentItem.t) : File_input.t =
  let uri = open_doc.TextDocumentItem.uri in
  let fn = Lsp_helpers.lsp_uri_to_path uri in
  let fn = Base.Option.value (Sys_utils.realpath fn) ~default:fn in
  File_input.FileContent (Some fn, open_doc.TextDocumentItem.text)

(******************************************************************************)
(* Diagnostics                                                                *)
(* These should really be handle inside the flow server so it sends out       *)
(* LSP publishDiagnostics notifications and we track them in the normal way.  *)
(* But while the flow server has to handle legacy clients as well as LSP      *)
(* clients, we don't want to make the flow server code too complex, so we're  *)
(* handling them here for now.                                                *)
(******************************************************************************)

let diagnostic_of_parse_error (loc, parse_error) : PublishDiagnostics.diagnostic =
  {
    Lsp.PublishDiagnostics.range = Lsp.loc_to_lsp_range loc;
    severity = Some PublishDiagnostics.Error;
    code = Lsp.PublishDiagnostics.StringCode "ParseError";
    source = Some "Flow";
    tags = [];
    message = Parse_error.PP.error parse_error;
    relatedInformation = [];
    data = PublishDiagnostics.NoExtraData;
  }

let live_syntax_errors_enabled (state : server_state) =
  let open Initialize in
  (get_initialize_params state).initializationOptions.liveSyntaxErrors

(** parse_and_cache: either the uri is an open file for which we already
    have parse results (ast+diagnostics), so we can just return them;
    or it's an open file and we are expected to lazily compute the parse results
    and store them in the state;
    or it's an unopened file in which case we'll retrieve parse results but
    won't store them. *)
let parse_and_cache (state : server_state) (uri : Lsp.DocumentUri.t) :
    server_state
    * ((Loc.t, Loc.t) Flow_ast.Program.t * Lsp.PublishDiagnostics.diagnostic list option) =
  (* The way flow compilation works in the flow server is that parser options
     are permissive to allow all constructs, so that parsing works well; if
     the user choses not to enable features through the user's .flowconfig
     then use of impermissable constructs will be reported at typecheck time
     (not as parse errors). We'll do the same here, with permissive parsing
     and only reporting parse errors. *)
  let parse_options =
    let flowconfig = get_flowconfig state in
    let use_strict = FlowConfig.modules_are_use_strict flowconfig in
    let module_ref_prefix = FlowConfig.haste_module_ref_prefix flowconfig in
    let assert_operator = FlowConfig.assert_operator flowconfig |> Options.AssertOperator.parse in
    Some
      {
        Parser_env.permissive_parse_options with
        Parser_env.use_strict;
        module_ref_prefix;
        assert_operator;
      }
  in

  let parse file =
    let (program, errors) =
      try
        let content = File_input.content_of_file_input_unsafe file in
        let filename_opt = File_input.path_of_file_input file in
        let filekey = Base.Option.map filename_opt ~f:(fun fn -> File_key.SourceFile fn) in
        Parser_flow.program_file ~fail:false ~parse_options ~token_sink:None content filekey
      with
      | _ ->
        ( ( Loc.none,
            {
              Flow_ast.Program.statements = [];
              interpreter = None;
              comments = None;
              all_comments = [];
            }
          ),
          []
        )
    in
    ( program,
      if live_syntax_errors_enabled state then
        Some (List.map errors ~f:diagnostic_of_parse_error)
      else
        None
    )
  in
  let open_files = get_open_files state in
  let existing_open_file_info = Lsp.UriMap.find_opt uri open_files in
  match existing_open_file_info with
  | Some { o_ast = Some o_ast; _ } ->
    (* We've already parsed this file since it last changed. No need to parse again *)
    (state, o_ast)
  | Some { o_open_doc; o_unsaved; _ } ->
    (* We have not parsed this file yet. We need to parse it now and save the updated ast *)
    let file = lsp_DocumentItem_to_flow o_open_doc in
    let o_ast = parse file in
    let open_file_info = Some { o_open_doc; o_ast = Some o_ast; o_unsaved } in
    let state = state |> update_open_file uri open_file_info in
    (state, o_ast)
  | None ->
    (* This is an unopened file, so we won't cache the results and won't return the errors *)
    let fn = Lsp_helpers.lsp_uri_to_path uri in
    let fn = Base.Option.value (Sys_utils.realpath fn) ~default:fn in
    let file = File_input.FileName fn in
    let (open_ast, _) = parse file in
    (state, (open_ast, None))

let do_documentSymbol (state : server_state) (id : lsp_id) (params : DocumentSymbol.params) :
    server_state =
  let uri = params.DocumentSymbol.textDocument.TextDocumentIdentifier.uri in
  (* It's not do_documentSymbol's job to set live parse errors, so we ignore them *)
  let (state, (ast, _live_parse_errors)) = parse_and_cache state uri in
  let supports_hierarchical_document_symbol =
    Lsp_helpers.supports_hierarchical_document_symbol (get_initialize_params state)
  in
  let result =
    if supports_hierarchical_document_symbol then
      `DocumentSymbol (DocumentSymbolProvider.provide_document_symbols ast)
    else
      `SymbolInformation (DocumentSymbolProvider.provide_symbol_information ~uri ast)
  in
  let json =
    let key = command_key_of_server_state state in
    Lsp_fmt.print_lsp ~key (ResponseMessage (id, DocumentSymbolResult result))
  in
  to_stdout json;
  state

let do_selectionRange (state : server_state) (id : lsp_id) (params : SelectionRange.params) :
    server_state =
  let { SelectionRange.textDocument = { TextDocumentIdentifier.uri }; positions } = params in
  (* It's not our job to set live parse errors, so we ignore them *)
  let (state, (ast, _live_parse_errors)) = parse_and_cache state uri in
  let response = SelectionRangeProvider.provide_selection_ranges positions ast in
  let json =
    let key = command_key_of_server_state state in
    Lsp_fmt.print_lsp ~key ~include_error_stack_trace:false (ResponseMessage (id, response))
  in
  to_stdout json;
  state

module RagePrint = struct
  let addline (b : Buffer.t) (prefix : string) (s : string) : unit =
    Buffer.add_string b prefix;
    Buffer.add_string b s;
    Buffer.add_string b "\n";
    ()

  let string_of_lazy_stats (lazy_stats : ServerProt.Response.lazy_stats) : string =
    ServerProt.(
      Printf.sprintf
        "lazy_mode=%B, checked_files=%d, total_files=%d"
        lazy_stats.Response.lazy_mode
        lazy_stats.Response.checked_files
        lazy_stats.Response.total_files
    )

  let string_of_lazy_mode = function
    | FlowConfig.Lazy -> "true"
    | FlowConfig.Watchman_DEPRECATED -> "watchman"
    | FlowConfig.Non_lazy -> "false"

  let string_of_connect_params (p : connect_params) : string =
    CommandUtils.(
      Printf.sprintf
        "retries=%d, no_auto_start=%B, autostop=%B, ignore_version=%B quiet=%B, temp_dir=%s, timeout=%s, lazy_mode=%s"
        p.retries
        p.no_auto_start
        p.autostop
        p.ignore_version
        p.quiet
        (Base.Option.value ~default:"None" p.temp_dir)
        (Base.Option.value_map p.timeout ~default:"None" ~f:string_of_int)
        (Base.Option.value_map p.lazy_mode ~default:"None" ~f:string_of_lazy_mode)
    )

  let string_of_open_file { o_open_doc; o_ast; o_unsaved } : string =
    Printf.sprintf
      "(uri=%s version=%d text=[%d bytes] ast=[%s] unsaved=%b)"
      (Lsp.DocumentUri.to_string o_open_doc.TextDocumentItem.uri)
      o_open_doc.TextDocumentItem.version
      (String.length o_open_doc.TextDocumentItem.text)
      (Base.Option.value_map o_ast ~default:"absent" ~f:(fun _ -> "present"))
      o_unsaved

  let string_of_open_files (files : open_file_info Lsp.UriMap.t) : string =
    Lsp.UriMap.bindings files
    |> List.map ~f:(fun (_, ofi) -> string_of_open_file ofi)
    |> String.concat ","

  let string_of_show_status (show_status : show_status_t) : string =
    match show_status with
    | Never_shown -> "Never_shown"
    | Shown (id_opt, params) ->
      Printf.sprintf
        "Shown id=%s params=%s"
        (Base.Option.value_map id_opt ~default:"None" ~f:Lsp_fmt.id_to_string)
        (print_showStatus params |> Hh_json.json_to_string)

  let add_ienv (b : Buffer.t) (ienv : initialized_env) : unit =
    addline b "i_connect_params=" (ienv.i_connect_params |> string_of_connect_params);
    addline b "i_root=" (ienv.i_root |> File_path.to_string);
    addline b "i_version=" (ienv.i_version |> Base.Option.value ~default:"None");
    addline b "i_server_id=" (ienv.i_server_id |> string_of_int);
    addline
      b
      "i_can_autostart_after_version_mismatch="
      (ienv.i_can_autostart_after_version_mismatch |> string_of_bool);
    addline
      b
      "i_outstanding_local_handlers="
      (ienv.i_outstanding_local_handlers
      |> IdMap.bindings
      |> List.map ~f:(fun (id, _handler) -> Lsp_fmt.id_to_string id)
      |> String.concat ","
      );
    addline
      b
      "i_outstanding_local_requests="
      (ienv.i_outstanding_local_requests
      |> IdMap.bindings
      |> List.map ~f:(fun (id, req) ->
             Printf.sprintf "%s:%s" (Lsp_fmt.id_to_string id) (Lsp_fmt.request_name_to_string req)
         )
      |> String.concat ","
      );
    addline
      b
      "i_outstanding_requests_from_server="
      (ienv.i_outstanding_requests_from_server
      |> WrappedMap.bindings
      |> List.map ~f:(fun (id, req) ->
             Printf.sprintf
               "#%d:%s:%s"
               id.server_id
               (Lsp_fmt.id_to_string id.message_id)
               (Lsp_fmt.request_name_to_string req)
         )
      |> String.concat ","
      );
    addline b "i_isConnected=" (ienv.i_isConnected |> string_of_bool);
    addline b "i_status=" (ienv.i_status |> string_of_show_status);
    addline b "i_open_files=" (ienv.i_open_files |> string_of_open_files);
    ()

  let add_denv (b : Buffer.t) (denv : disconnected_env) : unit =
    let (server_status, watcher_status) =
      match denv.d_server_status with
      | None -> (None, None)
      | Some (s, w) -> (Some s, Some w)
    in
    add_ienv b denv.d_ienv;
    addline b "d_autostart=" (denv.d_autostart |> string_of_bool);
    addline
      b
      "d_server_status:server="
      (server_status |> Base.Option.value_map ~default:"None" ~f:ServerStatus.string_of_status);
    addline
      b
      "d_server_status:watcher="
      (watcher_status |> Base.Option.value_map ~default:"None" ~f:FileWatcherStatus.string_of_status);
    ()

  let add_cenv (b : Buffer.t) (cenv : connected_env) : unit =
    let (server_status, watcher_status) = cenv.c_server_status in
    add_ienv b cenv.c_ienv;
    addline b "c_server_status:server=" (server_status |> ServerStatus.string_of_status);
    addline
      b
      "c_server_status:watcher="
      (watcher_status |> Base.Option.value_map ~default:"None" ~f:FileWatcherStatus.string_of_status);
    addline
      b
      "c_about_to_exit_code="
      (cenv.c_about_to_exit_code |> Base.Option.value_map ~default:"None" ~f:FlowExit.to_string);
    addline b "c_is_rechecking=" (cenv.c_is_rechecking |> string_of_bool);
    addline
      b
      "c_lazy_stats="
      (cenv.c_lazy_stats |> Base.Option.value_map ~default:"None" ~f:string_of_lazy_stats);
    addline
      b
      "c_outstanding_requests_to_server="
      (cenv.c_outstanding_requests_to_server
      |> IdSet.elements
      |> List.map ~f:Lsp_fmt.id_to_string
      |> String.concat ","
      );
    ()

  let string_of_state (state : server_state) : string =
    let b = Buffer.create 10000 in
    begin
      match state with
      | Disconnected denv ->
        Buffer.add_string b "Disconnected:\n";
        add_denv b denv
      | Connected cenv ->
        Buffer.add_string b "Connected:\n";
        add_cenv b cenv
    end;
    Buffer.contents b
end

let do_rage flowconfig_name (state : server_state) : Rage.result =
  Rage.(
    (* Some helpers to add various types of data to the rage output... *)
    let add_file (items : rageItem list) (file : File_path.t) : rageItem list =
      let data =
        if File_path.file_exists file then
          let data = File_path.cat file in
          (* cat even up to 1gig is workable even if ugly *)
          let len = String.length data in
          let max_len = 10 * 1024 * 1024 in
          (* maximum 10mb *)
          if len <= max_len then
            data
          else
            String.sub data (len - max_len) max_len
        else
          Printf.sprintf "File not found: %s" (File_path.to_string file)
      in
      { title = Some (File_path.to_string file); data } :: items
    in
    let add_string (items : rageItem list) (data : string) : rageItem list =
      { title = None; data } :: items
    in
    let add_pid (items : rageItem list) ((pid, reason) : int * string) : rageItem list =
      if String.starts_with ~prefix:"worker" reason then
        items
      else
        let pid = string_of_int pid in
        (* some systems have "pstack", some have "gstack", some have neither... *)
        let stack =
          try Sys_utils.exec_read_lines ~reverse:true ("pstack " ^ pid) with
          | _ -> begin
            try Sys_utils.exec_read_lines ~reverse:true ("gstack " ^ pid) with
            | e ->
              let e = Exception.wrap e in
              ["unable to pstack - " ^ Exception.get_ctor_string e]
          end
        in
        let stack = String.concat "\n" stack in
        add_string items (Printf.sprintf "PSTACK %s (%s) - %s\n\n" pid reason stack)
    in
    let items : rageItem list = [] in
    (* LOGFILES.
       Where are the logs? Specified explicitly by the user with --log-file and
       --monitor-log-file when they launched the server. Failing that, the
       values in environment variables FLOW_LOG_FILE and FLOW_MONITOR_LOG_FILE
       upon launch. Failing that, CommandUtils.server_log_file will look in the
       flowconfig for a "log.file" option. Failing that it will synthesize one
       from `Server_files_js.log_file` in the tmp-directory. And
       CommandUtils.monitor_log_file is similar except it bypasses flowconfig.
       As for tmp dir, that's --temp_dir, failing that FLOW_TEMP_DIR, failing
       that temp_dir in flowconfig, failing that Sys_utils.temp_dir_name /flow.
       WOW!
       Notionally the only authoritative way to find logs is to connect to a
       running monitor and ask it. But we're a 'rage' command whose whole point
       is to give good answers even when things are not working, e.g. when the
       monitor is down. And in any case, by design, a flow client can only ever
       interact with a server if the client was launched with the same flags
       (minimum tmp_dir and flowconfig) as the server was launched with.
       Therefore there's no need to ask the monitor. We'll just work with what
       log files we'd write to were we ourselves asked to start a server. *)
    let ienv = get_ienv state in
    let items =
      let root = ienv.i_root in
      let tmp_dir =
        CommandUtils.get_temp_dir ienv.i_connect_params.temp_dir
        |> File_path.make
        |> File_path.to_string
      in
      let server_log_file = CommandUtils.server_log_file ~flowconfig_name ~tmp_dir root in
      let monitor_log_file = CommandUtils.monitor_log_file ~flowconfig_name ~tmp_dir root in
      let items = add_file items server_log_file in
      let items = add_file items monitor_log_file in
      (* Let's pick up the old files in case user reported bug after a crash *)
      let items = add_file items (File_path.make (File_path.to_string server_log_file ^ ".old")) in
      let items = add_file items (File_path.make (File_path.to_string monitor_log_file ^ ".old")) in
      (* And the pids file *)
      let items =
        try
          let pids =
            PidLog.get_pids (Server_files_js.pids_file ~flowconfig_name ~tmp_dir ienv.i_root)
          in
          Base.List.fold pids ~init:items ~f:add_pid
        with
        | e ->
          let e = Exception.wrap e in
          add_string items (Printf.sprintf "Failed to get PIDs: %s" (Exception.to_string e))
      in
      items
    in
    (* CLIENT. This includes the client's perception of the server state. *)
    let items = add_string items ("LSP adapter state: " ^ RagePrint.string_of_state state ^ "\n") in
    (* DONE! *)
    items
  )

let parse_json (state : state) (msg : Jsonrpc.message) : lsp_message =
  let json = msg.Jsonrpc.json in
  (* to know how to parse a response, we must provide the corresponding request *)
  let outstanding (id : lsp_id) : lsp_request =
    let ienv =
      match state with
      | Pre_init _ ->
        Printf.ksprintf
          failwith
          "Unexpected LSP response before init: %s"
          (Hh_json.json_to_string json)
      | Post_shutdown ->
        Printf.ksprintf
          failwith
          "Unexpected LSP response after shutdown: %s"
          (Hh_json.json_to_string json)
      | Initialized server_state -> get_ienv server_state
    in
    match IdMap.find_opt id ienv.i_outstanding_local_requests with
    | Some msg -> msg
    | None ->
      (match WrappedMap.find_opt (decode_wrapped id) ienv.i_outstanding_requests_from_server with
      | Some msg -> msg
      | None ->
        raise
          (Error.LspException
             {
               Error.code = Error.InternalError;
               message =
                 Printf.sprintf "Wasn't expecting a response to request %s" (Lsp_fmt.id_to_string id);
               data = None;
             }
          ))
  in
  Lsp_fmt.parse_lsp json outstanding

let with_timer (f : unit -> 'a) : float * 'a =
  let start = Unix.gettimeofday () in
  let ret = f () in
  let duration = Unix.gettimeofday () -. start in
  (duration, ret)

(* The EventLogger needs to be periodically flushed. LspCommand was originally written to flush
   when idle, but the idle detection didn't quite work so we never really flushed until exiting. So
   instead lets periodically flush. Flushing should be fast and this is basically what the monitor
   does too. *)
module LogFlusher = LwtLoop.Make (struct
  type acc = unit

  let should_pause = ref true

  let main () =
    let%lwt () = Lwt_unix.sleep 5.0 in
    Lwt.join [EventLoggerLwt.flush (); FlowInteractionLogger.flush ()]

  let catch () exn = Exception.reraise exn
end)

(** Our interaction logging logs a snapshot of the state of the world at the start of an
    interaction (when the interaction is triggered) and at the end of an interaction (when the ux
    occurs). This function collects that state. This is called relatively often, so it should be
    pretty cheap *)
let collect_interaction_state (state : server_state) =
  let open LspInteraction in
  let time = Unix.gettimeofday () in
  let buffer_status =
    let files = get_open_files state in
    if Lsp.UriMap.is_empty files then
      NoOpenBuffers
    else if Lsp.UriMap.exists (fun _ file -> file.o_unsaved) files then
      UnsavedBuffers
    else
      NoUnsavedBuffers
  in
  let server_status =
    match state with
    | Disconnected disconnected_env ->
      if disconnected_env.d_server_status = None then
        Stopped
      else
        Initializing
    | Connected connected_env ->
      if connected_env.c_is_rechecking then
        Rechecking
      else
        Ready
  in
  { time; server_status; buffer_status }

(** Completed interactions clean themselves up, but we need to clean up pending interactions which
    have never been completed. *)
let gc_pending_interactions =
  let next_gc = ref (Unix.gettimeofday ()) in
  fun (state : state) ->
    match state with
    | Pre_init _
    | Post_shutdown ->
      ()
    | Initialized server_state ->
      if Unix.gettimeofday () >= !next_gc then
        next_gc := LspInteraction.gc ~get_state:(fun () -> collect_interaction_state server_state)

(** Kicks off the interaction tracking *)
let start_interaction ~trigger state =
  let start_state = collect_interaction_state state in
  LspInteraction.start ~start_state ~trigger

let log_interaction ~ux state id =
  let end_state = collect_interaction_state state in
  LspInteraction.log ~end_state ~ux ~id

let dismiss_tracks (state : server_state) : server_state =
  let decline_request_to_server (id : lsp_id) : unit =
    let e =
      {
        Error.code = Error.RequestCancelled;
        message = "Connection to server has been lost";
        data = None;
      }
    in
    let stack = "" in
    let json =
      let key = command_key_of_server_state state in
      Lsp_fmt.print_lsp_response ~key id (ErrorResult (e, stack))
    in
    to_stdout json
  in
  let cancel_request_from_server (server_id : int) (wrapped : wrapped_id) (_request : lsp_request) :
      unit =
    if server_id = wrapped.server_id then
      let id = encode_wrapped wrapped in
      let notification = CancelRequestNotification { CancelRequest.id } in
      let json = Lsp_fmt.print_lsp_notification notification in
      to_stdout json
    else
      ()
  in
  LspInteraction.dismiss_tracks (collect_interaction_state state);
  match state with
  | Connected env ->
    WrappedMap.iter
      (cancel_request_from_server env.c_ienv.i_server_id)
      env.c_ienv.i_outstanding_requests_from_server;
    IdSet.iter decline_request_to_server env.c_outstanding_requests_to_server;
    Connected { env with c_outstanding_requests_to_server = IdSet.empty }
    |> update_errors (LspErrors.clear_all_errors_and_send to_stdout)
  | Disconnected _ -> state

let do_live_diagnostics
    (state : server_state)
    (trigger : LspInteraction.trigger option)
    (metadata : LspProt.metadata)
    (uri : Lsp.DocumentUri.t) : server_state =
  (* Normally we don't log interactions for unknown triggers. But in this case we're providing live
     diagnostics and want to log what triggered it regardless of whether it's known or not *)
  let trigger = Base.Option.value trigger ~default:LspInteraction.UnknownTrigger in
  let () =
    (* Only ask the server for live errors if we're connected *)
    match state with
    | Connected cenv ->
      let metadata =
        { metadata with LspProt.interaction_tracking_id = Some (start_interaction ~trigger state) }
      in
      send_to_server cenv (LspProt.LiveErrorsRequest uri) metadata
    | Disconnected _ -> ()
  in
  let interaction_id = start_interaction ~trigger state in
  (* reparse the file and write it into the state's editor_open_files as needed *)
  let (state, (_, live_parse_errors)) = parse_and_cache state uri in
  (* Set the live parse errors *)
  let (state, ux) =
    match live_parse_errors with
    | None -> (state, LspInteraction.ErroredPushingLiveParseErrors)
    | Some live_parse_errors ->
      let state =
        state
        |> update_errors (LspErrors.set_live_parse_errors_and_send to_stdout uri live_parse_errors)
      in
      (state, LspInteraction.PushedLiveParseErrors uri)
  in
  log_interaction ~ux state interaction_id;
  let error_count =
    Base.Option.value_map live_parse_errors ~default:Hh_json.JSON_Null ~f:(fun errors ->
        Hh_json.JSON_Number (errors |> List.length |> string_of_int)
    )
  in
  FlowEventLogger.live_parse_errors
    ~request:(metadata.LspProt.start_json_truncated |> Hh_json.json_to_string)
    ~data:
      Hh_json.(
        JSON_Object
          [("uri", JSON_String (Lsp.DocumentUri.to_string uri)); ("error_count", error_count)]
        |> json_to_string
      )
    ~wall_start:metadata.LspProt.start_wall_time;

  state

let get_local_request_handler ienv (id, result) =
  match IdMap.find_opt id ienv.i_outstanding_local_handlers with
  | Some (handle, handle_error) ->
    let i_outstanding_local_handlers = IdMap.remove id ienv.i_outstanding_local_handlers in
    let i_outstanding_local_requests = IdMap.remove id ienv.i_outstanding_local_requests in
    let ienv = { ienv with i_outstanding_local_handlers; i_outstanding_local_requests } in
    let handler =
      match (result, handle) with
      | (ShowMessageRequestResult result, ShowMessageHandler handle) -> handle result
      | (ShowStatusResult result, ShowStatusHandler handle) -> handle result
      | (ApplyWorkspaceEditResult result, ApplyWorkspaceEditHandler handle) -> handle result
      | (ConfigurationResult result, ConfigurationHandler handle) -> handle result
      | (RegisterCapabilityResult, VoidHandler) -> (fun state -> state)
      | (ErrorResult (e, msg), _) -> handle_error (e, msg)
      | _ ->
        failwith (Printf.sprintf "Response %s has mistyped handler" (result_name_to_string result))
    in
    Some (ienv, handler)
  | None -> None

let try_connect ~version_mismatch_strategy flowconfig_name (env : disconnected_env) : server_state =
  let flowconfig = read_flowconfig_from_disk flowconfig_name env.d_ienv.i_root in
  (* If the version in .flowconfig has changed under our feet then we mustn't
     connect. We'll terminate and trust the editor to relaunch an ok version. *)
  let current_version = FlowConfig.required_version flowconfig in
  if env.d_ienv.i_version <> current_version then (
    let prev_version_str = Base.Option.value env.d_ienv.i_version ~default:"[None]" in
    let current_version_str = Base.Option.value current_version ~default:"[None]" in
    let message =
      "\nVersion in flowconfig that spawned the existing flow server: "
      ^ prev_version_str
      ^ "\nVersion in flowconfig currently: "
      ^ current_version_str
      ^ "\n"
    in
    Lsp_writers.telemetry_log to_stdout message;
    lsp_exit_bad ()
  );
  let start_env =
    let { i_connect_params; i_root; _ } = env.d_ienv in
    CommandUtils.make_env flowconfig flowconfig_name i_connect_params i_root
  in
  let client_handshake =
    let open SocketHandshake in
    ( {
        client_build_id = build_revision;
        client_version = Flow_version.version;
        is_stop_request = false;
        server_should_hangup_if_still_initializing = true;
        version_mismatch_strategy;
      },
      { client_type = Persistent { lsp_init_params = env.d_ienv.i_initialize_params } }
    )
  in

  let conn =
    CommandConnectSimple.connect_once
      ~flowconfig_name
      ~client_handshake
      ~tmp_dir:start_env.CommandConnect.tmp_dir
      start_env.CommandConnect.root
  in
  match conn with
  | Ok (ic, oc) ->
    let i_server_id = env.d_ienv.i_server_id + 1 in
    (* this flag is set to false to prevent restart loops when the flowconfig changes.
       once we successfully reconnect, it should be reset back to true (the default). *)
    let i_can_autostart_after_version_mismatch = true in
    let new_env =
      {
        c_ienv = { env.d_ienv with i_server_id; i_can_autostart_after_version_mismatch };
        c_conn = { ic; oc };
        c_server_status = (ServerStatus.initial_status, None);
        c_about_to_exit_code = None;
        c_is_rechecking = false;
        c_lazy_stats = None;
        c_outstanding_requests_to_server = Lsp.IdSet.empty;
        c_recent_summaries = [];
      }
    in
    let make_metadata method_name =
      {
        LspProt.empty_metadata with
        LspProt.start_wall_time = Unix.gettimeofday ();
        start_server_status = Some (fst new_env.c_server_status);
        start_watcher_status = snd new_env.c_server_status;
        start_json_truncated = Hh_json.(JSON_Object [("method", JSON_String method_name)]);
        lsp_method_name = method_name;
      }
    in
    (* send the initial messages to the server *)
    let () =
      let metadata = make_metadata "synthetic/subscribe" in
      send_to_server new_env LspProt.Subscribe metadata
    in
    let () =
      let settings = new_env.c_ienv.i_config in
      send_configuration_to_server "synthetic/configuration" settings new_env
    in
    let metadata = make_metadata "synthetic/open" in
    let () =
      Lsp.UriMap.iter
        (fun _ { o_open_doc; _ } ->
          let msg =
            NotificationMessage (DidOpenNotification { DidOpen.textDocument = o_open_doc })
          in
          send_lsp_to_server new_env metadata msg)
        env.d_ienv.i_open_files
    in

    (* close the old UI and bring up the new *)
    let new_state = show_connected new_env in
    (* Generate live errors for the newly opened files *)
    Lsp.UriMap.fold
      (fun uri _ state ->
        do_live_diagnostics state (Some LspInteraction.ServerConnected) metadata uri)
      env.d_ienv.i_open_files
      new_state
  (* Server_missing means the lock file is absent, because the server isn't running *)
  | Error (CommandConnectSimple.Server_missing as reason) ->
    let new_env = { env with d_autostart = false; d_server_status = None } in
    if env.d_autostart then
      let start_result = CommandConnect.start_flow_server start_env in
      match start_result with
      | Ok () -> show_connecting reason new_env
      | Error (msg, code) -> show_disconnected (Some code) (Some msg) new_env
    else
      show_disconnected None None new_env
  (* Server_socket_missing means the server is present but lacks its sock
     file. There's a tiny race possibility that the server has created a
     lock but not yet created a sock file. More likely is that the server
     is an old version of the server which doesn't even create the right
     sock file. We'll kill the server now so we can start a new one next.
     And if it was in that race? bad luck... *)
  | Error (CommandConnectSimple.Server_socket_missing as reason) -> begin
    try
      let tmp_dir = start_env.CommandConnect.tmp_dir in
      let root = start_env.CommandConnect.root in
      CommandMeanKill.mean_kill ~flowconfig_name ~tmp_dir root;
      show_connecting reason { env with d_server_status = None }
    with
    | CommandMeanKill.FailedToKill _ ->
      let msg = "An old version of the Flow server is running. Please stop it." in
      show_disconnected None (Some msg) { env with d_server_status = None }
  end
  (* The server exited due to a version mismatch between the lsp and the server. *)
  | Error (CommandConnectSimple.(Build_id_mismatch Server_exited) as reason) ->
    if env.d_autostart then
      show_connecting reason { env with d_server_status = None }
    else
      (* We shouldn't hit this case. When `env.d_autostart` is `false`, we ask the server NOT to
       * die on a version mismatch. *)
      let msg =
        message_with_flow_and_root_name_prefix
          env.d_ienv.i_flowconfig
          "the server was the wrong version"
      in
      show_disconnected None (Some msg) { env with d_server_status = None }
  (* The server and the lsp are different binaries and can't talk to each other. The server is not
     stopping (either because we asked it not to stop or because it is newer than this client). In
     this case, our best option is to stop the lsp and let the IDE start a new lsp with a newer
     binary *)
  | Error CommandConnectSimple.(Build_id_mismatch (Client_should_error { server_version; _ })) ->
    (match Semver.compare server_version Flow_version.version with
    | n when n < 0 ->
      Printf.eprintf
        "Flow: the running server is an older version of Flow (%s) than the LSP (%s), but we're not allowed to stop it"
        server_version
        Flow_version.version
    | 0 ->
      Printf.eprintf
        "Flow: the running server is a different binary with the same version (%s)"
        Flow_version.version
    | _ ->
      Printf.eprintf
        "Flow: the running server is a newer version of Flow (%s) than the LSP (%s)"
        server_version
        Flow_version.version);
    Printf.eprintf
      "LSP is exiting. Hopefully the IDE will start an LSP with the same binary as the server";
    lsp_exit_bad ()
  (* While the server is busy initializing, sometimes we get Server_busy.Fail_on_init
     with a server-status telling us how far it is through init. And sometimes we get
     just ServerStatus.Not_responding if the server was just too busy to give us a
     status update. These are cases where the right version of the server is running
     but it's not speaking to us just now. So we'll keep trying until it's ready. *)
  | Error (CommandConnectSimple.Server_busy (CommandConnectSimple.Fail_on_init st) as reason) ->
    show_connecting reason { env with d_server_status = Some st }
  (* The following codes mean the right version of the server is running so
     we'll retry. They provide no information about the d_server_status of
     the server, so we'll leave it as it was before. *)
  | Error (CommandConnectSimple.Server_busy CommandConnectSimple.Not_responding as reason)
  | Error (CommandConnectSimple.Server_busy CommandConnectSimple.Too_many_clients as reason) ->
    show_connecting reason env

(************************************************************************)
(** Main loop                                                          **)

(************************************************************************)

type log_needed =
  | LogNeeded of LspProt.metadata
  | LogDeferred
  | LogNotNeeded

let rec run ~flowconfig_name ~connect_params =
  let client = Jsonrpc.make_queue () in
  let state = Pre_init connect_params in
  LwtInit.run_lwt (initial_lwt_thread flowconfig_name client state)

and initial_lwt_thread flowconfig_name client state () =
  (* If `prom` in `Lwt.async (fun () -> prom)` resolves to an exception, this function will be
     called *)
  (Lwt.async_exception_hook :=
     fun exn ->
       let exn = Exception.wrap exn in
       let msg = Printf.sprintf "Uncaught async exception: %s" (Exception.to_string exn) in
       FlowExit.(exit ~msg Unknown_error)
  );

  LspInteraction.init ();
  Lwt.async LogFlusher.run;

  main_loop flowconfig_name client state

and main_loop flowconfig_name (client : Jsonrpc.queue) (state : state) : unit Lwt.t =
  (* TODO - delete this line once this loop is fully lwt. At the moment, the idle loop never
     actually does any lwt io so never yields. This starves any asynchronous lwt. This pause call
     just yields *)
  let%lwt () = Lwt.pause () in
  gc_pending_interactions state;
  let%lwt state =
    match%lwt get_next_event state client (parse_json state) with
    | event -> Lwt.return (main_handle flowconfig_name state event)
    | exception e -> Lwt.return (main_handle_error (Exception.wrap e) state None)
  in
  main_loop flowconfig_name client state

and main_handle flowconfig_name (state : state) (event : event) : state =
  let (client_duration, result) =
    with_timer (fun () ->
        try main_handle_unsafe flowconfig_name state event with
        | e -> Error (state, Exception.wrap e)
    )
  in
  match result with
  | Ok (state, LogNeeded metadata) ->
    let open LspProt in
    let client_duration =
      if metadata.client_duration = None then
        Some client_duration
      else
        metadata.client_duration
    in
    let metadata = { metadata with client_duration } in
    main_log_command state metadata;
    state
  | Ok (state, _) -> state
  | Error (state, exn) -> main_handle_error exn state (Some event)

and main_handle_initialized_unsafe flowconfig_name (state : server_state) (event : event) :
    (server_state * log_needed, server_state * Exception.t) result =
  match (state, event) with
  | ( _,
      Client_message
        ((NotificationMessage (DidChangeConfigurationNotification params) as msg), metadata)
    ) ->
    let { DidChangeConfiguration.settings } = params in
    let state =
      match settings with
      | Hh_json.JSON_Null ->
        (* a null notification means we should pull the configs we care about. the "push" model
           is discouraged, so a null notification is normal in VS Code. See
           https://github.com/microsoft/language-server-protocol/issues/567#issuecomment-420589320 *)
        update_ienv (fun ienv -> request_configuration ienv) state
      | i_config ->
        (* update the lsp process's cache *)
        let state = update_ienv (fun ienv -> { ienv with i_config }) state in
        (* forward the notification to the server process *)
        (match state with
        | Connected cenv -> send_lsp_to_server cenv metadata msg
        | Disconnected _ -> ());
        state
    in
    Ok (state, LogNotNeeded)
  | (_, Client_message ((ResponseMessage (id, result) as c), metadata)) ->
    let ienv = get_ienv state in
    (* was it a response to a request issued by lspCommand? *)
    (match get_local_request_handler ienv (id, result) with
    | Some (ienv, handler) ->
      let state = update_ienv (fun _ -> ienv) state in
      Ok (handler state, LogNotNeeded)
    | None ->
      (* if not, it must be a response to a request issued by the server *)
      (match state with
      | Connected cenv ->
        let (state, _) = track_to_server state c in
        let wrapped = decode_wrapped id in
        (* only forward responses if they're to current server *)
        ( if wrapped.server_id = cenv.c_ienv.i_server_id then
          let c = ResponseMessage (wrapped.message_id, result) in
          send_lsp_to_server cenv metadata c
        );
        Ok (state, LogNotNeeded)
      | Disconnected _ ->
        failwith (Printf.sprintf "Response %s has missing handler" (message_name_to_string c))))
  | (_, Client_message (RequestMessage (id, DocumentSymbolRequest params), metadata)) ->
    (* documentSymbols is handled in the client, not the server, since it's
       purely syntax-driven and we'd like it to work even if the server is
       busy or disconnected *)
    let interaction_id = start_interaction ~trigger:(LspInteraction.DocumentSymbol id) state in
    let state = do_documentSymbol state id params in
    log_interaction ~ux:LspInteraction.Responded state interaction_id;
    Ok (state, LogNeeded metadata)
  | (_, Client_message (RequestMessage (id, SelectionRangeRequest params), metadata)) ->
    (* selectionRange is handled in the client, not the server, since it's
       purely syntax-driven and we'd like it to work even if the server is
       busy or disconnected *)
    let interaction_id = start_interaction ~trigger:(LspInteraction.SelectionRange id) state in
    let state = do_selectionRange state id params in
    log_interaction ~ux:LspInteraction.Responded state interaction_id;
    Ok (state, LogNeeded metadata)
  | (Connected cenv, Client_message (c, metadata)) ->
    (* We'll track what's being sent to the server. This might involve some client
       computation work, which we'll profile, and send it over in metadata.
       Note: in the case where c is a cancel-notification for a request that
       was already handled in lspCommand like ShutdownRequest or DocSymbolsRequest
       we'll still forward it; that's okay since server already has to be
       hardened against unrecognized ids in cancel requests. *)
    let (state, { changed_live_uri }) = track_to_server state c in
    let trigger = LspInteraction.trigger_of_lsp_msg c in
    (* Forward the message to the server immediately *)
    let () =
      let interaction_tracking_id =
        Base.Option.map trigger ~f:(fun trigger -> start_interaction ~trigger state)
      in
      send_lsp_to_server cenv { metadata with LspProt.interaction_tracking_id } c
    in
    let state =
      Base.Option.value_map
        changed_live_uri
        ~default:state
        ~f:(do_live_diagnostics state trigger metadata)
    in
    Ok (state, LogDeferred)
  | (_, Client_message (RequestMessage (id, RageRequest), metadata)) ->
    (* How to handle a rage request? If we're connected to a server, then the
       above case will just have forwarded the message on to the server (and
       we'll patch in our own extra information when the server replies). But
       if there's no server then we have to reply here and now. *)
    let result = do_rage flowconfig_name state in
    let response = ResponseMessage (id, RageResult result) in
    let json =
      let key = command_key_of_server_state state in
      Lsp_fmt.print_lsp ~key response
    in
    to_stdout json;
    Ok (state, LogNeeded metadata)
  | (_, Client_message ((NotificationMessage (DidOpenNotification _) as c), metadata))
  | (_, Client_message ((NotificationMessage (DidChangeNotification _) as c), metadata))
  | (_, Client_message ((NotificationMessage (DidSaveNotification _) as c), metadata))
  | (_, Client_message ((NotificationMessage (DidCloseNotification _) as c), metadata)) ->
    let trigger = LspInteraction.trigger_of_lsp_msg c in
    let interaction_id =
      Base.Option.map trigger ~f:(fun trigger -> start_interaction ~trigger state)
    in
    (* these are editor events that happen while disconnected. *)
    let (client_duration, state) =
      with_timer (fun () ->
          let (state, { changed_live_uri }) = track_to_server state c in
          let state =
            Base.Option.value_map
              changed_live_uri
              ~default:state
              ~f:(do_live_diagnostics state trigger metadata)
          in
          state
      )
    in
    (* TODO - In the future if we start running check-contents on DidChange, we should probably
       log Errored instead of Responded for that one *)
    Base.Option.iter interaction_id ~f:(log_interaction ~ux:LspInteraction.Responded state);
    let metadata = { metadata with LspProt.client_duration = Some client_duration } in
    Ok (state, LogNeeded metadata)
  | (Disconnected _, Client_message (NotificationMessage (CancelRequestNotification _), _metadata))
    ->
    (* we cancel all outstanding requests when the server disconnects. if the client
       also cancels one of those requests, just ignore it. *)
    Ok (state, LogNotNeeded)
  | (Disconnected _, Client_message (c, metadata)) ->
    let interaction_id =
      LspInteraction.trigger_of_lsp_msg c
      |> Base.Option.map ~f:(fun trigger -> start_interaction ~trigger state)
    in
    let (state, _) = track_to_server state c in
    let exn =
      let method_ = Lsp_fmt.denorm_message_to_string c in
      Error.LspException
        {
          Error.code = Error.RequestCancelled;
          message = "Server not connected; can't handle " ^ method_;
          data = None;
        }
    in
    Base.Option.iter interaction_id ~f:(log_interaction ~ux:LspInteraction.Errored state);
    (match c with
    | RequestMessage (id, _request) ->
      let e = Lsp_fmt.error_of_exn exn in
      let outgoing = ResponseMessage (id, ErrorResult (e, "")) in
      let key = command_key_of_server_state state in
      to_stdout (Lsp_fmt.print_lsp ~include_error_stack_trace:false ~key outgoing);
      let metadata =
        let error_info = Some (LspProt.ExpectedError, e.Error.message, Utils.Callstack "") in
        { metadata with LspProt.error_info }
      in
      Ok (state, LogNeeded metadata)
    | _ -> Error (state, Exception.wrap_unraised exn))
  | (Connected cenv, Server_message LspProt.(NotificationFromServer (ServerExit exit_code))) ->
    let state = Connected { cenv with c_about_to_exit_code = Some exit_code } in
    Ok (state, LogNotNeeded)
  | (Connected cenv, Server_message LspProt.(RequestResponse (LspFromServer msg, metadata))) ->
    let (state, metadata, ux) =
      match msg with
      | None -> (state, metadata, LspInteraction.Responded)
      | Some outgoing ->
        let state = track_from_server state outgoing in
        let (outgoing, metadata, ux) =
          match outgoing with
          | RequestMessage (id, request) ->
            let wrapped = { server_id = cenv.c_ienv.i_server_id; message_id = id } in
            (RequestMessage (encode_wrapped wrapped, request), metadata, LspInteraction.Responded)
          | ResponseMessage (id, RageResult items) ->
            (* we'll zero out the "client_duration", which at the moment represents client-side
               work we did before sending out the request. By zeroing it out now, it'll get
               filled out with the client-side work that gets done right here and now. *)
            let metadata = { metadata with LspProt.client_duration = None } in
            let ux = LspInteraction.Responded in
            (ResponseMessage (id, RageResult (items @ do_rage flowconfig_name state)), metadata, ux)
          | ResponseMessage (_, ErrorResult (e, _)) ->
            let ux =
              if e.Error.code = Error.RequestCancelled then
                LspInteraction.Canceled
              else
                LspInteraction.Errored
            in
            (outgoing, metadata, ux)
          | _ -> (outgoing, metadata, LspInteraction.Responded)
        in
        let outgoing = selectively_omit_errors LspProt.(metadata.lsp_method_name) outgoing in
        let key = command_key_of_server_state state in
        to_stdout (Lsp_fmt.print_lsp ~include_error_stack_trace:false ~key outgoing);
        (state, metadata, ux)
    in
    Base.Option.iter metadata.LspProt.interaction_tracking_id ~f:(log_interaction ~ux state);
    Ok (state, LogNeeded metadata)
  | ( Connected _,
      Server_message
        LspProt.(
          RequestResponse (UncaughtException { request; exception_constructor; stack }, metadata))
    ) ->
    (* The Flow server hit an uncaught exception while processing request *)
    let metadata =
      let open LspProt in
      {
        metadata with
        error_info = Some (UnexpectedError, exception_constructor, Utils.Callstack stack);
      }
    in

    let outgoing =
      match request with
      | LspProt.LspToServer (RequestMessage (id, _)) ->
        (* We need to tell the client that this request hit an unexpected error *)
        let e =
          {
            Lsp.Error.code = Lsp.Error.UnknownErrorCode;
            message =
              "Flow encountered an unexpected error while handling this request. "
              ^ "See the Flow logs for more details.";
            data = None;
          }
        in

        Some (ResponseMessage (id, ErrorResult (e, stack)))
      | LspProt.Subscribe
      | LspProt.LspToServer _ ->
        (* We'll just send a telemetry notification, since the client wasn't expecting a response *)
        let text =
          let code = Error.code_to_enum Lsp.Error.UnknownErrorCode in
          Printf.sprintf "%s [%i]\n%s" exception_constructor code stack
        in
        Some
          (NotificationMessage
             (TelemetryNotification { LogMessage.type_ = MessageType.ErrorMessage; message = text })
          )
      | LspProt.LiveErrorsRequest _ ->
        (* LiveErrorsRequest are internal-only requests. If it fails we will log, but we don't
             need to notify the client *)
        None
    in
    let key = command_key_of_server_state state in
    Base.Option.iter outgoing ~f:(fun outgoing ->
        let outgoing = selectively_omit_errors LspProt.(metadata.lsp_method_name) outgoing in
        to_stdout (Lsp_fmt.print_lsp ~include_error_stack_trace:false ~key outgoing)
    );
    Base.Option.iter
      metadata.LspProt.interaction_tracking_id
      ~f:(log_interaction ~ux:LspInteraction.Errored state);
    Ok (state, LogNeeded metadata)
  | ( (Connected cenv as state),
      Server_message LspProt.(NotificationFromServer (Errors { diagnostics; errors_reason }))
    ) ->
    (* A note about the errors reported by this server message:
       While a recheck is in progress, between StartRecheck and EndRecheck,
       the server will periodically send errors+warnings. These are additive
       to the errors which have previously been reported. Once the recheck
       has finished then the server will send a new exhaustive set of errors.
       At this opportunity we should erase all errors not in this set.
       This differs considerably from the semantics of LSP publishDiagnostics
       which says "whenever you send publishDiagnostics for a file, that
       now contains the complete truth for that file." *)
    let () =
      let end_state = collect_interaction_state state in
      LspInteraction.log_pushed_errors ~end_state ~errors_reason
    in
    let state =
      Connected cenv
      |> update_errors
           ( if cenv.c_is_rechecking then
             LspErrors.add_streamed_server_errors_and_send to_stdout diagnostics
           else
             LspErrors.set_finalized_server_errors_and_send to_stdout diagnostics
           )
    in
    Ok (state, LogNotNeeded)
  | ( Connected _,
      Server_message
        LspProt.(
          RequestResponse
            (LiveErrorsResponse (Ok { live_diagnostics; live_errors_uri = uri }), metadata))
    ) ->
    let file_is_still_open = get_open_files state |> Lsp.UriMap.mem uri in
    let state =
      if file_is_still_open then (
        (* Only set the live non-parse errors if the file is still open. If it's been closed since
           the request was sent, then we will just ignore the response *)
        Base.Option.iter
          metadata.LspProt.interaction_tracking_id
          ~f:(log_interaction ~ux:(LspInteraction.PushedLiveNonParseErrors uri) state);
        FlowEventLogger.live_non_parse_errors
          ~request:(metadata.LspProt.start_json_truncated |> Hh_json.json_to_string)
          ~data:
            Hh_json.(
              JSON_Object
                (("uri", JSON_String (Lsp.DocumentUri.to_string uri))
                :: ("error_count", JSON_Number (List.length live_diagnostics |> string_of_int))
                :: metadata.LspProt.extra_data
                )
              |> json_to_string
            )
          ~wall_start:metadata.LspProt.start_wall_time;

        update_errors
          (LspErrors.set_live_non_parse_errors_and_send to_stdout uri live_diagnostics)
          state
      ) else (
        Base.Option.iter
          metadata.LspProt.interaction_tracking_id
          ~f:(log_interaction ~ux:LspInteraction.ErroredPushingLiveNonParseErrors state);
        FlowEventLogger.live_non_parse_errors_failed
          ~request:(metadata.LspProt.start_json_truncated |> Hh_json.json_to_string)
          ~data:
            Hh_json.(
              JSON_Object
                [
                  ("uri", JSON_String (Lsp.DocumentUri.to_string uri));
                  ("reason", JSON_String "File no longer open");
                ]
              |> json_to_string
            )
          ~wall_start:metadata.LspProt.start_wall_time;
        state
      )
    in
    Ok (state, LogNotNeeded)
  | ( Connected _,
      Server_message
        LspProt.(
          RequestResponse
            ( LiveErrorsResponse
                (Error
                  {
                    LspProt.live_errors_failure_kind;
                    live_errors_failure_reason;
                    live_errors_failure_uri;
                  }
                  ),
              metadata
            ))
    ) ->
    let ux =
      match live_errors_failure_kind with
      | LspProt.Canceled_error_response -> LspInteraction.CanceledPushingLiveNonParseErrors
      | LspProt.Errored_error_response -> LspInteraction.ErroredPushingLiveNonParseErrors
    in
    Base.Option.iter metadata.LspProt.interaction_tracking_id ~f:(log_interaction ~ux state);
    FlowEventLogger.live_non_parse_errors_failed
      ~request:(metadata.LspProt.start_json_truncated |> Hh_json.json_to_string)
      ~data:
        Hh_json.(
          JSON_Object
            [
              ("uri", JSON_String (live_errors_failure_uri |> Lsp.DocumentUri.to_string));
              ("reason", JSON_String live_errors_failure_reason);
            ]
          |> json_to_string
        )
      ~wall_start:metadata.LspProt.start_wall_time;
    Ok (state, LogNotNeeded)
  | (Connected cenv, Server_message LspProt.(NotificationFromServer StartRecheck)) ->
    let start_state = collect_interaction_state state in
    LspInteraction.recheck_start ~start_state;
    let cenv = { cenv with c_is_rechecking = true; c_lazy_stats = None } in
    let cenv = show_connected_status cenv in
    Ok (Connected cenv, LogNotNeeded)
  | (Connected cenv, Server_message LspProt.(NotificationFromServer (EndRecheck lazy_stats))) ->
    let state =
      let cenv = { cenv with c_is_rechecking = false; c_lazy_stats = Some lazy_stats } in
      let cenv = show_connected_status cenv in
      Connected cenv
    in
    let open_files = get_open_files state in
    let method_name = "synthetic/endRecheck" in
    let metadata =
      {
        LspProt.empty_metadata with
        LspProt.start_wall_time = Unix.gettimeofday ();
        start_server_status = Some (fst cenv.c_server_status);
        start_watcher_status = snd cenv.c_server_status;
        start_json_truncated = Hh_json.(JSON_Object [("method", JSON_String method_name)]);
        lsp_method_name = method_name;
      }
    in
    Lsp.UriMap.iter
      (fun uri _ -> send_to_server cenv (LspProt.LiveErrorsRequest uri) metadata)
      open_files;

    Ok (state, LogNotNeeded)
  | (Connected cenv, Server_message LspProt.(NotificationFromServer (Telemetry event))) ->
    let cenv = update_recent_summaries cenv event in
    Ok (Connected cenv, LogNotNeeded)
  | (Connected cenv, Server_message LspProt.(NotificationFromServer (Please_hold status))) ->
    let (server_status, watcher_status) = status in
    let cenv = { cenv with c_server_status = (server_status, Some watcher_status) } in
    let cenv = show_connected_status cenv in
    Ok (Connected cenv, LogNotNeeded)
  | (Disconnected env, Tick) ->
    (* the flow binary may have changed since we (the lsp process) were started.
       on our first attempt to connect, version_mismatch_strategy is set to
       Always_stop_server: since we just spawned, we can assume that we are the
       most up-to-date version of the binary. if we connect to an already-running
       server and the version mismatches, always stop the server.

       after that, if we ever get a version mismatch then the server must have
       restarted more recently than we have, so _it_ is the most up-to-date binary
       and we should exit.

       note that if the initial case happens and we stop the already-running server,
       try_connect doesn't immediately connect to it; we try again on the next tick
       (you are here!). if we somehow mismatch again -- e.g. the flow binary was
       updated immediately after the lsp was spawned, so our assumption that we were
       the latest binary was false -- we'll exit. the chances of this race happening
       repeatedly is virtually impossible. *)
    let version_mismatch_strategy = SocketHandshake.Error_client in
    let server_state = try_connect ~version_mismatch_strategy flowconfig_name env in
    Ok (server_state, LogNotNeeded)
  | (Disconnected _, Server_message _) ->
    (* this is impossible, a disconnected server can't send a message *)
    Ok (state, LogNotNeeded)
  | (_, Tick) -> Ok (state, LogNotNeeded)

and main_handle_unsafe flowconfig_name (state : state) (event : event) :
    (state * log_needed, state * Exception.t) result =
  let event = convert_to_client_uris state event in
  match (state, event) with
  | ( Pre_init i_connect_params,
      Client_message (RequestMessage (id, InitializeRequest i_initialize_params), metadata)
    ) ->
    let i_root = Lsp_helpers.get_root i_initialize_params |> File_path.make in
    (* TODO: use FlowConfig.get directly and send errors/warnings to the client instead
        of logging to stderr and exiting. *)
    let flowconfig = read_flowconfig_from_disk flowconfig_name i_root in
    let d_ienv =
      {
        i_initialize_params;
        i_connect_params;
        i_root;
        i_version = FlowConfig.required_version flowconfig;
        i_can_autostart_after_version_mismatch = true;
        i_server_id = 0;
        i_outstanding_local_requests = IdMap.empty;
        i_outstanding_local_handlers = IdMap.empty;
        i_outstanding_requests_from_server = WrappedMap.empty;
        i_isConnected = false;
        i_status = Never_shown;
        i_open_files = Lsp.UriMap.empty;
        i_errors = LspErrors.empty;
        i_config = Hh_json.JSON_Null;
        i_flowconfig = flowconfig;
      }
    in
    FlowInteractionLogger.set_server_config
      ~timeout_log_saving:(SMap.find_opt "timeout" (FlowConfig.log_saving flowconfig))
      ~flowconfig_name
      ~root:i_root
      ~root_name:(FlowConfig.root_name flowconfig);

    (* If the version in .flowconfig is simply incompatible with our current
       binary then it doesn't even make sense for us to start up. And future
       attempts by the client to launch us will fail as well. Clients which
       receive the following response are expected to shut down their LSP.

       see InitializeError in the LSP spec and
       https://github.com/microsoft/vscode-languageserver-node/blob/859f626f61e854ddbd9b132fad508219a4ed77b5/client/src/common/client.ts#L3049-L3065 *)
    let required_version = FlowConfig.required_version flowconfig in
    begin
      match CommandUtils.check_version required_version with
      | Ok () -> ()
      | Error msg ->
        raise
          (Error.LspException
             {
               Error.code = Error.ServerErrorStart;
               message = msg;
               data = Some Hh_json.(JSON_Object [("retry", JSON_Bool false)]);
             }
          )
    end;
    let response = ResponseMessage (id, InitializeResult (do_initialize i_initialize_params)) in
    let json =
      let key = command_key_of_ienv d_ienv in
      Lsp_fmt.print_lsp ~key response
    in
    to_stdout json;

    let d_ienv =
      if Lsp_helpers.supports_configuration i_initialize_params then
        d_ienv |> request_configuration |> subscribe_to_config_changes
      else
        d_ienv
    in

    (* there may be an already-running flow server that's running a binary that has since
       changed on disk. since we (the lsp process) were just spawned, we are using the
       more up-to-date binary, so if we're a different binary than the server, the server
       should exit so we can restart a new one. *)
    let version_mismatch_strategy = SocketHandshake.Always_stop_server in

    let env = { d_ienv; d_autostart = true; d_server_status = None } in
    Ok (Initialized (try_connect ~version_mismatch_strategy flowconfig_name env), LogNeeded metadata)
  | (_, Client_message (NotificationMessage InitializedNotification, _metadata)) ->
    Ok (state, LogNotNeeded)
  | (_, Client_message (NotificationMessage SetTraceNotification, _metadata))
  | (_, Client_message (NotificationMessage LogTraceNotification, _metadata)) ->
    (* specific to VSCode logging *)
    Ok (state, LogNotNeeded)
  | (_, Client_message (RequestMessage (id, ShutdownRequest), _metadata)) ->
    (* the shutdown request gives us a chance to shut down in an orderly way, like if
       we need to persist state. we have to respond to the client once we're done with
       that, and then the client will then send an exit notification to actually
       shut down the connection.

       we just disconnect from the server and reply right away. *)
    begin
      match state with
      | Initialized (Connected env) -> close_conn env
      | _ -> ()
    end;
    let response = ResponseMessage (id, ShutdownResult) in
    let json =
      let key = command_key_of_state state in
      Lsp_fmt.print_lsp ~key response
    in
    to_stdout json;
    Ok (Post_shutdown, LogNotNeeded)
  | (_, Client_message (NotificationMessage ExitNotification, _metadata)) ->
    if state = Post_shutdown then
      lsp_exit_ok ()
    else
      lsp_exit_bad ()
  | (Pre_init _, Client_message _) ->
    raise
      (Error.LspException
         {
           Error.code = Error.ServerNotInitialized;
           message = "Server not initialized";
           data = None;
         }
      )
  | (Initialized server_state, _) ->
    (match main_handle_initialized_unsafe flowconfig_name server_state event with
    | Ok (server_state, log_needed) -> Ok (Initialized server_state, log_needed)
    | Error (server_state, exn) -> Error (Initialized server_state, exn))
  | (Post_shutdown, Client_message (_, _metadata)) ->
    raise
      (Error.LspException
         { Error.code = Error.RequestCancelled; message = "Server shutting down"; data = None }
      )
  | (Pre_init _, Server_message _)
  | (Post_shutdown, Server_message _) ->
    (* this is impossible. get_next_event can only read a server event from
       an Initialized state. *)
    Ok (state, LogNotNeeded)
  | (_, Tick) -> Ok (state, LogNotNeeded)

and main_log_command (state : state) (metadata : LspProt.metadata) : unit =
  let {
    LspProt.start_json_truncated;
    start_wall_time = wall_start;
    server_profiling;
    client_duration;
    extra_data;
    start_lsp_state;
    start_lsp_state_reason;
    start_server_status;
    start_watcher_status;
    server_logging_context;
    error_info;
    lsp_method_name = method_name;
    interaction_tracking_id = _;
    lsp_id;
    activity_key;
  } =
    metadata
  in
  let client_context = FlowEventLogger.get_context () in
  let request_id =
    let default = "notif" in
    let f = Lsp_fmt.id_to_string in
    Base.Option.value_map lsp_id ~default ~f
  in
  let request = start_json_truncated |> Hh_json.json_to_string in
  let persistent_context =
    let start_server_status =
      Base.Option.map start_server_status ~f:(ServerStatus.string_of_status ~terse:true)
    in
    let start_watcher_status =
      Base.Option.map start_watcher_status ~f:FileWatcherStatus.string_of_status
    in
    Some
      {
        FlowEventLogger.start_lsp_state;
        start_lsp_state_reason;
        start_server_status;
        start_watcher_status;
      }
  in
  (* gather any recent typechecks that finished after the request had arrived *)
  let delays =
    match state with
    | Initialized (Connected cenv) ->
      Base.List.filter_map cenv.c_recent_summaries ~f:(fun (t, s) ->
          if t > wall_start then
            Some s
          else
            None
      )
    | _ -> []
  in
  let root =
    match state with
    | Pre_init _
    | Post_shutdown ->
      File_path.dummy_path
    | Initialized state -> get_root state
  in
  let persistent_delay =
    if delays = [] then
      None
    else
      Some (log_of_summaries ~root delays)
  in
  match error_info with
  | None ->
    FlowEventLogger.persistent_command_success
      ~server_logging_context
      ~request_id
      ~method_name
      ~request
      ~extra_data
      ~client_context
      ~persistent_context
      ~persistent_delay
      ~server_profiling
      ~client_duration
      ~wall_start
      ~activity_key
      ~error:None
  | Some (LspProt.ExpectedError, msg, stack) ->
    FlowEventLogger.persistent_command_success
      ~server_logging_context
      ~request_id
      ~method_name
      ~request
      ~extra_data
      ~client_context
      ~persistent_context
      ~persistent_delay
      ~server_profiling
      ~client_duration
      ~wall_start
      ~activity_key
      ~error:(Some (msg, stack))
  | Some (LspProt.UnexpectedError, msg, stack) ->
    FlowEventLogger.persistent_command_failure
      ~server_logging_context
      ~request
      ~extra_data
      ~client_context
      ~persistent_context
      ~persistent_delay
      ~server_profiling
      ~client_duration
      ~wall_start
      ~activity_key
      ~error:(msg, stack)

and main_log_error ~(expected : bool) (msg : string) (stack : string) (event : event option) : unit
    =
  let error = (msg, Utils.Callstack stack) in
  let client_context = FlowEventLogger.get_context () in
  let (request, activity_key) =
    match event with
    | Some (Client_message (_, metadata)) ->
      let request = metadata.LspProt.start_json_truncated |> Hh_json.json_to_string in
      let activity_key = metadata.LspProt.activity_key in
      (Some request, activity_key)
    | Some (Server_message _)
    | Some Tick
    | None ->
      (None, None)
  in
  if expected then
    FlowEventLogger.persistent_expected_error ~request ~client_context ~activity_key ~error
  else
    FlowEventLogger.persistent_unexpected_error ~request ~client_context ~activity_key ~error

and main_handle_error (exn : Exception.t) (state : state) (event : event option) : state =
  let stack = Exception.get_full_backtrace_string 500 exn in
  match Exception.unwrap exn with
  | Server_fatal_connection_exception _edata when state = Post_shutdown -> state
  | Server_fatal_connection_exception { Marshal_tools.stack = remote_stack; message } ->
    (* log the error *)
    let stack = remote_stack ^ "---\n" ^ stack in
    main_log_error ~expected:true ("[Server fatal] " ^ message) stack event;

    (* report that we're disconnected to telemetry/connectionStatus *)
    let state =
      match state with
      | Initialized (Connected env) ->
        let i_isConnected =
          Lsp_writers.notify_connectionStatus
            env.c_ienv.i_initialize_params
            to_stdout
            env.c_ienv.i_isConnected
            false
        in
        let env = { env with c_ienv = { env.c_ienv with i_isConnected } } in
        Initialized (Connected env)
      | _ -> state
    in
    (* send the error report *)
    let code =
      match state with
      | Initialized (Connected cenv) -> cenv.c_about_to_exit_code
      | _ -> None
    in
    let code = Base.Option.value_map code ~f:FlowExit.to_string ~default:"" in
    let report = Printf.sprintf "Server fatal exception: [%s] %s\n%s" code message stack in
    Lsp_writers.telemetry_error to_stdout report;
    let (d_autostart, d_ienv) =
      match state with
      | Initialized
          (Connected
            {
              c_ienv;
              c_about_to_exit_code =
                Some FlowExit.(Flowconfig_changed | Server_out_of_date | Lock_stolen);
              _;
            }
            ) ->
        (* we allow at most one autostart_after_version_mismatch per
           instance so as to avoid getting into version battles. *)
        let previous = c_ienv.i_can_autostart_after_version_mismatch in
        let d_ienv = { c_ienv with i_can_autostart_after_version_mismatch = false } in
        (previous, d_ienv)
      | Initialized
          (Connected { c_ienv; c_about_to_exit_code = Some FlowExit.File_watcher_missed_changes; _ })
        ->
        (* TODO: we should fix the monitor to just handle this without exiting!
           in the meantime, just restart the monitor, which will recrawl. *)
        (true, c_ienv)
      | Initialized (Connected { c_ienv; _ }) -> (false, c_ienv)
      | Initialized (Disconnected { d_ienv; _ }) -> (false, d_ienv)
      | Pre_init _
      | Post_shutdown ->
        failwith "Unexpected server error in inapplicable state"
    in
    let env = { d_ienv; d_autostart; d_server_status = None } in
    (match state with
    | Initialized server_state -> ignore (dismiss_tracks server_state)
    | Pre_init _
    | Post_shutdown ->
      ());
    let state = Initialized (Disconnected env) in
    state
  | Client_recoverable_connection_exception { Marshal_tools.stack = remote_stack; message } ->
    let stack = remote_stack ^ "---\n" ^ stack in
    main_log_error ~expected:true ("[Client recoverable] " ^ message) stack event;
    let report = Printf.sprintf "Client exception: %s\n%s" message stack in
    Lsp_writers.telemetry_error to_stdout report;
    state
  | Client_fatal_connection_exception { Marshal_tools.stack = remote_stack; message } ->
    let stack = remote_stack ^ "---\n" ^ stack in
    main_log_error ~expected:true ("[Client fatal] " ^ message) stack event;
    Printf.eprintf "Client fatal exception: %s\n%s\n%!" message stack;
    lsp_exit_bad ()
  | e ->
    let e = Lsp_fmt.error_of_exn e in
    main_log_error ~expected:true ("[FlowLSP] " ^ e.Error.message) stack event;
    let text =
      let code = Error.code_to_enum e.Error.code in
      Printf.sprintf "FlowLSP exception %s [%i]\n%s" e.Error.message code stack
    in
    let () =
      match event with
      | Some (Client_message (RequestMessage (id, _request), _metadata)) ->
        let key = command_key_of_state state in
        let json = Lsp_fmt.print_lsp_response ~key id (ErrorResult (e, stack)) in
        to_stdout json
      | _ -> Lsp_writers.telemetry_error to_stdout text
    in
    state
