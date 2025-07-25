(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Base

let spf = Printf.sprintf

(*
 * Module for us to interface with Watchman, a file watching service.
 * https://facebook.github.io/watchman/
 *
 * TODO:
 *   * Connect directly to the Watchman server socket instead of spawning
 *     a client process each time
 *   * Use the BSER protocol for enhanced performance
 *)

type error_kind =
  | Not_installed of { path: string }
  | Socket_unavailable of { msg: string }
  | Response_error of {
      request: string option;
      response: string;
      msg: string;
    }
  | Fresh_instance
  | Subscription_canceled
  | Unsupported_watch_roots of {
      roots: string list;  (** roots successfully returned by watch-project *)
      failed_paths: error_kind SMap.t;
          (** map from paths we tried to watch but couldn't figure out the root for, to the error Watchman gave (a Response_error) *)
    }
      (** Say we need to watch paths /foo/bar and /foo/baz. A few things could happen.
        Not errors:
        - /foo is the watchman root, so we successfully watch /foo with relative paths bar and baz
        - /foo is the watchman root, but bar doesn't exist. we'd guess that bar is relative to the root
        Errors:
        - /foo/bar and /foo/baz are both watchman roots. we error because we can't watch multiple roots
        - /foo/bar is the watchman root, but /foo/baz is not. we error with roots = [/foo/bar],
          failed_paths = [/foo/baz]. *)

type failure =
  | Dead
  | Restarted

let log ?request ?response msg =
  let response = Option.map ~f:(String_utils.truncate 100000) response in
  let () = FlowEventLogger.watchman_error ?request ?response msg in
  let () = Hh_logger.error "%s" msg in
  ()

let rec log_error = function
  | Not_installed { path } ->
    let msg = spf "watchman not found on PATH: %s" path in
    log msg
  | Socket_unavailable { msg } -> log msg
  | Response_error { request; response; msg } -> log ?request ~response msg
  | Fresh_instance -> log "Watchman missed some changes"
  | Subscription_canceled -> log "Subscription canceled by watchman"
  | Unsupported_watch_roots { roots; failed_paths } ->
    (match roots with
    | _ :: _ :: _ ->
      let msg =
        spf
          "Can't watch paths across multiple Watchman watch_roots. Found %d watch roots:\n%s"
          (List.length roots)
          (String.concat ~sep:"\n" roots)
      in
      log msg
    | _ ->
      let rev_paths =
        SMap.fold
          (fun path err acc ->
            (* we stored the Watchman response error, and log it here only when it's
               a real problem (vs when we can guess the relative path) *)
            log_error err;
            path :: acc)
          failed_paths
          []
      in
      let path_list = String.concat ~sep:"\n" (List.rev rev_paths) in
      let msg =
        match roots with
        | [root] -> spf "Found watch root %s, but could not watch paths:\n%s" root path_list
        | _ -> spf "Cannot deduce watch root for paths:\n%s" path_list
      in
      log msg)

type subscribe_mode =
  | All_changes
  | Defer_changes

type timeout = float option

type init_settings = {
  debug_logging: bool;
  defer_states: string list;  (** defer notifications while these states are asserted *)
  expression_terms: Hh_json.json list;  (** See watchman expression terms. *)
  mergebase_with: string;  (** symbolic commit to find changes against *)
  roots: File_path.t list;
  should_track_mergebase: bool;
  subscribe_mode: subscribe_mode;
  subscription_prefix: string;
  sync_timeout: int option;
}

type pushed_changes =
  (*
   * State name and metadata.
   *
   * For example:
   *   State name: "hg.update"
   * Metadata:
   *   {
   *    "partial":false,
   *    "rev":"780dab9ff0a01691c9b18a5ee1194810e555c78b",
   *    "distance":2,
   *    "status":"ok"
   *   }
   *
   * Note: The distance is HG Revision distance, not SVN revision distance.
   *)
  | State_enter of string * Hh_json.json option
  | State_leave of string * Hh_json.json option
  | Files_changed of {
      changes: SSet.t;  (** Files that changed *)
      changed_mergebase: bool option;
          (** Whether the mergebase changed ([None] if we weren't tracking the mergebase). *)
    }
      (** Notification that files changed. This differs from [Missed_changes]
          because [changes] includes all of the files that have changed on disk,
          even the upstream changes between the mergebases. This can be used to
          decide whether to process all of the changes, or re-init on the new
          mergebase. *)
  | Missed_changes of {
      prev_mergebase: string;  (** Previous mergebase *)
      mergebase: string;  (** New mergebase *)
      changes_since_mergebase: SSet.t;  (** Files that are changed locally since the new mergebase *)
    }
      (** Notification that Watchman missed some changes (it restarted or
          overflowed). Includes the mergebase and the files that have changed
          since the new mergebase. This differs from [Files_changed] in that
          it's not a complete list of the files that changed on disk. It isn't
          enough for us to update incrementally, but it could be used to re-init
          on top of the new mergebase. *)

module Capability = struct
  type t =
    | Scm_since
    | Scm_hg
    | Scm_git
  [@@deriving ord]

  let to_string = function
    | Scm_since -> "scm-since"
    | Scm_git -> "scm-git"
    | Scm_hg -> "scm-hg"

  let all = [Scm_since; Scm_hg; Scm_git]

  module Set = Flow_set.Make (struct
    type nonrec t = t

    let compare = compare
  end)
end

module Jget = Hh_json_helpers.Jget
module J = Hh_json_helpers.AdhocJsonHelpers

let json_of_string str =
  try Ok (Hh_json.json_of_string str) with
  | Hh_json.Syntax_error err ->
    let msg = spf "Failed to parse string as JSON: %s" err in
    Error msg

(** Parses a watchman response into JSON and checks for errors *)
let parse_response =
  let log_warnings obj =
    match Jget.string_opt (Some obj) "warning" with
    | None -> ()
    | Some warning ->
      FlowEventLogger.watchman_warning warning;
      Hh_logger.log "Watchman warning: %s\n" warning
  in
  (* Looks for common errors in watchman responses *)
  let handle_errors obj =
    match Jget.string_opt (Some obj) "error" with
    | None -> Ok obj
    | Some error -> Error error
  in
  fun ~debug_logging output ->
    if debug_logging then Hh_logger.info "Watchman response: %s" output;
    let open Result.Let_syntax in
    let%bind json = json_of_string output in
    log_warnings json;
    handle_errors json

type conn = Buffered_line_reader_lwt.t * Lwt_io.output_channel

(** The number of times to try to re-establish our persistent subscription.
    This number is pretty arbitrary. Mostly we just need some cap, but due
    to [backoff_delay] we end up sleeping about 3 minutes total which seems
    reasonable. *)
let max_reinit_attempts = 8

(** The number of times that [get_changes] is allowed to fail in a row before
    we decide that Watchman is borked and give up. This is guarding against
    a scenario where we are able to successfully reinit, but then our
    persistent connection keeps having problems (getting closed, invalid
    responses, etc) without ever having a successful response in between. *)
let max_retry_attempts = 3

(** Watchman watches a single root folder, and we may only care about some paths
    within it. All queries have to be against the root, and include terms to
    limit it to just the sub-paths we want. *)
type watch = {
  watch_root: string;
  watched_path_expression_terms: Hh_json.json option;
}

type dead_env = {
  (* Will reuse original settings to reinitializing watchman subscription. *)
  prior_settings: init_settings;
  dead_since: float;
  prior_clockspec: string;
  prior_watch_root: string;
}

type env = {
  mutable clockspec: string;
      (** See https://facebook.github.io/watchman/docs/clockspec.html
          This is also used to reliably detect a crashed watchman. Watchman has a
          facility to detect watchman process crashes between two "since" queries. *)
  mutable finished_an_hg_update: bool;
      (** This is set to true when leaving an hg.update state on our subscription.
          It is used when we get the next Files_changed event to check if the
          changes are due to an hg update, and then reset to false. *)
  mutable mergebase: string option;
      (** Keeps track of the current mergebase, which we use to know when the
          mergebase changes. *)
  conn: conn;
  settings: init_settings;
  should_track_mergebase: bool;
  subscription: string;
  vcs: Vcs.t option;
  watch: watch;
}

let dead_env_from_alive env =
  {
    prior_settings = env.settings;
    dead_since = Unix.gettimeofday ();
    (* When we start a new watchman connection, we continue to use the prior
     * clockspec. If the same watchman server is still alive, then all is
     * good. If not, the clockspec allows us to detect whether a new watchman
     * server had to be started. See also "is_fresh_instance" on watchman's
     * "since" response. *)
    prior_clockspec = env.clockspec;
    prior_watch_root = env.watch.watch_root;
  }

(****************************************************************************)
(* JSON methods. *)
(****************************************************************************)

(** Projects down from the boolean error monad into booleans.
    Error states go to false, values are projected directly. *)
let project_bool m =
  match m with
  | Ok (v, _) -> v
  | Error _ -> false

let response_error_of_json ?query ~response msg =
  let request = Option.map ~f:Hh_json.json_to_string query in
  let response = Hh_json.json_to_string response in
  Response_error { request; response; msg }

let get_string_prop ?query prop json =
  let open Hh_json.Access in
  match return json >>= get_string prop with
  | Ok (result, _keytrace) -> Ok result
  | Error err ->
    let msg = access_failure_to_string err in
    Error (response_error_of_json ?query ~response:json msg)

let clock { watch_root; _ } = J.strlist ["clock"; watch_root]

type watch_command =
  | Subscribe
  | Query

(** Conjunction of extra_expressions and expression_terms. *)
let request_json ?(extra_kv = []) ?(extra_expressions = []) watchman_command env =
  Hh_json.(
    let command =
      match watchman_command with
      | Subscribe -> "subscribe"
      | Query -> "query"
    in
    let header =
      [JSON_String command; JSON_String env.watch.watch_root]
      @
      match watchman_command with
      | Subscribe -> [JSON_String env.subscription]
      | _ -> []
    in
    let expressions = extra_expressions @ env.settings.expression_terms in
    let expressions =
      match env.watch.watched_path_expression_terms with
      | Some terms -> terms :: expressions
      | None -> expressions
    in
    assert (not (List.is_empty expressions));
    let extra_kv =
      match env.settings.sync_timeout with
      | Some sync_timeout -> ("sync_timeout", JSON_Number (Int.to_string sync_timeout)) :: extra_kv
      | None -> extra_kv
    in
    let directives =
      [
        JSON_Object
          (extra_kv
          @ [
              ("fields", J.strlist ["name"]);
              (* Watchman doesn't allow an empty allof expression. But expressions is never empty *)
              ("expression", J.pred "allof" expressions);
            ]
          );
      ]
    in
    let request = JSON_Array (header @ directives) in
    request
  )

let get_changes_since_mergebase_query env =
  let mergebase_with = env.settings.mergebase_with in
  let extra_kv =
    [
      ( "since",
        Hh_json.JSON_Object
          [("scm", Hh_json.JSON_Object [("mergebase-with", Hh_json.JSON_String mergebase_with)])]
      );
    ]
  in
  request_json ~extra_kv Query env

let subscribe_query env =
  let since = ("since", Hh_json.JSON_String env.clockspec) in
  let empty_on_fresh_instance = ("empty_on_fresh_instance", Hh_json.JSON_Bool true) in
  let mode =
    let states = "hg.update" :: env.settings.defer_states in
    match env.settings.subscribe_mode with
    | All_changes -> []
    | Defer_changes -> [("defer", J.strlist states)]
  in
  request_json ~extra_kv:(since :: empty_on_fresh_instance :: mode) Subscribe env

(** We filter all responses from get_changes through this. This is to detect
   * Watchman server crashes.
   *
   * See also Watchman docs on "since" query parameter. *)
let is_fresh_instance_response obj =
  Hh_json.Access.(return obj >>= get_bool "is_fresh_instance" |> project_bool)

let supports_scm_queries caps vcs =
  let open Capability in
  Set.mem Scm_since caps
  &&
  match vcs with
  | Some Vcs.Hg -> Set.mem Scm_hg caps
  | Some Vcs.Git -> Set.mem Scm_git caps
  | None -> false

let subscription_name settings =
  let pretty_pid = Sys_utils.get_pretty_pid () in
  Printf.sprintf "%s.%d" settings.subscription_prefix pretty_pid

(****************************************************************************)
(* I/O stuff *)
(****************************************************************************)

(* Send a request to the watchman process *)
let send_request ~debug_logging oc json =
  let json_str = Hh_json.(json_to_string json) in
  if debug_logging then Hh_logger.info "Watchman request: %s" json_str;

  try%lwt
    (* Print the json with a newline and then flush *)
    let%lwt () = Lwt_io.fprintl oc json_str in
    let%lwt () = Lwt_io.flush oc in
    Lwt.return (Ok ())
  with
  | Unix.Unix_error (Unix.EPIPE, _, _) ->
    let msg = "Connection closed (EPIPE)" in
    Lwt.return (Error (Socket_unavailable { msg }))

let get_sockname () =
  let cmd = "watchman" in
  let args = ["--no-pretty"; "get-sockname"] in
  let%lwt { LwtSysUtils.status; stdout; stderr } = LwtSysUtils.exec cmd args in
  match status with
  | Unix.WEXITED 0 ->
    let json = Hh_json.json_of_string stdout in
    Lwt.return (Ok (J.get_string_val "sockname" json))
  | Unix.WEXITED 127 ->
    let path = Option.value (Sys_utils.getenv_path ()) ~default:"(not set)" in
    Lwt.return (Error (Not_installed { path }))
  | Unix.WEXITED code ->
    let msg = spf "get-sockname exited code %d, stderr = %S" code stderr in
    Lwt.return (Error (Socket_unavailable { msg }))
  | Unix.WSIGNALED signal ->
    let signal = PrintSignal.string_of_signal signal in
    let msg = spf "get-sockname signaled with %s signal" signal in
    Lwt.return (Error (Socket_unavailable { msg }))
  | Unix.WSTOPPED signal ->
    let signal = PrintSignal.string_of_signal signal in
    let msg = spf "get-sockname stopped with %s signal" signal in
    Lwt.return (Error (Socket_unavailable { msg }))

(** Opens a connection to the watchman process through the socket *)
let open_connection =
  (* Opens a Unix socket. Could raise a [Unix.Unix_error]. *)
  let open_socket_exn sockname =
    if Sys.unix then
      (* Yes, I know that Unix.open_connection uses the same fd for input and output. But I don't
       * want to hardcode that assumption here. So let's pretend like ic and oc might be back by
       * different fds *)
      Unix.open_connection (Unix.ADDR_UNIX sockname)
    else
      (* On Windows, however, named pipes behave like regular files from the client's perspective.
       * We just open the file and create in/out channels for it. The file permissions attribute
       * is not needed because the file should exist already but we have to pass something. *)
      let fd = Unix.openfile sockname [Unix.O_RDWR] 0o640 in
      (Unix.in_channel_of_descr fd, Unix.out_channel_of_descr fd)
  in
  let open_socket sockname =
    try Ok (open_socket_exn sockname) with
    | Unix.Unix_error (error, _, _) ->
      let msg = spf "%s (socket: %s)" (Unix.error_message error) sockname in
      Error (Socket_unavailable { msg })
  in
  let connection_of_sockname sockname =
    let open Result.Let_syntax in
    let%bind (ic, oc) = open_socket sockname in
    let reader =
      Unix.descr_of_in_channel ic
      |> Lwt_unix.of_unix_file_descr ~blocking:true
      |> Buffered_line_reader_lwt.create
    in
    let oc =
      Unix.descr_of_out_channel oc
      |> Lwt_unix.of_unix_file_descr ~blocking:true
      |> Lwt_io.of_fd ~mode:Lwt_io.output
    in
    Ok (reader, oc)
  in
  fun () ->
    match%lwt get_sockname () with
    | Ok sockname -> Lwt.return (connection_of_sockname sockname)
    | Error _ as err -> Lwt.return err

let close_connection (reader, oc) =
  let ic = Buffered_line_reader_lwt.get_fd reader in
  let%lwt () =
    (* We call [close_connection] in [with_watchman_conn] even on error. Sometimes
        those errors are because the connection was closed unexpectedly, so we should
       ignore an already-closed connection (BADF) here. *)
    try%lwt Lwt_unix.close ic with
    | Unix.Unix_error (Unix.EBADF, _, _) -> Lwt.return_unit
  in
  let%lwt () =
    (* As mention in [open_connection], if we open the connection with [Unix.open_connection],
       we use a single fd for both input and output. That means we might be trying to close
       it twice here. If so, this second close with throw. So let's catch that exception and
       ignore it. *)
    try%lwt Lwt_io.close oc with
    | Unix.Unix_error (Unix.EBADF, _, _) -> Lwt.return_unit
  in
  Lwt.return_unit

let with_watchman_conn f =
  match%lwt open_connection () with
  | Ok conn ->
    let%lwt result =
      try%lwt f conn with
      | e ->
        let e = Exception.wrap e in
        let%lwt () = close_connection conn in
        Exception.reraise e
    in
    let%lwt () = close_connection conn in
    Lwt.return result
  | Error _ as err -> Lwt.return err

let read_line reader =
  try%lwt
    let%lwt line = Buffered_line_reader_lwt.get_next_line reader in
    Lwt.return (Ok line)
  with
  | End_of_file ->
    let msg = "Connection closed (end of file)" in
    Lwt.return (Error (Socket_unavailable { msg }))
  | Unix.Unix_error (Unix.EBADF, _, _) ->
    let msg = "Connection closed (bad file descriptor)" in
    Lwt.return (Error (Socket_unavailable { msg }))
  | Unix.Unix_error (Unix.ECONNRESET, _, _) ->
    let msg = "Connection closed (connection reset)" in
    Lwt.return (Error (Socket_unavailable { msg }))

let read_line_with_timeout ~timeout reader =
  try%lwt Lwt_unix.with_timeout timeout @@ fun () -> read_line reader with
  | Lwt_unix.Timeout ->
    let msg = spf "Timed out reading payload after %f seconds" timeout in
    Lwt.return (Error (Socket_unavailable { msg }))

(* Sends a request to watchman and returns the response. If we don't have a connection,
 * a new connection will be created before the request and destroyed after the response *)
let rec request ~debug_logging ?conn json =
  match conn with
  | None -> with_watchman_conn (fun conn -> request ~debug_logging ~conn json)
  | Some (reader, oc) ->
    (match%lwt send_request ~debug_logging oc json with
    | Ok () ->
      (match%lwt read_line reader with
      | Ok response ->
        (match parse_response ~debug_logging response with
        | Ok _ as result -> Lwt.return result
        | Error msg ->
          let request = Some (Hh_json.json_to_string json) in
          Lwt.return (Error (Response_error { request; response; msg })))
      | Error _ as err -> Lwt.return err)
    | Error _ as err -> Lwt.return err)

let wait_read reader =
  match%lwt Lwt_unix.wait_read (Buffered_line_reader_lwt.get_fd reader) with
  | () -> Lwt.return (Ok ())
  | exception Unix.Unix_error (Unix.EBADF, _, _) ->
    (* this is a curious error. it means that the file descriptor was already
       closed via `Lwt_unix.close` before we called `wait_read`, and the only
       place we do that is in `close_connection`. So that suggests that we're
       calling `Watchman.close` and then still calling `blocking_read` on the
       same instance again, but it's not clear where; we are cancelling those
       promises. *)
    let msg = "Connection closed (bad file descriptor)" in
    Lwt.return (Error (Socket_unavailable { msg }))

let blocking_read ~debug_logging ~conn:(reader, _) =
  match%lwt wait_read reader with
  | Error _ as err -> Lwt.return err
  | Ok () ->
    (match%lwt read_line_with_timeout ~timeout:40.0 reader with
    | Error _ as err -> Lwt.return err
    | Ok response ->
      (match parse_response ~debug_logging response with
      | Ok _ as response -> Lwt.return response
      | Error msg -> Lwt.return (Error (Response_error { request = None; response; msg }))))

(****************************************************************************)
(* Initialization, reinitialization *)
(****************************************************************************)

(** calls [watchman version] to check a list of Watchman capabilities *)
let get_capabilities ~debug_logging ?conn () =
  let open Hh_json in
  let names = List.map ~f:Capability.to_string Capability.all in
  let query = JSON_Array [JSON_String "version"; JSON_Object [("optional", J.strlist names)]] in
  match%lwt request ~debug_logging ?conn query with
  | Ok obj ->
    let set =
      Base.List.fold
        ~init:Capability.Set.empty
        ~f:(fun acc cap ->
          let name = Capability.to_string cap in
          let value =
            Access.(return obj >>= get_obj "capabilities" >>= get_bool name |> project_bool)
          in
          if value then
            Capability.Set.add cap acc
          else
            acc)
        Capability.all
    in
    Lwt.return (Ok set)
  | Error _ as err -> Lwt.return err

(** When we re-init our connection to Watchman, we use the old clockspec to get
  all the changes since our last response. If Watchman missed changes since the
  old clockspec, it is considered to be a "fresh instance".

  This can happen if Watchman restarted, or if there were so many changes that
  Watchman's underlying file watchers (FSEvents, Eden, etc) overflow.

  Unfortunately, the response to "subscribe" doesn't have the "is_fresh_instance"
  field. So we'll instead send a small "query" request. It should always return
  0 files, but it should tell us whether Watchman has missed changes since
  [clockspec]. *)
let is_fresh_instance_since ?conn ~debug_logging ~watch_root clockspec =
  let hard_to_match_name = "irrelevant.potato" in
  let query =
    Hh_json.(
      JSON_Array
        [
          JSON_String "query";
          JSON_String watch_root;
          JSON_Object
            [
              ("since", JSON_String clockspec);
              ("empty_on_fresh_instance", JSON_Bool true);
              ("expression", JSON_Array [JSON_String "name"; JSON_String hard_to_match_name]);
              (* by default, watchman will wait up to 60s to synchronize with the filesystem.
                 we don't care about the actual state of anything in this query, only whether
                 it's a new watchman instance, so set it to 0 *)
              ("sync_timeout", JSON_Number "0");
            ];
        ]
    )
  in
  match%lwt request ~debug_logging ?conn query with
  | Ok response ->
    (match Hh_json_helpers.Jget.bool_opt (Some response) "is_fresh_instance" with
    | Some has_restarted -> Lwt.return (Ok has_restarted)
    | None ->
      (* The response to this query **always** should include the `is_fresh_instance` boolean
       * property. If it is missing then something has gone wrong with Watchman. Since we can't
       * prove that Watchman has not restarted, we must treat this as an error. *)
      let msg = "Expected an is_fresh_instance property" in
      Lwt.return (Error (response_error_of_json ~query ~response msg)))
  | Error (Response_error _) ->
    (* if this simple query failed, it is because the root isn't being watched, so it may have
       missed updates. *)
    Lwt.return (Ok true)
  | Error _ as err -> Lwt.return err

let prepend_relative_path_term ~relative_path ~terms =
  match terms with
  | None -> None
  | Some _ when String.is_empty relative_path ->
    (* If we're watching the watch root directory, then there's no point in specifying a list of
     * files and directories to watch. We're already subscribed to any change in this watch root
     * anyway *)
    None
  | Some terms ->
    (* So lets say we're being told to watch foo/bar. Is foo/bar a directory? Is it a file? If it
     * is a file now, might it become a directory later? I'm not aware of aterm which will watch for either a file or a directory, so let's add two terms *)
    Some (J.strlist ["dirname"; relative_path] :: J.strlist ["name"; relative_path] :: terms)

(** Gets the clockspec. Uses the clockspec from the prior connection if one exists. *)
let get_clockspec ~debug_logging ~conn ~watch prior_clockspec =
  match prior_clockspec with
  | Some clockspec -> Lwt.return (Ok clockspec)
  | None ->
    let query = clock watch in
    let%lwt response = request ~debug_logging ~conn query in
    Lwt.return (Result.bind ~f:(get_string_prop ~query "clock") response)

(** Watches a path. Returns the watch root and relative path to that path. *)
let watch_project ~debug_logging ~conn root =
  let query = J.strlist ["watch-project"; File_path.to_string root] in
  let%lwt response = request ~debug_logging ~conn query in
  match response with
  | Error _ as err -> Lwt.return err
  | Ok response ->
    let watch_root = J.get_string_val "watch" response in
    let relative_path = J.get_string_val "relative_path" ~default:"" response in
    Lwt.return (Ok (watch_root, relative_path))

(** Calls [watchman watch-project] on a list of paths to watch (e.g. all of the
    include directories). The paths may be children of the actual watchman root,
    in which case watch-project returns the watch root and relative path.
    This function computes the set of terms that should be included in queries
    against the root to filter it to only the relative paths we care about. *)
let watch_paths ~debug_logging ~conn paths =
  LwtUtils.fold_result_s
    ~f:(fun (terms, watch_roots, failed_paths) path ->
      match%lwt watch_project ~debug_logging ~conn path with
      | Ok (watch_root, relative_path) ->
        let terms = prepend_relative_path_term ~relative_path ~terms in
        let watch_roots = SSet.add watch_root watch_roots in
        Lwt.return (Ok (terms, watch_roots, failed_paths))
      | Error (Response_error _ as err) ->
        let failed_paths = SMap.add (File_path.to_string path) err failed_paths in
        Lwt.return (Ok (terms, watch_roots, failed_paths))
      | Error _ as err -> Lwt.return err)
    ~init:(Some [], SSet.empty, SMap.empty)
    paths

let watch =
  (* The failed_paths are likely includes which don't exist on the filesystem, so watch_project
     returned an error. Let's do a best effort attempt to infer the relative path for each bad
     include. *)
  let guess_missing_relative_paths terms watch_root failed_paths =
    let watch_root =
      let normalized = Sys_utils.normalize_filename_dir_sep watch_root in
      if String.is_suffix ~suffix:"/" normalized then
        normalized
      else
        normalized ^ "/"
    in
    let (terms, failed_paths) =
      SMap.fold
        (fun path err (terms, failed_paths) ->
          let path = Sys_utils.normalize_filename_dir_sep path in
          if String.is_prefix ~prefix:watch_root path then
            let relative_path = String_utils.lstrip path watch_root in
            (prepend_relative_path_term ~relative_path ~terms, failed_paths)
          else
            (terms, SMap.add path err failed_paths))
        failed_paths
        (terms, SMap.empty)
    in
    if SMap.is_empty failed_paths then
      Ok terms
    else
      Error (Unsupported_watch_roots { roots = [watch_root]; failed_paths })
  in
  (* All of our watched paths should have the same watch root. Let's assert that *)
  let consolidate_watch_roots watch_roots failed_paths =
    match SSet.elements watch_roots with
    | [watch_root] -> Ok watch_root
    | roots -> Error (Unsupported_watch_roots { roots; failed_paths })
  in
  fun ~debug_logging ~conn roots ->
    match%lwt watch_paths ~debug_logging ~conn roots with
    | Ok (terms, watch_roots, failed_paths) ->
      (match consolidate_watch_roots watch_roots failed_paths with
      | Ok watch_root ->
        (match guess_missing_relative_paths terms watch_root failed_paths with
        | Ok terms ->
          let watched_path_expression_terms = Option.map terms ~f:(J.pred "anyof") in
          Lwt.return (Ok { watch_root; watched_path_expression_terms })
        | Error _ as err -> Lwt.return err)
      | Error _ as err -> Lwt.return err)
    | Error _ as err -> Lwt.return err

let rec with_retry ~max_attempts ?(attempt = 0) ?(on_retry = (fun _ -> Lwt_result.return)) f x =
  match%lwt f x with
  | Ok _ as ok -> Lwt.return ok
  | Error err ->
    log_error err;
    (match err with
    | Not_installed _
    | Unsupported_watch_roots _ ->
      Lwt.return (Error Dead)
    | Fresh_instance -> Lwt.return (Error Restarted)
    | Response_error _
    | Socket_unavailable _
    | Subscription_canceled ->
      if attempt >= max_attempts then (
        Hh_logger.error "Watchman has failed %d times in a row. Giving up." attempt;
        Lwt.return (Error Dead)
      ) else (
        match%lwt on_retry attempt x with
        | Ok x -> with_retry ~max_attempts ~attempt:(attempt + 1) ~on_retry f x
        | Error _ as err -> Lwt.return err
      ))

let re_init ?prior_clockspec settings =
  let open Lwt_result.Infix in
  let debug_logging = settings.debug_logging in
  open_connection () >>= fun conn ->
  get_capabilities ~debug_logging ~conn () >>= fun capabilities ->
  watch ~debug_logging ~conn settings.roots >>= fun watch ->
  get_clockspec ~debug_logging ~conn ~watch prior_clockspec >>= fun clockspec ->
  let subscription = subscription_name settings in
  let vcs = Vcs.find (File_path.make watch.watch_root) in
  let should_track_mergebase =
    settings.should_track_mergebase && supports_scm_queries capabilities vcs
  in
  let env =
    {
      settings;
      conn;
      watch;
      clockspec;
      subscription;
      vcs;
      should_track_mergebase;
      mergebase = None;
      finished_an_hg_update = false;
    }
  in
  request ~debug_logging ~conn (subscribe_query env) >>= fun response ->
  ignore response;
  Lwt.return (Ok env)

let backoff_delay attempts =
  let attempts = min attempts 3 in
  Float.of_int (4 * (2 ** attempts))

let extract_file_names env json =
  let open Hh_json.Access in
  return json
  >>= get_array "files"
  |> counit_with (fun _ ->
         (* When an hg.update happens, it shows up in the watchman subscription
            as a notification with no files key present. *)
         []
     )
  |> List.map ~f:(fun json ->
         let s = Hh_json.get_string_exn json in
         (* watchman returns paths relative to the watch root, with slashes
            normalized to use forward slashes. we concat manually using Bytes
            so we can replace the slashes in place. *)
         let root = env.watch.watch_root in
         let root_len = String.length root in
         let s_len = String.length s in
         let abs = Bytes.create (root_len + 1 + s_len) in
         Bytes.From_string.unsafe_blit ~src:root ~src_pos:0 ~dst:abs ~dst_pos:0 ~len:root_len;
         Bytes.unsafe_set abs root_len '/';
         Bytes.From_string.unsafe_blit ~src:s ~src_pos:0 ~dst:abs ~dst_pos:(root_len + 1) ~len:s_len;
         if Sys.win32 then
           for i = 0 to root_len + 1 + s_len do
             if Char.equal (Bytes.unsafe_get abs i) '/' then Bytes.unsafe_set abs i '\\'
           done;
         Bytes.unsafe_to_string ~no_mutation_while_string_reachable:abs
     )
  |> SSet.of_list

(** Reconnects to Watchman after a disconnect. Normally, [allow_fresh_instance]
  should be [false], meaning that we error if the Watchman process we reconnect
  to is a "fresh instance" (see [is_fresh_instance_since]). *)
let re_init_dead_env =
  let on_retry attempt dead_env =
    let backoff = backoff_delay attempt in
    let () = Hh_logger.info "Waiting %fs before reestablishing watchman subscription" backoff in
    let%lwt () = Lwt_unix.sleep backoff in
    Lwt.return (Ok dead_env)
  in
  (* if [allow_fresh_instance] is [false], then we only want to reconnect
     if Watchman did not miss any changes (is NOT a "fresh instance"). but
     sometimes we can handle missed changes, and so we can opt into
     reconnecting even when it might be a fresh instance. *)
  let can_re_init ~allow_fresh_instance dead_env =
    if allow_fresh_instance then
      Lwt.return (Ok true)
    else
      let debug_logging = dead_env.prior_settings.debug_logging in
      let clockspec = dead_env.prior_clockspec in
      let watch_root = dead_env.prior_watch_root in
      match%lwt is_fresh_instance_since ~debug_logging ~watch_root clockspec with
      | Ok missed_changes -> Lwt.return (Ok (not missed_changes))
      | Error _ as err -> Lwt.return err
  in
  let re_init_dead_env_once ~allow_fresh_instance dead_env =
    (* Give watchman 2 minutes to start up, plus sync_timeout (in milliseconds!) to sync.
       TODO: use `file_watcher.timeout` config instead (careful, it's in seconds) *)
    let timeout = Option.value ~default:0 dead_env.prior_settings.sync_timeout + 120000 in
    try%lwt
      Lwt_unix.with_timeout (Float.of_int timeout /. 1000.) @@ fun () ->
      match%lwt can_re_init ~allow_fresh_instance dead_env with
      | Ok true ->
        let () = Hh_logger.info "Attempting to reestablish watchman subscription" in
        let prior_clockspec =
          (* passing a clockspec from a previous instance causes the subscription to
             return is_fresh_instance and empty results, which defeats the point when
             allow_fresh_instance = true. but if we're passing allow_fresh_instance,
             then we should already be reconstructing missed changes. *)
          if allow_fresh_instance then
            None
          else
            Some dead_env.prior_clockspec
        in
        re_init ?prior_clockspec dead_env.prior_settings
      | Ok false ->
        let () = Hh_logger.log "Unable to resubscribe to a fresh watchman instance" in
        Lwt.return (Error Fresh_instance)
      | Error _ as err -> Lwt.return err
    with
    | Lwt_unix.Timeout ->
      Lwt.return (Error (Socket_unavailable { msg = spf "Timed out after %ds" timeout }))
  in
  fun ~allow_fresh_instance dead_env ->
    match%lwt
      with_retry
        ~max_attempts:max_reinit_attempts
        ~on_retry
        (re_init_dead_env_once ~allow_fresh_instance)
        dead_env
    with
    | Ok env ->
      Hh_logger.log "Watchman connection reestablished.";
      let downtime = Unix.gettimeofday () -. dead_env.dead_since in
      FlowEventLogger.watchman_connection_reestablished downtime;
      Lwt.return (Ok env)
    | Error _ as err -> Lwt.return err

let close_channel_on_instance env =
  let%lwt () = close_connection env.conn in
  Lwt.return (dead_env_from_alive env)

let close env = close_connection env.conn

let make_state_change_response state name data =
  let metadata = J.try_get_val "metadata" data in
  match state with
  | `Enter -> State_enter (name, metadata)
  | `Leave -> State_leave (name, metadata)

let extract_mergebase data =
  let open Hh_json.Access in
  let ret =
    let fat_clock = return data >>= get_obj "clock" in
    fat_clock >>= get_string "clock" >>= fun (clock, _) ->
    fat_clock >>= get_obj "scm" >>= get_string "mergebase" >>= fun (mergebase, _) ->
    return (clock, mergebase)
  in
  to_option ret

let subscription_is_cancelled data =
  match Jget.bool_opt (Some data) "canceled" with
  | None
  | Some false ->
    false
  | Some true -> true

let get_mergebase =
  (* watchman's mergebase-with queries also get the changes since mergebase.
     we don't want those here, we just want to quickly know the mergebase and
     will use that to decide whether we care about the changes. so we ask
     source control directly. *)
  let get_mergebase_from_vcs vcs root mergebase_with =
    match vcs with
    | Some Vcs.Hg ->
      (match%lwt Hg.merge_base ~cwd:root "." mergebase_with with
      | Ok hash -> Lwt.return (Ok (Some hash))
      | Error _ as err -> Lwt.return err)
    | Some Vcs.Git ->
      (match%lwt Git.merge_base ~cwd:root mergebase_with "HEAD" with
      | Ok hash -> Lwt.return (Ok (Some hash))
      | Error _ as err -> Lwt.return err)
    | None -> Lwt.return (Ok None)
  in
  fun (env : env) ->
    if env.should_track_mergebase then
      let vcs = env.vcs in
      let root = env.watch.watch_root in
      let mergebase_with = env.settings.mergebase_with in
      get_mergebase_from_vcs vcs root mergebase_with
    else
      Lwt.return (Ok None)

let get_mergebase_and_changes =
  let on_retry attempt env =
    let%lwt () = Lwt_unix.sleep (backoff_delay attempt) in
    Lwt.return (Ok env)
  in
  let run_query env =
    let debug_logging = env.settings.debug_logging in
    let query = get_changes_since_mergebase_query env in
    match%lwt request ~debug_logging query with
    | Error _ as err -> Lwt.return err
    | Ok response ->
      (match extract_mergebase response with
      | Some (_clock, mergebase) ->
        (* ignore clock and don't update env.clockspec. this is likely just a
           legacy thing, and it's probably ok if we did update env.clockspec.
           it's used when we resubscribe to a broken subscription, and since
           we already processed changes up to _clock, we can resubscribe
           from there instead of from env.clockspec again.

           it is assumed that there's already a subscription running that will
           catch any contemporaneous changes. suppose a subscription is started
           at clock C. we query for changes since mergebase here, and get back
           clock C+1. `changes` includes files that changed before our
           subscription, plus maybe some between C and C+1. we'll also get a
           subscription event for those changes between C and C+1, so we don't
           _need_ to update env.clockspec here. *)
        let changes = extract_file_names env response in
        Lwt.return (Ok (Some (mergebase, changes)))
      | None ->
        Lwt.return (Error (response_error_of_json ~query ~response "Failed to extract mergebase")))
  in
  fun (env : env) ->
    if env.should_track_mergebase then
      with_retry ~max_attempts:max_retry_attempts ~on_retry run_query env
    else
      Lwt.return (Ok None)

(** We want to know when an N-files-changed notification is due to the user changing
  their mergebase. This could be due to pulling & rebasing their work onto the new
  commit, or just moving from one commit to another.

  Using an SCM-aware subscription (https://facebook.github.io/watchman/docs/scm-query.html)
  would tell us when the mergebase changes, but then it would only tell us what
  files changed since that new mergebase. The idea there is that we'd download
  a new saved state based on that new mergebase, and so only need to process the
  files changed since mergebase. But there's a lot of overhead for us to use a
  new saved state, so it might be faster to just process all the upstream changes.

  We get all the upstream changes by not using an SCM-aware subscription, but
  then have to see if the mergebase changed on our own. Our approach is based
  around the assumption that once Watchman tells us that N files have changed,
  things have settled down enough that it's safe to query for the mergebase.
  And since querying for the mergebase is expensive, we only do so when we see
  an hg.update. After an hg.update it's more acceptable to delay a file-changed
  notification than after a user saves a file in the IDE.

  Returns [None] if we don't know whether the mergebase changed (mostly if
  [should_track_mergebase = false]), otherwise [Some did_change]. Also mutates
  [env.mergebase]. *)
let check_for_changed_mergebase (env : env) =
  match env.mergebase with
  | None ->
    Hh_logger.debug "Unable to check for changed mergebase: unknown previous mergebase";
    Lwt.return None
  | Some old_mergebase ->
    let%lwt new_mergebase =
      match%lwt get_mergebase env with
      | Ok mergebase -> Lwt.return mergebase
      | Error (Vcs_utils.Not_installed _) ->
        (* TODO: handle this more gracefully than `failwith`, but should be impossible.
           we already used the VCS to decide [should_track_mergebase]. *)
        failwith "Failed to query mergebase: unable to find vcs"
      | Error (Vcs_utils.Errored msg) ->
        (* TODO: handle this more gracefully than `failwith` *)
        failwith (Printf.sprintf "Failed to query mergebase: %s" msg)
    in
    (match new_mergebase with
    | Some mergebase ->
      let changed_mergebase = not (String.equal mergebase old_mergebase) in
      if changed_mergebase then (
        Hh_logger.info "Watchman reports mergebase changed from %S to %S" old_mergebase mergebase;
        env.mergebase <- Some mergebase
      ) else
        Hh_logger.debug "Watchman reports mergebase is unchanged at %S" mergebase;
      Lwt.return (Some changed_mergebase)
    | None ->
      Hh_logger.warn "Unable to fetch current mergebase";
      Lwt.return None)

let recover_from_restart (env : env) =
  match env.mergebase with
  | None ->
    (* we weren't tracking the mergebase so we can't figure out what changed
       while watchman wasn't listening *)
    Lwt.return (Error Restarted)
  | Some prev_mergebase ->
    (* on restart, reconnect to a fresh env. *)
    let%lwt dead_env = close_channel_on_instance env in
    (match%lwt re_init_dead_env ~allow_fresh_instance:true dead_env with
    | Ok env ->
      (match%lwt get_mergebase_and_changes env with
      | Error _ as err -> Lwt.return err
      | Ok None ->
        (* asking source control what changed while watchman was restarting was
           not supported, so we can't recover. note: this should virtually never
           happen: it means that Watchman previously supported SCM queries, but
           no longer does when we reconnect. *)
        Lwt.return (Error Restarted)
      | Ok (Some (mergebase, changes_since_mergebase)) ->
        (* this is a new `env`, make sure to store the mergebase! *)
        env.mergebase <- Some mergebase;
        (* it's possible that prev_mergebase and mergebase are equal *)
        let pushed_changes =
          Missed_changes { prev_mergebase; mergebase; changes_since_mergebase }
        in
        Lwt.return (Ok (env, pushed_changes)))
    | Error _ as err -> Lwt.return err)

let transform_asynchronous_get_changes_response env data =
  if is_fresh_instance_response data then
    Lwt.return (Error Fresh_instance)
  else if subscription_is_cancelled data then
    Lwt.return (Error Subscription_canceled)
  else (
    env.clockspec <- Jget.string_exn (Some data) "clock";
    match Jget.string_opt (Some data) "state-enter" with
    | Some state -> Lwt.return (Ok (env, make_state_change_response `Enter state data))
    | None ->
      (match Jget.string_opt (Some data) "state-leave" with
      | Some state ->
        if String.equal state "hg.update" then env.finished_an_hg_update <- true;
        Lwt.return (Ok (env, make_state_change_response `Leave state data))
      | None ->
        let changes = extract_file_names env data in
        let%lwt changed_mergebase =
          if env.finished_an_hg_update then (
            env.finished_an_hg_update <- false;
            check_for_changed_mergebase env
          ) else
            Lwt.return None
        in
        Lwt.return (Ok (env, Files_changed { changes; changed_mergebase })))
  )

let get_changes =
  let on_retry _attempt env =
    let%lwt dead_env = close_channel_on_instance env in
    re_init_dead_env ~allow_fresh_instance:false dead_env
  in
  let wait_for_changes env =
    let debug_logging = env.settings.debug_logging in
    match%lwt blocking_read ~debug_logging ~conn:env.conn with
    | Error _ as err -> Lwt.return err
    | Ok response -> transform_asynchronous_get_changes_response env response
  in
  (fun env -> with_retry ~max_attempts:max_retry_attempts ~on_retry wait_for_changes env)

let init settings =
  let on_retry attempt settings =
    let%lwt () = Lwt_unix.sleep (backoff_delay attempt) in
    Lwt.return (Ok settings)
  in
  match%lwt with_retry ~max_attempts:max_reinit_attempts ~on_retry re_init settings with
  | Ok env ->
    (match%lwt get_mergebase_and_changes env with
    | Ok mergebase_and_changes ->
      let (mergebase, files) =
        match mergebase_and_changes with
        | Some (mergebase, changes) ->
          Hh_logger.info
            "Watchman reports the initial mergebase as %S, and %d changes"
            mergebase
            (SSet.cardinal changes);
          (Some mergebase, changes)
        | None ->
          if env.should_track_mergebase then
            Hh_logger.warn
              "Not checking changes since mergebase! SCM-aware queries are not supported for your VCS by your version of Watchman.";
          (None, SSet.empty)
      in
      env.mergebase <- mergebase;
      Lwt.return (Ok (env, files))
    | Error _ -> Lwt.return (Error "Failed to query initial mergebase from Watchman"))
  | Error _ -> Lwt.return (Error "Failed to initialize watchman")

module Testing = struct
  type nonrec error_kind = error_kind

  let test_settings : init_settings =
    {
      debug_logging = false;
      defer_states = [];
      expression_terms = [];
      mergebase_with = "hash";
      roots = [File_path.dummy_path];
      should_track_mergebase = false;
      subscribe_mode = Defer_changes;
      subscription_prefix = "dummy_prefix";
      sync_timeout = None;
    }

  let get_test_conn () =
    let%lwt reader = Buffered_line_reader_lwt.get_null_reader ()
    and oc = Lwt_io.open_file ~mode:Lwt_io.output "/dev/null" in
    Lwt.return (reader, oc)

  let get_test_env () =
    let%lwt conn = get_test_conn () in
    Lwt.return
      {
        settings = test_settings;
        conn;
        clockspec = "";
        watch =
          {
            watch_root = "/path/to/root";
            watched_path_expression_terms =
              Some (J.pred "anyof" [J.strlist ["dirname"; "foo"]; J.strlist ["name"; "foo"]]);
          };
        vcs = None;
        should_track_mergebase = false;
        mergebase = None;
        finished_an_hg_update = false;
        subscription = "dummy_prefix.123456789";
      }

  let transform_asynchronous_get_changes_response env json =
    transform_asynchronous_get_changes_response env json
end
