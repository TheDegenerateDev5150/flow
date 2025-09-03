(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

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

type expression_node_parent =
  | StatementParentOfExpression of (Loc.t, Loc.t) Flow_ast.Statement.t
  | ExpressionParentOfExpression of (Loc.t, Loc.t) Flow_ast.Expression.t
  | ClassExtends
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

type node =
  | Raw of string
  | Comment of Loc.t Flow_ast.Comment.t
  | StringLiteral of Loc.t * Loc.t Flow_ast.StringLiteral.t
  | NumberLiteral of Loc.t * Loc.t Flow_ast.NumberLiteral.t
  | BigIntLiteral of Loc.t * Loc.t Flow_ast.BigIntLiteral.t
  | BooleanLiteral of Loc.t * Loc.t Flow_ast.BooleanLiteral.t
  | RegExpLiteral of Loc.t * Loc.t Flow_ast.RegExpLiteral.t
  | ModuleRefLiteral of Loc.t * (Loc.t, Loc.t) Flow_ast.ModuleRefLiteral.t
  | Statement of ((Loc.t, Loc.t) Flow_ast.Statement.t * statement_node_parent)
  | Program of (Loc.t, Loc.t) Flow_ast.Program.t
  | Expression of ((Loc.t, Loc.t) Flow_ast.Expression.t * expression_node_parent)
  | Pattern of (Loc.t, Loc.t) Flow_ast.Pattern.t
  | Params of (Loc.t, Loc.t) Flow_ast.Function.Params.t
  | Variance of Loc.t Flow_ast.Variance.t
  | Type of (Loc.t, Loc.t) Flow_ast.Type.t
  | TypeParam of (Loc.t, Loc.t) Flow_ast.Type.TypeParam.t
  | TypeAnnotation of (Loc.t, Loc.t) Flow_ast.Type.annotation
  | TypeGuard of (Loc.t, Loc.t) Flow_ast.Type.TypeGuard.t
  | TypeGuardAnnotation of (Loc.t, Loc.t) Flow_ast.Type.type_guard_annotation
  | FunctionTypeAnnotation of (Loc.t, Loc.t) Flow_ast.Type.annotation
  | ClassProperty of (Loc.t, Loc.t) Flow_ast.Class.Property.t
  | ClassPrivateField of (Loc.t, Loc.t) Flow_ast.Class.PrivateField.t
  | ObjectProperty of (Loc.t, Loc.t) Flow_ast.Expression.Object.property
  | TemplateLiteral of Loc.t * (Loc.t, Loc.t) Flow_ast.Expression.TemplateLiteral.t
  | JSXChild of (Loc.t, Loc.t) Flow_ast.JSX.child
  | JSXIdentifier of (Loc.t, Loc.t) Flow_ast.JSX.Identifier.t
  | MatchPattern of (Loc.t, Loc.t) Flow_ast.MatchPattern.t
  | MatchObjectPatternProperty of (Loc.t, Loc.t) Flow_ast.MatchPattern.ObjectPattern.Property.t
[@@deriving show]

val expand_statement_comment_bounds : (Loc.t, Loc.t) Flow_ast.Statement.t -> Loc.t

(* Diffs the given ASTs using referential equality to determine whether two nodes are different.
 * This works well for transformations based on Flow_ast_mapper, which preserves identity, but it
 * does not work well for e.g. parsing two programs and determining their differences. *)
val program : (Loc.t, Loc.t) Flow_ast.Program.t -> (Loc.t, Loc.t) Flow_ast.Program.t -> node changes

(* Diffs two lists and produces an edit script. This is exposed only for testing purposes *)
type 'a diff_result = int * 'a change'

val list_diff : 'a list -> 'a list -> 'a diff_result list option

type partition_result =
  | Partitioned of {
      directives: (Loc.t, Loc.t) Flow_ast.Statement.t list;
      imports: (Loc.t, Loc.t) Flow_ast.Statement.t list;
      body: (Loc.t, Loc.t) Flow_ast.Statement.t list;
    }

val partition_imports : (Loc.t, Loc.t) Flow_ast.Statement.t list -> partition_result
