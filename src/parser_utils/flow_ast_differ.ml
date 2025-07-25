(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

module Ast_utils = Flow_ast_utils
module Ast = Flow_ast
open Utils_js

type 'a change' =
  | Replace of 'a * 'a
  | Insert of {
      items: 'a list;
      (* separator. Defaults to \n *)
      separator: string option;
      leading_separator: bool;
    }
  | Delete of 'a
[@@deriving show]

type 'a change = Loc.t * 'a change' [@@deriving show]

type 'a changes = 'a change list [@@deriving show]

(* Position in the list is necessary to figure out what Loc.t to assign to insertions. *)
type 'a diff_result = int (* position *) * 'a change'

(* Compares changes based on location. *)
let change_compare (pos1, chg1) (pos2, chg2) =
  if pos1 <> pos2 then
    compare pos1 pos2
  else
    (* Orders the change types alphabetically. This puts same-indexed inserts before deletes *)
    match (chg1, chg2) with
    | (Insert _, Delete _)
    | (Delete _, Replace _)
    | (Insert _, Replace _) ->
      -1
    | (Delete _, Insert _)
    | (Replace _, Delete _)
    | (Replace _, Insert _) ->
      1
    | _ -> 0

(* diffs based on http://www.xmailserver.org/diff2.pdf on page 6 *)
let list_diff (old_list : 'a list) (new_list : 'a list) : 'a diff_result list option =
  (* Lots of acccesses in this algorithm so arrays are faster *)
  let (old_arr, new_arr) = (Array.of_list old_list, Array.of_list new_list) in
  let (n, m) = (Array.length old_arr, Array.length new_arr) in
  (* The shortest edit sequence problem is equivalent to finding the longest
     common subsequence, or equivalently the longest trace *)
  let longest_trace max_distance : (int * int) list option =
    (* adds the match points in this snake to the trace and produces the endpoint along with the
       new trace *)
    let rec follow_snake x y trace =
      if x >= n || y >= m then
        (x, y, trace)
      else if old_arr.(x) == new_arr.(y) then
        follow_snake (x + 1) (y + 1) ((x, y) :: trace)
      else
        (x, y, trace)
    in
    let rec build_trace dist frontier visited =
      if Hashtbl.mem visited (n, m) then
        ()
      else
        let new_frontier = Queue.create () in
        if dist > max_distance then
          ()
        else
          let follow_trace (x, y) : unit =
            let trace = Hashtbl.find visited (x, y) in
            let (x_old, y_old, advance_in_old_list) = follow_snake (x + 1) y trace in
            let (x_new, y_new, advance_in_new_list) = follow_snake x (y + 1) trace in
            (* if we have already visited this location, there is a shorter path to it, so we don't
               store this trace *)
            let () =
              if Hashtbl.mem visited (x_old, y_old) |> not then
                let () = Queue.add (x_old, y_old) new_frontier in
                Hashtbl.add visited (x_old, y_old) advance_in_old_list
            in
            if Hashtbl.mem visited (x_new, y_new) |> not then
              let () = Queue.add (x_new, y_new) new_frontier in
              Hashtbl.add visited (x_new, y_new) advance_in_new_list
          in
          Queue.iter follow_trace frontier;
          build_trace (dist + 1) new_frontier visited
    in
    (* Keep track of all visited string locations so we don't duplicate work *)
    let visited = Hashtbl.create (n * m) in
    let frontier = Queue.create () in
    (* Start with the basic trace, but follow a starting snake to a non-match point *)
    let (x, y, trace) = follow_snake 0 0 [] in
    Queue.add (x, y) frontier;
    Hashtbl.add visited (x, y) trace;
    build_trace 0 frontier visited;
    Hashtbl.find_opt visited (n, m)
  in
  (* Produces an edit script from a trace via the procedure described on page 4
     of the paper. Assumes the trace is ordered by the x coordinate *)
  let build_script_from_trace (trace : (int * int) list) : 'a diff_result list =
    (* adds inserts at position x_k for values in new_list from
       y_k + 1 to y_(k + 1) - 1 for k such that y_k + 1 < y_(k + 1) *)
    let rec add_inserts k script =
      let trace_len = List.length trace in
      let trace_array = Array.of_list trace in
      let gen_inserts first last =
        let len = last - first in
        Base.List.sub new_list ~pos:first ~len
      in
      if k > trace_len - 1 then
        script
      else
        (* The algorithm treats the trace as though (-1,-1) were the (-1)th match point
           in the list and (n,m) were the (len+1)th *)
        let first =
          if k = -1 then
            0
          else
            (trace_array.(k) |> snd) + 1
        in
        let last =
          if k = trace_len - 1 then
            m
          else
            trace_array.(k + 1) |> snd
        in
        if first < last then
          let start =
            if k = -1 then
              -1
            else
              trace_array.(k) |> fst
          in
          ( start,
            Insert { items = gen_inserts first last; separator = None; leading_separator = false }
          )
          :: script
          |> add_inserts (k + 1)
        else
          add_inserts (k + 1) script
    in
    (* Convert like-indexed deletes and inserts into a replacement. This relies
       on the fact that sorting the script with our change_compare function will order all
       Insert nodes before Deletes *)
    let rec convert_to_replace script =
      match script with
      | []
      | [_] ->
        script
      | (i1, Insert { items = [x]; _ }) :: (i2, Delete y) :: t when i1 = i2 - 1 ->
        (i2, Replace (y, x)) :: convert_to_replace t
      | (i1, Insert { items = x :: rst; separator; _ }) :: (i2, Delete y) :: t when i1 = i2 - 1 ->
        (* We are only removing the first element of the insertion. We make sure to indicate
           that the rest of the insert should have a leading separator between it and the replace. *)
        (i2, Replace (y, x))
        :: convert_to_replace
             ((i2, Insert { items = rst; separator; leading_separator = true }) :: t)
      | h :: t -> h :: convert_to_replace t
    in
    (* Deletes are added for every element of old_list that does not have a
       match point with new_list *)
    let deletes =
      Base.List.map ~f:fst trace
      |> ISet.of_list
      |> ISet.diff (Base.List.range 0 n |> ISet.of_list)
      |> ISet.elements
      |> Base.List.map ~f:(fun pos -> (pos, Delete old_arr.(pos)))
    in
    deletes |> add_inserts (-1) |> List.sort change_compare |> convert_to_replace
  in
  Base.Option.(
    longest_trace (n + m)
    >>| List.rev (* trace is built backwards for efficiency *)
    >>| build_script_from_trace
  )

type expression_node_parent =
  | StatementParentOfExpression of (Loc.t, Loc.t) Flow_ast.Statement.t
  | ExpressionParentOfExpression of (Loc.t, Loc.t) Flow_ast.Expression.t
  | SlotParentOfExpression (* Any slot that does not require expression to be parenthesized. *)
  | SpreadParentOfExpression
  | MatchExpressionCaseBodyParentOfExpression
[@@deriving show]

type statement_node_parent =
  | StatementBlockParentOfStatement of Loc.t
  | ExportParentOfStatement of Loc.t
  | IfParentOfStatement of Loc.t
  | LabeledStatementParentOfStatement of Loc.t
  | LoopParentOfStatement of Loc.t
  | WithStatementParentOfStatement of Loc.t
  | TopLevelParentOfStatement
  | SwitchCaseParentOfStatement of Loc.t
  | MatchCaseParentOfStatement of Loc.t
[@@deriving show]

(* We need a variant here for every node that we want to be able to store a diff for. The more we
 * have here, the more granularly we can diff. *)
type node =
  | Raw of string
  | Comment of Loc.t Flow_ast.Comment.t
  | StringLiteral of Loc.t * Loc.t Ast.StringLiteral.t
  | NumberLiteral of Loc.t * Loc.t Ast.NumberLiteral.t
  | BigIntLiteral of Loc.t * Loc.t Ast.BigIntLiteral.t
  | BooleanLiteral of Loc.t * Loc.t Ast.BooleanLiteral.t
  | RegExpLiteral of Loc.t * Loc.t Ast.RegExpLiteral.t
  | ModuleRefLiteral of Loc.t * (Loc.t, Loc.t) Ast.ModuleRefLiteral.t
  | Statement of ((Loc.t, Loc.t) Ast.Statement.t * statement_node_parent)
  | Program of (Loc.t, Loc.t) Ast.Program.t
  | Expression of ((Loc.t, Loc.t) Ast.Expression.t * expression_node_parent)
  | Pattern of (Loc.t, Loc.t) Ast.Pattern.t
  | Params of (Loc.t, Loc.t) Ast.Function.Params.t
  | Variance of Loc.t Ast.Variance.t
  | Type of (Loc.t, Loc.t) Flow_ast.Type.t
  | TypeParam of (Loc.t, Loc.t) Ast.Type.TypeParam.t
  | TypeAnnotation of (Loc.t, Loc.t) Flow_ast.Type.annotation
  | TypeGuard of (Loc.t, Loc.t) Flow_ast.Type.TypeGuard.t
  | TypeGuardAnnotation of (Loc.t, Loc.t) Flow_ast.Type.type_guard_annotation
  | FunctionTypeAnnotation of (Loc.t, Loc.t) Flow_ast.Type.annotation
  | ClassProperty of (Loc.t, Loc.t) Flow_ast.Class.Property.t
  | ClassPrivateField of (Loc.t, Loc.t) Flow_ast.Class.PrivateField.t
  | ObjectProperty of (Loc.t, Loc.t) Flow_ast.Expression.Object.property
  | TemplateLiteral of Loc.t * (Loc.t, Loc.t) Ast.Expression.TemplateLiteral.t
  | JSXChild of (Loc.t, Loc.t) Ast.JSX.child
  | JSXIdentifier of (Loc.t, Loc.t) Ast.JSX.Identifier.t
  | MatchPattern of (Loc.t, Loc.t) Ast.MatchPattern.t
  | MatchObjectPatternProperty of (Loc.t, Loc.t) Ast.MatchPattern.ObjectPattern.Property.t
[@@deriving show]

let expand_loc_with_comments loc node =
  let open Comment_attachment in
  let bounds (loc, node) f =
    let collector = new comment_bounds_collector ~loc in
    ignore (f collector (loc, node));
    collector#comment_bounds
  in
  let comment_bounds =
    match node with
    | StringLiteral (loc, lit) ->
      bounds (loc, lit) (fun collect (loc, lit) -> collect#string_literal loc lit)
    | NumberLiteral (loc, lit) ->
      bounds (loc, lit) (fun collect (loc, lit) -> collect#number_literal loc lit)
    | BigIntLiteral (loc, lit) ->
      bounds (loc, lit) (fun collect (loc, lit) -> collect#bigint_literal loc lit)
    | BooleanLiteral (loc, lit) ->
      bounds (loc, lit) (fun collect (loc, lit) -> collect#boolean_literal loc lit)
    | RegExpLiteral (loc, lit) ->
      bounds (loc, lit) (fun collect (loc, lit) -> collect#regexp_literal loc lit)
    | ModuleRefLiteral (loc, lit) ->
      bounds (loc, lit) (fun collect (loc, lit) -> collect#module_ref_literal loc lit)
    | Statement (stmt, _) -> bounds stmt (fun collect stmt -> collect#statement stmt)
    | Expression (expr, _) -> bounds expr (fun collect expr -> collect#expression expr)
    | Pattern pat -> bounds pat (fun collect pat -> collect#pattern pat)
    | Params params -> bounds params (fun collect params -> collect#function_params params)
    | Variance var -> bounds var (fun collect var -> collect#variance var)
    | Type ty -> bounds ty (fun collect ty -> collect#type_ ty)
    | TypeParam tparam -> bounds tparam (fun collect tparam -> collect#type_param tparam)
    | TypeAnnotation annot
    | FunctionTypeAnnotation annot ->
      bounds annot (fun collect annot -> collect#type_annotation annot)
    | TypeGuard guard -> bounds guard (fun collect guard -> collect#type_guard guard)
    | TypeGuardAnnotation guard ->
      bounds guard (fun collect guard -> collect#type_guard_annotation guard)
    | ClassProperty prop -> bounds prop (fun collect (loc, prop) -> collect#class_property loc prop)
    | ClassPrivateField f -> bounds f (fun collect (loc, f) -> collect#class_private_field loc f)
    | ObjectProperty (Ast.Expression.Object.Property prop) ->
      bounds prop (fun collect prop -> collect#object_property prop)
    | ObjectProperty (Ast.Expression.Object.SpreadProperty prop) ->
      bounds prop (fun collect prop -> collect#spread_property prop)
    | TemplateLiteral (loc, lit) ->
      bounds (loc, lit) (fun collect (loc, lit) -> collect#template_literal loc lit)
    | JSXIdentifier id -> bounds id (fun collect id -> collect#jsx_identifier id)
    | MatchPattern pat -> bounds pat (fun collect pat -> collect#match_pattern pat)
    | MatchObjectPatternProperty prop ->
      bounds prop (fun collect prop -> collect#match_object_pattern_property prop)
    (* Nodes that do have attached comments *)
    | Raw _
    | Comment _
    | Program _
    | JSXChild _ ->
      (None, None)
  in
  expand_loc_with_comment_bounds loc comment_bounds

let expand_statement_comment_bounds ((loc, _) as stmt) =
  let open Comment_attachment in
  let comment_bounds = statement_comment_bounds stmt in
  expand_loc_with_comment_bounds loc comment_bounds

let replace loc old_node new_node =
  (expand_loc_with_comments loc old_node, Replace (old_node, new_node))

let delete loc node = (expand_loc_with_comments loc node, Delete node)

let insert ~sep nodes = Insert { items = nodes; separator = sep; leading_separator = false }

(* This is needed because all of the functions assume that if they are called, there is some
 * difference between their arguments and they will often report that even if no difference actually
 * exists. This allows us to easily avoid calling the diffing function if there is no difference. *)
let diff_if_changed f x1 x2 =
  if x1 == x2 then
    []
  else
    f x1 x2

let diff_if_changed_ret_opt f x1 x2 =
  if x1 == x2 then
    Some []
  else
    f x1 x2

let diff_if_changed_opt f opt1 opt2 : node change list option =
  match (opt1, opt2) with
  | (Some x1, Some x2) ->
    if x1 == x2 then
      Some []
    else
      f x1 x2
  | (None, None) -> Some []
  | _ -> None

let diff_or_add_opt f add opt1 opt2 : node change list option =
  match (opt1, opt2) with
  | (Some x1, Some x2) ->
    if x1 == x2 then
      Some []
    else
      f x1 x2
  | (None, None) -> Some []
  | (None, Some x2) -> Some (add x2)
  | _ -> None

(* This is needed if the function f takes its arguments as options and produces an optional
   node change list (for instance, type annotation). In this case it is not sufficient just to
   give up and return None if only one of the options is present *)
let _diff_if_changed_opt_arg f opt1 opt2 : node change list option =
  match (opt1, opt2) with
  | (None, None) -> Some []
  | (Some x1, Some x2) when x1 == x2 -> Some []
  | _ -> f opt1 opt2

(* This is needed if the function for the given node returns a node change
 * list instead of a node change list option (for instance, expression) *)
let diff_if_changed_nonopt_fn f opt1 opt2 : node change list option =
  match (opt1, opt2) with
  | (Some x1, Some x2) ->
    if x1 == x2 then
      Some []
    else
      Some (f x1 x2)
  | (None, None) -> Some []
  | _ -> None

(* Is an RHS expression an import expression? *)
let is_import_expr (expr : (Loc.t, Loc.t) Ast.Expression.t) =
  let open Ast.Expression.Call in
  match expr with
  | (_, Ast.Expression.Import _) -> true
  | ( _,
      Ast.Expression.Call
        { callee = (_, Ast.Expression.Identifier (_, { Ast.Identifier.name; comments = _ })); _ }
    ) ->
    name = "require"
  | _ -> false

(* Guess whether a statement is an import or not *)
let is_directive_stmt (stmt : (Loc.t, Loc.t) Ast.Statement.t) =
  let open Ast.Statement.Expression in
  match stmt with
  | (_, Ast.Statement.Expression { directive = Some _; _ }) -> true
  | _ -> false

let is_import_stmt (stmt : (Loc.t, Loc.t) Ast.Statement.t) =
  let open Ast.Statement.Expression in
  let open Ast.Statement.VariableDeclaration in
  let open Ast.Statement.VariableDeclaration.Declarator in
  match stmt with
  | (_, Ast.Statement.ImportDeclaration _) -> true
  | (_, Ast.Statement.Expression { expression = expr; _ }) -> is_import_expr expr
  | (_, Ast.Statement.VariableDeclaration { declarations = decs; _ }) ->
    List.exists
      (fun (_, { init; _ }) -> Base.Option.value_map init ~default:false ~f:is_import_expr)
      decs
  | _ -> false

type partition_result =
  | Partitioned of {
      directives: (Loc.t, Loc.t) Ast.Statement.t list;
      imports: (Loc.t, Loc.t) Ast.Statement.t list;
      body: (Loc.t, Loc.t) Ast.Statement.t list;
    }

let partition_imports (stmts : (Loc.t, Loc.t) Ast.Statement.t list) =
  let rec partition_import_helper rec_stmts (directives, imports) =
    match rec_stmts with
    | hd :: tl when is_directive_stmt hd -> partition_import_helper tl (hd :: directives, imports)
    | hd :: tl when is_import_stmt hd -> partition_import_helper tl (directives, hd :: imports)
    | _ ->
      Partitioned { directives = List.rev directives; imports = List.rev imports; body = rec_stmts }
  in

  partition_import_helper stmts ([], [])

(* Outline:
 * - There is a function for every AST node that we want to be able to recurse into.
 * - Each function for an AST node represented in the `node` type above should return a list of
 *   changes.
 *   - If it cannot compute a more granular diff, it should return a list with a single element,
 *     which records the replacement of `old_node` with `new_node` (where `old_node` and
 *     `new_node` are the arguments passed to that function)
 * - Every other function should do the same, except if it is unable to return a granular diff, it
 *   should return `None` to indicate that its parent must be recorded as a replacement. This is
 *   because there is no way to record a replacement for a node which does not appear in the
 *   `node` type above.
 * - We can add additional functions as needed to improve the granularity of the diffs.
 * - We could eventually reach a point where no function would ever fail to generate a diff. That
 *   would require us to implement a function here for every AST node, and add a variant to the
 *   `node` type for every AST node as well. It would also likely require some tweaks to the AST.
 *   For example, a function return type is optional. If it is None, it has no location attached.
 *   What would we do if the original tree had no annotation, but the new tree did have one? We
 *   would not know what Loc.t to give to the insertion.
 *)
(* Entry point *)
let program (program1 : (Loc.t, Loc.t) Ast.Program.t) (program2 : (Loc.t, Loc.t) Ast.Program.t) :
    node change list =
  (* Assuming a diff has already been generated, recurse into it.
     This function is passed the old_list and index_offset parameters
     in order to correctly insert new statements WITHOUT assuming that
     the entire statement list is being processed with a single call
     to this function. When an Insert diff is detected, we need to find
     a Loc.t that represents where in the original program they will be inserted.
     To do so, we find the statement in the old statement list that they will
     be inserted after, and get its end_loc. The index_offset parameter represents how
     many statements in the old statement list are NOT represented in this diff--
     for example, if we separated the statement lists into a list of initial imports
     and a list of body statements and generated diffs for them separately
     (cf. toplevel_statement_list), when recursing into the body diffs, the
     length of the imports in the old statement list should be passed in to
     index_offset so that insertions into the body section are given the right index.
  *)
  let recurse_into_diff
      (type a b)
      (f : a -> a -> b change list option)
      (trivial : a -> (Loc.t * b) option)
      (old_list : a list)
      (index_offset : int)
      (diffs : a diff_result list) : b change list option =
    let open Base.Option in
    let recurse_into_change = function
      | (_, Replace (x1, x2)) -> f x1 x2
      | (index, Insert { items = lst; separator; leading_separator }) ->
        let index = index + index_offset in
        let loc =
          if List.length old_list = 0 then
            None
          else if index = -1 then
            (* To insert at the start of the list, insert before the first element *)
            List.hd old_list |> trivial >>| fst >>| Loc.start_loc
          else
            (* Otherwise insert it after the current element *)
            List.nth old_list index |> trivial >>| fst >>| Loc.end_loc
        in
        Base.List.map ~f:trivial lst
        |> all
        >>| Base.List.map ~f:snd (* drop the loc *)
        >>| (fun x -> Insert { items = x; separator; leading_separator })
        |> both loc
        >>| Base.List.return
      | (_, Delete x) -> trivial x >>| (fun (loc, y) -> (loc, Delete y)) >>| Base.List.return
    in
    let recurse_into_changes =
      Base.List.map ~f:recurse_into_change %> all %> map ~f:Base.List.concat
    in
    recurse_into_changes diffs
  in
  (* Runs `list_diff` and then recurses into replacements (using `f`) to get more granular diffs.
     For inserts and deletes, it uses `trivial` to produce a Loc.t and a b for the change *)
  let diff_and_recurse
      (type a b)
      (f : a -> a -> b change list option)
      (trivial : a -> (Loc.t * b) option)
      (old_list : a list)
      (new_list : a list) : b change list option =
    Base.Option.(list_diff old_list new_list >>= recurse_into_diff f trivial old_list 0)
  in
  (* Same as diff_and_recurse but takes in a function `f` that doesn't return an option *)
  let diff_and_recurse_nonopt (type a b) (f : a -> a -> b change list) =
    diff_and_recurse (fun x y -> f x y |> Base.Option.return)
  in
  (* diff_and_recurse for when there is no way to get a trivial transformation from a to b*)
  let diff_and_recurse_no_trivial f = diff_and_recurse f (fun _ -> None) in
  let diff_and_recurse_nonopt_no_trivial f = diff_and_recurse_nonopt f (fun _ -> None) in
  let join_diff_list = Some [] |> List.fold_left (Base.Option.map2 ~f:List.append) in
  let rec syntax_opt
            : 'internal.
              Loc.t ->
              (Loc.t, 'internal) Ast.Syntax.t option ->
              (Loc.t, 'internal) Ast.Syntax.t option ->
              node change list option =
   fun loc s1 s2 ->
    let add_comments { Ast.Syntax.leading; trailing; internal = _ } =
      Loc.(
        let fold_comment acc cmt = Comment cmt :: acc in
        let leading = List.fold_left fold_comment [] leading in
        let leading_inserts =
          match leading with
          | [] -> []
          | leading -> [({ loc with _end = loc.start }, insert ~sep:None (List.rev leading))]
        in
        let trailing = List.fold_left fold_comment [] trailing in
        let trailing_inserts =
          match trailing with
          | [] -> []
          | trailing -> [({ loc with start = loc._end }, insert ~sep:None (List.rev trailing))]
        in
        leading_inserts @ trailing_inserts
      )
    in
    diff_or_add_opt syntax add_comments s1 s2
  and syntax
        : 'internal.
          (Loc.t, 'internal) Ast.Syntax.t ->
          (Loc.t, 'internal) Ast.Syntax.t ->
          node change list option =
   fun s1 s2 ->
    let { Ast.Syntax.leading = leading1; trailing = trailing1; internal = _ } = s1 in
    let { Ast.Syntax.leading = leading2; trailing = trailing2; internal = _ } = s2 in
    let add_comment ((loc, _) as cmt) = Some (loc, Comment cmt) in
    let leading = diff_and_recurse comment add_comment leading1 leading2 in
    let trailing = diff_and_recurse comment add_comment trailing1 trailing2 in
    match (leading, trailing) with
    | (Some l, Some t) -> Some (l @ t)
    | (Some l, None) -> Some l
    | (None, Some t) -> Some t
    | (None, None) -> None
  and comment
      ((loc1, comment1) as cmt1 : Loc.t Ast.Comment.t)
      ((_loc2, comment2) as cmt2 : Loc.t Ast.Comment.t) =
    let open Ast.Comment in
    match (comment1, comment2) with
    | ({ kind = Line; _ }, { kind = Block; _ }) -> Some [replace loc1 (Comment cmt1) (Comment cmt2)]
    | ({ kind = Block; _ }, { kind = Line; _ }) -> Some [replace loc1 (Comment cmt1) (Comment cmt2)]
    | ({ kind = Line; text = c1; _ }, { kind = Line; text = c2; _ })
    | ({ kind = Block; text = c1; _ }, { kind = Block; text = c2; _ })
      when not (String.equal c1 c2) ->
      Some [replace loc1 (Comment cmt1) (Comment cmt2)]
    | _ -> None
  and program' (program1 : (Loc.t, Loc.t) Ast.Program.t) (program2 : (Loc.t, Loc.t) Ast.Program.t) :
      node change list =
    let open Ast.Program in
    let (program_loc, { statements = statements1; _ }) = program1 in
    let (_, { statements = statements2; _ }) = program2 in
    toplevel_statement_list statements1 statements2
    |> Base.Option.value ~default:[replace program_loc (Program program1) (Program program2)]
  and toplevel_statement_list
      (stmts1 : (Loc.t, Loc.t) Ast.Statement.t list) (stmts2 : (Loc.t, Loc.t) Ast.Statement.t list)
      =
    Base.Option.(
      let (imports1, body1) =
        let (Partitioned { directives; imports; body }) = partition_imports stmts1 in
        (directives @ imports, body)
      in
      let (imports2, body2) =
        let (Partitioned { directives; imports; body }) = partition_imports stmts2 in
        (directives @ imports, body)
      in
      let imports_diff = list_diff imports1 imports2 in
      let body_diff = list_diff body1 body2 in
      let whole_program_diff = list_diff stmts1 stmts2 in
      let split_len =
        all [imports_diff; body_diff]
        >>| Base.List.map ~f:List.length
        >>| List.fold_left ( + ) 0
        |> value ~default:max_int
      in
      let whole_len = value_map ~default:max_int whole_program_diff ~f:List.length in
      if split_len > whole_len then
        whole_program_diff
        >>= recurse_into_diff
              (fun x y -> Some (statement ~parent:TopLevelParentOfStatement x y))
              (fun s ->
                Some (expand_statement_comment_bounds s, Statement (s, TopLevelParentOfStatement)))
              stmts1
              0
      else
        imports_diff
        >>= recurse_into_diff
              (fun x y -> Some (statement ~parent:TopLevelParentOfStatement x y))
              (fun s ->
                Some (expand_statement_comment_bounds s, Statement (s, TopLevelParentOfStatement)))
              stmts1
              0
        >>= fun import_recurse ->
        body_diff
        >>= (List.length imports1
            |> recurse_into_diff
                 (fun x y -> Some (statement ~parent:TopLevelParentOfStatement x y))
                 (fun s ->
                   Some (expand_statement_comment_bounds s, Statement (s, TopLevelParentOfStatement)))
                 stmts1
            )
        >>| fun body_recurse -> import_recurse @ body_recurse
    )
  and statement_list
      ~(parent : statement_node_parent)
      (stmts1 : (Loc.t, Loc.t) Ast.Statement.t list)
      (stmts2 : (Loc.t, Loc.t) Ast.Statement.t list) : node change list option =
    diff_and_recurse_nonopt
      (statement ~parent)
      (fun s -> Some (expand_statement_comment_bounds s, Statement (s, parent)))
      stmts1
      stmts2
  and statement
      ~(parent : statement_node_parent)
      (stmt1 : (Loc.t, Loc.t) Ast.Statement.t)
      (stmt2 : (Loc.t, Loc.t) Ast.Statement.t) : node change list =
    let open Ast.Statement in
    let changes =
      match (stmt1, stmt2) with
      | ((loc, VariableDeclaration var1), (_, VariableDeclaration var2)) ->
        variable_declaration loc var1 var2
      | ((loc, FunctionDeclaration func1), (_, FunctionDeclaration func2)) ->
        function_declaration loc func1 func2
      | ((loc, ComponentDeclaration comp1), (_, ComponentDeclaration comp2)) ->
        component_declaration loc comp1 comp2
      | ((loc, ClassDeclaration class1), (_, ClassDeclaration class2)) -> class_ loc class1 class2
      | ((loc, InterfaceDeclaration intf1), (_, InterfaceDeclaration intf2)) ->
        interface loc intf1 intf2
      | ((loc, If if1), (_, If if2)) -> if_statement loc if1 if2
      | ((loc, Ast.Statement.Expression expr1), (_, Ast.Statement.Expression expr2)) ->
        expression_statement loc expr1 expr2
      | ((loc, Block block1), (_, Block block2)) -> block loc block1 block2
      | ((loc, For for1), (_, For for2)) -> for_statement loc for1 for2
      | ((loc, ForIn for_in1), (_, ForIn for_in2)) -> for_in_statement loc for_in1 for_in2
      | ((loc, While while1), (_, While while2)) -> Some (while_statement loc while1 while2)
      | ((loc, ForOf for_of1), (_, ForOf for_of2)) -> for_of_statement loc for_of1 for_of2
      | ((loc, DoWhile do_while1), (_, DoWhile do_while2)) ->
        Some (do_while_statement loc do_while1 do_while2)
      | ((loc, Switch switch1), (_, Switch switch2)) -> switch_statement loc switch1 switch2
      | ((loc, Return return1), (_, Return return2)) -> return_statement loc return1 return2
      | ((loc, Debugger dbg1), (_, Debugger dbg2)) -> debugger_statement loc dbg1 dbg2
      | ((loc, Continue cont1), (_, Continue cont2)) -> continue_statement loc cont1 cont2
      | ((loc, Labeled labeled1), (_, Labeled labeled2)) ->
        Some (labeled_statement loc labeled1 labeled2)
      | ((loc, With with1), (_, With with2)) -> Some (with_statement loc with1 with2)
      | ((loc, ExportDefaultDeclaration export1), (_, ExportDefaultDeclaration export2)) ->
        export_default_declaration loc export1 export2
      | ((loc, DeclareExportDeclaration export1), (_, DeclareExportDeclaration export2)) ->
        declare_export loc export1 export2
      | ((loc, ImportDeclaration import1), (_, ImportDeclaration import2)) ->
        import_declaration loc import1 import2
      | ((loc, ExportNamedDeclaration export1), (_, ExportNamedDeclaration export2)) ->
        export_named_declaration loc export1 export2
      | ((loc, Try try1), (_, Try try2)) -> try_ loc try1 try2
      | ((loc, Throw throw1), (_, Throw throw2)) -> Some (throw_statement loc throw1 throw2)
      | ((loc, DeclareTypeAlias d_t_alias1), (_, DeclareTypeAlias d_t_alias2)) ->
        type_alias loc d_t_alias1 d_t_alias2
      | ((loc, TypeAlias t_alias1), (_, TypeAlias t_alias2)) -> type_alias loc t_alias1 t_alias2
      | ((loc, OpaqueType o_type1), (_, OpaqueType o_type2)) -> opaque_type loc o_type1 o_type2
      | ((loc, DeclareClass declare_class_t1), (_, DeclareClass declare_class_t2)) ->
        declare_class loc declare_class_t1 declare_class_t2
      | ((loc, DeclareFunction func1), (_, DeclareFunction func2)) ->
        declare_function loc func1 func2
      | ((loc, DeclareVariable decl1), (_, DeclareVariable decl2)) ->
        declare_variable loc decl1 decl2
      | ((loc, EnumDeclaration enum1), (_, EnumDeclaration enum2)) ->
        enum_declaration loc enum1 enum2
      | ((loc, Match m1), (_, Match m2)) -> match_statement loc m1 m2
      | ((loc, Empty empty1), (_, Empty empty2)) -> empty_statement loc empty1 empty2
      | (_, _) -> None
    in
    let old_loc = Ast_utils.loc_of_statement stmt1 in
    Base.Option.value
      changes
      ~default:[replace old_loc (Statement (stmt1, parent)) (Statement (stmt2, parent))]
  and export_named_declaration loc export1 export2 =
    let open Ast.Statement.ExportNamedDeclaration in
    let {
      declaration = decl1;
      specifiers = specs1;
      source = src1;
      export_kind = kind1;
      comments = comments1;
    } =
      export1
    in
    let {
      declaration = decl2;
      specifiers = specs2;
      source = src2;
      export_kind = kind2;
      comments = comments2;
    } =
      export2
    in
    if src1 != src2 || kind1 != kind2 then
      None
    else
      let decls =
        diff_if_changed_nonopt_fn (statement ~parent:(ExportParentOfStatement loc)) decl1 decl2
      in
      let specs = diff_if_changed_opt export_named_declaration_specifier specs1 specs2 in
      let comments = syntax_opt loc comments1 comments2 in
      join_diff_list [decls; specs; comments]
  and export_default_declaration
      (loc : Loc.t)
      (export1 : (Loc.t, Loc.t) Ast.Statement.ExportDefaultDeclaration.t)
      (export2 : (Loc.t, Loc.t) Ast.Statement.ExportDefaultDeclaration.t) : node change list option
      =
    let open Ast.Statement.ExportDefaultDeclaration in
    let { declaration = declaration1; default = default1; comments = comments1 } = export1 in
    let { declaration = declaration2; default = default2; comments = comments2 } = export2 in
    if default1 != default2 then
      None
    else
      let declaration_diff =
        match (declaration1, declaration2) with
        | (Declaration s1, Declaration s2) ->
          statement ~parent:(ExportParentOfStatement loc) s1 s2 |> Base.Option.return
        | ( Ast.Statement.ExportDefaultDeclaration.Expression e1,
            Ast.Statement.ExportDefaultDeclaration.Expression e2
          ) ->
          expression
            ~parent:
              (StatementParentOfExpression (loc, Ast.Statement.ExportDefaultDeclaration export2))
            e1
            e2
          |> Base.Option.return
        | _ -> None
      in
      let comments_diff = syntax_opt loc comments1 comments2 in
      join_diff_list [declaration_diff; comments_diff]
  and export_specifier
      (spec1 : (Loc.t, Loc.t) Ast.Statement.ExportNamedDeclaration.ExportSpecifier.t)
      (spec2 : (Loc.t, Loc.t) Ast.Statement.ExportNamedDeclaration.ExportSpecifier.t) :
      node change list option =
    let open Ast.Statement.ExportNamedDeclaration.ExportSpecifier in
    let (_, { local = local1; exported = exported1; from_remote = _; imported_name_def_loc = _ }) =
      spec1
    in
    let (_, { local = local2; exported = exported2; from_remote = _; imported_name_def_loc = _ }) =
      spec2
    in
    let locals = diff_if_changed identifier local1 local2 |> Base.Option.return in
    let exporteds = diff_if_changed_nonopt_fn identifier exported1 exported2 in
    join_diff_list [locals; exporteds]
  and export_named_declaration_specifier
      (specs1 : (Loc.t, Loc.t) Ast.Statement.ExportNamedDeclaration.specifier)
      (specs2 : (Loc.t, Loc.t) Ast.Statement.ExportNamedDeclaration.specifier) =
    let open Ast.Statement.ExportNamedDeclaration in
    match (specs1, specs2) with
    | (ExportSpecifiers es1, ExportSpecifiers es2) ->
      diff_and_recurse_no_trivial export_specifier es1 es2
    | (ExportBatchSpecifier (_, ebs1), ExportBatchSpecifier (_, ebs2)) ->
      diff_if_changed_nonopt_fn identifier ebs1 ebs2
    | _ -> None
  and declare_export
      (loc : Loc.t)
      (export1 : (Loc.t, Loc.t) Ast.Statement.DeclareExportDeclaration.t)
      (export2 : (Loc.t, Loc.t) Ast.Statement.DeclareExportDeclaration.t) : node change list option
      =
    let open Ast.Statement.DeclareExportDeclaration in
    let {
      default = default1;
      declaration = decl1;
      specifiers = specs1;
      source = src1;
      comments = comments1;
    } =
      export1
    in
    let {
      default = default2;
      declaration = decl2;
      specifiers = specs2;
      source = src2;
      comments = comments2;
    } =
      export2
    in
    if default1 != default2 || src1 != src2 || decl1 != decl2 then
      None
    else
      let specs_diff = diff_if_changed_opt export_named_declaration_specifier specs1 specs2 in
      let comments_diff = syntax_opt loc comments1 comments2 in
      join_diff_list [specs_diff; comments_diff]
  and import_default_specifier
      (ds1 : (Loc.t, Loc.t) Ast.Statement.ImportDeclaration.default_identifier option)
      (ds2 : (Loc.t, Loc.t) Ast.Statement.ImportDeclaration.default_identifier option) :
      node change list option =
    let f ds1 ds2 =
      let open Ast.Statement.ImportDeclaration in
      let { identifier = id1; remote_default_name_def_loc = _ } = ds1 in
      let { identifier = id2; remote_default_name_def_loc = _ } = ds2 in
      identifier id1 id2
    in
    diff_if_changed_nonopt_fn f ds1 ds2
  and import_namespace_specifier
      (ident1 : (Loc.t, Loc.t) Ast.Identifier.t) (ident2 : (Loc.t, Loc.t) Ast.Identifier.t) :
      node change list option =
    diff_if_changed identifier ident1 ident2 |> Base.Option.return
  and import_named_specifier
      (nm_spec1 : (Loc.t, Loc.t) Ast.Statement.ImportDeclaration.named_specifier)
      (nm_spec2 : (Loc.t, Loc.t) Ast.Statement.ImportDeclaration.named_specifier) :
      node change list option =
    let open Ast.Statement.ImportDeclaration in
    let { kind = kind1; local = local1; remote = remote1; remote_name_def_loc = _ } = nm_spec1 in
    let { kind = kind2; local = local2; remote = remote2; remote_name_def_loc = _ } = nm_spec2 in
    if kind1 != kind2 then
      None
    else
      let locals = diff_if_changed_nonopt_fn identifier local1 local2 in
      let remotes = diff_if_changed identifier remote1 remote2 |> Base.Option.return in
      join_diff_list [locals; remotes]
  and import_specifier
      (spec1 : (Loc.t, Loc.t) Ast.Statement.ImportDeclaration.specifier)
      (spec2 : (Loc.t, Loc.t) Ast.Statement.ImportDeclaration.specifier) : node change list option =
    let open Ast.Statement.ImportDeclaration in
    match (spec1, spec2) with
    | (ImportNamedSpecifiers nm_specs1, ImportNamedSpecifiers nm_specs2) ->
      diff_and_recurse_no_trivial import_named_specifier nm_specs1 nm_specs2
    | (ImportNamespaceSpecifier (_, ident1), ImportNamespaceSpecifier (_, ident2)) ->
      diff_if_changed_ret_opt import_namespace_specifier ident1 ident2
    | _ -> None
  and import_declaration
      (loc : Loc.t)
      (import1 : (Loc.t, Loc.t) Ast.Statement.ImportDeclaration.t)
      (import2 : (Loc.t, Loc.t) Ast.Statement.ImportDeclaration.t) : node change list option =
    let open Ast.Statement.ImportDeclaration in
    let {
      import_kind = imprt_knd1;
      source = src1;
      default = dflt1;
      specifiers = spec1;
      comments = comments1;
    } =
      import1
    in
    let {
      import_kind = imprt_knd2;
      source = src2;
      default = dflt2;
      specifiers = spec2;
      comments = comments2;
    } =
      import2
    in
    if imprt_knd1 != imprt_knd2 || src1 != src2 then
      None
    else
      let dflt_diff = import_default_specifier dflt1 dflt2 in
      let spec_diff = diff_if_changed_opt import_specifier spec1 spec2 in
      let comments_diff = syntax_opt loc comments1 comments2 in
      join_diff_list [dflt_diff; spec_diff; comments_diff]
  and component_declaration
      (loc : Loc.t)
      (comp1 : (Loc.t, Loc.t) Ast.Statement.ComponentDeclaration.t)
      (comp2 : (Loc.t, Loc.t) Ast.Statement.ComponentDeclaration.t) =
    let open Ast.Statement.ComponentDeclaration in
    let {
      id = id1;
      params = params1;
      body = (loc_body, body1);
      renders = renders1;
      tparams = tparams1;
      sig_loc = _;
      comments = comments1;
    } =
      comp1
    in
    let {
      id = id2;
      params = params2;
      body = (_, body2);
      renders = renders2;
      tparams = tparams2;
      sig_loc = _;
      comments = comments2;
    } =
      comp2
    in
    let id = diff_if_changed_nonopt_fn identifier (Some id1) (Some id2) in
    let tparams = diff_if_changed_opt type_params tparams1 tparams2 in
    let params = diff_if_changed_ret_opt component_params params1 params2 in
    let returns =
      match (renders1, renders2) with
      | (Ast.Type.AvailableRenders (loc, r1), Ast.Type.AvailableRenders (_, r2)) ->
        diff_if_changed_ret_opt (render_type loc) r1 r2
      | (Ast.Type.MissingRenders _, Ast.Type.MissingRenders _) -> Some []
      | _ -> None
    in
    let body = diff_if_changed_ret_opt (block loc_body) body1 body2 in
    let comments = syntax_opt loc comments1 comments2 in
    join_diff_list [id; tparams; params; returns; body; comments]
  and component_params
      (params1 : (Loc.t, Loc.t) Ast.Statement.ComponentDeclaration.Params.t)
      (params2 : (Loc.t, Loc.t) Ast.Statement.ComponentDeclaration.Params.t) :
      node change list option =
    let open Ast.Statement.ComponentDeclaration.Params in
    let (loc, { params = param_lst1; rest = rest1; comments = comments1 }) = params1 in
    let (_, { params = param_lst2; rest = rest2; comments = comments2 }) = params2 in
    let params_diff = diff_and_recurse_no_trivial component_param param_lst1 param_lst2 in
    let rest_diff = diff_if_changed_opt component_rest_param rest1 rest2 in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [params_diff; rest_diff; comments_diff]
  and component_param
      (param1 : (Loc.t, Loc.t) Ast.Statement.ComponentDeclaration.Param.t)
      (param2 : (Loc.t, Loc.t) Ast.Statement.ComponentDeclaration.Param.t) : node change list option
      =
    let ( _,
          {
            Ast.Statement.ComponentDeclaration.Param.name = name1;
            local = local1;
            default = def1;
            shorthand = shorthand1;
          }
        ) =
      param1
    in
    let ( _,
          {
            Ast.Statement.ComponentDeclaration.Param.name = name2;
            local = local2;
            default = def2;
            shorthand = shorthand2;
          }
        ) =
      param2
    in
    let name_diff =
      match (name1, name2) with
      | ( Ast.Statement.ComponentDeclaration.Param.Identifier id1,
          Ast.Statement.ComponentDeclaration.Param.Identifier id2
        ) ->
        diff_if_changed_nonopt_fn identifier (Some id1) (Some id2)
      | ( Ast.Statement.ComponentDeclaration.Param.StringLiteral (loc1, lit1),
          Ast.Statement.ComponentDeclaration.Param.StringLiteral (loc2, lit2)
        ) ->
        diff_if_changed_ret_opt (string_literal loc1 loc2) lit1 lit2
      | ( Ast.Statement.ComponentDeclaration.Param.Identifier (loc1, { Ast.Identifier.name; _ }),
          Ast.Statement.ComponentDeclaration.Param.StringLiteral (loc2, lit2)
        ) ->
        Some [replace loc1 (Raw name) (StringLiteral (loc2, lit2))]
      | ( Ast.Statement.ComponentDeclaration.Param.StringLiteral (loc1, lit1),
          Ast.Statement.ComponentDeclaration.Param.Identifier (_, { Ast.Identifier.name; _ })
        ) ->
        Some [replace loc1 (StringLiteral (loc1, lit1)) (Raw name)]
    in
    let local_diff = diff_if_changed binding_pattern local1 local2 |> Base.Option.return in
    let default_diff =
      diff_if_changed_nonopt_fn (expression ~parent:SlotParentOfExpression) def1 def2
    in
    match (shorthand1, shorthand2) with
    | (false, false) -> join_diff_list [name_diff; local_diff; default_diff]
    | (true, true) -> join_diff_list [local_diff; default_diff]
    | (_, _) -> None
  and component_rest_param
      (elem1 : (Loc.t, Loc.t) Ast.Statement.ComponentDeclaration.RestParam.t)
      (elem2 : (Loc.t, Loc.t) Ast.Statement.ComponentDeclaration.RestParam.t) :
      node change list option =
    let open Ast.Statement.ComponentDeclaration.RestParam in
    let (loc, { argument = arg1; comments = comments1 }) = elem1 in
    let (_, { argument = arg2; comments = comments2 }) = elem2 in
    let arg_diff = Some (binding_pattern arg1 arg2) in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [arg_diff; comments_diff]
  and function_declaration loc func1 func2 = function_ loc func1 func2
  and function_
      ?(is_arrow = false)
      (loc : Loc.t)
      (func1 : (Loc.t, Loc.t) Ast.Function.t)
      (func2 : (Loc.t, Loc.t) Ast.Function.t) : node change list option =
    let open Ast.Function in
    let {
      id = id1;
      params = params1;
      body = body1;
      async = async1;
      generator = generator1;
      predicate = predicate1;
      effect_ = effect1;
      return = return1;
      tparams = tparams1;
      sig_loc = _;
      comments = comments1;
    } =
      func1
    in
    let {
      id = id2;
      params = params2;
      body = body2;
      async = async2;
      generator = generator2;
      effect_ = effect2;
      predicate = predicate2;
      return = return2;
      tparams = tparams2;
      sig_loc = _;
      comments = comments2;
    } =
      func2
    in
    if
      async1 != async2 || generator1 != generator2 || predicate1 != predicate2 || effect1 != effect2
    then
      None
    else
      let id = diff_if_changed_nonopt_fn identifier id1 id2 in
      let tparams = diff_if_changed_opt type_params tparams1 tparams2 in
      let params = diff_if_changed_ret_opt function_params params1 params2 in
      let returns = diff_if_changed function_return_annot return1 return2 |> Base.Option.return in
      let params =
        match (is_arrow, params1, params2, params, returns) with
        (* reprint the parameter if it's the single parameter of a lambda, or when return annotation
           has changed to add () to avoid syntax errors. *)
        | ( true,
            (l, { Params.params = [_p1]; rest = None; this_ = None; comments = _ }),
            (_, { Params.params = [_p2]; rest = None; this_ = None; comments = _ }),
            Some [_],
            _
          )
        | ( true,
            (l, { Params.params = [_p1]; rest = None; this_ = None; comments = _ }),
            (_, { Params.params = [_p2]; rest = None; this_ = None; comments = _ }),
            _,
            Some (_ :: _)
          ) ->
          Some [replace l (Params params1) (Params params2)]
        | _ -> params
      in
      let fnbody = diff_if_changed_ret_opt function_body_any body1 body2 in
      let comments = syntax_opt loc comments1 comments2 in
      join_diff_list [id; tparams; params; returns; fnbody; comments]
  and function_params
      (params1 : (Loc.t, Loc.t) Ast.Function.Params.t)
      (params2 : (Loc.t, Loc.t) Ast.Function.Params.t) : node change list option =
    let open Ast.Function.Params in
    let (loc, { params = param_lst1; rest = rest1; this_ = this1; comments = comments1 }) =
      params1
    in
    let (_, { params = param_lst2; rest = rest2; this_ = this2; comments = comments2 }) = params2 in
    let params_diff = diff_and_recurse_no_trivial function_param param_lst1 param_lst2 in
    let rest_diff = diff_if_changed_opt function_rest_param rest1 rest2 in
    let this_diff = diff_if_changed_opt function_this_param this1 this2 in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [params_diff; rest_diff; this_diff; comments_diff]
  and function_this_param
      (ftp1 : (Loc.t, Loc.t) Ast.Function.ThisParam.t)
      (ftp2 : (Loc.t, Loc.t) Ast.Function.ThisParam.t) : node change list option =
    let open Ast.Function.ThisParam in
    let (loc, { annot = annot1; comments = comments1 }) = ftp1 in
    let (_, { annot = annot2; comments = comments2 }) = ftp2 in
    let annot_diff = Some (diff_if_changed type_annotation annot1 annot2) in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [annot_diff; comments_diff]
  and function_param
      (param1 : (Loc.t, Loc.t) Ast.Function.Param.t) (param2 : (Loc.t, Loc.t) Ast.Function.Param.t)
      : node change list option =
    let (_, { Ast.Function.Param.argument = arg1; default = def1 }) = param1 in
    let (_, { Ast.Function.Param.argument = arg2; default = def2 }) = param2 in
    let param_diff = diff_if_changed function_param_pattern arg1 arg2 |> Base.Option.return in
    let default_diff =
      diff_if_changed_nonopt_fn (expression ~parent:SlotParentOfExpression) def1 def2
    in
    join_diff_list [param_diff; default_diff]
  and function_return_annot
      (return1 : (Loc.t, Loc.t) Ast.Function.ReturnAnnot.t)
      (return2 : (Loc.t, Loc.t) Ast.Function.ReturnAnnot.t) : node change list =
    let module RA = Ast.Function.ReturnAnnot in
    let annot_change typ =
      let open Ast.Type in
      match return2 with
      | RA.Available (_, (_, Function _)) -> FunctionTypeAnnotation typ
      | _ -> TypeAnnotation typ
    in
    match (return1, return2) with
    | (RA.Missing _, RA.Missing _) -> []
    | (RA.Available (loc1, typ), RA.Missing _) -> [delete loc1 (TypeAnnotation (loc1, typ))]
    | (RA.TypeGuard (loc1, grd), RA.Missing _) -> [delete loc1 (TypeGuardAnnotation (loc1, grd))]
    | (RA.Missing loc1, RA.Available annot) -> [(loc1, insert ~sep:None [annot_change annot])]
    | (RA.Missing loc1, RA.TypeGuard guard) ->
      [(loc1, insert ~sep:None [TypeGuardAnnotation guard])]
    | (RA.Available annot1, RA.Available annot2) -> type_annotation annot1 annot2
    | (RA.TypeGuard grd1, RA.TypeGuard grd2) -> type_guard_annotation grd1 grd2
    | (RA.Available (loc1, type1), RA.TypeGuard (loc2, guard2)) ->
      [replace loc1 (TypeAnnotation (loc1, type1)) (TypeGuardAnnotation (loc2, guard2))]
    | (RA.TypeGuard (loc1, guard1), RA.Available (loc2, type2)) ->
      [replace loc1 (TypeGuardAnnotation (loc1, guard1)) (TypeAnnotation (loc2, type2))]
  and function_body_any
      (body1 : (Loc.t, Loc.t) Ast.Function.body) (body2 : (Loc.t, Loc.t) Ast.Function.body) :
      node change list option =
    let open Ast.Function in
    match (body1, body2) with
    | (BodyExpression e1, BodyExpression e2) ->
      expression ~parent:SlotParentOfExpression e1 e2 |> Base.Option.return
    | (BodyBlock (loc, block1), BodyBlock (_, block2)) -> block loc block1 block2
    | _ -> None
  and variable_declarator
      (decl1 : (Loc.t, Loc.t) Ast.Statement.VariableDeclaration.Declarator.t)
      (decl2 : (Loc.t, Loc.t) Ast.Statement.VariableDeclaration.Declarator.t) :
      node change list option =
    let open Ast.Statement.VariableDeclaration.Declarator in
    let (_, { id = id1; init = init1 }) = decl1 in
    let (_, { id = id2; init = init2 }) = decl2 in
    let id_diff = diff_if_changed pattern id1 id2 |> Base.Option.return in
    let expr_diff =
      diff_if_changed_nonopt_fn (expression ~parent:SlotParentOfExpression) init1 init2
    in
    join_diff_list [id_diff; expr_diff]
  and variable_declaration
      (loc : Loc.t)
      (var1 : (Loc.t, Loc.t) Ast.Statement.VariableDeclaration.t)
      (var2 : (Loc.t, Loc.t) Ast.Statement.VariableDeclaration.t) : node change list option =
    let open Ast.Statement.VariableDeclaration in
    let { declarations = declarations1; kind = kind1; comments = comments1 } = var1 in
    let { declarations = declarations2; kind = kind2; comments = comments2 } = var2 in
    if kind1 != kind2 then
      None
    else
      let declarations_diff =
        if declarations1 != declarations2 then
          diff_and_recurse_no_trivial variable_declarator declarations1 declarations2
        else
          Some []
      in
      let comments_diff = syntax_opt loc comments1 comments2 in
      join_diff_list [declarations_diff; comments_diff]
  and if_statement
      loc (if1 : (Loc.t, Loc.t) Ast.Statement.If.t) (if2 : (Loc.t, Loc.t) Ast.Statement.If.t) :
      node change list option =
    let open Ast.Statement.If in
    let { test = test1; consequent = consequent1; alternate = alternate1; comments = comments1 } =
      if1
    in
    let { test = test2; consequent = consequent2; alternate = alternate2; comments = comments2 } =
      if2
    in
    let expr_diff =
      Some
        (diff_if_changed
           (expression ~parent:(StatementParentOfExpression (loc, Ast.Statement.If if2)))
           test1
           test2
        )
    in
    let parent = IfParentOfStatement loc in
    let cons_diff = Some (diff_if_changed (statement ~parent) consequent1 consequent2) in
    let alt_diff =
      match (alternate1, alternate2) with
      | (None, None) -> Some []
      | (Some _, None)
      | (None, Some _) ->
        None
      | ( Some (loc, { Alternate.body = body1; comments = comments1 }),
          Some (_, { Alternate.body = body2; comments = comments2 })
        ) ->
        let body_diff = Some (diff_if_changed (statement ~parent) body1 body2) in
        let comments_diff = syntax_opt loc comments1 comments2 in
        join_diff_list [body_diff; comments_diff]
    in
    let comments = syntax_opt loc comments1 comments2 in
    join_diff_list [comments; expr_diff; cons_diff; alt_diff]
  and with_statement
      (loc : Loc.t)
      (with1 : (Loc.t, Loc.t) Ast.Statement.With.t)
      (with2 : (Loc.t, Loc.t) Ast.Statement.With.t) : node change list =
    let open Ast.Statement.With in
    let { _object = _object1; body = body1; comments = comments1 } = with1 in
    let { _object = _object2; body = body2; comments = comments2 } = with2 in
    let _object_diff =
      diff_if_changed
        (expression ~parent:(StatementParentOfExpression (loc, Ast.Statement.With with2)))
        _object1
        _object2
    in
    let body_diff =
      diff_if_changed (statement ~parent:(WithStatementParentOfStatement loc)) body1 body2
    in
    let comments_diff = syntax_opt loc comments1 comments2 |> Base.Option.value ~default:[] in
    List.concat [_object_diff; body_diff; comments_diff]
  and try_
      loc (try1 : (Loc.t, Loc.t) Ast.Statement.Try.t) (try2 : (Loc.t, Loc.t) Ast.Statement.Try.t) =
    let open Ast.Statement.Try in
    let {
      block = (block_loc, block1);
      handler = handler1;
      finalizer = finalizer1;
      comments = comments1;
    } =
      try1
    in
    let { block = (_, block2); handler = handler2; finalizer = finalizer2; comments = comments2 } =
      try2
    in
    let comments = syntax_opt loc comments1 comments2 in
    let block_diff = diff_if_changed_ret_opt (block block_loc) block1 block2 in
    let finalizer_diff =
      match (finalizer1, finalizer2) with
      | (Some (loc, finalizer1), Some (_, finalizer2)) ->
        diff_if_changed_ret_opt (block loc) finalizer1 finalizer2
      | (None, None) -> Some []
      | _ -> None
    in
    let handler_diff = diff_if_changed_opt handler handler1 handler2 in
    join_diff_list [comments; block_diff; finalizer_diff; handler_diff]
  and handler
      (hand1 : (Loc.t, Loc.t) Ast.Statement.Try.CatchClause.t)
      (hand2 : (Loc.t, Loc.t) Ast.Statement.Try.CatchClause.t) =
    let open Ast.Statement.Try.CatchClause in
    let (old_loc, { body = (block_loc, block1); param = param1; comments = comments1 }) = hand1 in
    let (_new_loc, { body = (_, block2); param = param2; comments = comments2 }) = hand2 in
    let comments = syntax_opt old_loc comments1 comments2 in
    let body_diff = diff_if_changed_ret_opt (block block_loc) block1 block2 in
    let param_diff = diff_if_changed_nonopt_fn pattern param1 param2 in
    join_diff_list [comments; body_diff; param_diff]
  and class_
      (loc : Loc.t) (class1 : (Loc.t, Loc.t) Ast.Class.t) (class2 : (Loc.t, Loc.t) Ast.Class.t) =
    let open Ast.Class in
    let {
      id = id1;
      body = body1;
      tparams = tparams1;
      extends = extends1;
      implements = implements1;
      class_decorators = class_decorators1;
      comments = comments1;
    } =
      class1
    in
    let {
      id = id2;
      body = body2;
      tparams = tparams2;
      extends = extends2;
      implements = implements2;
      class_decorators = class_decorators2;
      comments = comments2;
    } =
      class2
    in
    if id1 != id2 then
      None
    else
      let tparams_diff = diff_if_changed_opt type_params tparams1 tparams2 in
      let extends_diff = diff_if_changed_opt class_extends extends1 extends2 in
      let implements_diff = diff_if_changed_opt class_implements implements1 implements2 in
      let body_diff = diff_if_changed_ret_opt class_body body1 body2 in
      let decorators_diff =
        diff_and_recurse_no_trivial class_decorator class_decorators1 class_decorators2
      in
      let comments_diff = syntax_opt loc comments1 comments2 in
      join_diff_list
        [tparams_diff; extends_diff; implements_diff; body_diff; decorators_diff; comments_diff]
  and class_extends
      ((loc, extends1) : (Loc.t, Loc.t) Ast.Class.Extends.t)
      ((_, extends2) : (Loc.t, Loc.t) Ast.Class.Extends.t) =
    let open Ast.Class.Extends in
    let { expr = expr1; targs = targs1; comments = comments1 } = extends1 in
    let { expr = expr2; targs = targs2; comments = comments2 } = extends2 in
    let expr_diff =
      diff_if_changed (expression ~parent:SlotParentOfExpression) expr1 expr2 |> Base.Option.return
    in
    let targs_diff = diff_if_changed_opt type_args targs1 targs2 in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [expr_diff; targs_diff; comments_diff]
  and class_implements
      ((loc, implements1) : (Loc.t, Loc.t) Ast.Class.Implements.t)
      ((_, implements2) : (Loc.t, Loc.t) Ast.Class.Implements.t) : node change list option =
    let open Ast.Class.Implements in
    let { interfaces = interfaces1; comments = comments1 } = implements1 in
    let { interfaces = interfaces2; comments = comments2 } = implements2 in
    let interfaces_diff =
      diff_and_recurse_no_trivial class_implements_interface interfaces1 interfaces2
    in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [interfaces_diff; comments_diff]
  and class_implements_interface
      ((_, interface1) : (Loc.t, Loc.t) Ast.Class.Implements.Interface.t)
      ((_, interface2) : (Loc.t, Loc.t) Ast.Class.Implements.Interface.t) : node change list option
      =
    let open Ast.Class.Implements.Interface in
    let { id = id1; targs = targs1 } = interface1 in
    let { id = id2; targs = targs2 } = interface2 in
    let id_diff = Some (diff_if_changed identifier id1 id2) in
    let targs_diff = diff_if_changed_opt type_args targs1 targs2 in
    join_diff_list [id_diff; targs_diff]
  and interface
      (loc : Loc.t)
      (intf1 : (Loc.t, Loc.t) Ast.Statement.Interface.t)
      (intf2 : (Loc.t, Loc.t) Ast.Statement.Interface.t) : node change list option =
    let open Ast.Statement.Interface in
    let {
      id = id1;
      tparams = tparams1;
      extends = extends1;
      body = (body_loc, body1);
      comments = comments1;
    } =
      intf1
    in
    let {
      id = id2;
      tparams = tparams2;
      extends = extends2;
      body = (_, body2);
      comments = comments2;
    } =
      intf2
    in
    let id_diff = diff_if_changed identifier id1 id2 |> Base.Option.return in
    let tparams_diff = diff_if_changed_opt type_params tparams1 tparams2 in
    let extends_diff = diff_and_recurse_no_trivial generic_type_with_loc extends1 extends2 in
    let body_diff = diff_if_changed_ret_opt (object_type body_loc) body1 body2 in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [id_diff; tparams_diff; extends_diff; body_diff; comments_diff]
  and class_body
      (class_body1 : (Loc.t, Loc.t) Ast.Class.Body.t) (class_body2 : (Loc.t, Loc.t) Ast.Class.Body.t)
      : node change list option =
    let open Ast.Class.Body in
    let (loc, { body = body1; comments = comments1 }) = class_body1 in
    let (_, { body = body2; comments = comments2 }) = class_body2 in
    let body_diff = diff_and_recurse_no_trivial class_element body1 body2 in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [body_diff; comments_diff]
  and class_decorator
      ((loc, dec1) : (Loc.t, Loc.t) Ast.Class.Decorator.t)
      ((_, dec2) : (Loc.t, Loc.t) Ast.Class.Decorator.t) : node change list option =
    let open Ast.Class.Decorator in
    let { expression = expression1; comments = comments1 } = dec1 in
    let { expression = expression2; comments = comments2 } = dec2 in
    let expression_diff =
      Some (expression ~parent:SlotParentOfExpression expression1 expression2)
    in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [expression_diff; comments_diff]
  and class_element
      (elem1 : (Loc.t, Loc.t) Ast.Class.Body.element) (elem2 : (Loc.t, Loc.t) Ast.Class.Body.element)
      : node change list option =
    let open Ast.Class.Body in
    match (elem1, elem2) with
    | (Method (loc, m1), Method (_, m2)) -> class_method loc m1 m2
    | (Property p1, Property p2) -> class_property p1 p2 |> Base.Option.return
    | (PrivateField f1, PrivateField f2) -> class_private_field f1 f2 |> Base.Option.return
    | (Method _, _)
    | (_, Method _) ->
      None
    | (Property p1, PrivateField f2) ->
      Some [replace (fst p1) (ClassProperty p1) (ClassPrivateField f2)]
    | (PrivateField f1, Property p2) ->
      Some [replace (fst f1) (ClassPrivateField f1) (ClassProperty p2)]
    | (StaticBlock _, _)
    | (_, StaticBlock _) ->
      None
  and class_private_field field1 field2 : node change list =
    let open Ast.Class.PrivateField in
    let ( loc1,
          {
            key = key1;
            value = val1;
            annot = annot1;
            static = s1;
            variance = var1;
            decorators = decorators1;
            comments = comments1;
          }
        ) =
      field1
    in
    let ( _,
          {
            key = key2;
            value = val2;
            annot = annot2;
            static = s2;
            variance = var2;
            decorators = decorators2;
            comments = comments2;
          }
        ) =
      field2
    in
    ( if key1 != key2 || s1 != s2 || var1 != var2 then
      None
    else
      let vals = diff_if_changed_ret_opt class_property_value val1 val2 in
      let annots = Some (diff_if_changed type_annotation_hint annot1 annot2) in
      let decorators = diff_and_recurse_no_trivial class_decorator decorators1 decorators2 in
      let comments = syntax_opt loc1 comments1 comments2 in
      join_diff_list [vals; annots; decorators; comments]
    )
    |> Base.Option.value
         ~default:[replace loc1 (ClassPrivateField field1) (ClassPrivateField field2)]
  and class_property prop1 prop2 : node change list =
    let open Ast.Class.Property in
    let ( loc1,
          {
            key = key1;
            value = val1;
            annot = annot1;
            static = s1;
            variance = var1;
            decorators = decorators1;
            comments = comments1;
          }
        ) =
      prop1
    in
    let ( _,
          {
            key = key2;
            value = val2;
            annot = annot2;
            static = s2;
            variance = var2;
            decorators = decorators2;
            comments = comments2;
          }
        ) =
      prop2
    in
    ( if key1 != key2 || s1 != s2 || var1 != var2 then
      None
    else
      let vals = diff_if_changed_ret_opt class_property_value val1 val2 in
      let annots = Some (diff_if_changed type_annotation_hint annot1 annot2) in
      let decorators = diff_and_recurse_no_trivial class_decorator decorators1 decorators2 in
      let comments = syntax_opt loc1 comments1 comments2 in
      join_diff_list [vals; annots; decorators; comments]
    )
    |> Base.Option.value ~default:[replace loc1 (ClassProperty prop1) (ClassProperty prop2)]
  and class_property_value val1 val2 : node change list option =
    let open Ast.Class.Property in
    match (val1, val2) with
    | (Declared, Declared) -> Some []
    | (Uninitialized, Uninitialized) -> Some []
    | (Initialized e1, Initialized e2) ->
      Some (diff_if_changed (expression ~parent:SlotParentOfExpression) e1 e2)
    | _ -> None
  and class_method
      (loc : Loc.t)
      (m1 : (Loc.t, Loc.t) Ast.Class.Method.t')
      (m2 : (Loc.t, Loc.t) Ast.Class.Method.t') : node change list option =
    let open Ast.Class.Method in
    let {
      kind = kind1;
      key = key1;
      value = (value_loc, value1);
      static = static1;
      decorators = decorators1;
      comments = comments1;
    } =
      m1
    in
    let {
      kind = kind2;
      key = key2;
      value = (_loc, value2);
      static = static2;
      decorators = decorators2;
      comments = comments2;
    } =
      m2
    in
    if
      kind1 != kind2
      || key1 != key2
      (* value handled below *)
      || static1 != static2
    then
      None
    else
      let value_diff = function_ value_loc value1 value2 in
      let decorators_diff = diff_and_recurse_no_trivial class_decorator decorators1 decorators2 in
      let comments_diff = syntax_opt loc comments1 comments2 in
      join_diff_list [value_diff; decorators_diff; comments_diff]
  and block
      (loc : Loc.t)
      (block1 : (Loc.t, Loc.t) Ast.Statement.Block.t)
      (block2 : (Loc.t, Loc.t) Ast.Statement.Block.t) : node change list option =
    let open Ast.Statement.Block in
    let { body = body1; comments = comments1 } = block1 in
    let { body = body2; comments = comments2 } = block2 in
    let body_diff = statement_list ~parent:(StatementBlockParentOfStatement loc) body1 body2 in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [body_diff; comments_diff]
  and expression_statement
      (loc : Loc.t)
      (stmt1 : (Loc.t, Loc.t) Ast.Statement.Expression.t)
      (stmt2 : (Loc.t, Loc.t) Ast.Statement.Expression.t) : node change list option =
    let open Ast.Statement.Expression in
    let { expression = expr1; directive = dir1; comments = comments1 } = stmt1 in
    let { expression = expr2; directive = dir2; comments = comments2 } = stmt2 in
    if dir1 != dir2 then
      None
    else
      let expression_diff =
        Some
          (expression
             ~parent:(StatementParentOfExpression (loc, Ast.Statement.Expression stmt2))
             expr1
             expr2
          )
      in
      let comments_diff = syntax_opt loc comments1 comments2 in
      join_diff_list [expression_diff; comments_diff]
  and expression
      ~(parent : expression_node_parent)
      (expr1 : (Loc.t, Loc.t) Ast.Expression.t)
      (expr2 : (Loc.t, Loc.t) Ast.Expression.t) : node change list =
    let changes =
      (* The open is here to avoid ambiguity with the use of the local `Expression` constructor
       * below *)
      let open Ast.Expression in
      match (expr1, expr2) with
      | ((loc1, Ast.Expression.StringLiteral lit1), (loc2, Ast.Expression.StringLiteral lit2)) ->
        diff_if_changed_ret_opt (string_literal loc1 loc2) lit1 lit2
      | ((loc1, Ast.Expression.BooleanLiteral lit1), (loc2, Ast.Expression.BooleanLiteral lit2)) ->
        diff_if_changed_ret_opt (boolean_literal loc1 loc2) lit1 lit2
      | ((loc1, Ast.Expression.NullLiteral lit1), (_, Ast.Expression.NullLiteral lit2)) ->
        diff_if_changed_ret_opt (syntax_opt loc1) lit1 lit2
      | ((loc1, Ast.Expression.NumberLiteral lit1), (loc2, Ast.Expression.NumberLiteral lit2)) ->
        diff_if_changed_ret_opt (number_literal loc1 loc2) lit1 lit2
      | ((loc1, Ast.Expression.BigIntLiteral lit1), (loc2, Ast.Expression.BigIntLiteral lit2)) ->
        diff_if_changed_ret_opt (bigint_literal loc1 loc2) lit1 lit2
      | ((loc1, Ast.Expression.RegExpLiteral lit1), (loc2, Ast.Expression.RegExpLiteral lit2)) ->
        diff_if_changed_ret_opt (regexp_literal loc1 loc2) lit1 lit2
      | ((loc1, Ast.Expression.ModuleRefLiteral lit1), (loc2, Ast.Expression.ModuleRefLiteral lit2))
        ->
        diff_if_changed_ret_opt (module_ref_literal loc1 loc2) lit1 lit2
      | ((loc, Binary b1), (_, Binary b2)) -> binary loc b1 b2
      | ((loc, Unary u1), (_, Unary u2)) -> unary loc u1 u2
      | ((_, Ast.Expression.Identifier id1), (_, Ast.Expression.Identifier id2)) ->
        identifier id1 id2 |> Base.Option.return
      | ((loc, Conditional c1), (_, Conditional c2)) -> conditional loc c1 c2 |> Base.Option.return
      | ((loc, New new1), (_, New new2)) -> new_ loc new1 new2
      | ((loc, Member member1), (_, Member member2)) -> member loc member1 member2
      | ((loc, Call call1), (_, Call call2)) -> call loc call1 call2
      | ((loc, ArrowFunction f1), (_, ArrowFunction f2)) -> function_ ~is_arrow:true loc f1 f2
      | ((loc, Function f1), (_, Function f2)) -> function_ loc f1 f2
      | ((loc, Class class1), (_, Class class2)) -> class_ loc class1 class2
      | ((loc, Assignment assn1), (_, Assignment assn2)) -> assignment loc assn1 assn2
      | ((loc, Object obj1), (_, Object obj2)) -> object_ loc obj1 obj2
      | ((loc, TaggedTemplate t_tmpl1), (_, TaggedTemplate t_tmpl2)) ->
        Some (tagged_template loc t_tmpl1 t_tmpl2)
      | ( (loc1, Ast.Expression.TemplateLiteral t_lit1),
          (loc2, Ast.Expression.TemplateLiteral t_lit2)
        ) ->
        Some (template_literal loc1 loc2 t_lit1 t_lit2)
      | ((loc, JSXElement jsx_elem1), (_, JSXElement jsx_elem2)) ->
        jsx_element loc jsx_elem1 jsx_elem2
      | ((loc, JSXFragment frag1), (_, JSXFragment frag2)) -> jsx_fragment loc frag1 frag2
      | ((loc, TypeCast t1), (_, TypeCast t2)) -> Some (type_cast loc t1 t2)
      | ((loc, Logical l1), (_, Logical l2)) -> logical loc l1 l2
      | ((loc, Array arr1), (_, Array arr2)) -> array loc arr1 arr2
      | ((_, (AsExpression _ | TSSatisfies _)), (_, TypeCast _)) -> None
      | (expr, (loc, TypeCast t2)) -> Some (type_cast_added parent expr loc t2)
      | ((loc, Update update1), (_, Update update2)) -> update loc update1 update2
      | ((loc, Sequence seq1), (_, Sequence seq2)) -> sequence loc seq1 seq2
      | ((loc, This t1), (_, This t2)) -> this_expression loc t1 t2
      | ((loc, Super s1), (_, Super s2)) -> super_expression loc s1 s2
      | ((loc, MetaProperty m1), (_, MetaProperty m2)) -> meta_property loc m1 m2
      | ((loc, Import i1), (_, Import i2)) -> import_expression loc i1 i2
      | ((loc, Match m1), (_, Match m2)) -> match_expression loc m1 m2
      | (_, _) -> None
    in
    let old_loc = Ast_utils.loc_of_expression expr1 in
    Base.Option.value
      changes
      ~default:[replace old_loc (Expression (expr1, parent)) (Expression (expr2, parent))]
  and string_literal loc1 loc2 lit1 lit2 =
    let open Ast.StringLiteral in
    let { value = val1; raw = raw1; comments = comments1 } = lit1 in
    let { value = val2; raw = raw2; comments = comments2 } = lit2 in
    let value_diff =
      if String.equal val1 val2 && String.equal raw1 raw2 then
        Some []
      else
        Some [replace loc1 (StringLiteral (loc1, lit1)) (StringLiteral (loc2, lit2))]
    in
    let comments_diff = syntax_opt loc1 comments1 comments2 in
    join_diff_list [value_diff; comments_diff]
  and number_literal loc1 loc2 lit1 lit2 =
    let open Ast.NumberLiteral in
    let { value = value1; raw = raw1; comments = comments1 } = lit1 in
    let { value = value2; raw = raw2; comments = comments2 } = lit2 in
    let value_diff =
      if value1 = value2 && String.equal raw1 raw2 then
        Some []
      else
        Some [replace loc1 (NumberLiteral (loc1, lit1)) (NumberLiteral (loc2, lit2))]
    in
    let comments_diff = syntax_opt loc1 comments1 comments2 in
    join_diff_list [value_diff; comments_diff]
  and bigint_literal loc1 loc2 lit1 lit2 =
    let open Ast.BigIntLiteral in
    let { value = value1; raw = raw1; comments = comments1 } = lit1 in
    let { value = value2; raw = raw2; comments = comments2 } = lit2 in
    let value_diff =
      if value1 = value2 && String.equal raw1 raw2 then
        Some []
      else
        Some [replace loc1 (BigIntLiteral (loc1, lit1)) (BigIntLiteral (loc2, lit2))]
    in
    let comments_diff = syntax_opt loc1 comments1 comments2 in
    join_diff_list [value_diff; comments_diff]
  and boolean_literal loc1 loc2 lit1 lit2 =
    let open Ast.BooleanLiteral in
    let { value = value1; comments = comments1 } = lit1 in
    let { value = value2; comments = comments2 } = lit2 in
    let value_diff =
      if value1 = value2 then
        Some []
      else
        Some [replace loc1 (BooleanLiteral (loc1, lit1)) (BooleanLiteral (loc2, lit2))]
    in
    let comments_diff = syntax_opt loc1 comments1 comments2 in
    join_diff_list [value_diff; comments_diff]
  and regexp_literal loc1 loc2 lit1 lit2 =
    let open Ast.RegExpLiteral in
    let { pattern = pattern1; flags = flags1; raw = raw1; comments = comments1 } = lit1 in
    let { pattern = pattern2; flags = flags2; raw = raw2; comments = comments2 } = lit2 in
    let value_diff =
      if pattern1 = pattern2 && flags1 = flags2 && raw1 = raw2 then
        Some []
      else
        Some [replace loc1 (RegExpLiteral (loc1, lit1)) (RegExpLiteral (loc2, lit2))]
    in
    let comments_diff = syntax_opt loc1 comments1 comments2 in
    join_diff_list [value_diff; comments_diff]
  and module_ref_literal loc1 loc2 lit1 lit2 =
    Some [replace loc1 (ModuleRefLiteral (loc1, lit1)) (ModuleRefLiteral (loc2, lit2))]
  and tagged_template
      (loc : Loc.t)
      (t_tmpl1 : (Loc.t, Loc.t) Ast.Expression.TaggedTemplate.t)
      (t_tmpl2 : (Loc.t, Loc.t) Ast.Expression.TaggedTemplate.t) : node change list =
    let open Ast.Expression.TaggedTemplate in
    let { tag = tag1; quasi = (quasi_loc1, quasi1); comments = comments1 } = t_tmpl1 in
    let { tag = tag2; quasi = (quasi_loc2, quasi2); comments = comments2 } = t_tmpl2 in
    let tag_diff =
      diff_if_changed
        (expression
           ~parent:(ExpressionParentOfExpression (loc, Ast.Expression.TaggedTemplate t_tmpl2))
        )
        tag1
        tag2
    in
    let quasi_diff = diff_if_changed (template_literal quasi_loc1 quasi_loc2) quasi1 quasi2 in
    let comments_diff = syntax_opt loc comments1 comments2 |> Base.Option.value ~default:[] in
    Base.List.concat [tag_diff; quasi_diff; comments_diff]
  and template_literal
      (loc1 : Loc.t)
      (loc2 : Loc.t)
      (* Need to pass in locs because TemplateLiteral doesn't have a loc attached *)
        (t_lit1 : (Loc.t, Loc.t) Ast.Expression.TemplateLiteral.t)
      (t_lit2 : (Loc.t, Loc.t) Ast.Expression.TemplateLiteral.t) : node change list =
    let open Ast.Expression.TemplateLiteral in
    let { quasis = quasis1; expressions = exprs1; comments = comments1 } = t_lit1 in
    let { quasis = quasis2; expressions = exprs2; comments = comments2 } = t_lit2 in
    let quasis_diff = diff_and_recurse_no_trivial template_literal_element quasis1 quasis2 in
    let exprs_diff =
      diff_and_recurse_nonopt_no_trivial
        (expression
           ~parent:(ExpressionParentOfExpression (loc1, Ast.Expression.TemplateLiteral t_lit2))
        )
        exprs1
        exprs2
    in
    let comments_diff = syntax_opt loc1 comments1 comments2 in
    let result = join_diff_list [quasis_diff; exprs_diff; comments_diff] in
    Base.Option.value
      result
      ~default:[replace loc1 (TemplateLiteral (loc1, t_lit1)) (TemplateLiteral (loc2, t_lit2))]
  and template_literal_element
      (tl_elem1 : Loc.t Ast.Expression.TemplateLiteral.Element.t)
      (tl_elem2 : Loc.t Ast.Expression.TemplateLiteral.Element.t) : node change list option =
    let open Ast.Expression.TemplateLiteral.Element in
    let (_, { value = value1; tail = tail1 }) = tl_elem1 in
    let (_, { value = value2; tail = tail2 }) = tl_elem2 in
    (* These are primitives, so structural equality is fine *)
    if value1.raw <> value2.raw || value1.cooked <> value2.cooked || tail1 <> tail2 then
      None
    else
      Some []
  and jsx_element
      (loc : Loc.t)
      (jsx_elem1 : (Loc.t, Loc.t) Ast.JSX.element)
      (jsx_elem2 : (Loc.t, Loc.t) Ast.JSX.element) : node change list option =
    let open Ast.JSX in
    let {
      opening_element = open_elem1;
      closing_element = close_elem1;
      children = (_, children1);
      comments = comments1;
    } =
      jsx_elem1
    in
    let {
      opening_element = open_elem2;
      closing_element = close_elem2;
      children = (_, children2);
      comments = comments2;
    } =
      jsx_elem2
    in
    let opening_diff = diff_if_changed_ret_opt jsx_opening_element open_elem1 open_elem2 in
    let children_diff = diff_and_recurse_nonopt_no_trivial jsx_child children1 children2 in
    let closing_diff = diff_if_changed_opt jsx_closing_element close_elem1 close_elem2 in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [opening_diff; children_diff; closing_diff; comments_diff]
  and jsx_fragment
      (loc : Loc.t)
      (frag1 : (Loc.t, Loc.t) Ast.JSX.fragment)
      (frag2 : (Loc.t, Loc.t) Ast.JSX.fragment) : node change list option =
    let open Ast.JSX in
    (* Opening and closing elements contain no information besides loc, so we
     * ignore them for the diff *)
    let {
      frag_opening_element = _;
      frag_children = (_, children1);
      frag_closing_element = _;
      frag_comments = frag_comments1;
    } =
      frag1
    in
    let {
      frag_opening_element = _;
      frag_children = (_, children2);
      frag_closing_element = _;
      frag_comments = frag_comments2;
    } =
      frag2
    in
    let children_diff = diff_and_recurse_nonopt_no_trivial jsx_child children1 children2 in
    let frag_comments_diff = syntax_opt loc frag_comments1 frag_comments2 in
    join_diff_list [children_diff; frag_comments_diff]
  and jsx_opening_element
      (elem1 : (Loc.t, Loc.t) Ast.JSX.Opening.t) (elem2 : (Loc.t, Loc.t) Ast.JSX.Opening.t) :
      node change list option =
    let open Ast.JSX.Opening in
    let (_, { name = name1; targs = targs1; self_closing = self_close1; attributes = attrs1 }) =
      elem1
    in
    let (_, { name = name2; targs = targs2; self_closing = self_close2; attributes = attrs2 }) =
      elem2
    in
    if self_close1 != self_close2 then
      None
    else
      let name_diff = diff_if_changed_ret_opt jsx_element_name name1 name2 in
      let targs_diff = diff_if_changed_ret_opt (diff_if_changed_opt call_type_args) targs1 targs2 in
      let attrs_diff = diff_and_recurse_no_trivial jsx_opening_attribute attrs1 attrs2 in
      join_diff_list [name_diff; targs_diff; attrs_diff]
  and jsx_element_name (name1 : (Loc.t, Loc.t) Ast.JSX.name) (name2 : (Loc.t, Loc.t) Ast.JSX.name) :
      node change list option =
    let open Ast.JSX in
    match (name1, name2) with
    | (Ast.JSX.Identifier id1, Ast.JSX.Identifier id2) ->
      Some (diff_if_changed jsx_identifier id1 id2)
    | (NamespacedName namespaced_name1, NamespacedName namespaced_name2) ->
      Some (diff_if_changed jsx_namespaced_name namespaced_name1 namespaced_name2)
    | (MemberExpression member_expr1, MemberExpression member_expr2) ->
      diff_if_changed_ret_opt jsx_member_expression member_expr1 member_expr2
    | _ -> None
  and jsx_identifier
      (id1 : (Loc.t, Loc.t) Ast.JSX.Identifier.t) (id2 : (Loc.t, Loc.t) Ast.JSX.Identifier.t) :
      node change list =
    let open Ast.JSX.Identifier in
    let (old_loc, { name = name1; comments = comments1 }) = id1 in
    let (_, { name = name2; comments = comments2 }) = id2 in
    let name_diff =
      if name1 = name2 then
        []
      else
        [replace old_loc (JSXIdentifier id1) (JSXIdentifier id2)]
    in
    let comments_diff = syntax_opt old_loc comments1 comments2 |> Base.Option.value ~default:[] in
    name_diff @ comments_diff
  and jsx_namespaced_name
      (namespaced_name1 : (Loc.t, Loc.t) Ast.JSX.NamespacedName.t)
      (namespaced_name2 : (Loc.t, Loc.t) Ast.JSX.NamespacedName.t) : node change list =
    let open Ast.JSX.NamespacedName in
    let (_, { namespace = namespace1; name = name1 }) = namespaced_name1 in
    let (_, { namespace = namespace2; name = name2 }) = namespaced_name2 in
    let namespace_diff = diff_if_changed jsx_identifier namespace1 namespace2 in
    let name_diff = diff_if_changed jsx_identifier name1 name2 in
    namespace_diff @ name_diff
  and jsx_member_expression
      (member_expr1 : (Loc.t, Loc.t) Ast.JSX.MemberExpression.t)
      (member_expr2 : (Loc.t, Loc.t) Ast.JSX.MemberExpression.t) : node change list option =
    let open Ast.JSX.MemberExpression in
    let (_, { _object = object1; property = prop1 }) = member_expr1 in
    let (_, { _object = object2; property = prop2 }) = member_expr2 in
    let obj_diff =
      match (object1, object2) with
      | (Ast.JSX.MemberExpression.Identifier id1, Ast.JSX.MemberExpression.Identifier id2) ->
        Some (diff_if_changed jsx_identifier id1 id2)
      | (MemberExpression member_expr1', MemberExpression member_expr2') ->
        diff_if_changed_ret_opt jsx_member_expression member_expr1' member_expr2'
      | _ -> None
    in
    let prop_diff = diff_if_changed jsx_identifier prop1 prop2 |> Base.Option.return in
    join_diff_list [obj_diff; prop_diff]
  and jsx_closing_element
      (elem1 : (Loc.t, Loc.t) Ast.JSX.Closing.t) (elem2 : (Loc.t, Loc.t) Ast.JSX.Closing.t) :
      node change list option =
    let open Ast.JSX.Closing in
    let (_, { name = name1 }) = elem1 in
    let (_, { name = name2 }) = elem2 in
    diff_if_changed_ret_opt jsx_element_name name1 name2
  and jsx_opening_attribute
      (jsx_attr1 : (Loc.t, Loc.t) Ast.JSX.Opening.attribute)
      (jsx_attr2 : (Loc.t, Loc.t) Ast.JSX.Opening.attribute) : node change list option =
    let open Ast.JSX.Opening in
    match (jsx_attr1, jsx_attr2) with
    | (Attribute attr1, Attribute attr2) -> diff_if_changed_ret_opt jsx_attribute attr1 attr2
    | (SpreadAttribute ((loc, _) as attr1), SpreadAttribute attr2) ->
      diff_if_changed_ret_opt (jsx_spread_attribute loc) attr1 attr2
    | _ -> None
  and jsx_spread_attribute
      (loc : Loc.t)
      (attr1 : (Loc.t, Loc.t) Ast.JSX.SpreadAttribute.t)
      (attr2 : (Loc.t, Loc.t) Ast.JSX.SpreadAttribute.t) : node change list option =
    let open Flow_ast.JSX.SpreadAttribute in
    let (_, { argument = arg1; comments = comments1 }) = attr1 in
    let (_, { argument = arg2; comments = comments2 }) = attr2 in
    let argument_diff =
      Some (diff_if_changed (expression ~parent:SpreadParentOfExpression) arg1 arg2)
    in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [argument_diff; comments_diff]
  and jsx_attribute
      (attr1 : (Loc.t, Loc.t) Ast.JSX.Attribute.t) (attr2 : (Loc.t, Loc.t) Ast.JSX.Attribute.t) :
      node change list option =
    let open Ast.JSX.Attribute in
    let (_, { name = name1; value = value1 }) = attr1 in
    let (_, { name = name2; value = value2 }) = attr2 in
    let name_diff =
      match (name1, name2) with
      | (Ast.JSX.Attribute.Identifier id1, Ast.JSX.Attribute.Identifier id2) ->
        Some (diff_if_changed jsx_identifier id1 id2)
      | (NamespacedName namespaced_name1, NamespacedName namespaced_name2) ->
        Some (diff_if_changed jsx_namespaced_name namespaced_name1 namespaced_name2)
      | _ -> None
    in
    let value_diff =
      match (value1, value2) with
      | ( Some (Ast.JSX.Attribute.StringLiteral (loc1, lit1)),
          Some (Ast.JSX.Attribute.StringLiteral (loc2, lit2))
        ) ->
        diff_if_changed_ret_opt (string_literal loc1 loc2) lit1 lit2
      | (Some (ExpressionContainer (loc, expr1)), Some (ExpressionContainer (_, expr2))) ->
        diff_if_changed_ret_opt (jsx_expression loc) expr1 expr2
      | _ -> None
    in
    join_diff_list [name_diff; value_diff]
  and jsx_child (child1 : (Loc.t, Loc.t) Ast.JSX.child) (child2 : (Loc.t, Loc.t) Ast.JSX.child) :
      node change list =
    let open Ast.JSX in
    let (old_loc, child1') = child1 in
    let (_, child2') = child2 in
    if child1' == child2' then
      []
    else
      let changes =
        match (child1', child2') with
        | (Element elem1, Element elem2) ->
          diff_if_changed_ret_opt (jsx_element old_loc) elem1 elem2
        | (Fragment frag1, Fragment frag2) ->
          diff_if_changed_ret_opt (jsx_fragment old_loc) frag1 frag2
        | (ExpressionContainer expr1, ExpressionContainer expr2) ->
          diff_if_changed_ret_opt (jsx_expression old_loc) expr1 expr2
        | (SpreadChild spread1, SpreadChild spread2) ->
          diff_if_changed_ret_opt (jsx_spread_child old_loc) spread1 spread2
        | (Text _, Text _) -> None
        | _ -> None
      in
      Base.Option.value changes ~default:[replace old_loc (JSXChild child1) (JSXChild child2)]
  and jsx_expression
      (loc : Loc.t)
      (jsx_expr1 : (Loc.t, Loc.t) Ast.JSX.ExpressionContainer.t)
      (jsx_expr2 : (Loc.t, Loc.t) Ast.JSX.ExpressionContainer.t) : node change list option =
    let open Ast.JSX in
    let { ExpressionContainer.expression = expr1; comments = comments1 } = jsx_expr1 in
    let { ExpressionContainer.expression = expr2; comments = comments2 } = jsx_expr2 in
    let comments_diff = syntax_opt loc comments1 comments2 in
    let expression_diff =
      match (expr1, expr2) with
      | (ExpressionContainer.Expression expr1', ExpressionContainer.Expression expr2') ->
        Some (diff_if_changed (expression ~parent:SlotParentOfExpression) expr1' expr2')
      | (ExpressionContainer.EmptyExpression, ExpressionContainer.EmptyExpression) -> Some []
      | _ -> None
    in
    join_diff_list [expression_diff; comments_diff]
  and jsx_spread_child
      (loc : Loc.t)
      (jsx_spread_child1 : (Loc.t, Loc.t) Ast.JSX.SpreadChild.t)
      (jsx_spread_child2 : (Loc.t, Loc.t) Ast.JSX.SpreadChild.t) : node change list option =
    let open Ast.JSX.SpreadChild in
    let { expression = expr1; comments = comments1 } = jsx_spread_child1 in
    let { expression = expr2; comments = comments2 } = jsx_spread_child2 in
    let expression_diff =
      Some (diff_if_changed (expression ~parent:SpreadParentOfExpression) expr1 expr2)
    in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [expression_diff; comments_diff]
  and assignment
      (loc : Loc.t)
      (assn1 : (Loc.t, Loc.t) Ast.Expression.Assignment.t)
      (assn2 : (Loc.t, Loc.t) Ast.Expression.Assignment.t) : node change list option =
    let open Ast.Expression.Assignment in
    let { operator = op1; left = pat1; right = exp1; comments = comments1 } = assn1 in
    let { operator = op2; left = pat2; right = exp2; comments = comments2 } = assn2 in
    if op1 != op2 then
      None
    else
      let pat_diff = diff_if_changed pattern pat1 pat2 in
      let exp_diff =
        diff_if_changed
          (expression ~parent:(ExpressionParentOfExpression (loc, Ast.Expression.Assignment assn2)))
          exp1
          exp2
      in
      let comments_diff = syntax_opt loc comments1 comments2 |> Base.Option.value ~default:[] in
      Some (List.concat [pat_diff; exp_diff; comments_diff])
  and object_spread_property loc prop1 prop2 =
    let open Ast.Expression.Object.SpreadProperty in
    let { argument = arg1; comments = comments1 } = prop1 in
    let { argument = arg2; comments = comments2 } = prop2 in
    let argument_diff =
      Some (diff_if_changed (expression ~parent:SpreadParentOfExpression) arg1 arg2)
    in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [argument_diff; comments_diff]
  and object_key key1 key2 =
    let module EOP = Ast.Expression.Object.Property in
    match (key1, key2) with
    | (EOP.StringLiteral (loc1, l1), EOP.StringLiteral (loc2, l2)) ->
      diff_if_changed_ret_opt (string_literal loc1 loc2) l1 l2
    | (EOP.NumberLiteral (loc1, l1), EOP.NumberLiteral (loc2, l2)) ->
      diff_if_changed_ret_opt (number_literal loc1 loc2) l1 l2
    | (EOP.BigIntLiteral (loc1, l1), EOP.BigIntLiteral (loc2, l2)) ->
      diff_if_changed_ret_opt (bigint_literal loc1 loc2) l1 l2
    | (EOP.Identifier i1, EOP.Identifier i2) ->
      diff_if_changed identifier i1 i2 |> Base.Option.return
    | (EOP.Computed (loc, c1), EOP.Computed (_, c2)) -> computed_key loc c1 c2
    | (_, _) -> None
  and object_regular_property (loc, prop1) (_, prop2) =
    let open Ast.Expression.Object.Property in
    match (prop1, prop2) with
    | ( Init { shorthand = sh1; value = val1; key = key1 },
        Init { shorthand = sh2; value = val2; key = key2 }
      ) ->
      if sh1 != sh2 then
        None
      else
        let values =
          diff_if_changed (expression ~parent:SlotParentOfExpression) val1 val2
          |> Base.Option.return
        in
        let keys = diff_if_changed_ret_opt object_key key1 key2 in
        join_diff_list [keys; values]
    | (Method { value = val1; key = key1 }, Method { value = val2; key = key2 }) ->
      let values = diff_if_changed_ret_opt (function_ (fst val1)) (snd val1) (snd val2) in
      let keys = diff_if_changed_ret_opt object_key key1 key2 in
      join_diff_list [keys; values]
    | ( Get { value = val1; key = key1; comments = comments1 },
        Get { value = val2; key = key2; comments = comments2 }
      )
    | ( Set { value = val1; key = key1; comments = comments1 },
        Set { value = val2; key = key2; comments = comments2 }
      ) ->
      let key_diff = diff_if_changed_ret_opt object_key key1 key2 in
      let value_diff = diff_if_changed_ret_opt (function_ (fst val1)) (snd val1) (snd val2) in
      let comments_diff = syntax_opt loc comments1 comments2 in
      join_diff_list [key_diff; value_diff; comments_diff]
    | _ -> None
  and object_property prop1 prop2 =
    let open Ast.Expression.Object in
    match (prop1, prop2) with
    | (Property (loc, p1), Property p2) ->
      object_regular_property (loc, p1) p2
      |> Base.Option.value ~default:[replace loc (ObjectProperty prop1) (ObjectProperty prop2)]
      |> Base.Option.return
    | (SpreadProperty (loc, p1), SpreadProperty (_, p2)) -> object_spread_property loc p1 p2
    | _ -> None
  and object_ loc obj1 obj2 =
    let open Ast.Expression.Object in
    let { properties = properties1; comments = comments1 } = obj1 in
    let { properties = properties2; comments = comments2 } = obj2 in
    let comments = syntax_opt loc comments1 comments2 in
    join_diff_list [comments; diff_and_recurse_no_trivial object_property properties1 properties2]
  and binary
      (loc : Loc.t)
      (b1 : (Loc.t, Loc.t) Ast.Expression.Binary.t)
      (b2 : (Loc.t, Loc.t) Ast.Expression.Binary.t) : node change list option =
    let open Ast.Expression.Binary in
    let { operator = op1; left = left1; right = right1; comments = comments1 } = b1 in
    let { operator = op2; left = left2; right = right2; comments = comments2 } = b2 in
    if op1 != op2 then
      None
    else
      let parent = ExpressionParentOfExpression (loc, Ast.Expression.Binary b2) in
      let left_diff = diff_if_changed (expression ~parent) left1 left2 in
      let right_diff = diff_if_changed (expression ~parent) right1 right2 in
      let comments_diff = syntax_opt loc comments1 comments2 |> Base.Option.value ~default:[] in
      Some (List.concat [left_diff; right_diff; comments_diff])
  and unary
      loc (u1 : (Loc.t, Loc.t) Ast.Expression.Unary.t) (u2 : (Loc.t, Loc.t) Ast.Expression.Unary.t)
      : node change list option =
    let open Ast.Expression.Unary in
    let { operator = op1; argument = arg1; comments = comments1 } = u1 in
    let { operator = op2; argument = arg2; comments = comments2 } = u2 in
    let comments = syntax_opt loc comments1 comments2 |> Base.Option.value ~default:[] in
    if op1 != op2 then
      None
    else
      Some
        (comments
        @ expression ~parent:(ExpressionParentOfExpression (loc, Ast.Expression.Unary u2)) arg1 arg2
        )
  and identifier (id1 : (Loc.t, Loc.t) Ast.Identifier.t) (id2 : (Loc.t, Loc.t) Ast.Identifier.t) :
      node change list =
    let (old_loc, { Ast.Identifier.name = name1; comments = comments1 }) = id1 in
    let (_new_loc, { Ast.Identifier.name = name2; comments = comments2 }) = id2 in
    let name =
      if String.equal name1 name2 then
        []
      else
        [replace old_loc (Raw name1) (Raw name2)]
    in
    let comments = syntax_opt old_loc comments1 comments2 |> Base.Option.value ~default:[] in
    comments @ name
  and conditional
      (loc : Loc.t)
      (c1 : (Loc.t, Loc.t) Ast.Expression.Conditional.t)
      (c2 : (Loc.t, Loc.t) Ast.Expression.Conditional.t) : node change list =
    let open Ast.Expression.Conditional in
    let { test = test1; consequent = cons1; alternate = alt1; comments = comments1 } = c1 in
    let { test = test2; consequent = cons2; alternate = alt2; comments = comments2 } = c2 in
    let parent = ExpressionParentOfExpression (loc, Ast.Expression.Conditional c2) in
    let test_diff = diff_if_changed (expression ~parent) test1 test2 in
    let cons_diff = diff_if_changed (expression ~parent) cons1 cons2 in
    let alt_diff = diff_if_changed (expression ~parent) alt1 alt2 in
    let comments_diff = syntax_opt loc comments1 comments2 |> Base.Option.value ~default:[] in
    Base.List.concat [test_diff; cons_diff; alt_diff; comments_diff]
  and new_
      loc (new1 : (Loc.t, Loc.t) Ast.Expression.New.t) (new2 : (Loc.t, Loc.t) Ast.Expression.New.t)
      : node change list option =
    let open Ast.Expression.New in
    let { callee = callee1; targs = targs1; arguments = arguments1; comments = comments1 } = new1 in
    let { callee = callee2; targs = targs2; arguments = arguments2; comments = comments2 } = new2 in
    let comments = syntax_opt loc comments1 comments2 in
    let targs = diff_if_changed_ret_opt (diff_if_changed_opt call_type_args) targs1 targs2 in
    let args = diff_if_changed_ret_opt (diff_if_changed_opt call_args) arguments1 arguments2 in
    let callee =
      Some
        (diff_if_changed
           (expression ~parent:(ExpressionParentOfExpression (loc, Ast.Expression.New new2)))
           callee1
           callee2
        )
    in
    join_diff_list [comments; targs; args; callee]
  and member
      (loc : Loc.t)
      (member1 : (Loc.t, Loc.t) Ast.Expression.Member.t)
      (member2 : (Loc.t, Loc.t) Ast.Expression.Member.t) : node change list option =
    let open Ast.Expression.Member in
    let { _object = obj1; property = prop1; comments = comments1 } = member1 in
    let { _object = obj2; property = prop2; comments = comments2 } = member2 in
    let obj =
      Some
        (diff_if_changed
           (expression ~parent:(ExpressionParentOfExpression (loc, Ast.Expression.Member member2)))
           obj1
           obj2
        )
    in
    let prop = diff_if_changed_ret_opt member_property prop1 prop2 in
    let comments = syntax_opt loc comments1 comments2 in
    join_diff_list [obj; prop; comments]
  and member_property
      (prop1 : (Loc.t, Loc.t) Ast.Expression.Member.property)
      (prop2 : (Loc.t, Loc.t) Ast.Expression.Member.property) : node change list option =
    let open Ast.Expression.Member in
    match (prop1, prop2) with
    | (PropertyExpression exp1, PropertyExpression exp2) ->
      Some (diff_if_changed (expression ~parent:SlotParentOfExpression) exp1 exp2)
    | (PropertyIdentifier id1, PropertyIdentifier id2) -> Some (diff_if_changed identifier id1 id2)
    | (PropertyPrivateName (loc, n1), PropertyPrivateName (_, n2)) ->
      Some (diff_if_changed (private_name loc) n1 n2)
    | (_, _) -> None
  and call
      (loc : Loc.t)
      (call1 : (Loc.t, Loc.t) Ast.Expression.Call.t)
      (call2 : (Loc.t, Loc.t) Ast.Expression.Call.t) : node change list option =
    let open Ast.Expression.Call in
    let { callee = callee1; targs = targs1; arguments = arguments1; comments = comments1 } =
      call1
    in
    let { callee = callee2; targs = targs2; arguments = arguments2; comments = comments2 } =
      call2
    in
    let targs = diff_if_changed_ret_opt (diff_if_changed_opt call_type_args) targs1 targs2 in
    let args = diff_if_changed_ret_opt call_args arguments1 arguments2 in
    let callee =
      Some
        (diff_if_changed
           (expression ~parent:(ExpressionParentOfExpression (loc, Ast.Expression.Call call2)))
           callee1
           callee2
        )
    in
    let comments = syntax_opt loc comments1 comments2 in
    join_diff_list [targs; args; callee; comments]
  and call_type_arg
      (t1 : (Loc.t, Loc.t) Ast.Expression.CallTypeArg.t)
      (t2 : (Loc.t, Loc.t) Ast.Expression.CallTypeArg.t) : node change list option =
    let open Ast.Expression.CallTypeArg in
    match (t1, t2) with
    | (Explicit type1, Explicit type2) -> Some (diff_if_changed type_ type1 type2)
    | (Implicit (loc, type1), Implicit (_, type2)) ->
      let { Implicit.comments = comments1 } = type1 in
      let { Implicit.comments = comments2 } = type2 in
      syntax_opt loc comments1 comments2
    | _ -> None
  and call_type_args
      (pi1 : (Loc.t, Loc.t) Ast.Expression.CallTypeArgs.t)
      (pi2 : (Loc.t, Loc.t) Ast.Expression.CallTypeArgs.t) : node change list option =
    let open Ast.Expression.CallTypeArgs in
    let (loc, { arguments = arguments1; comments = comments1 }) = pi1 in
    let (_, { arguments = arguments2; comments = comments2 }) = pi2 in
    let args_diff = diff_and_recurse_no_trivial call_type_arg arguments1 arguments2 in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [args_diff; comments_diff]
  and call_args
      (args1 : (Loc.t, Loc.t) Ast.Expression.ArgList.t)
      (args2 : (Loc.t, Loc.t) Ast.Expression.ArgList.t) : node change list option =
    let open Ast.Expression.ArgList in
    let (loc, { arguments = arguments1; comments = comments1 }) = args1 in
    let (_, { arguments = arguments2; comments = comments2 }) = args2 in
    let args_diff = diff_and_recurse_no_trivial expression_or_spread arguments1 arguments2 in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [args_diff; comments_diff]
  and expression_or_spread
      (expr1 : (Loc.t, Loc.t) Ast.Expression.expression_or_spread)
      (expr2 : (Loc.t, Loc.t) Ast.Expression.expression_or_spread) : node change list option =
    match (expr1, expr2) with
    | (Ast.Expression.Expression e1, Ast.Expression.Expression e2) ->
      Some (diff_if_changed (expression ~parent:SlotParentOfExpression) e1 e2)
    | (Ast.Expression.Spread spread1, Ast.Expression.Spread spread2) ->
      diff_if_changed_ret_opt spread_element spread1 spread2
    | (_, _) -> None
  and array_element
      (element1 : (Loc.t, Loc.t) Ast.Expression.Array.element)
      (element2 : (Loc.t, Loc.t) Ast.Expression.Array.element) : node change list option =
    let open Ast.Expression in
    match (element1, element2) with
    | (Array.Hole _, Array.Hole _) -> Some []
    | (Array.Expression e1, Array.Expression e2) ->
      Some (diff_if_changed (expression ~parent:SlotParentOfExpression) e1 e2)
    | (Array.Spread s1, Array.Spread s2) -> diff_if_changed_ret_opt spread_element s1 s2
    | _ -> None
  and spread_element
      (spread1 : (Loc.t, Loc.t) Ast.Expression.SpreadElement.t)
      (spread2 : (Loc.t, Loc.t) Ast.Expression.SpreadElement.t) : node change list option =
    let open Ast.Expression.SpreadElement in
    let (loc, { argument = arg1; comments = comments1 }) = spread1 in
    let (_, { argument = arg2; comments = comments2 }) = spread2 in
    let argument_diff =
      Some (diff_if_changed (expression ~parent:SpreadParentOfExpression) arg1 arg2)
    in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [argument_diff; comments_diff]
  and logical loc expr1 expr2 =
    let open Ast.Expression.Logical in
    let { left = left1; right = right1; operator = operator1; comments = comments1 } = expr1 in
    let { left = left2; right = right2; operator = operator2; comments = comments2 } = expr2 in
    if operator1 == operator2 then
      let parent = ExpressionParentOfExpression (loc, Ast.Expression.Logical expr2) in
      let left = diff_if_changed (expression ~parent) left1 left2 in
      let right = diff_if_changed (expression ~parent) right1 right2 in
      let comments = syntax_opt loc comments1 comments2 |> Base.Option.value ~default:[] in
      Some (Base.List.concat [left; right; comments])
    else
      None
  and array loc arr1 arr2 : node change list option =
    let open Ast.Expression.Array in
    let { elements = elems1; comments = comments1 } = arr1 in
    let { elements = elems2; comments = comments2 } = arr2 in
    let comments = syntax_opt loc comments1 comments2 in
    let elements = diff_and_recurse_no_trivial array_element elems1 elems2 in
    join_diff_list [comments; elements]
  and sequence loc seq1 seq2 : node change list option =
    let open Ast.Expression.Sequence in
    let { expressions = exps1; comments = comments1 } = seq1 in
    let { expressions = exps2; comments = comments2 } = seq2 in
    let expressions_diff =
      diff_and_recurse_nonopt_no_trivial
        (expression ~parent:(ExpressionParentOfExpression (loc, Ast.Expression.Sequence seq2)))
        exps1
        exps2
    in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [expressions_diff; comments_diff]
  and for_statement
      (loc : Loc.t)
      (stmt1 : (Loc.t, Loc.t) Ast.Statement.For.t)
      (stmt2 : (Loc.t, Loc.t) Ast.Statement.For.t) : node change list option =
    let open Ast.Statement.For in
    let { init = init1; test = test1; update = update1; body = body1; comments = comments1 } =
      stmt1
    in
    let { init = init2; test = test2; update = update2; body = body2; comments = comments2 } =
      stmt2
    in
    let init = diff_if_changed_opt for_statement_init init1 init2 in
    let parent = StatementParentOfExpression (loc, Ast.Statement.For stmt2) in
    let test = diff_if_changed_nonopt_fn (expression ~parent) test1 test2 in
    let update = diff_if_changed_nonopt_fn (expression ~parent) update1 update2 in
    let body = Some (diff_if_changed (statement ~parent:(LoopParentOfStatement loc)) body1 body2) in
    let comments = syntax_opt loc comments1 comments2 in
    join_diff_list [init; test; update; body; comments]
  and for_statement_init
      (init1 : (Loc.t, Loc.t) Ast.Statement.For.init) (init2 : (Loc.t, Loc.t) Ast.Statement.For.init)
      : node change list option =
    let open Ast.Statement.For in
    match (init1, init2) with
    | (InitDeclaration (loc, decl1), InitDeclaration (_, decl2)) ->
      variable_declaration loc decl1 decl2
    | (InitExpression expr1, InitExpression expr2) ->
      Some (diff_if_changed (expression ~parent:SlotParentOfExpression) expr1 expr2)
    | (InitDeclaration _, InitExpression _)
    | (InitExpression _, InitDeclaration _) ->
      None
  and for_in_statement
      (loc : Loc.t)
      (stmt1 : (Loc.t, Loc.t) Ast.Statement.ForIn.t)
      (stmt2 : (Loc.t, Loc.t) Ast.Statement.ForIn.t) : node change list option =
    let open Ast.Statement.ForIn in
    let { left = left1; right = right1; body = body1; each = each1; comments = comments1 } =
      stmt1
    in
    let { left = left2; right = right2; body = body2; each = each2; comments = comments2 } =
      stmt2
    in
    let left =
      if left1 == left2 then
        Some []
      else
        for_in_statement_lhs left1 left2
    in
    let body = Some (diff_if_changed (statement ~parent:(LoopParentOfStatement loc)) body1 body2) in
    let right =
      Some
        (diff_if_changed
           (expression ~parent:(StatementParentOfExpression (loc, Ast.Statement.ForIn stmt2)))
           right1
           right2
        )
    in
    let each =
      if each1 != each2 then
        None
      else
        Some []
    in
    let comments = syntax_opt loc comments1 comments2 in
    join_diff_list [left; right; body; each; comments]
  and for_in_statement_lhs
      (left1 : (Loc.t, Loc.t) Ast.Statement.ForIn.left)
      (left2 : (Loc.t, Loc.t) Ast.Statement.ForIn.left) : node change list option =
    let open Ast.Statement.ForIn in
    match (left1, left2) with
    | (LeftDeclaration (loc, decl1), LeftDeclaration (_, decl2)) ->
      variable_declaration loc decl1 decl2
    | (LeftPattern p1, LeftPattern p2) -> Some (pattern p1 p2)
    | (LeftDeclaration _, LeftPattern _)
    | (LeftPattern _, LeftDeclaration _) ->
      None
  and while_statement
      loc
      (stmt1 : (Loc.t, Loc.t) Ast.Statement.While.t)
      (stmt2 : (Loc.t, Loc.t) Ast.Statement.While.t) : node change list =
    let open Ast.Statement.While in
    let { body = body1; test = test1; comments = comments1 } = stmt1 in
    let { body = body2; test = test2; comments = comments2 } = stmt2 in
    let test =
      diff_if_changed
        (expression ~parent:(StatementParentOfExpression (loc, Ast.Statement.While stmt2)))
        test1
        test2
    in
    let body = diff_if_changed (statement ~parent:(LoopParentOfStatement loc)) body1 body2 in
    let comments = syntax_opt loc comments1 comments2 |> Base.Option.value ~default:[] in
    test @ body @ comments
  and for_of_statement
      (loc : Loc.t)
      (stmt1 : (Loc.t, Loc.t) Ast.Statement.ForOf.t)
      (stmt2 : (Loc.t, Loc.t) Ast.Statement.ForOf.t) : node change list option =
    let open Ast.Statement.ForOf in
    let { left = left1; right = right1; body = body1; await = await1; comments = comments1 } =
      stmt1
    in
    let { left = left2; right = right2; body = body2; await = await2; comments = comments2 } =
      stmt2
    in
    let left =
      if left1 == left2 then
        Some []
      else
        for_of_statement_lhs left1 left2
    in
    let body = Some (diff_if_changed (statement ~parent:(LoopParentOfStatement loc)) body1 body2) in
    let right =
      Some
        (diff_if_changed
           (expression ~parent:(StatementParentOfExpression (loc, Ast.Statement.ForOf stmt2)))
           right1
           right2
        )
    in
    let await =
      if await1 != await2 then
        None
      else
        Some []
    in
    let comments = syntax_opt loc comments1 comments2 in
    join_diff_list [left; right; body; await; comments]
  and for_of_statement_lhs
      (left1 : (Loc.t, Loc.t) Ast.Statement.ForOf.left)
      (left2 : (Loc.t, Loc.t) Ast.Statement.ForOf.left) : node change list option =
    let open Ast.Statement.ForOf in
    match (left1, left2) with
    | (LeftDeclaration (loc, decl1), LeftDeclaration (_, decl2)) ->
      variable_declaration loc decl1 decl2
    | (LeftPattern p1, LeftPattern p2) -> Some (pattern p1 p2)
    | (LeftDeclaration _, LeftPattern _)
    | (LeftPattern _, LeftDeclaration _) ->
      None
  and do_while_statement
      loc
      (stmt1 : (Loc.t, Loc.t) Ast.Statement.DoWhile.t)
      (stmt2 : (Loc.t, Loc.t) Ast.Statement.DoWhile.t) : node change list =
    let open Ast.Statement.DoWhile in
    let { body = body1; test = test1; comments = comments1 } = stmt1 in
    let { body = body2; test = test2; comments = comments2 } = stmt2 in
    let body = diff_if_changed (statement ~parent:(LoopParentOfStatement loc)) body1 body2 in
    let test =
      diff_if_changed
        (expression ~parent:(StatementParentOfExpression (loc, Ast.Statement.DoWhile stmt2)))
        test1
        test2
    in
    let comments = syntax_opt loc comments1 comments2 |> Base.Option.value ~default:[] in
    Base.List.concat [body; test; comments]
  and debugger_statement
      loc (stmt1 : Loc.t Ast.Statement.Debugger.t) (stmt2 : Loc.t Ast.Statement.Debugger.t) :
      node change list option =
    let open Ast.Statement.Debugger in
    let { comments = comments1 } = stmt1 in
    let { comments = comments2 } = stmt2 in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [comments_diff]
  and continue_statement
      loc (stmt1 : Loc.t Ast.Statement.Continue.t) (stmt2 : Loc.t Ast.Statement.Continue.t) :
      node change list option =
    let open Ast.Statement.Continue in
    let { comments = comments1; _ } = stmt1 in
    let { comments = comments2; _ } = stmt2 in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [comments_diff]
  and return_statement
      loc
      (stmt1 : (Loc.t, Loc.t) Ast.Statement.Return.t)
      (stmt2 : (Loc.t, Loc.t) Ast.Statement.Return.t) : node change list option =
    let open Ast.Statement.Return in
    let { argument = argument1; comments = comments1; return_out = ro1 } = stmt1 in
    let { argument = argument2; comments = comments2; return_out = ro2 } = stmt2 in
    if ro1 != ro2 then
      None
    else
      let comments = syntax_opt loc comments1 comments2 in
      join_diff_list
        [
          comments;
          diff_if_changed_nonopt_fn
            (expression ~parent:(StatementParentOfExpression (loc, Ast.Statement.Return stmt2)))
            argument1
            argument2;
        ]
  and throw_statement
      loc
      (stmt1 : (Loc.t, Loc.t) Ast.Statement.Throw.t)
      (stmt2 : (Loc.t, Loc.t) Ast.Statement.Throw.t) : node change list =
    let open Ast.Statement.Throw in
    let { argument = argument1; comments = comments1 } = stmt1 in
    let { argument = argument2; comments = comments2 } = stmt2 in
    let argument =
      diff_if_changed
        (expression ~parent:(StatementParentOfExpression (loc, Ast.Statement.Throw stmt2)))
        argument1
        argument2
    in
    let comments = syntax_opt loc comments1 comments2 |> Base.Option.value ~default:[] in
    argument @ comments
  and labeled_statement
      loc
      (labeled1 : (Loc.t, Loc.t) Ast.Statement.Labeled.t)
      (labeled2 : (Loc.t, Loc.t) Ast.Statement.Labeled.t) : node change list =
    let open Ast.Statement.Labeled in
    let { label = label1; body = body1; comments = comments1 } = labeled1 in
    let { label = label2; body = body2; comments = comments2 } = labeled2 in
    let label_diff = diff_if_changed identifier label1 label2 in
    let body_diff =
      diff_if_changed (statement ~parent:(LabeledStatementParentOfStatement loc)) body1 body2
    in
    let comments_diff = syntax_opt loc comments1 comments2 |> Base.Option.value ~default:[] in
    Base.List.concat [label_diff; body_diff; comments_diff]
  and switch_statement
      (loc : Loc.t)
      (stmt1 : (Loc.t, Loc.t) Ast.Statement.Switch.t)
      (stmt2 : (Loc.t, Loc.t) Ast.Statement.Switch.t) : node change list option =
    let open Ast.Statement.Switch in
    let { discriminant = discriminant1; cases = cases1; comments = comments1; exhaustive_out = ex1 }
        =
      stmt1
    in
    let { discriminant = discriminant2; cases = cases2; comments = comments2; exhaustive_out = ex2 }
        =
      stmt2
    in
    if ex1 != ex2 then
      None
    else
      let discriminant =
        Some
          (diff_if_changed
             (expression ~parent:(StatementParentOfExpression (loc, Ast.Statement.Switch stmt2)))
             discriminant1
             discriminant2
          )
      in
      let cases = diff_and_recurse_no_trivial switch_case cases1 cases2 in
      let comments = syntax_opt loc comments1 comments2 in
      join_diff_list [discriminant; cases; comments]
  and switch_case
      ((loc, s1) : (Loc.t, Loc.t) Ast.Statement.Switch.Case.t)
      ((_, s2) : (Loc.t, Loc.t) Ast.Statement.Switch.Case.t) : node change list option =
    let open Ast.Statement.Switch.Case in
    let { test = test1; case_test_loc = _; consequent = consequent1; comments = comments1 } = s1 in
    let { test = test2; case_test_loc = _; consequent = consequent2; comments = comments2 } = s2 in
    let test = diff_if_changed_nonopt_fn (expression ~parent:SlotParentOfExpression) test1 test2 in
    let consequent =
      statement_list ~parent:(SwitchCaseParentOfStatement loc) consequent1 consequent2
    in
    let comments = syntax_opt loc comments1 comments2 in
    join_diff_list [test; consequent; comments]
  and function_param_pattern
      (pat1 : (Loc.t, Loc.t) Ast.Pattern.t) (pat2 : (Loc.t, Loc.t) Ast.Pattern.t) : node change list
      =
    binding_pattern pat1 pat2
  and binding_pattern (pat1 : (Loc.t, Loc.t) Ast.Pattern.t) (pat2 : (Loc.t, Loc.t) Ast.Pattern.t) :
      node change list =
    pattern pat1 pat2
  and pattern (p1 : (Loc.t, Loc.t) Ast.Pattern.t) (p2 : (Loc.t, Loc.t) Ast.Pattern.t) :
      node change list =
    let changes =
      match (p1, p2) with
      | ((_, Ast.Pattern.Identifier i1), (_, Ast.Pattern.Identifier i2)) -> pattern_identifier i1 i2
      | ((loc, Ast.Pattern.Array a1), (_, Ast.Pattern.Array a2)) -> pattern_array loc a1 a2
      | ((loc, Ast.Pattern.Object o1), (_, Ast.Pattern.Object o2)) -> pattern_object loc o1 o2
      | ((_, Ast.Pattern.Expression e1), (_, Ast.Pattern.Expression e2)) ->
        Some (expression ~parent:SlotParentOfExpression e1 e2)
      | (_, _) -> None
    in
    let old_loc = Ast_utils.loc_of_pattern p1 in
    Base.Option.value changes ~default:[replace old_loc (Pattern p1) (Pattern p2)]
  and pattern_object
      (loc : Loc.t)
      (o1 : (Loc.t, Loc.t) Ast.Pattern.Object.t)
      (o2 : (Loc.t, Loc.t) Ast.Pattern.Object.t) : node change list option =
    let open Ast.Pattern.Object in
    let { properties = properties1; annot = annot1; comments = comments1 } = o1 in
    let { properties = properties2; annot = annot2; comments = comments2 } = o2 in
    let properties_diff =
      diff_and_recurse_no_trivial pattern_object_property properties1 properties2
    in
    let annot_diff = diff_if_changed type_annotation_hint annot1 annot2 |> Base.Option.return in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [properties_diff; annot_diff; comments_diff]
  and pattern_object_property
      (p1 : (Loc.t, Loc.t) Ast.Pattern.Object.property)
      (p2 : (Loc.t, Loc.t) Ast.Pattern.Object.property) : node change list option =
    let open Ast.Pattern.Object in
    match (p1, p2) with
    | (Property (_, p3), Property (_, p4)) ->
      let open Ast.Pattern.Object.Property in
      let { key = key1; pattern = pattern1; default = default1; shorthand = shorthand1 } = p3 in
      let { key = key2; pattern = pattern2; default = default2; shorthand = shorthand2 } = p4 in
      let keys = diff_if_changed_ret_opt pattern_object_property_key key1 key2 in
      let pats = Some (diff_if_changed pattern pattern1 pattern2) in
      let defaults =
        diff_if_changed_nonopt_fn (expression ~parent:SlotParentOfExpression) default1 default2
      in
      (match (shorthand1, shorthand2) with
      | (false, false) -> join_diff_list [keys; pats; defaults]
      | (_, _) -> None)
    | (RestElement re1, RestElement re2) -> pattern_rest_element re1 re2
    | (_, _) -> None
  and pattern_object_property_key
      (k1 : (Loc.t, Loc.t) Ast.Pattern.Object.Property.key)
      (k2 : (Loc.t, Loc.t) Ast.Pattern.Object.Property.key) : node change list option =
    let module POP = Ast.Pattern.Object.Property in
    match (k1, k2) with
    | (POP.StringLiteral (loc1, l1), POP.StringLiteral (loc2, l2)) ->
      diff_if_changed_ret_opt (string_literal loc1 loc2) l1 l2
    | (POP.NumberLiteral (loc1, l1), POP.NumberLiteral (loc2, l2)) ->
      diff_if_changed_ret_opt (number_literal loc1 loc2) l1 l2
    | (POP.BigIntLiteral (loc1, l1), POP.BigIntLiteral (loc2, l2)) ->
      diff_if_changed_ret_opt (bigint_literal loc1 loc2) l1 l2
    | (POP.Identifier i1, POP.Identifier i2) ->
      diff_if_changed identifier i1 i2 |> Base.Option.return
    | (POP.Computed (loc, c1), POP.Computed (_, c2)) ->
      diff_if_changed_ret_opt (computed_key loc) c1 c2
    | (_, _) -> None
  and pattern_array
      loc (a1 : (Loc.t, Loc.t) Ast.Pattern.Array.t) (a2 : (Loc.t, Loc.t) Ast.Pattern.Array.t) :
      node change list option =
    let open Ast.Pattern.Array in
    let { elements = elements1; annot = annot1; comments = comments1 } = a1 in
    let { elements = elements2; annot = annot2; comments = comments2 } = a2 in
    let elements_diff = diff_and_recurse_no_trivial pattern_array_e elements1 elements2 in
    let annot_diff = diff_if_changed type_annotation_hint annot1 annot2 |> Base.Option.return in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [comments_diff; elements_diff; annot_diff]
  and pattern_array_e
      (eo1 : (Loc.t, Loc.t) Ast.Pattern.Array.element)
      (eo2 : (Loc.t, Loc.t) Ast.Pattern.Array.element) : node change list option =
    let open Ast.Pattern.Array in
    match (eo1, eo2) with
    | (Element p1, Element p2) -> pattern_array_element p1 p2
    | (RestElement re1, RestElement re2) -> pattern_rest_element re1 re2
    | (Hole _, Hole _) -> Some [] (* Both elements elided *)
    | (_, _) -> None
  (* one element is elided and another is not *)
  and pattern_array_element
      ((_, e1) : (Loc.t, Loc.t) Ast.Pattern.Array.Element.t)
      ((_, e2) : (Loc.t, Loc.t) Ast.Pattern.Array.Element.t) : node change list option =
    let open Ast.Pattern.Array.Element in
    let { argument = argument1; default = default1 } = e1 in
    let { argument = argument2; default = default2 } = e2 in
    let args = Some (diff_if_changed pattern argument1 argument2) in
    let defaults =
      diff_if_changed_nonopt_fn (expression ~parent:SlotParentOfExpression) default1 default2
    in
    join_diff_list [args; defaults]
  and pattern_rest_element
      ((loc, r1) : (Loc.t, Loc.t) Ast.Pattern.RestElement.t)
      ((_, r2) : (Loc.t, Loc.t) Ast.Pattern.RestElement.t) : node change list option =
    let open Ast.Pattern.RestElement in
    let { argument = argument1; comments = comments1 } = r1 in
    let { argument = argument2; comments = comments2 } = r2 in
    let argument_diff = Some (pattern argument1 argument2) in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [argument_diff; comments_diff]
  and pattern_identifier
      (i1 : (Loc.t, Loc.t) Ast.Pattern.Identifier.t) (i2 : (Loc.t, Loc.t) Ast.Pattern.Identifier.t)
      : node change list option =
    let open Ast.Pattern.Identifier in
    let { name = name1; annot = annot1; optional = optional1 } = i1 in
    let { name = name2; annot = annot2; optional = optional2 } = i2 in
    if optional1 != optional2 then
      None
    else
      let ids = diff_if_changed identifier name1 name2 |> Base.Option.return in
      let annots = Some (diff_if_changed type_annotation_hint annot1 annot2) in
      join_diff_list [ids; annots]
  and function_rest_param
      (elem1 : (Loc.t, Loc.t) Ast.Function.RestParam.t)
      (elem2 : (Loc.t, Loc.t) Ast.Function.RestParam.t) : node change list option =
    let open Ast.Function.RestParam in
    let (loc, { argument = arg1; comments = comments1 }) = elem1 in
    let (_, { argument = arg2; comments = comments2 }) = elem2 in
    let arg_diff = Some (binding_pattern arg1 arg2) in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [arg_diff; comments_diff]
  and type_ ((loc1, type1) : (Loc.t, Loc.t) Ast.Type.t) ((loc2, type2) : (Loc.t, Loc.t) Ast.Type.t)
      : node change list =
    let open Ast.Type in
    let type_diff =
      match (type1, type2) with
      | (Any c1, Any c2)
      | (Mixed c1, Mixed c2)
      | (Empty c1, Empty c2)
      | (Void c1, Void c2)
      | (Null c1, Null c2)
      | (Symbol c1, Symbol c2)
      | (Number c1, Number c2)
      | (BigInt c1, BigInt c2)
      | (String c1, String c2)
      | (Exists c1, Exists c2) ->
        diff_if_changed_ret_opt (syntax_opt loc1) c1 c2
      | (Boolean { raw = r1; comments = c1 }, Boolean { raw = r2; comments = c2 }) ->
        if r1 == r2 then
          diff_if_changed_ret_opt (syntax_opt loc1) c1 c2
        else
          None
      | (Function fn1, Function fn2) -> diff_if_changed_ret_opt (function_type loc1) fn1 fn2
      | (Interface i1, Interface i2) -> diff_if_changed_ret_opt (interface_type loc1) i1 i2
      | (Generic g1, Generic g2) -> diff_if_changed_ret_opt (generic_type loc1) g1 g2
      | (Intersection t1, Intersection t2) -> diff_if_changed_ret_opt (intersection_type loc1) t1 t2
      | (Union t1, Union t2) -> diff_if_changed_ret_opt (union_type loc1) t1 t2
      | (Nullable t1, Nullable t2) -> diff_if_changed_ret_opt (nullable_type loc1) t1 t2
      | (Object obj1, Object obj2) -> diff_if_changed_ret_opt (object_type loc1) obj1 obj2
      | (Ast.Type.StringLiteral s1, Ast.Type.StringLiteral s2) ->
        diff_if_changed_ret_opt (string_literal loc1 loc2) s1 s2
      | (Ast.Type.NumberLiteral n1, Ast.Type.NumberLiteral n2) ->
        diff_if_changed_ret_opt (number_literal loc1 loc2) n1 n2
      | (Ast.Type.BigIntLiteral b1, Ast.Type.BigIntLiteral b2) ->
        diff_if_changed_ret_opt (bigint_literal loc1 loc2) b1 b2
      | (Ast.Type.BooleanLiteral b1, Ast.Type.BooleanLiteral b2) ->
        diff_if_changed_ret_opt (boolean_literal loc1 loc2) b1 b2
      | (Typeof t1, Typeof t2) -> diff_if_changed_ret_opt (typeof_type loc1) t1 t2
      | (Tuple t1, Tuple t2) -> diff_if_changed_ret_opt (tuple_type loc1) t1 t2
      | (Array t1, Array t2) -> diff_if_changed_ret_opt (array_type loc1) t1 t2
      | (Renders t1, Renders t2) -> diff_if_changed_ret_opt (render_type loc1) t1 t2
      | _ -> None
    in
    Base.Option.value type_diff ~default:[replace loc1 (Type (loc1, type1)) (Type (loc1, type2))]
  and interface_type
      (loc : Loc.t)
      (it1 : (Loc.t, Loc.t) Ast.Type.Interface.t)
      (it2 : (Loc.t, Loc.t) Ast.Type.Interface.t) : node change list option =
    let open Ast.Type.Interface in
    let { extends = extends1; body = (body_loc, body1); comments = comments1 } = it1 in
    let { extends = extends2; body = (_, body2); comments = comments2 } = it2 in
    let extends_diff = diff_and_recurse_no_trivial generic_type_with_loc extends1 extends2 in
    let body_diff = diff_if_changed_ret_opt (object_type body_loc) body1 body2 in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [extends_diff; body_diff; comments_diff]
  and generic_type
      (loc : Loc.t)
      (gt1 : (Loc.t, Loc.t) Ast.Type.Generic.t)
      (gt2 : (Loc.t, Loc.t) Ast.Type.Generic.t) : node change list option =
    let open Ast.Type.Generic in
    let { id = id1; targs = targs1; comments = comments1 } = gt1 in
    let { id = id2; targs = targs2; comments = comments2 } = gt2 in
    let id_diff = diff_if_changed_ret_opt generic_identifier_type id1 id2 in
    let targs_diff = diff_if_changed_opt type_args targs1 targs2 in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [id_diff; targs_diff; comments_diff]
  and generic_type_with_loc
      ((loc1, gt1) : Loc.t * (Loc.t, Loc.t) Ast.Type.Generic.t)
      ((_loc2, gt2) : Loc.t * (Loc.t, Loc.t) Ast.Type.Generic.t) : node change list option =
    generic_type loc1 gt1 gt2
  and generic_identifier_type
      (git1 : (Loc.t, Loc.t) Ast.Type.Generic.Identifier.t)
      (git2 : (Loc.t, Loc.t) Ast.Type.Generic.Identifier.t) : node change list option =
    let open Ast.Type.Generic.Identifier in
    match (git1, git2) with
    | (Unqualified id1, Unqualified id2) -> diff_if_changed identifier id1 id2 |> Base.Option.return
    | ( Qualified (_loc1, { qualification = q1; id = id1 }),
        Qualified (_loc2, { qualification = q2; id = id2 })
      ) ->
      let qualification_diff = diff_if_changed_ret_opt generic_identifier_type q1 q2 in
      let id_diff = diff_if_changed identifier id1 id2 |> Base.Option.return in
      join_diff_list [qualification_diff; id_diff]
    | _ -> None
  and object_type
      (loc : Loc.t) (ot1 : (Loc.t, Loc.t) Ast.Type.Object.t) (ot2 : (Loc.t, Loc.t) Ast.Type.Object.t)
      : node change list option =
    let open Ast.Type.Object in
    let { properties = props1; exact = exact1; inexact = inexact1; comments = comments1 } = ot1 in
    let { properties = props2; exact = exact2; inexact = inexact2; comments = comments2 } = ot2 in
    (* These are boolean literals, so structural equality is ok *)
    let exact_diff =
      if exact1 = exact2 then
        Some []
      else
        None
    in
    let inexact_diff =
      if inexact1 = inexact2 then
        Some []
      else
        None
    in
    let properties_diff = diff_and_recurse_no_trivial object_type_property props1 props2 in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [exact_diff; inexact_diff; properties_diff; comments_diff]
  and object_type_property
      (prop1 : (Loc.t, Loc.t) Ast.Type.Object.property)
      (prop2 : (Loc.t, Loc.t) Ast.Type.Object.property) : node change list option =
    let open Ast.Type.Object in
    match (prop1, prop2) with
    | (Property p1, Property p2) -> diff_if_changed_ret_opt object_property_type p1 p2
    | (SpreadProperty (loc, p1), SpreadProperty (_, p2)) ->
      diff_if_changed_ret_opt (object_spread_property_type loc) p1 p2
    | (Indexer (loc, p1), Indexer (_, p2)) ->
      diff_if_changed_ret_opt (object_indexer_type loc) p1 p2
    | (InternalSlot (loc, s1), InternalSlot (_, s2)) ->
      diff_if_changed_ret_opt (object_internal_slot_type loc) s1 s2
    | (CallProperty (loc, p1), CallProperty (_, p2)) ->
      diff_if_changed_ret_opt (object_call_property_type loc) p1 p2
    | _ -> None
  and object_property_type
      (optype1 : (Loc.t, Loc.t) Ast.Type.Object.Property.t)
      (optype2 : (Loc.t, Loc.t) Ast.Type.Object.Property.t) : node change list option =
    let open Ast.Type.Object.Property in
    let ( loc1,
          {
            key = key1;
            value = value1;
            optional = opt1;
            static = static1;
            proto = proto1;
            _method = method1;
            variance = var1;
            comments = comments1;
          }
        ) =
      optype1
    in
    let ( _loc2,
          {
            key = key2;
            value = value2;
            optional = opt2;
            static = static2;
            proto = proto2;
            _method = method2;
            variance = var2;
            comments = comments2;
          }
        ) =
      optype2
    in
    if opt1 != opt2 || static1 != static2 || proto1 != proto2 || method1 != method2 then
      None
    else
      let variance_diff = diff_if_changed_ret_opt variance var1 var2 in
      let key_diff = diff_if_changed_ret_opt object_key key1 key2 in
      let value_diff = diff_if_changed_ret_opt object_property_value_type value1 value2 in
      let comments_diff = syntax_opt loc1 comments1 comments2 in
      join_diff_list [variance_diff; key_diff; value_diff; comments_diff]
  and object_property_value_type
      (opvt1 : (Loc.t, Loc.t) Ast.Type.Object.Property.value)
      (opvt2 : (Loc.t, Loc.t) Ast.Type.Object.Property.value) : node change list option =
    let open Ast.Type.Object.Property in
    match (opvt1, opvt2) with
    | (Init t1, Init t2) -> diff_if_changed type_ t1 t2 |> Base.Option.return
    | (Get (loc1, ft1), Get (_, ft2))
    | (Set (loc1, ft1), Set (_, ft2)) ->
      diff_if_changed_ret_opt (function_type loc1) ft1 ft2
    | _ -> None
  and object_spread_property_type
      (loc : Loc.t)
      (spread1 : (Loc.t, Loc.t) Ast.Type.Object.SpreadProperty.t')
      (spread2 : (Loc.t, Loc.t) Ast.Type.Object.SpreadProperty.t') : node change list option =
    let open Ast.Type.Object.SpreadProperty in
    let { argument = argument1; comments = comments1 } = spread1 in
    let { argument = argument2; comments = comments2 } = spread2 in
    let argument_diff = Some (diff_if_changed type_ argument1 argument2) in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [argument_diff; comments_diff]
  and object_indexer_type
      (loc : Loc.t)
      (indexer1 : (Loc.t, Loc.t) Ast.Type.Object.Indexer.t')
      (indexer2 : (Loc.t, Loc.t) Ast.Type.Object.Indexer.t') : node change list option =
    let open Ast.Type.Object.Indexer in
    let {
      id = id1;
      key = key1;
      value = value1;
      static = static1;
      variance = variance1;
      comments = comments1;
    } =
      indexer1
    in
    let {
      id = id2;
      key = key2;
      value = value2;
      static = static2;
      variance = variance2;
      comments = comments2;
    } =
      indexer2
    in
    if static1 != static2 then
      None
    else
      let id_diff = diff_if_changed_nonopt_fn identifier id1 id2 in
      let key_diff = Some (diff_if_changed type_ key1 key2) in
      let value_diff = Some (diff_if_changed type_ value1 value2) in
      let variance_diff = diff_if_changed_ret_opt variance variance1 variance2 in
      let comments = syntax_opt loc comments1 comments2 in
      join_diff_list [id_diff; key_diff; value_diff; variance_diff; comments]
  and object_internal_slot_type
      (loc : Loc.t)
      (slot1 : (Loc.t, Loc.t) Ast.Type.Object.InternalSlot.t')
      (slot2 : (Loc.t, Loc.t) Ast.Type.Object.InternalSlot.t') : node change list option =
    let open Ast.Type.Object.InternalSlot in
    let {
      id = id1;
      value = value1;
      optional = optional1;
      static = static1;
      _method = method1;
      comments = comments1;
    } =
      slot1
    in
    let {
      id = id2;
      value = value2;
      optional = optional2;
      static = static2;
      _method = method2;
      comments = comments2;
    } =
      slot2
    in
    if optional1 != optional2 || static1 != static2 || method1 != method2 then
      None
    else
      let id_diff = Some (diff_if_changed identifier id1 id2) in
      let value_diff = Some (diff_if_changed type_ value1 value2) in
      let comments_diff = syntax_opt loc comments1 comments2 in
      join_diff_list [id_diff; value_diff; comments_diff]
  and object_call_property_type
      (loc : Loc.t)
      (call1 : (Loc.t, Loc.t) Ast.Type.Object.CallProperty.t')
      (call2 : (Loc.t, Loc.t) Ast.Type.Object.CallProperty.t') : node change list option =
    let open Ast.Type.Object.CallProperty in
    let { value = (value_loc, value1); static = static1; comments = comments1 } = call1 in
    let { value = (_, value2); static = static2; comments = comments2 } = call2 in
    if static1 != static2 then
      None
    else
      let value_diff = diff_if_changed_ret_opt (function_type value_loc) value1 value2 in
      let comments_diff = syntax_opt loc comments1 comments2 in
      join_diff_list [value_diff; comments_diff]
  and tuple_type
      (loc : Loc.t) (t1 : (Loc.t, Loc.t) Ast.Type.Tuple.t) (t2 : (Loc.t, Loc.t) Ast.Type.Tuple.t) :
      node change list option =
    let open Ast.Type.Tuple in
    let { elements = elements1; inexact = inexact1; comments = comments1 } = t1 in
    let { elements = elements2; inexact = inexact2; comments = comments2 } = t2 in
    let inexact_diff =
      if inexact1 = inexact2 then
        Some []
      else
        None
    in
    let elements_diff = diff_and_recurse_no_trivial tuple_element elements1 elements2 in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [elements_diff; inexact_diff; comments_diff]
  and tuple_element
      (e1 : (Loc.t, Loc.t) Ast.Type.Tuple.element) (e2 : (Loc.t, Loc.t) Ast.Type.Tuple.element) :
      node change list option =
    let open Ast.Type.Tuple in
    match (e1, e2) with
    | ((_, UnlabeledElement annot1), (_, UnlabeledElement annot2)) ->
      Some (diff_if_changed type_ annot1 annot2)
    | ((_, LabeledElement e1), (_, LabeledElement e2)) -> tuple_labeled_element e1 e2
    | ((_, SpreadElement e1), (_, SpreadElement e2)) -> tuple_spread_element e1 e2
    | _ -> None
  and tuple_labeled_element
      (t1 : (Loc.t, Loc.t) Ast.Type.Tuple.LabeledElement.t)
      (t2 : (Loc.t, Loc.t) Ast.Type.Tuple.LabeledElement.t) : node change list option =
    let open Ast.Type.Tuple.LabeledElement in
    let { name = name1; annot = annot1; variance = var1; optional = opt1 } = t1 in
    let { name = name2; annot = annot2; variance = var2; optional = opt2 } = t2 in
    let name_diff = Some (diff_if_changed identifier name1 name2) in
    let annot_diff = Some (diff_if_changed type_ annot1 annot2) in
    let variance_diff = diff_if_changed_ret_opt variance var1 var2 in
    let optional_diff =
      if opt1 = opt2 then
        Some []
      else
        None
    in
    join_diff_list [name_diff; annot_diff; variance_diff; optional_diff]
  and tuple_spread_element
      (e1 : (Loc.t, Loc.t) Ast.Type.Tuple.SpreadElement.t)
      (e2 : (Loc.t, Loc.t) Ast.Type.Tuple.SpreadElement.t) : node change list option =
    let open Ast.Type.Tuple.SpreadElement in
    let { name = name1; annot = annot1 } = e1 in
    let { name = name2; annot = annot2 } = e2 in
    let name_diff = diff_if_changed_nonopt_fn identifier name1 name2 in
    let annot_diff = Some (diff_if_changed type_ annot1 annot2) in
    join_diff_list [name_diff; annot_diff]
  and type_args (pi1 : (Loc.t, Loc.t) Ast.Type.TypeArgs.t) (pi2 : (Loc.t, Loc.t) Ast.Type.TypeArgs.t)
      : node change list option =
    let open Ast.Type.TypeArgs in
    let (loc, { arguments = arguments1; comments = comments1 }) = pi1 in
    let (_, { arguments = arguments2; comments = comments2 }) = pi2 in
    let args_diff = diff_and_recurse_nonopt_no_trivial type_ arguments1 arguments2 in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [args_diff; comments_diff]
  and function_param_type
      (fpt1 : (Loc.t, Loc.t) Ast.Type.Function.Param.t)
      (fpt2 : (Loc.t, Loc.t) Ast.Type.Function.Param.t) : node change list option =
    let open Ast.Type.Function.Param in
    let (_loc1, { annot = annot1; name = name1; optional = opt1 }) = fpt1 in
    let (_loc2, { annot = annot2; name = name2; optional = opt2 }) = fpt2 in
    (* These are boolean literals, so structural equality is ok *)
    let optional_diff =
      if opt1 = opt2 then
        Some []
      else
        None
    in
    let name_diff = diff_if_changed_nonopt_fn identifier name1 name2 in
    let annot_diff = diff_if_changed type_ annot1 annot2 |> Base.Option.return in
    join_diff_list [optional_diff; name_diff; annot_diff]
  and function_rest_param_type
      (frpt1 : (Loc.t, Loc.t) Ast.Type.Function.RestParam.t)
      (frpt2 : (Loc.t, Loc.t) Ast.Type.Function.RestParam.t) : node change list option =
    let open Ast.Type.Function.RestParam in
    let (loc, { argument = arg1; comments = comments1 }) = frpt1 in
    let (_, { argument = arg2; comments = comments2 }) = frpt2 in
    let arg_diff = diff_if_changed_ret_opt function_param_type arg1 arg2 in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [arg_diff; comments_diff]
  and function_this_constraint_type
      (ftct1 : (Loc.t, Loc.t) Ast.Type.Function.ThisParam.t)
      (ftct2 : (Loc.t, Loc.t) Ast.Type.Function.ThisParam.t) : node change list option =
    let open Ast.Type.Function.ThisParam in
    let (loc, { annot = annot1; comments = comments1 }) = ftct1 in
    let (_, { annot = annot2; comments = comments2 }) = ftct2 in
    let annot_diff = Some (diff_if_changed type_annotation annot1 annot2) in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [annot_diff; comments_diff]
  and function_type_return_annotation
      (ret_annot_1 : (Loc.t, Loc.t) Ast.Type.Function.return_annotation)
      (ret_annot_2 : (Loc.t, Loc.t) Ast.Type.Function.return_annotation) =
    let module F = Ast.Type.Function in
    match (ret_annot_1, ret_annot_2) with
    | (F.TypeAnnotation t1, F.TypeAnnotation t2) -> type_ t1 t2
    | (F.TypeGuard grd1, F.TypeGuard grd2) -> type_guard grd1 grd2
    | (F.TypeGuard (loc1, grd1), F.TypeAnnotation (loc2, t2)) ->
      [replace loc1 (TypeGuard (loc1, grd1)) (Type (loc2, t2))]
    | (F.TypeAnnotation (loc1, t1), F.TypeGuard (loc2, grd2)) ->
      [replace loc1 (Type (loc1, t1)) (TypeGuard (loc2, grd2))]
  and function_type
      (loc : Loc.t)
      (ft1 : (Loc.t, Loc.t) Ast.Type.Function.t)
      (ft2 : (Loc.t, Loc.t) Ast.Type.Function.t) : node change list option =
    let open Ast.Type.Function in
    let {
      params =
        ( params_loc,
          { Params.this_ = this1; params = params1; rest = rest1; comments = params_comments1 }
        );
      return = return1;
      tparams = tparams1;
      comments = func_comments1;
      effect_ = effect1;
    } =
      ft1
    in
    let {
      params =
        (_, { Params.this_ = this2; params = params2; rest = rest2; comments = params_comments2 });
      return = return2;
      tparams = tparams2;
      comments = func_comments2;
      effect_ = effect2;
    } =
      ft2
    in
    if effect1 != effect2 then
      None
    else
      let tparams_diff = diff_if_changed_opt type_params tparams1 tparams2 in
      let this_diff = diff_if_changed_opt function_this_constraint_type this1 this2 in
      let params_diff = diff_and_recurse_no_trivial function_param_type params1 params2 in
      let rest_diff = diff_if_changed_opt function_rest_param_type rest1 rest2 in
      let return_diff =
        diff_if_changed function_type_return_annotation return1 return2 |> Base.Option.return
      in
      let func_comments_diff = syntax_opt loc func_comments1 func_comments2 in
      let params_comments_diff = syntax_opt params_loc params_comments1 params_comments2 in
      join_diff_list
        [
          tparams_diff;
          this_diff;
          params_diff;
          rest_diff;
          return_diff;
          func_comments_diff;
          params_comments_diff;
        ]
  and nullable_type
      (loc : Loc.t)
      (t1 : (Loc.t, Loc.t) Ast.Type.Nullable.t)
      (t2 : (Loc.t, Loc.t) Ast.Type.Nullable.t) : node change list option =
    let open Ast.Type.Nullable in
    let { argument = argument1; comments = comments1 } = t1 in
    let { argument = argument2; comments = comments2 } = t2 in
    let argument_diff = Some (diff_if_changed type_ argument1 argument2) in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [argument_diff; comments_diff]
  and render_type
      (loc : Loc.t) (t1 : (Loc.t, Loc.t) Ast.Type.Renders.t) (t2 : (Loc.t, Loc.t) Ast.Type.Renders.t)
      : node change list option =
    let open Ast.Type.Renders in
    let { operator_loc; argument = argument1; variant = variant1; comments = comments1 } = t1 in
    let { operator_loc = _; argument = argument2; variant = variant2; comments = comments2 } = t2 in
    let variant_diff =
      if variant1 = variant2 then
        Some []
      else
        let str_of_variant = function
          | Normal -> "renders"
          | Maybe -> "renders?"
          | Star -> "renders*"
        in
        Some [replace operator_loc (Raw (str_of_variant variant1)) (Raw (str_of_variant variant2))]
    in
    let argument_diff = Some (diff_if_changed type_ argument1 argument2) in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [variant_diff; argument_diff; comments_diff]
  and typeof_type
      (loc : Loc.t) (t1 : (Loc.t, Loc.t) Ast.Type.Typeof.t) (t2 : (Loc.t, Loc.t) Ast.Type.Typeof.t)
      : node change list option =
    let open Ast.Type.Typeof in
    let { argument = argument1; targs = targs1; comments = comments1 } = t1 in
    let { argument = argument2; targs = targs2; comments = comments2 } = t2 in
    let argument_diff = diff_if_changed_ret_opt typeof_expr argument1 argument2 in
    let targs_diff = diff_if_changed_opt type_args targs1 targs2 in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [argument_diff; targs_diff; comments_diff]
  and typeof_expr
      (git1 : (Loc.t, Loc.t) Ast.Type.Typeof.Target.t)
      (git2 : (Loc.t, Loc.t) Ast.Type.Typeof.Target.t) : node change list option =
    let open Ast.Type.Typeof.Target in
    match (git1, git2) with
    | (Unqualified id1, Unqualified id2) -> diff_if_changed identifier id1 id2 |> Base.Option.return
    | ( Qualified (_loc1, { qualification = q1; id = id1 }),
        Qualified (_loc2, { qualification = q2; id = id2 })
      ) ->
      let qualification_diff = diff_if_changed_ret_opt typeof_expr q1 q2 in
      let id_diff = diff_if_changed identifier id1 id2 |> Base.Option.return in
      join_diff_list [qualification_diff; id_diff]
    | _ -> None
  and array_type
      (loc : Loc.t) (t1 : (Loc.t, Loc.t) Ast.Type.Array.t) (t2 : (Loc.t, Loc.t) Ast.Type.Array.t) :
      node change list option =
    let open Ast.Type.Array in
    let { argument = argument1; comments = comments1 } = t1 in
    let { argument = argument2; comments = comments2 } = t2 in
    let argument_diff = Some (diff_if_changed type_ argument1 argument2) in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [argument_diff; comments_diff]
  and union_type
      (loc : Loc.t) (t1 : (Loc.t, Loc.t) Ast.Type.Union.t) (t2 : (Loc.t, Loc.t) Ast.Type.Union.t) :
      node change list option =
    let open Ast.Type.Union in
    let { types = types1; comments = comments1 } = t1 in
    let { types = types2; comments = comments2 } = t2 in
    let types1 =
      let (t0, t1, ts) = types1 in
      t0 :: t1 :: ts
    in
    let types2 =
      let (t0, t1, ts) = types2 in
      t0 :: t1 :: ts
    in
    let types_diff = diff_and_recurse_nonopt_no_trivial type_ types1 types2 in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [types_diff; comments_diff]
  and intersection_type
      (loc : Loc.t)
      (t1 : (Loc.t, Loc.t) Ast.Type.Intersection.t)
      (t2 : (Loc.t, Loc.t) Ast.Type.Intersection.t) : node change list option =
    let open Ast.Type.Intersection in
    let { types = types1; comments = comments1 } = t1 in
    let { types = types2; comments = comments2 } = t2 in
    let types1 =
      let (t0, t1, ts) = types1 in
      t0 :: t1 :: ts
    in
    let types2 =
      let (t0, t1, ts) = types2 in
      t0 :: t1 :: ts
    in
    let types_diff = diff_and_recurse_nonopt_no_trivial type_ types1 types2 in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [types_diff; comments_diff]
  and type_alias
      (loc : Loc.t)
      (t_alias1 : (Loc.t, Loc.t) Ast.Statement.TypeAlias.t)
      (t_alias2 : (Loc.t, Loc.t) Ast.Statement.TypeAlias.t) : node change list option =
    let open Ast.Statement.TypeAlias in
    let { id = id1; tparams = t_params1; right = right1; comments = comments1 } = t_alias1 in
    let { id = id2; tparams = t_params2; right = right2; comments = comments2 } = t_alias2 in
    let id_diff = diff_if_changed identifier id1 id2 |> Base.Option.return in
    let t_params_diff = diff_if_changed_opt type_params t_params1 t_params2 in
    let right_diff = diff_if_changed type_ right1 right2 |> Base.Option.return in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [id_diff; t_params_diff; right_diff; comments_diff]
  and opaque_type
      (loc : Loc.t)
      (o_type1 : (Loc.t, Loc.t) Ast.Statement.OpaqueType.t)
      (o_type2 : (Loc.t, Loc.t) Ast.Statement.OpaqueType.t) : node change list option =
    let open Ast.Statement.OpaqueType in
    let {
      id = id1;
      tparams = t_params1;
      impl_type = impl_type1;
      lower_bound = lower_bound1;
      upper_bound = upper_bound1;
      legacy_upper_bound = legacy_upper_bound1;
      comments = comments1;
    } =
      o_type1
    in
    let {
      id = id2;
      tparams = t_params2;
      impl_type = impl_type2;
      lower_bound = lower_bound2;
      upper_bound = upper_bound2;
      legacy_upper_bound = legacy_upper_bound2;
      comments = comments2;
    } =
      o_type2
    in
    let id_diff = diff_if_changed identifier id1 id2 |> Base.Option.return in
    let t_params_diff = diff_if_changed_opt type_params t_params1 t_params2 in
    let lower_bound_diff = diff_if_changed_nonopt_fn type_ lower_bound1 lower_bound2 in
    let upper_bound_diff = diff_if_changed_nonopt_fn type_ upper_bound1 upper_bound2 in
    let legacy_upper_bound_diff =
      diff_if_changed_nonopt_fn type_ legacy_upper_bound1 legacy_upper_bound2
    in
    let impl_type_diff = diff_if_changed_nonopt_fn type_ impl_type1 impl_type2 in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list
      [
        id_diff;
        t_params_diff;
        lower_bound_diff;
        upper_bound_diff;
        legacy_upper_bound_diff;
        impl_type_diff;
        comments_diff;
      ]
  and declare_class loc dclass1 dclass2 =
    let open Ast.Statement.DeclareClass in
    let {
      id = id1;
      tparams = tparams1;
      body = (body_loc, body1);
      extends = extends1;
      mixins = mixins1;
      implements = implements1;
      comments = comments1;
    } =
      dclass1
    in
    let {
      id = id2;
      tparams = tparams2;
      body = (_, body2);
      extends = extends2;
      mixins = mixins2;
      implements = implements2;
      comments = comments2;
    } =
      dclass2
    in
    let id_diff = diff_if_changed identifier id1 id2 |> Base.Option.return in
    let t_params_diff = diff_if_changed_opt type_params tparams1 tparams2 in
    let body_diff = diff_if_changed_ret_opt (object_type body_loc) body1 body2 in
    let extends_diff = diff_if_changed_opt generic_type_with_loc extends1 extends2 in
    let implements_diff = diff_if_changed_opt class_implements implements1 implements2 in
    let comments_diff = syntax_opt loc comments1 comments2 in
    if mixins1 != mixins2 then
      None
    else
      join_diff_list
        [id_diff; t_params_diff; body_diff; extends_diff; implements_diff; comments_diff]
  and declare_function
      (loc : Loc.t)
      (func1 : (Loc.t, Loc.t) Ast.Statement.DeclareFunction.t)
      (func2 : (Loc.t, Loc.t) Ast.Statement.DeclareFunction.t) : node change list option =
    let open Ast.Statement.DeclareFunction in
    let { id = id1; annot = annot1; predicate = predicate1; comments = comments1 } = func1 in
    let { id = id2; annot = annot2; predicate = predicate2; comments = comments2 } = func2 in
    let id_diff = Some (diff_if_changed identifier id1 id2) in
    let annot_diff = Some (diff_if_changed type_annotation annot1 annot2) in
    let comments_diff = syntax_opt loc comments1 comments2 in
    if predicate1 != predicate2 then
      None
    else
      join_diff_list [id_diff; annot_diff; comments_diff]
  and declare_variable
      (loc : Loc.t)
      (decl1 : (Loc.t, Loc.t) Ast.Statement.DeclareVariable.t)
      (decl2 : (Loc.t, Loc.t) Ast.Statement.DeclareVariable.t) : node change list option =
    let open Ast.Statement.DeclareVariable in
    let { id = id1; annot = annot1; kind = kind1; comments = comments1 } = decl1 in
    let { id = id2; annot = annot2; kind = kind2; comments = comments2 } = decl2 in
    if kind1 != kind2 then
      None
    else
      let id_diff = Some (diff_if_changed identifier id1 id2) in
      let annot_diff = Some (diff_if_changed type_annotation annot1 annot2) in
      let comments_diff = syntax_opt loc comments1 comments2 in
      join_diff_list [id_diff; annot_diff; comments_diff]
  and enum_declaration
      (loc : Loc.t)
      (enum1 : (Loc.t, Loc.t) Ast.Statement.EnumDeclaration.t)
      (enum2 : (Loc.t, Loc.t) Ast.Statement.EnumDeclaration.t) : node change list option =
    let open Ast.Statement.EnumDeclaration in
    let { id = id1; body = body1; comments = comments1 } = enum1 in
    let { id = id2; body = body2; comments = comments2 } = enum2 in
    let id_diff = Some (diff_if_changed identifier id1 id2) in
    let body_diff = enum_body body1 body2 in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [id_diff; body_diff; comments_diff]
  and enum_body
      (body1 : Loc.t Ast.Statement.EnumDeclaration.body)
      (body2 : Loc.t Ast.Statement.EnumDeclaration.body) : node change list option =
    let open Ast.Statement.EnumDeclaration in
    match (body1, body2) with
    | ((loc, BooleanBody b1), (_, BooleanBody b2)) ->
      let {
        members = members1;
        explicit_type = explicit_type1;
        has_unknown_members = has_unknown_members1;
        BooleanBody.comments = comments1;
      } =
        b1
      in
      let {
        members = members2;
        explicit_type = explicit_type2;
        has_unknown_members = has_unknown_members2;
        BooleanBody.comments = comments2;
      } =
        b2
      in
      let members_diff = diff_and_recurse_no_trivial enum_boolean_member members1 members2 in
      let comments_diff = syntax_opt loc comments1 comments2 in
      if has_unknown_members1 != has_unknown_members2 || explicit_type1 != explicit_type2 then
        None
      else
        join_diff_list [members_diff; comments_diff]
    | ((loc, NumberBody b1), (_, NumberBody b2)) ->
      let {
        members = members1;
        explicit_type = explicit_type1;
        has_unknown_members = has_unknown_members1;
        NumberBody.comments = comments1;
      } =
        b1
      in
      let {
        members = members2;
        explicit_type = explicit_type2;
        has_unknown_members = has_unknown_members2;
        NumberBody.comments = comments2;
      } =
        b2
      in
      let members_diff = diff_and_recurse_no_trivial enum_number_member members1 members2 in
      let comments_diff = syntax_opt loc comments1 comments2 in
      if has_unknown_members1 != has_unknown_members2 || explicit_type1 != explicit_type2 then
        None
      else
        join_diff_list [members_diff; comments_diff]
    | ((loc, StringBody b1), (_, StringBody b2)) ->
      let {
        members = members1;
        explicit_type = explicit_type1;
        has_unknown_members = has_unknown_members1;
        StringBody.comments = comments1;
      } =
        b1
      in
      let {
        members = members2;
        explicit_type = explicit_type2;
        has_unknown_members = has_unknown_members2;
        StringBody.comments = comments2;
      } =
        b2
      in
      let members_diff =
        match (members1, members2) with
        | (StringBody.Defaulted m1, StringBody.Defaulted m2) ->
          diff_and_recurse_no_trivial enum_defaulted_member m1 m2
        | (StringBody.Initialized m1, StringBody.Initialized m2) ->
          diff_and_recurse_no_trivial enum_string_member m1 m2
        | _ -> None
      in
      let comments_diff = syntax_opt loc comments1 comments2 in
      if has_unknown_members1 != has_unknown_members2 || explicit_type1 != explicit_type2 then
        None
      else
        join_diff_list [members_diff; comments_diff]
    | ((loc, SymbolBody b1), (_, SymbolBody b2)) ->
      let {
        members = members1;
        has_unknown_members = has_unknown_members1;
        SymbolBody.comments = comments1;
      } =
        b1
      in
      let {
        members = members2;
        has_unknown_members = has_unknown_members2;
        SymbolBody.comments = comments2;
      } =
        b2
      in
      let members_diff = diff_and_recurse_no_trivial enum_defaulted_member members1 members2 in
      let comments_diff = syntax_opt loc comments1 comments2 in
      if has_unknown_members1 != has_unknown_members2 then
        None
      else
        join_diff_list [members_diff; comments_diff]
    | (_, _) -> None
  and enum_defaulted_member
      (member1 : Loc.t Ast.Statement.EnumDeclaration.DefaultedMember.t)
      (member2 : Loc.t Ast.Statement.EnumDeclaration.DefaultedMember.t) : node change list option =
    let open Ast.Statement.EnumDeclaration.DefaultedMember in
    let (_, { id = id1 }) = member1 in
    let (_, { id = id2 }) = member2 in
    Some (diff_if_changed identifier id1 id2)
  and enum_boolean_member
      (member1 :
        (Loc.t Ast.BooleanLiteral.t, Loc.t) Ast.Statement.EnumDeclaration.InitializedMember.t
        )
      (member2 :
        (Loc.t Ast.BooleanLiteral.t, Loc.t) Ast.Statement.EnumDeclaration.InitializedMember.t
        ) =
    let open Ast.Statement.EnumDeclaration.InitializedMember in
    let (_, { id = id1; init = (loc1, lit1) }) = member1 in
    let (_, { id = id2; init = (loc2, lit2) }) = member2 in
    let id_diff = Some (diff_if_changed identifier id1 id2) in
    let value_diff = diff_if_changed_ret_opt (boolean_literal loc1 loc2) lit1 lit2 in
    join_diff_list [id_diff; value_diff]
  and enum_number_member
      (member1 :
        (Loc.t Ast.NumberLiteral.t, Loc.t) Ast.Statement.EnumDeclaration.InitializedMember.t
        )
      (member2 :
        (Loc.t Ast.NumberLiteral.t, Loc.t) Ast.Statement.EnumDeclaration.InitializedMember.t
        ) =
    let open Ast.Statement.EnumDeclaration.InitializedMember in
    let (_, { id = id1; init = (loc1, lit1) }) = member1 in
    let (_, { id = id2; init = (loc2, lit2) }) = member2 in
    let id_diff = Some (diff_if_changed identifier id1 id2) in
    let value_diff = diff_if_changed_ret_opt (number_literal loc1 loc2) lit1 lit2 in
    join_diff_list [id_diff; value_diff]
  and enum_string_member
      (member1 :
        (Loc.t Ast.StringLiteral.t, Loc.t) Ast.Statement.EnumDeclaration.InitializedMember.t
        )
      (member2 :
        (Loc.t Ast.StringLiteral.t, Loc.t) Ast.Statement.EnumDeclaration.InitializedMember.t
        ) =
    let open Ast.Statement.EnumDeclaration.InitializedMember in
    let (_, { id = id1; init = (loc1, lit1) }) = member1 in
    let (_, { id = id2; init = (loc2, lit2) }) = member2 in
    let id_diff = Some (diff_if_changed identifier id1 id2) in
    let value_diff = diff_if_changed_ret_opt (string_literal loc1 loc2) lit1 lit2 in
    join_diff_list [id_diff; value_diff]
  and type_params
      (pd1 : (Loc.t, Loc.t) Ast.Type.TypeParams.t) (pd2 : (Loc.t, Loc.t) Ast.Type.TypeParams.t) :
      node change list option =
    let open Ast.Type.TypeParams in
    let (loc, { params = params1; comments = comments1 }) = pd1 in
    let (_, { params = params2; comments = comments2 }) = pd2 in
    let params_diff = diff_and_recurse_nonopt_no_trivial type_param params1 params2 in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [params_diff; comments_diff]
  and type_param
      ((loc1, t_param1) : (Loc.t, Loc.t) Ast.Type.TypeParam.t)
      ((_, t_param2) : (Loc.t, Loc.t) Ast.Type.TypeParam.t) : node change list =
    let open Ast.Type.TypeParam in
    let {
      name = name1;
      bound = bound1;
      bound_kind = bound_kind1;
      variance = variance1;
      default = default1;
      const = const1;
    } =
      t_param1
    in
    let {
      name = name2;
      bound = bound2;
      bound_kind = bound_kind2;
      variance = variance2;
      default = default2;
      const = const2;
    } =
      t_param2
    in
    let variance_diff = diff_if_changed_ret_opt variance variance1 variance2 in
    let name_diff = diff_if_changed identifier name1 name2 |> Base.Option.return in
    let bound_diff = diff_if_changed type_annotation_hint bound1 bound2 |> Base.Option.return in
    let bound_kind_diff =
      if bound_kind1 = bound_kind2 then
        Some []
      else
        None
    in
    let default_diff = diff_if_changed_nonopt_fn type_ default1 default2 in
    let const_diff =
      if const1 = const2 then
        Some []
      else
        None
    in
    let result =
      join_diff_list
        [variance_diff; name_diff; bound_diff; bound_kind_diff; default_diff; const_diff]
    in
    Base.Option.value
      result
      ~default:[replace loc1 (TypeParam (loc1, t_param1)) (TypeParam (loc1, t_param2))]
  and variance (var1 : Loc.t Ast.Variance.t option) (var2 : Loc.t Ast.Variance.t option) :
      node change list option =
    let open Ast.Variance in
    match (var1, var2) with
    | (Some (_, { kind = Readonly | In | Out | InOut; _ }), Some _) -> None
    | (Some (loc1, var1), Some (_, var2)) ->
      Some [replace loc1 (Variance (loc1, var1)) (Variance (loc1, var2))]
    | (Some (loc1, var1), None) -> Some [delete loc1 (Variance (loc1, var1))]
    | (None, None) -> Some []
    | _ -> None
  and type_annotation_hint
      (return1 : (Loc.t, Loc.t) Ast.Type.annotation_or_hint)
      (return2 : (Loc.t, Loc.t) Ast.Type.annotation_or_hint) : node change list =
    let open Ast.Type in
    let annot_change typ =
      match return2 with
      | Available (_, (_, Function _)) -> FunctionTypeAnnotation typ
      | _ -> TypeAnnotation typ
    in
    match (return1, return2) with
    | (Missing _, Missing _) -> []
    | (Available (loc1, typ), Missing _) -> [delete loc1 (TypeAnnotation (loc1, typ))]
    | (Missing loc1, Available annot) -> [(loc1, insert ~sep:None [annot_change annot])]
    | (Available annot1, Available annot2) -> type_annotation annot1 annot2
  and type_annotation
      ((loc1, typ1) : (Loc.t, Loc.t) Ast.Type.annotation)
      ((loc2, typ2) : (Loc.t, Loc.t) Ast.Type.annotation) : node change list =
    let open Ast.Type in
    match (typ1, typ2) with
    | (_, (_, Function _)) ->
      [replace loc1 (TypeAnnotation (loc1, typ1)) (FunctionTypeAnnotation (loc2, typ2))]
    | (_, _) -> type_ typ1 typ2
  and type_guard_annotation
      ((_, grd1) : (Loc.t, Loc.t) Ast.Type.type_guard_annotation)
      ((_, grd2) : (Loc.t, Loc.t) Ast.Type.type_guard_annotation) : node change list =
    type_guard grd1 grd2
  and type_guard
      ((loc1, grd1) : (Loc.t, Loc.t) Ast.Type.TypeGuard.t)
      ((loc2, grd2) : (Loc.t, Loc.t) Ast.Type.TypeGuard.t) : node change list =
    let open Ast.Type.TypeGuard in
    let { kind = kind1; guard = (x1, t1); comments = comments1 } = grd1 in
    let { kind = kind2; guard = (x2, t2); comments = comments2 } = grd2 in
    if kind1 != kind2 || t1 != t2 then
      [replace loc1 (TypeGuard (loc1, grd1)) (TypeGuard (loc2, grd2))]
    else
      let id = diff_if_changed identifier x1 x2 in
      let comments = syntax_opt loc1 comments1 comments2 |> Base.Option.value ~default:[] in
      Base.List.concat [id; comments]
  and type_cast
      (loc : Loc.t)
      (type_cast1 : (Loc.t, Loc.t) Flow_ast.Expression.TypeCast.t)
      (type_cast2 : (Loc.t, Loc.t) Flow_ast.Expression.TypeCast.t) : node change list =
    let open Flow_ast.Expression.TypeCast in
    let { expression = expr1; annot = annot1; comments = comments1 } = type_cast1 in
    let { expression = expr2; annot = annot2; comments = comments2 } = type_cast2 in
    let expr =
      diff_if_changed
        (expression ~parent:(ExpressionParentOfExpression (loc, Ast.Expression.TypeCast type_cast2)))
        expr1
        expr2
    in
    let annot = diff_if_changed type_annotation annot1 annot2 in
    let comments = syntax_opt loc comments1 comments2 |> Base.Option.value ~default:[] in
    Base.List.concat [expr; annot; comments]
  and type_cast_added
      (parent : expression_node_parent)
      (expr : (Loc.t, Loc.t) Flow_ast.Expression.t)
      (loc : Loc.t)
      (type_cast : (Loc.t, Loc.t) Flow_ast.Expression.TypeCast.t) : node change list =
    let open Flow_ast.Expression.TypeCast in
    Loc.(
      let { expression = expr2; annot = annot2; comments = _ } = type_cast in
      let expr_diff_rev = diff_if_changed (expression ~parent) expr expr2 |> List.rev in
      let append_annot_rev =
        ({ loc with start = loc._end }, insert ~sep:(Some "") [TypeAnnotation annot2; Raw ")"])
        :: expr_diff_rev
      in
      ({ loc with _end = loc.start }, insert ~sep:(Some "") [Raw "("]) :: List.rev append_annot_rev
    )
  and update
      loc
      (update1 : (Loc.t, Loc.t) Ast.Expression.Update.t)
      (update2 : (Loc.t, Loc.t) Ast.Expression.Update.t) : node change list option =
    let open Ast.Expression.Update in
    let { operator = op1; argument = arg1; prefix = p1; comments = comments1 } = update1 in
    let { operator = op2; argument = arg2; prefix = p2; comments = comments2 } = update2 in
    if op1 != op2 || p1 != p2 then
      None
    else
      let argument =
        expression
          ~parent:(ExpressionParentOfExpression (loc, Ast.Expression.Update update2))
          arg1
          arg2
      in
      let comments = syntax_opt loc comments1 comments2 |> Base.Option.value ~default:[] in
      Some (argument @ comments)
  and this_expression
      (loc : Loc.t) (this1 : Loc.t Ast.Expression.This.t) (this2 : Loc.t Ast.Expression.This.t) :
      node change list option =
    let open Ast.Expression.This in
    let { comments = comments1 } = this1 in
    let { comments = comments2 } = this2 in
    syntax_opt loc comments1 comments2
  and super_expression
      (loc : Loc.t) (super1 : Loc.t Ast.Expression.Super.t) (super2 : Loc.t Ast.Expression.Super.t)
      : node change list option =
    let open Ast.Expression.Super in
    let { comments = comments1 } = super1 in
    let { comments = comments2 } = super2 in
    syntax_opt loc comments1 comments2
  and meta_property
      (loc : Loc.t)
      (meta1 : Loc.t Ast.Expression.MetaProperty.t)
      (meta2 : Loc.t Ast.Expression.MetaProperty.t) : node change list option =
    let open Ast.Expression.MetaProperty in
    let { meta = meta1; property = property1; comments = comments1 } = meta1 in
    let { meta = meta2; property = property2; comments = comments2 } = meta2 in
    let meta = Some (diff_if_changed identifier meta1 meta2) in
    let property = Some (diff_if_changed identifier property1 property2) in
    let comments = syntax_opt loc comments1 comments2 in
    join_diff_list [meta; property; comments]
  and import_expression
      (loc : Loc.t)
      (import1 : (Loc.t, Loc.t) Ast.Expression.Import.t)
      (import2 : (Loc.t, Loc.t) Ast.Expression.Import.t) : node change list option =
    let open Ast.Expression.Import in
    let { argument = argument1; comments = comments1 } = import1 in
    let { argument = argument2; comments = comments2 } = import2 in
    let argument =
      Some
        (diff_if_changed
           (expression ~parent:(ExpressionParentOfExpression (loc, Ast.Expression.Import import2)))
           argument1
           argument2
        )
    in
    let comments = syntax_opt loc comments1 comments2 in
    join_diff_list [argument; comments]
  and match_expression
      (loc : Loc.t)
      (m1 : (Loc.t, Loc.t) Ast.Expression.match_expression)
      (m2 : (Loc.t, Loc.t) Ast.Expression.match_expression) : node change list option =
    let open Ast.Match in
    let { arg = arg1; cases = cases1; comments = comments1; match_keyword_loc = _ } = m1 in
    let { arg = arg2; cases = cases2; comments = comments2; match_keyword_loc = _ } = m2 in
    let arg = Some (diff_if_changed (expression ~parent:SlotParentOfExpression) arg1 arg2) in
    let cases = diff_and_recurse_no_trivial match_expression_case cases1 cases2 in
    let comments = syntax_opt loc comments1 comments2 in
    join_diff_list [arg; cases; comments]
  and match_expression_case (loc, c1) (_, c2) : node change list option =
    let open Ast.Match.Case in
    let {
      pattern = pattern1;
      body = body1;
      guard = guard1;
      comments = comments1;
      invalid_syntax = invalid_syntax1;
    } =
      c1
    in
    let {
      pattern = pattern2;
      body = body2;
      guard = guard2;
      comments = comments2;
      invalid_syntax = invalid_syntax2;
    } =
      c2
    in
    let pattern = Some (diff_if_changed match_pattern pattern1 pattern2) in
    let body =
      Some
        (diff_if_changed (expression ~parent:MatchExpressionCaseBodyParentOfExpression) body1 body2)
    in
    let guard =
      diff_if_changed_nonopt_fn (expression ~parent:SlotParentOfExpression) guard1 guard2
    in
    let comments = syntax_opt loc comments1 comments2 in
    let invalid_syntax =
      diff_if_changed_ret_opt match_case_invalid_syntax invalid_syntax1 invalid_syntax2
    in
    join_diff_list [pattern; body; guard; comments; invalid_syntax]
  and match_statement
      (loc : Loc.t)
      (m1 : (Loc.t, Loc.t) Ast.Statement.match_statement)
      (m2 : (Loc.t, Loc.t) Ast.Statement.match_statement) : node change list option =
    let open Ast.Match in
    let { arg = arg1; cases = cases1; comments = comments1; match_keyword_loc = _ } = m1 in
    let { arg = arg2; cases = cases2; comments = comments2; match_keyword_loc = _ } = m2 in
    let arg = Some (diff_if_changed (expression ~parent:SlotParentOfExpression) arg1 arg2) in
    let cases = diff_and_recurse_no_trivial match_statement_case cases1 cases2 in
    let comments = syntax_opt loc comments1 comments2 in
    join_diff_list [arg; cases; comments]
  and match_statement_case (loc, c1) (_, c2) : node change list option =
    let open Ast.Match.Case in
    let {
      pattern = pattern1;
      body = body1;
      guard = guard1;
      comments = comments1;
      invalid_syntax = invalid_syntax1;
    } =
      c1
    in
    let {
      pattern = pattern2;
      body = body2;
      guard = guard2;
      comments = comments2;
      invalid_syntax = invalid_syntax2;
    } =
      c2
    in
    let pattern = Some (diff_if_changed match_pattern pattern1 pattern2) in
    let body =
      Some (diff_if_changed (statement ~parent:(MatchCaseParentOfStatement loc)) body1 body2)
    in
    let guard =
      diff_if_changed_nonopt_fn (expression ~parent:SlotParentOfExpression) guard1 guard2
    in
    let comments = syntax_opt loc comments1 comments2 in
    let invalid_syntax =
      diff_if_changed_ret_opt match_case_invalid_syntax invalid_syntax1 invalid_syntax2
    in
    join_diff_list [pattern; body; guard; comments; invalid_syntax]
  and match_case_invalid_syntax
      (x1 : Loc.t Ast.Match.Case.InvalidSyntax.t) (x2 : Loc.t Ast.Match.Case.InvalidSyntax.t) :
      node change list option =
    let open Ast.Match.Case.InvalidSyntax in
    match (x1, x2) with
    | ( { invalid_prefix_case = None; invalid_infix_colon = None; invalid_suffix_semicolon = None },
        { invalid_prefix_case = None; invalid_infix_colon = None; invalid_suffix_semicolon = None }
      ) ->
      Some []
    | _ -> None
  and match_pattern (p1 : (Loc.t, Loc.t) Ast.MatchPattern.t) (p2 : (Loc.t, Loc.t) Ast.MatchPattern.t)
      : node change list =
    let open Ast.MatchPattern in
    let result =
      match (p1, p2) with
      | ( ( loc,
            WildcardPattern
              { WildcardPattern.invalid_syntax_default_keyword = invalid1; comments = comments1 }
          ),
          ( _,
            WildcardPattern
              { WildcardPattern.invalid_syntax_default_keyword = invalid2; comments = comments2 }
          )
        ) ->
        if invalid1 <> invalid2 then
          None
        else
          diff_if_changed_ret_opt (syntax_opt loc) comments1 comments2
      | ((loc1, NumberPattern p1), (loc2, NumberPattern p2)) ->
        diff_if_changed_ret_opt (number_literal loc1 loc2) p1 p2
      | ((loc1, BigIntPattern p1), (loc2, BigIntPattern p2)) ->
        diff_if_changed_ret_opt (bigint_literal loc1 loc2) p1 p2
      | ((loc1, StringPattern p1), (loc2, StringPattern p2)) ->
        diff_if_changed_ret_opt (string_literal loc1 loc2) p1 p2
      | ((loc1, BooleanPattern p1), (loc2, BooleanPattern p2)) ->
        diff_if_changed_ret_opt (boolean_literal loc1 loc2) p1 p2
      | ((loc, NullPattern p1), (_, NullPattern p2)) ->
        diff_if_changed_ret_opt (syntax_opt loc) p1 p2
      | ((loc, UnaryPattern p1), (_, UnaryPattern p2)) ->
        let { UnaryPattern.operator = op1; argument = arg1; comments = comments1 } = p1 in
        let { UnaryPattern.operator = op2; argument = arg2; comments = comments2 } = p2 in
        if op1 != op2 then
          None
        else
          let argument =
            match (arg1, arg2) with
            | ((loc1, UnaryPattern.NumberLiteral lit1), (loc2, UnaryPattern.NumberLiteral lit2)) ->
              diff_if_changed_ret_opt (number_literal loc1 loc2) lit1 lit2
            | ((loc1, UnaryPattern.BigIntLiteral lit1), (loc2, UnaryPattern.BigIntLiteral lit2)) ->
              diff_if_changed_ret_opt (bigint_literal loc1 loc2) lit1 lit2
            | _ -> None
          in
          let comments = syntax_opt loc comments1 comments2 in
          join_diff_list [argument; comments]
      | ((loc, BindingPattern p1), (_, BindingPattern p2)) ->
        diff_if_changed_ret_opt (match_binding_pattern loc) p1 p2
      | ((_, IdentifierPattern p1), (_, IdentifierPattern p2)) ->
        Some (diff_if_changed identifier p1 p2)
      | ((loc, MemberPattern p1), (_, MemberPattern p2)) ->
        diff_if_changed_ret_opt (match_member_pattern loc) p1 p2
      | ((loc, OrPattern p1), (_, OrPattern p2)) ->
        let { OrPattern.patterns = patterns1; comments = comments1 } = p1 in
        let { OrPattern.patterns = patterns2; comments = comments2 } = p2 in
        let patterns = diff_and_recurse_nonopt_no_trivial match_pattern patterns1 patterns2 in
        let comments = syntax_opt loc comments1 comments2 in
        join_diff_list [patterns; comments]
      | ((loc, ArrayPattern p1), (_, ArrayPattern p2)) ->
        let { ArrayPattern.elements = elements1; rest = rest1; comments = comments1 } = p1 in
        let { ArrayPattern.elements = elements2; rest = rest2; comments = comments2 } = p2 in
        let elements =
          diff_and_recurse_nonopt_no_trivial match_array_pattern_element elements1 elements2
        in
        let rest = diff_if_changed_opt match_rest_pattern rest1 rest2 in
        let comments = syntax_opt loc comments1 comments2 in
        join_diff_list [elements; rest; comments]
      | ((loc, ObjectPattern p1), (_, ObjectPattern p2)) ->
        let { ObjectPattern.properties = props1; rest = rest1; comments = comments1 } = p1 in
        let { ObjectPattern.properties = props2; rest = rest2; comments = comments2 } = p2 in
        let properties =
          diff_and_recurse_nonopt_no_trivial match_object_pattern_property props1 props2
        in
        let rest = diff_if_changed_opt match_rest_pattern rest1 rest2 in
        let comments = syntax_opt loc comments1 comments2 in
        join_diff_list [properties; rest; comments]
      | ((loc, AsPattern p1), (_, AsPattern p2)) ->
        let { AsPattern.pattern = pattern1; target = t1; comments = comments1 } = p1 in
        let { AsPattern.pattern = pattern2; target = t2; comments = comments2 } = p2 in
        let pattern = Some (diff_if_changed match_pattern pattern1 pattern2) in
        let target =
          match (t1, t2) with
          | (AsPattern.Identifier id1, AsPattern.Identifier id2) ->
            Some (diff_if_changed identifier id1 id2)
          | (AsPattern.Binding (loc, b1), AsPattern.Binding (_, b2)) ->
            diff_if_changed_ret_opt (match_binding_pattern loc) b1 b2
          | _ -> None
        in
        let comments = syntax_opt loc comments1 comments2 in
        join_diff_list [pattern; target; comments]
      | _ -> None
    in
    let (loc, _) = p1 in
    result |> Base.Option.value ~default:[replace loc (MatchPattern p1) (MatchPattern p2)]
  and match_member_pattern
      (loc : Loc.t)
      (p1 : (Loc.t, Loc.t) Ast.MatchPattern.MemberPattern.t)
      (p2 : (Loc.t, Loc.t) Ast.MatchPattern.MemberPattern.t) : node change list option =
    let open Ast.MatchPattern.MemberPattern in
    let (_, { base = base1; property = property1; comments = comments1 }) = p1 in
    let (_, { base = base2; property = property2; comments = comments2 }) = p2 in
    let comments = syntax_opt loc comments1 comments2 in
    let base =
      match (base1, base2) with
      | (BaseIdentifier id1, BaseIdentifier id2) -> Some (diff_if_changed identifier id1 id2)
      | (BaseMember m1, BaseMember m2) ->
        let (loc, _) = m1 in
        diff_if_changed_ret_opt (match_member_pattern loc) m1 m2
      | _ -> None
    in
    let property =
      match (property1, property2) with
      | (PropertyNumber (loc1, lit1), PropertyNumber (loc2, lit2)) ->
        diff_if_changed_ret_opt (number_literal loc1 loc2) lit1 lit2
      | (PropertyBigInt (loc1, lit1), PropertyBigInt (loc2, lit2)) ->
        diff_if_changed_ret_opt (bigint_literal loc1 loc2) lit1 lit2
      | (PropertyString (loc1, lit1), PropertyString (loc2, lit2)) ->
        diff_if_changed_ret_opt (string_literal loc1 loc2) lit1 lit2
      | (PropertyIdentifier id1, PropertyIdentifier id2) -> Some (diff_if_changed identifier id1 id2)
      | _ -> None
    in
    join_diff_list [base; property; comments]
  and match_binding_pattern
      (loc : Loc.t)
      (p1 : (Loc.t, Loc.t) Ast.MatchPattern.BindingPattern.t)
      (p2 : (Loc.t, Loc.t) Ast.MatchPattern.BindingPattern.t) : node change list option =
    let open Ast.MatchPattern.BindingPattern in
    let { kind = kind1; id = id1; comments = comments1 } = p1 in
    let { kind = kind2; id = id2; comments = comments2 } = p2 in
    if kind1 != kind2 then
      None
    else
      let id = Some (diff_if_changed identifier id1 id2) in
      let comments = syntax_opt loc comments1 comments2 in
      join_diff_list [id; comments]
  and match_array_pattern_element
      (e1 : (Loc.t, Loc.t) Ast.MatchPattern.ArrayPattern.Element.t)
      (e2 : (Loc.t, Loc.t) Ast.MatchPattern.ArrayPattern.Element.t) : node change list =
    let open Ast.MatchPattern.ArrayPattern.Element in
    let { pattern = p1; index = _ } = e1 in
    let { pattern = p2; index = _ } = e2 in
    diff_if_changed match_pattern p1 p2
  and match_object_pattern_property
      (p1 : (Loc.t, Loc.t) Ast.MatchPattern.ObjectPattern.Property.t)
      (p2 : (Loc.t, Loc.t) Ast.MatchPattern.ObjectPattern.Property.t) : node change list =
    let open Ast.MatchPattern.ObjectPattern in
    let result =
      match (p1, p2) with
      | ( ( loc,
            Property.Valid
              {
                Property.key = key1;
                pattern = pattern1;
                shorthand = shorthand1;
                comments = comments1;
              }
          ),
          ( _,
            Property.Valid
              {
                Property.key = key2;
                pattern = pattern2;
                shorthand = shorthand2;
                comments = comments2;
              }
          )
        ) ->
        if shorthand1 != shorthand2 then
          None
        else
          let key =
            match (key1, key2) with
            | (Property.NumberLiteral (loc1, lit1), Property.NumberLiteral (loc2, lit2)) ->
              diff_if_changed_ret_opt (number_literal loc1 loc2) lit1 lit2
            | (Property.BigIntLiteral (loc1, lit1), Property.BigIntLiteral (loc2, lit2)) ->
              diff_if_changed_ret_opt (bigint_literal loc1 loc2) lit1 lit2
            | (Property.StringLiteral (loc1, lit1), Property.StringLiteral (loc2, lit2)) ->
              diff_if_changed_ret_opt (string_literal loc1 loc2) lit1 lit2
            | (Property.Identifier id1, Property.Identifier id2) ->
              Some (diff_if_changed identifier id1 id2)
            | _ -> None
          in
          let pattern = Some (diff_if_changed match_pattern pattern1 pattern2) in
          let comments = syntax_opt loc comments1 comments2 in
          join_diff_list [key; pattern; comments]
      | _ -> None
    in
    let (loc, _) = p1 in
    result
    |> Base.Option.value
         ~default:[replace loc (MatchObjectPatternProperty p1) (MatchObjectPatternProperty p2)]
  and match_rest_pattern
      (r1 : (Loc.t, Loc.t) Ast.MatchPattern.RestPattern.t)
      (r2 : (Loc.t, Loc.t) Ast.MatchPattern.RestPattern.t) : node change list option =
    let open Ast.MatchPattern.RestPattern in
    let (loc, { argument = arg1; comments = comments1 }) = r1 in
    let (_, { argument = arg2; comments = comments2 }) = r2 in
    let argument =
      diff_if_changed_opt
        (fun (loc, arg1) (_, arg2) -> match_binding_pattern loc arg1 arg2)
        arg1
        arg2
    in
    let comments = syntax_opt loc comments1 comments2 in
    join_diff_list [argument; comments]
  and computed_key
      (loc : Loc.t)
      (computed1 : (Loc.t, Loc.t) Ast.ComputedKey.t')
      (computed2 : (Loc.t, Loc.t) Ast.ComputedKey.t') : node change list option =
    let open Ast.ComputedKey in
    let { expression = expression1; comments = comments1 } = computed1 in
    let { expression = expression2; comments = comments2 } = computed2 in
    let expression_diff =
      Some (diff_if_changed (expression ~parent:SlotParentOfExpression) expression1 expression2)
    in
    let comments_diff = syntax_opt loc comments1 comments2 in
    join_diff_list [expression_diff; comments_diff]
  and private_name (loc : Loc.t) (id1 : Loc.t Ast.PrivateName.t') (id2 : Loc.t Ast.PrivateName.t') :
      node change list =
    let open Ast.PrivateName in
    let { name = name1; comments = comments1 } = id1 in
    let { name = name2; comments = comments2 } = id2 in
    let name =
      if String.equal name1 name2 then
        []
      else
        [replace loc (Raw ("#" ^ name1)) (Raw ("#" ^ name2))]
    in
    let comments = syntax_opt loc comments1 comments2 |> Base.Option.value ~default:[] in
    comments @ name
  and empty_statement
      (loc : Loc.t) (empty1 : Loc.t Ast.Statement.Empty.t) (empty2 : Loc.t Ast.Statement.Empty.t) :
      node change list option =
    let open Ast.Statement.Empty in
    let { comments = comments1 } = empty1 in
    let { comments = comments2 } = empty2 in
    syntax_opt loc comments1 comments2
  in
  program' program1 program2 |> List.sort change_compare
