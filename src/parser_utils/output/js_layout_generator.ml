(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

module Ast = Flow_ast
open Layout

module Trailing_commas = struct
  type t =
    | All  (** Wherever possible (including function arguments). *)
    | ES5  (** Where valid in ES5 (objects, arrays, etc.) *)
    | Off  (** No trailing commas *)

  let enabled_for_function_params = function
    | All -> true
    | ES5 -> false
    | Off -> false

  let enabled_for_function_args = function
    | All -> true
    | ES5 -> true
    | Off -> false

  let enabled_for_objects = function
    | All -> true
    | ES5 -> true
    | Off -> false

  let enabled_for_arrays = function
    | All -> true
    | ES5 -> true
    | Off -> false

  let enabled_for_types = function
    | All -> true
    | ES5 -> true
    | Off -> false
end

type opts = {
  bracket_spacing: bool;
  preserve_formatting: bool;
  single_quotes: bool;
  trailing_commas: Trailing_commas.t;
}

(* There are some cases where expressions must be wrapped in parens to eliminate
   ambiguity. We pass whether we're in one of these special cases down through
   the tree as we generate the layout. Note that these are only necessary as
   long as the ambiguity can exist, so emitting any wrapper (like a paren or
   bracket) is enough to reset the context back to Normal. *)
type expression_context = {
  left: expression_context_left;
  group: expression_context_group;
}

(** certain contexts where the left parenthesis matters. this is set back to [Normal_left]
    as soon as we output something (see [context_after_token]). *)
and expression_context_left =
  | Normal_left
  | In_expression_statement  (** [(function x(){});] would become a declaration w/o the paren **)
  | In_tagged_template  (** [(new a)``] would become [new (a``)] w/o the paren *)
  | In_plus_op  (** [x+(+y)] would become [(x++)y] w/o the paren *)
  | In_minus_op  (** [x-(-y)] would become [(x--)y] w/o the paren *)

and expression_context_group =
  | Normal_group
  | In_arrow_func  (** [() => ({a: b})] would be a block w/ a labeled statement w/o the parens *)
  | In_for_init  (** [for ((x in y);;);] would become a for-in w/o the parens *)

let default_opts =
  {
    bracket_spacing = true;
    preserve_formatting = false;
    single_quotes = false;
    trailing_commas = Trailing_commas.All;
  }

let normal_context = { left = Normal_left; group = Normal_group }

(** Some contexts only matter to the left-most token. If we output some other
    token, like an `=`, then we can reset the context. Note that all contexts
    reset when wrapped in parens, brackets, braces, etc, so we don't need to call
    this in those cases, we can just set it back to Normal. *)
let context_after_token ctxt = { ctxt with left = Normal_left }

(* JS layout helpers *)
let with_semicolon node = fuse [node; Atom ";"]

let with_pretty_semicolon node = fuse [node; IfPretty (Atom ";", Empty)]

let wrap_in_parens ?(with_break = false) item =
  if with_break then
    group [wrap_and_indent ?break:(Some pretty_hardline) (Atom "(", Atom ")") [item]]
  else
    group [Atom "("; item; Atom ")"]

let wrap_in_parens_on_break item =
  group [wrap_and_indent (IfBreak (Atom "(", Empty), IfBreak (Atom ")", Empty)) [item]]

let option f = function
  | Some v -> f v
  | None -> Empty

let hint f = function
  | Ast.Type.Available v -> f v
  | Ast.Type.Missing _ -> Empty

let deoptionalize l =
  List.rev
    (List.fold_left
       (fun acc -> function
         | None -> acc
         | Some x -> x :: acc)
       []
       l
    )

(* See https://developer.mozilla.org/en-US/docs/Web/JavaScript/Reference/Operators/Operator_Precedence *)
let max_precedence = 22

let min_precedence = 1

(* 0 means always parenthesize, which is not a precedence decision *)

let precedence_of_assignment = 3

let precedence_of_expression expr =
  let module E = Ast.Expression in
  match expr with
  (* Expressions that don't involve operators have the highest priority *)
  | (_, E.Array _)
  | (_, E.Class _)
  | (_, E.Function _)
  | (_, E.Identifier _)
  | (_, E.JSXElement _)
  | (_, E.JSXFragment _)
  | (_, E.StringLiteral _)
  | (_, E.BooleanLiteral _)
  | (_, E.NullLiteral _)
  | (_, E.NumberLiteral _)
  | (_, E.BigIntLiteral _)
  | (_, E.RegExpLiteral _)
  | (_, E.Match _)
  | (_, E.ModuleRefLiteral _)
  | (_, E.Object _)
  | (_, E.Super _)
  | (_, E.TemplateLiteral _)
  | (_, E.This _)
  | (_, E.TypeCast _) ->
    max_precedence
  (* Expressions involving operators *)
  | (_, E.Member _)
  | (_, E.OptionalMember _)
  | (_, E.MetaProperty _)
  | (_, E.Call _)
  | (_, E.OptionalCall _)
  | (_, E.New { E.New.arguments = Some _; _ }) ->
    21
  | (_, E.New { E.New.arguments = None; _ }) -> 20
  | (_, E.TaggedTemplate _)
  | (_, E.Import _) ->
    19
  | (_, E.Update { E.Update.prefix = false; _ }) -> 18
  | (_, E.Update { E.Update.prefix = true; _ })
  | (_, E.Unary _) ->
    17
  | (_, E.AsExpression _)
  | (_, E.AsConstExpression _)
  | (_, E.TSSatisfies _) ->
    12
  | (_, E.Binary { E.Binary.operator; _ }) -> begin
    match operator with
    | E.Binary.Exp -> 16
    | E.Binary.Mult -> 15
    | E.Binary.Div -> 15
    | E.Binary.Mod -> 15
    | E.Binary.Plus -> 14
    | E.Binary.Minus -> 14
    | E.Binary.LShift -> 13
    | E.Binary.RShift -> 13
    | E.Binary.RShift3 -> 13
    | E.Binary.LessThan -> 12
    | E.Binary.LessThanEqual -> 12
    | E.Binary.GreaterThan -> 12
    | E.Binary.GreaterThanEqual -> 12
    | E.Binary.In -> 12
    | E.Binary.Instanceof -> 12
    | E.Binary.Equal -> 11
    | E.Binary.NotEqual -> 11
    | E.Binary.StrictEqual -> 11
    | E.Binary.StrictNotEqual -> 11
    | E.Binary.BitAnd -> 10
    | E.Binary.Xor -> 9
    | E.Binary.BitOr -> 8
  end
  | (_, E.Logical { E.Logical.operator = E.Logical.And; _ }) -> 7
  | (_, E.Logical { E.Logical.operator = E.Logical.Or; _ }) -> 6
  | (_, E.Logical { E.Logical.operator = E.Logical.NullishCoalesce; _ }) -> 5
  | (_, E.Conditional _) -> 4
  | (_, E.Assignment _) -> precedence_of_assignment
  | (_, E.ArrowFunction _) ->
    (* must be >= Assignment, so that `x = () => y = 123` doesn't need parens. It must be lower
       than a Conditional so that `(() => {}) ? 1 : 2` doesn't become `() => ({} ? 1 : 2)` *)
    precedence_of_assignment
  | (_, E.Yield _) -> 2
  | (_, E.Sequence _) -> 0

let definitely_needs_parens =
  let module E = Ast.Expression in
  let context_needs_parens ctxt expr =
    match ctxt with
    | { group = In_arrow_func; _ } -> begin
      (* an object body expression in an arrow function needs parens to not
         make it become a block with label statement. *)
      match expr with
      | (_, E.Object _) -> true
      | _ -> false
    end
    | { group = In_for_init; _ } -> begin
      (* an `in` binary expression in the init of a for loop needs parens to not
         make the for loop become a for-in loop. *)
      match expr with
      | (_, E.Binary { E.Binary.operator = E.Binary.In; _ }) -> true
      | _ -> false
    end
    | { left = In_expression_statement; _ } -> begin
      (* functions (including async functions, but not arrow functions) and
         classes must be wrapped in parens to avoid ambiguity with function and
         class declarations. objects must be also, to not be confused with
         blocks.

         https://tc39.github.io/ecma262/#prod-ExpressionStatement *)
      match expr with
      | (_, E.Class _)
      | (_, E.Function _)
      | (_, E.Object _)
      | (_, E.Assignment { E.Assignment.left = (_, Ast.Pattern.Object _); _ }) ->
        true
      | _ -> false
    end
    | { left = In_tagged_template; _ } -> begin
      match expr with
      | (_, E.Class _)
      | (_, E.Function _)
      | (_, E.New _)
      | (_, E.Import _)
      | (_, E.Object _) ->
        true
      | _ -> false
    end
    | { left = In_minus_op; _ } -> begin
      match expr with
      | (_, E.Unary { E.Unary.operator = E.Unary.Minus; _ })
      | (_, E.Update { E.Update.operator = E.Update.Decrement; prefix = true; _ }) ->
        true
      | _ -> false
    end
    | { left = In_plus_op; _ } -> begin
      match expr with
      | (_, E.Unary { E.Unary.operator = E.Unary.Plus; _ })
      | (_, E.Update { E.Update.operator = E.Update.Increment; prefix = true; _ }) ->
        true
      | _ -> false
    end
    | { left = Normal_left; group = Normal_group } -> false
  in
  fun ~precedence ctxt expr ->
    precedence_of_expression expr < precedence || context_needs_parens ctxt expr

(* TODO: this only needs to be shallow; we don't need to walk into function
   or class bodies, for example. *)
class contains_call_mapper result_ref =
  object
    inherit [Loc.t] Flow_ast_mapper.mapper

    method! call _loc expr =
      result_ref := true;
      expr
  end

let contains_call_expression expr =
  (* TODO: use a fold *)
  let result = ref false in
  let _ = (new contains_call_mapper result)#expression expr in
  !result

type statement_or_comment =
  | Statement of (Loc.t, Loc.t) Ast.Statement.t
  | Comment of Loc.t Ast.Comment.t

let better_quote =
  let rec count (double, single) str i =
    if i < 0 then
      (double, single)
    else
      let acc =
        match str.[i] with
        | '"' -> (succ double, single)
        | '\'' -> (double, succ single)
        | _ -> (double, single)
      in
      count acc str (pred i)
  in
  fun ~prefer_single_quotes str ->
    let (double_count, single_count) = count (0, 0) str (String.length str - 1) in
    let double = ("\"", double_count) in
    let single = ("'", single_count) in
    let (preferred, alternate) =
      if prefer_single_quotes then
        (single, double)
      else
        (double, single)
    in
    if snd preferred > snd alternate then
      fst alternate
    else
      fst preferred

let utf8_escape =
  (* a null character can be printed as \x00 or \0. but if the next character is an ASCII digit,
     then using \0 would create \01 (for example), which is a legacy octal 1. so, rather than simply
     fold over the codepoints, we have to look ahead at the next character as well. *)
  let lookahead_fold_wtf_8 :
      ?pos:int ->
      ?len:int ->
      (next:(int * Wtf8.codepoint) option -> 'a -> int -> Wtf8.codepoint -> 'a) ->
      'a ->
      string ->
      'a =
    let lookahead ~f (prev, buf) i cp =
      let next = Some (i, cp) in
      let buf =
        match prev with
        | Some (prev_i, prev_cp) -> f ~next buf prev_i prev_cp
        | None -> buf
      in
      (next, buf)
    in
    fun ?pos ?len f acc str ->
      str |> Wtf8.fold_wtf_8 ?pos ?len (lookahead ~f) (None, acc) |> fun (last, acc) ->
      match last with
      | Some (i, cp) -> f ~next:None acc i cp
      | None -> acc
  in
  let f ~quote ~next buf _i = function
    | Wtf8.Malformed -> buf
    | Wtf8.Point cp -> begin
      match cp with
      (* SingleEscapeCharacter: http://www.ecma-international.org/ecma-262/6.0/#table-34 *)
      | 0x0 ->
        let zero =
          match next with
          | Some (_i, Wtf8.Point n) when 0x30 <= n && n <= 0x39 -> "\\x00"
          | _ -> "\\0"
        in
        Buffer.add_string buf zero;
        buf
      | 0x8 ->
        Buffer.add_string buf "\\b";
        buf
      | 0x9 ->
        Buffer.add_string buf "\\t";
        buf
      | 0xA ->
        Buffer.add_string buf "\\n";
        buf
      | 0xB ->
        Buffer.add_string buf "\\v";
        buf
      | 0xC ->
        Buffer.add_string buf "\\f";
        buf
      | 0xD ->
        Buffer.add_string buf "\\r";
        buf
      | 0x22 when quote = "\"" ->
        Buffer.add_string buf "\\\"";
        buf
      | 0x27 when quote = "'" ->
        Buffer.add_string buf "\\'";
        buf
      | 0x5C ->
        Buffer.add_string buf "\\\\";
        buf
      (* printable ascii *)
      | n when 0x1F < n && n < 0x7F ->
        Buffer.add_char buf (Char.unsafe_chr cp);
        buf
      (* basic multilingual plane, 2 digits *)
      | n when n < 0x100 ->
        Printf.bprintf buf "\\x%02x" n;
        buf
      (* basic multilingual plane, 4 digits *)
      | n when n < 0x10000 ->
        Printf.bprintf buf "\\u%04x" n;
        buf
      (* supplemental planes *)
      | n ->
        (* ES5 does not support the \u{} syntax, so print surrogate pairs
           "\ud83d\udca9" instead of "\u{1f4A9}". if we add a flag to target
           ES6, we should change this. *)
        let n' = n - 0x10000 in
        let hi = 0xD800 lor (n' lsr 10) in
        let lo = 0xDC00 lor (n' land 0x3FF) in
        Printf.bprintf buf "\\u%4x" hi;
        Printf.bprintf buf "\\u%4x" lo;
        buf
    end
  in
  fun ~quote str ->
    str |> lookahead_fold_wtf_8 (f ~quote) (Buffer.create (String.length str)) |> Buffer.contents

let quote_string ~prefer_single_quotes value =
  let quote = better_quote ~prefer_single_quotes value in
  Utils_js.spf "%s%s%s" quote (utf8_escape ~quote value) quote

let is_single_linebreak prev next = Loc.(next.start.line = prev._end.line + 1)

let is_multi_linebreak prev next = Loc.(next.start.line > prev._end.line + 1)

let layout_comment loc comment =
  let open Ast.Comment in
  SourceLocation
    ( loc,
      match comment with
      | { kind = Line; text; _ } -> fuse [Atom "//"; Atom text; hardline]
      | { kind = Block; text; _ } -> fuse [Atom "/*"; Atom text; Atom "*/"]
    )

let layout_from_leading_comment (loc, comment) next_loc =
  let open Ast.Comment in
  let layout_comment = layout_comment loc comment in
  match next_loc with
  | None -> layout_comment
  | Some next_loc ->
    let is_single_linebreak = is_single_linebreak loc next_loc in
    let is_multi_linebreak = is_multi_linebreak loc next_loc in
    (match comment with
    | { kind = Line; _ } when is_multi_linebreak -> fuse [layout_comment; pretty_hardline]
    | { kind = Line; _ } -> layout_comment
    | { kind = Block; _ } when is_multi_linebreak ->
      fuse [layout_comment; pretty_hardline; pretty_hardline]
    | { kind = Block; _ } when is_single_linebreak -> fuse [layout_comment; pretty_hardline]
    | { kind = Block; _ } -> fuse [layout_comment; pretty_space])

let layout_from_trailing_comment (loc, comment) (prev_loc, prev_comment) =
  let open Ast.Comment in
  let is_single_linebreak = is_single_linebreak prev_loc loc in
  let is_multi_linebreak = is_multi_linebreak prev_loc loc in
  let layout_comment = layout_comment loc comment in
  match prev_comment with
  | Some { kind = Line; _ } when is_multi_linebreak -> fuse [pretty_hardline; layout_comment]
  | Some { kind = Line; _ } -> layout_comment
  | Some { kind = Block; _ } when is_multi_linebreak ->
    fuse [pretty_hardline; pretty_hardline; layout_comment]
  | Some { kind = Block; _ } when is_single_linebreak -> fuse [pretty_hardline; layout_comment]
  | Some { kind = Block; _ } -> fuse [pretty_space; layout_comment]
  | None when is_multi_linebreak -> fuse [pretty_hardline; pretty_hardline; layout_comment]
  | None when is_single_linebreak -> fuse [pretty_hardline; layout_comment]
  | None -> fuse [pretty_space; layout_comment]

let layout_from_leading_comments comments node_loc =
  let rec inner = function
    | [] -> []
    | [comment] -> [layout_from_leading_comment comment node_loc]
    | comment :: ((next_loc, _) :: _ as rest) ->
      layout_from_leading_comment comment (Some next_loc) :: inner rest
  in
  inner comments

let layout_from_trailing_comments comments node_loc =
  let rec inner prev_comment = function
    | [] -> []
    | (loc, comment) :: rest ->
      layout_from_trailing_comment (loc, comment) prev_comment :: inner (loc, Some comment) rest
  in
  inner node_loc comments

let layout_node_with_comments current_loc comments layout_node =
  let { Ast.Syntax.leading; trailing; _ } = comments in
  let preceding = layout_from_leading_comments leading (Some current_loc) in
  let following = layout_from_trailing_comments trailing (current_loc, None) in
  Concat (List.concat [preceding; [layout_node]; following])

let layout_node_with_comments_opt current_loc comments layout_node =
  match comments with
  | Some c -> layout_node_with_comments current_loc c layout_node
  | None -> layout_node

let source_location_with_comments ?comments (current_loc, layout_node) =
  let layout = SourceLocation (current_loc, layout_node) in
  match comments with
  | Some comments -> layout_node_with_comments current_loc comments layout
  | None -> layout

let internal_comments = function
  | None
  | Some { Ast.Syntax.internal = []; _ } ->
    None
  | Some { Ast.Syntax.internal = (first_loc, _) :: _ as internal; _ } ->
    Some (first_loc, (None, None), Concat (layout_from_leading_comments internal None))

(* Given a set of comment bounds, determine what separator should be inserted before the
   comments to preserve whether the first comment starts on a new line.

   - If there are no leading comments return the specified separator.
   - If the first leading comment starts on a new line, ignore the specified separator and
     return a hard line break.
   - If the first leading comment does not start on a new line, return the optional same_line
     separator, otherwise return the no_comment separator. *)
let comment_aware_separator ?(same_line = None) ~no_comment comment_bounds =
  match comment_bounds with
  | (Some (_, { Ast.Comment.on_newline = true; _ }), _) -> pretty_hardline
  | (Some (_, { Ast.Comment.on_newline = false; _ }), _) ->
    (match same_line with
    | None -> no_comment
    | Some sep -> sep)
  | _ -> no_comment

let identifier_with_comments current_loc name comments =
  let node = Identifier (current_loc, name) in
  match comments with
  | Some comments -> layout_node_with_comments current_loc comments node
  | None -> node

(* Generate JS layouts *)
let rec program
    ?(opts = default_opts)
    ~preserve_docblock
    ~checksum
    (loc, { Ast.Program.statements; all_comments; _ }) =
  let nodes =
    if preserve_docblock && all_comments <> [] then
      let (directives, statements) = Flow_ast_utils.partition_directives statements in
      let all_comments =
        match statements with
        | [] -> all_comments
        | (loc, _) :: _ -> Comment_utils.comments_before_loc loc all_comments
      in
      [
        combine_directives_and_comments ~opts directives all_comments;
        fuse (statement_list ~opts statements);
      ]
    else
      [fuse (statement_list ~opts statements)]
  in
  let nodes = group [join pretty_hardline nodes] in
  let nodes = maybe_embed_checksum nodes checksum in
  let loc = { loc with Loc.start = { Loc.line = 1; column = 0 } } in
  source_location_with_comments (loc, nodes)

and program_simple ?(opts = default_opts) (loc, { Ast.Program.statements; _ }) =
  let nodes = group [fuse (statement_list ~opts statements)] in
  let loc = { loc with Loc.start = { Loc.line = 1; column = 0 } } in
  source_location_with_comments (loc, nodes)

and combine_directives_and_comments ~opts directives comments : Layout.layout_node =
  let directives = Base.List.map ~f:(fun ((loc, _) as x) -> (loc, Statement x)) directives in
  let comments = Base.List.map ~f:(fun ((loc, _) as x) -> (loc, Comment x)) comments in
  let merged = List.merge (fun (a, _) (b, _) -> Loc.compare a b) directives comments in
  let nodes =
    Base.List.map
      ~f:(function
        | (loc, Statement s) ->
          (loc, Comment_attachment.statement_comment_bounds s, statement ~opts s)
        | (loc, Comment c) -> (loc, (None, None), comment c))
      merged
  in
  fuse (list_with_newlines nodes)

and maybe_embed_checksum nodes checksum =
  match checksum with
  | Some checksum ->
    let comment = Printf.sprintf "/* %s */" checksum in
    fuse [nodes; Newline; Atom comment]
  | None -> nodes

and comment (loc, comment) =
  let open Ast.Comment in
  source_location_with_comments
    ( loc,
      match comment with
      | { kind = Block; text; _ } -> fuse [Atom "/*"; Atom text; Atom "*/"]
      | { kind = Line; text; _ } -> fuse [Atom "//"; Atom text; Newline]
    )

(**
 * Renders a statement
 *
 * Set `pretty_semicolon` when a semicolon is only required in pretty mode. For example,
 * a semicolon is never required on the last statement of a statement list, so we can set
 * `~pretty_semicolon:true` to only print the unnecessary semicolon in pretty mode.
 *)
and statement ?(pretty_semicolon = false) ~opts (root_stmt : (Loc.t, Loc.t) Ast.Statement.t) =
  let (loc, stmt) = root_stmt in
  let module E = Ast.Expression in
  let module S = Ast.Statement in
  let with_semicolon =
    if pretty_semicolon then
      with_pretty_semicolon
    else
      with_semicolon
  in
  source_location_with_comments
    ( loc,
      match stmt with
      | S.Empty { S.Empty.comments } -> layout_node_with_comments_opt loc comments (Atom ";")
      | S.Debugger { S.Debugger.comments } ->
        layout_node_with_comments_opt loc comments @@ with_semicolon (Atom "debugger")
      | S.Block b -> block ~opts (loc, b)
      | S.Expression { S.Expression.expression = expr; directive = _; comments } ->
        let ctxt = { normal_context with left = In_expression_statement } in
        layout_node_with_comments_opt loc comments
        @@ with_semicolon (expression_with_parens ~precedence:0 ~ctxt ~opts expr)
      | S.If { S.If.test; consequent; alternate; comments } ->
        layout_node_with_comments_opt
          loc
          comments
          begin
            match alternate with
            | Some (loc, ({ S.If.Alternate.body; comments } as alternate)) ->
              let alternate_separator =
                comment_aware_separator
                  ~no_comment:pretty_space
                  (Comment_attachment.if_alternate_statement_comment_bounds loc alternate)
              in
              fuse
                [
                  group
                    [
                      statement_with_test "if" (expression ~opts test);
                      statement_after_test ~opts consequent;
                    ];
                  alternate_separator;
                  layout_node_with_comments_opt loc comments
                  @@ fuse_with_space [Atom "else"; statement ~opts ~pretty_semicolon body];
                ]
            | None ->
              group
                [
                  statement_with_test "if" (expression ~opts test);
                  statement_after_test ~opts ~pretty_semicolon consequent;
                ]
          end
      | S.Labeled { S.Labeled.label; body; comments } ->
        layout_node_with_comments_opt
          loc
          comments
          (fuse [identifier label; Atom ":"; pretty_space; statement ~opts body])
      | S.Break { S.Break.label; comments } ->
        let s_break = Atom "break" in
        layout_node_with_comments_opt loc comments
        @@ with_semicolon
             (match label with
             | Some l -> fuse [s_break; space; identifier l]
             | None -> s_break)
      | S.Continue { S.Continue.label; comments } ->
        let s_continue = Atom "continue" in
        layout_node_with_comments_opt loc comments
        @@ with_semicolon
             (match label with
             | Some l -> fuse [s_continue; space; identifier l]
             | None -> s_continue)
      | S.With { S.With._object; body; comments } ->
        layout_node_with_comments_opt
          loc
          comments
          (fuse
             [
               statement_with_test "with" (expression ~opts _object); statement_after_test ~opts body;
             ]
          )
      | S.Match { Ast.Match.arg; cases; match_keyword_loc = _; comments } ->
        let cases =
          List.map
            (fun ((loc, _) as case) ->
              ( loc,
                Comment_attachment.match_statement_case_comment_bounds case,
                match_case ~opts ~on_case_body:(statement ~pretty_semicolon:false) case
              ))
            cases
          |> list_with_newlines
        in
        let cases_node = wrap_and_indent ~break:pretty_hardline (Atom "{", Atom "}") [fuse cases] in
        layout_node_with_comments_opt
          loc
          comments
          (fuse
             [
               group
                 [
                   Atom "match";
                   pretty_space;
                   wrap_and_indent (Atom "(", Atom ")") [expression ~opts arg];
                 ];
               pretty_space;
               cases_node;
             ]
          )
      | S.Switch { S.Switch.discriminant; cases; comments; exhaustive_out = _ } ->
        let case_nodes =
          let rec helper acc =
            let open Comment_attachment in
            function
            | [] -> List.rev acc
            | [((loc, _) as case)] ->
              let case =
                (loc, switch_case_comment_bounds case, switch_case ~opts ~last:true case)
              in
              List.rev (case :: acc)
            | ((loc, _) as case) :: rest ->
              let case =
                (loc, switch_case_comment_bounds case, switch_case ~opts ~last:false case)
              in
              helper (case :: acc) rest
          in
          helper [] cases |> list_with_newlines
        in
        let cases_node =
          wrap_and_indent ~break:pretty_hardline (Atom "{", Atom "}") [fuse case_nodes]
        in
        layout_node_with_comments_opt
          loc
          comments
          (fuse
             [
               statement_with_test "switch" (expression ~opts discriminant); pretty_space; cases_node;
             ]
          )
      | S.Return { S.Return.argument; comments; return_out = _ } ->
        let s_return = Atom "return" in
        layout_node_with_comments_opt loc comments
        @@ with_semicolon
             (match argument with
             | Some arg ->
               let arg =
                 match arg with
                 | (_, E.Logical _)
                 | (_, E.Binary _)
                 | (_, E.Sequence _)
                 | (_, E.JSXElement _) ->
                   wrap_in_parens_on_break (expression ~opts arg)
                 | _ ->
                   (* If the return argument has a leading comment then we must wrap the argument
                      and its comments in parens. Otherwise, the comments could push the argument
                      to the next line, meaning the return would be parsed without an argument. *)
                   let (leading, _) = Comment_attachment.expression_comment_bounds arg in
                   let arg = expression ~opts arg in
                   if leading = None then
                     arg
                   else
                     wrap_in_parens_on_break arg
               in
               fuse_with_space [s_return; arg]
             | None -> s_return)
      | S.Throw { S.Throw.argument; comments } ->
        layout_node_with_comments_opt loc comments
        @@ with_semicolon
             (fuse_with_space [Atom "throw"; wrap_in_parens_on_break (expression ~opts argument)])
      | S.Try { S.Try.block = b; handler; finalizer; comments } ->
        layout_node_with_comments_opt
          loc
          comments
          (fuse
             [
               Atom "try";
               pretty_space;
               block ~opts b;
               (match handler with
               | Some (loc, { S.Try.CatchClause.param; body; comments }) ->
                 source_location_with_comments
                   ?comments
                   ( loc,
                     match param with
                     | Some p ->
                       fuse
                         [
                           pretty_space;
                           statement_with_test "catch" (pattern ~ctxt:normal_context ~opts p);
                           pretty_space;
                           block ~opts body;
                         ]
                     | None -> fuse [pretty_space; Atom "catch"; pretty_space; block ~opts body]
                   )
               | None -> Empty);
               (match finalizer with
               | Some b -> fuse [pretty_space; Atom "finally"; pretty_space; block ~opts b]
               | None -> Empty);
             ]
          )
      | S.While { S.While.test; body; comments } ->
        layout_node_with_comments_opt
          loc
          comments
          (fuse
             [
               statement_with_test "while" (expression ~opts test);
               statement_after_test ~opts ~pretty_semicolon body;
             ]
          )
      | S.DoWhile { S.DoWhile.body; test; comments } ->
        layout_node_with_comments_opt loc comments
        @@ with_semicolon
             (fuse
                [
                  fuse_with_space [Atom "do"; statement ~opts body];
                  pretty_space;
                  Atom "while";
                  pretty_space;
                  group [wrap_and_indent (Atom "(", Atom ")") [expression ~opts test]];
                ]
             )
      | S.For { S.For.init; test; update; body; comments } ->
        layout_node_with_comments_opt loc comments
        @@ fuse
             [
               statement_with_test
                 "for"
                 (join
                    (fuse [Atom ";"; pretty_line])
                    [
                      begin
                        match init with
                        | Some (S.For.InitDeclaration decl) ->
                          let ctxt = { normal_context with group = In_for_init } in
                          variable_declaration ~ctxt ~opts decl
                        | Some (S.For.InitExpression expr) ->
                          let ctxt = { normal_context with group = In_for_init } in
                          expression_with_parens ~precedence:0 ~ctxt ~opts expr
                        | None -> Empty
                      end;
                      begin
                        match test with
                        | Some expr -> expression ~opts expr
                        | None -> Empty
                      end;
                      begin
                        match update with
                        | Some expr -> expression ~opts expr
                        | None -> Empty
                      end;
                    ]
                 );
               statement_after_test ~opts ~pretty_semicolon body;
             ]
      | S.ForIn { S.ForIn.left; right; body; each; comments } ->
        layout_node_with_comments_opt loc comments
        @@ fuse
             [
               Atom "for";
               ( if each then
                 fuse [space; Atom "each"]
               else
                 Empty
               );
               pretty_space;
               wrap_in_parens
                 (fuse_with_space
                    [
                      begin
                        match left with
                        | S.ForIn.LeftDeclaration decl -> variable_declaration ~opts decl
                        | S.ForIn.LeftPattern patt -> pattern ~opts patt
                      end;
                      Atom "in";
                      expression ~opts right;
                    ]
                 );
               statement_after_test ~opts ~pretty_semicolon body;
             ]
      | S.FunctionDeclaration func -> function_ ~opts loc func
      | S.ComponentDeclaration component -> component_declaration ~opts loc component
      | S.VariableDeclaration decl ->
        let semicolon =
          if pretty_semicolon then
            Some (IfPretty (Atom ";", Empty))
          else
            Some (Atom ";")
        in
        variable_declaration ?semicolon ~opts (loc, decl)
      | S.ClassDeclaration class_ -> class_base ~opts loc class_
      | S.EnumDeclaration enum -> enum_declaration ~def:(Atom "enum") loc enum
      | S.ForOf { S.ForOf.left; right; body; await; comments } ->
        layout_node_with_comments_opt loc comments
        @@ fuse
             [
               Atom "for";
               ( if await then
                 fuse [space; Atom "await"]
               else
                 Empty
               );
               pretty_space;
               wrap_in_parens
                 (fuse_with_space
                    [
                      begin
                        match left with
                        | S.ForOf.LeftDeclaration decl -> variable_declaration ~opts decl
                        | S.ForOf.LeftPattern
                            ( ( _,
                                Ast.Pattern.Identifier
                                  {
                                    Ast.Pattern.Identifier.name =
                                      (_, { Ast.Identifier.name = "async"; _ });
                                    annot = Ast.Type.Missing _;
                                    _;
                                  }
                              ) as patt
                            ) ->
                          wrap_in_parens (pattern ~opts patt)
                        | S.ForOf.LeftPattern patt -> pattern ~opts patt
                      end;
                      Atom "of";
                      expression_with_parens
                        ~ctxt:normal_context
                        ~precedence:min_precedence
                        ~opts
                        right;
                    ]
                 );
               statement_after_test ~opts ~pretty_semicolon body;
             ]
      | S.ImportDeclaration import -> import_declaration ~opts loc import
      | S.ExportNamedDeclaration export -> export_declaration ~opts loc export
      | S.ExportDefaultDeclaration export -> export_default_declaration ~opts loc export
      | S.TypeAlias typeAlias -> type_alias ~opts ~declare:false loc typeAlias
      | S.OpaqueType opaqueType -> opaque_type ~opts ~declare:false loc opaqueType
      | S.InterfaceDeclaration interface -> interface_declaration ~opts loc interface
      | S.DeclareClass interface -> declare_class ~opts loc interface
      | S.DeclareComponent interface -> declare_component ~opts loc interface
      | S.DeclareEnum enum -> declare_enum loc enum
      | S.DeclareFunction func -> declare_function ~opts loc func
      | S.DeclareInterface interface -> declare_interface ~opts loc interface
      | S.DeclareVariable var -> declare_variable ~opts loc var
      | S.DeclareModuleExports exports -> declare_module_exports ~opts loc exports
      | S.DeclareModule m -> declare_module ~opts loc m
      | S.DeclareNamespace n -> declare_namespace ~opts loc n
      | S.DeclareTypeAlias typeAlias -> type_alias ~opts ~declare:true loc typeAlias
      | S.DeclareOpaqueType opaqueType -> opaque_type ~opts ~declare:true loc opaqueType
      | S.DeclareExportDeclaration export -> declare_export_declaration ~opts loc export
    )

(* The beginning of a statement that does a "test", like `if (test)` or `while (test)` *)
and statement_with_test name test =
  group [Atom name; pretty_space; wrap_and_indent (Atom "(", Atom ")") [test]]

(* A statement following a "test", like the `statement` in `if (expr) statement` or
   `for (...) statement`. Better names for this are welcome! *)
and statement_after_test ?pretty_semicolon ~opts = function
  | (_, Ast.Statement.Empty _) as stmt -> statement ?pretty_semicolon ~opts stmt
  | (_, Ast.Statement.Block _) as stmt ->
    fuse [pretty_space; statement ?pretty_semicolon ~opts stmt]
  | stmt -> Indent (fuse [pretty_line; statement ?pretty_semicolon ~opts stmt])

and expression ?(ctxt = normal_context) ~opts (root_expr : (Loc.t, Loc.t) Ast.Expression.t) =
  let (loc, expr) = root_expr in
  let module E = Ast.Expression in
  let precedence = precedence_of_expression (loc, expr) in
  source_location_with_comments
    ( loc,
      match expr with
      | E.This { E.This.comments } -> layout_node_with_comments_opt loc comments (Atom "this")
      | E.Super { E.Super.comments } -> layout_node_with_comments_opt loc comments (Atom "super")
      | E.Array { E.Array.elements; comments } ->
        let element_loc = function
          | E.Array.Hole loc -> loc
          | E.Array.Expression (loc, _) -> loc
          | E.Array.Spread (loc, _) -> loc
        in
        let has_trailing_hole =
          match List.rev elements with
          | E.Array.Hole _ :: _ -> true
          | _ -> false
        in
        let elements =
          List.map
            (fun element ->
              let loc = element_loc element in
              ( loc,
                Comment_attachment.array_element_comment_bounds loc element,
                array_element ~ctxt:normal_context ~opts element
              ))
            elements
        in
        let elements_layout =
          list_with_newlines ~sep:(Atom ",") ~sep_linebreak:pretty_line ~skip_empty:false elements
        in
        (* If the last element is a hole, then we need to manually insert a trailing `,` even in
           ugly mode. Otherwise add a trailing comma only in pretty mode. *)
        let trailing_comma =
          if has_trailing_hole then
            Atom ","
          else if elements <> [] && Trailing_commas.enabled_for_arrays opts.trailing_commas then
            if_break (Atom ",") Empty
          else
            Empty
        in
        let elements_layout = elements_layout @ [trailing_comma] in
        let elements_layout = list_add_internal_comments elements elements_layout comments in
        layout_node_with_comments_opt loc comments
        @@ group [wrap_and_indent (Atom "[", Atom "]") elements_layout]
      | E.Object { E.Object.properties; comments } ->
        let prop_loc = function
          | E.Object.Property (loc, _) -> loc
          | E.Object.SpreadProperty (loc, _) -> loc
        in
        let num_props = List.length properties in
        let internal_comments =
          match internal_comments comments with
          | None -> []
          | Some comments -> [comments]
        in
        let props =
          Base.List.mapi
            ~f:(fun i prop ->
              (* Add trailing comma to last property *)
              let prop_layout =
                if
                  i = num_props - 1
                  && internal_comments = []
                  && Trailing_commas.enabled_for_objects opts.trailing_commas
                then
                  fuse [object_property ~opts prop; if_break (Atom ",") Empty]
                else
                  object_property ~opts prop
              in
              (prop_loc prop, Comment_attachment.object_property_comment_bounds prop, prop_layout))
            properties
        in
        let props = props @ internal_comments in
        let props = list_with_newlines ~sep:(Atom ",") ~sep_linebreak:pretty_line props in
        (* If first prop is on a different line then pretty print with line breaks *)
        let break =
          match properties with
          | [] -> None
          | first_prop :: _ ->
            if Loc.(loc.start.line < (prop_loc first_prop).start.line) then
              Some pretty_hardline
            else if opts.bracket_spacing then
              Some pretty_line
            else
              Some softline
        in
        let props_layout = wrap_and_indent ?break (Atom "{", Atom "}") props in
        layout_node_with_comments_opt loc comments @@ group [props_layout]
      | E.Sequence { E.Sequence.expressions; comments } ->
        (* to get an AST like `x, (y, z)`, then there must've been parens
           around the right side. we can force that by bumping the minimum
           precedence. *)
        let precedence = precedence + 1 in
        let layouts =
          Base.List.map ~f:(expression_with_parens ~precedence ~ctxt ~opts) expressions
        in
        layout_node_with_comments_opt loc comments
        @@ group [join (fuse [Atom ","; pretty_line]) layouts]
      | E.Identifier ident -> identifier ident
      | E.StringLiteral lit -> string_literal ~opts loc lit
      | E.BooleanLiteral lit -> boolean_literal loc lit
      | E.NullLiteral lit -> null_literal loc lit
      | E.NumberLiteral lit -> number_literal ~opts loc lit
      | E.BigIntLiteral lit -> bigint_literal loc lit
      | E.RegExpLiteral lit -> regexp_literal ~opts loc lit
      | E.ModuleRefLiteral lit -> module_ref_literal loc lit
      | E.Function func -> function_ ~opts loc func
      | E.ArrowFunction func -> arrow_function ~ctxt ~opts loc func
      | E.Assignment { E.Assignment.operator; left; right; comments } ->
        layout_node_with_comments_opt loc comments
        @@ fuse
             [
               pattern ~ctxt ~opts left;
               pretty_space;
               begin
                 match operator with
                 | None -> Atom "="
                 | Some op -> Atom (Flow_ast_utils.string_of_assignment_operator op)
               end;
               comment_aware_separator
                 ~no_comment:pretty_space
                 (Comment_attachment.expression_comment_bounds right);
               begin
                 let ctxt = context_after_token ctxt in
                 expression_with_parens ~precedence ~ctxt ~opts right
               end;
             ]
      | E.Binary { E.Binary.operator; left; right; comments } ->
        layout_node_with_comments_opt loc comments
        @@ fuse_with_space
             [
               expression_with_parens ~precedence ~ctxt ~opts left;
               Atom (Flow_ast_utils.string_of_binary_operator operator);
               begin
                 match (operator, right) with
                 | (E.Binary.Plus, (_, E.Unary { E.Unary.operator = E.Unary.Plus; _ }))
                 | (E.Binary.Minus, (_, E.Unary { E.Unary.operator = E.Unary.Minus; _ }))
                 | ( E.Binary.Plus,
                     (_, E.Update { E.Update.prefix = true; operator = E.Update.Increment; _ })
                   )
                 | ( E.Binary.Minus,
                     (_, E.Update { E.Update.prefix = true; operator = E.Update.Decrement; _ })
                   ) ->
                   let ctxt = context_after_token ctxt in
                   let right_separator =
                     comment_aware_separator
                       ~no_comment:ugly_space
                       (Comment_attachment.expression_comment_bounds right)
                   in
                   fuse [right_separator; expression ~ctxt ~opts right]
                 | _ ->
                   (* to get an AST like `x + (y - z)`, then there must've been parens
                      around the right side. we can force that by bumping the minimum
                      precedence to not have parens. *)
                   let precedence = precedence + 1 in
                   let ctxt =
                     {
                       ctxt with
                       left =
                         (match operator with
                         | E.Binary.Minus -> In_minus_op
                         | E.Binary.Plus -> In_plus_op
                         | _ -> Normal_left);
                     }
                   in
                   let right_separator =
                     comment_aware_separator
                       ~no_comment:Empty
                       (Comment_attachment.expression_comment_bounds right)
                   in
                   fuse [right_separator; expression_with_parens ~opts ~precedence ~ctxt right]
               end;
             ]
      | E.Call c -> call ~precedence ~ctxt ~opts c loc
      | E.OptionalCall { E.OptionalCall.call = c; optional; filtered_out = _ } ->
        call ~optional ~precedence ~ctxt ~opts c loc
      | E.Conditional { E.Conditional.test; consequent; alternate; comments } ->
        let test_layout =
          (* increase precedence since conditionals are right-associative *)
          expression_with_parens ~precedence:(precedence + 1) ~ctxt ~opts test
        in
        layout_node_with_comments_opt loc comments
        @@ group
             [
               test_layout;
               Indent
                 (fuse
                    [
                      pretty_line;
                      Atom "?";
                      pretty_space;
                      expression_with_parens ~precedence:min_precedence ~ctxt ~opts consequent;
                      pretty_line;
                      Atom ":";
                      pretty_space;
                      expression_with_parens ~precedence:min_precedence ~ctxt ~opts alternate;
                    ]
                 );
             ]
      | E.Logical { E.Logical.operator; left; right; comments } ->
        let expression_with_parens ~precedence ~ctxt ~opts expr =
          match (operator, expr) with
          (* Logical expressions inside a nullish coalese expression must be wrapped in parens *)
          | ( E.Logical.NullishCoalesce,
              (_, E.Logical { E.Logical.operator = E.Logical.And | E.Logical.Or; _ })
            ) ->
            let (leading, _) = Comment_attachment.expression_comment_bounds expr in
            wrap_in_parens ~with_break:(leading <> None) (expression ~opts expr)
          | _ -> expression_with_parens ~precedence ~ctxt ~opts expr
        in
        let left = expression_with_parens ~precedence ~ctxt ~opts left in
        let operator =
          match operator with
          | E.Logical.Or -> Atom "||"
          | E.Logical.And -> Atom "&&"
          | E.Logical.NullishCoalesce -> Atom "??"
        in
        let right_separator =
          comment_aware_separator
            ~no_comment:pretty_line
            ~same_line:(Some pretty_space)
            (Comment_attachment.expression_comment_bounds right)
        in
        let right = expression_with_parens ~precedence:(precedence + 1) ~ctxt ~opts right in
        (* if we need to wrap, the op stays on the first line, with the RHS on a
           new line and indented by 2 spaces *)
        layout_node_with_comments_opt loc comments
        @@ Group [left; pretty_space; operator; Indent (fuse [right_separator; right])]
      | E.Member m -> member ~precedence ~ctxt ~opts m loc
      | E.OptionalMember { E.OptionalMember.member = m; optional; filtered_out = _ } ->
        member ~optional ~precedence ~ctxt ~opts m loc
      | E.New { E.New.callee; targs; arguments; comments } ->
        let callee_layout =
          if definitely_needs_parens ~precedence ctxt callee || contains_call_expression callee then
            let (leading, _) = Comment_attachment.expression_comment_bounds callee in
            wrap_in_parens ~with_break:(leading <> None) (expression ~ctxt ~opts callee)
          else
            expression ~ctxt ~opts callee
        in
        layout_node_with_comments_opt loc comments
        @@ group
             [
               fuse_with_space [Atom "new"; callee_layout];
               option (call_type_args ~opts ~less_than:"<") targs;
               option (call_args ~opts ~is_new:true ~lparen:"(") arguments;
             ]
      | E.Unary { E.Unary.operator; argument; comments } ->
        let (s_operator, needs_space, prefix) =
          match operator with
          | E.Unary.Minus -> (Atom "-", false, true)
          | E.Unary.Plus -> (Atom "+", false, true)
          | E.Unary.Not -> (Atom "!", false, true)
          | E.Unary.BitNot -> (Atom "~", false, true)
          | E.Unary.Typeof -> (Atom "typeof", true, true)
          | E.Unary.Void -> (Atom "void", true, true)
          | E.Unary.Delete -> (Atom "delete", true, true)
          | E.Unary.Await -> (Atom "await", true, true)
          | E.Unary.Nonnull -> (Atom "!", false, false)
        in
        let expr =
          let ctxt =
            {
              ctxt with
              left =
                (match operator with
                | E.Unary.Minus -> In_minus_op
                | E.Unary.Plus -> In_plus_op
                | _ -> Normal_left);
            }
          in
          expression_with_parens ~precedence ~ctxt ~opts argument
        in
        let (fst, snd) =
          if prefix then
            (s_operator, expr)
          else
            (expr, s_operator)
        in
        layout_node_with_comments_opt loc comments
        @@ fuse
             [
               fst;
               ( if needs_space then
                 match argument with
                 | (_, E.Sequence _) -> Empty
                 | _ -> space
               else
                 Empty
               );
               snd;
             ]
      | E.Update { E.Update.operator; prefix; argument; comments } ->
        layout_node_with_comments_opt
          loc
          comments
          (let s_operator =
             match operator with
             | E.Update.Increment -> Atom "++"
             | E.Update.Decrement -> Atom "--"
           in
           (* we never need to wrap `argument` in parens because it must be a valid
              left-hand side expression *)
           if prefix then
             fuse [s_operator; expression ~ctxt ~opts argument]
           else
             fuse [expression ~ctxt ~opts argument; s_operator]
          )
      | E.Class class_ -> class_base ~opts loc class_
      | E.Yield { E.Yield.argument; delegate; comments; result_out = _ } ->
        layout_node_with_comments_opt loc comments
        @@ fuse
             [
               Atom "yield";
               ( if delegate then
                 Atom "*"
               else
                 Empty
               );
               (match argument with
               | Some arg -> fuse [space; expression ~ctxt ~opts arg]
               | None -> Empty);
             ]
      | E.Match { Ast.Match.arg; cases; comments; match_keyword_loc = _ } ->
        let cases =
          List.map
            (fun ((loc, _) as case) ->
              ( loc,
                Comment_attachment.match_expression_case_comment_bounds case,
                match_case ~opts ~on_case_body:(expression ?ctxt:None) case
              ))
            cases
        in
        let cases_nodes = list_with_newlines ~sep:(Atom ",") ~skip_empty:false cases in
        let cases_nodes = cases_nodes @ [if_pretty (Atom ",") Empty] in
        let cases_node =
          wrap_and_indent ~break:pretty_hardline (Atom "{", Atom "}") [fuse cases_nodes]
        in
        layout_node_with_comments_opt
          loc
          comments
          (fuse
             [
               group
                 [
                   Atom "match";
                   pretty_space;
                   wrap_and_indent (Atom "(", Atom ")") [expression ~opts arg];
                 ];
               pretty_space;
               cases_node;
             ]
          )
      | E.MetaProperty { E.MetaProperty.meta; property; comments } ->
        layout_node_with_comments_opt loc comments
        @@ fuse [identifier meta; Atom "."; identifier property]
      | E.TaggedTemplate
          {
            E.TaggedTemplate.tag;
            quasi =
              (template_loc, ({ E.TemplateLiteral.comments = template_comments; _ } as template));
            comments;
          } ->
        let ctxt = { normal_context with left = In_tagged_template } in
        layout_node_with_comments_opt loc comments
        @@ fuse
             [
               expression_with_parens ~precedence ~ctxt ~opts tag;
               source_location_with_comments
                 ?comments:template_comments
                 (template_loc, template_literal ~opts template);
             ]
      | E.TemplateLiteral ({ E.TemplateLiteral.comments; _ } as template) ->
        layout_node_with_comments_opt loc comments (template_literal ~opts template)
      | E.JSXElement el -> jsx_element ~opts loc el
      | E.JSXFragment fr -> jsx_fragment ~opts loc fr
      | E.TypeCast cast -> type_cast ~opts loc cast
      | E.AsConstExpression cast -> as_const_expression ~ctxt ~opts ~precedence loc cast
      | E.AsExpression cast -> as_expression ~ctxt ~opts ~precedence loc cast
      | E.TSSatisfies cast -> ts_satisfies ~opts loc cast
      | E.Import { E.Import.argument; comments } ->
        layout_node_with_comments_opt loc comments
        @@ fuse [Atom "import"; wrap_in_parens (expression ~opts argument)]
    )

and call ?(optional = Ast.Expression.OptionalCall.NonOptional) ~precedence ~ctxt ~opts call_node loc
    =
  let { Ast.Expression.Call.callee; targs; arguments; comments } = call_node in
  let (targs, lparen) =
    match targs with
    | None ->
      let lparen =
        match optional with
        | Ast.Expression.OptionalCall.NonOptional -> "("
        | Ast.Expression.OptionalCall.Optional -> "?.("
        | Ast.Expression.OptionalCall.AssertNonnull -> "!("
      in
      (Empty, lparen)
    | Some targs ->
      let less_than =
        match optional with
        | Ast.Expression.OptionalCall.NonOptional -> "<"
        | Ast.Expression.OptionalCall.Optional -> "?.<"
        | Ast.Expression.OptionalCall.AssertNonnull -> "!<"
      in
      (call_type_args ~opts ~less_than targs, "(")
  in
  layout_node_with_comments_opt
    loc
    comments
    (fuse
       [
         expression_with_parens ~precedence ~ctxt ~opts callee;
         targs;
         call_args ~opts ~is_new:false ~lparen arguments;
       ]
    )

and expression_with_parens ~opts ~precedence ~(ctxt : expression_context) expr =
  if definitely_needs_parens ~precedence ctxt expr then
    let (leading, _) = Comment_attachment.expression_comment_bounds expr in
    wrap_in_parens ~with_break:(leading <> None) (expression ~ctxt:normal_context ~opts expr)
  else
    expression ~ctxt ~opts expr

and spread_element ~opts ~precedence ~ctxt (loc, { Ast.Expression.SpreadElement.argument; comments })
    =
  source_location_with_comments
    ?comments
    (loc, fuse [Atom "..."; expression_with_parens ~precedence ~ctxt ~opts argument])

and expression_or_spread ?(ctxt = normal_context) ~opts expr_or_spread =
  (* min_precedence causes operators that should always be parenthesized
     (they have precedence = 0) to be parenthesized. one notable example is
     the comma operator, which would be confused with additional arguments if
     not parenthesized. *)
  let precedence = min_precedence in
  match expr_or_spread with
  | Ast.Expression.Expression expr -> expression_with_parens ~opts ~precedence ~ctxt expr
  | Ast.Expression.Spread spread -> spread_element ~opts ~precedence ~ctxt spread

and array_element ~ctxt ~opts element =
  let open Ast.Expression.Array in
  let precedence = min_precedence in
  match element with
  | Hole _ -> Empty
  | Expression expr -> expression_with_parens ~opts ~precedence ~ctxt expr
  | Spread spread -> spread_element ~opts ~precedence ~ctxt spread

and identifier (loc, { Ast.Identifier.name; comments }) = identifier_with_comments loc name comments

and number_literal ~opts loc { Ast.NumberLiteral.value; raw; comments } =
  let node =
    if opts.preserve_formatting then
      Atom raw
    else
      let str = Dtoa.shortest_string_of_float value in
      if String.equal raw str then
        Atom raw
      else
        IfPretty (Atom raw, Atom str)
  in
  layout_node_with_comments_opt loc comments node

and number_literal_member ~opts loc { Ast.NumberLiteral.raw; value; comments } =
  let node =
    if opts.preserve_formatting then
      Atom raw
    else
      let str = Dtoa.shortest_string_of_float value in
      (* `1.foo` is a syntax error, but `1.0.foo`, `1e0.foo` and even `1..foo` are all ok. *)
      let is_int x = not (String.contains x '.' || String.contains x 'e') in
      let if_pretty =
        if is_int raw then
          wrap_in_parens (Atom raw)
        else
          Atom raw
      in
      let if_ugly =
        if is_int str then
          fuse [Atom str; Atom "."]
        else
          Atom str
      in
      if if_pretty = if_ugly then
        if_pretty
      else
        IfPretty (if_pretty, if_ugly)
  in
  layout_node_with_comments_opt loc comments node

and string_literal ~opts loc { Ast.StringLiteral.value; raw; comments } =
  let node =
    if opts.preserve_formatting then
      Atom raw
    else
      let quote = better_quote ~prefer_single_quotes:opts.single_quotes value in
      fuse [Atom quote; Atom (utf8_escape ~quote value); Atom quote]
  in
  layout_node_with_comments_opt loc comments node

and bigint_literal loc { Ast.BigIntLiteral.value = _; raw; comments } =
  layout_node_with_comments_opt loc comments (Atom raw)

and boolean_literal loc { Ast.BooleanLiteral.value; comments } =
  let value =
    if value then
      "true"
    else
      "false"
  in
  layout_node_with_comments_opt loc comments (Atom value)

and regexp_literal ~opts loc { Ast.RegExpLiteral.pattern; flags; raw; comments; _ } =
  let node =
    if opts.preserve_formatting then
      Atom raw
    else
      let flags = flags |> String_utils.to_list |> List.sort Char.compare |> String_utils.of_list in
      fuse [Atom "/"; Atom pattern; Atom "/"; Atom flags]
  in
  layout_node_with_comments_opt loc comments node

and module_ref_literal loc { Ast.ModuleRefLiteral.raw; comments; _ } =
  layout_node_with_comments_opt loc comments (Atom raw)

and null_literal loc comments = layout_node_with_comments_opt loc comments (Atom "null")

and member
    ?(optional = Ast.Expression.OptionalMember.NonOptional) ~opts ~precedence ~ctxt member_node loc
    =
  let { Ast.Expression.Member._object; property; comments } = member_node in
  let (computed, property_loc) =
    match property with
    | Ast.Expression.Member.PropertyExpression (loc, _) -> (true, loc)
    | Ast.Expression.Member.PropertyIdentifier (loc, _)
    | Ast.Expression.Member.PropertyPrivateName (loc, _) ->
      (false, loc)
  in
  let (ldelim, rdelim) =
    match (computed, optional) with
    | (false, Ast.Expression.OptionalMember.NonOptional) -> (Atom ".", Empty)
    | (false, Ast.Expression.OptionalMember.Optional) -> (Atom "?.", Empty)
    | (false, Ast.Expression.OptionalMember.AssertNonnull) -> (Atom "!.", Empty)
    | (true, Ast.Expression.OptionalMember.NonOptional) -> (Atom "[", Atom "]")
    | (true, Ast.Expression.OptionalMember.Optional) -> (Atom "?.[", Atom "]")
    | (true, Ast.Expression.OptionalMember.AssertNonnull) -> (Atom "![", Atom "]")
  in
  let property_layout =
    match property with
    | Ast.Expression.Member.PropertyIdentifier (loc, { Ast.Identifier.name = id; comments }) ->
      source_location_with_comments ?comments (loc, Atom id)
    | Ast.Expression.Member.PropertyPrivateName (loc, { Ast.PrivateName.name = id; comments }) ->
      source_location_with_comments ?comments (loc, Atom ("#" ^ id))
    | Ast.Expression.Member.PropertyExpression expr -> expression ~ctxt ~opts expr
  in
  (* If this is a computed property with leading comments we must break and indent so that
     comments begin on the line after the left delimiter. *)
  let (leading_property, _) =
    Comment_attachment.member_property_comment_bounds property_loc property
  in
  let property_layout_with_delims =
    if computed && leading_property <> None then
      group [wrap_and_indent ?break:(Some pretty_hardline) (ldelim, rdelim) [property_layout]]
    else
      fuse [ldelim; property_layout; rdelim]
  in
  layout_node_with_comments_opt loc comments
  @@ fuse
       [
         begin
           match _object with
           | (_, Ast.Expression.Call _) -> expression ~ctxt ~opts _object
           | (loc, Ast.Expression.NumberLiteral lit) when not computed ->
             (* 1.foo would be confused with a decimal point, so it needs parens *)
             number_literal_member ~opts loc lit
           | _ -> expression_with_parens ~opts ~precedence ~ctxt _object
         end;
         (* If this is a non-computed member expression where the object has a trailing block
            comment on a line before the property, insert a line break after the comment so that
            the dot and property are printed on the line below the comment. *)
         begin
           match Comment_attachment.expression_comment_bounds _object with
           | (_, Some (comment_loc, { Ast.Comment.kind = Ast.Comment.Block; _ }))
             when (not computed) && Loc.(comment_loc._end.line < property_loc.start.line) ->
             pretty_hardline
           | _ -> Empty
         end;
         property_layout_with_delims;
       ]

and type_cast ~opts loc cast =
  let { Ast.Expression.TypeCast.expression = expr; annot; comments } = cast in
  let expr_layout = expression ~opts expr in
  (* Work around Babel bug present in current version of Babel (7.10) where arrow functions with
     type params in type casts are a parse error. Wrapping the arrow function in parens fixes this.
     Babel issue: https://github.com/babel/babel/issues/11716 *)
  let expr_layout =
    match expr with
    | (_, Ast.Expression.ArrowFunction { Ast.Function.tparams = Some _; _ }) ->
      wrap_in_parens expr_layout
    | _ -> expr_layout
  in
  layout_node_with_comments_opt loc comments
  @@ wrap_in_parens (fuse [expr_layout; type_annotation ~opts annot])

and as_const_expression ~ctxt ~opts ~precedence loc cast =
  let open Ast.Expression.AsConstExpression in
  let { expression = expr; comments } = cast in
  let expr_layout = expression_with_parens ~ctxt ~opts ~precedence expr in
  let rhs = [Atom "as"; space; Atom "const"] in
  layout_node_with_comments_opt loc comments @@ fuse [expr_layout; space; fuse rhs]

and as_expression ~ctxt ~opts ~precedence loc cast =
  let open Ast.Expression.AsExpression in
  let { expression = expr; annot = (_, annot); comments } = cast in
  layout_node_with_comments_opt loc comments
  @@ fuse
       [
         expression_with_parens ~ctxt ~opts ~precedence expr;
         space;
         Atom "as";
         space;
         type_ ~opts annot;
       ]

and ts_satisfies ~opts loc cast =
  let open Ast.Expression.TSSatisfies in
  let { expression = expr; annot = (_, annot); comments } = cast in
  let expr_layout = expression ~opts expr in
  let rhs = [Atom "satisfies"; space; type_ ~opts annot] in
  layout_node_with_comments_opt loc comments @@ fuse [expr_layout; space; fuse rhs]

and pattern_object_property_key ~opts =
  let open Ast.Pattern.Object in
  function
  | Property.StringLiteral (loc, lit) -> string_literal ~opts loc lit
  | Property.NumberLiteral (loc, lit) -> number_literal ~opts loc lit
  | Property.BigIntLiteral (loc, lit) -> bigint_literal loc lit
  | Property.Identifier ident -> identifier ident
  | Property.Computed (loc, { Ast.ComputedKey.expression = expr; comments }) ->
    layout_node_with_comments_opt loc comments
    @@ fuse
         [
           Atom "[";
           Sequence ({ seq with break = Break_if_needed }, [expression ~opts expr]);
           Atom "]";
         ]

and rest_element ~opts loc { Ast.Pattern.RestElement.argument; comments } =
  source_location_with_comments ?comments (loc, fuse [Atom "..."; pattern ~opts argument])

and pattern_array_element ~opts =
  let open Ast.Pattern.Array in
  function
  | Hole _ -> Empty
  | Element (loc, { Element.argument; default }) ->
    let elem = pattern ~opts argument in
    let elem =
      match default with
      | Some expr -> fuse_with_default ~opts elem expr
      | None -> elem
    in
    source_location_with_comments (loc, elem)
  | RestElement (loc, rest) -> rest_element ~opts loc rest

and pattern ?(ctxt = normal_context) ~opts ((loc, pat) : (Loc.t, Loc.t) Ast.Pattern.t) =
  let module P = Ast.Pattern in
  source_location_with_comments
    ( loc,
      match pat with
      | P.Object { P.Object.properties; annot; comments } ->
        let props =
          List.map
            (fun property ->
              match property with
              | P.Object.Property (loc, { P.Object.Property.key; pattern = pat; default; shorthand })
                ->
                let prop = pattern_object_property_key ~opts key in
                let prop =
                  match shorthand with
                  | false -> fuse [prop; Atom ":"; pretty_space; pattern ~opts pat]
                  | true -> prop
                in
                let prop =
                  match default with
                  | Some expr -> fuse_with_default ~opts prop expr
                  | None -> prop
                in
                let prop_layout = source_location_with_comments (loc, prop) in
                let comment_bounds =
                  Comment_attachment.object_pattern_property_comment_bounds loc property
                in
                (loc, comment_bounds, prop_layout)
              | P.Object.RestElement (loc, el) ->
                let prop_layout = rest_element ~opts loc el in
                let comment_bounds =
                  Comment_attachment.object_pattern_property_comment_bounds loc property
                in
                (loc, comment_bounds, prop_layout))
            properties
        in
        let props_layout = list_with_newlines ~sep:(Atom ",") ~sep_linebreak:pretty_line props in
        (* Add internal comments *)
        let props_layout = list_add_internal_comments props props_layout comments in
        layout_node_with_comments_opt loc comments
        @@ group
             [wrap_and_indent (Atom "{", Atom "}") props_layout; hint (type_annotation ~opts) annot]
      | P.Array { P.Array.elements; annot; comments } ->
        let element_loc = function
          | P.Array.Hole loc -> loc
          | P.Array.Element (loc, _) -> loc
          | P.Array.RestElement (loc, _) -> loc
        in
        let elements =
          List.map
            (fun element ->
              let loc = element_loc element in
              ( loc,
                Comment_attachment.array_pattern_element_comment_bounds loc element,
                pattern_array_element ~opts element
              ))
            elements
        in
        let elements_layout =
          list_with_newlines ~sep:(Atom ",") ~sep_linebreak:pretty_line ~skip_empty:false elements
        in
        let elements_layout = list_add_internal_comments elements elements_layout comments in
        layout_node_with_comments_opt loc comments
        @@ group
             [
               wrap_and_indent (Atom "[", Atom "]") elements_layout;
               hint (type_annotation ~opts) annot;
             ]
      | P.Identifier { P.Identifier.name; annot; optional } ->
        fuse
          [
            identifier name;
            ( if optional then
              Atom "?"
            else
              Empty
            );
            hint (type_annotation ~opts) annot;
          ]
      | P.Expression expr -> expression ~ctxt ~opts expr
    )

and fuse_with_default ?(ctxt = normal_context) ~opts node expr =
  fuse
    [
      node;
      pretty_space;
      Atom "=";
      pretty_space;
      expression_with_parens
        ~precedence:precedence_of_assignment
        ~ctxt:(context_after_token ctxt)
        ~opts
        expr;
    ]

and template_literal ~opts { Ast.Expression.TemplateLiteral.quasis; expressions; comments = _ } =
  let module T = Ast.Expression.TemplateLiteral in
  let template_element i (loc, { T.Element.value = { T.Element.raw; _ }; tail }) =
    fuse
      [
        source_location_with_comments
          ( loc,
            fuse
              [
                ( if i > 0 then
                  Atom "}"
                else
                  Empty
                );
                Atom raw;
                ( if not tail then
                  Atom "${"
                else
                  Empty
                );
              ]
          );
        ( if not tail then
          expression ~opts (List.nth expressions i)
        else
          Empty
        );
      ]
  in
  fuse [Atom "`"; fuse (List.mapi template_element quasis); Atom "`"]

and variable_kind kind = Atom (Flow_ast_utils.string_of_variable_kind kind)

and variable_declaration
    ?(ctxt = normal_context)
    ?(semicolon = Empty)
    ~opts
    (loc, { Ast.Statement.VariableDeclaration.declarations; kind; comments }) =
  let has_init =
    List.exists
      (fun var ->
        let open Ast.Statement.VariableDeclaration.Declarator in
        match var with
        | (_, { id = _; init = Some _ }) -> true
        | _ -> false)
      declarations
  in
  let sep =
    if has_init then
      pretty_hardline
    else
      pretty_line
  in
  let decls_layout =
    match declarations with
    | [] -> Empty (* impossible *)
    | [single_decl] -> variable_declarator ~ctxt ~opts single_decl
    | hd :: tl ->
      let hd = variable_declarator ~ctxt ~opts hd in
      let tl = Base.List.map ~f:(variable_declarator ~ctxt ~opts) tl in
      group [hd; Atom ","; Indent (fuse [sep; join (fuse [Atom ","; sep]) tl])]
  in
  source_location_with_comments
    ?comments
    (loc, fuse [fuse_with_space [variable_kind kind; decls_layout]; semicolon])

and variable_declarator ~ctxt ~opts (loc, { Ast.Statement.VariableDeclaration.Declarator.id; init })
    =
  source_location_with_comments
    ( loc,
      match init with
      | Some expr ->
        let init_separator =
          comment_aware_separator
            ~no_comment:pretty_space
            (Comment_attachment.expression_comment_bounds expr)
        in
        fuse
          [
            pattern ~ctxt ~opts id;
            pretty_space;
            Atom "=";
            init_separator;
            expression_with_parens ~opts ~precedence:precedence_of_assignment ~ctxt expr;
          ]
      | None -> pattern ~ctxt ~opts id
    )

and arrow_function
    ?(ctxt = normal_context)
    ~opts
    loc
    {
      Ast.Function.params =
        (params_loc, { Ast.Function.Params.comments = params_comments; _ }) as params;
      body;
      async;
      predicate;
      return;
      tparams;
      comments;
      generator = _;
      effect_ = _;
      id = _;
      (* arrows don't have ids and can't be generators *) sig_loc = _;
    } =
  let is_single_simple_param =
    match params with
    | ( _,
        {
          Ast.Function.Params.params =
            [
              ( _,
                {
                  Ast.Function.Param.argument =
                    ( _,
                      Ast.Pattern.Identifier
                        {
                          Ast.Pattern.Identifier.optional = false;
                          annot = Ast.Type.Missing _;
                          name = (id_loc, { Ast.Identifier.comments = id_comments; _ });
                        }
                    );
                  default = None;
                }
              );
            ];
          rest = None;
          this_ = None;
          (* We must wrap the single param in parentheses if there are internal comments *)
          comments = None | Some { Ast.Syntax.internal = []; _ };
        }
      ) ->
      (* We must wrap the single param in parentheses if it has any attached comments on
         the same line as the param. *)
      (match id_comments with
      | None -> true
      | Some { Ast.Syntax.leading; trailing; _ } ->
        let on_same_line comments =
          List.exists (fun (loc, _) -> Loc.lines_intersect loc id_loc) comments
        in
        (not (on_same_line leading)) && not (on_same_line trailing))
    | _ -> false
  in
  let params_and_stuff =
    match (is_single_simple_param, return, predicate, tparams) with
    | (true, Ast.Function.ReturnAnnot.Missing _, None, None) ->
      let (_, { Ast.Function.Params.params; _ }) = params in
      layout_node_with_comments_opt
        params_loc
        params_comments
        (function_param ~ctxt ~opts (List.hd params))
    | (_, _, _, _) ->
      let params =
        layout_node_with_comments_opt params_loc params_comments (function_params ~ctxt ~opts params)
      in
      fuse
        [
          option (type_parameter ~opts ~kind:Flow_ast_mapper.FunctionTP) tparams;
          group [params; function_return ~opts ~arrow:true return predicate];
        ]
  in
  let body_separator =
    comment_aware_separator
      ~no_comment:pretty_space
      (Comment_attachment.function_body_comment_bounds body)
  in
  layout_node_with_comments_opt loc comments
  @@ fuse
       [
         fuse_with_space
           [
             ( if async then
               Atom "async"
             else
               Empty
             );
             params_and_stuff;
           ];
         (* Babylon does not parse ():*=>{}` because it thinks the `*=` is an
            unexpected multiply-and-assign operator. Thus, we format this with a
            space e.g. `():* =>{}`. *)
         begin
           match return with
           | Ast.Function.ReturnAnnot.Available (_, (_, Ast.Type.Exists _)) -> space
           | _ -> pretty_space
         end;
         Atom "=>";
         body_separator;
         begin
           match body with
           | Ast.Function.BodyBlock b -> block ~opts b
           | Ast.Function.BodyExpression expr ->
             let ctxt = { normal_context with group = In_arrow_func } in
             (* BodyExpression is an AssignmentExpression *)
             let precedence = precedence_of_assignment in
             expression_with_parens ~precedence ~ctxt ~opts expr
         end;
       ]

and function_ ~opts loc func =
  let {
    Ast.Function.id;
    params;
    body;
    async;
    generator;
    effect_;
    predicate;
    return;
    tparams;
    sig_loc = _;
    comments;
  } =
    func
  in
  let prefix =
    let s_func =
      fuse
        [
          ( if effect_ = Ast.Function.Hook then
            Atom "hook"
          else
            Atom "function"
          );
          ( if generator then
            Atom "*"
          else
            Empty
          );
        ]
    in
    let id =
      match id with
      | Some id -> fuse [s_func; space; identifier id]
      | None -> s_func
    in
    if async then
      fuse [Atom "async"; space; id]
    else
      id
  in
  function_base ~opts ~prefix ~params ~body:(Some body) ~predicate ~return ~tparams ~loc ~comments

and function_base ~opts ~prefix ~params ~body ~predicate ~return ~tparams ~loc ~comments =
  let (params_loc, { Ast.Function.Params.comments = params_comments; _ }) = params in
  layout_node_with_comments_opt loc comments
  @@ fuse
       [
         prefix;
         option (type_parameter ~opts ~kind:Flow_ast_mapper.FunctionTP) tparams;
         group
           [
             layout_node_with_comments_opt
               params_loc
               params_comments
               (function_params ~ctxt:normal_context ~opts params);
             function_return ~opts ~arrow:false return predicate;
           ];
         pretty_space;
         option
           (function
             | Ast.Function.BodyBlock b -> block ~opts b
             | Ast.Function.BodyExpression _ -> failwith "Only arrows should have BodyExpressions")
           body;
       ]

and function_param ~ctxt ~opts (loc, { Ast.Function.Param.argument; default }) : Layout.layout_node
    =
  let node = pattern ~ctxt ~opts argument in
  let node =
    match default with
    | Some expr -> fuse_with_default ~opts node expr
    | None -> node
  in
  source_location_with_comments (loc, node)

and function_params_and_return
    ~opts (loc, { Ast.Function.params; predicate; return; tparams; comments; _ }) =
  source_location_with_comments
    ?comments
    ( loc,
      function_base
        ~opts
        ~prefix:Empty
        ~params
        ~body:None
        ~predicate
        ~return
        ~tparams
        ~loc
        ~comments
    )

and list_add_internal_comments list list_layout comments =
  match internal_comments comments with
  | None -> list_layout
  | Some (comments_loc, _, comments_layout) ->
    (match List.rev list with
    | [] -> list_layout @ [comments_layout]
    | (last_item_loc, _, _) :: _ ->
      (* Preserve newlines between internal comments and last item in the list *)
      if is_single_linebreak last_item_loc comments_loc then
        list_layout @ [pretty_hardline; comments_layout]
      else if is_multi_linebreak last_item_loc comments_loc then
        list_layout @ [pretty_hardline; pretty_hardline; comments_layout]
      else
        list_layout @ [comments_layout])

and function_params
    ?(ctxt = normal_context) ~opts (_, { Ast.Function.Params.params; rest; comments; this_ }) =
  let params =
    Base.List.map
      ~f:(fun ((loc, _) as param) ->
        ( loc,
          Comment_attachment.function_param_comment_bounds param,
          function_param ~ctxt ~opts param
        ))
      params
  in
  (* Add rest param *)
  let params =
    match rest with
    | Some ((loc, { Ast.Function.RestParam.argument; comments }) as rest) ->
      let rest_layout =
        source_location_with_comments
          ?comments
          (loc, fuse [Atom "..."; pattern ~ctxt ~opts argument])
      in
      let rest_param =
        (loc, Comment_attachment.function_rest_param_comment_bounds rest, rest_layout)
      in
      params @ [rest_param]
    | None -> params
  in
  (* Add this param *)
  let params =
    match this_ with
    | None -> params
    | Some ((loc, { Ast.Function.ThisParam.annot; comments }) as param) ->
      let this_layout =
        source_location_with_comments
          ?comments
          (loc, fuse [Atom "this"; type_annotation ~opts annot])
      in
      let this_param =
        (loc, Comment_attachment.function_this_param_comment_bounds param, this_layout)
      in
      this_param :: params
  in
  let params_layout = list_with_newlines ~sep:(Atom ",") ~sep_linebreak:pretty_line params in
  (* Add trailing comma *)
  let params_layout =
    if
      params <> []
      && rest = None
      && Trailing_commas.enabled_for_function_params opts.trailing_commas
    then
      params_layout @ [if_break (Atom ",") Empty]
    else
      params_layout
  in
  let params_layout = list_add_internal_comments params params_layout comments in
  wrap_and_indent (Atom "(", Atom ")") params_layout

and function_return ~opts ~arrow return predicate =
  (* Function return types in arrow functions must be wrapped in parens or else arrow
     from arrow function is interpreted as part of the function type. *)
  let needs_parens = function
    | ( _,
        ( _,
          Ast.Type.Function
            { Ast.Type.Function.params = (_, { Ast.Type.Function.Params.params = _ :: _; _ }); _ }
        )
      )
      when arrow ->
      true
    | _ -> false
  in
  match (return, predicate) with
  | (Ast.Function.ReturnAnnot.Missing _, None) -> Empty
  | (Ast.Function.ReturnAnnot.Missing _, Some pred) ->
    fuse [Atom ":"; pretty_space; type_predicate ~opts pred]
  | (Ast.Function.ReturnAnnot.Available ret, Some pred) ->
    fuse
      [
        type_annotation ~opts ~parens:(needs_parens ret) ret; pretty_space; type_predicate ~opts pred;
      ]
  | (Ast.Function.ReturnAnnot.Available ret, None) ->
    type_annotation ~opts ~parens:(needs_parens ret) ret
  | (Ast.Function.ReturnAnnot.TypeGuard ((_, (_, { Ast.Type.TypeGuard.guard = t; _ })) as guard), _)
    ->
    let needs_parens =
      match t with
      | (loc, Some t) -> needs_parens (loc, t)
      | (_, None) -> false
    in
    type_guard_annotation ~opts ~needs_parens guard

and block ~opts (loc, { Ast.Statement.Block.body; comments }) =
  let statements = statement_list ~opts ~pretty_semicolon:true body in
  source_location_with_comments
    ?comments
    ( loc,
      if statements <> [] then
        group [wrap_and_indent ~break:pretty_hardline (Atom "{", Atom "}") [fuse statements]]
      else
        match internal_comments comments with
        | None -> Atom "{}"
        | Some (_, _, comments) -> fuse [Atom "{"; comments; Atom "}"]
    )

and decorators_list ~opts decorators =
  if List.length decorators > 0 then
    let decorators =
      List.map
        (fun (loc, { Ast.Class.Decorator.expression = expr; comments }) ->
          source_location_with_comments
            ?comments
            ( loc,
              fuse
                [
                  Atom "@";
                  begin
                    (* Magic number, after `Call` but before `Update` *)
                    let precedence = 18 in
                    expression_with_parens ~precedence ~ctxt:normal_context ~opts expr
                  end;
                ]
            ))
        decorators
    in
    group [join pretty_line decorators; if_pretty hardline space]
  else
    Empty

and component_declaration ~opts loc component =
  let {
    Ast.Statement.ComponentDeclaration.id;
    params;
    body;
    renders;
    tparams;
    comments;
    sig_loc = _;
  } =
    component
  in
  let prefix = fuse [Atom "component"; space; identifier id] in
  component_base ~opts ~prefix ~params ~body ~renders ~tparams ~loc ~comments

and component_base ~opts ~prefix ~params ~body ~renders ~tparams ~loc ~comments =
  let (params_loc, { Ast.Statement.ComponentDeclaration.Params.comments = params_comments; _ }) =
    params
  in
  layout_node_with_comments_opt loc comments
  @@ fuse
       [
         prefix;
         option (type_parameter ~opts ~kind:Flow_ast_mapper.ComponentDeclarationTP) tparams;
         group
           [
             layout_node_with_comments_opt
               params_loc
               params_comments
               (component_params ~ctxt:normal_context ~opts params);
             component_renders ~opts renders;
           ];
         pretty_space;
         block ~opts body;
       ]

and component_params
    ?(ctxt = normal_context)
    ~opts
    (_, { Ast.Statement.ComponentDeclaration.Params.params; rest; comments }) =
  let params =
    Base.List.map
      ~f:(fun ((loc, _) as param) ->
        ( loc,
          Comment_attachment.component_param_comment_bounds param,
          component_param ~ctxt ~opts param
        ))
      params
  in
  (* Add rest param *)
  let params =
    match rest with
    | Some ((loc, { Ast.Statement.ComponentDeclaration.RestParam.argument; comments }) as rest) ->
      let rest_layout =
        source_location_with_comments
          ?comments
          (loc, fuse [Atom "..."; pattern ~ctxt ~opts argument])
      in
      let rest_param =
        (loc, Comment_attachment.component_rest_param_comment_bounds rest, rest_layout)
      in
      params @ [rest_param]
    | None -> params
  in
  let params_layout = list_with_newlines ~sep:(Atom ",") ~sep_linebreak:pretty_line params in
  (* Add trailing comma *)
  let params_layout =
    if
      params <> []
      && rest = None
      && Trailing_commas.enabled_for_function_params opts.trailing_commas
    then
      params_layout @ [if_break (Atom ",") Empty]
    else
      params_layout
  in
  let params_layout = list_add_internal_comments params params_layout comments in
  wrap_and_indent (Atom "(", Atom ")") params_layout

and component_param
    ~ctxt ~opts (loc, { Ast.Statement.ComponentDeclaration.Param.name; local; default; shorthand })
    =
  let local_node = pattern ~ctxt ~opts local in
  let node =
    match shorthand with
    | true -> local_node
    | false ->
      let name_node = component_param_name ~opts name in
      fuse [name_node; space; Atom "as"; space; local_node]
  in
  let node =
    match default with
    | Some expr -> fuse_with_default ~opts node expr
    | None -> node
  in
  source_location_with_comments (loc, node)

and component_param_name ~opts = function
  | Ast.Statement.ComponentDeclaration.Param.Identifier name -> identifier name
  | Ast.Statement.ComponentDeclaration.Param.StringLiteral (loc, lit) ->
    string_literal ~opts loc lit

and component_renders ~opts return =
  match return with
  | Ast.Type.MissingRenders _ -> Empty
  | Ast.Type.AvailableRenders (loc, renders) ->
    source_location_with_comments (loc, fuse [space; render_type ~opts loc renders])

and class_method
    ~opts
    (loc, { Ast.Class.Method.kind; key; value = (func_loc, func); static; decorators; comments }) =
  let module M = Ast.Class.Method in
  let {
    Ast.Function.params;
    body;
    async;
    generator;
    effect_ = _;
    predicate;
    return;
    tparams;
    id = _;
    (* methods don't use id; see `key` *) sig_loc = _;
    comments = func_comments;
  } =
    func
  in
  source_location_with_comments
    ?comments
    ( loc,
      let s_key =
        match key with
        | Ast.Expression.Object.Property.PrivateName
            (ident_loc, { Ast.PrivateName.name; comments = key_comments }) ->
          layout_node_with_comments_opt
            ident_loc
            key_comments
            (identifier (Flow_ast_utils.ident_of_source (ident_loc, "#" ^ name)))
        | _ -> object_property_key ~opts key
      in
      let s_key =
        if generator then
          fuse [Atom "*"; s_key]
        else
          s_key
      in
      let s_kind =
        match kind with
        | M.Constructor
        | M.Method ->
          Empty
        | M.Get -> Atom "get"
        | M.Set -> Atom "set"
      in
      (* TODO: getters/setters/constructors will never be async *)
      let s_async =
        if async then
          Atom "async"
        else
          Empty
      in
      let prefix = fuse_with_space [s_async; s_kind; s_key] in
      fuse
        [
          decorators_list ~opts decorators;
          ( if static then
            fuse [Atom "static"; space]
          else
            Empty
          );
          source_location_with_comments
            ( func_loc,
              function_base
                ~opts
                ~prefix
                ~params
                ~body:(Some body)
                ~predicate
                ~return
                ~tparams
                ~loc:func_loc
                ~comments:func_comments
            );
        ]
    )

and class_property_helper ~opts loc key value static annot variance_ decorators comments =
  let (declare, value) =
    match value with
    | Ast.Class.Property.Declared -> (true, None)
    | Ast.Class.Property.Uninitialized -> (false, None)
    | Ast.Class.Property.Initialized expr -> (false, Some expr)
  in
  source_location_with_comments
    ?comments
    ( loc,
      with_semicolon
        (fuse
           [
             decorators_list ~opts decorators;
             ( if declare then
               fuse [Atom "declare"; space]
             else
               Empty
             );
             ( if static then
               fuse [Atom "static"; space]
             else
               Empty
             );
             option variance variance_;
             key;
             hint (type_annotation ~opts) annot;
             begin
               match value with
               | Some v ->
                 fuse
                   [
                     pretty_space;
                     Atom "=";
                     pretty_space;
                     expression_with_parens ~precedence:min_precedence ~ctxt:normal_context ~opts v;
                   ]
               | None -> Empty
             end;
           ]
        )
    )

and class_property
    ~opts (loc, { Ast.Class.Property.key; value; static; annot; variance; decorators; comments }) =
  class_property_helper
    ~opts
    loc
    (object_property_key ~opts key)
    value
    static
    annot
    variance
    decorators
    comments

and class_private_field
    ~opts
    ( loc,
      {
        Ast.Class.PrivateField.key = (ident_loc, { Ast.PrivateName.name; comments = key_comments });
        value;
        static;
        annot;
        variance;
        decorators;
        comments;
      }
    ) =
  let key =
    layout_node_with_comments_opt
      ident_loc
      key_comments
      (identifier (Flow_ast_utils.ident_of_source (ident_loc, "#" ^ name)))
  in
  class_property_helper ~opts loc key value static annot variance decorators comments

and class_static_block ~opts (loc, { Ast.Class.StaticBlock.body; comments }) =
  let statements = statement_list ~opts ~pretty_semicolon:true body in
  source_location_with_comments
    ?comments
    ( loc,
      if statements <> [] then
        let body =
          group [wrap_and_indent ~break:pretty_hardline (Atom "{", Atom "}") [fuse statements]]
        in
        fuse [Atom "static"; pretty_space; body]
      else
        match internal_comments comments with
        | None -> fuse [Atom "static"; pretty_space; Atom "{}"]
        | Some (_, _, comments) -> fuse [Atom "static"; pretty_space; Atom "{"; comments; Atom "}"]
    )

and class_body ~opts (loc, { Ast.Class.Body.body; comments }) =
  let elements =
    Base.List.map
      ~f:
        (let open Comment_attachment in
        function
        | Ast.Class.Body.Method ((loc, _) as meth) ->
          let comment_bounds =
            comment_bounds loc meth (fun collector (loc, meth) -> collector#class_method loc meth)
          in
          (loc, comment_bounds, class_method ~opts meth)
        | Ast.Class.Body.Property ((loc, _) as prop) ->
          let comment_bounds =
            comment_bounds loc prop (fun collector (loc, prop) -> collector#class_property loc prop)
          in
          (loc, comment_bounds, class_property ~opts prop)
        | Ast.Class.Body.PrivateField ((loc, _) as field) ->
          let comment_bounds =
            comment_bounds loc field (fun collector (loc, field) ->
                collector#class_private_field loc field
            )
          in
          (loc, comment_bounds, class_private_field ~opts field)
        | Ast.Class.Body.StaticBlock ((loc, _) as block) ->
          let comment_bounds =
            comment_bounds loc block (fun collector (loc, block) ->
                collector#class_static_block loc block
            )
          in
          (loc, comment_bounds, class_static_block ~opts block)
        )
      body
    |> list_with_newlines
  in
  if body <> [] then
    source_location_with_comments
      ?comments
      (loc, group [wrap_and_indent ~break:pretty_hardline (Atom "{", Atom "}") [fuse elements]])
  else
    source_location_with_comments ?comments (loc, Atom "{}")

and class_implements ~opts implements =
  match implements with
  | None -> None
  | Some (loc, { Ast.Class.Implements.interfaces; comments }) ->
    Some
      (source_location_with_comments
         ?comments
         ( loc,
           fuse
             [
               Atom "implements";
               space;
               fuse_list
                 ~sep:(Atom ",")
                 (List.map
                    (fun (loc, { Ast.Class.Implements.Interface.id; targs }) ->
                      source_location_with_comments
                        (loc, fuse [identifier id; option (type_args ~opts) targs]))
                    interfaces
                 );
             ]
         )
      )

and class_base
    ~opts loc { Ast.Class.id; body; tparams; extends; implements; class_decorators; comments } =
  let decorator_parts = decorators_list ~opts class_decorators in
  let class_parts =
    [
      Atom "class";
      begin
        match id with
        | Some ident ->
          fuse
            [
              space;
              identifier ident;
              option (type_parameter ~opts ~kind:Flow_ast_mapper.ClassTP) tparams;
            ]
        | None -> Empty
      end;
    ]
  in
  let extends_parts =
    let class_extends =
      [
        begin
          match extends with
          | Some (loc, { Ast.Class.Extends.expr; targs; comments }) ->
            Some
              (source_location_with_comments
                 ?comments
                 ( loc,
                   fuse
                     [
                       Atom "extends";
                       space;
                       source_location_with_comments
                         (loc, fuse [expression ~opts expr; option (type_args ~opts) targs]);
                     ]
                 )
              )
          | None -> None
        end;
        class_implements ~opts implements;
      ]
    in
    match deoptionalize class_extends with
    | [] -> []
    | items -> [Layout.Indent (fuse [line; join line items])]
  in
  let parts =
    []
    |> List.rev_append class_parts
    |> List.rev_append extends_parts
    |> List.cons pretty_space
    |> List.cons (class_body ~opts body)
    |> List.rev
  in
  group [decorator_parts; source_location_with_comments ?comments (loc, group parts)]

and enum_declaration ~def loc { Ast.Statement.EnumDeclaration.id; body; comments } =
  let open Ast.Statement.EnumDeclaration in
  let representation_type name explicit =
    if explicit then
      fuse [space; Atom "of"; space; Atom name]
    else
      Empty
  in
  let wrap_body members =
    wrap_and_indent ~break:pretty_hardline (Atom "{", Atom "}") [join pretty_hardline members]
  in
  let defaulted_member (_, { DefaultedMember.id }) = fuse [identifier id; Atom ","] in
  let initialized_member id value =
    fuse [identifier id; pretty_space; Atom "="; pretty_space; value; Atom ","]
  in
  let boolean_member
      ( _,
        { InitializedMember.id; init = (loc, { Ast.BooleanLiteral.value = init_value; comments }) }
      ) =
    initialized_member
      id
      (layout_node_with_comments_opt
         loc
         comments
         ( if init_value then
           Atom "true"
         else
           Atom "false"
         )
      )
  in
  let number_member
      (_, { InitializedMember.id; init = (loc, { Ast.NumberLiteral.raw; comments; _ }) }) =
    initialized_member id (layout_node_with_comments_opt loc comments (Atom raw))
  in
  let string_member
      (_, { InitializedMember.id; init = (loc, { Ast.StringLiteral.raw; comments; _ }) }) =
    initialized_member id (layout_node_with_comments_opt loc comments (Atom raw))
  in
  let bigint_member
      (_, { InitializedMember.id; init = (loc, { Ast.BigIntLiteral.raw; comments; _ }) }) =
    initialized_member id (layout_node_with_comments_opt loc comments (Atom raw))
  in
  let unknown_members has_unknown_members =
    if has_unknown_members then
      [Atom "..."]
    else
      []
  in
  let enum_internal_comments comments =
    Base.Option.value_map
      ~default:[]
      ~f:(fun (_, _, layout) -> [layout])
      (internal_comments comments)
  in
  let body =
    match body with
    | (loc, BooleanBody { BooleanBody.members; explicit_type; has_unknown_members; comments }) ->
      fuse
        [
          representation_type "boolean" explicit_type;
          pretty_space;
          layout_node_with_comments_opt loc comments
          @@ wrap_body
          @@ Base.List.map ~f:boolean_member members
          @ enum_internal_comments comments
          @ unknown_members has_unknown_members;
        ]
    | (loc, NumberBody { NumberBody.members; explicit_type; has_unknown_members; comments }) ->
      fuse
        [
          representation_type "number" explicit_type;
          pretty_space;
          layout_node_with_comments_opt loc comments
          @@ wrap_body
          @@ Base.List.map ~f:number_member members
          @ enum_internal_comments comments
          @ unknown_members has_unknown_members;
        ]
    | (loc, StringBody { StringBody.members; explicit_type; has_unknown_members; comments }) ->
      fuse
        [
          representation_type "string" explicit_type;
          pretty_space;
          (layout_node_with_comments_opt loc comments
          @@ wrap_body
          @@
          match members with
          | StringBody.Defaulted members ->
            Base.List.map ~f:defaulted_member members
            @ enum_internal_comments comments
            @ unknown_members has_unknown_members
          | StringBody.Initialized members ->
            Base.List.map ~f:string_member members
            @ enum_internal_comments comments
            @ unknown_members has_unknown_members
          );
        ]
    | (loc, SymbolBody { SymbolBody.members; has_unknown_members; comments }) ->
      fuse
        [
          representation_type "symbol" true;
          pretty_space;
          layout_node_with_comments_opt loc comments
          @@ wrap_body
          @@ Base.List.map ~f:defaulted_member members
          @ enum_internal_comments comments
          @ unknown_members has_unknown_members;
        ]
    | (loc, BigIntBody { BigIntBody.members; explicit_type; has_unknown_members; comments }) ->
      fuse
        [
          representation_type "bigint" explicit_type;
          pretty_space;
          layout_node_with_comments_opt loc comments
          @@ wrap_body
          @@ Base.List.map ~f:bigint_member members
          @ enum_internal_comments comments
          @ unknown_members has_unknown_members;
        ]
  in
  layout_node_with_comments_opt loc comments (fuse [def; space; identifier id; body])

and declare_enum loc enum =
  enum_declaration ~def:(fuse [Atom "declare"; space; Atom "enum"]) loc enum

(* given a list of (loc * layout node) pairs, insert newlines between the nodes when necessary *)
and list_with_newlines
    ?(sep = Empty)
    ?(sep_linebreak = pretty_hardline)
    ?(skip_empty = true)
    (nodes :
      (Loc.t * (Loc.t Ast.Comment.t option * Loc.t Ast.Comment.t option) * Layout.layout_node) list
      ) =
  let rec helper nodes acc prev_loc =
    match nodes with
    | [] -> acc
    | (loc, (first_leading, last_trailing), node) :: rest ->
      let open Loc in
      (* Expand node's loc to include its attached comments *)
      let loc =
        Comment_attachment.expand_loc_with_comment_bounds loc (first_leading, last_trailing)
      in
      let has_trailing_line_comment =
        match last_trailing with
        | Some (_, { Ast.Comment.kind = Ast.Comment.Line; _ }) -> true
        | _ -> false
      in
      let sep =
        if rest = [] then
          Empty
        (* Line comments already end in a hard newline, so another linebreak is not needed *)
        else if has_trailing_line_comment then
          sep
        else
          fuse [sep; sep_linebreak]
      in
      let acc =
        match (prev_loc, node) with
        (* empty line, don't add anything *)
        | (_, Empty) when skip_empty -> acc
        (* Location is empty, default to no line break *)
        | (Some loc, node) when loc = Loc.none -> fuse [node; sep] :: acc
        (* Lines are offset by more than one, let's add a line break. *)
        | (Some { Loc._end; _ }, node) when _end.line + 1 < loc.start.line ->
          fuse [pretty_hardline; node; sep] :: acc
        (* Hasn't matched, just add the node *)
        | (_, node) -> fuse [node; sep] :: acc
      in
      helper rest acc (Some loc)
  in
  let nodes = helper nodes [] None in
  List.rev nodes

and statement_list ?(pretty_semicolon = false) ~opts statements =
  let rec mapper acc = function
    | [] -> List.rev acc
    | ((loc, _) as stmt) :: rest ->
      let pretty_semicolon = pretty_semicolon && rest = [] in
      let comment_bounds = Comment_attachment.statement_comment_bounds stmt in
      let acc = (loc, comment_bounds, statement ~opts ~pretty_semicolon stmt) :: acc in
      (mapper [@tailcall]) acc rest
  in
  mapper [] statements |> list_with_newlines

and object_property_key ~opts key =
  let module O = Ast.Expression.Object in
  match key with
  | O.Property.StringLiteral (loc, lit) -> string_literal ~opts loc lit
  | O.Property.NumberLiteral (loc, lit) -> number_literal ~opts loc lit
  | O.Property.BigIntLiteral (loc, lit) -> bigint_literal loc lit
  | O.Property.Identifier ident -> identifier ident
  | O.Property.Computed (loc, { Ast.ComputedKey.expression = expr; comments }) ->
    layout_node_with_comments_opt loc comments
    @@ fuse
         [
           Atom "["; Layout.Indent (fuse [pretty_line; expression ~opts expr]); pretty_line; Atom "]";
         ]
  | O.Property.PrivateName _ -> failwith "Internal Error: Found object prop with private name"

and object_property ~opts property =
  let module O = Ast.Expression.Object in
  match property with
  | O.Property (loc, O.Property.Init { key; value; shorthand }) ->
    let value_separator =
      comment_aware_separator
        ~no_comment:pretty_space
        (Comment_attachment.expression_comment_bounds value)
    in
    source_location_with_comments
      ( loc,
        let s_key = object_property_key ~opts key in
        if shorthand then
          s_key
        else
          group
            [
              s_key;
              Atom ":";
              value_separator;
              expression_with_parens ~precedence:min_precedence ~ctxt:normal_context ~opts value;
            ]
      )
  | O.Property (loc, O.Property.Method { key; value = (fn_loc, func) }) ->
    let s_key = object_property_key ~opts key in
    let {
      Ast.Function.id;
      params;
      body;
      async;
      generator;
      effect_ = _;
      predicate;
      return;
      tparams;
      sig_loc = _;
      comments = fn_comments;
    } =
      func
    in
    assert (id = None);

    (* methods don't have ids, see `key` *)
    let prefix =
      fuse
        [
          ( if async then
            fuse [Atom "async"; space]
          else
            Empty
          );
          ( if generator then
            Atom "*"
          else
            Empty
          );
          s_key;
        ]
    in
    source_location_with_comments
      ( loc,
        source_location_with_comments
          ( fn_loc,
            function_base
              ~opts
              ~prefix
              ~params
              ~body:(Some body)
              ~predicate
              ~return
              ~tparams
              ~loc:fn_loc
              ~comments:fn_comments
          )
      )
  | O.Property (loc, O.Property.Get { key; value = (fn_loc, func); comments }) ->
    let {
      Ast.Function.id;
      params;
      body;
      async;
      generator;
      effect_ = _;
      predicate;
      return;
      tparams;
      sig_loc = _;
      comments = fn_comments;
    } =
      func
    in
    assert (id = None);

    (* getters don't have ids, see `key` *)
    assert (not async);

    (* getters can't be async *)
    assert (not generator);

    (* getters can't be generators *)
    let prefix = fuse [Atom "get"; space; object_property_key ~opts key] in
    source_location_with_comments
      ?comments
      ( loc,
        source_location_with_comments
          ( fn_loc,
            function_base
              ~opts
              ~prefix
              ~params
              ~body:(Some body)
              ~predicate
              ~return
              ~tparams
              ~loc:fn_loc
              ~comments:fn_comments
          )
      )
  | O.Property (loc, O.Property.Set { key; value = (fn_loc, func); comments }) ->
    let {
      Ast.Function.id;
      params;
      body;
      async;
      generator;
      effect_ = _;
      predicate;
      return;
      tparams;
      sig_loc = _;
      comments = fn_comments;
    } =
      func
    in
    assert (id = None);

    (* setters don't have ids, see `key` *)
    assert (not async);

    (* setters can't be async *)
    assert (not generator);

    (* setters can't be generators *)
    let prefix = fuse [Atom "set"; space; object_property_key ~opts key] in
    source_location_with_comments
      ?comments
      ( loc,
        source_location_with_comments
          ( fn_loc,
            function_base
              ~opts
              ~prefix
              ~params
              ~body:(Some body)
              ~predicate
              ~return
              ~tparams
              ~loc:fn_loc
              ~comments:fn_comments
          )
      )
  | O.SpreadProperty (loc, { O.SpreadProperty.argument; comments }) ->
    source_location_with_comments ?comments (loc, fuse [Atom "..."; expression ~opts argument])

and jsx_element ~opts loc { Ast.JSX.opening_element; closing_element; children; comments } =
  layout_node_with_comments_opt loc comments
  @@ fuse
       [
         begin
           match opening_element with
           | (_, { Ast.JSX.Opening.self_closing = false; _ }) -> jsx_opening ~opts opening_element
           | (_, { Ast.JSX.Opening.self_closing = true; _ }) ->
             jsx_self_closing ~opts opening_element
         end;
         jsx_children ~opts loc children;
         begin
           match closing_element with
           | Some closing -> jsx_closing closing
           | _ -> Empty
         end;
       ]

and jsx_fragment
    ~opts loc { Ast.JSX.frag_opening_element; frag_closing_element; frag_children; frag_comments } =
  layout_node_with_comments_opt loc frag_comments
  @@ fuse
       [
         jsx_fragment_opening ~opts frag_opening_element;
         jsx_children ~opts loc frag_children;
         jsx_closing_fragment frag_closing_element;
       ]

and jsx_identifier (loc, { Ast.JSX.Identifier.name; comments }) =
  identifier_with_comments loc name comments

and jsx_namespaced_name (loc, { Ast.JSX.NamespacedName.namespace; name }) =
  source_location_with_comments (loc, fuse [jsx_identifier namespace; Atom ":"; jsx_identifier name])

and jsx_member_expression (loc, { Ast.JSX.MemberExpression._object; property }) =
  source_location_with_comments
    ( loc,
      fuse
        [
          begin
            match _object with
            | Ast.JSX.MemberExpression.Identifier ident -> jsx_identifier ident
            | Ast.JSX.MemberExpression.MemberExpression member -> jsx_member_expression member
          end;
          Atom ".";
          jsx_identifier property;
        ]
    )

and jsx_expression_container ~opts loc { Ast.JSX.ExpressionContainer.expression = expr; comments } =
  let internal_comments =
    match internal_comments comments with
    | None -> Empty
    | Some (_, _, comments) -> comments
  in
  layout_node_with_comments_opt loc comments
  @@ fuse
       [
         Atom "{";
         begin
           match expr with
           | Ast.JSX.ExpressionContainer.Expression expr -> expression ~opts expr
           | Ast.JSX.ExpressionContainer.EmptyExpression -> Empty
         end;
         internal_comments;
         Atom "}";
       ]

and jsx_spread_child ~opts loc { Ast.JSX.SpreadChild.expression = expr; comments } =
  fuse
    [
      Atom "{";
      layout_node_with_comments_opt loc comments (Atom "...");
      expression ~opts expr;
      Atom "}";
    ]

and jsx_attribute ~opts (loc, { Ast.JSX.Attribute.name; value }) =
  let module A = Ast.JSX.Attribute in
  source_location_with_comments
    ( loc,
      fuse
        [
          begin
            match name with
            | A.Identifier ident -> jsx_identifier ident
            | A.NamespacedName name -> jsx_namespaced_name name
          end;
          begin
            match value with
            | Some v ->
              fuse
                [
                  Atom "=";
                  begin
                    match v with
                    | A.StringLiteral (loc, lit) ->
                      source_location_with_comments (loc, string_literal ~opts loc lit)
                    | A.ExpressionContainer (loc, express) ->
                      source_location_with_comments (loc, jsx_expression_container ~opts loc express)
                  end;
                ]
            | None -> flat_ugly_space (* TODO we shouldn't do this for the last attr *)
          end;
        ]
    )

and jsx_spread_attribute ~opts (loc, { Ast.JSX.SpreadAttribute.argument; comments }) =
  layout_node_with_comments_opt loc comments
  @@ fuse [Atom "{"; Atom "..."; expression ~opts argument; Atom "}"]

and jsx_element_name = function
  | Ast.JSX.Identifier ident -> jsx_identifier ident
  | Ast.JSX.NamespacedName name -> jsx_namespaced_name name
  | Ast.JSX.MemberExpression member -> jsx_member_expression member

and jsx_opening_attr ~opts = function
  | Ast.JSX.Opening.Attribute attr -> jsx_attribute ~opts attr
  | Ast.JSX.Opening.SpreadAttribute attr -> jsx_spread_attribute ~opts attr

and jsx_opening ~opts (loc, { Ast.JSX.Opening.name; targs; attributes; self_closing = _ }) =
  jsx_opening_helper ~opts loc (Some name) targs attributes

and jsx_fragment_opening ~opts loc = jsx_opening_helper ~opts loc None None []

and jsx_opening_helper ~opts loc nameOpt targs attributes =
  source_location_with_comments
    ( loc,
      group
        [
          Atom "<";
          (match nameOpt with
          | Some name -> jsx_element_name name
          | None -> Empty);
          option (call_type_args ~opts ~less_than:"<") targs;
          ( if attributes <> [] then
            Layout.Indent
              (fuse [line; join pretty_line (Base.List.map ~f:(jsx_opening_attr ~opts) attributes)])
          else
            Empty
          );
          Atom ">";
        ]
    )

and jsx_self_closing ~opts (loc, { Ast.JSX.Opening.name; targs; attributes; self_closing = _ }) =
  let attributes = Base.List.map ~f:(jsx_opening_attr ~opts) attributes in
  source_location_with_comments
    ( loc,
      group
        [
          Atom "<";
          jsx_element_name name;
          option (call_type_args ~opts ~less_than:"<") targs;
          ( if attributes <> [] then
            fuse [Layout.Indent (fuse [line; join pretty_line attributes]); pretty_line]
          else
            pretty_space
          );
          Atom "/>";
        ]
    )

and jsx_closing (loc, { Ast.JSX.Closing.name }) =
  source_location_with_comments (loc, fuse [Atom "</"; jsx_element_name name; Atom ">"])

and jsx_closing_fragment loc = source_location_with_comments (loc, fuse [Atom "</>"])

and jsx_children ~opts loc (_children_loc, children) =
  Loc.(
    let processed_children = deoptionalize (Base.List.map ~f:(jsx_child ~opts) children) in
    (* Check for empty children *)
    if List.length processed_children <= 0 then
      Empty
    (* If start and end lines don't match check inner breaks *)
    else if loc._end.line > loc.start.line then
      let (children_n, _) =
        List.fold_left
          (fun (children_n, last_line) (loc, child) ->
            let child_n = SourceLocation (loc, child) in
            let formatted_child_n =
              match last_line with
              (* First child, newlines will always be forced via the `pretty_hardline` below *)
              | None -> child_n
              (* If there is at least one blank line between the current and previous child,
                 output a single blank line separating the children. *)
              | Some last_line when loc.start.line > last_line + 1 ->
                fuse [pretty_hardline; Newline; child_n]
              (* If the current child and the previous child line positions are offset match
                 this via forcing a newline *)
              | Some last_line when loc.start.line > last_line ->
                (* TODO: Remove the `Newline` hack, this forces newlines to exist
                   when using the compact printer *)
                fuse [Newline; child_n]
              (* Must be on the same line as the previous child *)
              | Some _ -> child_n
            in
            (formatted_child_n :: children_n, Some loc._end.line))
          ([], None)
          processed_children
      in
      fuse [Layout.Indent (fuse (pretty_hardline :: List.rev children_n)); pretty_hardline]
    (* Single line *)
    else
      fuse (Base.List.map ~f:(fun (loc, child) -> SourceLocation (loc, child)) processed_children)
  )

and jsx_child ~opts (loc, child) =
  match child with
  | Ast.JSX.Element elem -> Some (loc, jsx_element ~opts loc elem)
  | Ast.JSX.Fragment frag -> Some (loc, jsx_fragment ~opts loc frag)
  | Ast.JSX.ExpressionContainer express -> Some (loc, jsx_expression_container ~opts loc express)
  | Ast.JSX.SpreadChild spread -> Some (loc, jsx_spread_child ~opts loc spread)
  | Ast.JSX.Text { Ast.JSX.Text.raw; _ } -> begin
    match Utils_jsx.trim_jsx_text loc raw with
    | Some (loc, txt) -> Some (loc, Atom txt)
    | None -> None
  end

and partition_specifiers ~opts default specifiers =
  let open Ast.Statement.ImportDeclaration in
  let (special, named) =
    match specifiers with
    | Some (ImportNamespaceSpecifier (loc, id)) -> ([import_namespace_specifier (loc, id)], None)
    | Some (ImportNamedSpecifiers named_specifiers) ->
      let named =
        (* special case for imports: single specifiers don't break no matter how long *)
        match (named_specifiers, default) with
        | ([_], Some _) (* one specifier and a default *)
        | (_ :: _ :: _, _) (* more than one specifier *) ->
          import_named_specifiers ~opts named_specifiers
        | ([named_specifier], None) (* one specifier but no default *) ->
          let bracket_space =
            if opts.bracket_spacing then
              pretty_space
            else
              Empty
          in
          fuse
            [
              Atom "{";
              bracket_space;
              import_named_specifier named_specifier;
              bracket_space;
              Atom "}";
            ]
        | ([], _) -> Atom "{}"
      in
      ([], Some named)
    | None -> ([], None)
  in
  let special =
    match default with
    | Some { identifier = default; remote_default_name_def_loc = _ } ->
      identifier default :: special
    | None -> special
  in
  (special, named)

and import_namespace_specifier (loc, id) =
  source_location_with_comments (loc, fuse [Atom "*"; pretty_space; Atom "as"; space; identifier id])

and import_named_specifier
    { Ast.Statement.ImportDeclaration.kind; local; remote; remote_name_def_loc = _ } =
  fuse
    [
      (let open Ast.Statement.ImportDeclaration in
      match kind with
      | Some ImportType -> fuse [Atom "type"; space]
      | Some ImportTypeof -> fuse [Atom "typeof"; space]
      | Some ImportValue
      | None ->
        Empty
      );
      identifier remote;
      (match local with
      | Some id -> fuse [space; Atom "as"; space; identifier id]
      | None -> Empty);
    ]

and import_named_specifiers ~opts named_specifiers =
  group
    [
      new_list
        ~wrap:(Atom "{", Atom "}")
        ~sep:(Atom ",")
        ~wrap_spaces:opts.bracket_spacing
        (Base.List.map ~f:import_named_specifier named_specifiers);
    ]

and import_declaration
    ~opts loc { Ast.Statement.ImportDeclaration.import_kind; source; specifiers; default; comments }
    =
  let s_from = fuse [Atom "from"; pretty_space] in
  let module I = Ast.Statement.ImportDeclaration in
  layout_node_with_comments_opt loc comments
  @@ with_semicolon
       (fuse
          [
            Atom "import";
            begin
              match import_kind with
              | I.ImportType -> fuse [space; Atom "type"]
              | I.ImportTypeof -> fuse [space; Atom "typeof"]
              | I.ImportValue -> Empty
            end;
            begin
              match (partition_specifiers ~opts default specifiers, import_kind) with
              (* No export specifiers *)
              (* `import 'module-name';` *)
              | (([], None), I.ImportValue) -> pretty_space
              (* `import type {} from 'module-name';` *)
              | (([], None), (I.ImportType | I.ImportTypeof)) ->
                fuse [pretty_space; Atom "{}"; pretty_space; s_from]
              (* Only has named specifiers *)
              | (([], Some named), _) -> fuse [pretty_space; named; pretty_space; s_from]
              (* Only has default or namedspaced specifiers *)
              | ((special, None), _) ->
                fuse [space; fuse_list ~sep:(Atom ",") special; space; s_from]
              (* Has both default or namedspaced specifiers and named specifiers *)
              | ((special, Some named), _) ->
                fuse [space; fuse_list ~sep:(Atom ",") (special @ [named]); pretty_space; s_from]
            end;
            string_literal ~opts (fst source) (snd source);
          ]
       )

and export_source ~opts ~prefix = function
  | Some (loc, lit) -> fuse [prefix; Atom "from"; pretty_space; string_literal ~opts loc lit]
  | None -> Empty

and export_specifier ~opts source =
  let open Ast.Statement.ExportNamedDeclaration in
  function
  | ExportSpecifiers specifiers ->
    fuse
      [
        group
          [
            new_list
              ~wrap:(Atom "{", Atom "}")
              ~sep:(Atom ",")
              ~wrap_spaces:opts.bracket_spacing
              (List.map
                 (fun ( loc,
                        {
                          ExportSpecifier.local;
                          exported;
                          from_remote = _;
                          imported_name_def_loc = _;
                        }
                      ) ->
                   source_location_with_comments
                     ( loc,
                       fuse
                         [
                           identifier local;
                           begin
                             match exported with
                             | Some export -> fuse [space; Atom "as"; space; identifier export]
                             | None -> Empty
                           end;
                         ]
                     ))
                 specifiers
              );
          ];
        export_source ~opts ~prefix:pretty_space source;
      ]
  | ExportBatchSpecifier (loc, Some ident) ->
    fuse
      [
        source_location_with_comments
          (loc, fuse [Atom "*"; pretty_space; Atom "as"; space; identifier ident]);
        export_source ~opts ~prefix:space source;
      ]
  | ExportBatchSpecifier (loc, None) ->
    fuse
      [
        source_location_with_comments (loc, Atom "*");
        export_source ~opts ~prefix:pretty_space source;
      ]

and export_declaration
    ~opts
    loc
    { Ast.Statement.ExportNamedDeclaration.declaration; specifiers; source; export_kind; comments }
    =
  layout_node_with_comments_opt loc comments
  @@ fuse
       [
         Atom "export";
         begin
           match (declaration, specifiers) with
           | (Some decl, None) -> fuse [space; statement ~opts decl]
           | (None, Some specifier) ->
             with_semicolon
               (fuse
                  [
                    begin
                      match export_kind with
                      | Ast.Statement.ExportType -> fuse [space; Atom "type"]
                      | Ast.Statement.ExportValue -> Empty
                    end;
                    pretty_space;
                    export_specifier ~opts source specifier;
                  ]
               )
           | (_, _) -> failwith "Invalid export declaration"
         end;
       ]

and export_default_declaration
    ~opts loc { Ast.Statement.ExportDefaultDeclaration.default = _; declaration; comments } =
  layout_node_with_comments_opt loc comments
  @@ fuse
       [
         Atom "export";
         space;
         Atom "default";
         space;
         (let open Ast.Statement.ExportDefaultDeclaration in
         match declaration with
         | Declaration stat -> statement ~opts stat
         | Expression expr -> with_semicolon (expression ~opts expr)
         );
       ]

and variance (loc, { Ast.Variance.kind; comments }) =
  source_location_with_comments
    ?comments
    ( loc,
      match kind with
      | Ast.Variance.Plus -> Atom "+"
      | Ast.Variance.Minus -> Atom "-"
      | Ast.Variance.Readonly -> fuse [Atom "readonly"; space]
      | Ast.Variance.In -> fuse [Atom "in"; space]
      | Ast.Variance.Out -> fuse [Atom "out"; space]
      | Ast.Variance.InOut -> fuse [Atom "in out"; space]
    )

and const const_ =
  if Base.Option.is_some const_ then
    fuse [Atom "const"; space]
  else
    Empty

and match_case_guard ~opts guard =
  Base.Option.value_map guard ~default:Empty ~f:(fun e ->
      fuse [space; Atom "if"; pretty_space; wrap_in_parens (expression ~opts e)]
  )

and match_case :
      'B.
      opts:opts ->
      on_case_body:(opts:opts -> 'B -> Layout.layout_node) ->
      ('loc, 'loc, 'B) Ast.Match.Case.t ->
      Layout.layout_node =
 fun ~opts ~on_case_body (loc, { Ast.Match.Case.pattern; body; guard; comments; invalid_syntax = _ })
     ->
  layout_node_with_comments_opt
    loc
    comments
    (fuse
       [
         match_pattern ~opts pattern;
         match_case_guard ~opts guard;
         pretty_space;
         Atom "=>";
         pretty_space;
         on_case_body ~opts body;
       ]
    )

and match_pattern ~opts (loc, pattern) =
  let open Ast.MatchPattern in
  match pattern with
  | WildcardPattern { WildcardPattern.comments; _ } ->
    layout_node_with_comments_opt loc comments (Atom "_")
  | NumberPattern lit -> number_literal ~opts loc lit
  | BigIntPattern lit -> bigint_literal loc lit
  | StringPattern lit -> string_literal ~opts loc lit
  | BooleanPattern lit -> boolean_literal loc lit
  | NullPattern comments -> null_literal loc comments
  | IdentifierPattern ident -> identifier ident
  | MemberPattern mem -> match_member_pattern ~opts mem
  | UnaryPattern { UnaryPattern.operator; argument; comments } ->
    let operator =
      match operator with
      | UnaryPattern.Minus -> "-"
      | UnaryPattern.Plus -> "+"
    in
    let argument =
      match argument with
      | (loc, UnaryPattern.NumberLiteral lit) -> number_literal ~opts loc lit
      | (loc, UnaryPattern.BigIntLiteral lit) -> bigint_literal loc lit
    in
    layout_node_with_comments_opt loc comments (fuse [Atom operator; argument])
  | BindingPattern binding -> match_binding_pattern loc binding
  | ObjectPattern obj -> match_object_pattern ~opts loc obj
  | ArrayPattern arr -> match_array_pattern ~opts loc arr
  | OrPattern { OrPattern.patterns; comments } ->
    let patterns = Base.List.map ~f:(match_pattern ~opts) patterns in
    layout_node_with_comments_opt
      loc
      comments
      (join (fuse [pretty_space; Atom "|"; pretty_space]) patterns)
  | AsPattern { AsPattern.pattern; target; comments } ->
    let pattern =
      match pattern with
      | (_, OrPattern _) -> fuse [Atom "("; match_pattern ~opts pattern; Atom ")"]
      | _ -> match_pattern ~opts pattern
    in
    let target =
      match target with
      | AsPattern.Binding (loc, binding) -> match_binding_pattern loc binding
      | AsPattern.Identifier ident -> identifier ident
    in
    layout_node_with_comments_opt loc comments (fuse [pattern; space; Atom "as"; space; target])

and match_member_pattern ~opts (loc, { Ast.MatchPattern.MemberPattern.base; property; comments }) =
  let open Ast.MatchPattern.MemberPattern in
  let base =
    match base with
    | BaseIdentifier id -> identifier id
    | BaseMember mem -> match_member_pattern ~opts mem
  in
  layout_node_with_comments_opt
    loc
    comments
    (match property with
    | PropertyString (loc, lit) -> fuse [base; Atom "["; string_literal ~opts loc lit; Atom "]"]
    | PropertyNumber (loc, lit) -> fuse [base; Atom "["; number_literal ~opts loc lit; Atom "]"]
    | PropertyBigInt (loc, lit) -> fuse [base; Atom "["; bigint_literal loc lit; Atom "]"]
    | PropertyIdentifier ident -> fuse [base; Atom "."; identifier ident])

and match_binding_pattern loc { Ast.MatchPattern.BindingPattern.kind; id; comments } =
  source_location_with_comments ?comments (loc, fuse_with_space [variable_kind kind; identifier id])

and match_object_pattern ~opts loc { Ast.MatchPattern.ObjectPattern.properties; rest; comments } =
  let props_rev = Base.List.rev_map ~f:(match_object_pattern_property ~opts) properties in
  let props_rev =
    Base.Option.value_map rest ~default:props_rev ~f:(fun rest ->
        match_rest_pattern rest :: props_rev
    )
  in
  let props = List.rev props_rev in
  layout_node_with_comments_opt
    loc
    comments
    (group [new_list ~wrap:(Atom "{", Atom "}") ~sep:(fuse [Atom ","]) props])

and match_object_pattern_property ~opts prop =
  let open Ast.MatchPattern.ObjectPattern in
  let prop_key key =
    match key with
    | Property.StringLiteral (loc, lit) -> string_literal ~opts loc lit
    | Property.NumberLiteral (loc, lit) -> number_literal ~opts loc lit
    | Property.BigIntLiteral (loc, lit) -> bigint_literal loc lit
    | Property.Identifier ident -> identifier ident
  in
  match prop with
  | (loc, Property.Valid { Property.key; pattern; shorthand; comments }) ->
    layout_node_with_comments_opt
      loc
      comments
      ( if shorthand then
        match_pattern ~opts pattern
      else
        fuse [prop_key key; Atom ":"; pretty_space; match_pattern ~opts pattern]
      )
  | (_, Property.InvalidShorthand ident) -> identifier ident

and match_array_pattern ~opts loc { Ast.MatchPattern.ArrayPattern.elements; rest; comments } =
  let open Ast.MatchPattern.ArrayPattern in
  let elements_rev =
    Base.List.rev_map ~f:(fun { Element.pattern; _ } -> match_pattern ~opts pattern) elements
  in
  let elements_rev =
    Base.Option.value_map rest ~default:elements_rev ~f:(fun rest ->
        match_rest_pattern rest :: elements_rev
    )
  in
  let elements = List.rev elements_rev in
  layout_node_with_comments_opt
    loc
    comments
    (group [new_list ~wrap:(Atom "[", Atom "]") ~sep:(Atom ",") elements])

and match_rest_pattern (loc, { Ast.MatchPattern.RestPattern.argument; comments }) =
  match argument with
  | Some (arg_loc, arg) ->
    layout_node_with_comments_opt loc comments (fuse [Atom "..."; match_binding_pattern arg_loc arg])
  | None -> layout_node_with_comments_opt loc comments (Atom "...")

and switch_case
    ~opts ~last (loc, { Ast.Statement.Switch.Case.test; case_test_loc = _; consequent; comments }) =
  let case_left =
    layout_node_with_comments_opt
      loc
      comments
      (match test with
      | Some expr -> fuse_with_space [Atom "case"; fuse [expression ~opts expr; Atom ":"]]
      | None -> Atom "default:")
  in
  source_location_with_comments
    ( loc,
      match consequent with
      | [] -> case_left
      | _ ->
        let statements = statement_list ~opts ~pretty_semicolon:last consequent in
        fuse [case_left; Indent (fuse [pretty_hardline; fuse statements])]
    )

and type_param
    ~opts
    ( _,
      {
        Ast.Type.TypeParam.name = (loc, { Ast.Identifier.name; comments });
        bound;
        bound_kind;
        variance = variance_;
        default;
        const = const_;
      }
    ) =
  fuse
    [
      const const_;
      option variance variance_;
      source_location_with_comments ?comments (loc, Atom name);
      hint
        (fun t ->
          match bound_kind with
          | Ast.Type.TypeParam.Colon -> type_annotation ~opts t
          | Ast.Type.TypeParam.Extends ->
            let (_, t) = t in
            fuse [space; Atom "extends"; space; type_ ~opts t])
        bound;
      begin
        match default with
        | Some t -> fuse [pretty_space; Atom "="; pretty_space; type_ ~opts t]
        | None -> Empty
      end;
    ]

and type_parameter ~opts ~kind (loc, { Ast.Type.TypeParams.params; comments }) =
  let num_params = List.length params in
  let internal_comments =
    match internal_comments comments with
    | None -> []
    | Some comments -> [comments]
  in
  let params =
    Base.List.mapi
      ~f:(fun i ((loc, _) as param) ->
        let param_layout = type_param ~opts param in
        (* Add trailing comma to last parameter *)
        let param_layout =
          if
            i = num_params - 1
            && internal_comments = []
            && Trailing_commas.enabled_for_types opts.trailing_commas
          then
            fuse [param_layout; if_break (Atom ",") Empty]
          else
            param_layout
        in
        let comment_bounds = Comment_attachment.type_param_comment_bounds ~kind param in
        (loc, comment_bounds, param_layout))
      params
  in
  let params = params @ internal_comments in
  let params_layout = list_with_newlines ~sep:(Atom ",") ~sep_linebreak:pretty_line params in
  source_location_with_comments
    ?comments
    (loc, group [wrap_and_indent (Atom "<", Atom ">") params_layout])

and call_args ~opts ~is_new ~lparen (loc, { Ast.Expression.ArgList.arguments; comments }) =
  let arg_loc = function
    | Ast.Expression.Expression (loc, _) -> loc
    | Ast.Expression.Spread (loc, _) -> loc
  in
  let num_args = List.length arguments in
  let internal_comments =
    match internal_comments comments with
    | None -> []
    | Some comments -> [comments]
  in
  (* Multiline JSX expression in new expressions are wrapped in parentheses by prettier. If we
     encounter a multiline JSX expression in a new expression, expand its loc by one line in both
     directions when determining adjacent whitespace to account for where the parentheses would be .*)
  let expand_arg_loc loc arg =
    let open Loc in
    match arg with
    | Ast.Expression.Expression (loc, (Ast.Expression.JSXElement _ | Ast.Expression.JSXFragment _))
      when is_new && loc.start.line < loc._end.line ->
      {
        loc with
        start = { loc.start with line = loc.start.line - 1 };
        _end = { loc._end with line = loc._end.line + 1 };
      }
    | _ -> loc
  in
  let args =
    Base.List.mapi
      ~f:(fun i arg ->
        let loc = arg_loc arg in
        let comment_bounds = Comment_attachment.expression_or_spread_comment_bounds loc arg in
        (* Add trailing comma to last argument *)
        let arg_layout = expression_or_spread ~opts arg in
        let arg_layout =
          if
            i = num_args - 1
            && internal_comments = []
            && Trailing_commas.enabled_for_function_args opts.trailing_commas
          then
            fuse [arg_layout; if_break (Atom ",") Empty]
          else
            arg_layout
        in
        (expand_arg_loc loc arg, comment_bounds, arg_layout))
      arguments
  in
  (* Add internal comments *)
  let args = args @ internal_comments in
  let args_layout = list_with_newlines ~sep:(Atom ",") ~sep_linebreak:pretty_line args in
  (* Match prettier's behavior by preserving whether a single template argument begins on new line *)
  let break =
    match arguments with
    | [
     Ast.Expression.Expression
       (arg_loc, (Ast.Expression.TemplateLiteral _ | Ast.Expression.TaggedTemplate _));
    ]
      when internal_comments = [] ->
      if Loc.(loc.start.line = arg_loc.start.line) then
        Some Empty
      else
        Some pretty_hardline
    | _ -> Some softline
  in
  source_location_with_comments
    ?comments
    (loc, group [wrap_and_indent ?break (Atom lparen, Atom ")") args_layout])

and call_type_args ~opts ~less_than (loc, { Ast.Expression.CallTypeArgs.arguments = args; comments })
    =
  let arg_loc = function
    | Ast.Expression.CallTypeArg.Explicit (loc, _) -> loc
    | Ast.Expression.CallTypeArg.Implicit (loc, _) -> loc
  in
  let num_args = List.length args in
  let internal_comments =
    match internal_comments comments with
    | None -> []
    | Some comments -> [comments]
  in
  let args =
    Base.List.mapi
      ~f:(fun i arg ->
        let loc = arg_loc arg in
        let comment_bounds = Comment_attachment.call_type_arg_comment_bounds loc arg in
        (* Add trailing comma to last argument *)
        let arg_layout = call_type_arg ~opts arg in
        let arg_layout =
          if
            i = num_args - 1
            && internal_comments = []
            && Trailing_commas.enabled_for_types opts.trailing_commas
          then
            fuse [arg_layout; if_break (Atom ",") Empty]
          else
            arg_layout
        in
        (loc, comment_bounds, arg_layout))
      args
  in
  (* Add internal comments *)
  let args = args @ internal_comments in
  let args_layout = list_with_newlines ~sep:(Atom ",") ~sep_linebreak:pretty_line args in
  source_location_with_comments
    ?comments
    (loc, group [wrap_and_indent (Atom less_than, Atom ">") args_layout])

and call_type_arg ~opts (x : (Loc.t, Loc.t) Ast.Expression.CallTypeArg.t) =
  let open Ast.Expression.CallTypeArg in
  match x with
  | Implicit (loc, { Implicit.comments }) -> layout_node_with_comments_opt loc comments (Atom "_")
  | Explicit t -> type_ ~opts t

and type_args ~opts (loc, { Ast.Type.TypeArgs.arguments; comments }) =
  let num_args = List.length arguments in
  let internal_comments =
    match internal_comments comments with
    | None -> []
    | Some comments -> [comments]
  in
  let args =
    Base.List.mapi
      ~f:(fun i ((loc, _) as arg) ->
        let comment_bounds =
          Comment_attachment.comment_bounds_without_trailing_line_comment
            (Comment_attachment.type_comment_bounds arg)
        in
        (* Add trailing comma to last argument *)
        let arg_layout = type_ ~opts arg in
        let arg_layout =
          if
            i = num_args - 1
            && internal_comments = []
            && Trailing_commas.enabled_for_types opts.trailing_commas
          then
            fuse [arg_layout; if_break (Atom ",") Empty]
          else
            arg_layout
        in
        (loc, comment_bounds, arg_layout))
      arguments
  in
  (* Add internal comments *)
  let args = args @ internal_comments in
  let args_layout = list_with_newlines ~sep:(Atom ",") ~sep_linebreak:pretty_line args in
  source_location_with_comments
    ?comments
    (loc, group [wrap_and_indent (Atom "<", Atom ">") args_layout])

and type_alias ~opts ~declare loc { Ast.Statement.TypeAlias.id; tparams; right; comments } =
  let right_separator =
    comment_aware_separator ~no_comment:pretty_space (Comment_attachment.type_comment_bounds right)
  in
  layout_node_with_comments_opt loc comments
  @@ group
       [
         with_semicolon
           (fuse
              [
                ( if declare then
                  fuse [Atom "declare"; space]
                else
                  Empty
                );
                Atom "type";
                space;
                identifier id;
                option (type_parameter ~opts ~kind:Flow_ast_mapper.TypeAliasTP) tparams;
                pretty_space;
                Atom "=";
                right_separator;
                type_ ~opts right;
              ]
           );
       ]

and opaque_type
    ~opts
    ~declare
    loc
    {
      Ast.Statement.OpaqueType.id;
      tparams;
      impl_type;
      lower_bound;
      upper_bound;
      legacy_upper_bound;
      comments;
    } =
  let bounds =
    let upper_bound =
      match upper_bound with
      | Some t -> [pretty_space; Atom "extends"; pretty_space; type_ ~opts t]
      | None ->
        (match legacy_upper_bound with
        | Some t -> [Atom ":"; pretty_space; type_ ~opts t]
        | None -> [])
    in
    match lower_bound with
    | None -> upper_bound
    | Some lower_bound_t ->
      pretty_space :: Atom "super" :: pretty_space :: type_ ~opts lower_bound_t :: upper_bound
  in
  layout_node_with_comments_opt loc comments
  @@ with_semicolon
       (fuse
          ([
             ( if declare then
               fuse [Atom "declare"; space]
             else
               Empty
             );
             Atom "opaque type";
             space;
             identifier id;
             option (type_parameter ~opts ~kind:Flow_ast_mapper.OpaqueTypeTP) tparams;
           ]
          @ bounds
          @
          match impl_type with
          | Some impl_type -> [pretty_space; Atom "="; pretty_space; type_ ~opts impl_type]
          | None -> []
          )
       )

and type_annotation ?(parens = false) ~opts (loc, t) =
  source_location_with_comments
    ( loc,
      fuse
        [
          Atom ":";
          pretty_space;
          ( if parens then
            wrap_in_parens (type_ ~opts t)
          else
            type_ ~opts t
          );
        ]
    )

and type_predicate ~opts (loc, { Ast.Type.Predicate.kind; comments }) =
  source_location_with_comments
    ?comments
    ( loc,
      fuse
        [
          Atom "%checks";
          (let open Ast.Type.Predicate in
          match kind with
          | Declared expr -> wrap_in_parens (expression ~opts expr)
          | Inferred -> Empty
          );
        ]
    )

and type_guard ~opts ~needs_parens guard =
  let open Ast.Type.TypeGuard in
  let (_, { kind; guard = (x, t); comments = _ }) = guard in
  let kind_part =
    match kind with
    | Default -> []
    | Asserts -> [Atom "asserts"]
    | Implies -> [Atom "implies"]
  in
  let id_part = identifier x in
  let type_part =
    match t with
    | None -> []
    | Some t when needs_parens -> [Atom "is"; wrap_in_parens (type_ ~opts t)]
    | Some t -> [Atom "is"; type_ ~opts t]
  in
  join space (kind_part @ [id_part] @ type_part)

and type_guard_annotation ~opts ~needs_parens (loc, guard) =
  source_location_with_comments
    (loc, fuse [Atom ":"; pretty_space; type_guard ~opts ~needs_parens guard])

and type_union_or_intersection ~opts ~sep loc ts comments =
  (* Do not break at the start if the last leading comment is on an earlier line,
     as a line break will already have been inserted. *)
  let inline_start =
    match comments with
    | None -> false
    | Some { Ast.Syntax.leading; _ } ->
      (match List.rev leading with
      | (last_leading_loc, _) :: _ when Loc.(last_leading_loc._end.line < loc.start.line) -> true
      | _ -> false)
  in
  list
    ~inline:(inline_start, true)
    (List.mapi
       (fun i t ->
         let type_separator =
           comment_aware_separator
             ~no_comment:pretty_space
             (Comment_attachment.type_comment_bounds t)
         in
         let sep = fuse [sep; type_separator] in
         fuse
           [
             ( if i = 0 then
               IfBreak (sep, Empty)
             else
               sep
             );
             type_with_parens ~opts t;
           ])
       ts
    )

and type_function_param ~opts (loc, { Ast.Type.Function.Param.name; annot; optional }) =
  source_location_with_comments
    ( loc,
      fuse
        [
          begin
            match name with
            | Some id ->
              fuse
                [
                  identifier id;
                  ( if optional then
                    Atom "?"
                  else
                    Empty
                  );
                  Atom ":";
                  pretty_space;
                ]
            | None -> Empty
          end;
          type_ ~opts annot;
        ]
    )

and type_function_params ~opts (loc, { Ast.Type.Function.Params.this_; params; rest; comments }) =
  let params =
    Base.List.map
      ~f:(fun ((loc, _) as param) ->
        ( loc,
          Comment_attachment.function_type_param_comment_bounds param,
          type_function_param ~opts param
        ))
      params
  in
  (* Add rest param *)
  let params =
    match rest with
    | Some ((loc, { Ast.Type.Function.RestParam.argument; comments }) as rest) ->
      let rest_layout =
        source_location_with_comments
          ?comments
          (loc, fuse [Atom "..."; type_function_param ~opts argument])
      in
      let rest_param =
        (loc, Comment_attachment.function_type_rest_param_comment_bounds rest, rest_layout)
      in
      params @ [rest_param]
    | None -> params
  in
  (* Add this constraint *)
  let params =
    match this_ with
    | Some ((loc, { Ast.Type.Function.ThisParam.annot; comments = _ }) as this_) ->
      let this_layout =
        source_location_with_comments (loc, fuse [Atom "this"; type_annotation ~opts annot])
      in
      let this_constraint =
        (loc, Comment_attachment.function_type_this_param_comment_bounds this_, this_layout)
      in
      this_constraint :: params
    | None -> params
  in
  let params_layout = list_with_newlines ~sep:(Atom ",") ~sep_linebreak:pretty_line params in
  let params_layout = list_add_internal_comments params params_layout comments in
  layout_node_with_comments_opt loc comments
  @@ fuse [wrap_and_indent (Atom "(", Atom ")") params_layout]

and type_function_return ~opts = function
  | Ast.Type.Function.TypeAnnotation t -> type_ ~opts t
  | Ast.Type.Function.TypeGuard guard -> type_guard ~opts ~needs_parens:false guard

and type_function
    ~opts ~sep loc { Ast.Type.Function.params; return; tparams; effect_; comments = func_comments }
    =
  layout_node_with_comments_opt loc func_comments
  @@ group
       [
         ( if effect_ = Ast.Function.Hook then
           Atom "hook"
         else
           Empty
         );
         option (type_parameter ~opts ~kind:Flow_ast_mapper.FunctionTypeTP) tparams;
         type_function_params ~opts params;
         sep;
         pretty_space;
         type_function_return ~opts return;
       ]

and type_object_property ~opts =
  let open Ast.Type.Object in
  function
  | Property
      ( loc,
        { Property.key; value; optional; static; proto; variance = variance_; _method; comments }
      ) ->
    let s_static =
      if static then
        fuse [Atom "static"; space]
      else
        Empty
    in
    let s_proto =
      if proto then
        fuse [Atom "proto"; space]
      else
        Empty
    in
    source_location_with_comments
      ?comments
      ( loc,
        match (value, _method, proto, optional) with
        (* Functions with no special properties can be rendered as methods *)
        | (Property.Init (loc, Ast.Type.Function func), true, false, false) ->
          source_location_with_comments
            ( loc,
              fuse
                [
                  s_static;
                  object_property_key ~opts key;
                  type_function ~opts ~sep:(Atom ":") loc func;
                ]
            )
        (* Normal properties *)
        | (Property.Init t, _, _, _) ->
          fuse
            [
              s_static;
              s_proto;
              option variance variance_;
              object_property_key ~opts key;
              ( if optional then
                Atom "?"
              else
                Empty
              );
              Atom ":";
              pretty_space;
              type_ ~opts t;
            ]
        (* Getters/Setters *)
        | (Property.Get (loc, func), _, _, _) ->
          source_location_with_comments
            ( loc,
              fuse
                [
                  Atom "get";
                  space;
                  object_property_key ~opts key;
                  type_function ~opts ~sep:(Atom ":") loc func;
                ]
            )
        | (Property.Set (loc, func), _, _, _) ->
          source_location_with_comments
            ( loc,
              fuse
                [
                  Atom "set";
                  space;
                  object_property_key ~opts key;
                  type_function ~opts ~sep:(Atom ":") loc func;
                ]
            )
      )
  | SpreadProperty (loc, { SpreadProperty.argument; comments }) ->
    source_location_with_comments ?comments (loc, fuse [Atom "..."; type_ ~opts argument])
  | Indexer (loc, { Indexer.id; key; value; static; variance = variance_; comments }) ->
    source_location_with_comments
      ?comments
      ( loc,
        fuse
          [
            ( if static then
              fuse [Atom "static"; space]
            else
              Empty
            );
            option variance variance_;
            Atom "[";
            begin
              match id with
              | Some id -> fuse [identifier id; Atom ":"; pretty_space]
              | None -> Empty
            end;
            type_ ~opts key;
            Atom "]";
            Atom ":";
            pretty_space;
            type_ ~opts value;
          ]
      )
  | MappedType
      ( loc,
        { MappedType.key_tparam; prop_type; source_type; variance = variance_; optional; comments }
      ) ->
    let optional_token =
      MappedType.(
        match optional with
        | PlusOptional -> Atom "+?"
        | MinusOptional -> Atom "-?"
        | Optional -> Atom "?"
        | NoOptionalFlag -> Empty
      )
    in
    source_location_with_comments
      ?comments
      ( loc,
        fuse
          [
            option variance variance_;
            Atom "[";
            identifier (snd key_tparam).Ast.Type.TypeParam.name;
            space;
            Atom "in";
            space;
            type_ ~opts source_type;
            Atom "]";
            optional_token;
            Atom ":";
            pretty_space;
            type_ ~opts prop_type;
          ]
      )
  | CallProperty (loc, { CallProperty.value = (call_loc, func); static; comments }) ->
    source_location_with_comments
      ?comments
      ( loc,
        fuse
          [
            ( if static then
              fuse [Atom "static"; space]
            else
              Empty
            );
            source_location_with_comments
              (call_loc, type_function ~opts ~sep:(Atom ":") call_loc func);
          ]
      )
  | InternalSlot (loc, { InternalSlot.id; value; optional; static; _method = _; comments }) ->
    source_location_with_comments
      ?comments
      ( loc,
        fuse
          [
            ( if static then
              fuse [Atom "static"; space]
            else
              Empty
            );
            Atom "[[";
            identifier id;
            Atom "]]";
            ( if optional then
              Atom "?"
            else
              Empty
            );
            Atom ":";
            pretty_space;
            type_ ~opts value;
          ]
      )

and type_object ?(sep = Atom ",") ~opts loc { Ast.Type.Object.exact; properties; inexact; comments }
    =
  let s_exact =
    if exact then
      Atom "|"
    else
      Empty
  in
  let sep_linebreak = pretty_line in
  let prop_loc =
    let open Ast.Type.Object in
    function
    | Property (loc, _)
    | SpreadProperty (loc, _)
    | Indexer (loc, _)
    | CallProperty (loc, _)
    | InternalSlot (loc, _)
    | MappedType (loc, _) ->
      loc
  in
  let num_props = List.length properties in
  let internal_comments = internal_comments comments in
  let has_internal_comments = Base.Option.is_some internal_comments in
  let rev_props =
    Base.List.rev_mapi
      ~f:(fun i property ->
        let prop_layout =
          (* Add trailing comma to last property *)
          if
            i = num_props - 1
            && (not (has_internal_comments || inexact))
            && Trailing_commas.enabled_for_types opts.trailing_commas
          then
            let sep = if_break sep Empty in
            fuse [type_object_property ~opts property; sep]
          else
            type_object_property ~opts property
        in
        ( prop_loc property,
          Comment_attachment.object_type_property_comment_bounds property,
          prop_layout
        ))
      properties
  in
  (* Add internal comments and the inexact ellipsis *)
  let rev_props =
    match (internal_comments, inexact) with
    | (Some (loc, junk, layout), true) ->
      let has_trailing_line_comment =
        match comments with
        | Some { Ast.Syntax.internal; _ } ->
          (match Base.List.rev internal with
          | (_, { Ast.Comment.kind = Ast.Comment.Line; _ }) :: _ -> true
          | _ -> false)
        | None -> false
      in
      let linebreak =
        if has_trailing_line_comment then
          (* line comments have their own linebreak, so if the comment
             right before the ellipsis is a line comment, don't add
             another linebreak. *)
          Empty
        else
          sep_linebreak
      in
      (loc, junk, fuse [layout; linebreak; Atom "..."]) :: rev_props
    | (Some comments, false) -> comments :: rev_props
    | (None, true) -> (loc, (None, None), Atom "...") :: rev_props
    | (None, false) -> rev_props
  in
  let props = Base.List.rev rev_props in
  (* If first prop is on a different line then pretty print with line breaks *)
  let break =
    match props with
    | [] -> None
    | (first_loc, _, _) :: _ ->
      if Loc.(loc.start.line < first_loc.start.line) then
        Some pretty_hardline
      else if opts.bracket_spacing then
        Some pretty_line
      else
        None
  in
  let props_layout =
    let props = list_with_newlines ~sep ~sep_linebreak props in
    wrap_and_indent ?break (fuse [Atom "{"; s_exact], fuse [s_exact; Atom "}"]) props
  in
  layout_node_with_comments_opt loc comments @@ group [props_layout]

and type_interface ~opts loc { Ast.Type.Interface.extends; body = (obj_loc, obj); comments } =
  layout_node_with_comments_opt loc comments
  @@ fuse
       [
         Atom "interface";
         interface_extends ~opts extends;
         pretty_space;
         source_location_with_comments (obj_loc, type_object ~opts ~sep:(Atom ",") obj_loc obj);
       ]

and interface_extends ~opts = function
  | [] -> Empty
  | xs ->
    fuse
      [
        space;
        Atom "extends";
        space;
        fuse_list
          ~sep:(Atom ",")
          (List.map
             (fun (loc, generic) ->
               source_location_with_comments (loc, type_generic ~opts loc generic))
             xs
          );
      ]

and type_generic ~opts loc { Ast.Type.Generic.id; targs; comments } =
  let rec generic_identifier =
    let open Ast.Type.Generic.Identifier in
    function
    | Unqualified id -> identifier id
    | Qualified (loc, { qualification; id }) ->
      source_location_with_comments
        (loc, fuse [generic_identifier qualification; Atom "."; identifier id])
  in
  layout_node_with_comments_opt loc comments
  @@ fuse [generic_identifier id; option (type_args ~opts) targs]

and type_indexed_access
    ?(optional = false) ~opts loc { Ast.Type.IndexedAccess._object; index; comments } =
  let left_delim =
    if optional then
      Atom "?.["
    else
      Atom "["
  in
  layout_node_with_comments_opt loc comments
  @@ fuse [type_ ~opts _object; left_delim; type_ ~opts index; Atom "]"]

and type_nullable ~opts loc { Ast.Type.Nullable.argument; comments } =
  layout_node_with_comments_opt loc comments (fuse [Atom "?"; type_with_parens ~opts argument])

and type_typeof ~opts loc { Ast.Type.Typeof.argument; targs; comments } =
  let rec generic_identifier =
    let open Ast.Type.Typeof.Target in
    function
    | Unqualified id -> identifier id
    | Qualified (loc, { qualification; id }) ->
      source_location_with_comments
        (loc, fuse [generic_identifier qualification; Atom "."; identifier id])
  in
  layout_node_with_comments_opt
    loc
    comments
    (fuse [Atom "typeof"; space; generic_identifier argument; option (type_args ~opts) targs])

and type_keyof ~opts loc { Ast.Type.Keyof.argument; comments } =
  layout_node_with_comments_opt loc comments (fuse [Atom "keyof"; space; type_ ~opts argument])

and render_type ~opts loc { Ast.Type.Renders.operator_loc = _; comments; argument; variant } =
  let operator =
    match variant with
    | Ast.Type.Renders.Normal -> "renders"
    | Ast.Type.Renders.Maybe -> "renders?"
    | Ast.Type.Renders.Star -> "renders*"
  in
  flow_type_operator ~opts loc comments operator argument

and flow_type_operator ~opts loc comments operator operand =
  layout_node_with_comments_opt
    loc
    comments
    (fuse [Atom operator; space; type_with_parens ~opts operand])

and type_readonly ~opts loc { Ast.Type.ReadOnly.argument; comments } =
  layout_node_with_comments_opt loc comments (fuse [Atom "readonly"; space; type_ ~opts argument])

and type_tuple ~opts loc { Ast.Type.Tuple.elements; inexact; comments } =
  let elements_rev =
    Base.List.rev_map
      ~f:(function
        | (_, Ast.Type.Tuple.UnlabeledElement annot) -> type_ ~opts annot
        | (loc, Ast.Type.Tuple.LabeledElement e) -> type_tuple_labeled_element ~opts loc e
        | (loc, Ast.Type.Tuple.SpreadElement e) -> type_tuple_spread_element ~opts loc e)
      elements
  in
  let elements_rev =
    if inexact then
      Atom "..." :: elements_rev
    else
      elements_rev
  in
  let elements = List.rev elements_rev in
  layout_node_with_comments_opt
    loc
    comments
    (group [new_list ~wrap:(Atom "[", Atom "]") ~sep:(Atom ",") elements])

and type_tuple_labeled_element
    ~opts loc { Ast.Type.Tuple.LabeledElement.name; annot; variance = variance_; optional } =
  source_location_with_comments
    ( loc,
      fuse
        [
          option variance variance_;
          identifier name;
          ( if optional then
            Atom "?"
          else
            Empty
          );
          Atom ":";
          pretty_space;
          type_ ~opts annot;
        ]
    )

and type_tuple_spread_element ~opts loc { Ast.Type.Tuple.SpreadElement.name; annot } =
  source_location_with_comments
    ( loc,
      match name with
      | Some name -> fuse [Atom "..."; identifier name; Atom ":"; pretty_space; type_ ~opts annot]
      | None -> fuse [Atom "..."; type_ ~opts annot]
    )

and type_array ~opts loc { Ast.Type.Array.argument; comments } =
  layout_node_with_comments_opt loc comments (fuse [Atom "Array<"; type_ ~opts argument; Atom ">"])

and type_conditional
    ~opts loc { Ast.Type.Conditional.check_type; extends_type; true_type; false_type; comments } =
  layout_node_with_comments_opt loc comments
  @@ group
       [
         fuse
           [
             type_with_parens ~opts check_type;
             space;
             Atom "extends";
             space;
             type_with_parens ~opts extends_type;
           ];
         Indent
           (fuse
              [
                pretty_line;
                Atom "?";
                pretty_space;
                type_ ~opts true_type;
                pretty_line;
                Atom ":";
                pretty_space;
                type_ ~opts false_type;
              ]
           );
       ]

and type_infer ~opts loc { Ast.Type.Infer.tparam; comments } =
  layout_node_with_comments_opt loc comments (fuse [Atom "infer"; space; type_param ~opts tparam])

and type_union ~opts loc { Ast.Type.Union.types = (t0, t1, ts); comments } =
  layout_node_with_comments_opt
    loc
    comments
    (type_union_or_intersection ~opts ~sep:(Atom "|") loc (t0 :: t1 :: ts) comments)

and type_intersection ~opts loc { Ast.Type.Intersection.types = (t0, t1, ts); comments } =
  layout_node_with_comments_opt
    loc
    comments
    (type_union_or_intersection ~opts ~sep:(Atom "&") loc (t0 :: t1 :: ts) comments)

and type_with_parens ~opts t =
  let module T = Ast.Type in
  match t with
  | (_, T.Function _)
  | (_, T.Union _)
  | (_, T.Intersection _)
  | (_, T.Conditional _) ->
    wrap_in_parens (type_ ~opts t)
  | _ -> type_ ~opts t

and type_ ~opts ((loc, t) : (Loc.t, Loc.t) Ast.Type.t) =
  let module T = Ast.Type in
  source_location_with_comments
    ( loc,
      match t with
      | T.Any comments -> layout_node_with_comments_opt loc comments (Atom "any")
      | T.Mixed comments -> layout_node_with_comments_opt loc comments (Atom "mixed")
      | T.Empty comments -> layout_node_with_comments_opt loc comments (Atom "empty")
      | T.Void comments -> layout_node_with_comments_opt loc comments (Atom "void")
      | T.Null comments -> null_literal loc comments
      | T.Symbol comments -> layout_node_with_comments_opt loc comments (Atom "symbol")
      | T.Number comments -> layout_node_with_comments_opt loc comments (Atom "number")
      | T.BigInt comments -> layout_node_with_comments_opt loc comments (Atom "bigint")
      | T.String comments -> layout_node_with_comments_opt loc comments (Atom "string")
      | T.Boolean { raw; comments } ->
        let raw =
          match raw with
          | `Boolean -> "boolean"
          | `Bool -> "bool"
        in
        layout_node_with_comments_opt loc comments (Atom raw)
      | T.Unknown comments -> layout_node_with_comments_opt loc comments (Atom "unknown")
      | T.Never comments -> layout_node_with_comments_opt loc comments (Atom "never")
      | T.Undefined comments -> layout_node_with_comments_opt loc comments (Atom "undefined")
      | T.Nullable t -> type_nullable ~opts loc t
      | T.Function func -> type_function ~opts ~sep:(fuse [pretty_space; Atom "=>"]) loc func
      | T.Component comp -> type_component ~opts loc comp
      | T.Object obj -> type_object ~opts loc obj
      | T.Interface i -> type_interface ~opts loc i
      | T.Array t -> type_array ~opts loc t
      | T.Conditional t -> type_conditional ~opts loc t
      | T.Infer t -> type_infer ~opts loc t
      | T.Generic generic -> type_generic ~opts loc generic
      | T.IndexedAccess indexed_access -> type_indexed_access ~opts loc indexed_access
      | T.OptionalIndexedAccess { T.OptionalIndexedAccess.indexed_access; optional } ->
        type_indexed_access ~optional ~opts loc indexed_access
      | T.Union t -> type_union ~opts loc t
      | T.Intersection t -> type_intersection ~opts loc t
      | T.Typeof t -> type_typeof ~opts loc t
      | T.Keyof t -> type_keyof ~opts loc t
      | T.Renders renders -> render_type ~opts loc renders
      | T.ReadOnly t -> type_readonly ~opts loc t
      | T.Tuple t -> type_tuple ~opts loc t
      | T.StringLiteral lit -> string_literal ~opts loc lit
      | T.NumberLiteral lit -> number_literal ~opts loc lit
      | T.BigIntLiteral lit -> bigint_literal loc lit
      | T.BooleanLiteral lit -> boolean_literal loc lit
      | T.Exists comments -> layout_node_with_comments_opt loc comments (Atom "*")
    )

and interface_declaration_base
    ~opts
    ~def
    loc
    { Ast.Statement.Interface.id; tparams; body = (body_loc, obj); extends; comments } =
  layout_node_with_comments_opt loc comments
  @@ fuse
       [
         def;
         identifier id;
         option (type_parameter ~opts ~kind:Flow_ast_mapper.InterfaceTP) tparams;
         interface_extends ~opts extends;
         pretty_space;
         source_location_with_comments (body_loc, type_object ~opts ~sep:(Atom ",") body_loc obj);
       ]

and interface_declaration ~opts loc interface =
  interface_declaration_base ~opts ~def:(fuse [Atom "interface"; space]) loc interface

and declare_interface ~opts loc interface =
  interface_declaration_base
    ~opts
    ~def:(fuse [Atom "declare"; space; Atom "interface"; space])
    loc
    interface

and declare_class
    ?(s_type = Empty)
    ~opts
    loc
    {
      Ast.Statement.DeclareClass.id;
      tparams;
      body = (body_loc, obj);
      extends;
      mixins;
      implements;
      comments;
    } =
  let class_parts =
    [
      Atom "declare";
      space;
      s_type;
      Atom "class";
      space;
      identifier id;
      option (type_parameter ~opts ~kind:Flow_ast_mapper.DeclareClassTP) tparams;
    ]
  in
  let extends_parts =
    let class_extends =
      [
        begin
          match extends with
          | Some (loc, generic) ->
            Some
              (fuse
                 [
                   Atom "extends";
                   space;
                   source_location_with_comments (loc, type_generic ~opts loc generic);
                 ]
              )
          | None -> None
        end;
        begin
          match mixins with
          | [] -> None
          | xs ->
            Some
              (fuse
                 [
                   Atom "mixins";
                   space;
                   fuse_list
                     ~sep:(Atom ",")
                     (List.map
                        (fun (loc, generic) ->
                          source_location_with_comments (loc, type_generic ~opts loc generic))
                        xs
                     );
                 ]
              )
        end;
        class_implements ~opts implements;
      ]
    in
    match deoptionalize class_extends with
    | [] -> Empty
    | items -> Layout.Indent (fuse [line; join line items])
  in
  let body =
    source_location_with_comments (body_loc, type_object ~opts ~sep:(Atom ",") body_loc obj)
  in
  let parts =
    []
    |> List.rev_append class_parts
    |> List.cons extends_parts
    |> List.cons pretty_space
    |> List.cons body
    |> List.rev
  in
  source_location_with_comments ?comments (loc, group parts)

and declare_component
    ?(s_type = Empty)
    ~opts
    loc
    {
      Ast.Statement.DeclareComponent.id;
      tparams;
      params = (params_loc, { Ast.Type.Component.Params.comments = params_comments; _ }) as params;
      renders;
      comments;
    } =
  layout_node_with_comments_opt loc comments
  @@ with_semicolon
       (fuse
          [
            Atom "declare";
            space;
            s_type;
            Atom "component";
            space;
            identifier id;
            option (type_parameter ~opts ~kind:Flow_ast_mapper.DeclareComponentTP) tparams;
            group
              [
                layout_node_with_comments_opt
                  params_loc
                  params_comments
                  (component_type_params ~opts params);
                component_renders ~opts renders;
              ];
          ]
       )

and type_component
    ~opts
    loc
    {
      Ast.Type.Component.tparams;
      params = (params_loc, { Ast.Type.Component.Params.comments = params_comments; _ }) as params;
      renders;
      comments;
    } =
  layout_node_with_comments_opt loc comments
  @@ fuse
       [
         Atom "component";
         option (type_parameter ~opts ~kind:Flow_ast_mapper.ComponentTypeTP) tparams;
         group
           [
             layout_node_with_comments_opt
               params_loc
               params_comments
               (component_type_params ~opts params);
             component_renders ~opts renders;
           ];
       ]

and component_type_params ~opts (_, { Ast.Type.Component.Params.params; rest; comments }) =
  let params =
    Base.List.map
      ~f:(fun ((loc, { Ast.Type.Component.Param.name; annot; optional }) as param) ->
        let (_, annot') = annot in
        ( loc,
          Comment_attachment.component_type_param_comment_bounds param,
          component_type_param ~opts ~optional loc name annot'
        ))
      params
  in
  (* Add rest param *)
  let params =
    match rest with
    | Some ((loc, { Ast.Type.Component.RestParam.argument; annot; optional; comments }) as rest) ->
      let rest_layout =
        source_location_with_comments
          ?comments
          ( loc,
            fuse
              [
                Atom "...";
                Base.Option.value_map
                  ~default:(type_ ~opts annot)
                  ~f:(fun i ->
                    component_type_param
                      ~opts
                      ~optional
                      loc
                      (Ast.Statement.ComponentDeclaration.Param.Identifier i)
                      annot)
                  argument;
              ]
          )
      in
      let rest_param =
        (loc, Comment_attachment.component_type_rest_param_comment_bounds rest, rest_layout)
      in
      params @ [rest_param]
    | None -> params
  in
  let params_layout = list_with_newlines ~sep:(Atom ",") ~sep_linebreak:pretty_line params in
  (* Add trailing comma *)
  let params_layout =
    if
      params <> []
      && rest = None
      && Trailing_commas.enabled_for_function_params opts.trailing_commas
    then
      params_layout @ [if_break (Atom ",") Empty]
    else
      params_layout
  in
  let params_layout = list_add_internal_comments params params_layout comments in
  wrap_and_indent (Atom "(", Atom ")") params_layout

and component_type_param ~opts ~optional loc name annot =
  let optional_layout =
    match optional with
    | true -> Atom "?"
    | false -> Empty
  in
  let name_layout =
    fuse [component_param_name ~opts name; optional_layout; Atom ":"; pretty_space]
  in
  source_location_with_comments (loc, fuse [name_layout; type_ ~opts annot])

and declare_function
    ?(s_type = Empty)
    ~opts
    loc
    { Ast.Statement.DeclareFunction.id; annot = (annot_lot, t); predicate; comments } =
  layout_node_with_comments_opt loc comments
  @@ with_semicolon
       (fuse
          [
            Atom "declare";
            space;
            s_type;
            Atom "function";
            space;
            identifier id;
            source_location_with_comments
              ( annot_lot,
                match t with
                | (loc, Ast.Type.Function func) ->
                  source_location_with_comments (loc, type_function ~opts ~sep:(Atom ":") loc func)
                | _ -> failwith "Invalid DeclareFunction"
              );
            begin
              match predicate with
              | Some pred -> fuse [pretty_space; type_predicate ~opts pred]
              | None -> Empty
            end;
          ]
       )

and declare_variable
    ?(s_type = Empty) ~opts loc { Ast.Statement.DeclareVariable.id; annot; kind; comments } =
  layout_node_with_comments_opt loc comments
  @@ with_semicolon
       (fuse
          [
            Atom "declare";
            space;
            s_type;
            variable_kind kind;
            space;
            identifier id;
            type_annotation ~opts annot;
          ]
       )

and declare_module_exports ~opts loc { Ast.Statement.DeclareModuleExports.annot; comments } =
  layout_node_with_comments_opt loc comments
  @@ with_semicolon
       (fuse [Atom "declare"; space; Atom "module.exports"; type_annotation ~opts annot])

and declare_module ~opts loc { Ast.Statement.DeclareModule.id; body; comments } =
  source_location_with_comments
    ?comments
    ( loc,
      fuse
        [
          Atom "declare";
          space;
          Atom "module";
          space;
          begin
            match id with
            | Ast.Statement.DeclareModule.Identifier id -> identifier id
            | Ast.Statement.DeclareModule.Literal (loc, lit) -> string_literal ~opts loc lit
          end;
          pretty_space;
          block ~opts body;
        ]
    )

and declare_namespace ~opts loc { Ast.Statement.DeclareNamespace.id; body; comments } =
  source_location_with_comments
    ?comments
    ( loc,
      fuse
        (match id with
        | Ast.Statement.DeclareNamespace.Global id ->
          [Atom "declare"; space; identifier id; pretty_space; block ~opts body]
        | Ast.Statement.DeclareNamespace.Local id ->
          [
            Atom "declare";
            space;
            Atom "namespace";
            space;
            identifier id;
            pretty_space;
            block ~opts body;
          ])
    )

and declare_export_declaration
    ~opts
    loc
    { Ast.Statement.DeclareExportDeclaration.default; declaration; specifiers; source; comments } =
  let s_export =
    fuse
      [
        Atom "export";
        space;
        ( if Base.Option.is_some default then
          fuse [Atom "default"; space]
        else
          Empty
        );
      ]
  in
  match (declaration, specifiers) with
  | (Some decl, None) ->
    let open Ast.Statement.DeclareExportDeclaration in
    (match decl with
    (* declare export var *)
    | Variable (loc, var) ->
      source_location_with_comments ?comments (loc, declare_variable ~opts ~s_type:s_export loc var)
    (* declare export function *)
    | Function (loc, func) ->
      source_location_with_comments ?comments (loc, declare_function ~opts ~s_type:s_export loc func)
    (* declare export class *)
    | Class (loc, c) ->
      source_location_with_comments ?comments (loc, declare_class ~opts ~s_type:s_export loc c)
    (* declare export component *)
    | Component (loc, c) ->
      source_location_with_comments ?comments (loc, declare_component ~opts ~s_type:s_export loc c)
    (* declare export default [type]
     * this corresponds to things like
     * export default 1+1; *)
    | DefaultType t ->
      source_location_with_comments
        ?comments
        (loc, with_semicolon (fuse [Atom "declare"; space; s_export; type_ ~opts t]))
    (* declare export type *)
    | NamedType (loc, typeAlias) ->
      source_location_with_comments
        ?comments
        (loc, fuse [Atom "declare"; space; s_export; type_alias ~opts ~declare:false loc typeAlias])
    (* declare export opaque type *)
    | NamedOpaqueType (loc, opaqueType) ->
      source_location_with_comments
        ?comments
        ( loc,
          fuse [Atom "declare"; space; s_export; opaque_type ~opts ~declare:false loc opaqueType]
        )
    (* declare export interface *)
    | Interface (loc, interface) ->
      source_location_with_comments
        ?comments
        (loc, fuse [Atom "declare"; space; s_export; interface_declaration ~opts loc interface])
    (* declare export enum *)
    | Enum (loc, enum) ->
      source_location_with_comments
        ?comments
        (loc, fuse [Atom "declare"; space; s_export; enum_declaration ~def:(Atom "enum") loc enum]))
  | (None, Some specifier) ->
    source_location_with_comments
      ?comments
      ( loc,
        fuse
          [
            Atom "declare";
            space;
            Atom "export";
            pretty_space;
            export_specifier ~opts source specifier;
          ]
      )
  | (_, _) -> failwith "Invalid declare export declaration"
