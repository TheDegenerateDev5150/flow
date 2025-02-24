(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

module Scope_api = Scope_api.With_Loc
module Ssa_api = Ssa_api.With_Loc

module InformationCollectors : sig
  type t = {
    has_unwrapped_control_flow: bool;
    async_function: bool;
    has_this_super: bool;
  }

  val collect_statements_information : (Loc.t, Loc.t) Flow_ast.Statement.t list -> t

  val collect_expression_information : (Loc.t, Loc.t) Flow_ast.Expression.t -> t
end

module RefactorProgramMappers : sig
  val extract_statements_to_function :
    target_body_loc:Loc.t ->
    extracted_statements_loc:Loc.t ->
    function_call_statements:(Loc.t, Loc.t) Flow_ast.Statement.t list ->
    function_declaration_statement:(Loc.t, Loc.t) Flow_ast.Statement.t ->
    (Loc.t, Loc.t) Flow_ast.Program.t ->
    (Loc.t, Loc.t) Flow_ast.Program.t

  val extract_statements_to_method :
    target_body_loc:Loc.t ->
    extracted_statements_loc:Loc.t ->
    function_call_statements:(Loc.t, Loc.t) Flow_ast.Statement.t list ->
    method_declaration:(Loc.t, Loc.t) Flow_ast.Class.Body.element ->
    (Loc.t, Loc.t) Flow_ast.Program.t ->
    (Loc.t, Loc.t) Flow_ast.Program.t

  val extract_expression_to_react_component :
    expression_loc:Loc.t ->
    expression_replacement:(Loc.t, Loc.t) Flow_ast.Expression.t ->
    component_declaration_statement:(Loc.t, Loc.t) Flow_ast.Statement.t ->
    (Loc.t, Loc.t) Flow_ast.Program.t ->
    (Loc.t, Loc.t) Flow_ast.Program.t

  val extract_expression_to_constant :
    statement_loc:Loc.t ->
    expression_loc:Loc.t ->
    expression_replacement:(Loc.t, Loc.t) Flow_ast.Expression.t ->
    constant_definition:(Loc.t, Loc.t) Flow_ast.Statement.t ->
    (Loc.t, Loc.t) Flow_ast.Program.t ->
    (Loc.t, Loc.t) Flow_ast.Program.t

  val extract_expression_to_class_field :
    class_body_loc:Loc.t ->
    expression_loc:Loc.t ->
    expression_replacement:(Loc.t, Loc.t) Flow_ast.Expression.t ->
    field_definition:(Loc.t, Loc.t) Flow_ast.Class.Body.element ->
    (Loc.t, Loc.t) Flow_ast.Program.t ->
    (Loc.t, Loc.t) Flow_ast.Program.t

  val extract_type_to_type_alias :
    statement_loc:Loc.t ->
    type_loc:Loc.t ->
    type_replacement:(Loc.t, Loc.t) Flow_ast.Type.t ->
    type_alias:(Loc.t, Loc.t) Flow_ast.Statement.t ->
    (Loc.t, Loc.t) Flow_ast.Program.t ->
    (Loc.t, Loc.t) Flow_ast.Program.t
end

module VariableAnalysis : sig
  val collect_used_names : (Loc.t, Loc.t) Flow_ast.Program.t -> SSet.t

  type relevant_defs = {
    (* All the definitions that are used by the extracted statements, along with their scopes. *)
    defs_with_scopes_of_local_uses: (Scope_api.Def.t * Scope_api.Scope.t) list;
    (* All the variables that have been reassigned within the extracted statements that
       would be shadowed after refactor. *)
    vars_with_shadowed_local_reassignments: (string * Loc.t) list;
  }

  (* Finding lists of definitions relevant to refactor analysis.
     See the type definition of `relevant_defs` for more information. *)
  val collect_relevant_defs_with_scope :
    scope_info:Scope_api.info -> ssa_values:Ssa_api.values -> extracted_loc:Loc.t -> relevant_defs

  (* After moving extracted statements into a function into another scope, some variables might
     become undefined since original definition exists in inner scopes.
     This function computes such list from the scope information of definitions and the location
     of the scope to put the extracted function. *)
  val undefined_variables_after_extraction :
    scope_info:Scope_api.info ->
    defs_with_scopes_of_local_uses:(Scope_api.Def.t * Scope_api.Scope.t) list ->
    new_function_target_scope_loc:Loc.t option ->
    extracted_loc:Loc.t ->
    (string * Loc.t) list

  type escaping_definitions = {
    (* A list of variable names that are defined inside the extracted statements,
       but have uses outside of them. *)
    escaping_variables: (string * Loc.t) list;
    (* Whether any of the escaping variables has another write outside of extracted statements. *)
    has_external_writes: bool;
  }

  val collect_escaping_local_defs :
    scope_info:Scope_api.info ->
    ssa_values:Ssa_api.values ->
    extracted_statements_loc:Loc.t ->
    escaping_definitions
end

module TypeSynthesizer : sig
  (* An object of all the information needed to provide and transform parameter type annotations. *)
  type synthesizer_context

  val create_synthesizer_context :
    cx:Context.t ->
    file:File_key.t ->
    file_sig:File_sig.t ->
    typed_ast:(ALoc.t, ALoc.t * Type.t) Flow_ast.Program.t ->
    loc_of_aloc:(ALoc.t -> Loc.t) ->
    get_ast_from_shared_mem:(File_key.t -> (Loc.t, Loc.t) Flow_ast.Program.t option) ->
    get_haste_module_info:(File_key.t -> Haste_module_info.t option) ->
    get_type_sig:(File_key.t -> Type_sig_collections.Locs.index Packed_type_sig.Module.t option) ->
    locs:Loc_collections.LocSet.t ->
    synthesizer_context

  type type_synthesizer_with_import_adder = {
    type_param_synthesizer:
      Type.typeparam -> ((Loc.t, Loc.t) Flow_ast.Type.TypeParam.t, Insert_type.expected) result;
    type_synthesizer:
      Loc.t ->
      ((Type.typeparam list * (Loc.t, Loc.t) Flow_ast.Type.t) option, Insert_type.expected) result;
    added_imports: unit -> (string * Autofix_imports.bindings) list;
  }

  val create_type_synthesizer_with_import_adder :
    synthesizer_context -> type_synthesizer_with_import_adder
end
