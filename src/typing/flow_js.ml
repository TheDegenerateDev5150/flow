(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* This module describes the subtyping algorithm that forms the core of
   typechecking. The algorithm (in its basic form) is described in Francois
   Pottier's thesis. The main data structures maintained by the algorithm are:
   (1) for every type variable, which type variables form its lower and upper
   bounds (i.e., flow in and out of the type variable); and (2) for every type
   variable, which concrete types form its lower and upper bounds. Every new
   subtyping constraint added to the system is deconstructed into its subparts,
   until basic flows between type variables and other type variables or concrete
   types remain; these flows are then viewed as links in a chain, bringing
   together further concrete types and type variables to participate in
   subtyping. This process continues till a fixpoint is reached---which itself
   is guaranteed to exist, and is usually reached in very few steps. *)

open Flow_js_utils
open Utils_js
open Reason
open Type
open TypeUtil
open Constraint
open Debug_js.Verbose
module FlowError = Flow_error
module IICheck = Implicit_instantiation_check

(**************************************************************)

(* Check that id1 is not linked to id2. *)
let not_linked (id1, _bounds1) (_id2, bounds2) =
  (* It suffices to check that id1 is not already in the lower bounds of
     id2. Equivalently, we could check that id2 is not already in the upper
     bounds of id1. *)
  not (IMap.mem id1 bounds2.lowertvars)

(********************************************************************)

module ImplicitTypeArgument = Instantiation_utils.ImplicitTypeArgument
module TypeAppExpansion = Instantiation_utils.TypeAppExpansion
module Cache = Flow_cache

(********************)
(* subtype relation *)
(********************)

(* Sometimes we expect types to be def types. For example, when we see a flow
   constraint from type l to type u, we expect l to be a def type. As another
   example, when we see a unification constraint between t1 and t2, we expect
   both t1 and t2 to be def types. *)

(* Recursion limiter. We proxy recursion depth with trace depth,
   which is either equal or pretty close.
   When check is called with a trace whose depth exceeds a constant
   limit, we throw a LimitExceeded exception.
*)

module RecursionCheck : sig
  exception LimitExceeded

  val check : Context.t -> Type.DepthTrace.t -> unit
end = struct
  exception LimitExceeded

  (* check trace depth as a proxy for recursion depth
     and throw when limit is exceeded *)
  let check cx trace =
    if DepthTrace.depth trace >= Context.recursion_limit cx then raise LimitExceeded
end

(* The main problem with constant folding is infinite recursion. Consider a loop
 * that keeps adding 1 to a variable x, which is initialized to 0. If we
 * constant fold x naively, we'll recurse forever, inferring that x has the type
 * (0 | 1 | 2 | 3 | 4 | etc). What we need to do is recognize loops and stop
 * doing constant folding.
 *
 * One solution is for constant-folding-location to keep count of how many times
 * we have seen a reason at a given position in the array.
 * Then, when we've seen it multiple times in the same place, we can decide
 * to stop doing constant folding.
 *)

module ConstFoldExpansion : sig
  val guard : Context.t -> int -> reason * int -> (int -> 't) -> 't
end = struct
  let get_rmap cache id = IMap.find_opt id cache |> Base.Option.value ~default:ConstFoldMap.empty

  let increment reason_with_pos rmap =
    match ConstFoldMap.find_opt reason_with_pos rmap with
    | None -> (0, ConstFoldMap.add reason_with_pos 1 rmap)
    | Some count -> (count, ConstFoldMap.add reason_with_pos (count + 1) rmap)

  let guard cx id reason_with_pos f =
    let cache = Context.const_fold_cache cx in
    let (count, rmap) = get_rmap !cache id |> increment reason_with_pos in
    cache := IMap.add id rmap !cache;
    f count
end

let subst = Type_subst.subst ~placeholder_no_infer:false

let check_canceled =
  let count = ref 0 in
  fun () ->
    let n = (!count + 1) mod 128 in
    count := n;
    if n = 0 then WorkerCancel.check_should_cancel ()

let is_concrete t =
  match t with
  | EvalT _
  | AnnotT _
  | MaybeT _
  | OptionalT _
  | TypeAppT _
  | ThisTypeAppT _
  | OpenT _ ->
    false
  | _ -> true

let inherited_method = function
  | OrdinaryName "constructor" -> false
  | _ -> true

let find_resolved_opt cx ~default ~f id =
  let constraints = Context.find_graph cx id in
  match constraints with
  | Resolved t -> f t
  | FullyResolved s -> f (Context.force_fully_resolved_tvar cx s)
  | Unresolved _ -> default

let rec drop_resolved cx t =
  match t with
  | GenericT { reason; name; id = g_id; bound = OpenT (_, id); no_infer } ->
    find_resolved_opt cx id ~default:t ~f:(fun t ->
        GenericT { reason; name; id = g_id; bound = drop_resolved cx t; no_infer }
    )
  | OpenT (_, id) -> find_resolved_opt cx id ~default:t ~f:(drop_resolved cx)
  | _ -> t

(********************** start of slab **********************************)
module M__flow
    (FlowJs : Flow_common.S)
    (ReactJs : React_kit.REACT)
    (ObjectKit : Object_kit.OBJECT)
    (SpeculationKit : Speculation_kit.OUTPUT)
    (SubtypingKit : Subtyping_kit.OUTPUT) =
struct
  open SubtypingKit

  module InstantiationHelper = struct
    let mk_targ = ImplicitTypeArgument.mk_targ

    let is_subtype = FlowJs.rec_flow_t

    let unify cx trace ~use_op (t1, t2) = FlowJs.rec_unify cx trace ~use_op ~unify_any:true t1 t2

    let reposition = FlowJs.reposition ?desc:None ?annot_loc:None
  end

  module InstantiationKit = Instantiation_kit (InstantiationHelper)
  module ImplicitInstantiationKit = Implicit_instantiation.Kit (FlowJs) (InstantiationHelper)
  include InstantiationKit

  let speculative_subtyping_succeeds cx l u =
    match
      SpeculationKit.try_singleton_throw_on_failure
        cx
        DepthTrace.dummy_trace
        l
        (UseT (unknown_use, u))
    with
    | exception Flow_js_utils.SpeculationSingletonError -> false
    | _ -> true

  (* get prop *)

  let perform_lookup_action cx trace propref p target_kind lreason ureason =
    let open FlowJs in
    function
    | LookupProp (use_op, up) -> rec_flow_p cx ~trace ~use_op lreason ureason propref (p, up)
    | SuperProp (use_op, lp) -> rec_flow_p cx ~trace ~use_op ureason lreason propref (lp, p)
    | ReadProp { use_op; obj_t; tout } ->
      let react_dro =
        match obj_t with
        | OpenT _ -> failwith "Expected concrete type"
        | DefT (_, InstanceT inst) -> inst.inst.inst_react_dro
        | DefT (_, ObjT o) -> o.flags.react_dro
        | _ -> None
      in
      FlowJs.perform_read_prop_action cx trace use_op propref p ureason react_dro tout
    | WriteProp { use_op; obj_t = _; tin; write_ctx; prop_tout; mode } -> begin
      match (Property.write_t_of_property_type ~ctx:write_ctx p, target_kind, mode) with
      | (Some t, IndexerProperty, Delete) ->
        (* Always OK to delete a property we found via an indexer *)
        let void = VoidT.why (reason_of_t t) in
        Base.Option.iter
          ~f:(fun prop_tout -> rec_flow_t cx trace ~use_op:unknown_use (void, prop_tout))
          prop_tout
      | (Some t, _, _) ->
        rec_flow cx trace (tin, UseT (use_op, t));
        Base.Option.iter
          ~f:(fun prop_tout -> rec_flow_t cx trace ~use_op:unknown_use (t, prop_tout))
          prop_tout
      | (None, _, _) ->
        let reason_prop = reason_of_propref propref in
        let prop_name = name_of_propref propref in
        let msg = Error_message.EPropNotWritable { reason_prop; prop_name; use_op } in
        add_output cx msg
    end
    | MatchProp { use_op; drop_generic = drop_generic_; prop_t = tin } -> begin
      match Property.read_t_of_property_type p with
      | Some t ->
        let t =
          if drop_generic_ then
            drop_generic t
          else
            t
        in
        rec_flow cx trace (tin, UseT (use_op, t))
      | None ->
        let reason_prop = reason_of_propref propref in
        let prop_name = name_of_propref propref in
        add_output cx (Error_message.EPropNotReadable { reason_prop; prop_name; use_op })
    end

  let mk_react_dro cx use_op dro t =
    let id = Eval.generate_id () in
    FlowJs.mk_possibly_evaluated_destructor cx use_op (reason_of_t t) t (ReactDRO dro) id

  let mk_hooklike cx use_op t =
    let id = Eval.generate_id () in
    FlowJs.mk_possibly_evaluated_destructor cx use_op (reason_of_t t) t MakeHooklike id

  module Get_prop_helper = struct
    type r = Type.tvar -> unit

    let error_type cx trace reason tout =
      FlowJs.rec_flow_t cx ~use_op:unknown_use trace (AnyT.error reason, OpenT tout)

    let return cx ~use_op trace t tout = FlowJs.rec_flow_t cx ~use_op trace (t, OpenT tout)

    let dict_read_check = FlowJs.rec_flow_t

    let reposition = FlowJs.reposition ?desc:None ?annot_loc:None

    let cg_lookup
        cx trace ~obj_t ~method_accessible t (reason_op, lookup_kind, propref, use_op, ids) tout =
      FlowJs.rec_flow
        cx
        trace
        ( t,
          LookupT
            {
              reason = reason_op;
              lookup_kind;
              try_ts_on_failure = [];
              propref;
              lookup_action = ReadProp { use_op; obj_t; tout };
              method_accessible;
              ids = Some ids;
              ignore_dicts = false;
            }
        )

    let cg_get_prop cx trace t (use_op, access_reason, id, (prop_reason, name)) tout =
      FlowJs.rec_flow
        cx
        trace
        ( t,
          GetPropT
            {
              use_op;
              reason = access_reason;
              id;
              from_annot = false;
              skip_optional = false;
              propref = mk_named_prop ~reason:prop_reason name;
              tout;
              hint = hint_unavailable;
            }
        )

    let mk_react_dro = mk_react_dro

    let mk_hooklike = mk_hooklike

    let prop_overlaps_with_indexer =
      Some
        (fun cx name reason_name key ->
          let name_t = type_of_key_name cx name reason_name in
          speculative_subtyping_succeeds cx name_t key)
  end

  module GetPropTKit = GetPropT_kit (Get_prop_helper)

  (** NOTE: Do not call this function directly. Instead, call the wrapper
      functions `rec_flow`, `join_flow`, or `flow_opt` (described below) inside
      this module, and the function `flow` outside this module. **)
  let rec __flow cx ((l : Type.t), (u : Type.use_t)) trace =
    if
      TypeUtil.ground_subtype_use_t
        ~on_singleton_eq:(Flow_js_utils.update_lit_type_from_annot cx)
        (l, u)
    then
      print_types_if_verbose cx trace (l, u)
    else if Cache.FlowConstraint.get cx (l, u) then
      print_types_if_verbose cx trace ~note:"(cached)" (l, u)
    else (
      print_types_if_verbose cx trace (l, u);

      (* limit recursion depth *)
      RecursionCheck.check cx trace;

      (* Check if this worker has been told to cancel *)
      check_canceled ();

      (* Expect that l is a def type. On the other hand, u may be a use type or a
         def type: the latter typically when we have annotations. *)
      if
        match l with
        | AnyT _ ->
          (* Either propagate AnyT through the use type, or short-circuit because any <: u trivially *)
          any_propagated cx trace l u
        | GenericT { bound; name; reason; id; no_infer } ->
          handle_generic cx trace ~no_infer bound reason id name u
        | _ -> false
        (* Either propagate AnyT through the def type, or short-circuit because l <: any trivially *)
      then
        ()
      else if
        match u with
        | UseT (use_op, (AnyT _ as any)) -> any_propagated_use cx trace use_op any l
        | _ -> false
      then
        ()
      else if
        match l with
        | DefT (_, EmptyT) -> empty_success u
        | _ -> false
      then
        ()
      else
        (* START OF PATTERN MATCH *)
        match (l, u) with
        (********)
        (* eval *)
        (********)
        | (EvalT (_, _, id1), UseT (_, EvalT (_, _, id2))) when Type.Eval.equal_id id1 id2 ->
          if Context.is_verbose cx then prerr_endline "EvalT ~> EvalT fast path"
        | (EvalT (t, TypeDestructorT (use_op', reason, d), id), _) ->
          let result = mk_type_destructor cx ~trace use_op' reason t d id in
          rec_flow cx trace (result, u)
        | (_, UseT (use_op, EvalT (t, TypeDestructorT (use_op', reason, d), id))) ->
          let result = mk_type_destructor cx ~trace use_op' reason t d id in
          rec_flow cx trace (result, ReposUseT (reason, false, use_op, l))
        (******************)
        (* process X ~> Y *)
        (******************)
        | (OpenT (_, tvar1), UseT (use_op, OpenT (r_upper, tvar2))) ->
          Context.add_array_or_object_literal_declaration_upper_bound
            cx
            tvar1
            (OpenT (r_upper, tvar2));
          let (id1, constraints1) = Context.find_constraints cx tvar1 in
          let (id2, constraints2) = Context.find_constraints cx tvar2 in
          (match (constraints1, constraints2) with
          | (Unresolved bounds1, Unresolved bounds2) ->
            if not_linked (id1, bounds1) (id2, bounds2) then (
              add_upper_edges ~new_use_op:use_op cx trace (id1, bounds1) (id2, bounds2);
              add_lower_edges cx trace ~new_use_op:use_op (id1, bounds1) (id2, bounds2);
              flows_across cx trace ~use_op bounds1.lower bounds2.upper
            )
          | (Unresolved bounds1, Resolved t2) ->
            let t2_use = flow_use_op cx unknown_use (UseT (use_op, t2)) in
            edges_and_flows_to_t cx trace (id1, bounds1) t2_use
          | (Unresolved bounds1, FullyResolved s2) ->
            let t2_use =
              flow_use_op cx unknown_use (UseT (use_op, Context.force_fully_resolved_tvar cx s2))
            in
            edges_and_flows_to_t cx trace (id1, bounds1) t2_use
          | (Resolved t1, Unresolved bounds2) ->
            edges_and_flows_from_t cx trace ~new_use_op:use_op t1 (id2, bounds2)
          | (FullyResolved s1, Unresolved bounds2) ->
            edges_and_flows_from_t
              cx
              trace
              ~new_use_op:use_op
              (Context.force_fully_resolved_tvar cx s1)
              (id2, bounds2)
          | (Resolved t1, Resolved t2) ->
            let t2_use = flow_use_op cx unknown_use (UseT (use_op, t2)) in
            rec_flow cx trace (t1, t2_use)
          | (Resolved t1, FullyResolved s2) ->
            let t2_use =
              flow_use_op cx unknown_use (UseT (use_op, Context.force_fully_resolved_tvar cx s2))
            in
            rec_flow cx trace (t1, t2_use)
          | (FullyResolved s1, Resolved t2) ->
            let t2_use = flow_use_op cx unknown_use (UseT (use_op, t2)) in
            rec_flow cx trace (Context.force_fully_resolved_tvar cx s1, t2_use)
          | (FullyResolved s1, FullyResolved s2) ->
            let t2_use =
              flow_use_op cx unknown_use (UseT (use_op, Context.force_fully_resolved_tvar cx s2))
            in
            rec_flow cx trace (Context.force_fully_resolved_tvar cx s1, t2_use))
        (******************)
        (* process Y ~> U *)
        (******************)
        | (OpenT (r, tvar), t2) ->
          if
            (* We have some simple tvar id based concretization. Bad cyclic types can only
             * come from indirections through OpenT, most of them are already defended with
             * Flow_js_utils.InvalidCyclicTypeValidation and turned to any, but there are gaps
             * (especially EvalT from type sig), so we defend it again here. *)
            match t2 with
            | ConcretizeT { reason = _; kind = _; seen; collector = _ } ->
              ISet.mem tvar !seen
              ||
              ( seen := ISet.add tvar !seen;
                false
              )
            | _ -> false
          then
            ()
          else
            let () =
              match t2 with
              | UseT (_, t2) ->
                Context.add_array_or_object_literal_declaration_upper_bound cx tvar t2
              | _ -> ()
            in
            let t2 =
              match desc_of_reason r with
              | RTypeParam _ -> mod_use_op_of_use_t (fun op -> Frame (ImplicitTypeParam, op)) t2
              | _ -> t2
            in
            let (id1, constraints1) = Context.find_constraints cx tvar in
            (match constraints1 with
            | Unresolved bounds1 -> edges_and_flows_to_t cx trace (id1, bounds1) t2
            | Resolved t1 -> rec_flow cx trace (t1, t2)
            | FullyResolved s1 -> rec_flow cx trace (Context.force_fully_resolved_tvar cx s1, t2))
        (******************)
        (* process L ~> X *)
        (******************)
        | (t1, UseT (use_op, OpenT (_, tvar))) ->
          let (id2, constraints2) = Context.find_constraints cx tvar in
          (match constraints2 with
          | Unresolved bounds2 ->
            edges_and_flows_from_t cx trace ~new_use_op:use_op t1 (id2, bounds2)
          | Resolved t2 -> rec_flow cx trace (t1, UseT (use_op, t2))
          | FullyResolved s2 ->
            rec_flow cx trace (t1, UseT (use_op, Context.force_fully_resolved_tvar cx s2)))
        (************************)
        (* Eval type destructor *)
        (************************)
        | (l, EvalTypeDestructorT { destructor_use_op; reason; repos; destructor; tout }) ->
          let l =
            match repos with
            | None -> l
            | Some (reason, use_desc) -> reposition_reason cx ~trace reason ~use_desc l
          in
          eval_destructor cx ~trace destructor_use_op reason l destructor tout
        (************)
        (* Subtyping *)
        (*************)
        | (_, UseT (use_op, u)) -> rec_sub_t cx use_op l u trace
        | ( UnionT (_, _),
            ConcretizeT { reason = _; kind = ConcretizeForSentinelPropTest; seen = _; collector }
          )
        (* For l.key !== sentinel when sentinel has a union type, don't split the union. This
           prevents a drastic blowup of cases which can cause perf problems. *)
        | ( UnionT (_, _),
            ConcretizeT
              {
                reason = _;
                kind = ConcretizeForPredicate ConcretizeRHSForLiteralPredicateTest;
                seen = _;
                collector;
              }
          ) ->
          TypeCollector.add collector l
        | ( UnionT (_, rep),
            ConcretizeT
              {
                reason = _;
                kind = ConcretizeForPredicate ConcretizeKeepOptimizedUnions;
                seen = _;
                collector;
              }
          )
          when UnionRep.is_optimized_finally rep ->
          TypeCollector.add collector l
        | ( UnionT _,
            ConcretizeT
              {
                reason = _;
                kind = ConcretizeForMatchArg { keep_unions = true };
                seen = _;
                collector;
              }
          ) ->
          TypeCollector.add collector l
        | (UnionT (_, urep), ConcretizeT _) -> flow_all_in_union cx trace urep u
        | (MaybeT (lreason, t), ConcretizeT _) ->
          let lreason = replace_desc_reason RNullOrVoid lreason in
          rec_flow cx trace (NullT.make lreason, u);
          rec_flow cx trace (VoidT.make lreason, u);
          rec_flow cx trace (t, u)
        | (OptionalT { reason = r; type_ = t; use_desc }, ConcretizeT _) ->
          rec_flow cx trace (VoidT.why_with_use_desc ~use_desc r, u);
          rec_flow cx trace (t, u)
        | (AnnotT (r, t, use_desc), ConcretizeT _) ->
          (* TODO: directly derive loc and desc from the reason of tvar *)
          let loc = loc_of_reason r in
          let desc =
            if use_desc then
              Some (desc_of_reason r)
            else
              None
          in
          rec_flow cx trace (reposition ~trace cx loc ?annot_loc:(annot_loc_of_reason r) ?desc t, u)
        | (DefT (reason, EmptyT), ConvertEmptyPropsToMixedT (_, tout)) ->
          rec_flow_t cx trace ~use_op:unknown_use (MixedT.make reason, tout)
        | (_, ConvertEmptyPropsToMixedT (_, tout)) ->
          rec_flow_t cx trace ~use_op:unknown_use (l, tout)
        (***************)
        (* annotations *)
        (***************)

        (* Special cases where we want to recursively concretize types within the
           lower bound. *)
        | (UnionT (r, rep), ReposUseT (reason, use_desc, use_op, l)) ->
          let rep =
            UnionRep.ident_map
              (annot ~in_implicit_instantiation:(Context.in_implicit_instantiation cx) use_desc)
              rep
          in
          let loc = loc_of_reason reason in
          let annot_loc = annot_loc_of_reason reason in
          let r = opt_annot_reason ?annot_loc @@ repos_reason loc r in
          let r =
            if use_desc then
              replace_desc_reason (desc_of_reason reason) r
            else
              r
          in
          rec_flow cx trace (l, UseT (use_op, UnionT (r, rep)))
        | (MaybeT (r, u), ReposUseT (reason, use_desc, use_op, l)) ->
          let loc = loc_of_reason reason in
          let annot_loc = annot_loc_of_reason reason in
          let r = opt_annot_reason ?annot_loc @@ repos_reason loc r in
          let r =
            if use_desc then
              replace_desc_reason (desc_of_reason reason) r
            else
              r
          in
          rec_flow
            cx
            trace
            ( l,
              UseT
                ( use_op,
                  MaybeT
                    ( r,
                      annot
                        ~in_implicit_instantiation:(Context.in_implicit_instantiation cx)
                        use_desc
                        u
                    )
                )
            )
        | ( OptionalT { reason = r; type_ = u; use_desc = use_desc_optional_t },
            ReposUseT (reason, use_desc, use_op, l)
          ) ->
          let loc = loc_of_reason reason in
          let annot_loc = annot_loc_of_reason reason in
          let r = opt_annot_reason ?annot_loc @@ repos_reason loc r in
          let r =
            if use_desc then
              replace_desc_reason (desc_of_reason reason) r
            else
              r
          in
          rec_flow
            cx
            trace
            ( l,
              UseT
                ( use_op,
                  OptionalT
                    {
                      reason = r;
                      type_ =
                        annot
                          ~in_implicit_instantiation:(Context.in_implicit_instantiation cx)
                          use_desc
                          u;
                      use_desc = use_desc_optional_t;
                    }
                )
            )
        | ( DefT
              ( r,
                RendersT
                  (StructuralRenders { renders_variant; renders_structural_type = UnionT (_, rep) })
              ),
            ReposUseT (reason, use_desc, use_op, l)
          ) ->
          let rep =
            UnionRep.ident_map
              (annot ~in_implicit_instantiation:(Context.in_implicit_instantiation cx) use_desc)
              rep
          in
          let loc = loc_of_reason reason in
          let annot_loc = annot_loc_of_reason reason in
          let r = opt_annot_reason ?annot_loc @@ repos_reason loc r in
          let r =
            if use_desc then
              replace_desc_reason (desc_of_reason reason) r
            else
              r
          in
          rec_flow
            cx
            trace
            ( l,
              UseT
                ( use_op,
                  DefT
                    ( r,
                      RendersT
                        (StructuralRenders
                           { renders_variant; renders_structural_type = UnionT (r, rep) }
                        )
                    )
                )
            )
        (* Waits for a def type to become concrete, repositions it as an upper UseT
           using the stored reason. This can be used to store a reason as it flows
           through a tvar. *)
        | (u_def, ReposUseT (reason, use_desc, use_op, l)) ->
          let u = reposition_reason cx ~trace reason ~use_desc u_def in
          rec_flow cx trace (l, UseT (use_op, u))
        (* The source component of an annotation flows out of the annotated
           site to downstream uses. *)
        | (AnnotT (r, t, use_desc), u) ->
          let t = reposition_reason ~trace cx r ~use_desc t in
          rec_flow cx trace (t, u)
        (***************************)
        (* type cast e.g. `(x: T)` *)
        (***************************)
        | (DefT (reason, EnumValueT enum_info), TypeCastT (use_op, cast_to_t)) ->
          rec_flow cx trace (cast_to_t, EnumCastT { use_op; enum = (reason, enum_info) })
        | (UnionT (_, rep), TypeCastT (use_op, (UnionT _ as u))) ->
          union_to_union cx trace use_op l rep u
        | (UnionT _, TypeCastT (use_op, AnnotT (r, t, use_desc))) ->
          rec_flow cx trace (t, ReposUseT (r, use_desc, use_op, l))
        | (UnionT (_, rep1), TypeCastT _) -> flow_all_in_union cx trace rep1 u
        | (_, TypeCastT (use_op, cast_to_t)) ->
          (match FlowJs.singleton_concrete_type_for_inspection cx (reason_of_t l) l with
          | DefT (reason, EnumValueT enum_info) ->
            rec_flow cx trace (cast_to_t, EnumCastT { use_op; enum = (reason, enum_info) })
          | _ -> rec_flow cx trace (l, UseT (use_op, cast_to_t)))
        (**********************************************************************)
        (* enum cast e.g. `(x: T)` where `x` is an `EnumValueT`                    *)
        (* We allow enums to be explicitly cast to their representation type. *)
        (* When we specialize `TypeCastT` when the LHS is an `EnumValueT`, the     *)
        (* `cast_to_t` of `TypeCastT` must then be resolved. So we call flow  *)
        (* with it on the LHS, and `EnumCastT` on the RHS. When we actually   *)
        (* turn this into a `UseT`, it must placed back on the RHS.           *)
        (**********************************************************************)
        | ( cast_to_t,
            EnumCastT
              {
                use_op;
                enum =
                  (_, (ConcreteEnum { representation_t; _ } | AbstractEnum { representation_t }));
              }
          )
          when TypeUtil.quick_subtype representation_t cast_to_t ->
          rec_flow cx trace (representation_t, UseT (use_op, cast_to_t))
        | (cast_to_t, EnumCastT { use_op; enum = (reason, enum) }) ->
          rec_flow cx trace (DefT (reason, EnumValueT enum), UseT (use_op, cast_to_t))
        (******************)
        (* Module exports *)
        (******************)
        | ( t,
            ConcretizeT
              {
                reason = _;
                kind = ConcretizeForCJSExtractNamedExportsAndTypeExports;
                seen = _;
                collector;
              }
          ) ->
          TypeCollector.add collector t
        (******************************)
        (* optional chaining - part A *)
        (******************************)
        | (DefT (_, VoidT), OptionalChainT { reason; lhs_reason; voided_out; t_out; _ }) ->
          CalleeRecorder.add_callee_use cx CalleeRecorder.Tast l t_out;
          Context.mark_optional_chain cx (loc_of_reason reason) lhs_reason ~useful:true;
          rec_flow_t ~use_op:unknown_use cx trace (l, voided_out)
        | (DefT (r, NullT), OptionalChainT { reason; lhs_reason; voided_out; t_out; _ }) ->
          CalleeRecorder.add_callee_use cx CalleeRecorder.Tast l t_out;
          let void =
            match desc_of_reason r with
            | RNull ->
              (* to avoid error messages like "null is incompatible with null",
                 give VoidT that arise from `null` annotations a new description
                 explaining why it is void and not null *)
              DefT (replace_desc_reason RVoidedNull r, VoidT)
            | _ -> DefT (r, VoidT)
          in
          Context.mark_optional_chain cx (loc_of_reason reason) lhs_reason ~useful:true;
          rec_flow_t ~use_op:unknown_use cx trace (void, voided_out)
        (***************************)
        (* optional indexed access *)
        (***************************)
        | (DefT (r, (EmptyT | VoidT | NullT)), OptionalIndexedAccessT { use_op; tout_tvar; _ }) ->
          rec_flow_t ~use_op cx trace (EmptyT.why r, OpenT tout_tvar)
        | ((MaybeT (_, t) | OptionalT { type_ = t; _ }), OptionalIndexedAccessT _) ->
          rec_flow cx trace (t, u)
        | (UnionT (_, rep), OptionalIndexedAccessT { use_op; reason; index; tout_tvar }) ->
          let (t0, (t1, ts)) = UnionRep.members_nel rep in
          let f t =
            Tvar.mk_no_wrap_where cx reason (fun tvar ->
                rec_flow
                  cx
                  trace
                  (t, OptionalIndexedAccessT { use_op; reason; index; tout_tvar = tvar })
            )
          in
          let rep = UnionRep.make (f t0) (f t1) (Base.List.map ts ~f) in
          rec_unify cx trace ~use_op:unknown_use (UnionT (reason, rep)) (OpenT tout_tvar)
        | (_, OptionalIndexedAccessT { use_op; reason; index; tout_tvar })
          when match l with
               | IntersectionT _ -> false
               | _ -> true ->
          let u =
            match index with
            | OptionalIndexedAccessStrLitIndex name ->
              let reason_op = replace_desc_reason (RProperty (Some name)) reason in
              GetPropT
                {
                  use_op;
                  reason;
                  id = None;
                  from_annot = true;
                  skip_optional = false;
                  propref = mk_named_prop ~reason:reason_op ~from_indexed_access:true name;
                  tout = tout_tvar;
                  hint = hint_unavailable;
                }
            | OptionalIndexedAccessTypeIndex key_t ->
              GetElemT
                {
                  use_op;
                  reason;
                  id = None;
                  from_annot = true;
                  skip_optional = false;
                  access_iterables = false;
                  key_t;
                  tout = tout_tvar;
                }
          in
          rec_flow cx trace (l, u)
        (*************)
        (* DRO and hooklike *)
        (*************)
        | (OptionalT ({ type_; _ } as o), DeepReadOnlyT (((r, _) as tout), (dro_loc, dro_type))) ->
          rec_flow_t
            cx
            trace
            ~use_op:unknown_use
            ( OptionalT
                {
                  o with
                  type_ =
                    Tvar.mk_no_wrap_where cx r (fun tvar ->
                        rec_flow cx trace (type_, DeepReadOnlyT (tvar, (dro_loc, dro_type)))
                    );
                },
              OpenT tout
            )
        | (OptionalT ({ type_; _ } as o), HooklikeT ((r, _) as tout)) ->
          rec_flow_t
            cx
            trace
            ~use_op:unknown_use
            ( OptionalT
                {
                  o with
                  type_ =
                    Tvar.mk_no_wrap_where cx r (fun tvar ->
                        rec_flow cx trace (type_, HooklikeT tvar)
                    );
                },
              OpenT tout
            )
        | (MaybeT (rl, t), DeepReadOnlyT (((r, _) as tout), (dro_loc, dro_type))) ->
          rec_flow_t
            cx
            trace
            ~use_op:unknown_use
            ( MaybeT
                ( rl,
                  Tvar.mk_no_wrap_where cx r (fun tvar ->
                      rec_flow cx trace (t, DeepReadOnlyT (tvar, (dro_loc, dro_type)))
                  )
                ),
              OpenT tout
            )
        | (MaybeT (rl, t), HooklikeT ((r, _) as tout)) ->
          rec_flow_t
            cx
            trace
            ~use_op:unknown_use
            ( MaybeT
                (rl, Tvar.mk_no_wrap_where cx r (fun tvar -> rec_flow cx trace (t, HooklikeT tvar))),
              OpenT tout
            )
        | (UnionT (reason, rep), DeepReadOnlyT (tout, (dro_loc, dro_type))) ->
          if not (UnionRep.is_optimized_finally rep) then
            UnionRep.optimize_enum_only ~flatten:(Type_mapper.union_flatten cx) rep;
          if Option.is_some (UnionRep.check_enum rep) then
            rec_flow_t ~use_op:unknown_use cx trace (l, OpenT tout)
          else
            let dro_union =
              map_union
                ~f:(fun cx trace t tout ->
                  let tout = open_tvar tout in
                  rec_flow cx trace (t, DeepReadOnlyT (tout, (dro_loc, dro_type))))
                cx
                trace
                rep
                reason
            in
            rec_flow_t ~use_op:unknown_use cx trace (dro_union, OpenT tout)
        | (UnionT (reason, rep), HooklikeT tout) ->
          if not (UnionRep.is_optimized_finally rep) then
            UnionRep.optimize_enum_only ~flatten:(Type_mapper.union_flatten cx) rep;
          if Option.is_some (UnionRep.check_enum rep) then
            rec_flow_t ~use_op:unknown_use cx trace (l, OpenT tout)
          else
            let hook_union =
              map_union
                ~f:(fun cx trace t tout ->
                  let tout = open_tvar tout in
                  rec_flow cx trace (t, HooklikeT tout))
                cx
                trace
                rep
                reason
            in
            rec_flow_t ~use_op:unknown_use cx trace (hook_union, OpenT tout)
        | (IntersectionT (reason, rep), DeepReadOnlyT (tout, (dro_loc, dro_type))) ->
          let dro_inter =
            map_inter
              ~f:(fun cx trace t tout ->
                let tout = open_tvar tout in
                rec_flow cx trace (t, DeepReadOnlyT (tout, (dro_loc, dro_type))))
              cx
              trace
              rep
              reason
          in
          rec_flow_t ~use_op:unknown_use cx trace (dro_inter, OpenT tout)
        | (DefT (r, ObjT ({ Type.flags; _ } as o)), DeepReadOnlyT (tout, (dro_loc, dro_type))) ->
          rec_flow_t
            ~use_op:unknown_use
            cx
            trace
            ( DefT
                (r, ObjT { o with Type.flags = { flags with react_dro = Some (dro_loc, dro_type) } }),
              OpenT tout
            )
        | ( DefT (r, ArrT (TupleAT { elem_t; elements; arity; inexact; react_dro = _ })),
            DeepReadOnlyT (tout, (dro_loc, dro_type))
          ) ->
          rec_flow_t
            ~use_op:unknown_use
            cx
            trace
            ( DefT
                ( r,
                  ArrT
                    (TupleAT
                       { elem_t; elements; arity; inexact; react_dro = Some (dro_loc, dro_type) }
                    )
                ),
              OpenT tout
            )
        | ( DefT (r, ArrT (ArrayAT { elem_t; tuple_view; react_dro = _ })),
            DeepReadOnlyT (tout, (dro_loc, dro_type))
          ) ->
          rec_flow_t
            ~use_op:unknown_use
            cx
            trace
            ( DefT (r, ArrT (ArrayAT { elem_t; tuple_view; react_dro = Some (dro_loc, dro_type) })),
              OpenT tout
            )
        | (DefT (r, ArrT (ROArrayAT (t, _))), DeepReadOnlyT (tout, (dro_loc, dro_type))) ->
          rec_flow_t
            ~use_op:unknown_use
            cx
            trace
            (DefT (r, ArrT (ROArrayAT (t, Some (dro_loc, dro_type)))), OpenT tout)
        | (DefT (r, InstanceT ({ inst; _ } as instance)), DeepReadOnlyT (tout, react_dro)) ->
          rec_flow_t
            ~use_op:unknown_use
            cx
            trace
            ( DefT
                (r, InstanceT { instance with inst = { inst with inst_react_dro = Some react_dro } }),
              OpenT tout
            )
        | (DefT (r, FunT (s, ({ effect_ = ArbitraryEffect; _ } as funtype))), HooklikeT tout) ->
          rec_flow_t
            ~use_op:unknown_use
            cx
            trace
            (DefT (r, FunT (s, { funtype with effect_ = AnyEffect })), OpenT tout)
        | ( DefT
              ( rp,
                PolyT
                  ( { t_out = DefT (r, FunT (s, ({ effect_ = ArbitraryEffect; _ } as funtype))); _ }
                  as poly
                  )
              ),
            HooklikeT tout
          ) ->
          rec_flow_t
            ~use_op:unknown_use
            cx
            trace
            ( DefT
                ( rp,
                  PolyT
                    { poly with t_out = DefT (r, FunT (s, { funtype with effect_ = AnyEffect })) }
                ),
              OpenT tout
            )
        | (DefT (r, ObjT ({ call_t = Some id; _ } as obj)), HooklikeT tout) ->
          let t =
            match Context.find_call cx id with
            | DefT (rf, FunT (s, ({ effect_ = ArbitraryEffect; _ } as funtype))) ->
              let call = DefT (rf, FunT (s, { funtype with effect_ = AnyEffect })) in
              let id = Context.make_call_prop cx call in
              DefT (r, ObjT { obj with call_t = Some id })
            | DefT
                ( rp,
                  PolyT
                    ( {
                        t_out = DefT (rf, FunT (s, ({ effect_ = ArbitraryEffect; _ } as funtype)));
                        _;
                      } as poly
                    )
                ) ->
              let call =
                DefT
                  ( rp,
                    PolyT
                      {
                        poly with
                        t_out = DefT (rf, FunT (s, { funtype with effect_ = AnyEffect }));
                      }
                  )
              in
              let id = Context.make_call_prop cx call in
              DefT (r, ObjT { obj with call_t = Some id })
            | _ -> l
          in
          rec_flow_t ~use_op:unknown_use cx trace (t, OpenT tout)
        | ( (IntersectionT _ | OpaqueT _ | DefT (_, PolyT _)),
            (DeepReadOnlyT (tout, _) | HooklikeT tout)
          ) ->
          rec_flow_t ~use_op:unknown_use cx trace (l, OpenT tout)
        | ( DefT
              ( r,
                InstanceT
                  {
                    inst =
                      {
                        inst_react_dro = Some (dro_loc, dro_type);
                        class_id;
                        type_args = [(_, _, key_t, _); (_, _, val_t, _)];
                        _;
                      };
                    _;
                  }
              ),
            ( GetKeysT _ | GetValuesT _ | GetDictValuesT _ | CallT _ | LookupT _ | SetPropT _
            | GetPropT _ | MethodT _ | ObjRestT _ | SetElemT _ | GetElemT _ | CallElemT _ | BindT _
              )
          )
          when is_builtin_class_id "Map" class_id cx -> begin
          match u with
          | MethodT (use_op, _, reason, Named { name = OrdinaryName name; _ }, _)
          | GetPropT { propref = Named { name = OrdinaryName name; _ }; use_op; reason; _ }
            when match name with
                 | "clear"
                 | "delete"
                 | "set" ->
                   true
                 | _ -> false ->
            add_output
              cx
              (Error_message.EPropNotReadable
                 {
                   reason_prop = reason;
                   prop_name = Some (OrdinaryName name);
                   use_op = Frame (ReactDeepReadOnly (dro_loc, dro_type), use_op);
                 }
              )
          | _ ->
            let key_t = mk_react_dro cx unknown_use (dro_loc, dro_type) key_t in
            let val_t = mk_react_dro cx unknown_use (dro_loc, dro_type) val_t in
            let ro_map = get_builtin_typeapp ~use_desc:true cx r "$ReadOnlyMap" [key_t; val_t] in
            let u =
              TypeUtil.mod_use_op_of_use_t
                (fun use_op -> Frame (ReactDeepReadOnly (dro_loc, dro_type), use_op))
                u
            in
            rec_flow cx trace (ro_map, u)
        end
        | ( DefT
              ( r,
                InstanceT
                  {
                    inst =
                      {
                        inst_react_dro = Some (dro_loc, dro_type);
                        class_id;
                        type_args = [(_, _, elem_t, _)];
                        _;
                      };
                    _;
                  }
              ),
            ( GetKeysT _ | GetValuesT _ | GetDictValuesT _ | CallT _ | LookupT _ | SetPropT _
            | GetPropT _ | MethodT _ | ObjRestT _ | SetElemT _ | GetElemT _ | CallElemT _ | BindT _
              )
          )
          when is_builtin_class_id "Set" class_id cx -> begin
          match u with
          | MethodT (use_op, _, reason, Named { name = OrdinaryName name; _ }, _)
          | GetPropT { propref = Named { name = OrdinaryName name; _ }; use_op; reason; _ }
            when match name with
                 | "add"
                 | "clear"
                 | "delete" ->
                   true
                 | _ -> false ->
            add_output
              cx
              (Error_message.EPropNotReadable
                 {
                   reason_prop = reason;
                   prop_name = Some (OrdinaryName name);
                   use_op = Frame (ReactDeepReadOnly (dro_loc, dro_type), use_op);
                 }
              )
          | _ ->
            let elem_t = mk_react_dro cx unknown_use (dro_loc, dro_type) elem_t in
            let ro_set = get_builtin_typeapp ~use_desc:true cx r "$ReadOnlySet" [elem_t] in
            let u =
              TypeUtil.mod_use_op_of_use_t
                (fun use_op -> Frame (ReactDeepReadOnly (dro_loc, dro_type), use_op))
                u
            in
            rec_flow cx trace (ro_set, u)
        end
        (***************)
        (* maybe types *)
        (***************)

        (* The type maybe(T) is the same as null | undefined | UseT *)
        | (DefT (r, (NullT | VoidT)), FilterMaybeT (use_op, tout)) ->
          rec_flow_t cx trace ~use_op (EmptyT.why r, tout)
        | (DefT (r, MixedT Mixed_everything), FilterMaybeT (use_op, tout)) ->
          rec_flow_t cx trace ~use_op (DefT (r, MixedT Mixed_non_maybe), tout)
        | (OptionalT { reason = _; type_ = tout; use_desc = _ }, FilterMaybeT _)
        | (MaybeT (_, tout), FilterMaybeT _) ->
          rec_flow cx trace (tout, u)
        | (DefT (_, EmptyT), FilterMaybeT (use_op, tout)) -> rec_flow_t cx trace ~use_op (l, tout)
        | (MaybeT _, ReposLowerT { reason = reason_op; use_desc; use_t = u }) ->
          (* Don't split the maybe type into its constituent members. Instead,
             reposition the entire maybe type. *)
          let loc = loc_of_reason reason_op in
          let desc =
            if use_desc then
              Some (desc_of_reason reason_op)
            else
              None
          in
          rec_flow cx trace (reposition cx ~trace loc ?desc l, u)
        | (MaybeT _, ResolveUnionT { reason; resolved; unresolved; upper; id }) ->
          resolve_union cx trace reason id resolved unresolved l upper
        | (MaybeT (reason, t), _)
          when match u with
               | ConditionalT { distributive_tparam_name; _ } ->
                 Option.is_some distributive_tparam_name
               | _ -> true ->
          let reason = replace_desc_reason RNullOrVoid reason in
          let t = push_type_alias_reason reason t in
          rec_flow cx trace (NullT.make reason, u);
          rec_flow cx trace (VoidT.make reason, u);
          rec_flow cx trace (t, u)
        (******************)
        (* optional types *)
        (******************)

        (* The type optional(T) is the same as undefined | UseT *)
        | (DefT (r, VoidT), FilterOptionalT (use_op, tout)) ->
          rec_flow_t cx trace ~use_op (EmptyT.why r, tout)
        | (OptionalT { reason = _; type_ = tout; use_desc = _ }, FilterOptionalT _) ->
          rec_flow cx trace (tout, u)
        | (OptionalT _, ReposLowerT { reason; use_desc; use_t = u }) ->
          (* Don't split the optional type into its constituent members. Instead,
             reposition the entire optional type. *)
          rec_flow cx trace (reposition_reason cx ~trace reason ~use_desc l, u)
        | (OptionalT _, ResolveUnionT { reason; resolved; unresolved; upper; id }) ->
          resolve_union cx trace reason id resolved unresolved l upper
        | (OptionalT { reason = _; type_ = t; use_desc = _ }, ExtractReactRefT _) ->
          rec_flow cx trace (t, u)
        | (OptionalT { reason = r; type_ = t; use_desc }, _)
          when match u with
               | ConditionalT { distributive_tparam_name; _ } ->
                 Option.is_some distributive_tparam_name
               | _ -> true ->
          let void = VoidT.why_with_use_desc ~use_desc r in
          rec_flow cx trace (void, u);
          rec_flow cx trace (t, u)
        | (_, ExtractReactRefT (reason, tout)) ->
          let t_ = ImplicitInstantiationKit.run_ref_extractor cx ~use_op:unknown_use ~reason l in
          rec_flow_t cx ~use_op:unknown_use trace (t_, tout)
        (*********************)
        (* type applications *)
        (*********************)

        (* Sometimes a polymorphic class may have a polymorphic method whose return
           type is a type application on the same polymorphic class, possibly
           expanded. See Array#map or Array#concat, e.g. It is not unusual for
           programmers to reuse variables, assigning the result of a method call on
           a variable to itself, in which case we could get into cycles of unbounded
           instantiation. We use caching to cut these cycles. Caching relies on
           reasons (see module Cache.I). This is OK since intuitively, there should
           be a unique instantiation of a polymorphic definition for any given use
           of it in the source code.

           In principle we could use caching more liberally, but we don't because
           not all use types arise from source code, and because reasons are not
           perfect. Indeed, if we tried caching for all use types, we'd lose
           precision and report spurious errors.

           Also worth noting is that we can never safely cache def types. This is
           because substitution of type parameters in def types does not affect
           their reasons, so we'd trivially lose precision. *)
        | (ThisTypeAppT (reason_tapp, c, this, ts), _) ->
          let reason_op = reason_of_use_t u in
          instantiate_this_class cx trace ~reason_op ~reason_tapp c ts this (Upper u)
        | (TypeAppT _, ReposLowerT { reason; use_desc; use_t = u }) ->
          rec_flow cx trace (reposition_reason cx ~trace reason ~use_desc l, u)
        | ( TypeAppT { reason = reason_tapp; use_op; type_; targs; from_value; use_desc },
            MethodT (_, _, _, _, _)
          )
        | ( TypeAppT { reason = reason_tapp; use_op; type_; targs; from_value; use_desc },
            PrivateMethodT (_, _, _, _, _, _, _)
          ) ->
          let reason_op = reason_of_use_t u in
          let t =
            mk_typeapp_instance_annot
              cx
              ~trace
              ~use_op
              ~reason_op
              ~reason_tapp
              ~from_value
              ~use_desc
              type_
              targs
          in
          rec_flow cx trace (t, u)
        (* This is the second step in checking a TypeAppT (c, ts) ~> TypeAppT (c, ts).
         * The first step is in subtyping_kit.ml, and concretizes the c for our
         * upper bound TypeAppT.
         *
         * When we have done that, then we want to concretize the lower bound. We
         * flip all our arguments to ConcretizeTypeAppsT and set the final element
         * to false to signal that we have concretized the upper bound's c.
         *
         * If the upper bound's c is not a PolyT then we will fall down to an
         * incompatible use error. *)
        | ( (DefT (_, PolyT _) as c2),
            ConcretizeTypeAppsT (use_op, (ts2, fv2, op2, r2), (c1, ts1, fv1, op1, r1), true)
          ) ->
          rec_flow
            cx
            trace
            (c1, ConcretizeTypeAppsT (use_op, (ts1, fv1, op1, r1), (c2, ts2, fv2, op2, r2), false))
        (* When we have concretized the c for our lower bound TypeAppT then we can
         * finally run our TypeAppT ~> TypeAppT logic. If we have referentially the
         * same PolyT for each TypeAppT then we want to check the type arguments
         * only. (Checked in the when condition.) If we do not have the same PolyT
         * for each TypeAppT then we want to expand our TypeAppTs and compare the
         * expanded results.
         *
         * If the lower bound's c is not a PolyT then we will fall down to an
         * incompatible use error.
         *
         * The upper bound's c should always be a PolyT here since we could not have
         * made it here if it was not given the logic of our earlier case. *)
        | ( DefT (_, PolyT { tparams_loc; tparams; id = id1; t_out; _ }),
            ConcretizeTypeAppsT
              (use_op, (ts1, fv1, _, r1), (DefT (_, PolyT { id = id2; _ }), ts2, fv2, _, r2), false)
          )
          when id1 = id2
               && List.length ts1 = List.length ts2
               && (not (wraps_utility_type cx t_out))
               && fv1 = fv2 ->
          let targs = List.map2 (fun t1 t2 -> (t1, t2)) ts1 ts2 in
          type_app_variance_check cx trace use_op r1 r2 targs tparams_loc tparams
        (* This is the case which implements the expansion for our
         * TypeAppT (c, ts) ~> TypeAppT (c, ts) when the cs are unequal. *)
        | ( DefT (_, PolyT { tparams_loc = tparams_loc1; tparams = xs1; t_out = t1; id = id1 }),
            ConcretizeTypeAppsT
              ( use_op,
                (ts1, fv1, op1, r1),
                ( DefT (_, PolyT { tparams_loc = tparams_loc2; tparams = xs2; t_out = t2; id = id2 }),
                  ts2,
                  fv2,
                  op2,
                  r2
                ),
                false
              )
          ) ->
          let (op1, op2) =
            match root_of_use_op use_op with
            | UnknownUse -> (op1, op2)
            | _ -> (use_op, use_op)
          in
          let t1 =
            mk_typeapp_instance_of_poly
              cx
              trace
              ~use_op:op2
              ~reason_op:r2
              ~reason_tapp:r1
              ~from_value:fv1
              id1
              tparams_loc1
              xs1
              t1
              ts1
          in
          let t2 =
            mk_typeapp_instance_of_poly
              cx
              trace
              ~use_op:op1
              ~reason_op:r1
              ~reason_tapp:r2
              ~from_value:fv2
              id2
              tparams_loc2
              xs2
              t2
              ts2
          in
          rec_flow cx trace (t1, UseT (use_op, t2))
        | (TypeAppT { reason = reason_tapp; use_op; type_; targs; from_value; use_desc = _ }, _) ->
          let reason_op = reason_of_use_t u in
          if TypeAppExpansion.push_unless_loop cx `Lower (type_, targs) then (
            let t =
              mk_typeapp_instance_annot
                cx
                ~trace
                ~use_op
                ~reason_op
                ~reason_tapp
                ~from_value
                type_
                targs
            in
            rec_flow cx trace (t, u);
            TypeAppExpansion.pop cx
          )
        (* Concretize types for type inspection purpose up to this point. The rest are
           recorded as lower bound to the target tvar. *)
        | (t, ConcretizeT { reason = _; kind = ConcretizeForImportsExports; seen = _; collector })
          ->
          TypeCollector.add collector t
        (* Namespace and type qualification *)
        | ( NamespaceT { namespace_symbol = _; values_type; types_tmap },
            GetTypeFromNamespaceT
              { reason = reason_op; use_op; prop_ref = (prop_ref_reason, prop_name); tout }
          ) ->
          (match
             NameUtils.Map.find_opt prop_name (Context.find_props cx types_tmap)
             |> Base.Option.bind ~f:Type.Property.read_t
           with
          | Some prop ->
            let t = reposition cx ~trace (loc_of_reason reason_op) prop in
            rec_flow_t cx ~use_op trace (t, OpenT tout)
          | None ->
            rec_flow
              cx
              trace
              ( values_type,
                GetPropT
                  {
                    use_op;
                    reason = reason_op;
                    id = None;
                    from_annot = false;
                    skip_optional = false;
                    propref =
                      Named
                        { reason = prop_ref_reason; name = prop_name; from_indexed_access = false };
                    tout;
                    hint = hint_unavailable;
                  }
              ))
        | ( _,
            GetTypeFromNamespaceT
              { reason = reason_op; use_op; prop_ref = (prop_ref_reason, prop_name); tout }
          ) ->
          rec_flow
            cx
            trace
            ( l,
              GetPropT
                {
                  use_op;
                  reason = reason_op;
                  id = None;
                  from_annot = false;
                  skip_optional = false;
                  propref =
                    Named
                      { reason = prop_ref_reason; name = prop_name; from_indexed_access = false };
                  tout;
                  hint = hint_unavailable;
                }
            )
        (* unwrap namespace type into object type, drop all information about types in the namespace *)
        | (NamespaceT { namespace_symbol = _; values_type; types_tmap = _ }, _) ->
          rec_flow cx trace (values_type, u)
        (***************************************)
        (* transform values to type references *)
        (***************************************)
        | (l, ValueToTypeReferenceT (use_op, reason_op, type_t_kind, tout)) ->
          let t =
            Flow_js_utils.ValueToTypeReferenceTransform.run_on_concrete_type
              cx
              ~use_op
              reason_op
              type_t_kind
              l
          in
          rec_unify cx trace ~use_op t tout
        (**********************)
        (*    opaque types    *)
        (**********************)

        (* Repositioning should happen before opaque types are considered so that we can
         * have the "most recent" location when we do look at the opaque type *)
        | (OpaqueT _, ReposLowerT { reason; use_desc; use_t = u }) ->
          rec_flow cx trace (reposition_reason cx ~trace reason ~use_desc l, u)
        (* Store the opaque type when doing `ToStringT`, so we can use that
           rather than just `string` if the underlying is `string`. *)
        | ( OpaqueT
              (_, { opaque_id = Opaque.UserDefinedOpaqueTypeId opaque_id; underlying_t = Some t; _ }),
            ToStringT { reason; t_out; _ }
          )
          when ALoc.source (opaque_id :> ALoc.t) = Some (Context.file cx) ->
          rec_flow cx trace (t, ToStringT { orig_t = Some l; reason; t_out })
        (* Use the upper bound of OpaqueT if it's available, for operations that must be
         * performed on some concretized types. *)
        | (OpaqueT (_, { upper_t = Some t; _ }), ObjKitT _)
        | (OpaqueT (_, { upper_t = Some t; _ }), ReactKitT _) ->
          rec_flow cx trace (t, u)
        (* Store the opaque type when doing `ToStringT`, so we can use that
           rather than just `string` if the supertype is `string`. *)
        | (OpaqueT (_, { upper_t = Some t; _ }), ToStringT { reason; t_out; _ }) ->
          rec_flow cx trace (t, ToStringT { orig_t = Some l; reason; t_out })
        (* If the type is still in the same file it was defined, we allow it to
         * expose its underlying type information *)
        | ( OpaqueT
              (_, { opaque_id = Opaque.UserDefinedOpaqueTypeId opaque_id; underlying_t = Some t; _ }),
            _
          )
          when ALoc.source (opaque_id :> ALoc.t) = Some (Context.file cx) ->
          rec_flow cx trace (t, u)
        (*****************************************************)
        (* keys (NOTE: currently we only support string keys *)
        (*****************************************************)
        | (KeysT _, ToStringT { t_out; _ }) ->
          (* KeysT outputs strings, so we know ToStringT will be a no-op. *)
          rec_flow cx trace (l, t_out)
        | (KeysT (reason1, o1), _) ->
          (* flow all keys of o1 to u *)
          rec_flow cx trace (o1, GetKeysT (reason1, u));
          (match u with
          | UseT (_, t) -> Tvar_resolver.resolve cx t
          | _ -> ())
        (* Concretize types for type inspection purpose up to this point. The rest are
           recorded as lower bound to the target tvar. *)
        | (t, ConcretizeT { reason = _; kind = ConcretizeForInspection; seen = _; collector }) ->
          TypeCollector.add collector t
        (* helpers *)
        | ( DefT (reason_o, ObjT { props_tmap = mapr; flags; _ }),
            HasOwnPropT (use_op, reason_op, key)
          ) ->
          (match (drop_generic key, flags.obj_kind) with
          (* If we have a literal string and that property exists *)
          | (DefT (_, SingletonStrT { value = x; _ }), _) when Context.has_prop cx mapr x -> ()
          (* If we have a dictionary, try that next *)
          | (_, Indexed { key = expected_key; _ }) ->
            rec_flow_t ~use_op cx trace (mod_reason_of_t (Fun.const reason_op) key, expected_key)
          | _ ->
            let (prop, suggestion) =
              match drop_generic key with
              | DefT (_, SingletonStrT { value = prop; _ }) ->
                (Some prop, prop_typo_suggestion cx [mapr] (display_string_of_name prop))
              | _ -> (None, None)
            in
            let err =
              Error_message.EPropNotFound
                {
                  prop_name = prop;
                  reason_prop = reason_op;
                  reason_obj = reason_o;
                  use_op;
                  suggestion;
                }
            in
            add_output cx err)
        | ( DefT (reason_o, InstanceT { inst; _ }),
            HasOwnPropT
              ( use_op,
                reason_op,
                ( ( DefT (_, SingletonStrT { value = x; _ })
                  | GenericT { bound = DefT (_, SingletonStrT { value = x; _ }); _ } ) as key
                )
              )
          ) ->
          let own_props = Context.find_props cx inst.own_props in
          (match NameUtils.Map.find_opt x own_props with
          | Some _ -> ()
          | None ->
            let err =
              Error_message.EPropNotFound
                {
                  prop_name = Some x;
                  reason_prop = reason_op;
                  reason_obj = reason_o;
                  use_op;
                  suggestion = prop_typo_suggestion cx [inst.own_props] (display_string_of_name x);
                }
            in
            (match inst.inst_dict with
            | Some { key = dict_key; _ } ->
              rec_flow_t ~use_op cx trace (mod_reason_of_t (Fun.const reason_op) key, dict_key)
            | None -> add_output cx err))
        | (DefT (reason_o, InstanceT _), HasOwnPropT (use_op, reason_op, _)) ->
          let err =
            Error_message.EPropNotFound
              {
                prop_name = None;
                reason_prop = reason_op;
                reason_obj = reason_o;
                use_op;
                suggestion = None;
              }
          in
          add_output cx err
        (* AnyT has every prop *)
        | (AnyT _, HasOwnPropT _) -> ()
        | (DefT (_, ObjT { flags; props_tmap; _ }), GetKeysT (reason_op, keys)) ->
          let dict_t = Obj_type.get_dict_opt flags.obj_kind in
          (* flow the union of keys of l to keys *)
          let keylist =
            Flow_js_utils.keylist_of_props (Context.find_props cx props_tmap) reason_op
          in
          rec_flow cx trace (union_of_ts reason_op keylist, keys);
          Base.Option.iter dict_t ~f:(fun { key; _ } ->
              rec_flow cx trace (key, ToStringT { orig_t = None; reason = reason_op; t_out = keys })
          )
        | (DefT (_, InstanceT { inst; _ }), GetKeysT (reason_op, keys)) ->
          (* methods are not enumerable, so only walk fields *)
          let own_props = Context.find_props cx inst.own_props in
          let keylist = Flow_js_utils.keylist_of_props own_props reason_op in
          rec_flow cx trace (union_of_ts reason_op keylist, keys);
          (match inst.inst_dict with
          | Some { key = dict_key; _ } ->
            rec_flow
              cx
              trace
              (dict_key, ToStringT { orig_t = None; reason = reason_op; t_out = keys })
          | None -> ())
        | (AnyT _, GetKeysT (reason_op, keys)) -> rec_flow cx trace (StrModuleT.why reason_op, keys)
        (* In general, typechecking is monotonic in the sense that more constraints
           produce more errors. However, sometimes we may want to speculatively try
           out constraints, backtracking if they produce errors (and removing the
           errors produced). This is useful to typecheck union types and
           intersection types: see below. **)
        (* NOTE: It is important that any def type that simplifies to a union or
           intersection of other def types be processed before we process unions
           and intersections: otherwise we may get spurious errors. **)

        (**********)
        (* values *)
        (**********)
        | (DefT (_, ObjT o), GetValuesT (reason, values)) ->
          let values_l = Flow_js_utils.get_values_type_of_obj_t cx o reason in
          rec_flow_t ~use_op:unknown_use cx trace (values_l, values)
        | ( DefT (_, InstanceT { inst = { own_props; inst_dict; _ }; _ }),
            GetValuesT (reason, values)
          ) ->
          let values_l =
            Flow_js_utils.get_values_type_of_instance_t cx own_props inst_dict reason
          in
          rec_flow_t ~use_op:unknown_use cx trace (values_l, values)
        | (DefT (_, ArrT arr), GetValuesT (reason, t_out)) ->
          let elem_t = elemt_of_arrtype arr in
          rec_flow_t ~use_op:unknown_use cx trace (mod_reason_of_t (Fun.const reason) elem_t, t_out)
        (* Any will always be ok *)
        | (AnyT (_, src), GetValuesT (reason, values)) ->
          rec_flow_t ~use_op:unknown_use cx trace (AnyT.why src reason, values)
        (***********************************************)
        (* Values of a dictionary - `mixed` otherwise. *)
        (***********************************************)
        | ( DefT
              ( _,
                ObjT
                  { flags = { obj_kind = Indexed { value; dict_polarity; _ }; _ }; props_tmap; _ }
              ),
            GetDictValuesT (_, result)
          )
          when Context.find_props cx props_tmap |> NameUtils.Map.is_empty
               && Polarity.compat (dict_polarity, Polarity.Positive) ->
          rec_flow cx trace (value, result)
        | (DefT (_, ObjT _), GetDictValuesT (reason, result))
        | (DefT (_, InstanceT _), GetDictValuesT (reason, result)) ->
          rec_flow cx trace (MixedT.why reason, result)
        (* Any will always be ok *)
        | (AnyT (_, src), GetDictValuesT (reason, result)) ->
          rec_flow cx trace (AnyT.why src reason, result)
        (********************************)
        (* union and intersection types *)
        (********************************)
        (* We don't want to miss any union optimizations because of unevaluated type destructors, so
           if our union contains any of these problematic types, we force it to resolve its elements before
           considering its upper bound *)
        | (_, ResolveUnionT { reason; resolved; unresolved; upper; id }) ->
          resolve_union cx trace reason id resolved unresolved l upper
        | (UnionT (reason, rep), FilterMaybeT (use_op, tout)) ->
          let quick_subtype = TypeUtil.quick_subtype in
          let void = VoidT.why reason in
          let null = NullT.why reason in
          let filter_void t = quick_subtype t void in
          let filter_null t = quick_subtype t null in
          let filter_null_and_void t = filter_void t || filter_null t in
          begin
            match UnionRep.check_enum rep with
            | Some _ ->
              rec_flow_t
                ~use_op
                cx
                trace
                (remove_predicate_from_union reason cx filter_null_and_void rep, tout)
            | None ->
              let non_maybe_union =
                map_union
                  ~f:(fun cx trace t tout -> rec_flow cx trace (t, FilterMaybeT (use_op, tout)))
                  cx
                  trace
                  rep
                  reason
              in
              rec_flow_t ~use_op cx trace (non_maybe_union, tout)
          end
        | (UnionT (reason, rep), upper) when UnionRep.members rep |> List.exists is_union_resolvable
          ->
          iter_resolve_union ~f:rec_flow cx trace reason rep upper
        (* Don't split the union type into its constituent members. Instead,
           reposition the entire union type. *)
        | (UnionT _, ReposLowerT { reason; use_desc; use_t = u }) ->
          rec_flow cx trace (reposition_reason cx ~trace reason ~use_desc l, u)
        | (UnionT _, SealGenericT { reason = _; id; name; cont; no_infer }) ->
          let reason = reason_of_t l in
          continue cx trace (GenericT { reason; id; name; bound = l; no_infer }) cont
        | (UnionT _, ObjKitT (use_op, reason, resolve_tool, tool, tout)) ->
          ObjectKit.run trace cx use_op reason resolve_tool tool ~tout l
        (* Shortcut for indexed accesses with the same type as the dict key. *)
        | ( UnionT _,
            ElemT
              {
                use_op;
                reason;
                obj = DefT (_, ObjT { flags = { react_dro; _ } as flags; _ }) as _obj;
                action =
                  ReadElem { id = _; from_annot = _; skip_optional = _; access_iterables = _; tout };
              }
          )
          when let dict = Obj_type.get_dict_opt flags.obj_kind in
               match dict with
               | Some { key; dict_polarity; _ } ->
                 Concrete_type_eq.eq cx l key && Polarity.compat (dict_polarity, Polarity.Positive)
               | None -> false ->
          let { value; _ } = Base.Option.value_exn (Obj_type.get_dict_opt flags.obj_kind) in
          let value = reposition_reason cx ~trace reason value in
          let value =
            match react_dro with
            | Some dro -> mk_react_dro cx (Frame (ReactDeepReadOnly dro, use_op)) dro value
            | None -> value
          in
          rec_flow_t cx trace ~use_op:unknown_use (value, OpenT tout)
        | ( UnionT (_, rep),
            ElemT
              {
                use_op;
                reason;
                obj;
                action = ReadElem { id; from_annot = true; skip_optional; access_iterables; tout };
              }
          ) ->
          let reason = update_desc_reason invalidate_rtype_alias reason in
          let (t0, (t1, ts)) = UnionRep.members_nel rep in
          let f t =
            Tvar.mk_no_wrap_where cx reason (fun tvar ->
                let action =
                  ReadElem { id; from_annot = true; skip_optional; access_iterables; tout = tvar }
                in
                rec_flow cx trace (t, ElemT { use_op; reason; obj; action })
            )
          in
          let rep = UnionRep.make (f t0) (f t1) (Base.List.map ts ~f) in
          rec_flow_t cx trace ~use_op:unknown_use (UnionT (reason, rep), OpenT tout)
        | (UnionT (_, rep), _)
          when match u with
               | WriteComputedObjPropCheckT _
               | ExtractReactRefT _ ->
                 false
               | ConditionalT { distributive_tparam_name; _ } ->
                 Option.is_some distributive_tparam_name
               | _ -> true ->
          flow_all_in_union cx trace rep u
        | (_, FilterOptionalT (use_op, u)) -> rec_flow_t cx trace ~use_op (l, u)
        | (_, FilterMaybeT (use_op, u)) -> rec_flow_t cx trace ~use_op (l, u)
        (* special treatment for some operations on intersections: these
           rules fire for particular UBs whose constraints can (or must)
           be resolved against intersection LBs as a whole, instead of
           by decomposing the intersection into its parts.
        *)
        (* lookup of properties **)
        | ( IntersectionT (_, rep),
            LookupT
              {
                reason;
                lookup_kind;
                try_ts_on_failure;
                propref;
                lookup_action;
                ids;
                method_accessible;
                ignore_dicts;
              }
          ) ->
          let ts = InterRep.members rep in
          assert (ts <> []);

          (* Since s could be in any object type in the list ts, we try to look it
             up in the first element of ts, pushing the rest into the list
             try_ts_on_failure (see below). *)
          rec_flow
            cx
            trace
            ( List.hd ts,
              LookupT
                {
                  reason;
                  lookup_kind;
                  try_ts_on_failure = List.tl ts @ try_ts_on_failure;
                  propref;
                  lookup_action;
                  ids;
                  method_accessible;
                  ignore_dicts;
                }
            )
        (* Cases of an intersection need to produce errors on non-existent
           properties instead of a default, so that other cases may be tried
           instead and succeed. *)
        | ( IntersectionT _,
            GetPropT { use_op; reason; id = Some _; from_annot; skip_optional; propref; tout; hint }
          ) ->
          rec_flow
            cx
            trace
            ( l,
              GetPropT { use_op; reason; id = None; from_annot; skip_optional; propref; tout; hint }
            )
        | (IntersectionT _, TestPropT { use_op; reason; id = _; propref; tout; hint }) ->
          rec_flow
            cx
            trace
            ( l,
              GetPropT
                {
                  use_op;
                  reason;
                  id = None;
                  from_annot = false;
                  skip_optional = false;
                  propref;
                  tout;
                  hint;
                }
            )
        | ( IntersectionT _,
            OptionalChainT
              ( {
                  t_out =
                    GetPropT
                      {
                        use_op;
                        reason;
                        id = Some _;
                        from_annot;
                        skip_optional;
                        propref;
                        tout;
                        hint;
                      };
                  _;
                } as opt_chain
              )
          ) ->
          rec_flow
            cx
            trace
            ( l,
              OptionalChainT
                {
                  opt_chain with
                  t_out =
                    GetPropT
                      { use_op; reason; id = None; from_annot; skip_optional; propref; tout; hint };
                }
            )
        | ( IntersectionT _,
            OptionalChainT
              ({ t_out = TestPropT { use_op; reason; id = _; propref; tout; hint }; _ } as opt_chain)
          ) ->
          rec_flow
            cx
            trace
            ( l,
              OptionalChainT
                {
                  opt_chain with
                  t_out =
                    GetPropT
                      {
                        use_op;
                        reason;
                        id = None;
                        from_annot = false;
                        skip_optional = false;
                        propref;
                        tout;
                        hint;
                      };
                }
            )
        | (IntersectionT _, DestructuringT (reason, kind, selector, tout, id)) ->
          destruct cx ~trace reason kind l selector tout id
        (* extends **)
        | (IntersectionT (_, rep), ExtendsUseT (use_op, reason, try_ts_on_failure, l, u)) ->
          let (t, ts) = InterRep.members_nel rep in
          let try_ts_on_failure = Nel.to_list ts @ try_ts_on_failure in
          (* Since s could be in any object type in the list ts, we try to look it
             up in the first element of ts, pushing the rest into the list
             try_ts_on_failure (see below). *)
          rec_flow cx trace (t, ExtendsUseT (use_op, reason, try_ts_on_failure, l, u))
        (* consistent override of properties **)
        | (IntersectionT (_, rep), SuperT (use_op, reason, derived)) ->
          InterRep.members rep
          |> List.iter (fun t ->
                 let u =
                   match use_op with
                   | Op (ClassExtendsCheck c) ->
                     let use_op = Op (ClassExtendsCheck { c with extends = reason_of_t t }) in
                     SuperT (use_op, reason, derived)
                   | _ -> u
                 in
                 rec_flow cx trace (t, u)
             )
        (* structural subtype multiple inheritance **)
        | (IntersectionT (_, rep), ImplementsT (use_op, this)) ->
          InterRep.members rep
          |> List.iter (fun t ->
                 let u =
                   match use_op with
                   | Op (ClassImplementsCheck c) ->
                     let use_op = Op (ClassImplementsCheck { c with implements = reason_of_t t }) in
                     ImplementsT (use_op, this)
                   | _ -> u
                 in
                 rec_flow cx trace (t, u)
             )
        (* predicates: prevent a predicate upper bound from prematurely decomposing
           an intersection lower bound *)
        | ( IntersectionT _,
            ConcretizeT { reason = _; kind = ConcretizeForPredicate _; seen = _; collector }
          ) ->
          TypeCollector.add collector l
        (* This duplicates the (_, ReposLowerT u) near the end of this pattern
           match but has to appear here to preempt the (IntersectionT, _) in
           between so that we reposition the entire intersection. *)
        | (IntersectionT _, ReposLowerT { reason; use_desc; use_t = u }) ->
          rec_flow cx trace (reposition_reason cx ~trace reason ~use_desc l, u)
        | (IntersectionT _, ObjKitT (use_op, reason, resolve_tool, tool, tout)) ->
          ObjectKit.run trace cx use_op reason resolve_tool tool ~tout l
        | (IntersectionT _, SealGenericT { reason = _; id; name; cont; no_infer }) ->
          let reason = reason_of_t l in
          continue cx trace (GenericT { reason; id; name; bound = l; no_infer }) cont
        | (IntersectionT _, CallT { use_op; call_action = ConcretizeCallee tout; _ }) ->
          rec_flow_t cx trace ~use_op (l, OpenT tout)
        | ( IntersectionT _,
            ConcretizeT
              {
                reason = _;
                kind = ConcretizeForOperatorsChecking | ConcretizeForObjectAssign;
                seen = _;
                collector;
              }
          ) ->
          TypeCollector.add collector l
        | (IntersectionT (r, rep), u) ->
          let u' =
            match u with
            | OptionalChainT { t_out; _ } -> t_out
            | u -> u
          in
          (* We only call CalleeRecorder here for sig-help information. As far as
           * the typed AST is concerned when dealing with intersections we record
           * the specific branch that was selected. Therefore, we do not record
           * intersections when they hit a CallT constraint. The only time when an
           * intersection is allowed is when we have exhausted the branches of a
           * speculation job (this is a Flow error) and fall back to the
           * intersection as the type for the callee node. (This happens in
           * Default_resolver.) *)
          CalleeRecorder.add_callee_use cx CalleeRecorder.SigHelp l u';
          SpeculationKit.try_intersection cx trace u r rep
        (******************************)
        (* optional chaining - part B *)
        (******************************)
        (* The remaining cases of OptionalChainT will be handled after union-like,
         * intersections and type applications have been resolved *)
        | (_, OptionalChainT { reason; lhs_reason; t_out; voided_out = _ }) ->
          Context.mark_optional_chain
            cx
            (loc_of_reason reason)
            lhs_reason
            ~useful:
              (match l with
              | AnyT (_, AnyError _) -> false
              | DefT (_, MixedT _)
              | AnyT _ ->
                true
              | _ -> false);
          rec_flow cx trace (l, t_out)
        (*************************)
        (* Resolving rest params *)
        (*************************)

        (* `any` is obviously fine as a spread element. `Object` is fine because
         * any Iterable can be spread, and `Object` is the any type that covers
         * iterable objects. *)
        | ( AnyT (r, src),
            ResolveSpreadT (use_op, reason_op, { rrt_resolved; rrt_unresolved; rrt_resolve_to })
          ) ->
          let rrt_resolved = ResolvedAnySpreadArg (r, src) :: rrt_resolved in
          resolve_spread_list_rec
            cx
            ~trace
            ~use_op
            ~reason_op
            (rrt_resolved, rrt_unresolved)
            rrt_resolve_to
        | (_, ResolveSpreadT (use_op, reason_op, { rrt_resolved; rrt_unresolved; rrt_resolve_to }))
          ->
          let reason = reason_of_t l in
          let (lt, generic) =
            match l with
            | GenericT { bound; id; reason; _ } -> (reposition_reason cx reason bound, Some id)
            | _ -> (l, None)
          in
          let arrtype =
            match lt with
            | DefT (_, ArrT arrtype) ->
              (* Arrays *)
              (match (rrt_resolve_to, arrtype) with
              | (ResolveSpreadsToTupleType _, (ArrayAT { tuple_view = None; _ } | ROArrayAT _)) ->
                (* Only tuples can be spread into tuple types. *)
                add_output
                  cx
                  (Error_message.ETupleInvalidTypeSpread
                     { reason_spread = reason_op; reason_arg = reason }
                  );
                ArrayAT { elem_t = AnyT.error reason; tuple_view = None; react_dro = None }
              | _ -> arrtype)
            | _ ->
              (* Non-array non-any iterables, opaque arrays, etc *)
              let resolve_to =
                match rrt_resolve_to with
                (* Spreading iterables in a type context is always OK *)
                | ResolveSpreadsToMultiflowSubtypeFull _ -> `Iterable
                (* Otherwise we're spreading values *)
                | ResolveSpreadsToArray _
                | ResolveSpreadsToArrayLiteral _
                | ResolveSpreadsToMultiflowCallFull _
                | ResolveSpreadsToMultiflowPartial _ ->
                  (* Babel's "loose mode" array spread transform deviates from
                   * the spec by assuming the spread argument is always an
                   * array. If the babel_loose_array_spread option is set, model
                   * this assumption.
                   *)
                  if Context.babel_loose_array_spread cx then
                    `Array
                  else
                    `Iterable
                | ResolveSpreadsToTupleType _ -> `Tuple
              in
              let elem_t = Tvar.mk cx reason in
              let resolve_to_type =
                match resolve_to with
                | `ArrayLike ->
                  get_builtin_typeapp
                    cx
                    (replace_desc_new_reason (RCustom "Array-like object expected for apply") reason)
                    "$ArrayLike"
                    [elem_t]
                | `Iterable ->
                  let targs =
                    [
                      elem_t;
                      Unsoundness.why ResolveSpread reason;
                      Unsoundness.why ResolveSpread reason;
                    ]
                  in
                  get_builtin_typeapp
                    cx
                    (replace_desc_new_reason (RCustom "Iterable expected for spread") reason)
                    "$Iterable"
                    targs
                | `Array ->
                  DefT
                    ( replace_desc_new_reason (RCustom "Array expected for spread") reason,
                      ArrT (ROArrayAT (elem_t, None))
                    )
                | `Tuple ->
                  add_output
                    cx
                    (Error_message.ETupleInvalidTypeSpread
                       { reason_spread = reason_op; reason_arg = reason }
                    );
                  AnyT.error reason
              in
              rec_flow_t ~use_op:unknown_use cx trace (l, resolve_to_type);
              ArrayAT { elem_t; tuple_view = None; react_dro = None }
          in
          let elemt = elemt_of_arrtype arrtype in
          begin
            match rrt_resolve_to with
            (* Any ResolveSpreadsTo* which does some sort of constant folding needs to
             * carry an id around to break the infinite recursion that constant
             * constant folding can trigger *)
            | ResolveSpreadsToTupleType { id; inexact = _; elem_t; tout }
            | ResolveSpreadsToArrayLiteral { id; as_const = _; elem_t; tout } ->
              (* You might come across code like
               *
               * for (let x = 1; x < 3; x++) { foo = [...foo, x]; }
               *
               * where every time you spread foo, you flow another type into foo. So
               * each time `l ~> ResolveSpreadT` is processed, it might produce a new
               * `l ~> ResolveSpreadT` with a new `l`.
               *
               * Here is how we avoid this:
               *
               * 1. We use ConstFoldExpansion to detect when we see a ResolveSpreadT
               *    upper bound multiple times
               * 2. When a ResolveSpreadT upper bound multiple times, we change it into
               *    a ResolveSpreadT upper bound that resolves to a more general type.
               *    This should prevent more distinct lower bounds from flowing in
               * 3. rec_flow caches (l,u) pairs.
               *)
              let reason_elemt = reason_of_t elemt in
              let pos = Base.List.length rrt_resolved in
              ConstFoldExpansion.guard cx id (reason_elemt, pos) (fun recursion_depth ->
                  match recursion_depth with
                  | 0 ->
                    (* The first time we see this, we process it normally *)
                    let rrt_resolved =
                      ResolvedSpreadArg (reason, arrtype, generic) :: rrt_resolved
                    in
                    resolve_spread_list_rec
                      cx
                      ~trace
                      ~use_op
                      ~reason_op
                      (rrt_resolved, rrt_unresolved)
                      rrt_resolve_to
                  | 1 ->
                    (* To avoid infinite recursion, let's deconstruct to a simpler case
                     * where we no longer resolve to a tuple but instead just resolve to
                     * an array. *)
                    rec_flow
                      cx
                      trace
                      ( l,
                        ResolveSpreadT
                          ( use_op,
                            reason_op,
                            {
                              rrt_resolved;
                              rrt_unresolved;
                              rrt_resolve_to = ResolveSpreadsToArray (elem_t, tout);
                            }
                          )
                      )
                  | _ ->
                    (* We've already deconstructed, so there's nothing left to do *)
                    ()
              )
            | ResolveSpreadsToMultiflowCallFull (id, _)
            | ResolveSpreadsToMultiflowSubtypeFull (id, _)
            | ResolveSpreadsToMultiflowPartial (id, _, _, _) ->
              let reason_elemt = reason_of_t elemt in
              let pos = Base.List.length rrt_resolved in
              ConstFoldExpansion.guard cx id (reason_elemt, pos) (fun recursion_depth ->
                  match recursion_depth with
                  | 0 ->
                    (* The first time we see this, we process it normally *)
                    let rrt_resolved =
                      ResolvedSpreadArg (reason, arrtype, generic) :: rrt_resolved
                    in
                    resolve_spread_list_rec
                      cx
                      ~trace
                      ~use_op
                      ~reason_op
                      (rrt_resolved, rrt_unresolved)
                      rrt_resolve_to
                  | 1 ->
                    (* Consider
                     *
                     * function foo(...args) { foo(1, ...args); }
                     * foo();
                     *
                     * Because args is unannotated, we try to infer it. However, due to
                     * the constant folding we do with spread arguments, we'll first
                     * infer that it is [], then [] | [1], then [] | [1] | [1,1] ...etc
                     *
                     * We can recognize that we're stuck in a constant folding loop. But
                     * how to break it?
                     *
                     * In this case, we are constant folding by recognizing when args is
                     * a tuple or an array literal. We can break the loop by turning
                     * tuples or array literals into simple arrays.
                     *)
                    let new_arrtype =
                      match arrtype with
                      (* These can get us into constant folding loops *)
                      | ArrayAT { elem_t; tuple_view = Some _; react_dro }
                      | TupleAT { elem_t; react_dro; _ } ->
                        ArrayAT { elem_t; tuple_view = None; react_dro }
                      (* These cannot *)
                      | ArrayAT { tuple_view = None; _ }
                      | ROArrayAT _ ->
                        arrtype
                    in
                    let rrt_resolved =
                      ResolvedSpreadArg (reason, new_arrtype, generic) :: rrt_resolved
                    in
                    resolve_spread_list_rec
                      cx
                      ~trace
                      ~use_op
                      ~reason_op
                      (rrt_resolved, rrt_unresolved)
                      rrt_resolve_to
                  | _ -> ()
              )
            (* no caching *)
            | ResolveSpreadsToArray _ ->
              let rrt_resolved = ResolvedSpreadArg (reason, arrtype, generic) :: rrt_resolved in
              resolve_spread_list_rec
                cx
                ~trace
                ~use_op
                ~reason_op
                (rrt_resolved, rrt_unresolved)
                rrt_resolve_to
          end
        (*****************)
        (* destructuring *)
        (*****************)
        | (_, DestructuringT (reason, kind, selector, tout, id)) ->
          destruct cx ~trace reason kind l selector tout id
        (**************)
        (* conditional type *)
        (**************)
        | (DefT (_, EmptyT), ConditionalT { use_op; tout; _ }) ->
          rec_flow_t cx trace ~use_op (l, OpenT tout)
        | ( DefT (reason_tapp, PolyT { tparams_loc = _; tparams; t_out; _ }),
            ConditionalT { use_op; reason = reason_op; _ }
          ) ->
          let t_ =
            ImplicitInstantiationKit.run_monomorphize
              cx
              trace
              ~use_op
              ~reason_op
              ~reason_tapp
              tparams
              t_out
          in
          rec_flow cx trace (t_, u)
        | ( check_t,
            ConditionalT
              {
                use_op;
                reason;
                distributive_tparam_name = Some name;
                infer_tparams;
                extends_t;
                true_t;
                false_t;
                tout;
              }
          ) ->
          let subst = mk_distributive_tparam_subst_fn cx ~use_op name check_t in
          rec_flow
            cx
            trace
            ( check_t,
              ConditionalT
                {
                  use_op;
                  reason;
                  distributive_tparam_name = None;
                  infer_tparams =
                    Base.List.map infer_tparams ~f:(fun tparam ->
                        { tparam with bound = subst tparam.bound }
                    );
                  extends_t = subst extends_t;
                  true_t = subst true_t;
                  false_t = subst false_t;
                  tout;
                }
            )
        | ( check_t,
            ConditionalT
              {
                use_op;
                reason;
                distributive_tparam_name = None;
                infer_tparams;
                extends_t;
                true_t;
                false_t;
                tout;
              }
          ) ->
          let result =
            ImplicitInstantiationKit.run_conditional
              cx
              trace
              ~use_op
              ~reason
              ~tparams:infer_tparams
              ~check_t
              ~extends_t
              ~true_t
              ~false_t
          in
          rec_flow_t cx trace ~use_op (result, OpenT tout)
        (* singleton lower bounds are equivalent to the corresponding
           primitive with a literal constraint. These conversions are
           low precedence to allow equality exploits above, such as
           the UnionT membership check, to fire.
           TODO we can move to a single representation for singletons -
           either SingletonFooT or (FooT <literal foo>) - if we can
           ensure that their meaning as upper bounds is unambiguous.
           Currently a SingletonFooT means the constrained type,
           but the literal in (FooT <literal>) is a no-op.
           Abstractly it should be totally possible to scrub literals
           from the latter kind of flow, but it's unclear how difficult
           it would be in practice.
        *)
        | ( DefT (_, (SingletonStrT _ | SingletonNumT _ | SingletonBoolT _)),
            ReposLowerT { reason; use_desc; use_t = u }
          ) ->
          rec_flow cx trace (reposition_reason cx ~trace reason ~use_desc l, u)
        (* NullProtoT is necessary as an upper bound, to distinguish between
           (ObjT _, NullProtoT _) constraints and (ObjT _, DefT (_, NullT)), but as
           a lower bound, it's the same as DefT (_, NullT) *)
        | (NullProtoT reason, _) -> rec_flow cx trace (DefT (reason, NullT), u)
        (********************)
        (* mixin conversion *)
        (********************)

        (* A class can be viewed as a mixin by extracting its immediate properties,
           and "erasing" its static and super *)
        | ( DefT (class_reason, ClassT (ThisInstanceT (_, { inst; _ }, is_this, this_name))),
            MixinT (r, tvar)
          ) ->
          let static = ObjProtoT r in
          let super = ObjProtoT r in
          rec_flow
            cx
            trace
            ( DefT
                ( class_reason,
                  ClassT
                    (ThisInstanceT (r, { static; super; implements = []; inst }, is_this, this_name))
                ),
              UseT (unknown_use, tvar)
            )
        | ( DefT
              ( _,
                PolyT
                  {
                    tparams_loc;
                    tparams = xs;
                    t_out =
                      DefT (class_r, ClassT (ThisInstanceT (_, { inst; _ }, is_this, this_name)));
                    _;
                  }
              ),
            MixinT (r, tvar)
          ) ->
          let static = ObjProtoT r in
          let super = ObjProtoT r in
          let instance = { static; super; implements = []; inst } in
          rec_flow
            cx
            trace
            ( poly_type
                (Type.Poly.generate_id ())
                tparams_loc
                xs
                (DefT (class_r, ClassT (ThisInstanceT (r, instance, is_this, this_name)))),
              UseT (unknown_use, tvar)
            )
        | (AnyT (_, src), MixinT (r, tvar)) ->
          rec_flow_t ~use_op:unknown_use cx trace (AnyT.why src r, tvar)
        (* TODO: it is conceivable that other things (e.g. functions) could also be
           viewed as mixins (e.g. by extracting properties in their prototypes), but
           such enhancements are left as future work. *)
        (***************************************)
        (* generic function may be specialized *)
        (***************************************)

        (* Instantiate a polymorphic definition using the supplied type
           arguments. Use the instantiation cache if directed to do so by the
           operation. (SpecializeT operations are created when processing TypeAppT
           types, so the decision to cache or not originates there.) *)
        | ( DefT (_, PolyT { tparams_loc; tparams = xs; t_out = t; id }),
            SpecializeT (use_op, reason_op, reason_tapp, ts, tvar)
          ) ->
          let ts = Base.Option.value ts ~default:[] in
          let t_ =
            mk_typeapp_of_poly cx trace ~use_op ~reason_op ~reason_tapp id tparams_loc xs t ts
          in
          rec_flow_t ~use_op:unknown_use cx trace (t_, tvar)
        (* empty targs specialization of non-polymorphic classes is a no-op *)
        | (DefT (_, ClassT _), SpecializeT (_, _, _, None, tvar)) ->
          rec_flow_t ~use_op:unknown_use cx trace (l, tvar)
        | (AnyT _, SpecializeT (_, _, _, _, tvar)) ->
          rec_flow_t ~use_op:unknown_use cx trace (l, tvar)
        (* this-specialize a this-abstracted class by substituting This *)
        | (DefT (_, ClassT (ThisInstanceT (inst_r, i, _, this_name))), ThisSpecializeT (r, this, k))
          ->
          let i = Type_subst.subst_instance_type cx (Subst_name.Map.singleton this_name this) i in
          continue_repos cx trace r (DefT (inst_r, InstanceT i)) k
        (* this-specialization of non-this-abstracted classes is a no-op *)
        | (DefT (_, ClassT i), ThisSpecializeT (r, _this, k)) ->
          (* TODO: check that this is a subtype of i? *)
          continue_repos cx trace r i k
        | (AnyT _, ThisSpecializeT (r, _, k)) -> continue_repos cx trace r l k
        | (DefT (_, PolyT _), ReposLowerT { reason; use_desc; use_t = u }) ->
          rec_flow cx trace (reposition_reason cx ~trace reason ~use_desc l, u)
        | (DefT (_, ClassT (ThisInstanceT _)), ReposLowerT { reason; use_desc; use_t = u }) ->
          rec_flow cx trace (reposition_reason cx ~trace reason ~use_desc l, u)
        (* Special case for `_ instanceof C` where C is polymorphic *)
        | ( DefT (reason_tapp, PolyT { tparams_loc; tparams = ids; t_out = t; _ }),
            ConcretizeT
              {
                reason = _;
                kind = ConcretizeForPredicate ConcretizeRHSForInstanceOfPredicateTest;
                seen = _;
                collector = _;
              }
          ) ->
          let l =
            instantiate_poly_default_args
              cx
              trace
              ~use_op:unknown_use
              ~reason_op:(reason_of_use_t u)
              ~reason_tapp
              (tparams_loc, ids, t)
          in
          rec_flow cx trace (l, u)
        | ( DefT (_, PolyT _),
            ConcretizeT { reason = _; kind = ConcretizeForPredicate _; seen = _; collector }
          ) ->
          TypeCollector.add collector l
        (* The rules below are hit when a polymorphic type appears outside a
           type application expression - i.e. not followed by a type argument list
           delimited by angle brackets.
           We want to require full expressions in type positions like annotations,
           but allow use of polymorphically-typed values - for example, in class
           extends clauses and at function call sites - without explicit type
           arguments, since typically they're easily inferred from context.
        *)
        (* We are calling the static callable method of a class. We need to be careful
         * not to apply the targs at this point, because this PolyT represents the class
         * and not the static function that's being called. We implicitly instantiate
         * the instance's tparams using the bounds and then forward the result original call
         * instead of consuming the method call's type arguments.
         *
         * We use the bounds to explicitly instantiate so that we don't create yet another implicit
         * instantiation here that would be un-annotatable. *)
        | ( DefT
              ( reason_tapp,
                PolyT
                  { tparams_loc; tparams = ids; t_out = DefT (_, ClassT (ThisInstanceT _)) as t; _ }
              ),
            CallT { use_op; reason = reason_op; _ }
          ) ->
          let targs = Nel.map (fun tparam -> ExplicitArg tparam.bound) ids in
          let t_ =
            instantiate_with_targs
              cx
              trace
              (tparams_loc, ids, t)
              (Nel.to_list targs)
              ~use_op
              ~reason_op
              ~reason_tapp
          in
          rec_flow cx trace (t_, u)
        (* We use the ConcretizeCallee action to simplify types for hint decomposition.
           After having instantiated polymorphic classes on static calls (case above),
           we can just return the remaining polymorphic types, since there is not
           much we can do about them here. These will be handled by the hint
           decomposition code that has some knowledge of the call arguments.
        *)
        | (DefT (_, PolyT _), CallT { use_op; call_action = ConcretizeCallee tout; _ }) ->
          rec_flow_t cx trace ~use_op (l, OpenT tout)
        (* Calls to polymorphic functions may cause non-termination, e.g. when the
           results of the calls feed back as subtle variations of the original
           arguments. This is similar to how we may have non-termination with
           method calls on type applications. Thus, it makes sense to replicate
           the specialization caching mechanism used in TypeAppT ~> MethodT to
           avoid non-termination in PolyT ~> CallT.

           As it turns out, we need a bit more work here. A call may invoke
           different cases of an overloaded polymorphic function on different
           arguments, so we use the reasons of arguments in addition to the reason
           of the call as keys for caching instantiations.

           On the other hand, even the reasons of arguments may not offer sufficient
           distinguishing power when the arguments have not been concretized:
           differently typed arguments could be incorrectly summarized by common
           type variables they flow to, causing spurious errors.

           NOTE: This is probably not the final word on non-termination with
           generics. We need to separate the double duty of reasons in the current
           implementation as error positions and as caching keys. As error
           positions we should be able to subject reasons to arbitrary tweaking,
           without fearing regressions in termination guarantees.
        *)
        | ( DefT (reason_tapp, PolyT { tparams_loc; tparams = ids; t_out = t; _ }),
            CallT { use_op; reason = reason_op; call_action = Funcalltype calltype; return_hint }
          ) ->
          let check = lazy (IICheck.of_call l (tparams_loc, ids, t) use_op reason_op calltype) in
          let lparts = (reason_tapp, tparams_loc, ids, t) in
          let uparts = (use_op, reason_op, calltype.call_targs, return_hint) in
          let t_ = instantiate_poly_call_or_new cx trace lparts uparts check in
          let u =
            CallT
              {
                use_op;
                reason = reason_op;
                call_action = Funcalltype { calltype with call_targs = None };
                return_hint;
              }
          in
          rec_flow cx trace (t_, u)
        | ( DefT (reason_tapp, PolyT { tparams_loc; tparams = ids; t_out = t; _ }),
            ConstructorT
              { use_op; reason = reason_op; targs; args; tout; return_hint; specialized_ctor }
          ) ->
          let check = lazy (IICheck.of_ctor l (tparams_loc, ids, t) use_op reason_op targs args) in
          let lparts = (reason_tapp, tparams_loc, ids, t) in
          let uparts = (use_op, reason_op, targs, return_hint) in
          let t_ = instantiate_poly_call_or_new cx trace lparts uparts check in
          let u =
            ConstructorT
              {
                use_op;
                reason = reason_op;
                targs = None;
                args;
                tout;
                return_hint;
                specialized_ctor;
              }
          in
          rec_flow cx trace (t_, u)
        | ( DefT (reason_tapp, PolyT { tparams_loc; tparams = ids; t_out = t; _ }),
            ReactKitT
              ( use_op,
                reason_op,
                React.CreateElement
                  {
                    component;
                    jsx_props;
                    return_hint;
                    targs;
                    tout;
                    record_monomorphized_result = _;
                    inferred_targs = _;
                    specialized_component;
                  }
              )
          ) ->
          let lparts = (reason_tapp, tparams_loc, ids, t) in
          let uparts = (use_op, reason_op, targs, return_hint) in
          let check =
            let poly_t = (tparams_loc, ids, t) in
            lazy (IICheck.of_react_jsx l poly_t use_op reason_op ~component ~jsx_props ~targs)
          in
          let (t_, inferred_targs) =
            instantiate_poly_call_or_new_with_soln cx trace lparts uparts check
          in
          let u =
            ReactKitT
              ( use_op,
                reason_op,
                React.CreateElement
                  {
                    component;
                    jsx_props;
                    return_hint;
                    targs = None;
                    tout;
                    record_monomorphized_result = true;
                    inferred_targs = Some inferred_targs;
                    specialized_component;
                  }
              )
          in
          rec_flow cx trace (t_, u)
        | ( DefT (r, ObjT { call_t = Some id; _ }),
            ReactKitT
              ( _,
                _,
                ( React.CreateElement _ | React.GetProps _ | React.GetConfig _ | React.ConfigCheck _
                | React.GetRef _ )
              )
          )
          when match Context.find_call cx id with
               | DefT (_, PolyT { t_out = DefT (_, FunT _); _ }) as fun_t ->
                 rec_flow cx trace (mod_reason_of_t (Fun.const r) fun_t, u);
                 true
               | _ -> false ->
          ()
        | ( DefT (reason_tapp, PolyT { tparams_loc = _; tparams; t_out; _ }),
            ReactKitT (use_op, reason_op, (React.GetProps _ | React.GetConfig _ | React.GetRef _))
          ) ->
          let t_ =
            ImplicitInstantiationKit.run_monomorphize
              cx
              trace
              ~use_op
              ~reason_op
              ~reason_tapp
              tparams
              t_out
          in
          rec_flow cx trace (t_, u)
        (******************************)
        (* functions statics - part A *)
        (******************************)
        | ( ( DefT (reason, FunT (static, _))
            | DefT (_, PolyT { t_out = DefT (reason, FunT (static, _)); _ }) ),
            MethodT (use_op, reason_call, reason_lookup, propref, action)
          ) ->
          let method_type =
            Tvar.mk_no_wrap_where cx reason_lookup (fun tout ->
                let use_t =
                  GetPropT
                    {
                      use_op;
                      reason = reason_lookup;
                      id = None;
                      from_annot = false;
                      skip_optional = false;
                      propref;
                      tout;
                      hint = hint_unavailable;
                    }
                in
                rec_flow cx trace (static, ReposLowerT { reason; use_desc = false; use_t })
            )
          in
          apply_method_action cx trace method_type use_op reason_call l action
        | (DefT (reason_tapp, PolyT { tparams_loc; tparams = ids; t_out = t; _ }), _) ->
          let reason_op = reason_of_use_t u in
          let use_op =
            match use_op_of_use_t u with
            | Some use_op -> use_op
            | None -> unknown_use
          in
          let unify_bounds =
            match u with
            | MethodT (_, _, _, _, NoMethodAction _) -> true
            | _ -> false
          in
          let (t_, _) =
            instantiate_poly
              cx
              trace
              ~use_op
              ~reason_op
              ~reason_tapp
              ~unify_bounds
              (tparams_loc, ids, t)
          in
          rec_flow cx trace (t_, u)
        (* when a this-abstracted class flows to upper bounds, fix the class *)
        | (DefT (class_r, ClassT (ThisInstanceT (r, i, this, this_name))), _) ->
          let reason = reason_of_use_t u in
          rec_flow
            cx
            trace
            (DefT (class_r, ClassT (fix_this_instance cx reason (r, i, this, this_name))), u)
        | (ThisInstanceT (r, i, this, this_name), _) ->
          let reason = reason_of_use_t u in
          rec_flow cx trace (fix_this_instance cx reason (r, i, this, this_name), u)
        (*****************************)
        (* React Abstract Components *)
        (*****************************)
        (* When looking at properties of an AbstractComponent, we delegate to a union of
         * function component and class component
         *)
        | ( DefT (r, ReactAbstractComponentT _),
            (TestPropT _ | GetPropT _ | SetPropT _ | GetElemT _ | SetElemT _)
          ) ->
          let statics = get_builtin_type cx ~trace r "React$AbstractComponentStatics" in
          rec_flow cx trace (statics, u)
        (* Components can never be called *)
        | ( DefT (r, ReactAbstractComponentT _),
            CallT { use_op; reason; call_action = Funcalltype { call_tout; _ }; _ }
          ) ->
          add_output cx (Error_message.ECannotCallReactComponent { reason = r });
          rec_flow_t cx trace ~use_op (AnyT.error reason, OpenT call_tout)
        (***********************************************)
        (* function types deconstruct into their parts *)
        (***********************************************)

        (* FunT ~> CallT *)
        | (DefT (_, FunT _), CallT { use_op; call_action = ConcretizeCallee tout; _ }) ->
          rec_flow_t cx trace ~use_op (l, OpenT tout)
        | ( DefT (reason_fundef, FunT (_, funtype)),
            CallT
              {
                use_op;
                reason = reason_callsite;
                call_action = Funcalltype calltype;
                return_hint = _;
              }
          ) ->
          let funtype =
            let { effect_; return_t; _ } = funtype in
            let return_t =
              match effect_ with
              | HookDecl _
              | HookAnnot ->
                if Context.react_rule_enabled cx Options.DeepReadOnlyHookReturns then
                  mk_possibly_evaluated_destructor
                    cx
                    unknown_use
                    (TypeUtil.reason_of_t return_t)
                    return_t
                    (ReactDRO (def_loc_of_reason reason_fundef, HookReturn))
                    (Eval.generate_id ())
                else
                  return_t
              | ArbitraryEffect
              | AnyEffect ->
                return_t
            in
            { funtype with return_t }
          in
          let { this_t = (o1, _); params = _; return_t = t1; _ } = funtype in
          let {
            call_this_t = o2;
            call_targs;
            call_args_tlist = tins2;
            call_tout = t2;
            call_strict_arity;
            call_speculation_hint_state = _;
            call_specialized_callee;
          } =
            calltype
          in
          rec_flow cx trace (o2, UseT (use_op, o1));
          CalleeRecorder.add_callee cx CalleeRecorder.All l call_specialized_callee;

          Base.Option.iter call_targs ~f:(fun _ ->
              add_output
                cx
                Error_message.(
                  ECallTypeArity
                    {
                      call_loc = loc_of_reason reason_callsite;
                      is_new = false;
                      reason_arity = reason_fundef;
                      expected_arity = 0;
                    }
                )
          );

          if call_strict_arity then
            multiflow_call cx trace ~use_op reason_callsite tins2 funtype
          else
            multiflow_subtype cx trace ~use_op reason_callsite tins2 funtype;

          (* flow return type of function to the tvar holding the return type of the
             call. clears the op stack because the result of the call is not the
             call itself. *)
          rec_flow_t
            ~use_op:unknown_use
            cx
            trace
            (reposition cx ~trace (loc_of_reason reason_callsite) t1, OpenT t2)
        | (AnyT _, CallT { use_op; call_action = ConcretizeCallee tout; _ }) ->
          rec_flow_t cx trace ~use_op (l, OpenT tout)
        | ( AnyT (reason_fundef, src),
            CallT
              { use_op; reason = reason_op; call_action = Funcalltype calltype; return_hint = _ }
          ) ->
          let {
            call_this_t;
            call_targs = _;
            (* An untyped receiver can't do anything with type args *)
            call_args_tlist;
            call_tout;
            call_strict_arity = _;
            call_speculation_hint_state = _;
            call_specialized_callee;
          } =
            calltype
          in
          CalleeRecorder.add_callee cx CalleeRecorder.All l call_specialized_callee;
          let src = any_mod_src_keep_placeholder Untyped src in
          let any = AnyT.why src reason_fundef in
          rec_flow_t cx ~use_op trace (call_this_t, any);
          call_args_iter (fun t -> rec_flow cx trace (t, UseT (use_op, any))) call_args_tlist;
          rec_flow_t cx ~use_op trace (AnyT.why src reason_op, OpenT call_tout)
        | (_, ReactKitT (use_op, reason_op, tool)) -> ReactJs.run cx trace ~use_op reason_op l tool
        (****************************************)
        (* You can cast an object to a function *)
        (****************************************)
        | ( DefT (reason, (ObjT _ | InstanceT _)),
            CallT { use_op; reason = reason_op; call_action = _; return_hint = _ }
          ) ->
          let prop_name = Some (OrdinaryName "$call") in
          let fun_t =
            match l with
            | DefT (_, ObjT { call_t = Some id; _ })
            | DefT (_, InstanceT { inst = { inst_call_t = Some id; _ }; _ }) ->
              Context.find_call cx id
            | _ ->
              let reason_prop = replace_desc_reason (RProperty prop_name) reason_op in
              let error_message =
                Error_message.EPropNotFound
                  { reason_prop; reason_obj = reason; prop_name; use_op; suggestion = None }
              in
              add_output cx error_message;
              AnyT.error reason_op
          in
          rec_flow cx trace (reposition cx ~trace (loc_of_reason reason) fun_t, u)
        | (AnyT (_, src), ObjTestT (reason_op, _, u)) ->
          rec_flow_t ~use_op:unknown_use cx trace (AnyT.why src reason_op, u)
        | (_, ObjTestT (reason_op, default, u)) ->
          let u =
            ReposLowerT { reason = reason_op; use_desc = false; use_t = UseT (unknown_use, u) }
          in
          if object_like l then
            rec_flow cx trace (l, u)
          else
            rec_flow cx trace (default, u)
        | (AnyT (_, src), ObjTestProtoT (reason_op, u)) ->
          rec_flow_t cx trace ~use_op:unknown_use (AnyT.why src reason_op, u)
        | (DefT (_, NullT), ObjTestProtoT (reason_op, u)) ->
          rec_flow_t cx trace ~use_op:unknown_use (NullProtoT.why reason_op, u)
        | (_, ObjTestProtoT (reason_op, u)) ->
          let proto =
            if object_like l then
              reposition cx ~trace (loc_of_reason reason_op) l
            else
              let () =
                add_output
                  cx
                  (Error_message.EInvalidPrototype (loc_of_reason reason_op, reason_of_t l))
              in
              ObjProtoT.why reason_op
          in
          rec_flow_t cx trace ~use_op:unknown_use (proto, u)
        (**************************************************)
        (* instances of classes follow declared hierarchy *)
        (**************************************************)
        | ( DefT (reason, InstanceT { super; implements; inst; static }),
            ExtendsUseT
              ( use_op,
                reason_op,
                try_ts_on_failure,
                l,
                ( DefT
                    ( reason_u,
                      InstanceT
                        {
                          inst = inst_super;
                          static = static_super;
                          super = super_super;
                          implements = _super_impls;
                        }
                    ) as u
                )
              )
          ) ->
          if is_same_instance_type inst inst_super then
            let { type_args = tmap1; _ } = inst in
            let { type_args = tmap2; _ } = inst_super in
            let ureason =
              update_desc_reason
                (function
                  | RExtends desc -> desc
                  | desc -> desc)
                reason_op
            in
            flow_type_args cx trace ~use_op reason ureason tmap1 tmap2
          else if
            (* We are subtyping a class from platform-specific impl file against the interface file *)
            TypeUtil.nominal_id_have_same_logical_module
              ~file_options:(Context.file_options cx)
              ~projects_options:(Context.projects_options cx)
              (inst.class_id, inst.class_name)
              (inst_super.class_id, inst_super.class_name)
            && List.length inst.type_args = List.length inst_super.type_args
          then (
            if TypeUtil.is_in_common_interface_conformance_check use_op then (
              let implements_use_op =
                Op (ClassImplementsCheck { def = reason; name = reason; implements = reason_u })
              in
              (* We need to ensure that the shape of the class instances match. *)
              let inst_type_to_obj_type reason inst =
                inst_type_to_obj_type
                  cx
                  reason
                  (inst.own_props, inst.proto_props, inst.inst_call_t, inst.inst_dict)
              in
              rec_unify
                cx
                trace
                ~use_op:implements_use_op
                (inst_type_to_obj_type reason inst)
                (inst_type_to_obj_type reason_u inst_super);
              (* We need to ensure that the shape of the class statics match. *)
              let spread_of reason t =
                (* Spread to keep only own props and own methods. *)
                let id = Eval.generate_id () in
                let destructor =
                  SpreadType (Object.Spread.Annot { make_exact = false }, [], None)
                in
                mk_possibly_evaluated_destructor cx unknown_use reason t destructor id
              in
              rec_unify
                cx
                trace
                ~use_op:implements_use_op
                (spread_of reason static)
                (spread_of reason_u static_super);
              (* We need to ensure that the classes have the same nominal hierarchy *)
              rec_flow_t cx trace ~use_op (super, super_super)
            );
            (* We need to ensure that the classes have the matching targs *)
            flow_type_args cx trace ~use_op reason reason_u inst.type_args inst_super.type_args
          ) else
            (* If this instance type has declared implementations, any structural
               tests have already been performed at the declaration site. We can
               then use the ExtendsUseT use type to search for a nominally matching
               implementation, thereby short-circuiting a potentially expensive
               structural test at the use site. *)
            let use_t = ExtendsUseT (use_op, reason_op, try_ts_on_failure @ implements, l, u) in
            rec_flow cx trace (super, ReposLowerT { reason; use_desc = false; use_t })
        (*********************************************************)
        (* class types derive instance types (with constructors) *)
        (*********************************************************)
        | ( DefT (reason, ClassT this),
            ConstructorT
              { use_op; reason = reason_op; targs; args; tout = t; return_hint; specialized_ctor }
          ) ->
          let reason_o = replace_desc_reason RConstructorVoidReturn reason in
          let annot_loc = loc_of_reason reason_op in
          (* early error if type args passed to non-polymorphic class *)
          Base.Option.iter targs ~f:(fun _ ->
              add_output
                cx
                Error_message.(
                  ECallTypeArity
                    {
                      call_loc = annot_loc;
                      is_new = true;
                      reason_arity = reason_of_t this;
                      expected_arity = 0;
                    }
                )
          );
          (* call this.constructor(args) *)
          let ret =
            Tvar.mk_no_wrap_where cx reason_op (fun t ->
                let funtype = mk_methodcalltype None args t in
                let propref = mk_named_prop ~reason:reason_o (OrdinaryName "constructor") in
                rec_flow
                  cx
                  trace
                  ( this,
                    MethodT
                      ( use_op,
                        reason_op,
                        reason_o,
                        propref,
                        CallM
                          {
                            methodcalltype = funtype;
                            return_hint;
                            specialized_callee = specialized_ctor;
                          }
                      )
                  )
            )
          in
          (* return this *)
          rec_flow cx trace (ret, ObjTestT (annot_reason ~annot_loc reason_op, this, t))
        | ( AnyT (_, src),
            ConstructorT
              {
                use_op;
                reason = reason_op;
                targs;
                args;
                tout = t;
                return_hint = _;
                specialized_ctor = _;
              }
          ) ->
          ignore targs;

          let src = any_mod_src_keep_placeholder Untyped src in
          (* An untyped receiver can't do anything with type args *)
          call_args_iter
            (fun t -> rec_flow cx trace (t, UseT (use_op, AnyT.why src reason_op)))
            args;
          rec_flow_t cx trace ~use_op:unknown_use (AnyT.why src reason_op, t)
        (* Only classes (and `any`) can be constructed. *)
        | ( _,
            ConstructorT
              {
                use_op;
                reason = reason_op;
                tout = t;
                args = _;
                targs = _;
                return_hint = _;
                specialized_ctor = _;
              }
          ) ->
          add_output cx Error_message.(EInvalidConstructor (reason_of_t l));
          rec_flow_t cx trace ~use_op (AnyT.error reason_op, t)
        (* Since we don't know the signature of a method on AnyT, assume every
           parameter is an AnyT. *)
        | (AnyT (_, src), MethodT (_, _, _, propref, NoMethodAction prop_t)) ->
          let src = any_mod_src_keep_placeholder Untyped src in
          rec_flow_t cx trace ~use_op:unknown_use (AnyT.why src (reason_of_propref propref), prop_t)
        | (AnyT (_, src), PrivateMethodT (_, _, prop_r, _, _, _, NoMethodAction prop_t)) ->
          let src = any_mod_src_keep_placeholder Untyped src in
          rec_flow_t cx trace ~use_op:unknown_use (AnyT.why src prop_r, prop_t)
        | ( AnyT (_, src),
            MethodT
              ( use_op,
                reason_op,
                _,
                _,
                CallM
                  {
                    methodcalltype = { meth_args_tlist; meth_tout; _ };
                    return_hint = _;
                    specialized_callee;
                  }
              )
          )
        | ( AnyT (_, src),
            PrivateMethodT
              ( use_op,
                reason_op,
                _,
                _,
                _,
                _,
                CallM
                  {
                    methodcalltype = { meth_args_tlist; meth_tout; _ };
                    return_hint = _;
                    specialized_callee;
                  }
              )
          ) ->
          let src = any_mod_src_keep_placeholder Untyped src in
          let any = AnyT.why src reason_op in
          call_args_iter (fun t -> rec_flow cx trace (t, UseT (use_op, any))) meth_args_tlist;
          CalleeRecorder.add_callee cx CalleeRecorder.Tast l specialized_callee;
          rec_flow_t cx trace ~use_op:unknown_use (any, OpenT meth_tout)
        | (AnyT (_, src), MethodT (use_op, reason_op, _, _, (ChainM _ as chain)))
        | (AnyT (_, src), PrivateMethodT (use_op, reason_op, _, _, _, _, (ChainM _ as chain))) ->
          let src = any_mod_src_keep_placeholder Untyped src in
          let any = AnyT.why src reason_op in
          apply_method_action cx trace any use_op reason_op l chain
        (*************************)
        (* statics can be read   *)
        (*************************)
        | (DefT (_, InstanceT { static; _ }), GetStaticsT ((reason_op, _) as tout)) ->
          rec_flow
            cx
            trace
            ( static,
              ReposLowerT
                { reason = reason_op; use_desc = false; use_t = UseT (unknown_use, OpenT tout) }
            )
        | (AnyT (_, src), GetStaticsT ((reason_op, _) as tout)) ->
          rec_flow_t cx trace ~use_op:unknown_use (AnyT.why src reason_op, OpenT tout)
        | (ObjProtoT _, GetStaticsT ((reason_op, _) as tout)) ->
          (* ObjProtoT not only serves as the instance type of the root class, but
             also as the statics of the root class. *)
          rec_flow
            cx
            trace
            ( l,
              ReposLowerT
                { reason = reason_op; use_desc = false; use_t = UseT (unknown_use, OpenT tout) }
            )
        (********************)
        (* __proto__ getter *)
        (********************)

        (* TODO: Fix GetProtoT for InstanceT (and ClassT).
           The __proto__ object of an instance is an ObjT having the properties in
           insttype.methods_tmap, not the super instance. *)
        | (DefT (_, InstanceT { super; _ }), GetProtoT (reason_op, t)) ->
          let proto = reposition cx ~trace (loc_of_reason reason_op) super in
          rec_flow_t cx trace ~use_op:unknown_use (proto, OpenT t)
        | (DefT (_, ObjT { proto_t; _ }), GetProtoT (reason_op, t)) ->
          let proto = reposition cx ~trace (loc_of_reason reason_op) proto_t in
          rec_flow_t cx trace ~use_op:unknown_use (proto, OpenT t)
        | (ObjProtoT _, GetProtoT (reason_op, t)) ->
          let proto = NullT.why reason_op in
          rec_flow_t cx trace ~use_op:unknown_use (proto, OpenT t)
        | (FunProtoT reason, GetProtoT (reason_op, t)) ->
          let proto = ObjProtoT (repos_reason (loc_of_reason reason_op) reason) in
          rec_flow_t cx trace ~use_op:unknown_use (proto, OpenT t)
        | (AnyT (_, src), GetProtoT (reason_op, t)) ->
          let src = any_mod_src_keep_placeholder Untyped src in
          let proto = AnyT.why src reason_op in
          rec_flow_t cx trace ~use_op:unknown_use (proto, OpenT t)
        (********************)
        (* __proto__ setter *)
        (********************)
        | (AnyT _, SetProtoT _) -> ()
        | (_, SetProtoT (reason_op, _)) ->
          add_output cx (Error_message.EUnsupportedSetProto reason_op)
        (********************************************************)
        (* instances of classes may have their fields looked up *)
        (********************************************************)
        | ( DefT (lreason, InstanceT { super; inst; _ }),
            LookupT
              {
                reason = reason_op;
                lookup_kind = kind;
                try_ts_on_failure;
                propref;
                lookup_action = action;
                ids;
                method_accessible;
                ignore_dicts;
              }
          ) ->
          let use_op = use_op_of_lookup_action action in
          (match
             GetPropTKit.get_instance_prop cx trace ~use_op ~ignore_dicts inst propref reason_op
           with
          | Some (p, target_kind) ->
            let p =
              check_method_unbinding
                cx
                ~use_op
                ~method_accessible
                ~reason_op
                ~propref
                ~hint:hint_unavailable
                p
            in
            (match kind with
            | NonstrictReturning (_, Some (id, _)) -> Context.test_prop_hit cx id
            | _ -> ());
            perform_lookup_action
              cx
              trace
              propref
              (Property.type_ p)
              target_kind
              lreason
              reason_op
              action
          | None ->
            rec_flow
              cx
              trace
              ( super,
                LookupT
                  {
                    reason = reason_op;
                    lookup_kind = kind;
                    try_ts_on_failure;
                    propref;
                    lookup_action = action;
                    method_accessible;
                    ids =
                      Base.Option.map ids ~f:(fun ids ->
                          if
                            Properties.Set.mem inst.own_props ids
                            || Properties.Set.mem inst.proto_props ids
                          then
                            ids
                          else
                            Properties.Set.add inst.own_props ids
                            |> Properties.Set.add inst.proto_props
                      );
                    ignore_dicts;
                  }
              ))
        (********************************)
        (* ... and their fields written *)
        (********************************)
        | ( DefT (_, InstanceT { inst = { inst_react_dro = Some (dro_loc, dro_type); _ }; _ }),
            SetPropT (use_op, _, propref, _, _, _, _)
          )
          when not (is_exception_to_react_dro propref) ->
          let reason_prop = reason_of_propref propref in
          let prop_name = name_of_propref propref in
          let use_op = Frame (ReactDeepReadOnly (dro_loc, dro_type), use_op) in
          add_output cx (Error_message.EPropNotWritable { reason_prop; prop_name; use_op })
        | ( DefT (reason_instance, InstanceT _),
            SetPropT (use_op, reason_op, propref, mode, write_ctx, tin, prop_tout)
          ) ->
          let lookup_action = WriteProp { use_op; obj_t = l; prop_tout; tin; write_ctx; mode } in
          let method_accessible = true in
          let lookup_kind =
            instance_lookup_kind
              cx
              trace
              ~reason_instance
              ~reason_op
              ~method_accessible
              l
              propref
              lookup_action
          in
          rec_flow
            cx
            trace
            ( l,
              LookupT
                {
                  reason = reason_op;
                  lookup_kind;
                  try_ts_on_failure = [];
                  propref;
                  lookup_action;
                  ids = None;
                  method_accessible;
                  ignore_dicts = true;
                }
            )
        | (DefT (reason_c, InstanceT _), SetPrivatePropT (use_op, reason_op, x, _, [], _, _, _, _))
          ->
          add_output
            cx
            (Error_message.EPrivateLookupFailed ((reason_op, reason_c), OrdinaryName x, use_op))
        | ( DefT (reason_c, InstanceT { inst; _ }),
            SetPrivatePropT
              (use_op, reason_op, x, mode, scope :: scopes, static, write_ctx, tin, prop_tout)
          ) ->
          if not (ALoc.equal_id scope.class_binding_id inst.class_id) then
            rec_flow
              cx
              trace
              ( l,
                SetPrivatePropT
                  (use_op, reason_op, x, mode, scopes, static, write_ctx, tin, prop_tout)
              )
          else
            let map =
              if static then
                inst.class_private_static_fields
              else
                inst.class_private_fields
            in
            let name = OrdinaryName x in
            (match NameUtils.Map.find_opt name (Context.find_props cx map) with
            | None ->
              add_output
                cx
                (Error_message.EPrivateLookupFailed ((reason_op, reason_c), name, use_op))
            | Some p ->
              let action = WriteProp { use_op; obj_t = l; prop_tout; tin; write_ctx; mode } in
              let propref = mk_named_prop ~reason:reason_op name in
              perform_lookup_action
                cx
                trace
                propref
                (Property.type_ p)
                PropertyMapProperty
                reason_c
                reason_op
                action)
        (*****************************)
        (* ... and their fields read *)
        (*****************************)
        | ( DefT (r, InstanceT _),
            GetPropT { propref = Named { name = OrdinaryName "constructor"; _ }; tout; hint = _; _ }
          ) ->
          let t = TypeUtil.class_type ?annot_loc:(annot_loc_of_reason r) l in
          rec_flow_t cx trace ~use_op:unknown_use (t, OpenT tout)
        | ( DefT (reason_instance, InstanceT { super; inst; _ }),
            GetPropT
              { use_op; reason = reason_op; id; from_annot; skip_optional; propref; tout; hint }
          ) ->
          let method_accessible = from_annot in
          let lookup_action = ReadProp { use_op; obj_t = l; tout } in
          let lookup_kind =
            instance_lookup_kind
              cx
              trace
              ~reason_instance
              ~reason_op
              ~method_accessible
              l
              propref
              lookup_action
          in
          GetPropTKit.read_instance_prop
            cx
            trace
            ~use_op
            ~instance_t:l
            ~id
            ~method_accessible
            ~super
            ~lookup_kind
            ~hint
            ~skip_optional
            inst
            propref
            reason_op
            tout
        | ( DefT (reason_c, InstanceT { inst; _ }),
            GetPrivatePropT (use_op, reason_op, prop_name, scopes, static, tout)
          ) ->
          get_private_prop
            ~cx
            ~allow_method_access:false
            ~trace
            ~l
            ~reason_c
            ~instance:inst
            ~use_op
            ~reason_op
            ~prop_name
            ~scopes
            ~static
            ~tout
        (********************************)
        (* ... and their methods called *)
        (********************************)
        | ( DefT (reason_instance, InstanceT { super; inst; _ }),
            MethodT (use_op, reason_call, reason_lookup, propref, action)
          ) ->
          let funt =
            Tvar.mk_no_wrap_where cx reason_lookup (fun tout ->
                let lookup_action = ReadProp { use_op; obj_t = l; tout } in
                let method_accessible = true in
                let lookup_kind =
                  instance_lookup_kind
                    cx
                    trace
                    ~reason_instance
                    ~reason_op:reason_lookup
                    ~method_accessible
                    l
                    propref
                    lookup_action
                in
                GetPropTKit.read_instance_prop
                  cx
                  trace
                  ~use_op
                  ~instance_t:l
                  ~id:None
                  ~method_accessible:true
                  ~super
                  ~lookup_kind
                  ~hint:hint_unavailable
                  ~skip_optional:false
                  inst
                  propref
                  reason_call
                  tout
            )
          in
          (* suppress ops while calling the function. if `funt` is a `FunT`, then
             `CallT` will set its own ops during the call. if `funt` is something
             else, then something like `VoidT ~> CallT` doesn't need the op either
             because we want to point at the call and undefined thing. *)
          apply_method_action cx trace funt use_op reason_call l action
        | ( DefT (reason_c, InstanceT { inst; _ }),
            PrivateMethodT
              (use_op, reason_op, reason_lookup, prop_name, scopes, static, method_action)
          ) ->
          let tvar = Tvar.mk_no_wrap cx reason_lookup in
          let funt = OpenT (reason_lookup, tvar) in
          let l =
            if static then
              TypeUtil.class_type l
            else
              l
          in
          get_private_prop
            ~cx
            ~allow_method_access:true
            ~trace
            ~l
            ~reason_c
            ~instance:inst
            ~use_op
            ~reason_op
            ~prop_name
            ~scopes
            ~static
            ~tout:(reason_lookup, tvar);
          apply_method_action cx trace funt use_op reason_op l method_action
        (*****************************************************************)
        (* Object.assign logic has been moved to type_operation_utils.ml *)
        (*****************************************************************)
        | (l, ConcretizeT { reason = _; kind = ConcretizeForObjectAssign; seen = _; collector }) ->
          TypeCollector.add collector l
        (*************************)
        (* objects can be copied *)
        (*************************)
        | ( DefT (reason_obj, ObjT { props_tmap; flags = { obj_kind; _ }; reachable_targs; _ }),
            ObjRestT (reason_op, xs, t, id)
          ) ->
          ConstFoldExpansion.guard cx id (reason_obj, 0) (function
              | 0 ->
                let o =
                  Flow_js_utils.objt_to_obj_rest
                    cx
                    props_tmap
                    ~reachable_targs
                    ~obj_kind
                    ~reason_op
                    ~reason_obj
                    xs
                in
                rec_flow_t cx trace ~use_op:unknown_use (o, t)
              | _ -> ()
              )
        | (DefT (reason, InstanceT { super; inst; _ }), ObjRestT (reason_op, xs, t, _)) ->
          (* Spread fields from super into an object *)
          let obj_super =
            Tvar.mk_where cx reason_op (fun tvar ->
                let use_t = ObjRestT (reason_op, xs, tvar, Reason.mk_id ()) in
                rec_flow cx trace (super, ReposLowerT { reason; use_desc = false; use_t })
            )
          in
          let o =
            Flow_js_utils.objt_to_obj_rest
              cx
              inst.own_props
              ~reachable_targs:[]
              ~obj_kind:Exact
              ~reason_op
              ~reason_obj:reason
              xs
          in
          (* Combine super and own props. *)
          let use_op = Op (ObjectSpread { op = reason_op }) in
          let spread_tool = Object.Resolve Object.Next in
          let spread_target =
            Object.Spread.Value { make_seal = Obj_type.mk_seal ~as_const:false ~frozen:false }
          in
          let spread_state =
            {
              Object.Spread.todo_rev = [Object.Spread.Type o];
              acc = [];
              spread_id = Reason.mk_id ();
              union_reason = None;
              curr_resolve_idx = 0;
            }
          in
          let o =
            Tvar.mk_where cx reason_op (fun tvar ->
                rec_flow
                  cx
                  trace
                  ( obj_super,
                    ObjKitT
                      ( use_op,
                        reason_op,
                        spread_tool,
                        Type.Object.Spread (spread_target, spread_state),
                        tvar
                      )
                  )
            )
          in
          rec_flow_t cx ~use_op trace (o, t)
        | (AnyT (_, src), ObjRestT (reason, _, t, _)) ->
          rec_flow_t cx trace ~use_op:unknown_use (AnyT.why src reason, t)
        | (ObjProtoT _, ObjRestT (reason, _, t, _)) ->
          let obj = Obj_type.mk_with_proto cx reason ~obj_kind:Exact l in
          rec_flow_t cx trace ~use_op:unknown_use (obj, t)
        | (DefT (_, (NullT | VoidT)), ObjRestT (reason, _, t, _)) ->
          let o = Obj_type.mk ~obj_kind:Exact cx reason in
          rec_flow_t cx trace ~use_op:unknown_use (o, t)
        (*******************************************)
        (* objects may have their fields looked up *)
        (*******************************************)
        | ( DefT (reason_obj, ObjT o),
            LookupT
              {
                reason = reason_op;
                lookup_kind;
                try_ts_on_failure;
                propref;
                lookup_action = action;
                ids;
                method_accessible;
                ignore_dicts;
              }
          ) ->
          (match
             GetPropTKit.get_obj_prop
               cx
               trace
               unknown_use
               ~skip_optional:false
                 (* TODO: make `no_unchecked_indexed_access=true` work in deeper prototypes. *)
               ~never_union_void_on_computed_prop_access:true
               o
               propref
               reason_op
           with
          | Some (p, target_kind) ->
            (match lookup_kind with
            | NonstrictReturning (_, Some (id, _)) -> Context.test_prop_hit cx id
            | _ -> ());
            perform_lookup_action cx trace propref p target_kind reason_obj reason_op action
          | None ->
            rec_flow
              cx
              trace
              ( o.proto_t,
                LookupT
                  {
                    reason = reason_op;
                    lookup_kind;
                    try_ts_on_failure;
                    propref;
                    lookup_action = action;
                    method_accessible;
                    ids = Base.Option.map ids ~f:(Properties.Set.add o.props_tmap);
                    ignore_dicts;
                  }
              ))
        | ( AnyT (reason, src),
            LookupT
              {
                reason = reason_op;
                lookup_kind;
                try_ts_on_failure = _;
                propref;
                lookup_action = action;
                ids = _;
                method_accessible = _;
                ignore_dicts = _;
              }
          ) ->
          (match action with
          | SuperProp (_, lp) when Property.write_t_of_property_type lp = None ->
            (* Without this exception, we will call rec_flow_p where
             * `write_t lp = None` and `write_t up = Some`, which is a polarity
             * mismatch error. Instead of this, we could "read" `mixed` from
             * covariant props, which would always flow into `any`. *)
            ()
          | _ ->
            let src = any_mod_src_keep_placeholder Untyped src in
            let p = OrdinaryField { type_ = AnyT.why src reason_op; polarity = Polarity.Neutral } in
            (match lookup_kind with
            | NonstrictReturning (_, Some (id, _)) -> Context.test_prop_hit cx id
            | _ -> ());
            perform_lookup_action cx trace propref p DynamicProperty reason reason_op action)
        (*****************************************)
        (* ... and their fields written *)
        (*****************************************)
        (* o.x = ... has the additional effect of o[_] = ... **)
        | (DefT (_, ObjT { flags; _ }), SetPropT (use_op, _, propref, _, _, _, _))
          when obj_is_readonlyish flags && not (is_exception_to_react_dro propref) ->
          let reason_prop = reason_of_propref propref in
          let prop_name = name_of_propref propref in
          let use_op =
            match flags.react_dro with
            | Some dro -> Frame (ReactDeepReadOnly dro, use_op)
            | None -> use_op
          in
          add_output cx (Error_message.EPropNotWritable { reason_prop; prop_name; use_op })
        | (DefT (reason_obj, ObjT o), SetPropT (use_op, reason_op, propref, mode, _, tin, prop_t))
          ->
          write_obj_prop cx trace ~use_op ~mode o propref reason_obj reason_op tin prop_t
        (* Since we don't know the type of the prop, use AnyT. *)
        | (AnyT (_, src), SetPropT (use_op, reason_op, _, _, _, t, prop_t)) ->
          let src = any_mod_src_keep_placeholder Untyped src in
          Base.Option.iter
            ~f:(fun t -> rec_flow_t cx trace ~use_op:unknown_use (AnyT.why src reason_op, t))
            prop_t;
          rec_flow cx trace (t, UseT (use_op, AnyT.why src reason_op))
        (*****************************)
        (* ... and their fields read *)
        (*****************************)
        | ( DefT (_, ObjT _),
            GetPropT { reason; propref = Named { name = OrdinaryName "constructor"; _ }; tout; _ }
          ) ->
          rec_flow_t cx trace ~use_op:unknown_use (Unsoundness.why Constructor reason, OpenT tout)
        | ( DefT (reason_obj, ObjT o),
            GetPropT
              { use_op; reason = reason_op; id; from_annot; skip_optional; propref; tout; hint = _ }
          ) ->
          let lookup_info =
            Base.Option.map id ~f:(fun id ->
                let lookup_default_tout =
                  Tvar.mk_where cx reason_op (fun tvar ->
                      rec_flow_t ~use_op cx trace (tvar, OpenT tout)
                  )
                in
                (id, lookup_default_tout)
            )
          in
          GetPropTKit.read_obj_prop
            cx
            trace
            ~use_op
            ~from_annot
            ~skip_optional
            o
            propref
            reason_obj
            reason_op
            lookup_info
            tout
        | ( AnyT (_, src),
            GetPropT
              {
                use_op = _;
                reason;
                id;
                from_annot = _;
                skip_optional = _;
                propref = _;
                tout;
                hint = _;
              }
          ) ->
          Base.Option.iter id ~f:(Context.test_prop_hit cx);
          let src = any_mod_src_keep_placeholder Untyped src in
          rec_flow_t cx trace ~use_op:unknown_use (AnyT.why src reason, OpenT tout)
        | (AnyT (_, src), GetPrivatePropT (_, reason, _, _, _, tout)) ->
          let src = any_mod_src_keep_placeholder Untyped src in
          rec_flow_t cx trace ~use_op:unknown_use (AnyT.why src reason, OpenT tout)
        (********************************)
        (* ... and their methods called *)
        (********************************)
        | ( DefT (_, ObjT _),
            MethodT (_, reason_call, _, Named { name = OrdinaryName "constructor"; _ }, action)
          ) ->
          add_specialized_callee_method_action cx trace (AnyT.untyped reason_call) action
        | (DefT (reason_obj, ObjT o), MethodT (use_op, reason_call, reason_lookup, propref, action))
          ->
          let t =
            Tvar.mk_no_wrap_where cx reason_lookup (fun tout ->
                GetPropTKit.read_obj_prop
                  cx
                  trace
                  ~use_op
                  ~from_annot:false
                  ~skip_optional:false
                  o
                  propref
                  reason_obj
                  reason_lookup
                  None
                  tout
            )
          in
          apply_method_action cx trace t use_op reason_call l action
        (******************************************)
        (* strings may have their characters read *)
        (******************************************)
        | ( DefT (reason_s, (StrGeneralT _ | SingletonStrT _)),
            GetElemT
              {
                use_op;
                reason = reason_op;
                id = _;
                from_annot = _;
                skip_optional = _;
                access_iterables = _;
                key_t;
                tout;
              }
          ) ->
          rec_flow cx trace (key_t, UseT (use_op, NumModuleT.why reason_s));
          rec_flow_t cx trace ~use_op:unknown_use (StrModuleT.why reason_op, OpenT tout)
        (* Expressions may be used as keys to access objects and arrays. In
           general, we cannot evaluate such expressions at compile time. However,
           in some idiomatic special cases, we can; in such cases, we know exactly
           which strings/numbers the keys may be, and thus, we can use precise
           properties and indices to resolve the accesses. *)
        (**********************************************************************)
        (* objects/arrays may have their properties/elements written and read *)
        (**********************************************************************)
        | ( (DefT (_, (ObjT _ | ArrT _ | InstanceT _)) | AnyT _),
            SetElemT (use_op, reason, key, mode, tin, tout)
          ) ->
          let action = WriteElem { tin; tout; mode } in
          rec_flow cx trace (key, ElemT { use_op; reason; obj = l; action })
        | ( (DefT (_, (ObjT _ | ArrT _ | InstanceT _)) | AnyT _),
            GetElemT
              { use_op; reason; id; from_annot; skip_optional; access_iterables; key_t; tout }
          ) ->
          let action = ReadElem { id; from_annot; skip_optional; access_iterables; tout } in
          rec_flow cx trace (key_t, ElemT { use_op; reason; obj = l; action })
        | ( (DefT (_, (ObjT _ | ArrT _ | InstanceT _)) | AnyT _),
            CallElemT (use_op, reason_call, reason_lookup, key, action)
          ) ->
          let action = CallElem (reason_call, action) in
          rec_flow cx trace (key, ElemT { use_op; reason = reason_lookup; obj = l; action })
        (* If we are accessing `Iterable<T>` with a number, and have `access_iterables = true`,
           then output `T`. *)
        | ( DefT (_, (NumGeneralT _ | SingletonNumT _)),
            ElemT
              {
                use_op;
                obj =
                  DefT
                    ( _,
                      InstanceT
                        { super = _; inst = { class_id; type_args = (_, _, t, _) :: _; _ }; _ }
                    );
                action = ReadElem { access_iterables = true; tout; _ };
                _;
              }
          )
          when is_builtin_iterable_class_id class_id cx ->
          rec_flow_t cx trace ~use_op (t, OpenT tout)
        | (_, ElemT { use_op; reason; obj = DefT (_, (ObjT _ | InstanceT _)) as obj; action }) ->
          elem_action_on_obj cx trace ~use_op l obj reason action
        | (_, ElemT { use_op; reason; obj = AnyT (_, src) as obj; action }) ->
          let value = AnyT.why src reason in
          perform_elem_action cx trace ~use_op ~restrict_deletes:false reason obj value action
        (* It is not safe to write to an unknown index in a tuple. However, any is
         * a source of unsoundness, so that's ok. `tup[(0: any)] = 123` should not
         * error when `tup[0] = 123` does not. *)
        | ( AnyT _,
            ElemT
              { use_op; reason = reason_op; obj = DefT (reason_tup, ArrT arrtype) as arr; action }
          ) ->
          let react_dro =
            match (action, arrtype) with
            | ( WriteElem _,
                (ROArrayAT _ | TupleAT { react_dro = Some _; _ } | ArrayAT { react_dro = Some _; _ })
              ) ->
              let reasons = (reason_op, reason_tup) in
              let use_op =
                match arrtype with
                | TupleAT { react_dro = Some dro; _ }
                | ArrayAT { react_dro = Some dro; _ } ->
                  Frame (ReactDeepReadOnly dro, use_op)
                | _ -> use_op
              in
              add_output cx (Error_message.EROArrayWrite (reasons, use_op));
              None
            | ( ReadElem _,
                (ROArrayAT (_, react_dro) | TupleAT { react_dro; _ } | ArrayAT { react_dro; _ })
              ) ->
              react_dro
            | _ -> None
          in
          let value = elemt_of_arrtype arrtype in
          let value =
            match react_dro with
            | Some dro -> mk_react_dro cx use_op dro value
            | None -> value
          in
          perform_elem_action cx trace ~use_op ~restrict_deletes:false reason_op arr value action
        | ( DefT (_, (NumGeneralT _ | SingletonNumT _)),
            ElemT { use_op; reason; obj = DefT (reason_tup, ArrT arrtype) as arr; action }
          ) ->
          let (write_action, read_action, never_union_void_on_computed_prop_access) =
            match action with
            | ReadElem { from_annot; _ } -> (false, true, from_annot)
            | CallElem _ -> (false, false, false)
            | WriteElem _ -> (true, false, true)
          in
          let (value, is_tuple, use_op, react_dro) =
            array_elem_check
              ~write_action
              ~never_union_void_on_computed_prop_access
              cx
              l
              use_op
              reason
              reason_tup
              arrtype
          in
          let value =
            match react_dro with
            | Some dro when read_action -> mk_react_dro cx use_op dro value
            | _ -> value
          in
          perform_elem_action cx trace ~use_op ~restrict_deletes:is_tuple reason arr value action
        | ( DefT (_, ArrT _),
            GetPropT
              {
                use_op = _;
                reason;
                id = _;
                from_annot = _;
                skip_optional = _;
                propref = Named { name = OrdinaryName "constructor"; _ };
                tout;
                hint = _;
              }
          ) ->
          rec_flow_t cx trace ~use_op:unknown_use (Unsoundness.why Constructor reason, OpenT tout)
        | ( DefT (_, ArrT _),
            SetPropT (_, _, Named { name = OrdinaryName "constructor"; _ }, _, _, _, _)
          ) ->
          ()
        | ( DefT (_, ArrT _),
            MethodT (_, reason_call, _, Named { name = OrdinaryName "constructor"; _ }, action)
          ) ->
          add_specialized_callee_method_action cx trace (AnyT.untyped reason_call) action
        (**************************************************)
        (* array pattern can consume the rest of an array *)
        (**************************************************)
        | (DefT (_, ArrT arrtype), ArrRestT (_, reason, i, tout)) ->
          let arrtype =
            match arrtype with
            | ArrayAT { tuple_view = None; _ }
            | ROArrayAT _ ->
              arrtype
            | ArrayAT
                {
                  elem_t;
                  tuple_view = Some (TupleView { elements; arity = (num_req, num_total); inexact });
                  react_dro;
                } ->
              let elements = Base.List.drop elements i in
              let arity = (max (num_req - i) 0, max (num_total - i) 0) in
              ArrayAT
                { elem_t; tuple_view = Some (TupleView { elements; arity; inexact }); react_dro }
            | TupleAT { elem_t; elements; arity = (num_req, num_total); inexact; react_dro } ->
              TupleAT
                {
                  elem_t;
                  elements = Base.List.drop elements i;
                  arity = (max (num_req - i) 0, max (num_total - i) 0);
                  inexact;
                  react_dro;
                }
          in
          let a = DefT (reason, ArrT arrtype) in
          rec_flow_t cx trace ~use_op:unknown_use (a, tout)
        | (AnyT (_, src), ArrRestT (_, reason, _, tout)) ->
          rec_flow_t cx trace ~use_op:unknown_use (AnyT.why src reason, tout)
        (**************************************************)
        (* function types can be mapped over a structure  *)
        (**************************************************)
        | (AnyT (_, src), MapTypeT (_, reason_op, _, tout)) ->
          let src = any_mod_src_keep_placeholder Untyped src in
          rec_flow_t cx trace ~use_op:unknown_use (AnyT.why src reason_op, tout)
        | (DefT (_, ObjT o), MapTypeT (_, reason_op, ObjectKeyMirror, tout)) ->
          rec_flow_t cx trace ~use_op:unknown_use (obj_key_mirror cx o reason_op, tout)
        (**************)
        (* object kit *)
        (**************)
        | ( GenericT { reason; no_infer; bound; _ },
            Object.(
              ObjKitT
                ( use_op,
                  reason_op,
                  Resolve Next,
                  Object.ObjectMap { prop_type; mapped_type_flags; selected_keys_opt = None },
                  tout
                ))
          )
          when speculative_subtyping_succeeds
                 cx
                 bound
                 (DefT (reason, ArrT (ROArrayAT (DefT (reason, MixedT Mixed_everything), None)))) ->
          let (t_generic_id, t) =
            let rec loop t ls =
              match t with
              | GenericT { id; bound; reason; _ } ->
                loop
                  (mod_reason_of_t (fun _ -> reason) bound)
                  (Generic.spread_append (Generic.make_spread id) ls)
              | _ -> (ls, t)
            in
            loop l Generic.spread_empty
          in
          let mapped_bound =
            Tvar.mk_where cx reason_op (fun tout ->
                rec_flow
                  cx
                  trace
                  ( t,
                    ObjKitT
                      ( use_op,
                        reason_op,
                        Object.(Resolve Next),
                        Object.ObjectMap { prop_type; mapped_type_flags; selected_keys_opt = None },
                        tout
                      )
                  )
            )
          in
          let mapped_generic_t =
            Generic.make_op_id Subst_name.Mapped t_generic_id
            |> Base.Option.value_map ~default:t ~f:(fun id ->
                   GenericT
                     {
                       bound = mapped_bound;
                       reason;
                       id;
                       name = Generic.subst_name_of_id id;
                       no_infer;
                     }
               )
          in
          rec_flow_t cx trace ~use_op:unknown_use (mapped_generic_t, tout)
        | ( DefT (_, ArrT arrtype),
            Object.(
              ObjKitT
                ( use_op,
                  reason_op,
                  Resolve Next,
                  Object.ObjectMap
                    {
                      prop_type = property_type;
                      mapped_type_flags =
                        { variance = mapped_type_variance; optional = mapped_type_optionality };
                      selected_keys_opt = None;
                    },
                  OpenT tout
                ))
          ) ->
          let f value_t ~index ~optional =
            let key_t =
              let r = reason_of_t value_t in
              match index with
              | None -> NumModuleT.why r
              | Some i ->
                DefT
                  (r, SingletonNumT { from_annot = true; value = (float_of_int i, string_of_int i) })
            in
            Slice_utils.mk_mapped_prop_type
              ~use_op
              ~mapped_type_optionality
              ~poly_prop:property_type
              key_t
              optional
          in
          let () =
            match mapped_type_variance with
            | Polarity.Neutral -> ()
            | _ ->
              add_output
                cx
                Error_message.(
                  EInvalidMappedType { loc = loc_of_reason reason_op; kind = VarianceOnArrayInput }
                )
          in
          let arrtype =
            match arrtype with
            | ArrayAT { elem_t; tuple_view; react_dro } ->
              ArrayAT
                {
                  elem_t = f ~optional:false ~index:None elem_t;
                  react_dro;
                  tuple_view =
                    Base.Option.map
                      ~f:(fun (TupleView { elements; arity; inexact }) ->
                        let elements =
                          Base.List.mapi
                            ~f:(fun i (TupleElement { name; t; polarity; optional; reason }) ->
                              TupleElement
                                {
                                  name;
                                  t = f ~optional ~index:(Some i) t;
                                  polarity;
                                  optional;
                                  reason;
                                })
                            elements
                        in
                        TupleView { elements; arity; inexact })
                      tuple_view;
                }
            | TupleAT { elem_t; elements; arity; inexact; react_dro } ->
              TupleAT
                {
                  elem_t = f ~optional:false ~index:None elem_t;
                  react_dro;
                  elements =
                    Base.List.mapi
                      ~f:(fun i (TupleElement { name; t; polarity; optional; reason }) ->
                        TupleElement
                          { name; t = f ~optional ~index:(Some i) t; polarity; optional; reason })
                      elements;
                  arity;
                  inexact;
                }
            | ROArrayAT (elemt, dro) -> ROArrayAT (f ~optional:false ~index:None elemt, dro)
          in
          let t =
            let reason = replace_desc_reason RArrayType reason_op in
            DefT (reason, ArrT arrtype)
          in
          rec_flow_t cx trace ~use_op:unknown_use (t, OpenT tout)
        | (_, ObjKitT (use_op, reason, resolve_tool, tool, tout)) ->
          ObjectKit.run trace cx use_op reason resolve_tool tool ~tout l
        (************************************************************************)
        (* functions may be bound by passing a receiver and (partial) arguments *)
        (************************************************************************)
        | (FunProtoBindT _, CallT { use_op; call_action = ConcretizeCallee tout; _ }) ->
          rec_flow_t cx trace ~use_op (l, OpenT tout)
        | ( FunProtoBindT lreason,
            CallT
              {
                use_op;
                reason = reason_op;
                call_action =
                  Funcalltype
                    ( {
                        call_this_t = func;
                        call_targs;
                        call_args_tlist = first_arg :: call_args_tlist;
                        _;
                      } as funtype
                    );
                return_hint = _;
              }
          ) ->
          Base.Option.iter call_targs ~f:(fun _ ->
              add_output
                cx
                Error_message.(
                  ECallTypeArity
                    {
                      call_loc = loc_of_reason reason_op;
                      is_new = false;
                      reason_arity = lreason;
                      expected_arity = 0;
                    }
                )
          );
          let call_this_t = extract_non_spread cx first_arg in
          let call_targs = None in
          let funtype = { funtype with call_this_t; call_targs; call_args_tlist } in
          rec_flow cx trace (func, BindT (use_op, reason_op, funtype))
        | ( DefT (reason, FunT (_, ({ this_t = (o1, _); _ } as ft))),
            BindT (use_op, reason_op, calltype)
          ) ->
          let {
            call_this_t = o2;
            call_targs = _;
            (* always None *)
            call_args_tlist = tins2;
            call_tout;
            call_strict_arity = _;
            call_speculation_hint_state = _;
            call_specialized_callee;
          } =
            calltype
          in
          CalleeRecorder.add_callee cx CalleeRecorder.All l call_specialized_callee;
          (* TODO: closure *)
          rec_flow_t cx trace ~use_op (o2, o1);

          let resolve_to =
            ResolveSpreadsToMultiflowPartial (mk_id (), ft, reason_op, OpenT call_tout)
          in
          resolve_call_list cx ~trace ~use_op reason tins2 resolve_to
        | (DefT (_, ObjT { call_t = Some id; _ }), BindT _) ->
          rec_flow cx trace (Context.find_call cx id, u)
        | (DefT (_, InstanceT { inst = { inst_call_t = Some id; _ }; _ }), BindT _) ->
          rec_flow cx trace (Context.find_call cx id, u)
        | (AnyT (_, src), BindT (use_op, reason, calltype)) ->
          let {
            call_this_t;
            call_targs = _;
            (* always None *)
            call_args_tlist;
            call_tout;
            call_strict_arity = _;
            call_speculation_hint_state = _;
            call_specialized_callee;
          } =
            calltype
          in
          CalleeRecorder.add_callee cx CalleeRecorder.All l call_specialized_callee;
          let src = any_mod_src_keep_placeholder Untyped src in
          rec_flow_t cx trace ~use_op:unknown_use (AnyT.why src reason, call_this_t);
          call_args_iter
            (fun param_t -> rec_flow cx trace (AnyT.why src reason, UseT (use_op, param_t)))
            call_args_tlist;
          rec_flow_t cx trace ~use_op:unknown_use (l, OpenT call_tout)
        (***************************************************************)
        (* Enable structural subtyping for upperbounds like interfaces *)
        (***************************************************************)
        | ((ObjProtoT _ | FunProtoT _ | DefT (_, NullT)), ImplementsT _) -> ()
        | ( DefT
              ( reason_inst,
                InstanceT
                  {
                    super;
                    inst =
                      {
                        own_props;
                        proto_props;
                        inst_call_t;
                        inst_kind = InterfaceKind _;
                        inst_dict;
                        _;
                      };
                    _;
                  }
              ),
            ImplementsT (use_op, t)
          ) ->
          structural_subtype
            cx
            trace
            ~use_op
            t
            reason_inst
            (own_props, proto_props, inst_call_t, inst_dict);
          rec_flow
            cx
            trace
            ( super,
              ReposLowerT
                { reason = reason_inst; use_desc = false; use_t = ImplementsT (use_op, t) }
            )
        | (_, ImplementsT _) -> add_output cx (Error_message.EUnsupportedImplements (reason_of_t l))
        (*********************************************************************)
        (* class A is a base class of class B iff                            *)
        (* properties in B that override properties in A or its base classes *)
        (* have the same signatures                                          *)
        (*********************************************************************)

        (* The purpose of SuperT is to establish consistency between overriding
           properties with overridden properties. As such, the lookups performed
           for the inherited properties are non-strict: they are not required to
           exist. **)
        | ( DefT (ureason, InstanceT { static = st; _ }),
            SuperT (use_op, reason, Derived { own; proto; static })
          ) ->
          let check_super l = check_super cx trace ~use_op reason ureason l in
          NameUtils.Map.iter (check_super l) own;
          NameUtils.Map.iter (fun x p -> if inherited_method x then check_super l x p) proto;

          (* TODO: inherited_method logic no longer applies for statics. It used to
             when call properties were included in the props, but that is no longer
             the case. All that remains is the "constructor" prop, which has no
             special meaning on the static object. *)
          NameUtils.Map.iter (fun x p -> if inherited_method x then check_super st x p) static
        (***********************)
        (* opaque types part 2 *)
        (***********************)

        (* Predicate_kit should not see unwrapped opaque type *)
        | ( OpaqueT _,
            ConcretizeT { reason = _; kind = ConcretizeForPredicate _; seen = _; collector }
          ) ->
          TypeCollector.add collector l
        | (OpaqueT _, SealGenericT { reason = _; id; name; cont; no_infer }) ->
          let reason = reason_of_t l in
          continue cx trace (GenericT { reason; id; name; bound = l; no_infer }) cont
        (* Preserve OpaqueT as consequent, but branch based on the bound *)
        | (OpaqueT (_, { upper_t = Some t; _ }), CondT (r, then_t_opt, else_t, tout)) ->
          let then_t_opt =
            match then_t_opt with
            | Some _ -> then_t_opt
            | None -> Some l
          in
          rec_flow cx trace (t, CondT (r, then_t_opt, else_t, tout))
        (* Opaque types may be treated as their supertype when they are a lower bound for a use *)
        | (OpaqueT (opaque_t_reason, { upper_t = Some t; _ }), _) ->
          rec_flow
            cx
            trace
            ( t,
              mod_use_op_of_use_t
                (fun use_op -> Frame (OpaqueTypeUpperBound { opaque_t_reason }, use_op))
                u
            )
        (* Concretize types for type operation purpose up to this point. The rest are
           recorded as lower bound to the target tvar. *)
        | (t, ConcretizeT { reason = _; kind = ConcretizeForOperatorsChecking; seen = _; collector })
          ->
          TypeCollector.add collector t
        (**************************************************************************)
        (* final shared concretization point for predicate and sentinel prop test *)
        (**************************************************************************)
        | (_, ConcretizeT { reason = _; kind = ConcretizeForPredicate _; seen = _; collector })
        | (_, ConcretizeT { reason = _; kind = ConcretizeForSentinelPropTest; seen = _; collector })
          ->
          TypeCollector.add collector l
        (******************************)
        (* functions statics - part B *)
        (******************************)
        | (DefT (reason, FunT (static, _)), _) when object_like_op u ->
          rec_flow cx trace (static, ReposLowerT { reason; use_desc = false; use_t = u })
        (*****************************************)
        (* classes can have their prototype read *)
        (*****************************************)
        | ( DefT (reason, ClassT instance),
            GetPropT
              {
                use_op = _;
                reason = _;
                id = _;
                from_annot = _;
                skip_optional = _;
                propref = Named { name = OrdinaryName "prototype"; _ };
                tout;
                hint = _;
              }
          ) ->
          let instance = reposition cx ~trace (loc_of_reason reason) instance in
          rec_flow_t cx trace ~use_op:unknown_use (instance, OpenT tout)
        (*****************)
        (* class statics *)
        (*****************)

        (* For Get/SetPrivatePropT or PrivateMethodT, the instance id is needed to determine whether
         * or not the private static field exists on that class. Since we look through the scopes for
         * the type of the field, there is no need to look at the static member of the instance.
         * Instead, we just flip the boolean flag to true, indicating that when the
         * InstanceT ~> Set/GetPrivatePropT or PrivateMethodT constraint is processed that we should
         * look at the private static fields instead of the private instance fields. *)
        | (DefT (reason, ClassT instance), GetPrivatePropT (use_op, reason_op, x, scopes, _, tout))
          ->
          let u = GetPrivatePropT (use_op, reason_op, x, scopes, true, tout) in
          rec_flow cx trace (instance, ReposLowerT { reason; use_desc = false; use_t = u })
        | ( DefT (reason, ClassT instance),
            SetPrivatePropT (use_op, reason_op, x, mode, scopes, _, wr_ctx, tout, tp)
          ) ->
          let u = SetPrivatePropT (use_op, reason_op, x, mode, scopes, true, wr_ctx, tout, tp) in
          rec_flow cx trace (instance, ReposLowerT { reason; use_desc = false; use_t = u })
        | ( DefT (reason, ClassT instance),
            PrivateMethodT (use_op, reason_op, reason_lookup, prop_name, scopes, _, action)
          ) ->
          let u =
            PrivateMethodT (use_op, reason_op, reason_lookup, prop_name, scopes, true, action)
          in
          rec_flow cx trace (instance, ReposLowerT { reason; use_desc = false; use_t = u })
        | ( DefT (reason, ClassT instance),
            MethodT (use_op, reason_call, reason_lookup, propref, action)
          ) ->
          let statics = (reason, Tvar.mk_no_wrap cx reason) in
          rec_flow cx trace (instance, GetStaticsT statics);
          let method_type =
            Tvar.mk_no_wrap_where cx reason_lookup (fun tout ->
                let u =
                  GetPropT
                    {
                      use_op;
                      reason = reason_lookup;
                      id = None;
                      from_annot = false;
                      skip_optional = false;
                      propref;
                      tout;
                      hint = hint_unavailable;
                    }
                in
                rec_flow
                  cx
                  trace
                  (OpenT statics, ReposLowerT { reason; use_desc = false; use_t = u })
            )
          in
          apply_method_action cx trace method_type use_op reason_call l action
        | (DefT (reason, ClassT instance), _) when object_like_op u ->
          let statics = (reason, Tvar.mk_no_wrap cx reason) in
          rec_flow cx trace (instance, GetStaticsT statics);
          rec_flow cx trace (OpenT statics, u)
        (************************)
        (* classes as functions *)
        (************************)

        (* When a class value flows to a function annotation or call site, check for
           the presence of a call property in the former (as a static) compatible
           with the latter.

           TODO: Call properties are excluded from the subclass compatibility
           checks, which makes it unsafe to call a Class<T> type like this.
           For example:

               declare class A { static (): string };
               declare class B extends A { static (): number }
               var klass: Class<A> = B;
               var foo: string = klass(); // passes, but `foo` is a number

           The same issue is also true for constructors, which are similarly
           excluded from subclass compatibility checks, but are allowed on ClassT
           types.
        *)
        | (DefT (reason, ClassT instance), CallT _) ->
          let statics = (reason, Tvar.mk_no_wrap cx reason) in
          rec_flow cx trace (instance, GetStaticsT statics);
          rec_flow cx trace (OpenT statics, u)
        (*********)
        (* enums *)
        (*********)
        | ( DefT (enum_reason, EnumObjectT { enum_value_t; enum_info = ConcreteEnum enum_info }),
            GetPropT
              {
                use_op;
                reason = access_reason;
                id = _;
                from_annot = _;
                skip_optional = _;
                propref = Named { reason = prop_reason; name = member_name; _ };
                tout;
                hint = _;
              }
          ) ->
          let access = (use_op, access_reason, None, (prop_reason, member_name)) in
          GetPropTKit.on_EnumObjectT
            cx
            trace
            enum_reason
            ~enum_object_t:l
            ~enum_value_t
            ~enum_info
            access
            tout
        | (DefT (_, EnumObjectT _), TestPropT { use_op = _; reason; id = _; propref; tout; hint })
          ->
          rec_flow
            cx
            trace
            ( l,
              GetPropT
                {
                  use_op = Op (GetProperty reason);
                  reason;
                  id = None;
                  from_annot = false;
                  skip_optional = false;
                  propref;
                  tout;
                  hint;
                }
            )
        | ( DefT (_, EnumObjectT { enum_value_t; enum_info }),
            MethodT (use_op, call_reason, lookup_reason, (Named _ as propref), action)
          ) ->
          let t =
            Tvar.mk_no_wrap_where cx lookup_reason (fun tout ->
                let representation_t =
                  match enum_info with
                  | ConcreteEnum { representation_t; _ }
                  | AbstractEnum { representation_t } ->
                    representation_t
                in
                rec_flow
                  cx
                  trace
                  ( enum_proto
                      cx
                      ~reason:lookup_reason
                      ~enum_object_t:l
                      ~enum_value_t
                      ~representation_t,
                    GetPropT
                      {
                        use_op;
                        reason = lookup_reason;
                        id = None;
                        from_annot = false;
                        skip_optional = false;
                        propref;
                        tout;
                        hint = hint_unavailable;
                      }
                  )
            )
          in
          apply_method_action cx trace t use_op call_reason l action
        | (DefT (enum_reason, EnumObjectT _), GetElemT { key_t; tout; _ }) ->
          let reason = reason_of_t key_t in
          add_output
            cx
            (Error_message.EEnumInvalidMemberAccess
               { member_name = None; suggestion = None; reason; enum_reason }
            );
          rec_flow_t cx trace ~use_op:unknown_use (AnyT.error reason, OpenT tout)
        | (DefT (enum_reason, EnumObjectT _), SetPropT (_, op_reason, _, _, _, _, tout))
        | (DefT (enum_reason, EnumObjectT _), SetElemT (_, op_reason, _, _, _, tout)) ->
          add_output
            cx
            (Error_message.EEnumModification { loc = loc_of_reason op_reason; enum_reason });
          Base.Option.iter tout ~f:(fun tout ->
              rec_flow_t cx trace ~use_op:unknown_use (AnyT.error op_reason, tout)
          )
        | (DefT (enum_reason, EnumObjectT _), GetValuesT (op_reason, tout)) ->
          add_output
            cx
            (Error_message.EEnumInvalidObjectUtilType { reason = op_reason; enum_reason });
          rec_flow_t cx trace ~use_op:unknown_use (AnyT.error op_reason, tout)
        | (DefT (enum_reason, EnumObjectT _), GetDictValuesT (reason, result)) ->
          add_output cx (Error_message.EEnumInvalidObjectFunction { reason; enum_reason });
          rec_flow cx trace (AnyT.error reason, result)
        | ( DefT
              ( _,
                EnumValueT (ConcreteEnum { representation_t; _ } | AbstractEnum { representation_t })
              ),
            MethodT (use_op, call_reason, lookup_reason, (Named _ as propref), action)
          ) ->
          let enum_value_proto =
            FlowJs.get_builtin_typeapp cx lookup_reason "$EnumValueProto" [l; representation_t]
          in
          let t =
            Tvar.mk_no_wrap_where cx lookup_reason (fun tout ->
                rec_flow
                  cx
                  trace
                  ( enum_value_proto,
                    GetPropT
                      {
                        use_op;
                        reason = lookup_reason;
                        id = None;
                        from_annot = false;
                        skip_optional = false;
                        propref;
                        tout;
                        hint = hint_unavailable;
                      }
                  )
            )
          in
          apply_method_action cx trace t use_op call_reason l action
        (**************************************************************************)
        (* TestPropT is emitted for property reads in the context of branch tests.
           Such tests are always non-strict, in that we don't immediately report an
           error if the property is not found not in the object type. Instead, if
           the property is not found, we control the result type of the read based
           on the flags on the object type. For exact object types, the
           result type is `void`; otherwise, it is "unknown". Indeed, if the
           property is not found in an exact object type, we can be sure it
           won't exist at run time, so the read will return undefined; but for other
           object types, the property *might* exist at run time, and since we don't
           know what the type of the property would be, we set things up so that the
           result of the read cannot be used in any interesting way. *)
        (**************************************************************************)
        | (DefT (_, (NullT | VoidT)), TestPropT { use_op; reason; id; propref; tout; hint }) ->
          (* The wildcard TestPropT implementation forwards the lower bound to
             LookupT. This is unfortunate, because LookupT is designed to terminate
             (successfully) on NullT, but property accesses on null should be type
             errors. Ideally, we should prevent LookupT constraints from being
             syntax-driven, in order to preserve the delicate invariants that
             surround it. *)
          rec_flow
            cx
            trace
            ( l,
              GetPropT
                {
                  use_op;
                  reason;
                  id = Some id;
                  from_annot = false;
                  skip_optional = false;
                  propref;
                  tout;
                  hint;
                }
            )
        | (DefT (r, MixedT (Mixed_truthy | Mixed_non_maybe)), TestPropT { use_op; id; tout; _ }) ->
          (* Special-case property tests of definitely non-null/non-void values to
             return mixed and treat them as a hit. *)
          Context.test_prop_hit cx id;
          rec_flow_t cx trace ~use_op (DefT (r, MixedT Mixed_everything), OpenT tout)
        | ( _,
            TestPropT
              {
                use_op;
                reason;
                id;
                propref = Named { name = OrdinaryName "constructor"; _ } as propref;
                tout;
                hint;
              }
          ) ->
          rec_flow
            cx
            trace
            ( l,
              GetPropT
                {
                  use_op;
                  reason;
                  id = Some id;
                  from_annot = false;
                  skip_optional = false;
                  propref;
                  tout;
                  hint;
                }
            )
        | (_, TestPropT { use_op; reason = reason_op; id; propref; tout; hint = _ }) ->
          (* NonstrictReturning lookups unify their result, but we don't want to
             unify with the tout tvar directly, so we create an indirection here to
             ensure we only supply lower bounds to tout. *)
          let lookup_default =
            Tvar.mk_where cx reason_op (fun tvar -> rec_flow_t ~use_op cx trace (tvar, OpenT tout))
          in
          let name = name_of_propref propref in
          let reason_prop =
            match propref with
            | Named { reason; _ } -> reason
            | Computed _ -> reason_op
          in
          let test_info = Some (id, (reason_prop, reason_of_t l)) in
          let lookup_default =
            match l with
            | DefT (_, ObjT { flags; _ }) when Obj_type.is_exact flags.obj_kind ->
              let r = replace_desc_reason (RMissingProperty name) reason_op in
              Some (DefT (r, VoidT), lookup_default)
            | _ ->
              (* Note: a lot of other types could in principle be considered
                 "exact". For example, new instances of classes could have exact
                 types; so could `super` references (since they are statically
                 rather than dynamically bound). However, currently we don't support
                 any other exact types. Considering exact types inexact is sound, so
                 there is no problem falling back to the same conservative
                 approximation we use for inexact types in those cases. *)
              let r = replace_desc_reason (RUnknownProperty name) reason_op in
              Some (DefT (r, MixedT Mixed_everything), lookup_default)
          in
          let lookup_kind = NonstrictReturning (lookup_default, test_info) in
          rec_flow
            cx
            trace
            ( l,
              LookupT
                {
                  reason = reason_op;
                  lookup_kind;
                  try_ts_on_failure = [];
                  propref;
                  lookup_action = ReadProp { use_op; obj_t = l; tout };
                  method_accessible =
                    begin
                      match l with
                      | DefT (_, InstanceT _) -> false
                      | _ -> true
                    end;
                  ids = Some Properties.Set.empty;
                  ignore_dicts = false;
                }
            )
        (***************************)
        (* conditional type switch *)
        (***************************)

        (* Use our alternate if our lower bound is empty. *)
        | (DefT (_, EmptyT), CondT (_, _, else_t, tout)) ->
          rec_flow_t cx trace ~use_op:unknown_use (else_t, tout)
        (* Otherwise continue by Flowing out lower bound to tout. *)
        | (_, CondT (_, then_t_opt, _, tout)) ->
          let then_t =
            match then_t_opt with
            | Some t -> t
            | None -> l
          in
          rec_flow_t cx trace ~use_op:unknown_use (then_t, tout)
        (*****************)
        (* repositioning *)
        (*****************)

        (* waits for a lower bound to become concrete, and then repositions it to
           the location stored in the ReposLowerT, which is usually the location
           where that lower bound was used; the lower bound's location (which is
           being overwritten) is where it was defined. *)
        | (_, ReposLowerT { reason; use_desc; use_t = u }) ->
          rec_flow cx trace (reposition_reason cx ~trace reason ~use_desc l, u)
        (***********************************************************)
        (* generics                                                *)
        (***********************************************************)
        | (_, SealGenericT { reason = _; id; name; cont; no_infer }) ->
          let reason = reason_of_t l in
          continue cx trace (GenericT { reason; id; name; bound = l; no_infer }) cont
        | (GenericT { reason; bound; _ }, _) ->
          rec_flow cx trace (reposition_reason cx reason bound, u)
        (************)
        (* GetEnumT *)
        (************)
        | ( DefT (enum_reason, EnumValueT enum_info),
            GetEnumT { use_op; orig_t; kind = `GetEnumObject; tout; _ }
          ) ->
          let enum_value_t = Base.Option.value ~default:l orig_t in
          rec_flow
            cx
            trace
            (DefT (enum_reason, EnumObjectT { enum_value_t; enum_info }), UseT (use_op, tout))
        | (_, GetEnumT { use_op; kind = `GetEnumObject; tout; _ }) ->
          rec_flow cx trace (l, UseT (use_op, tout))
        | ( DefT (_, EnumObjectT { enum_value_t; _ }),
            GetEnumT { use_op; kind = `GetEnumValue; tout; _ }
          ) ->
          rec_flow cx trace (enum_value_t, UseT (use_op, tout))
        | (_, GetEnumT { use_op; kind = `GetEnumValue; tout; _ }) ->
          rec_flow cx trace (l, UseT (use_op, tout))
        (**********************************)
        (* Flow Enums exhaustive checking *)
        (**********************************)
        (* Entry point to exhaustive checking logic - when resolving the discriminant as an enum. *)
        | ( DefT (enum_reason, EnumValueT (ConcreteEnum enum_info)),
            EnumExhaustiveCheckT
              {
                reason = check_reason;
                check =
                  EnumExhaustiveCheckPossiblyValid
                    { tool = EnumResolveDiscriminant; possible_checks; checks; default_case_loc };
                incomplete_out;
                discriminant_after_check;
              }
          ) ->
          enum_exhaustive_check
            cx
            ~trace
            ~check_reason
            ~enum_reason
            ~enum:enum_info
            ~possible_checks
            ~checks
            ~default_case_loc
            ~incomplete_out
            ~discriminant_after_check
        | (DefT (enum_reason, EnumValueT (AbstractEnum _)), EnumExhaustiveCheckT { reason; _ }) ->
          add_output cx (Error_message.EEnumInvalidAbstractUse { reason; enum_reason })
        (* Resolving the case tests. *)
        | ( _,
            EnumExhaustiveCheckT
              {
                reason = check_reason;
                check =
                  EnumExhaustiveCheckPossiblyValid
                    {
                      tool = EnumResolveCaseTest { discriminant_reason; discriminant_enum; check };
                      possible_checks;
                      checks;
                      default_case_loc;
                    };
                incomplete_out;
                discriminant_after_check;
              }
          ) ->
          let (EnumCheck { member_name; _ }) = check in
          let { enum_id = enum_id_discriminant; members; _ } = discriminant_enum in
          let checks =
            match l with
            | DefT (_, EnumObjectT { enum_info = ConcreteEnum { enum_id = enum_id_check; _ }; _ })
              when ALoc.equal_id enum_id_discriminant enum_id_check && SMap.mem member_name members
              ->
              check :: checks
            (* If the check is not the same enum type, ignore it and continue. The user will
             * still get an error as the comparison between discriminant and case test will fail. *)
            | _ -> checks
          in
          enum_exhaustive_check
            cx
            ~trace
            ~check_reason
            ~enum_reason:discriminant_reason
            ~enum:discriminant_enum
            ~possible_checks
            ~checks
            ~default_case_loc
            ~incomplete_out
            ~discriminant_after_check
        | ( DefT (enum_reason, EnumValueT enum_info),
            EnumExhaustiveCheckT
              {
                reason;
                check = EnumExhaustiveCheckInvalid reasons;
                incomplete_out;
                discriminant_after_check = _;
              }
          ) ->
          let example_member =
            match enum_info with
            | ConcreteEnum { members; _ } -> SMap.choose_opt members |> Base.Option.map ~f:fst
            | AbstractEnum _ -> None
          in
          List.iter
            (fun loc ->
              add_output
                cx
                (Error_message.EEnumInvalidCheck
                   { loc; enum_reason; example_member; from_match = false }
                ))
            reasons;
          enum_exhaustive_check_incomplete cx ~trace ~reason incomplete_out
        (* If the discriminant is empty, the check is successful. *)
        | ( DefT (_, EmptyT),
            EnumExhaustiveCheckT
              {
                check =
                  ( EnumExhaustiveCheckInvalid _
                  | EnumExhaustiveCheckPossiblyValid { tool = EnumResolveDiscriminant; _ } );
                _;
              }
          ) ->
          ()
        (* Non-enum discriminants.
         * If `discriminant_after_check` is empty (e.g. because the discriminant has been refined
         * away by each case), then `trigger` will be empty, which will prevent the implicit void
         * return that could occur otherwise. *)
        | ( _,
            EnumExhaustiveCheckT
              {
                reason;
                check =
                  ( EnumExhaustiveCheckInvalid _
                  | EnumExhaustiveCheckPossiblyValid { tool = EnumResolveDiscriminant; _ } );
                incomplete_out;
                discriminant_after_check;
              }
          ) ->
          enum_exhaustive_check_incomplete
            cx
            ~trace
            ~reason
            ?trigger:discriminant_after_check
            incomplete_out
        (***************)
        (* unsupported *)
        (***************)

        (* Lookups can be strict or non-strict, as denoted by the presence or
           absence of strict_reason in the following two pattern matches.
           Strictness derives from whether the object is sealed and was
           created in the same scope in which the lookup occurs - see
           mk_strict_lookup_reason below. The failure of a strict lookup
           to find the desired property causes an error; a non-strict one
           does not.
        *)
        | ( (DefT (_, NullT) | ObjProtoT _),
            LookupT
              {
                reason;
                lookup_kind;
                try_ts_on_failure = next :: try_ts_on_failure;
                propref;
                lookup_action;
                method_accessible;
                ids;
                ignore_dicts;
              }
          ) ->
          (* When s is not found, we always try to look it up in the next element in
             the list try_ts_on_failure. *)
          rec_flow
            cx
            trace
            ( next,
              LookupT
                {
                  reason;
                  lookup_kind;
                  try_ts_on_failure;
                  propref;
                  lookup_action;
                  method_accessible;
                  ids;
                  ignore_dicts;
                }
            )
        | ( (ObjProtoT _ | FunProtoT _),
            LookupT
              {
                reason = reason_op;
                lookup_kind = _;
                try_ts_on_failure = [];
                propref = Named { name = OrdinaryName "__proto__"; _ };
                lookup_action = ReadProp { use_op = _; obj_t = l; tout };
                ids = _;
                method_accessible = _;
                ignore_dicts = _;
              }
          ) ->
          (* __proto__ is a getter/setter on Object.prototype *)
          rec_flow cx trace (l, GetProtoT (reason_op, tout))
        | ( (ObjProtoT _ | FunProtoT _),
            LookupT
              {
                reason = reason_op;
                lookup_kind = _;
                try_ts_on_failure = [];
                propref = Named { name = OrdinaryName "__proto__"; _ };
                lookup_action =
                  WriteProp { use_op = _; obj_t = l; prop_tout = _; tin; write_ctx = _; mode = _ };
                method_accessible = _;
                ids = _;
                ignore_dicts = _;
              }
          ) ->
          (* __proto__ is a getter/setter on Object.prototype *)
          rec_flow cx trace (l, SetProtoT (reason_op, tin))
        | ( ObjProtoT _,
            LookupT { reason = reason_op; try_ts_on_failure = []; propref = Named { name; _ }; _ }
          )
          when is_object_prototype_method name ->
          (* TODO: These properties should go in Object.prototype. Currently we
             model Object.prototype as a ObjProtoT, as an optimization against a
             possible deluge of shadow properties on Object.prototype, since it
             is shared by every object. **)
          rec_flow cx trace (get_builtin_type cx ~trace reason_op "Object", u)
        | (FunProtoT _, LookupT { reason = reason_op; propref = Named { name; _ }; _ })
          when is_function_prototype name ->
          (* TODO: Ditto above comment for Function.prototype *)
          rec_flow cx trace (get_builtin_type cx ~trace reason_op "Function", u)
        | ( (DefT (reason, NullT) | ObjProtoT reason | FunProtoT reason),
            LookupT
              {
                reason = reason_op;
                lookup_kind = Strict strict_reason;
                try_ts_on_failure = [];
                propref = Named { reason = reason_prop; name; _ } as propref;
                lookup_action = action;
                method_accessible = _;
                ids;
                ignore_dicts = _;
              }
          ) ->
          let error_message =
            let use_op = use_op_of_lookup_action action in
            let suggestion =
              Base.Option.bind ids ~f:(fun ids ->
                  prop_typo_suggestion cx (Properties.Set.elements ids) (display_string_of_name name)
              )
            in
            Error_message.EPropNotFound
              { reason_prop; reason_obj = strict_reason; prop_name = Some name; use_op; suggestion }
          in
          add_output cx error_message;
          let p =
            OrdinaryField
              { type_ = AnyT.error_of_kind UnresolvedName reason_op; polarity = Polarity.Neutral }
          in
          perform_lookup_action cx trace propref p DynamicProperty reason reason_op action
        | ( (DefT (reason, NullT) | ObjProtoT reason | FunProtoT reason),
            LookupT
              {
                reason = reason_op;
                lookup_kind = Strict strict_reason;
                try_ts_on_failure = [];
                propref = Computed elem_t as propref;
                lookup_action = action;
                method_accessible = _;
                ids = _;
                ignore_dicts = _;
              }
          ) ->
          (match elem_t with
          | OpenT _ ->
            let loc = loc_of_t elem_t in
            add_output cx Error_message.(EInternal (loc, PropRefComputedOpen))
          | DefT (_, SingletonStrT _) ->
            let loc = loc_of_t elem_t in
            add_output cx Error_message.(EInternal (loc, PropRefComputedLiteral))
          | AnyT (_, src) ->
            let src = any_mod_src_keep_placeholder Untyped src in
            let p = OrdinaryField { type_ = AnyT.why src reason_op; polarity = Polarity.Neutral } in
            perform_lookup_action cx trace propref p DynamicProperty reason reason_op action
          | _ ->
            let reason_prop = reason_op in
            let error_message =
              let use_op = use_op_of_lookup_action action in
              Error_message.EPropNotFound
                {
                  reason_prop;
                  reason_obj = strict_reason;
                  prop_name = None;
                  use_op;
                  suggestion = None;
                }
            in
            add_output cx error_message)
        (* LookupT is a non-strict lookup *)
        | ( (DefT (_, NullT) | ObjProtoT _ | FunProtoT _),
            LookupT
              {
                lookup_kind = NonstrictReturning (t_opt, test_opt);
                try_ts_on_failure = [];
                propref;
                lookup_action = action;
                ids;
                _;
              }
          ) ->
          (* don't fire

             ...unless a default return value is given. Two examples:

             1. A failure could arise when an unchecked module was looked up and
             not found declared, in which case we consider that module's exports to
             be `any`.

             2. A failure could arise also when an object property is looked up in
             a condition, in which case we consider the object's property to be
             `mixed`.
          *)
          let use_op =
            Base.Option.value ~default:unknown_use (Some (use_op_of_lookup_action action))
          in
          Base.Option.iter test_opt ~f:(fun (id, reasons) ->
              let suggestion =
                match propref with
                | Named { name = OrdinaryName name; _ } ->
                  Base.Option.bind ids ~f:(fun ids ->
                      prop_typo_suggestion cx (Properties.Set.elements ids) name
                  )
                | _ -> None
              in
              if Context.typing_mode cx <> Context.HintEvaluationMode then
                Context.test_prop_miss cx id (name_of_propref propref) reasons use_op suggestion
          );

          begin
            match t_opt with
            | Some (not_found, t) -> rec_unify cx trace ~use_op ~unify_any:true t not_found
            | None -> ()
          end
        (* SuperT only involves non-strict lookups *)
        | (DefT (_, NullT), SuperT _)
        | (ObjProtoT _, SuperT _)
        | (FunProtoT _, SuperT _) ->
          ()
        (* ExtendsUseT searches for a nominal superclass. The search terminates with
           either failure at the root or a structural subtype check. **)
        | (AnyT (_, src), ExtendsUseT (use_op, reason_op, ts, t1, t2)) ->
          Base.List.iter ts ~f:(fun t -> rec_flow_t cx trace ~use_op (AnyT.why src reason_op, t));
          rec_flow_t cx trace ~use_op (AnyT.why src reason_op, t1);
          rec_flow_t cx trace ~use_op (AnyT.why src reason_op, t2)
        | (DefT (lreason, ObjT { proto_t; _ }), ExtendsUseT _) ->
          let l = reposition cx ~trace (loc_of_reason lreason) proto_t in
          rec_flow cx trace (l, u)
        | (DefT (reason, ClassT instance), ExtendsUseT _) ->
          let statics = (reason, Tvar.mk_no_wrap cx reason) in
          rec_flow cx trace (instance, GetStaticsT statics);
          rec_flow cx trace (OpenT statics, u)
        | (DefT (_, NullT), ExtendsUseT (use_op, reason, next :: try_ts_on_failure, l, u)) ->
          (* When seaching for a nominal superclass fails, we always try to look it
             up in the next element in the list try_ts_on_failure. *)
          rec_flow cx trace (next, ExtendsUseT (use_op, reason, try_ts_on_failure, l, u))
        | ( DefT (_, NullT),
            ExtendsUseT
              ( use_op,
                _,
                [],
                l,
                DefT
                  ( reason_inst,
                    InstanceT
                      {
                        super;
                        inst =
                          {
                            own_props;
                            proto_props;
                            inst_call_t;
                            inst_kind = InterfaceKind _;
                            inst_dict;
                            _;
                          };
                        _;
                      }
                  )
              )
          ) ->
          structural_subtype
            cx
            trace
            ~use_op
            l
            reason_inst
            (own_props, proto_props, inst_call_t, inst_dict);
          rec_flow cx trace (l, UseT (use_op, super))
        (* Unwrap deep readonly *)
        | (_, (DeepReadOnlyT (tout, _) | HooklikeT tout)) ->
          rec_flow_t ~use_op:unknown_use cx trace (l, OpenT tout)
        (* Render Type Misc Uses *)
        | ( DefT (_, RendersT (InstrinsicRenders _ | NominalRenders _)),
            ExitRendersT { renders_reason; u }
          )
        | (DefT (renders_reason, RendersT (InstrinsicRenders _ | NominalRenders _)), u) ->
          let mixed_element =
            get_builtin_react_type
              cx
              ~trace
              renders_reason
              Flow_intermediate_error_types.ReactModuleForReactMixedElementType
          in
          rec_flow cx trace (mixed_element, u)
        | ( DefT
              ( r,
                RendersT
                  (StructuralRenders
                    { renders_variant = RendersNormal; renders_structural_type = t }
                    )
              ),
            u
          ) ->
          let u' = ExitRendersT { renders_reason = r; u } in
          rec_flow cx trace (t, u')
        | (_, ExitRendersT { renders_reason; u }) ->
          let node =
            get_builtin_react_type
              cx
              ~trace
              renders_reason
              Flow_intermediate_error_types.ReactModuleForReactNodeType
          in
          rec_flow cx trace (node, u)
        (***********************)
        (* Object library call *)
        (***********************)
        | ((ObjProtoT _ | FunProtoT _), CheckReactImmutableT _) -> ()
        | (ObjProtoT reason, _) ->
          let use_desc = true in
          let obj_proto = get_builtin_type cx ~trace reason ~use_desc "Object" in
          rec_flow cx trace (obj_proto, u)
        (*************************)
        (* Function library call *)
        (*************************)
        | (FunProtoT reason, _) ->
          let use_desc = true in
          let fun_proto = get_builtin_type cx ~trace reason ~use_desc "Function" in
          rec_flow cx trace (fun_proto, u)
        | (_, ExtendsUseT (use_op, _, [], t, tc)) ->
          let (reason_l, reason_u) = FlowError.ordered_reasons (reason_of_t t, reason_of_t tc) in
          add_output
            cx
            (Error_message.EIncompatibleWithUseOp
               { reason_lower = reason_l; reason_upper = reason_u; use_op; explanation = None }
            )
        (*********)
        (* Match *)
        (*********)
        | (t, ConcretizeT { reason = _; kind = ConcretizeForMatchArg _; seen = _; collector }) ->
          TypeCollector.add collector t
        (******************************)
        (* String utils (e.g. prefix) *)
        (******************************)
        (* StrUtilT just becomes a StrT so we can access properties and methods. *)
        | (StrUtilT { reason; op = StrPrefix arg | StrSuffix arg; remainder = _ }, _) ->
          let reason = replace_desc_reason RString reason in
          let literal_kind =
            if arg = "" then
              AnyLiteral
            else
              Truthy
          in
          rec_flow cx trace (DefT (reason, StrGeneralT literal_kind), u)
        (*******************************)
        (* ToString abstract operation *)
        (*******************************)

        (* ToStringT passes through strings unchanged, and flows a generic StrT otherwise *)
        | (DefT (_, (StrGeneralT _ | SingletonStrT _)), ToStringT { orig_t = None; t_out; _ }) ->
          rec_flow cx trace (l, t_out)
        | (DefT (_, (StrGeneralT _ | SingletonStrT _)), ToStringT { orig_t = Some t; t_out; _ }) ->
          rec_flow cx trace (t, t_out)
        | (_, ToStringT { reason; t_out; _ }) -> rec_flow cx trace (StrModuleT.why reason, t_out)
        (**********************)
        (* Array library call *)
        (**********************)
        | ( DefT
              (reason, ArrT (ArrayAT { elem_t; react_dro = Some (dro_loc, dro_type); tuple_view })),
            (GetPropT _ | SetPropT _ | MethodT _ | LookupT _)
          ) -> begin
          match u with
          | MethodT (use_op, _, reason, Named { name = OrdinaryName name; _ }, _)
          | GetPropT { propref = Named { name = OrdinaryName name; _ }; use_op; reason; _ }
            when match name with
                 | "fill"
                 | "pop"
                 | "push"
                 | "reverse"
                 | "shift"
                 | "sort"
                 | "splice"
                 | "unshift" ->
                   true
                 | _ -> false ->
            add_output
              cx
              (Error_message.EPropNotReadable
                 {
                   reason_prop = reason;
                   prop_name = Some (OrdinaryName name);
                   use_op = Frame (ReactDeepReadOnly (dro_loc, dro_type), use_op);
                 }
              );
            rec_flow
              cx
              trace
              (DefT (reason, ArrT (ArrayAT { elem_t; react_dro = None; tuple_view })), u)
          | _ ->
            let l =
              get_builtin_typeapp
                ~use_desc:true
                cx
                reason
                "$ReadOnlyArray"
                [mk_react_dro cx unknown_use (dro_loc, dro_type) elem_t]
            in
            let u =
              TypeUtil.mod_use_op_of_use_t
                (fun use_op -> Frame (ReactDeepReadOnly (dro_loc, dro_type), use_op))
                u
            in
            rec_flow cx trace (l, u)
        end
        | ( DefT (reason, ArrT (ArrayAT { elem_t; _ })),
            (GetPropT _ | SetPropT _ | MethodT _ | LookupT _)
          ) ->
          rec_flow cx trace (get_builtin_typeapp cx reason "Array" [elem_t], u)
        (*************************)
        (* Tuple "length" access *)
        (*************************)
        | ( DefT (reason, ArrT (TupleAT { elem_t = _; elements = _; arity; inexact; react_dro = _ })),
            GetPropT
              {
                use_op = _;
                reason = _;
                id = _;
                from_annot = _;
                skip_optional = _;
                propref = Named { name = OrdinaryName "length"; _ };
                tout;
                hint = _;
              }
          ) ->
          GetPropTKit.on_array_length cx trace reason ~inexact arity (reason_of_use_t u) tout
        | ( DefT
              ( reason,
                ArrT (TupleAT { elem_t; react_dro = Some dro; _ } | ROArrayAT (elem_t, Some dro))
              ),
            (GetPropT _ | SetPropT _ | MethodT _ | LookupT _)
          ) ->
          let u =
            let (dro_loc, dro_type) = dro in
            TypeUtil.mod_use_op_of_use_t
              (fun use_op -> Frame (ReactDeepReadOnly (dro_loc, dro_type), use_op))
              u
          in
          rec_flow
            cx
            trace
            ( get_builtin_typeapp
                ~use_desc:true
                cx
                reason
                "$ReadOnlyArray"
                [mk_react_dro cx unknown_use dro elem_t],
              u
            )
        | ( DefT (reason, ArrT ((TupleAT _ | ROArrayAT _) as arrtype)),
            (GetPropT _ | SetPropT _ | MethodT _ | LookupT _)
          ) ->
          let t = elemt_of_arrtype arrtype in
          rec_flow cx trace (get_builtin_typeapp cx reason "$ReadOnlyArray" [t], u)
        (***********************)
        (* String library call *)
        (***********************)
        | (DefT (reason, (StrGeneralT _ | SingletonStrT _)), u) when primitive_promoting_use_t u ->
          rec_flow cx trace (get_builtin_type cx ~trace reason "String", u)
        (***********************)
        (* Number library call *)
        (***********************)
        | (DefT (reason, (NumGeneralT _ | SingletonNumT _)), u) when primitive_promoting_use_t u ->
          rec_flow cx trace (get_builtin_type cx ~trace reason "Number", u)
        (***********************)
        (* Boolean library call *)
        (***********************)
        | (DefT (reason, (BoolGeneralT | SingletonBoolT _)), u) when primitive_promoting_use_t u ->
          rec_flow cx trace (get_builtin_type cx ~trace reason "Boolean", u)
        (***********************)
        (* BigInt library call *)
        (***********************)
        | (DefT (reason, (BigIntGeneralT _ | SingletonBigIntT _)), u)
          when primitive_promoting_use_t u ->
          rec_flow cx trace (get_builtin_type cx ~trace reason "BigInt", u)
        (***********************)
        (* Symbol library call *)
        (***********************)
        | (DefT (reason, SymbolT), u) when primitive_promoting_use_t u ->
          rec_flow cx trace (get_builtin_type cx ~trace reason "Symbol", u)
        (*****************************************************)
        (* Nice error messages for mixed function refinement *)
        (*****************************************************)
        | (DefT (lreason, MixedT Mixed_function), (MethodT _ | SetPropT _ | GetPropT _ | LookupT _))
          ->
          rec_flow cx trace (FunProtoT lreason, u)
        | (DefT (_, MixedT Mixed_function), CallT { call_action = ConcretizeCallee tout; _ }) ->
          rec_flow_t cx trace ~use_op:unknown_use (l, OpenT tout)
        | ( DefT (lreason, MixedT Mixed_function),
            CallT { use_op; reason = ureason; call_action = _; return_hint = _ }
          ) ->
          add_output
            cx
            (Error_message.EIncompatible
               {
                 lower = (lreason, None);
                 upper = (ureason, Error_message.IncompatibleMixedCallT);
                 use_op = Some use_op;
               }
            );
          rec_flow cx trace (AnyT.make (AnyError None) lreason, u)
        (* Special cases of FunT *)
        | (FunProtoBindT reason, MethodT (use_op, call_r, lookup_r, propref, action)) ->
          let method_type =
            Tvar.mk_no_wrap_where cx lookup_r (fun tout ->
                let u =
                  GetPropT
                    {
                      use_op;
                      reason = lookup_r;
                      id = None;
                      from_annot = false;
                      skip_optional = false;
                      propref;
                      tout;
                      hint = hint_unavailable;
                    }
                in
                rec_flow cx trace (FunProtoT reason, u)
            )
          in
          apply_method_action cx trace method_type use_op call_r l action
        | (FunProtoBindT reason, _) -> rec_flow cx trace (FunProtoT reason, u)
        | (_, LookupT { propref; lookup_action; _ }) ->
          Default_resolve.default_resolve_touts
            ~flow:(rec_flow_t cx trace ~use_op:unknown_use)
            cx
            (reason_of_t l |> loc_of_reason)
            u;
          let use_op = Some (use_op_of_lookup_action lookup_action) in
          add_output
            cx
            (Error_message.EIncompatibleProp
               {
                 prop = name_of_propref propref;
                 reason_prop = reason_of_propref propref;
                 reason_obj = reason_of_t l;
                 special = error_message_kind_of_lower l;
                 use_op;
               }
            )
        | ( DefT (_, InstanceT { super; inst = { class_id; _ }; _ }),
            CheckUnusedPromiseT { reason; async }
          ) ->
          (match Flow_js_utils.builtin_promise_class_id cx with
          | None -> () (* Promise has some unexpected type *)
          | Some promise_class_id ->
            if ALoc.equal_id promise_class_id class_id then
              add_output cx (Error_message.EUnusedPromise { loc = loc_of_reason reason; async })
            else
              rec_flow cx trace (super, CheckUnusedPromiseT { reason; async }))
        | (_, CheckUnusedPromiseT _) -> ()
        (* computed properties *)
        | (t, ConcretizeT { reason = _; kind = ConcretizeAll; seen = _; collector }) ->
          TypeCollector.add collector t
        | (DefT (lreason, SingletonStrT _), WriteComputedObjPropCheckT _) ->
          let loc = loc_of_reason lreason in
          add_output cx Error_message.(EInternal (loc, PropRefComputedLiteral))
        | (AnyT (_, src), WriteComputedObjPropCheckT { reason; value_t; _ }) ->
          let src = any_mod_src_keep_placeholder Untyped src in
          rec_flow_t cx trace ~use_op:unknown_use (value_t, AnyT.why src reason)
        | ( DefT (_, StrGeneralT _),
            WriteComputedObjPropCheckT { err_on_str_key = (use_op, reason_obj); _ }
          ) ->
          add_output
            cx
            (Error_message.EPropNotFound
               {
                 prop_name = None;
                 reason_prop = TypeUtil.reason_of_t l;
                 reason_obj;
                 use_op;
                 suggestion = None;
               }
            )
        | ( DefT (reason, SingletonNumT { value = (value, _); _ }),
            WriteComputedObjPropCheckT { reason_key; _ }
          ) ->
          let kind = Flow_intermediate_error_types.InvalidObjKey.kind_of_num_value value in
          add_output cx (Error_message.EObjectComputedPropertyAssign (reason, reason_key, kind))
        | (_, WriteComputedObjPropCheckT { reason = _; reason_key; _ }) ->
          let reason = reason_of_t l in
          add_output
            cx
            (Error_message.EObjectComputedPropertyAssign
               (reason, reason_key, Flow_intermediate_error_types.InvalidObjKey.Other)
            )
        | ( DefT (_, ObjT { flags = { obj_kind; _ }; props_tmap; proto_t; call_t; _ }),
            CheckReactImmutableT { use_op; lower_reason; upper_reason; dro_loc }
          ) ->
          let props_safe =
            Context.fold_real_props
              cx
              props_tmap
              (fun _ prop acc ->
                match prop with
                | Field { type_; polarity = Polarity.Positive; _ } ->
                  rec_flow cx trace (type_, u);
                  acc
                | _ -> false)
              true
          in
          let dict_safe =
            match Obj_type.get_dict_opt obj_kind with
            | Some { dict_polarity = Polarity.Positive; value; _ } ->
              rec_flow cx trace (value, u);
              true
            | None -> true
            | _ -> false
          in
          let locally_safe = Base.Option.is_none call_t && props_safe && dict_safe in
          if locally_safe then
            rec_flow cx trace (proto_t, u)
          else
            add_output
              cx
              (Error_message.EIncompatibleReactDeepReadOnly
                 { lower = lower_reason; upper = upper_reason; dro_loc; use_op }
              )
        | ( DefT (_, InstanceT { inst = { class_id; type_args; _ }; _ }),
            CheckReactImmutableT { use_op; lower_reason; upper_reason; dro_loc }
          ) -> begin
          match type_args with
          | [(_, _, elem_t, _)] when is_builtin_class_id "$ReadOnlySet" class_id cx ->
            rec_flow cx trace (elem_t, u)
          | [(_, _, key_t, _); (_, _, val_t, _)] when is_builtin_class_id "$ReadOnlyMap" class_id cx
            ->
            rec_flow cx trace (key_t, u);
            rec_flow cx trace (val_t, u)
          | _ ->
            add_output
              cx
              (Error_message.EIncompatibleReactDeepReadOnly
                 { lower = lower_reason; upper = upper_reason; dro_loc; use_op }
              )
        end
        | ( DefT (_, ArrT (ArrayAT _)),
            CheckReactImmutableT { use_op; lower_reason; upper_reason; dro_loc }
          ) ->
          add_output
            cx
            (Error_message.EIncompatibleReactDeepReadOnly
               { lower = lower_reason; upper = upper_reason; dro_loc; use_op }
            )
        | (DefT (_, ArrT arr), CheckReactImmutableT _) -> rec_flow cx trace (elemt_of_arrtype arr, u)
        | (_, CheckReactImmutableT _) -> ()
        | _ ->
          add_output
            cx
            (Error_message.EIncompatible
               {
                 lower = (reason_of_t l, error_message_kind_of_lower l);
                 upper = (reason_of_use_t u, error_message_kind_of_upper u);
                 use_op = use_op_of_use_t u;
               }
            );
          let resolve_callee =
            match u with
            | CallT _ -> Some (reason_of_t l, [l])
            | _ -> None
          in
          Default_resolve.default_resolve_touts
            ~flow:(rec_flow_t cx trace ~use_op:unknown_use)
            ?resolve_callee
            cx
            (reason_of_t l |> loc_of_reason)
            u
      (* END OF PATTERN MATCH *)
    )

  (* Returns true when __flow should succeed immediately if EmptyT flows into u. *)
  and empty_success u =
    match u with
    (* Work has to happen when Empty flows to these types *)
    | UseT (_, OpenT _)
    | EvalTypeDestructorT _
    | UseT (_, DefT (_, TypeT _))
    | CondT _
    | ConditionalT _
    | DestructuringT _
    | EnumExhaustiveCheckT _
    | FilterMaybeT _
    | ObjKitT _
    | OptionalIndexedAccessT _
    | ReposLowerT _
    | ReposUseT _
    | SealGenericT _
    | ResolveUnionT _
    | EnumCastT _
    | ConvertEmptyPropsToMixedT _
    | HooklikeT _
    | SpecializeT _
    | ValueToTypeReferenceT _ ->
      false
    | _ -> true

  and handle_generic cx trace ~no_infer bound reason id name u =
    let make_generic t = GenericT { reason; id; name; bound = t; no_infer } in
    let narrow_generic_with_continuation mk_use_t cont =
      let t_out' = (reason, Tvar.mk_no_wrap cx reason) in
      let use_t = mk_use_t t_out' in
      rec_flow cx trace (reposition_reason cx reason bound, use_t);
      rec_flow cx trace (OpenT t_out', SealGenericT { reason; id; name; cont; no_infer })
    in
    let narrow_generic_use mk_use_t use_t_out =
      narrow_generic_with_continuation mk_use_t (Upper use_t_out)
    in
    let narrow_generic ?(use_op = unknown_use) mk_use_t t_out =
      narrow_generic_use (fun v -> mk_use_t (OpenT v)) (UseT (use_op, t_out))
    in
    let narrow_generic_tvar ?(use_op = unknown_use) mk_use_t t_out =
      narrow_generic_use mk_use_t (UseT (use_op, OpenT t_out))
    in
    let wait_for_concrete_bound ?(upper = u) () =
      rec_flow
        cx
        trace
        ( reposition_reason cx reason bound,
          SealGenericT { reason; id; name; cont = Upper upper; no_infer }
        );
      true
    in
    let distribute_union_intersection ?(upper = u) () =
      match bound with
      | UnionT (_, rep) ->
        let (t1, (t2, ts)) = UnionRep.members_nel rep in
        let union_of_generics =
          UnionRep.make (make_generic t1) (make_generic t2) (Base.List.map ~f:make_generic ts)
        in
        rec_flow cx trace (UnionT (reason, union_of_generics), upper);
        true
      | IntersectionT (_, rep) ->
        let (t1, (t2, ts)) = InterRep.members_nel rep in
        let inter_of_generics =
          InterRep.make (make_generic t1) (make_generic t2) (Base.List.map ~f:make_generic ts)
        in
        rec_flow cx trace (IntersectionT (reason, inter_of_generics), upper);
        true
      | _ -> false
    in
    let update_action_meth_generic_this l = function
      | CallM { methodcalltype = mct; return_hint; specialized_callee } ->
        CallM
          {
            methodcalltype = { mct with meth_generic_this = Some l };
            return_hint;
            specialized_callee;
          }
      | ChainM
          {
            exp_reason;
            lhs_reason;
            methodcalltype = mct;
            voided_out;
            return_hint;
            specialized_callee;
          } ->
        ChainM
          {
            exp_reason;
            lhs_reason;
            methodcalltype = { mct with meth_generic_this = Some l };
            voided_out;
            return_hint;
            specialized_callee;
          }
      | NoMethodAction t -> NoMethodAction t
    in
    if
      match bound with
      | GenericT { bound; id = id'; no_infer; _ } ->
        Generic.collapse id id'
        |> Base.Option.value_map ~default:false ~f:(fun id ->
               rec_flow cx trace (GenericT { reason; name; bound; id; no_infer }, u);
               true
           )
      (* The ClassT operation should commute with GenericT; that is, GenericT(ClassT(x)) = ClassT(GenericT(x)) *)
      | DefT (r, ClassT bound) ->
        rec_flow
          cx
          trace
          (DefT (r, ClassT (GenericT { reason = reason_of_t bound; name; bound; id; no_infer })), u);
        true
      | KeysT _ ->
        rec_flow
          cx
          trace
          ( reposition_reason cx reason bound,
            SealGenericT { reason; id; name; no_infer; cont = Upper u }
          );
        true
      | DefT (_, EmptyT) -> empty_success u
      | _ -> false
    then
      true
    else
      match u with
      (* In this set of cases, we flow the generic's upper bound to u. This is what we normally would do
         in the catch-all generic case anyways, but these rules are to avoid wildcards elsewhere in __flow. *)
      | ConcretizeT { reason = _; kind = ConcretizeForOperatorsChecking; seen = _; collector = _ }
      | TestPropT _
      | OptionalChainT _
      | OptionalIndexedAccessT _
      | UseT (Op (Coercion _), DefT (_, (StrGeneralT _ | SingletonStrT _))) ->
        rec_flow cx trace (reposition_reason cx reason bound, u);
        true
      | ReactKitT _ ->
        if is_concrete bound then
          distribute_union_intersection ()
        else
          wait_for_concrete_bound ()
      | ToStringT { orig_t; reason; t_out } ->
        narrow_generic_use
          (fun t_out' -> ToStringT { orig_t; reason; t_out = UseT (unknown_use, OpenT t_out') })
          t_out;
        true
      | UseT (use_op, MaybeT (r, t_out)) ->
        narrow_generic ~use_op (fun t_out' -> UseT (use_op, MaybeT (r, t_out'))) t_out;
        true
      | UseT (use_op, OptionalT ({ type_ = t_out; _ } as opt)) ->
        narrow_generic
          ~use_op
          (fun t_out' -> UseT (use_op, OptionalT { opt with type_ = t_out' }))
          t_out;
        true
      | DeepReadOnlyT (t_out, (dro_loc, dro_type)) ->
        narrow_generic_tvar (fun t_out' -> DeepReadOnlyT (t_out', (dro_loc, dro_type))) t_out;
        true
      | HooklikeT t_out ->
        narrow_generic_tvar (fun t_out' -> HooklikeT t_out') t_out;
        true
      | FilterMaybeT (use_op, t_out) ->
        narrow_generic (fun t_out' -> FilterMaybeT (use_op, t_out')) t_out;
        true
      | FilterOptionalT (use_op, t_out) ->
        narrow_generic (fun t_out' -> FilterOptionalT (use_op, t_out')) t_out;
        true
      | ObjRestT (r, xs, t_out, id) ->
        narrow_generic (fun t_out' -> ObjRestT (r, xs, t_out', id)) t_out;
        true
      (* Support "new this.constructor ()" *)
      | GetPropT
          {
            use_op;
            reason = reason_op;
            id;
            from_annot;
            skip_optional;
            propref = Named { reason; name = OrdinaryName "constructor" as name; _ };
            tout;
            hint;
          } ->
        if is_concrete bound then
          match bound with
          | DefT (_, InstanceT _) ->
            narrow_generic_tvar
              (fun tout' ->
                GetPropT
                  {
                    use_op;
                    reason = reason_op;
                    id;
                    from_annot;
                    skip_optional;
                    propref = mk_named_prop ~reason name;
                    tout = tout';
                    hint;
                  })
              tout;
            true
          | _ -> false
        else
          wait_for_concrete_bound ()
      | ConstructorT
          { use_op; reason = reason_op; targs; args; tout; return_hint; specialized_ctor } ->
        if is_concrete bound then
          match bound with
          | DefT (_, ClassT _) ->
            narrow_generic
              (fun tout' ->
                ConstructorT
                  {
                    use_op;
                    reason = reason_op;
                    targs;
                    args;
                    tout = tout';
                    return_hint;
                    specialized_ctor;
                  })
              tout;
            true
          | _ -> false
        else
          wait_for_concrete_bound ()
      | ElemT _ ->
        if is_concrete bound then
          distribute_union_intersection ()
        else
          wait_for_concrete_bound ()
      | MethodT (op, r1, r2, prop, action) ->
        let l = make_generic bound in
        let action' = update_action_meth_generic_this l action in
        let u' = MethodT (op, r1, r2, prop, action') in
        let consumed =
          if is_concrete bound then
            distribute_union_intersection ~upper:u' ()
          else
            wait_for_concrete_bound ~upper:u' ()
        in
        if not consumed then rec_flow cx trace (reposition_reason cx reason bound, u');
        true
      | PrivateMethodT (op, r1, r2, prop, scopes, static, action) ->
        let l = make_generic bound in
        let action' = update_action_meth_generic_this l action in
        let u' = PrivateMethodT (op, r1, r2, prop, scopes, static, action') in
        let consumed =
          if is_concrete bound then
            distribute_union_intersection ~upper:u' ()
          else
            wait_for_concrete_bound ~upper:u' ()
        in
        if not consumed then rec_flow cx trace (reposition_reason cx reason bound, u');
        true
      | ObjKitT _
      | UseT (_, IntersectionT _) ->
        if is_concrete bound then
          distribute_union_intersection ()
        else
          wait_for_concrete_bound ()
      | UseT (_, (UnionT _ as u)) ->
        if
          union_optimization_guard cx TypeUtil.quick_subtype bound u
          = UnionOptimizationGuardResult.True
        then begin
          if Context.is_verbose cx then prerr_endline "UnionT ~> UnionT fast path (via a generic)";
          true
        end else if is_concrete bound then
          distribute_union_intersection ()
        else
          wait_for_concrete_bound ()
      | UseT (_, KeysT _)
      | EvalTypeDestructorT _ ->
        if is_concrete bound then
          false
        else
          wait_for_concrete_bound ()
      | ResolveSpreadT _ when not (is_concrete bound) -> wait_for_concrete_bound ()
      | _ -> false

  (* "Expands" any to match the form of a type. Allows us to reuse our propagation rules for any
     cases. Note that it is not always safe to do this (ie in the case of unions).
     Note: we can get away with a shallow (i.e. non-recursive) expansion here because the flow between
     the any-expanded type and the original will handle the any-propagation to any relevant positions,
     some of which may invoke this function when they hit the any propagation functions in the
     recusive call to __flow. *)
  and expand_any _cx any t =
    let only_any _ = any in
    match t with
    | DefT (r, ArrT (ArrayAT _)) ->
      DefT (r, ArrT (ArrayAT { elem_t = any; tuple_view = None; react_dro = None }))
    | DefT (r, ArrT (TupleAT { elements; arity; inexact; react_dro; _ })) ->
      DefT
        ( r,
          ArrT
            (TupleAT
               {
                 react_dro;
                 elem_t = any;
                 elements =
                   Base.List.map
                     ~f:(fun (TupleElement { name; t; polarity; optional; reason }) ->
                       TupleElement { name; t = only_any t; polarity; optional; reason })
                     elements;
                 arity;
                 inexact;
               }
            )
        )
    | OpaqueT (r, ({ underlying_t; lower_t; upper_t; opaque_type_args; _ } as opaquetype)) ->
      let opaquetype =
        {
          opaquetype with
          underlying_t = Base.Option.(underlying_t >>| only_any);
          lower_t = Base.Option.(lower_t >>| only_any);
          upper_t = Base.Option.(upper_t >>| only_any);
          opaque_type_args =
            Base.List.(opaque_type_args >>| fun (str, r', _, polarity) -> (str, r', any, polarity));
        }
      in
      OpaqueT (r, opaquetype)
    | _ ->
      (* Just returning any would result in infinite recursion in most cases *)
      failwith "no any expansion defined for this case"

  and any_prop_to_function
      use_op
      { this_t = (this, _); params; rest_param; return_t; type_guard; def_reason = _; effect_ = _ }
      covariant
      contravariant =
    List.iter (snd %> contravariant ~use_op) params;
    Base.Option.iter ~f:(fun (_, _, t) -> contravariant ~use_op t) rest_param;
    contravariant ~use_op this;
    let () =
      match type_guard with
      | Some (TypeGuard { type_guard = t; _ }) -> covariant ~use_op t
      | _ -> ()
    in
    covariant ~use_op return_t

  and invariant_any_propagation_flow cx trace ~use_op any t = rec_unify cx trace ~use_op any t

  and any_prop_call_prop cx ~use_op ~covariant_flow = function
    | None -> ()
    | Some id -> covariant_flow ~use_op (Context.find_call cx id)

  and any_prop_properties cx trace ~use_op ~covariant_flow ~contravariant_flow any properties =
    properties
    |> NameUtils.Map.iter (fun _ property ->
           let polarity = Property.polarity property in
           property
           |> Property.iter_t (fun t ->
                  match polarity with
                  | Polarity.Positive -> covariant_flow ~use_op t
                  | Polarity.Negative -> contravariant_flow ~use_op t
                  | Polarity.Neutral -> invariant_any_propagation_flow cx trace ~use_op any t
              )
       )

  and any_prop_obj
      cx
      trace
      ~use_op
      ~covariant_flow
      ~contravariant_flow
      any
      { flags = _; props_tmap = _; proto_t = _; call_t = _; reachable_targs } =
    (* NOTE: Doing this always would be correct and desirable, but the
     * performance of doing this always is just not good enough. Instead,
     * we do it only in implicit instantiation to ensure that we do not get
     * spurious underconstrained errors when objects contain type arguments
     * that get any as a lower bound *)
    if Context.in_implicit_instantiation cx then
      reachable_targs
      |> List.iter (fun (t, p) ->
             match p with
             | Polarity.Positive -> covariant_flow ~use_op t
             | Polarity.Negative -> contravariant_flow ~use_op t
             | Polarity.Neutral -> invariant_any_propagation_flow cx trace ~use_op any t
         )

  (* FullyResolved tvars cannot contain non-FullyResolved parts, so there's no need to
   * deeply traverse them! *)
  and any_prop_tvar cx tvar =
    match Context.find_constraints cx tvar with
    | (_, FullyResolved _) -> true
    | _ -> false

  and any_prop_to_type_args cx trace ~use_op any ~covariant_flow ~contravariant_flow targs =
    List.iter
      (fun (_, _, t, polarity) ->
        match polarity with
        | Polarity.Positive -> covariant_flow ~use_op t
        | Polarity.Negative -> contravariant_flow ~use_op t
        | Polarity.Neutral -> invariant_any_propagation_flow cx trace ~use_op any t)
      targs

  (* TODO: Proper InstanceT propagation has non-termation issues that requires some
   * deep investigation. Punting on it for now. Note that using the type_args polarity
   * will likely be stricter than necessary. In practice, most type params do not
   * have variance sigils even if they are only used co/contravariantly.
   * Inline interfaces are an exception to this rule. The type_args there can be
   * empty even if the interface contains type arguments because they would only
   * appear in type_args if they are bound at the interface itself. We handle those
   * in the more general way, since they are used so rarely that non-termination is not
   * an issue (for now!) *)
  and any_prop_inst
      cx
      trace
      ~use_op
      any
      ~covariant_flow
      ~contravariant_flow
      static
      super
      implements
      {
        inst_react_dro = _;
        class_id = _;
        class_name = _;
        type_args;
        own_props;
        proto_props;
        inst_call_t;
        initialized_fields = _;
        initialized_static_fields = _;
        inst_kind;
        inst_dict = _;
        class_private_fields = _;
        class_private_methods = _;
        class_private_static_fields = _;
        class_private_static_methods = _;
      } =
    any_prop_to_type_args cx trace ~use_op any ~covariant_flow ~contravariant_flow type_args;
    match inst_kind with
    | InterfaceKind { inline = true } ->
      covariant_flow ~use_op static;
      covariant_flow ~use_op super;
      List.iter (covariant_flow ~use_op) implements;
      let property_prop =
        any_prop_properties cx trace ~use_op ~covariant_flow ~contravariant_flow any
      in
      property_prop (Context.find_props cx own_props);
      property_prop (Context.find_props cx proto_props);
      any_prop_call_prop cx ~use_op ~covariant_flow inst_call_t
    | _ -> ()

  (* types trapped for any propagation. Returns true if this function handles the any case, either
     by propagating or by doing the trivial case. False if the usetype needs to be handled
     separately. *)
  and any_propagated cx trace any u =
    let covariant_flow ~use_op t = rec_flow_t cx trace ~use_op (any, t) in
    let contravariant_flow ~use_op t = rec_flow_t cx trace ~use_op (t, any) in
    match u with
    | ExitRendersT { renders_reason = _; u } -> any_propagated cx trace any u
    | UseT (use_op, DefT (_, ArrT (ROArrayAT (t, _)))) (* read-only arrays are covariant *)
    | UseT (use_op, DefT (_, ClassT t)) (* mk_instance ~for_type:false *) ->
      covariant_flow ~use_op t;
      true
    | UseT
        (use_op, DefT (_, ReactAbstractComponentT { config; instance; renders; component_kind = _ }))
      ->
      contravariant_flow ~use_op config;
      let () =
        match instance with
        | ComponentInstanceOmitted (_ : reason) -> ()
        | ComponentInstanceAvailableAsRefSetterProp t -> contravariant_flow ~use_op t
      in
      covariant_flow ~use_op renders;
      true
    | UseT
        ( use_op,
          DefT (_, RendersT (StructuralRenders { renders_structural_type; renders_variant = _ }))
        ) ->
      covariant_flow ~use_op renders_structural_type;
      true
    | UseT
        ( _,
          DefT
            ( _,
              RendersT
                ( InstrinsicRenders _
                | NominalRenders { renders_id = _; renders_name = _; renders_super = _ }
                | DefaultRenders )
            )
        ) ->
      false
    (* Some types just need to be expanded and filled with any types *)
    | UseT (use_op, (DefT (_, ArrT (ArrayAT _)) as t))
    | UseT (use_op, (DefT (_, ArrT (TupleAT _)) as t))
    | UseT (use_op, (OpaqueT _ as t)) ->
      rec_flow_t cx trace ~use_op (expand_any cx any t, t);
      true
    | UseT (use_op, DefT (_, FunT (_, funtype))) ->
      any_prop_to_function use_op funtype covariant_flow contravariant_flow;
      true
    | UseT (_, OpenT (_, id)) -> any_prop_tvar cx id
    (* AnnotTs are 0->1, so there's no need to propagate any inside them *)
    | UseT (_, AnnotT _) -> true
    | ArrRestT _
    | BindT _
    | CallT _
    | CallElemT _
    | CondT _
    | ConstructorT _
    | DestructuringT _
    | ElemT _
    | EnumExhaustiveCheckT _
    | ExtendsUseT _
    | ConditionalT _
    | GetElemT _
    | GetEnumT _
    | GetKeysT _
    | GetPrivatePropT _
    | GetPropT _
    | GetTypeFromNamespaceT _
    | GetProtoT _
    | GetStaticsT _
    | GetValuesT _
    | GetDictValuesT _
    | FilterOptionalT _
    | FilterMaybeT _
    | DeepReadOnlyT _
    | HooklikeT _
    | ConcretizeT _
    | ResolveUnionT _
    | LookupT _
    | MapTypeT _
    | MethodT _
    | MixinT _
    | ObjKitT _
    | ObjRestT _
    | ObjTestProtoT _
    | ObjTestT _
    | OptionalChainT _
    | OptionalIndexedAccessT _
    | PrivateMethodT _
    | ReactKitT _
    | ReposLowerT _
    | ReposUseT _
    | ResolveSpreadT _
    | SealGenericT _
    | SetElemT _
    | SetPropT _
    | SpecializeT _
    (* Should be impossible. We only generate these with OpenPredTs. *)
    | TestPropT _
    | ThisSpecializeT _
    | ToStringT _
    | UseT (_, MaybeT _) (* used to filter maybe *)
    | UseT (_, OptionalT _) (* used to filter optional *)
    (* Handled in __flow *)
    | UseT (_, ThisTypeAppT _)
    | UseT (_, TypeAppT _)
    | UseT (_, DefT (_, TypeT _))
    | ValueToTypeReferenceT _
    (* Ideally, any would pollute every member of the union. However, it should be safe to only
       taint the type in the branch that flow picks when generating constraints for this, so
       this can be handled by the pre-existing rules *)
    | UseT (_, UnionT _)
    | UseT (_, IntersectionT _) (* Already handled in the wildcard case in __flow *)
    | EvalTypeDestructorT _
    | ConvertEmptyPropsToMixedT _
    | CheckUnusedPromiseT _ ->
      false
    | UseT (use_op, DefT (_, ObjT obj)) ->
      any_prop_obj cx trace ~use_op ~covariant_flow ~contravariant_flow any obj;
      true
    | UseT (use_op, DefT (_, InstanceT { static; super; implements; inst })) ->
      any_prop_inst
        cx
        trace
        ~use_op
        any
        ~covariant_flow
        ~contravariant_flow
        static
        super
        implements
        inst;
      true
    (* These types have no t_out, so can't propagate anything. Thus we short-circuit by returning
       true *)
    | HasOwnPropT _
    | ExtractReactRefT _
    | ImplementsT _
    | SetPrivatePropT _
    | SetProtoT _
    | SuperT _
    | TypeCastT _
    | EnumCastT _
    | ConcretizeTypeAppsT _
    | UseT (_, KeysT _) (* Any won't interact with the type inside KeysT, so it can't be tainted *)
    | WriteComputedObjPropCheckT _
    | CheckReactImmutableT _ ->
      true
    (* TODO: Punt on these for now, but figure out whether these should fall through or not *)
    | UseT _ -> true

  (* Propagates any flows in case of contravariant/invariant subtypes: the any must pollute
     all types in contravariant positions when t <: any. *)
  and any_propagated_use cx trace use_op any l =
    let covariant_flow ~use_op t = rec_flow_t cx trace ~use_op (t, any) in
    let contravariant_flow ~use_op t = rec_flow_t cx trace ~use_op (any, t) in
    match l with
    | DefT (_, FunT (_, funtype)) ->
      (* function types are contravariant in the arguments *)
      any_prop_to_function use_op funtype covariant_flow contravariant_flow;
      true
    | OpaqueT (_, { opaque_id = Opaque.InternalEnforceUnionOptimized; _ }) -> false
    (* Some types just need to be expanded and filled with any types *)
    | (DefT (_, ArrT (ArrayAT _)) as t)
    | (DefT (_, ArrT (TupleAT _)) as t)
    | (OpaqueT _ as t) ->
      rec_flow_t cx trace ~use_op (t, expand_any cx any t);
      true
    | KeysT _ ->
      (* Keys cannot be tainted by any *)
      true
    | DefT (_, ClassT t)
    | DefT (_, ArrT (ROArrayAT (t, _))) ->
      covariant_flow ~use_op t;
      true
    | DefT (_, ReactAbstractComponentT { config; instance; renders; component_kind = _ }) ->
      contravariant_flow ~use_op config;
      let () =
        match instance with
        | ComponentInstanceOmitted (_ : reason) -> ()
        | ComponentInstanceAvailableAsRefSetterProp t -> contravariant_flow ~use_op t
      in
      covariant_flow ~use_op renders;
      true
    | GenericT { bound; _ } ->
      covariant_flow ~use_op bound;
      true
    | DefT (_, ObjT obj) ->
      any_prop_obj cx trace ~use_op ~covariant_flow ~contravariant_flow any obj;
      true
    | DefT (_, InstanceT { static; super; implements; inst }) ->
      any_prop_inst
        cx
        trace
        ~use_op
        any
        ~covariant_flow
        ~contravariant_flow
        static
        super
        implements
        inst;
      true
    (* These types have no negative positions in their lower bounds *)
    | FunProtoBindT _
    | FunProtoT _
    | ObjProtoT _
    | NullProtoT _ ->
      true
    (* AnnotTs are 0->1, so there's no need to propagate any inside them *)
    | AnnotT _ -> true
    | OpenT (_, id) -> any_prop_tvar cx id
    (* Handled already in __flow *)
    | ThisInstanceT _
    | EvalT _
    | OptionalT _
    | MaybeT _
    | DefT (_, PolyT _)
    | TypeAppT _
    | UnionT _
    | IntersectionT _
    | ThisTypeAppT _ ->
      false
    (* Should never occur as the lower bound of any *)
    | NamespaceT _ -> false
    | StrUtilT _
    | DefT _
    | AnyT _ ->
      true

  (*********************)
  (* inheritance utils *)
  (*********************)
  and flow_type_args cx trace ~use_op lreason ureason targs1 targs2 =
    List.iter2
      (fun (x, targ_reason, t1, polarity) (_, _, t2, _) ->
        let use_op =
          Frame
            ( TypeArgCompatibility
                { name = x; targ = targ_reason; lower = lreason; upper = ureason; polarity },
              use_op
            )
        in
        match polarity with
        | Polarity.Negative -> rec_flow cx trace (t2, UseT (use_op, t1))
        | Polarity.Positive -> rec_flow cx trace (t1, UseT (use_op, t2))
        | Polarity.Neutral -> rec_unify cx trace ~use_op t1 t2)
      targs1
      targs2

  and inst_type_to_obj_type cx reason_struct (own_props_id, proto_props_id, call_id, inst_dict) =
    let own_props = Context.find_props cx own_props_id in
    let proto_props = Context.find_props cx proto_props_id in
    let props_tmap = Properties.generate_id () in
    Context.add_property_map cx props_tmap (NameUtils.Map.union own_props proto_props);
    (* Interfaces with an indexer type are indexed, all others are inexact *)
    let obj_kind =
      match inst_dict with
      | Some d -> Indexed d
      | None -> Inexact
    in
    let o =
      {
        flags = { obj_kind; react_dro = None };
        props_tmap;
        (* Interfaces have no prototype *)
        proto_t = ObjProtoT reason_struct;
        call_t = call_id;
        reachable_targs = [];
      }
    in
    DefT (reason_struct, ObjT o)

  (* dispatch checks to verify that lower satisfies the structural
     requirements given in the tuple. *)
  (* TODO: own_props/proto_props is misleading, since they come from interfaces,
     which don't have an own/proto distinction. *)
  and structural_subtype
      cx trace ~use_op lower reason_struct (own_props_id, proto_props_id, call_id, inst_dict) =
    match lower with
    (* Object <: Interface subtyping creates an object out of the interface to dispatch to the
       existing object <: object logic *)
    | DefT
        ( lreason,
          ObjT
            {
              flags = { obj_kind = lkind; react_dro = _ };
              props_tmap = lprops;
              proto_t = lproto;
              call_t = lcall;
              reachable_targs = lreachable_targs;
            }
        ) ->
      let o =
        inst_type_to_obj_type cx reason_struct (own_props_id, proto_props_id, call_id, inst_dict)
      in
      let lower =
        DefT
          ( lreason,
            ObjT
              {
                flags = { obj_kind = lkind; react_dro = None };
                props_tmap = lprops;
                proto_t = lproto;
                call_t = lcall;
                reachable_targs = lreachable_targs;
              }
          )
      in
      rec_flow_t cx trace ~use_op (lower, o)
    | _ ->
      inst_structural_subtype
        cx
        trace
        ~use_op
        lower
        reason_struct
        (own_props_id, proto_props_id, call_id, inst_dict)

  and inst_structural_subtype
      cx trace ~use_op lower reason_struct (own_props_id, proto_props_id, call_id, inst_dict) =
    let lreason = reason_of_t lower in
    let lit = is_literal_object_reason lreason in
    let own_props = Context.find_props cx own_props_id in
    let proto_props = Context.find_props cx proto_props_id in
    let call_t = Base.Option.map call_id ~f:(Context.find_call cx) in
    let read_only_if_lit p =
      match p with
      | Field { key_loc = _; type_; _ } when lit ->
        OrdinaryField { type_; polarity = Polarity.Positive }
      | _ -> Property.type_ p
    in
    inst_dict
    |> Base.Option.iter ~f:(fun { key = ukey; value = uvalue; dict_polarity = upolarity; _ } ->
           match lower with
           | DefT
               ( _,
                 InstanceT
                   {
                     inst =
                       {
                         inst_dict =
                           Some { key = lkey; value = lvalue; dict_polarity = lpolarity; _ };
                         _;
                       };
                     _;
                   }
               ) ->
             rec_flow_p
               cx
               ~trace
               ~report_polarity:false
               ~use_op:
                 (Frame (IndexerKeyCompatibility { lower = lreason; upper = reason_struct }, use_op))
               lreason
               reason_struct
               (Computed ukey)
               ( OrdinaryField { type_ = lkey; polarity = lpolarity },
                 OrdinaryField { type_ = ukey; polarity = upolarity }
               );
             rec_flow_p
               cx
               ~trace
               ~use_op:
                 (Frame
                    ( PropertyCompatibility { prop = None; lower = lreason; upper = reason_struct },
                      use_op
                    )
                 )
               lreason
               reason_struct
               (Computed uvalue)
               ( OrdinaryField { type_ = lvalue; polarity = lpolarity },
                 OrdinaryField { type_ = uvalue; polarity = upolarity }
               )
           | _ -> ()
       );
    own_props
    |> NameUtils.Map.iter (fun name p ->
           let use_op =
             Frame
               ( PropertyCompatibility { prop = Some name; lower = lreason; upper = reason_struct },
                 use_op
               )
           in
           match p with
           | Field { type_ = OptionalT _ as t; polarity; _ } ->
             let propref =
               let reason =
                 update_desc_reason (fun desc -> ROptional (RPropertyOf (name, desc))) reason_struct
               in
               mk_named_prop ~reason name
             in
             let polarity =
               if lit then
                 Polarity.Positive
               else
                 polarity
             in
             rec_flow
               cx
               trace
               ( lower,
                 LookupT
                   {
                     reason = reason_struct;
                     lookup_kind =
                       NonstrictReturning
                         (Base.Option.map ~f:(fun { value; _ } -> (value, t)) inst_dict, None);
                     try_ts_on_failure = [];
                     propref;
                     lookup_action = LookupProp (use_op, OrdinaryField { type_ = t; polarity });
                     method_accessible = true;
                     ids = Some Properties.Set.empty;
                     ignore_dicts = false;
                   }
               )
           | _ ->
             let propref =
               let reason =
                 update_desc_reason (fun desc -> RPropertyOf (name, desc)) reason_struct
               in
               mk_named_prop ~reason name
             in
             rec_flow
               cx
               trace
               ( lower,
                 LookupT
                   {
                     reason = reason_struct;
                     lookup_kind = Strict lreason;
                     try_ts_on_failure = [];
                     propref;
                     lookup_action = LookupProp (use_op, read_only_if_lit p);
                     method_accessible = true;
                     ids = Some Properties.Set.empty;
                     ignore_dicts = false;
                   }
               )
       );
    proto_props
    |> NameUtils.Map.iter (fun name p ->
           let use_op =
             Frame
               ( PropertyCompatibility { prop = Some name; lower = lreason; upper = reason_struct },
                 use_op
               )
           in
           let propref =
             let reason = update_desc_reason (fun desc -> RPropertyOf (name, desc)) reason_struct in
             mk_named_prop ~reason name
           in
           rec_flow
             cx
             trace
             ( lower,
               LookupT
                 {
                   reason = reason_struct;
                   lookup_kind = Strict lreason;
                   try_ts_on_failure = [];
                   propref;
                   lookup_action = LookupProp (use_op, read_only_if_lit p);
                   method_accessible = true;
                   ids = Some Properties.Set.empty;
                   ignore_dicts = false;
                 }
             )
       );
    call_t
    |> Base.Option.iter ~f:(fun ut ->
           let prop_name = Some (OrdinaryName "$call") in
           let use_op =
             Frame
               ( PropertyCompatibility { prop = prop_name; lower = lreason; upper = reason_struct },
                 use_op
               )
           in
           match lower with
           | DefT (_, ObjT { call_t = Some lid; _ })
           | DefT (_, InstanceT { inst = { inst_call_t = Some lid; _ }; _ }) ->
             let lt = Context.find_call cx lid in
             rec_flow cx trace (lt, UseT (use_op, ut))
           | _ ->
             let reason_prop =
               update_desc_reason
                 (fun desc -> RPropertyOf (OrdinaryName "$call", desc))
                 reason_struct
             in
             let error_message =
               Error_message.EPropNotFound
                 { reason_prop; reason_obj = lreason; prop_name; use_op; suggestion = None }
             in
             add_output cx error_message
       )

  and check_super cx trace ~use_op lreason ureason t x p =
    let use_op =
      Frame (PropertyCompatibility { prop = Some x; lower = lreason; upper = ureason }, use_op)
    in
    let reason_prop = replace_desc_reason (RProperty (Some x)) lreason in
    let action = SuperProp (use_op, Property.type_ p) in
    let t =
      (* munge names beginning with single _ *)
      if is_munged_prop_name cx x then
        ObjProtoT (reason_of_t t)
      else
        t
    in
    let propref = mk_named_prop ~reason:reason_prop x in
    FlowJs.rec_flow
      cx
      trace
      ( t,
        LookupT
          {
            reason = lreason;
            lookup_kind = NonstrictReturning (None, None);
            try_ts_on_failure = [];
            propref;
            lookup_action = action;
            ids = Some Properties.Set.empty;
            method_accessible = true;
            ignore_dicts = false;
          }
      )

  and destruct cx ~trace reason kind t selector tout id =
    let annot =
      match kind with
      | DestructAnnot -> true
      | DestructInfer -> false
    in
    eval_selector cx ~trace ~annot reason t selector tout id

  and eval_selector cx ?trace ~annot reason curr_t s tvar id =
    flow_opt
      cx
      ?trace
      ( curr_t,
        match s with
        | Prop (name, has_default) ->
          let name = OrdinaryName name in
          let lookup_ub () =
            let use_op = unknown_use in
            let action = ReadProp { use_op; obj_t = curr_t; tout = tvar } in
            (* LookupT unifies with the default with tvar. To get around that, we can create some
             * indirection with a fresh tvar in between to ensure that we only add a lower bound
             *)
            let default_tout =
              Tvar.mk_where cx reason (fun tout ->
                  flow_opt cx ?trace (tout, UseT (use_op, OpenT tvar))
              )
            in
            let void_reason = replace_desc_reason RVoid (fst tvar) in
            let lookup_kind =
              NonstrictReturning (Some (DefT (void_reason, VoidT), default_tout), None)
            in
            LookupT
              {
                reason;
                lookup_kind;
                try_ts_on_failure = [];
                propref = mk_named_prop ~reason name;
                lookup_action = action;
                method_accessible = false;
                ids = Some Properties.Set.empty;
                ignore_dicts = false;
              }
          in
          let getprop_ub () =
            GetPropT
              {
                use_op = unknown_use;
                reason;
                id = Some id;
                from_annot = annot;
                skip_optional = false;
                propref = mk_named_prop ~reason name;
                tout = tvar;
                hint = hint_unavailable;
              }
          in
          if has_default then
            match curr_t with
            | DefT (_, NullT) -> getprop_ub ()
            | DefT (_, ObjT { flags = { obj_kind; _ }; proto_t = ObjProtoT _; _ })
              when Obj_type.is_exact obj_kind ->
              lookup_ub ()
            | _ -> getprop_ub ()
          else
            getprop_ub ()
        | Elem key_t ->
          GetElemT
            {
              use_op = unknown_use;
              reason;
              id = None;
              from_annot = annot;
              skip_optional = false;
              access_iterables = false;
              key_t;
              tout = tvar;
            }
        | ObjRest xs -> ObjRestT (reason, xs, OpenT tvar, id)
        | ArrRest i -> ArrRestT (unknown_use, reason, i, OpenT tvar)
        | Default -> FilterOptionalT (unknown_use, OpenT tvar)
      )

  and evaluate_type_destructor cx ~trace use_op reason t d tvar =
    (* As an optimization, unwrap resolved tvars so that they are only evaluated
     * once to an annotation instead of a tvar that gets a bound on both sides. *)
    let t = drop_resolved cx t in
    match t with
    | OpenT _
    | GenericT { bound = OpenT _; _ } ->
      let x =
        EvalTypeDestructorT
          { destructor_use_op = use_op; reason; repos = None; destructor = d; tout = tvar }
      in
      rec_flow cx trace (t, x)
    | GenericT { bound = AnnotT (r, t, use_desc); reason; name; id; no_infer } ->
      let x =
        EvalTypeDestructorT
          {
            destructor_use_op = use_op;
            reason;
            repos = Some (r, use_desc);
            destructor = d;
            tout = tvar;
          }
      in
      rec_flow cx trace (GenericT { reason; name; id; bound = t; no_infer }, x)
    | EvalT _ ->
      let x =
        EvalTypeDestructorT
          { destructor_use_op = use_op; reason; repos = None; destructor = d; tout = tvar }
      in
      rec_flow cx trace (t, x)
    | AnnotT (r, t, use_desc) ->
      let x =
        EvalTypeDestructorT
          {
            destructor_use_op = use_op;
            reason;
            repos = Some (r, use_desc);
            destructor = d;
            tout = tvar;
          }
      in
      rec_flow cx trace (t, x)
    | _ -> eval_destructor cx ~trace use_op reason t d tvar

  and mk_type_destructor cx ~trace use_op reason t d id =
    let evaluated = Context.evaluated cx in
    let result =
      match Eval.Map.find_opt id evaluated with
      | Some cached_t -> cached_t
      | None ->
        Tvar.mk_no_wrap_where cx reason (fun tvar ->
            Context.set_evaluated cx (Eval.Map.add id (OpenT tvar) evaluated);
            evaluate_type_destructor cx ~trace use_op reason t d tvar
        )
    in
    if
      (not (Flow_js_utils.TvarVisitors.has_unresolved_tvars cx t))
      && not (Flow_js_utils.TvarVisitors.has_unresolved_tvars_in_destructors cx d)
    then
      Tvar_resolver.resolve cx result;
    result

  and eval_destructor cx ~trace use_op reason t d tout =
    match d with
    (* Non-homomorphic mapped types have their own special resolution code, so they do not fit well
     * into the structure of the rest of this function. We handle them upfront instead. *)
    | MappedType
        {
          homomorphic = Unspecialized;
          mapped_type_flags;
          property_type;
          distributive_tparam_name = _;
        } ->
      let t =
        ObjectKit.mapped_type_of_keys
          cx
          trace
          use_op
          reason
          ~keys:t
          ~property_type
          mapped_type_flags
      in
      (* Intentional unknown_use for the tout Flow *)
      rec_flow cx trace (t, UseT (unknown_use, OpenT tout))
    | _ ->
      let destruct_union ?(f = (fun t -> t)) r members upper =
        let destructor = TypeDestructorT (use_op, reason, d) in
        (* `ResolveUnionT` resolves in reverse order, so `rev_map` here so we resolve in the original order. *)
        let unresolved =
          members |> Base.List.rev_map ~f:(fun t -> Cache.Eval.id cx (f t) destructor)
        in
        let (first, unresolved) = (List.hd unresolved, List.tl unresolved) in
        let u =
          ResolveUnionT { reason = r; unresolved; resolved = []; upper; id = Reason.mk_id () }
        in
        rec_flow cx trace (first, u)
      in
      let destruct_maybe ?f r t upper =
        let reason = replace_desc_new_reason RNullOrVoid r in
        let null = NullT.make reason in
        let void = VoidT.make reason in
        destruct_union ?f reason [t; null; void] upper
      in
      let destruct_optional ?f r t upper =
        let reason = replace_desc_new_reason RVoid r in
        let void = VoidT.make reason in
        destruct_union ?f reason [t; void] upper
      in
      let destruct_and_preserve_opaque_t r ({ underlying_t; lower_t; upper_t; _ } as opaquetype) =
        let eval_t t =
          let tvar = Tvar.mk_no_wrap cx reason in
          (* We have to eagerly evaluate these destructors when possible because
           * various other systems, like type_filter, expect OpaqueT underlying_t upper_t, and
           * lower_t to be inspectable *)
          eagerly_eval_destructor_if_resolved cx ~trace use_op reason t d tvar
        in
        let underlying_t = Base.Option.map ~f:eval_t underlying_t in
        let lower_t = Base.Option.map ~f:eval_t lower_t in
        let upper_t = Base.Option.map ~f:eval_t upper_t in
        let opaque_t = OpaqueT (r, { opaquetype with underlying_t; lower_t; upper_t }) in
        rec_flow_t cx trace ~use_op (opaque_t, OpenT tout)
      in
      let should_destruct_union () =
        match d with
        | ConditionalType { distributive_tparam_name; _ } -> Option.is_some distributive_tparam_name
        | ReactDRO _ ->
          (match t with
          | UnionT (_, rep) ->
            if not (UnionRep.is_optimized_finally rep) then
              UnionRep.optimize_enum_only ~flatten:(Type_mapper.union_flatten cx) rep;
            Option.is_none (UnionRep.check_enum rep)
          | _ -> true)
        | _ -> true
      in
      (match (t, d) with
      | ( GenericT
            {
              bound =
                OpaqueT
                  ( _,
                    {
                      opaque_id = Opaque.UserDefinedOpaqueTypeId opaque_id;
                      underlying_t = Some t;
                      _;
                    }
                  );
              reason = r;
              id;
              name;
              no_infer;
            },
          _
        )
        when ALoc.source (opaque_id :> ALoc.t) = Some (Context.file cx) ->
        eval_destructor
          cx
          ~trace
          use_op
          reason
          (GenericT { bound = t; reason = r; id; name; no_infer })
          d
          tout
      | (OpaqueT (r, opaquetype), ReactDRO _) -> destruct_and_preserve_opaque_t r opaquetype
      | (OpaqueT (_, { opaque_id = Opaque.UserDefinedOpaqueTypeId id; underlying_t = Some t; _ }), _)
        when ALoc.source (id :> ALoc.t) = Some (Context.file cx) ->
        eval_destructor cx ~trace use_op reason t d tout
      (* Specialize TypeAppTs before evaluating them so that we can handle special
         cases. Like the union case below. mk_typeapp_instance will return an AnnotT
         which will be fully resolved using the AnnotT case above. *)
      | ( GenericT
            {
              bound =
                TypeAppT
                  { reason = _; use_op = use_op_tapp; type_; targs; from_value; use_desc = _ };
              reason = reason_tapp;
              id;
              name;
              no_infer;
            },
          _
        ) ->
        let destructor = TypeDestructorT (use_op, reason, d) in
        let t =
          mk_typeapp_instance_annot
            cx
            ~trace
            ~use_op:use_op_tapp
            ~reason_op:reason
            ~reason_tapp
            ~from_value
            type_
            targs
        in
        rec_flow
          cx
          trace
          ( Cache.Eval.id
              cx
              (GenericT { bound = t; name; id; reason = reason_tapp; no_infer })
              destructor,
            UseT (use_op, OpenT tout)
          )
      | ( TypeAppT
            { reason = reason_tapp; use_op = use_op_tapp; type_; targs; from_value; use_desc = _ },
          _
        ) ->
        let destructor = TypeDestructorT (use_op, reason, d) in
        let t =
          mk_typeapp_instance_annot
            cx
            ~trace
            ~use_op:use_op_tapp
            ~reason_op:reason
            ~reason_tapp
            ~from_value
            type_
            targs
        in
        rec_flow_t cx trace ~use_op:unknown_use (Cache.Eval.id cx t destructor, OpenT tout)
      (* If we are destructuring a union, evaluating the destructor on the union
         itself may have the effect of splitting the union into separate lower
         bounds, which prevents the speculative match process from working.
         Instead, we preserve the union by pushing down the destructor onto the
         branches of the unions.
      *)
      | (UnionT (_, rep), _) when should_destruct_union () ->
        destruct_union reason (UnionRep.members rep) (UseT (unknown_use, OpenT tout))
      | (GenericT { reason = _; bound = UnionT (_, rep); id; name; no_infer }, _)
        when should_destruct_union () ->
        destruct_union
          ~f:(fun bound -> GenericT { reason = reason_of_t bound; bound; id; name; no_infer })
          reason
          (UnionRep.members rep)
          (UseT (use_op, OpenT tout))
      | (MaybeT (r, t), _) when should_destruct_union () ->
        destruct_maybe r t (UseT (unknown_use, OpenT tout))
      | (GenericT { reason; bound = MaybeT (_, t); id; name; no_infer }, _)
        when should_destruct_union () ->
        destruct_maybe
          ~f:(fun bound -> GenericT { reason = reason_of_t bound; bound; id; name; no_infer })
          reason
          t
          (UseT (use_op, OpenT tout))
      | (OptionalT { reason = r; type_ = t; use_desc = _ }, _) when should_destruct_union () ->
        destruct_optional r t (UseT (unknown_use, OpenT tout))
      | ( GenericT
            {
              reason;
              bound = OptionalT { reason = _; type_ = t; use_desc = _ };
              id;
              name;
              no_infer;
            },
          _
        )
        when should_destruct_union () ->
        destruct_optional
          ~f:(fun bound -> GenericT { reason = reason_of_t bound; bound; id; name; no_infer })
          reason
          t
          (UseT (use_op, OpenT tout))
      | (AnnotT (r, t, use_desc), _) ->
        let t = reposition_reason ~trace cx r ~use_desc t in
        let destructor = TypeDestructorT (use_op, reason, d) in
        rec_flow_t cx trace ~use_op:unknown_use (Cache.Eval.id cx t destructor, OpenT tout)
      | (GenericT { bound = AnnotT (_, t, use_desc); reason = r; name; id; no_infer }, _) ->
        let t = reposition_reason ~trace cx r ~use_desc t in
        let destructor = TypeDestructorT (use_op, reason, d) in
        rec_flow_t
          cx
          trace
          ~use_op
          ( Cache.Eval.id cx (GenericT { reason = r; id; name; bound = t; no_infer }) destructor,
            OpenT tout
          )
      | _ ->
        (match d with
        | NonMaybeType ->
          (* We intentionally use `unknown_use` here! When we flow to a tout we never
           * want to carry a `use_op`. We want whatever `use_op` the tout is used with
           * to win. *)
          rec_flow cx trace (t, FilterMaybeT (unknown_use, OpenT tout))
        | PropertyType { name; _ } ->
          let reason_op = replace_desc_reason (RProperty (Some name)) reason in
          let u =
            GetPropT
              {
                use_op;
                reason;
                id = None;
                from_annot = true;
                skip_optional = false;
                propref = mk_named_prop ~reason:reason_op name;
                tout;
                hint = hint_unavailable;
              }
          in
          rec_flow cx trace (t, u)
        | ElementType { index_type; _ } ->
          let u =
            GetElemT
              {
                use_op;
                reason;
                id = None;
                from_annot = true;
                skip_optional = false;
                access_iterables = false;
                key_t = index_type;
                tout;
              }
          in
          rec_flow cx trace (t, u)
        | OptionalIndexedAccessNonMaybeType { index } ->
          rec_flow cx trace (t, OptionalIndexedAccessT { use_op; reason; index; tout_tvar = tout })
        | OptionalIndexedAccessResultType { void_reason } ->
          let void = VoidT.why void_reason in
          let u =
            ResolveUnionT
              {
                reason;
                resolved = [void];
                unresolved = [];
                upper = UseT (unknown_use, OpenT tout);
                id = Reason.mk_id ();
              }
          in
          rec_flow cx trace (t, u)
        | SpreadType (options, todo_rev, head_slice) ->
          let u =
            Object.(
              Object.Spread.(
                let tool = Resolve Next in
                let state =
                  {
                    todo_rev;
                    acc = Base.Option.value_map ~f:(fun x -> [InlineSlice x]) ~default:[] head_slice;
                    spread_id = Reason.mk_id ();
                    union_reason = None;
                    curr_resolve_idx = 0;
                  }
                in
                ObjKitT (use_op, reason, tool, Spread (options, state), OpenT tout)
              )
            )
          in
          rec_flow cx trace (t, u)
        | SpreadTupleType { reason_tuple; reason_spread = _; inexact; resolved_rev; unresolved } ->
          let elem_t = Tvar.mk cx reason_tuple in
          let u =
            ResolveSpreadT
              ( use_op,
                reason_tuple,
                {
                  rrt_resolved = resolved_rev;
                  rrt_unresolved = unresolved;
                  rrt_resolve_to =
                    ResolveSpreadsToTupleType
                      { id = Reason.mk_id (); inexact; elem_t; tout = OpenT tout };
                }
              )
          in
          rec_flow cx trace (t, u)
        | ReactCheckComponentConfig pmap ->
          let u =
            Object.(
              let tool = Resolve Next in
              ObjKitT (use_op, reason, tool, Object.ReactCheckComponentConfig pmap, OpenT tout)
            )
          in
          rec_flow cx trace (t, u)
        | RestType (options, t') ->
          let u =
            Object.(
              Object.Rest.(
                let tool = Resolve Next in
                let state = One t' in
                ObjKitT (use_op, reason, tool, Rest (options, state), OpenT tout)
              )
            )
          in
          rec_flow cx trace (t, u)
        | ExactType ->
          rec_flow
            cx
            trace
            (t, Object.(ObjKitT (use_op, reason, Resolve Next, MakeExact, OpenT tout)))
        | ReadOnlyType ->
          rec_flow
            cx
            trace
            (t, Object.(ObjKitT (use_op, reason, Resolve Next, ReadOnly, OpenT tout)))
        | ReactDRO (dro_loc, dro_type) ->
          rec_flow cx trace (t, DeepReadOnlyT (tout, (dro_loc, dro_type)))
        | MakeHooklike -> rec_flow cx trace (t, HooklikeT tout)
        | PartialType ->
          rec_flow cx trace (t, Object.(ObjKitT (use_op, reason, Resolve Next, Partial, OpenT tout)))
        | RequiredType ->
          rec_flow
            cx
            trace
            (t, Object.(ObjKitT (use_op, reason, Resolve Next, Required, OpenT tout)))
        | ValuesType -> rec_flow cx trace (t, GetValuesT (reason, OpenT tout))
        | ConditionalType { distributive_tparam_name; infer_tparams; extends_t; true_t; false_t } ->
          let u =
            ConditionalT
              {
                use_op;
                reason;
                distributive_tparam_name;
                infer_tparams;
                extends_t;
                true_t;
                false_t;
                tout;
              }
          in
          rec_flow cx trace (t, u)
        | TypeMap tmap -> rec_flow cx trace (t, MapTypeT (use_op, reason, tmap, OpenT tout))
        | ReactElementPropsType ->
          rec_flow cx trace (t, ReactKitT (use_op, reason, React.GetProps (OpenT tout)))
        | ReactElementConfigType ->
          rec_flow cx trace (t, ReactKitT (use_op, reason, React.GetConfig (OpenT tout)))
        | MappedType { property_type; mapped_type_flags; homomorphic; distributive_tparam_name } ->
          let (property_type, homomorphic) =
            substitute_mapped_type_distributive_tparams
              cx
              ~use_op
              distributive_tparam_name
              ~property_type
              homomorphic
              ~source:t
          in
          let selected_keys_opt =
            match homomorphic with
            | SemiHomomorphic t -> Some t
            | _ -> None
          in
          let u =
            Object.(
              ObjKitT
                ( use_op,
                  reason,
                  Resolve Next,
                  Object.ObjectMap
                    { prop_type = property_type; mapped_type_flags; selected_keys_opt },
                  OpenT tout
                )
            )
          in
          rec_flow cx trace (t, u)
        | EnumType ->
          let u =
            GetEnumT { use_op; reason; orig_t = Some t; kind = `GetEnumObject; tout = OpenT tout }
          in
          rec_flow cx trace (t, u)))

  and eagerly_eval_destructor_if_resolved cx ~trace use_op reason t d tvar =
    eval_destructor cx ~trace use_op reason t d (reason, tvar);
    let result = OpenT (reason, tvar) in
    if
      (not (Subst_name.Set.is_empty (Type_subst.free_var_finder cx t)))
      || (not (Subst_name.Set.is_empty (Type_subst.free_var_finder_in_destructor cx d)))
      || Flow_js_utils.TvarVisitors.has_unresolved_tvars cx t
      || Flow_js_utils.TvarVisitors.has_unresolved_tvars_in_destructors cx d
    then
      result
    else (
      Tvar_resolver.resolve cx result;
      let t = singleton_concrete_type_for_inspection cx reason result in
      match t with
      | OpenT (_, id) ->
        let (_, constraints) = Context.find_constraints cx id in
        (match constraints with
        | FullyResolved t -> Context.force_fully_resolved_tvar cx t
        | _ -> t)
      | t -> t
    )

  and mk_possibly_evaluated_destructor cx use_op reason t d id =
    let eval_t = EvalT (t, TypeDestructorT (use_op, reason, d), id) in
    ( if Subst_name.Set.is_empty (Type_subst.free_var_finder cx eval_t) then
      let evaluated = Context.evaluated cx in
      match Eval.Map.find_opt id evaluated with
      | Some _ -> ()
      | None ->
        let trace = DepthTrace.dummy_trace in
        let eval_t = EvalT (t, TypeDestructorT (use_op, reason, d), id) in
        if Flow_js_utils.TvarVisitors.has_unresolved_tvars cx eval_t then
          ignore
          @@ Tvar.mk_no_wrap_where cx reason (fun tvar ->
                 Context.set_evaluated cx (Eval.Map.add id (OpenT tvar) evaluated);
                 evaluate_type_destructor cx ~trace use_op reason t d tvar
             )
        else if Flow_js_utils.TvarVisitors.has_placeholders cx eval_t then
          ignore
          @@ Tvar.mk_no_wrap_where cx reason (fun tvar ->
                 Context.set_evaluated cx (Eval.Map.add id (OpenT tvar) evaluated);
                 evaluate_type_destructor cx ~trace use_op reason t d tvar;
                 Tvar_resolver.resolve cx (OpenT tvar)
             )
        else
          let result =
            Flow_js_utils.map_on_resolved_type cx reason t (fun t ->
                Tvar_resolver.mk_tvar_and_fully_resolve_no_wrap_where
                  cx
                  reason
                  (evaluate_type_destructor cx ~trace use_op reason t d)
            )
          in
          Context.set_evaluated cx (Eval.Map.add id result evaluated)
    );
    eval_t

  (* Instantiate a polymorphic definition given tparam instantiations in a Call or
   * New expression. *)
  and instantiate_with_targs_with_soln
      cx trace ~use_op ~reason_op ~reason_tapp (tparams_loc, xs, t) targs =
    let (_, ts) =
      Nel.fold_left
        (fun (targs, ts) _ ->
          match targs with
          | [] -> ([], ts)
          | ExplicitArg t :: targs -> (targs, t :: ts)
          | ImplicitArg _ :: _ ->
            failwith
              "targs containing ImplicitArg should be handled by ImplicitInstantiationKit instead.")
        (targs, [])
        xs
    in
    instantiate_poly_with_targs
      cx
      trace
      ~use_op
      ~reason_op
      ~reason_tapp
      (tparams_loc, xs, t)
      (List.rev ts)

  and instantiate_with_targs cx trace ~use_op ~reason_op ~reason_tapp (tparams_loc, xs, t) targs =
    let (t, _) =
      instantiate_with_targs_with_soln
        cx
        trace
        ~use_op
        ~reason_op
        ~reason_tapp
        (tparams_loc, xs, t)
        targs
    in
    t

  and instantiate_poly_call_or_new_with_soln cx trace lparts uparts check =
    let (reason_tapp, tparams_loc, ids, t) = lparts in
    let (use_op, reason_op, targs, return_hint) = uparts in
    match all_explicit_targs targs with
    | Some targs ->
      instantiate_with_targs_with_soln
        cx
        trace
        (tparams_loc, ids, t)
        targs
        ~use_op
        ~reason_op
        ~reason_tapp
    | None ->
      let check = Lazy.force check in
      ImplicitInstantiationKit.run_call cx check trace ~use_op ~reason_op ~reason_tapp ~return_hint

  and instantiate_poly_call_or_new cx trace lparts uparts check =
    let (reason_tapp, tparams_loc, ids, t) = lparts in
    let (use_op, reason_op, targs, return_hint) = uparts in
    match all_explicit_targs targs with
    | Some targs ->
      instantiate_with_targs cx trace (tparams_loc, ids, t) targs ~use_op ~reason_op ~reason_tapp
    | None ->
      let check = Lazy.force check in
      let (t, _) =
        ImplicitInstantiationKit.run_call
          cx
          check
          trace
          ~use_op
          ~reason_op
          ~reason_tapp
          ~return_hint
      in
      t

  (* Instantiate a polymorphic definition with stated bound or 'any' for args *)
  (* Needed only for `instanceof` refis and React.PropTypes.instanceOf types *)
  and instantiate_poly_default_args cx trace ~use_op ~reason_op ~reason_tapp (tparams_loc, xs, t) =
    (* Remember: other_bound might refer to other type params *)
    let (ts, _) =
      Nel.fold_left
        (fun (ts, map) typeparam ->
          let t = Unsoundness.why InstanceOfRefinement reason_op in
          (t :: ts, Subst_name.Map.add typeparam.name t map))
        ([], Subst_name.Map.empty)
        xs
    in
    let ts = List.rev ts in
    let (t, _) =
      instantiate_poly_with_targs cx trace ~use_op ~reason_op ~reason_tapp (tparams_loc, xs, t) ts
    in
    t

  (* Specialize This in a class. Eventually this causes substitution. *)
  and instantiate_this_class cx trace ~reason_op ~reason_tapp c ts this k =
    let tc =
      match ts with
      | None -> c
      | Some ts ->
        Tvar.mk_where cx reason_tapp (fun tout ->
            rec_flow cx trace (c, SpecializeT (unknown_use, reason_op, reason_tapp, Some ts, tout))
        )
    in
    rec_flow cx trace (tc, ThisSpecializeT (reason_tapp, this, k))

  (*********)
  (* enums *)
  (*********)
  and enum_exhaustive_check
      cx
      ~trace
      ~check_reason
      ~enum_reason
      ~enum
      ~possible_checks
      ~checks
      ~default_case_loc
      ~incomplete_out
      ~discriminant_after_check =
    match possible_checks with
    (* No possible checks left to resolve, analyze the exhaustive check. *)
    | [] ->
      let { members; has_unknown_members; _ } = enum in
      let check_member (members_remaining, seen) (EnumCheck { case_test_loc; member_name }) =
        if not @@ SMap.mem member_name members_remaining then
          add_output
            cx
            (Error_message.EEnumMemberAlreadyChecked
               {
                 case_test_loc;
                 prev_check_loc = SMap.find member_name seen;
                 enum_reason;
                 member_name;
               }
            );
        (SMap.remove member_name members_remaining, SMap.add member_name case_test_loc seen)
      in
      let (left_over, _) = List.fold_left check_member (members, SMap.empty) checks in
      (match (SMap.is_empty left_over, default_case_loc, has_unknown_members) with
      | (false, _, _) ->
        add_output
          cx
          (Error_message.EEnumNotAllChecked
             {
               reason = check_reason;
               enum_reason;
               left_to_check = SMap.keys left_over;
               default_case_loc;
             }
          );
        enum_exhaustive_check_incomplete cx ~trace ~reason:check_reason incomplete_out
      (* When we have unknown members, a default is required even when we've checked all known members. *)
      | (true, None, true) ->
        add_output cx (Error_message.EEnumUnknownNotChecked { reason = check_reason; enum_reason });
        enum_exhaustive_check_incomplete cx ~trace ~reason:check_reason incomplete_out
      | (true, Some _, true) -> ()
      | (true, Some default_case_loc, false) ->
        add_output
          cx
          (Error_message.EEnumAllMembersAlreadyChecked { loc = default_case_loc; enum_reason })
      | _ -> ())
    (* There are still possible checks to resolve, continue to resolve them. *)
    | (obj_t, check) :: rest_possible_checks ->
      let exhaustive_check =
        EnumExhaustiveCheckT
          {
            reason = check_reason;
            check =
              EnumExhaustiveCheckPossiblyValid
                {
                  tool =
                    EnumResolveCaseTest
                      { discriminant_enum = enum; discriminant_reason = enum_reason; check };
                  possible_checks = rest_possible_checks;
                  checks;
                  default_case_loc;
                };
            incomplete_out;
            discriminant_after_check;
          }
      in
      rec_flow cx trace (obj_t, exhaustive_check)

  and enum_exhaustive_check_incomplete
      cx ~trace ~reason ?(trigger = VoidT.why reason) incomplete_out =
    rec_flow_t cx trace ~use_op:unknown_use (trigger, incomplete_out)

  and resolve_union cx trace reason id resolved unresolved l upper =
    let continue resolved =
      match unresolved with
      | [] -> rec_flow cx trace (union_of_ts reason resolved, upper)
      | next :: rest ->
        (* We intentionally do not rec_flow here. Unions can be very large, and resolving each
         * member under the same trace can cause a recursion limit error. To avoid that, we resolve
         * each member under their own trace *)
        flow cx (next, ResolveUnionT { reason; resolved; unresolved = rest; upper; id })
    in
    match l with
    | DefT (_, EmptyT) -> continue resolved
    | _ ->
      let reason_elemt = reason_of_t l in
      let pos = Base.List.length resolved in
      (* Union resolution can fall prey to the same sort of infinite recursion that array spreads can, so
         we can use the same constant folding guard logic that arrays do. To more fully understand how that works,
         see the comment there. *)
      ConstFoldExpansion.guard cx id (reason_elemt, pos) (function
          | 0 -> continue (l :: resolved)
          (* Unions are idempotent, so we can just skip any duplicated elements *)
          | 1 -> continue resolved
          | _ -> ()
          )

  (** Property lookup functions in objects and instances *)

  (* property lookup functions in objects and instances *)
  and prop_typo_suggestion cx ids =
    Base.List.(
      ids
      >>| Context.find_real_props cx
      >>= NameUtils.Map.keys
      |> Base.List.rev_map ~f:display_string_of_name
      |> typo_suggestion
    )

  and get_private_prop
      ~cx
      ~allow_method_access
      ~trace
      ~l
      ~reason_c
      ~instance
      ~use_op
      ~reason_op
      ~prop_name
      ~scopes
      ~static
      ~tout =
    match scopes with
    | [] ->
      add_output
        cx
        (Error_message.EPrivateLookupFailed ((reason_op, reason_c), OrdinaryName prop_name, use_op))
    | scope :: scopes ->
      if not (ALoc.equal_id scope.class_binding_id instance.class_id) then
        get_private_prop
          ~cx
          ~allow_method_access
          ~trace
          ~l
          ~reason_c
          ~instance
          ~use_op
          ~reason_op
          ~prop_name
          ~scopes
          ~static
          ~tout
      else
        let name = OrdinaryName prop_name in
        let perform_lookup_action p =
          let action = ReadProp { use_op; obj_t = l; tout } in
          let propref = mk_named_prop ~reason:reason_op name in
          perform_lookup_action cx trace propref p PropertyMapProperty reason_c reason_op action
        in
        let field_maps =
          if static then
            instance.class_private_static_fields
          else
            instance.class_private_fields
        in
        (match NameUtils.Map.find_opt name (Context.find_props cx field_maps) with
        | Some p -> perform_lookup_action (Property.type_ p)
        | None ->
          let method_maps =
            if static then
              instance.class_private_static_methods
            else
              instance.class_private_methods
          in
          (match NameUtils.Map.find_opt name (Context.find_props cx method_maps) with
          | Some p ->
            ( if not allow_method_access then
              match p with
              | Method { type_ = t; _ } ->
                add_output
                  cx
                  (Error_message.EMethodUnbinding { use_op; reason_op; reason_prop = reason_of_t t })
              | _ -> ()
            );
            perform_lookup_action (Property.type_ p)
          | None ->
            add_output cx (Error_message.EPrivateLookupFailed ((reason_op, reason_c), name, use_op))))

  and elem_action_on_obj cx trace ~use_op l obj reason_op action =
    let propref = propref_for_elem_t cx l in
    match action with
    | ReadElem { id; from_annot; skip_optional; access_iterables = _; tout } ->
      rec_flow
        cx
        trace
        ( obj,
          GetPropT
            {
              use_op;
              reason = reason_op;
              from_annot;
              skip_optional;
              id;
              propref;
              tout;
              hint = hint_unavailable;
            }
        )
    | WriteElem { tin; tout; mode } ->
      rec_flow cx trace (obj, SetPropT (use_op, reason_op, propref, mode, Normal, tin, None));
      Base.Option.iter ~f:(fun t -> rec_flow_t cx trace ~use_op:unknown_use (obj, t)) tout
    | CallElem (reason_call, ft) ->
      rec_flow cx trace (obj, MethodT (use_op, reason_call, reason_op, propref, ft))

  and write_obj_prop cx trace ~use_op ~mode o propref reason_obj reason_op tin prop_tout =
    let obj_t = DefT (reason_obj, ObjT o) in
    let action = WriteProp { use_op; obj_t; prop_tout; tin; write_ctx = Normal; mode } in
    match
      GetPropTKit.get_obj_prop
        cx
        trace
        ~skip_optional:false
        ~never_union_void_on_computed_prop_access:true
        use_op
        o
        propref
        reason_op
    with
    | Some (p, target_kind) ->
      perform_lookup_action cx trace propref p target_kind reason_obj reason_op action
    | None ->
      (match propref with
      | Named { reason; name = OrdinaryName "constructor"; _ } ->
        let reason = replace_desc_reason (RFunction RNormal) reason in
        let rest_param =
          Some (None, loc_of_reason reason, EmptyT.why (replace_desc_new_reason REmpty reason))
        in
        let funtype =
          mk_boundfunctiontype
            ~this:(global_this reason)
            []
            ~rest_param
            ~def_reason:reason
            ~type_guard:None
            (AnyT.untyped reason)
        in
        let fn = DefT (reason, FunT (dummy_static reason, funtype)) in
        rec_flow_t cx trace ~use_op (tin, fn);
        Base.Option.iter ~f:(fun t -> rec_flow_t cx trace ~use_op:unknown_use (fn, t)) prop_tout
      | Named { reason = reason_prop; name; _ } ->
        if Obj_type.is_exact o.flags.obj_kind then
          add_output
            cx
            (Error_message.EPropNotFound
               {
                 prop_name = Some name;
                 reason_prop;
                 reason_obj;
                 use_op;
                 suggestion = prop_typo_suggestion cx [o.props_tmap] (display_string_of_name name);
               }
            )
        else
          let lookup_kind = Strict reason_obj in
          rec_flow
            cx
            trace
            ( o.proto_t,
              LookupT
                {
                  reason = reason_op;
                  lookup_kind;
                  try_ts_on_failure = [];
                  propref;
                  lookup_action = action;
                  ids = Some (Properties.Set.singleton o.props_tmap);
                  method_accessible = true;
                  ignore_dicts = false;
                }
            )
      | Computed elem_t ->
        rec_flow
          cx
          trace
          ( elem_t,
            WriteComputedObjPropCheckT
              {
                reason = TypeUtil.reason_of_t elem_t;
                reason_key = None;
                value_t = tin;
                err_on_str_key = (use_op, reason_obj);
              }
          ))

  (* filter out undefined from a type *)
  and filter_optional cx ?trace reason opt_t =
    let tvar = Tvar.mk_no_wrap cx reason in
    flow_opt cx ?trace (opt_t, FilterOptionalT (unknown_use, OpenT (reason, tvar)));
    tvar

  and pick_use_op cx op1 op2 =
    let ignore_root = function
      | UnknownUse -> true
      (* If we are speculating then a Speculation use_op should be considered
       * "opaque". If we are not speculating then Speculation use_ops that escaped
       * (through benign tvars) should be ignored.
       *
       * Ideally we could replace the Speculation use_ops on benign tvars with their
       * underlying use_op after speculation ends. *)
      | Speculation _ -> not (Speculation.speculating cx)
      | _ -> false
    in
    if ignore_root (root_of_use_op op1) then
      op2
    else
      let root_of_op2 = root_of_use_op op2 in
      let should_replace =
        fold_use_op
          (* If the root of the previous use_op is UnknownUse and our alternate
           * use_op does not have an UnknownUse root then we use our
           * alternate use_op. *)
          ignore_root
          (fun should_replace -> function
            (* If the use was added to an implicit type param then we want to use
             * our alternate if the implicit type param use_op chain is inside
             * the implicit type param instantiation. Since we can't directly compare
             * abstract locations, we determine whether to do this using a heuristic
             * based on the 'locality' of the use_op root. *)
            | ImplicitTypeParam when not should_replace ->
              (match root_of_op2 with
              | FunCall { local; _ }
              | FunCallMethod { local; _ } ->
                local
              | AssignVar _
              | Coercion _
              | DeleteVar _
              | DeleteProperty _
              | FunImplicitReturn _
              | FunReturnStatement _
              | GetProperty _
              | IndexedTypeAccess _
              | InferBoundCompatibilityCheck _
              | EvalMappedType _
              | SetProperty _
              | UpdateProperty _
              | JSXCreateElement _
              | ObjectAddComputedProperty _
              | ObjectSpread _
              | ObjectRest _
              | ObjectChain _
              | TypeApplication _
              | Speculation _
              | InitField _ ->
                true
              | Cast _
              | RefinementCheck _
              | SwitchRefinementCheck _
              | ClassExtendsCheck _
              | ClassMethodDefinition _
              | ClassImplementsCheck _
              | ClassOwnProtoCheck _
              | ConformToCommonInterface _
              | DeclareComponentRef _
              | GeneratorYield _
              | ReactCreateElementCall _
              | ReactGetIntrinsic _
              | MatchingProp _
              | TypeGuardIncompatibility _
              | RenderTypeInstantiation _
              | ComponentRestParamCompatibility _
              | PositiveTypeGuardConsistency _
              | UnknownUse ->
                false)
            | UnifyFlip when not should_replace ->
              (match root_of_op2 with
              | TypeApplication _ -> true
              | _ -> should_replace)
            | _ -> should_replace)
          op2
      in
      if should_replace then
        op1
      else
        op2

  and flow_use_op cx op1 u = mod_use_op_of_use_t (fun op2 -> pick_use_op cx op1 op2) u

  (** Bounds Manipulation

    The following general considerations apply when manipulating bounds.

    1. All type variables start out as roots, but some of them eventually become
    goto nodes. As such, bounds of roots may contain goto nodes. However, we
    never perform operations directly on goto nodes; instead, we perform those
    operations on their roots. It is tempting to replace goto nodes proactively
    with their roots to avoid this issue, but doing so may be expensive, whereas
    the union-find data structure amortizes the cost of looking up roots.

    2. Another issue is that while the bounds of a type variable start out
    empty, and in particular do not contain the type variable itself, eventually
    other type variables in the bounds may be unified with the type variable. We
    do not remove these type variables proactively, but instead filter them out
    when considering the bounds. In the future we might consider amortizing the
    cost of this filtering.

    3. When roots are resolved, they act like the corresponding concrete
    types. We maintain the invariant that whenever lower bounds or upper bounds
    contain resolved roots, they also contain the corresponding concrete types.

    4. When roots are unresolved (they have lower bounds and upper bounds,
    possibly consisting of concrete types as well as type variables), we
    maintain the invarant that every lower bound has already been propagated to
    every upper bound. We also maintain the invariant that the bounds are
    transitively closed modulo equivalence: for every type variable in the
    bounds, all the bounds of its root are also included.
   **)

  (* for each l in ls: l => u *)
  and flows_to_t cx trace ls u =
    ls
    |> TypeMap.iter (fun l (trace_l, use_op) ->
           let u = flow_use_op cx use_op u in
           join_flow cx [trace_l; trace] (l, u)
       )

  (* for each u in us: l => u *)
  and flows_from_t cx trace ~new_use_op l us =
    us
    |> UseTypeMap.iter (fun (u, _) trace_u ->
           let u = flow_use_op cx new_use_op u in
           join_flow cx [trace; trace_u] (l, u)
       )

  (* for each l in ls, u in us: l => u *)
  and flows_across cx trace ~use_op ls us =
    ls
    |> TypeMap.iter (fun l (trace_l, use_op') ->
           us
           |> UseTypeMap.iter (fun (u, _) trace_u ->
                  let u = flow_use_op cx use_op' (flow_use_op cx use_op u) in
                  join_flow cx [trace_l; trace; trace_u] (l, u)
              )
       )

  (* bounds.upper += u *)
  and add_upper cx u trace bounds =
    bounds.upper <- UseTypeMap.add (u, Context.speculation_id cx) trace bounds.upper

  (* bounds.lower += l *)
  and add_lower l (trace, use_op) bounds =
    bounds.lower <- TypeMap.add l (trace, use_op) bounds.lower

  (** Given a map of bindings from tvars to traces, a tvar to skip, and an `each`
    function taking a tvar and its associated trace, apply `each` to all
    unresolved root constraints reached from the bound tvars, except those of
    skip_tvar. (Typically skip_tvar is a tvar that will be processed separately,
    so we don't want to redo that work. We also don't want to consider any tvar
    that has already been resolved, because the resolved type will be processed
    separately, too, as part of the bounds of skip_tvar. **)
  and iter_with_filter cx bindings skip_id each =
    bindings
    |> IMap.iter (fun id trace ->
           match Context.find_constraints cx id with
           | (root_id, Unresolved bounds) when root_id <> skip_id -> each (root_id, bounds) trace
           | _ -> ()
       )

  (** Given [edges_to_t (id1, bounds1) t2], for each [id] in [id1] + [bounds1.lowertvars],
    [id.bounds.upper += t2]. When going through [bounds1.lowertvars], filter out [id1].

    As an optimization, skip [id1] when it will become either a resolved root or a
    goto node (so that updating its bounds is unnecessary). *)
  and edges_to_t cx trace ?(opt = false) (id1, bounds1) t2 =
    if not opt then add_upper cx t2 trace bounds1;
    iter_with_filter cx bounds1.lowertvars id1 (fun (_, bounds) (trace_l, use_op) ->
        let t2 = flow_use_op cx use_op t2 in
        add_upper cx t2 (DepthTrace.concat_trace [trace_l; trace]) bounds
    )

  (** Given [edges_from_t t1 (id2, bounds2)], for each [id] in [id2] + [bounds2.uppertvars],
    [id.bounds.lower += t1]. When going through [bounds2.uppertvars], filter out [id2].

    As an optimization, skip [id2] when it will become either a resolved root or a
    goto node (so that updating its bounds is unnecessary). *)
  and edges_from_t cx trace ~new_use_op ?(opt = false) t1 (id2, bounds2) =
    if not opt then add_lower t1 (trace, new_use_op) bounds2;
    iter_with_filter cx bounds2.uppertvars id2 (fun (_, bounds) (trace_u, use_op) ->
        let use_op = pick_use_op cx new_use_op use_op in
        add_lower t1 (DepthTrace.concat_trace [trace; trace_u], use_op) bounds
    )

  (** for each [id'] in [id] + [bounds.lowertvars], [id'.bounds.upper += us] *)
  and edges_to_ts ~new_use_op cx trace ?(opt = false) (id, bounds) us =
    us
    |> UseTypeMap.iter (fun (u, _) trace_u ->
           let u = flow_use_op cx new_use_op u in
           edges_to_t cx (DepthTrace.concat_trace [trace; trace_u]) ~opt (id, bounds) u
       )

  (** for each [id'] in [id] + [bounds.uppertvars], [id'.bounds.lower += ls] *)
  and edges_from_ts cx trace ~new_use_op ?(opt = false) ls (id, bounds) =
    ls
    |> TypeMap.iter (fun l (trace_l, use_op) ->
           let new_use_op = pick_use_op cx use_op new_use_op in
           edges_from_t cx (DepthTrace.concat_trace [trace_l; trace]) ~new_use_op ~opt l (id, bounds)
       )

  (** for each [id] in [id1] + [bounds1.lowertvars]:
        id.bounds.upper += t2
        for each l in bounds1.lower: l => t2

    As an invariant, [bounds1.lower] should already contain [id.bounds.lower] for
    each id in [bounds1.lowertvars]. *)
  and edges_and_flows_to_t cx trace ?(opt = false) (id1, bounds1) t2 =
    (* Skip iff edge exists as part of the speculation path to the current branch *)
    let skip =
      List.exists
        (fun branch ->
          let Speculation_state.{ speculation_id; case = { case_id; _ }; _ } = branch in
          UseTypeMap.mem (t2, Some (speculation_id, case_id)) bounds1.upper)
        !(Context.speculation_state cx)
      || UseTypeMap.mem (t2, None) bounds1.upper
    in
    if not skip then (
      edges_to_t cx trace ~opt (id1, bounds1) t2;
      flows_to_t cx trace bounds1.lower t2
    )

  (** for each [id] in [id2] + [bounds2.uppertvars]:
        id.bounds.lower += t1
        for each u in bounds2.upper: t1 => u

    As an invariant, [bounds2.upper] should already contain [id.bounds.upper] for
    each id in [bounds2.uppertvars]. *)
  and edges_and_flows_from_t cx trace ~new_use_op ?(opt = false) t1 (id2, bounds2) =
    if not (TypeMap.mem t1 bounds2.lower) then (
      edges_from_t cx trace ~new_use_op ~opt t1 (id2, bounds2);
      flows_from_t cx trace ~new_use_op t1 bounds2.upper
    )

  (** bounds.uppertvars += id *)
  and add_uppertvar id trace use_op bounds =
    bounds.uppertvars <- IMap.add id (trace, use_op) bounds.uppertvars

  (** bounds.lowertvars += id *)
  and add_lowertvar id trace use_op bounds =
    bounds.lowertvars <- IMap.add id (trace, use_op) bounds.lowertvars

  (** for each [id] in [id1] + [bounds1.lowertvars]:
        id.bounds.uppertvars += id2

    When going through [bounds1.lowertvars], filter out [id1].

    As an optimization, skip id1 when it will become either a resolved root or a
    goto node (so that updating its bounds is unnecessary). *)
  and edges_to_tvar cx trace ~new_use_op ?(opt = false) (id1, bounds1) id2 =
    if not opt then add_uppertvar id2 trace new_use_op bounds1;
    iter_with_filter cx bounds1.lowertvars id1 (fun (_, bounds) (trace_l, use_op) ->
        let use_op = pick_use_op cx use_op new_use_op in
        add_uppertvar id2 (DepthTrace.concat_trace [trace_l; trace]) use_op bounds
    )

  (** for each id in id2 + bounds2.uppertvars:
        id.bounds.lowertvars += id1

    When going through bounds2.uppertvars, filter out id2.

    As an optimization, skip id2 when it will become either a resolved root or a
    goto node (so that updating its bounds is unnecessary). *)
  and edges_from_tvar cx trace ~new_use_op ?(opt = false) id1 (id2, bounds2) =
    if not opt then add_lowertvar id1 trace new_use_op bounds2;
    iter_with_filter cx bounds2.uppertvars id2 (fun (_, bounds) (trace_u, use_op) ->
        let use_op = pick_use_op cx new_use_op use_op in
        add_lowertvar id1 (DepthTrace.concat_trace [trace; trace_u]) use_op bounds
    )

  (** for each id in id1 + bounds1.lowertvars:
        id.bounds.upper += bounds2.upper
        id.bounds.uppertvars += id2
        id.bounds.uppertvars += bounds2.uppertvars *)
  and add_upper_edges ~new_use_op cx trace ?(opt = false) (id1, bounds1) (id2, bounds2) =
    edges_to_ts ~new_use_op cx trace ~opt (id1, bounds1) bounds2.upper;
    edges_to_tvar cx trace ~new_use_op ~opt (id1, bounds1) id2;
    iter_with_filter cx bounds2.uppertvars id2 (fun (tvar, _) (trace_u, use_op) ->
        let new_use_op = pick_use_op cx new_use_op use_op in
        let trace = DepthTrace.concat_trace [trace; trace_u] in
        edges_to_tvar cx trace ~new_use_op ~opt (id1, bounds1) tvar
    )

  (** for each id in id2 + bounds2.uppertvars:
        id.bounds.lower += bounds1.lower
        id.bounds.lowertvars += id1
        id.bounds.lowertvars += bounds1.lowertvars *)
  and add_lower_edges cx trace ~new_use_op ?(opt = false) (id1, bounds1) (id2, bounds2) =
    edges_from_ts cx trace ~new_use_op ~opt bounds1.lower (id2, bounds2);
    edges_from_tvar cx trace ~new_use_op ~opt id1 (id2, bounds2);
    iter_with_filter cx bounds1.lowertvars id1 (fun (tvar, _) (trace_l, use_op) ->
        let use_op = pick_use_op cx use_op new_use_op in
        let trace = DepthTrace.concat_trace [trace_l; trace] in
        edges_from_tvar cx trace ~new_use_op:use_op ~opt tvar (id2, bounds2)
    )

  (***************)
  (* unification *)
  (***************)
  and unify_flip use_op = Frame (UnifyFlip, use_op)

  (** Chain a root to another root. If both roots are unresolved, this amounts to
    copying over the bounds of one root to another, and adding all the
    connections necessary when two non-unifiers flow to each other. If one or
    both of the roots are resolved, they effectively act like the corresponding
    concrete types. *)
  and goto cx trace ~use_op (id1, node1, root1) (id2, _, root2) =
    match (root1.constraints, root2.constraints) with
    | (Unresolved bounds1, Unresolved bounds2) ->
      let cond1 = not_linked (id1, bounds1) (id2, bounds2) in
      let cond2 = not_linked (id2, bounds2) (id1, bounds1) in
      if cond1 then flows_across cx trace ~use_op bounds1.lower bounds2.upper;
      if cond2 then flows_across cx trace ~use_op:(unify_flip use_op) bounds2.lower bounds1.upper;
      if cond1 then (
        add_upper_edges cx trace ~new_use_op:use_op ~opt:true (id1, bounds1) (id2, bounds2);
        add_lower_edges cx trace ~new_use_op:use_op (id1, bounds1) (id2, bounds2)
      );
      if cond2 then (
        add_upper_edges cx trace ~new_use_op:(unify_flip use_op) (id2, bounds2) (id1, bounds1);
        add_lower_edges
          cx
          trace
          ~new_use_op:(unify_flip use_op)
          ~opt:true
          (id2, bounds2)
          (id1, bounds1)
      );
      node1 := Goto { parent = id2 }
    | (Unresolved bounds1, Resolved t2) ->
      let t2_use = UseT (use_op, t2) in
      edges_and_flows_to_t cx trace ~opt:true (id1, bounds1) t2_use;
      edges_and_flows_from_t cx trace ~new_use_op:(unify_flip use_op) ~opt:true t2 (id1, bounds1);
      node1 := Goto { parent = id2 }
    | (Unresolved bounds1, FullyResolved s2) ->
      let t2 = Context.force_fully_resolved_tvar cx s2 in
      let t2_use = UseT (use_op, t2) in
      edges_and_flows_to_t cx trace ~opt:true (id1, bounds1) t2_use;
      edges_and_flows_from_t cx trace ~new_use_op:(unify_flip use_op) ~opt:true t2 (id1, bounds1);
      node1 := Goto { parent = id2 }
    | (Resolved t1, Unresolved bounds2) ->
      let t1_use = UseT (unify_flip use_op, t1) in
      edges_and_flows_to_t cx trace ~opt:true (id2, bounds2) t1_use;
      edges_and_flows_from_t cx trace ~new_use_op:use_op ~opt:true t1 (id2, bounds2);
      root2.constraints <- root1.constraints;
      node1 := Goto { parent = id2 }
    | (FullyResolved s1, Unresolved bounds2) ->
      let t1 = Context.force_fully_resolved_tvar cx s1 in
      let t1_use = UseT (unify_flip use_op, t1) in
      edges_and_flows_to_t cx trace ~opt:true (id2, bounds2) t1_use;
      edges_and_flows_from_t cx trace ~new_use_op:use_op ~opt:true t1 (id2, bounds2);
      root2.constraints <- root1.constraints;
      node1 := Goto { parent = id2 }
    | (Resolved t1, Resolved t2) ->
      (* replace node first, in case rec_unify recurses back to these tvars *)
      node1 := Goto { parent = id2 };
      rec_unify cx trace ~use_op t1 t2
    | (Resolved t1, FullyResolved s2) ->
      let t2 = Context.force_fully_resolved_tvar cx s2 in
      (* replace node first, in case rec_unify recurses back to these tvars *)
      node1 := Goto { parent = id2 };
      rec_unify cx trace ~use_op t1 t2
    | (FullyResolved s1, FullyResolved s2) ->
      let t1 = Context.force_fully_resolved_tvar cx s1 in
      let t2 = Context.force_fully_resolved_tvar cx s2 in
      (* replace node first, in case rec_unify recurses back to these tvars *)
      node1 := Goto { parent = id2 };
      rec_unify cx trace ~use_op t1 t2
    | (FullyResolved s1, Resolved t2) ->
      let t1 = Context.force_fully_resolved_tvar cx s1 in
      (* prefer fully resolved roots to resolved roots *)
      root2.constraints <- root1.constraints;
      (* replace node first, in case rec_unify recurses back to these tvars *)
      node1 := Goto { parent = id2 };
      rec_unify cx trace ~use_op t1 t2

  (** Unify two type variables. This involves finding their roots, and making one
    point to the other. Ranks are used to keep chains short. *)
  and merge_ids cx trace ~use_op id1 id2 =
    let ((id1, _, root1) as root_node1) = Context.find_root cx id1 in
    let ((id2, _, root2) as root_node2) = Context.find_root cx id2 in
    if id1 = id2 then
      ()
    else if root1.rank < root2.rank then
      goto cx trace ~use_op root_node1 root_node2
    else if root2.rank < root1.rank then
      goto cx trace ~use_op:(unify_flip use_op) root_node2 root_node1
    else (
      root2.rank <- root1.rank + 1;
      goto cx trace ~use_op root_node1 root_node2
    )

  (** Resolve a type variable to a type. This involves finding its root, and
    resolving to that type. *)
  and resolve_id cx trace ~use_op id t =
    let (id, _, root) = Context.find_root cx id in
    match root.constraints with
    | Unresolved bounds ->
      root.constraints <- Resolved t;
      edges_and_flows_to_t cx trace ~opt:true (id, bounds) (UseT (use_op, t));
      edges_and_flows_from_t cx trace ~new_use_op:use_op ~opt:true t (id, bounds)
    | Resolved t_ -> rec_unify cx trace ~use_op t_ t
    | FullyResolved s -> rec_unify cx trace ~use_op (Context.force_fully_resolved_tvar cx s) t

  (******************)

  (* Unification of two types *)

  (* It is potentially dangerous to unify a type variable to a type that "forgets"
     constraints during propagation. These types are "any-like": the canonical
     example of such a type is any. Overall, we want unification to be a sound
     "optimization," in the sense that replacing bidirectional flows with
     unification should not miss errors. But consider a scenario where we have a
     type variable with two incoming flows, string and any, and two outgoing
     flows, number and any. If we replace the flows from/to any with an
     unification with any, we will miss the string/number incompatibility error.

     However, unifying with any-like types is sometimes desirable /
     intentional.
  *)
  and ok_unify ~unify_any = function
    | AnyT _ -> unify_any
    | _ -> true

  and __unify cx ~use_op ~unify_any t1 t2 trace =
    print_unify_types_if_verbose cx trace (t1, t2);
    (* If the type is the same type or we have already seen this type pair in our
     * cache then do not continue. *)
    if t1 = t2 then
      ()
    else (
      (* limit recursion depth *)
      RecursionCheck.check cx trace;

      match (t1, t2) with
      | (OpenT (_, id1), OpenT (_, id2)) -> merge_ids cx trace ~use_op id1 id2
      | (OpenT (_, id), t) when ok_unify ~unify_any t -> resolve_id cx trace ~use_op id t
      | (t, OpenT (_, id)) when ok_unify ~unify_any t ->
        resolve_id cx trace ~use_op:(unify_flip use_op) id t
      | (DefT (_, PolyT { id = id1; _ }), DefT (_, PolyT { id = id2; _ })) when id1 = id2 -> ()
      | ( DefT (_, ArrT (ArrayAT { elem_t = t1; tuple_view = tv1; react_dro = _ })),
          DefT (_, ArrT (ArrayAT { elem_t = t2; tuple_view = tv2; react_dro = _ }))
        ) ->
        let ts1 =
          Base.Option.value_map
            ~default:[]
            ~f:(fun (TupleView { elements; arity = _; inexact = _ }) ->
              tuple_ts_of_elements elements)
            tv1
        in
        let ts2 =
          Base.Option.value_map
            ~default:[]
            ~f:(fun (TupleView { elements; arity = _; inexact = _ }) ->
              tuple_ts_of_elements elements)
            tv2
        in
        array_unify cx trace ~use_op (ts1, t1, ts2, t2)
      | ( DefT
            ( r1,
              ArrT
                (TupleAT
                  {
                    elem_t = _;
                    elements = elements1;
                    arity = lower_arity;
                    inexact = lower_inexact;
                    react_dro = _;
                  }
                  )
            ),
          DefT
            ( r2,
              ArrT
                (TupleAT
                  {
                    elem_t = _;
                    elements = elements2;
                    arity = upper_arity;
                    inexact = upper_inexact;
                    react_dro = _;
                  }
                  )
            )
        ) ->
        let (num_req1, num_total1) = lower_arity in
        let (num_req2, num_total2) = upper_arity in
        if lower_inexact <> upper_inexact || num_req1 <> num_req2 || num_total1 <> num_total2 then
          add_output
            cx
            (Error_message.ETupleArityMismatch
               {
                 use_op;
                 lower_reason = r1;
                 lower_arity;
                 lower_inexact;
                 upper_reason = r2;
                 upper_arity;
                 upper_inexact;
                 unify = true;
               }
            );
        let n = ref 0 in
        iter2opt
          (fun t1 t2 ->
            match (t1, t2) with
            | ( Some (TupleElement { t = t1; polarity = p1; name = _; optional = _; reason = _ }),
                Some (TupleElement { t = t2; polarity = p2; name = _; optional = _; reason = _ })
              ) ->
              if not @@ Polarity.equal (p1, p2) then
                add_output
                  cx
                  (Error_message.ETupleElementPolarityMismatch
                     {
                       index = !n;
                       reason_lower = r1;
                       polarity_lower = p1;
                       reason_upper = r2;
                       polarity_upper = p2;
                       use_op;
                     }
                  );
              rec_unify cx trace ~use_op t1 t2;
              n := !n + 1
            | _ -> ())
          (elements1, elements2)
      | ( DefT (lreason, ObjT { props_tmap = lflds; flags = lflags; _ }),
          DefT (ureason, ObjT { props_tmap = uflds; flags = uflags; _ })
        ) ->
        if
          (not (Obj_type.is_exact lflags.obj_kind))
          && (not (is_literal_object_reason ureason))
          && Obj_type.is_exact uflags.obj_kind
        then
          exact_obj_error cx lflags.obj_kind ~use_op ~exact_reason:ureason t1;
        if
          (not (Obj_type.is_exact uflags.obj_kind))
          && (not (is_literal_object_reason lreason))
          && Obj_type.is_exact lflags.obj_kind
        then
          exact_obj_error cx uflags.obj_kind ~use_op ~exact_reason:lreason t2;
        (* ensure the keys and values are compatible with each other. *)
        let ldict = Obj_type.get_dict_opt lflags.obj_kind in
        let udict = Obj_type.get_dict_opt uflags.obj_kind in
        begin
          match (ldict, udict) with
          | (Some { key = lk; value = lv; _ }, Some { key = uk; value = uv; _ }) ->
            rec_unify
              cx
              trace
              lk
              uk
              ~use_op:(Frame (IndexerKeyCompatibility { lower = lreason; upper = ureason }, use_op));
            rec_unify
              cx
              trace
              lv
              uv
              ~use_op:
                (Frame
                   (PropertyCompatibility { prop = None; lower = lreason; upper = ureason }, use_op)
                )
          | (Some _, None) ->
            let use_op =
              Frame (PropertyCompatibility { prop = None; lower = ureason; upper = lreason }, use_op)
            in
            let lreason = replace_desc_reason RSomeProperty lreason in
            let err =
              Error_message.EPropNotFound
                {
                  prop_name = None;
                  reason_prop = lreason;
                  reason_obj = ureason;
                  use_op;
                  suggestion = None;
                }
            in
            add_output cx err
          | (None, Some _) ->
            let use_op =
              Frame
                ( PropertyCompatibility { prop = None; lower = lreason; upper = ureason },
                  Frame (UnifyFlip, use_op)
                )
            in
            let ureason = replace_desc_reason RSomeProperty ureason in
            let err =
              Error_message.EPropNotFound
                {
                  prop_name = None;
                  reason_prop = lreason;
                  reason_obj = ureason;
                  use_op;
                  suggestion = None;
                }
            in
            add_output cx err
          | (None, None) -> ()
        end;

        let lpmap = Context.find_props cx lflds in
        let upmap = Context.find_props cx uflds in
        NameUtils.Map.merge
          (fun x lp up ->
            ( if not (is_internal_name x || is_dictionary_exempt x) then
              match (lp, up) with
              | (Some p1, Some p2) -> unify_props cx trace ~use_op x lreason ureason p1 p2
              | (Some p1, None) -> unify_prop_with_dict cx trace ~use_op x p1 lreason ureason udict
              | (None, Some p2) -> unify_prop_with_dict cx trace ~use_op x p2 ureason lreason ldict
              | (None, None) -> ()
            );
            None)
          lpmap
          upmap
        |> ignore
      | ( DefT (_, FunT (_, ({ type_guard = None; _ } as funtype1))),
          DefT (_, FunT (_, ({ type_guard = None; _ } as funtype2)))
        )
        when List.length funtype1.params = List.length funtype2.params ->
        rec_unify
          cx
          trace
          ~use_op
          (subtype_this_of_function funtype1)
          (subtype_this_of_function funtype2);
        List.iter2
          (fun (_, t1) (_, t2) -> rec_unify cx trace ~use_op t1 t2)
          funtype1.params
          funtype2.params;
        rec_unify cx trace ~use_op funtype1.return_t funtype2.return_t
      | ( TypeAppT
            { reason = _; use_op = _; type_ = c1; targs = ts1; from_value = fv1; use_desc = _ },
          TypeAppT
            { reason = _; use_op = _; type_ = c2; targs = ts2; from_value = fv2; use_desc = _ }
        )
        when c1 = c2 && List.length ts1 = List.length ts2 && fv1 = fv2 ->
        List.iter2 (rec_unify cx trace ~use_op) ts1 ts2
      | (AnnotT (_, OpenT (_, id1), _), AnnotT (_, OpenT (_, id2), _)) -> begin
        (* It is tempting to unify the tvars here, but that would be problematic. These tvars should
           eventually resolve to the type definitions that these annotations reference. By unifying
           them, we might accidentally resolve one of the tvars to the type definition of the other,
           which would lead to confusing behavior.

           On the other hand, if the tvars are already resolved, then we can do something
           interesting... *)
        match (Context.find_graph cx id1, Context.find_graph cx id2) with
        | (Resolved t1, Resolved t2)
          when Reason.concretize_equal (Context.aloc_tables cx) (reason_of_t t1) (reason_of_t t2) ->
          naive_unify cx trace ~use_op t1 t2
        | (Resolved t1, FullyResolved s2)
          when let t2 = Context.force_fully_resolved_tvar cx s2 in
               Reason.concretize_equal (Context.aloc_tables cx) (reason_of_t t1) (reason_of_t t2) ->
          naive_unify cx trace ~use_op t1 t2
        | (FullyResolved s1, Resolved t2)
          when let t1 = Context.force_fully_resolved_tvar cx s1 in
               Reason.concretize_equal (Context.aloc_tables cx) (reason_of_t t1) (reason_of_t t2) ->
          naive_unify cx trace ~use_op t1 t2
        | (FullyResolved s1, FullyResolved s2)
        (* Can we unify these types? Tempting, again, but annotations can refer to recursive type
           definitions, and we might get into an infinite loop (which could perhaps be avoided by
           a unification cache, but we'd rather not cache if we can get away with it).

           The alternative is to do naive unification, but we must be careful. In particular, it
           could cause confusing errors: recall that the naive unification of annotations goes
           through repositioning over these types.

           But if we simulate the same repositioning here, we won't really save anything. For
           example, these types could be essentially the same union, and repositioning them would
           introduce differences in their representations that would kill other
           optimizations. Thus, we focus on the special case where these types have the same
           reason, and then do naive unification. *)
          when let t1 = Context.force_fully_resolved_tvar cx s1 in
               let t2 = Context.force_fully_resolved_tvar cx s2 in
               Reason.concretize_equal (Context.aloc_tables cx) (reason_of_t t1) (reason_of_t t2) ->
          naive_unify cx trace ~use_op t1 t2
        | _ -> naive_unify cx trace ~use_op t1 t2
      end
      | _ -> naive_unify cx trace ~use_op t1 t2
    )

  and unify_props cx trace ~use_op x r1 r2 p1 p2 =
    let use_op = Frame (PropertyCompatibility { prop = Some x; lower = r1; upper = r2 }, use_op) in
    (* If both sides are neutral fields, we can just unify once *)
    match (p1, p2) with
    | ( Field { type_ = t1; polarity = Polarity.Neutral; _ },
        Field { type_ = t2; polarity = Polarity.Neutral; _ }
      ) ->
      rec_unify cx trace ~use_op t1 t2
    | _ ->
      (* Otherwise, unify read/write sides separately. *)
      (match (Property.read_t p1, Property.read_t p2) with
      | (Some t1, Some t2) -> rec_unify cx trace ~use_op t1 t2
      | _ -> ());
      (match (Property.write_t p1, Property.write_t p2) with
      | (Some t1, Some t2) -> rec_unify cx trace ~use_op t1 t2
      | _ -> ());

      (* Error if polarity is not compatible both ways. *)
      let polarity1 = Property.polarity p1 in
      let polarity2 = Property.polarity p2 in
      if not (Polarity.equal (polarity1, polarity2)) then
        add_output
          cx
          (Error_message.EPropPolarityMismatch
             {
               lreason = r1;
               ureason = r2;
               props = Nel.one (Some x, (polarity1, polarity2));
               use_op;
             }
          )

  (* If some property `x` exists in one object but not another, ensure the
     property is compatible with a dictionary, or error if none. *)
  and unify_prop_with_dict cx trace ~use_op x p prop_obj_reason dict_reason dict =
    (* prop_obj_reason: reason of the object containing the prop
       dict_reason: reason of the object potentially containing a dictionary
       prop_reason: reason of the prop itself *)
    let prop_reason = replace_desc_reason (RProperty (Some x)) prop_obj_reason in
    match dict with
    | Some { key; value; dict_polarity; _ } ->
      rec_flow
        cx
        trace
        ( string_key x prop_reason,
          UseT
            ( Frame
                (IndexerKeyCompatibility { lower = dict_reason; upper = prop_obj_reason }, use_op),
              key
            )
        );
      let p2 =
        Field { preferred_def_locs = None; key_loc = None; type_ = value; polarity = dict_polarity }
      in
      unify_props cx trace ~use_op x prop_obj_reason dict_reason p p2
    | None ->
      let use_op =
        Frame
          ( PropertyCompatibility { prop = Some x; lower = dict_reason; upper = prop_obj_reason },
            use_op
          )
      in
      let err =
        Error_message.EPropNotFound
          {
            prop_name = Some x;
            reason_prop = prop_reason;
            reason_obj = dict_reason;
            use_op;
            suggestion = None;
          }
      in
      add_output cx err

  (* TODO: Unification between concrete types is still implemented as
     bidirectional flows. This means that the destructuring work is duplicated,
     and we're missing some opportunities for nested unification. *)
  and naive_unify cx trace ~use_op t1 t2 =
    rec_flow_t cx trace ~use_op (t1, t2);
    rec_flow_t cx trace ~use_op:(unify_flip use_op) (t2, t1)

  (* TODO: either ensure that array_unify is the same as array_flow both ways, or
     document why not. *)
  (* array helper *)
  and array_unify cx trace ~use_op = function
    | ([], e1, [], e2) ->
      (* general element1 = general element2 *)
      rec_unify cx trace ~use_op e1 e2
    | (ts1, _, [], e2)
    | ([], e2, ts1, _) ->
      (* specific element1 = general element2 *)
      List.iter (fun t1 -> rec_unify cx trace ~use_op t1 e2) ts1
    | (t1 :: ts1, e1, t2 :: ts2, e2) ->
      (* specific element1 = specific element2 *)
      rec_unify cx trace ~use_op t1 t2;
      array_unify cx trace ~use_op (ts1, e1, ts2, e2)

  (*******************************************************************)
  (* subtyping a sequence of arguments with a sequence of parameters *)
  (*******************************************************************)

  (* Process spread arguments and then apply the arguments to the parameters *)
  and multiflow_call cx trace ~use_op reason_op args ft =
    let resolve_to = ResolveSpreadsToMultiflowCallFull (mk_id (), ft) in
    resolve_call_list cx ~trace ~use_op reason_op args resolve_to

  (* Process spread arguments and then apply the arguments to the parameters *)
  and multiflow_subtype cx trace ~use_op reason_op args ft =
    let resolve_to = ResolveSpreadsToMultiflowSubtypeFull (mk_id (), ft) in
    resolve_call_list cx ~trace ~use_op reason_op args resolve_to

  (* Like multiflow_partial, but if there is no spread argument, it flows VoidT to
   * all unused parameters *)
  and multiflow_full
      cx ~trace ~use_op reason_op ~is_strict ~def_reason ~spread_arg ~rest_param (arglist, parlist)
      =
    let (unused_parameters, _) =
      multiflow_partial
        cx
        ~trace
        ~use_op
        reason_op
        ~is_strict
        ~def_reason
        ~spread_arg
        ~rest_param
        (arglist, parlist)
    in
    let _ =
      List.fold_left
        (fun n (_, param) ->
          let use_op = Frame (FunMissingArg { n; op = reason_op; def = def_reason }, use_op) in
          rec_flow cx trace (VoidT.why reason_op, UseT (use_op, param));
          n + 1)
        (List.length parlist - List.length unused_parameters + 1)
        unused_parameters
    in
    ()

  (* This is a tricky function. The simple description is that it flows all the
   * arguments to all the parameters. This function is used by
   * Function.prototype.apply, so after the arguments are applied, it returns the
   * unused parameters.
   *
   * It is a little trickier in that there may be a single spread argument after
   * all the regular arguments. There may also be a rest parameter.
   *)
  and multiflow_partial =
    let rec multiflow_non_spreads cx ~use_op n (arglist, parlist) =
      match (arglist, parlist) with
      (* Do not complain on too many arguments.
         This pattern is ubiqutous and causes a lot of noise when complained about.
         Note: optional/rest parameters do not provide a workaround in this case.
      *)
      | (_, [])
      (* No more arguments *)
      | ([], _) ->
        ([], arglist, parlist)
      | ((tin, _) :: tins, (name, tout) :: touts) ->
        (* flow `tin` (argument) to `tout` (param). *)
        let tout =
          let use_op =
            Frame (FunParam { n; name; lower = reason_of_t tin; upper = reason_of_t tout }, use_op)
          in
          UseT (use_op, tout)
        in

        let (used_pairs, unused_arglist, unused_parlist) =
          multiflow_non_spreads cx ~use_op (n + 1) (tins, touts)
        in
        (* We additionally record the type of the arg ~> parameter at the location of the parameter
         * to power autofixes for missing parameter annotations *)
        let par_def_loc =
          let reason = reason_of_use_t tout in
          def_loc_of_reason reason
        in
        Context.add_missing_local_annot_lower_bound cx par_def_loc tin;
        ((tin, tout) :: used_pairs, unused_arglist, unused_parlist)
    in
    fun cx ~trace ~use_op ~is_strict ~def_reason ~spread_arg ~rest_param reason_op (arglist, parlist)
        ->
      (* Handle all the non-spread arguments and all the non-rest parameters *)
      let (used_pairs, unused_arglist, unused_parlist) =
        multiflow_non_spreads cx ~use_op 1 (arglist, parlist)
      in
      (* If there is a spread argument, it will consume all the unused parameters *)
      let (used_pairs, unused_parlist) =
        match spread_arg with
        | None -> (used_pairs, unused_parlist)
        | Some (reason, arrtype, _) ->
          let spread_arg_elemt = elemt_of_arrtype arrtype in
          (* The spread argument may be an empty array and to be 100% correct, we
           * should flow VoidT to every remaining parameter, however we don't. This
           * is consistent with how we treat arrays almost everywhere else *)
          ( used_pairs
            @ Base.List.map
                ~f:(fun (_, param) ->
                  let use_op =
                    Frame (FunRestParam { lower = reason; upper = reason_of_t param }, use_op)
                  in
                  (spread_arg_elemt, UseT (use_op, param)))
                unused_parlist,
            []
          )
      in
      (* If there is a rest parameter, it will consume all the unused arguments *)
      match rest_param with
      | None ->
        ( if is_strict then
          match unused_arglist with
          | [] -> ()
          | (first_unused_arg, _) :: _ ->
            Error_message.EFunctionCallExtraArg
              ( mk_reason RFunctionUnusedArgument (loc_of_t first_unused_arg),
                def_reason,
                List.length parlist,
                use_op
              )
            |> add_output cx
        );

        (* Flow the args and params after we add the EFunctionCallExtraArg error.
         * This improves speculation error reporting. *)
        List.iter (rec_flow cx trace) used_pairs;

        (unused_parlist, rest_param)
      | Some (name, loc, rest_param) ->
        List.iter (rec_flow cx trace) used_pairs;
        let rest_reason = reason_of_t rest_param in
        let orig_rest_reason = repos_reason loc rest_reason in
        (* We're going to build an array literal with all the unused arguments
         * (and the spread argument if it exists). Then we're going to flow that
         * to the rest parameter *)
        let rev_elems =
          List.rev_map
            (fun (arg, generic) ->
              let reason = mk_reason RArrayElement (loc_of_t arg) in
              UnresolvedArg (mk_tuple_element reason arg, generic))
            unused_arglist
        in
        let unused_rest_param =
          match spread_arg with
          | None ->
            (* If the rest parameter is consuming N elements, then drop N elements
             * from the rest parameter *)
            Tvar.mk_where cx rest_reason (fun tout ->
                let i = List.length rev_elems in
                rec_flow cx trace (rest_param, ArrRestT (use_op, orig_rest_reason, i, tout))
            )
          | Some _ ->
            (* If there is a spread argument, then a tuple rest parameter will error
             * anyway. So let's assume that the rest param is an array with unknown
             * arity. Dropping elements from it isn't worth doing *)
            rest_param
        in
        let elems =
          match spread_arg with
          | None -> List.rev rev_elems
          | Some (reason, arrtype, generic) ->
            let spread_array = DefT (reason, ArrT arrtype) in
            let spread_array =
              Base.Option.value_map
                ~f:(fun id ->
                  GenericT
                    {
                      id;
                      bound = spread_array;
                      reason;
                      name = Generic.subst_name_of_id id;
                      no_infer = false;
                    })
                ~default:spread_array
                generic
            in
            List.rev_append rev_elems [UnresolvedSpreadArg spread_array]
        in
        let arg_array_reason =
          replace_desc_reason (RRestArrayLit (desc_of_reason reason_op)) reason_op
        in
        let arg_array =
          Tvar.mk_where cx arg_array_reason (fun tout ->
              let reason_op = arg_array_reason in
              let element_reason =
                let instantiable = Reason.is_instantiable_reason rest_reason in
                replace_desc_reason
                  (Reason.RInferredUnionElemArray { instantiable; is_empty = List.is_empty elems })
                  reason_op
              in
              let elem_t = Tvar.mk cx element_reason in
              ResolveSpreadsToArrayLiteral { id = mk_id (); as_const = false; elem_t; tout }
              |> resolve_spread_list cx ~use_op ~reason_op elems
          )
        in
        let () =
          let use_op =
            Frame
              ( FunRestParam { lower = reason_of_t arg_array; upper = reason_of_t rest_param },
                use_op
              )
          in
          rec_flow cx trace (arg_array, UseT (use_op, rest_param))
        in
        (unused_parlist, Some (name, loc, unused_rest_param))

  and resolve_call_list cx ~trace ~use_op reason_op args resolve_to =
    let unresolved =
      Base.List.map
        ~f:(function
          | Arg t ->
            let reason = mk_reason RArrayElement (loc_of_t t) in
            UnresolvedArg (mk_tuple_element reason t, None)
          | SpreadArg t -> UnresolvedSpreadArg t)
        args
    in
    resolve_spread_list_rec cx ~trace ~use_op ~reason_op ([], unresolved) resolve_to

  and resolve_spread_list cx ~use_op ~reason_op list resolve_to =
    resolve_spread_list_rec cx ~use_op ~reason_op ([], list) resolve_to

  (* This function goes through the unresolved elements to find the next rest
   * element to resolve *)
  and resolve_spread_list_rec cx ?trace ~use_op ~reason_op (resolved_rev, unresolved) resolve_to =
    match (resolved_rev, unresolved) with
    | (resolved_rev, []) ->
      finish_resolve_spread_list cx ?trace ~use_op ~reason_op (List.rev resolved_rev) resolve_to
    | (resolved_rev, UnresolvedArg (next, generic) :: unresolved) ->
      resolve_spread_list_rec
        cx
        ?trace
        ~use_op
        ~reason_op
        (ResolvedArg (next, generic) :: resolved_rev, unresolved)
        resolve_to
    | (resolved_rev, UnresolvedSpreadArg next :: unresolved) ->
      flow_opt
        cx
        ?trace
        ( next,
          ResolveSpreadT
            ( use_op,
              reason_op,
              {
                rrt_resolved = resolved_rev;
                rrt_unresolved = unresolved;
                rrt_resolve_to = resolve_to;
              }
            )
        )

  (* Now that everything is resolved, we can construct whatever type we're trying
   * to resolve to. *)
  and finish_resolve_spread_list =
    let propagate_dro cx elem arrtype =
      match arrtype with
      | ROArrayAT (_, Some l)
      | ArrayAT { react_dro = Some l; _ }
      | TupleAT { react_dro = Some l; _ } ->
        mk_react_dro cx unknown_use l elem
      | _ -> elem
    in

    (* Turn tuple rest params into single params *)
    let flatten_spread_args cx args =
      let (args_rev, spread_after_opt, _, inexact_spread) =
        Base.List.fold_left args ~init:([], false, false, false) ~f:(fun acc arg ->
            let (args_rev, spread_after_opt, seen_opt, inexact_spread) = acc in
            ( if inexact_spread then
              (* We have an element after an inexact spread *)
              let reason = reason_of_resolved_param arg in
              add_output cx (Error_message.ETupleElementAfterInexactSpread reason)
            );
            match arg with
            | ResolvedSpreadArg (_, arrtype, generic) -> begin
              let spread_after_opt = spread_after_opt || seen_opt in
              let (args_rev, seen_opt, inexact_spread) =
                match arrtype with
                | ArrayAT { tuple_view = None; _ } -> (arg :: args_rev, seen_opt, inexact_spread)
                | ArrayAT { tuple_view = Some (TupleView { elements = []; inexact; _ }); _ }
                | TupleAT { elements = []; inexact; _ } ->
                  (* The latter two cases corresponds to the empty array. If
                   * we folded over the empty elements list, then this would
                   * cause an empty result. *)
                  (arg :: args_rev, seen_opt, inexact_spread || inexact)
                | ArrayAT { tuple_view = Some (TupleView { elements; inexact; _ }); _ }
                | TupleAT { elements; inexact; _ } ->
                  let (args_rev, seen_opt) =
                    Base.List.fold_left
                      ~f:(fun (args_rev, seen_opt) (TupleElement ({ optional; t; _ } as elem)) ->
                        let elem = TupleElement { elem with t = propagate_dro cx t arrtype } in
                        (ResolvedArg (elem, generic) :: args_rev, seen_opt || optional))
                      ~init:(args_rev, seen_opt)
                      elements
                  in
                  (args_rev, seen_opt, inexact_spread || inexact)
                | ROArrayAT _ -> (arg :: args_rev, seen_opt, inexact_spread)
              in
              (args_rev, spread_after_opt, seen_opt, inexact_spread)
            end
            | ResolvedAnySpreadArg _ -> (arg :: args_rev, spread_after_opt, seen_opt, inexact_spread)
            | ResolvedArg (TupleElement { optional; _ }, _) ->
              (arg :: args_rev, spread_after_opt, seen_opt || optional, inexact_spread)
        )
      in
      (List.rev args_rev, spread_after_opt, inexact_spread)
    in
    let spread_resolved_to_any_src =
      List.find_map (function
          | ResolvedAnySpreadArg (_, src) -> Some src
          | ResolvedArg _
          | ResolvedSpreadArg _ ->
            None
          )
    in
    let finish_array cx ~use_op ?trace ~reason_op ~resolve_to resolved elem_t tout =
      (* Did `any` flow to one of the rest parameters? If so, we need to resolve
       * to a type that is both a subtype and supertype of the desired type. *)
      let result =
        match spread_resolved_to_any_src resolved with
        | Some any_src ->
          (match resolve_to with
          (* Array<any> is a good enough any type for arrays *)
          | ResolveToArray ->
            DefT
              ( reason_op,
                ArrT
                  (ArrayAT
                     { elem_t = AnyT.why any_src reason_op; tuple_view = None; react_dro = None }
                  )
              )
          (* Array literals can flow to a tuple. Arrays can't. So if the presence
           * of an `any` forces us to degrade an array literal to Array<any> then
           * we might get a new error. Since introducing `any`'s shouldn't cause
           * errors, this is bad. Instead, let's degrade array literals to `any` *)
          | ResolveToArrayLiteral { as_const = _ }
          (* There is no AnyTupleT type, so let's degrade to `any`. *)
          | ResolveToTupleType _ ->
            AnyT.why any_src reason_op)
        | None ->
          (* Spreads that resolve to tuples are flattened *)
          let (elems, spread_after_opt, inexact_spread) = flatten_spread_args cx resolved in
          let as_const =
            match resolve_to with
            | ResolveToArrayLiteral { as_const } -> as_const
            | ResolveToTupleType _
            | ResolveToArray ->
              false
          in
          let tuple_elements =
            match resolve_to with
            | ResolveToArrayLiteral _
            | ResolveToTupleType _ ->
              elems
              (* If no spreads are left, then this is a tuple too! *)
              |> List.fold_left
                   (fun acc elem ->
                     match (acc, elem) with
                     | (None, _) -> None
                     | ( Some _,
                         ResolvedSpreadArg
                           ( _,
                             ( ArrayAT { tuple_view = Some (TupleView { elements = []; _ }); _ }
                             | TupleAT { elements = []; _ } ),
                             _
                           )
                       ) ->
                       (* Spread of empty array/tuple results in same tuple elements as before. *)
                       acc
                     | (_, ResolvedSpreadArg _) -> None
                     | (Some tuple_elements, ResolvedArg (elem, _)) ->
                       (* Spreading array values into a fresh literal drops variance,
                        * just like object spread. *)
                       let elem =
                         let (TupleElement { t; optional; name; reason; polarity = _ }) = elem in
                         let polarity =
                           if as_const then
                             Polarity.Positive
                           else
                             Polarity.Neutral
                         in
                         TupleElement { t; optional; name; reason; polarity }
                       in
                       Some (elem :: tuple_elements)
                     | (_, ResolvedAnySpreadArg _) -> failwith "Should not be hit")
                   (Some [])
              |> Base.Option.map ~f:List.rev
            | ResolveToArray -> None
          in

          (* We infer the array's general element type by looking at the type of
           * every element in the array *)
          let (tset, generic) =
            Generic.(
              List.fold_left
                (fun (tset, generic_state) elem ->
                  let (elem_t, generic, ro) =
                    match elem with
                    | ResolvedSpreadArg (_, arrtype, generic) ->
                      ( propagate_dro cx (elemt_of_arrtype arrtype) arrtype,
                        generic,
                        ro_of_arrtype arrtype
                      )
                    | ResolvedArg (TupleElement { t = elem_t; _ }, generic) ->
                      (elem_t, generic, ArraySpread.NonROSpread)
                    | ResolvedAnySpreadArg _ -> failwith "Should not be hit"
                  in
                  ( TypeExSet.add elem_t tset,
                    ArraySpread.merge
                      ~printer:
                        (print_if_verbose_lazy
                           cx
                           ~trace:(Base.Option.value trace ~default:DepthTrace.dummy_trace)
                        )
                      generic_state
                      generic
                      ro
                  ))
                (TypeExSet.empty, ArraySpread.Bottom)
                elems
            )
          in
          let generic = Generic.ArraySpread.to_option generic in

          (* composite elem type is an upper bound of all element types *)
          (* Should the element type of the array be the union of its element types?

             No. Instead of using a union, we use an unresolved tvar to
             represent the least upper bound of each element type. Effectively,
             this keeps the element type "open," at least locally.[*]

             Using a union pins down the element type prematurely, and moreover,
             might lead to speculative matching when setting elements or caling
             contravariant methods (`push`, `concat`, etc.) on the array.

             In any case, using a union doesn't quite work as intended today
             when the element types themselves could be unresolved tvars. For
             example, the following code would work even with unions:

             declare var o: { x: number; }
             var a = ["hey", o.x]; // no error, but is an error if 42 replaces o.x
             declare var i: number;
             a[i] = false;

             [*] Eventually, the element type does get pinned down to a union
             when the type of the expression is resolved. In the future we might
             have to do that pinning more carefully, and using an unresolved
             tvar instead of a union here doesn't conflict with those plans.
          *)
          if inexact_spread then
            let reason_mixed = replace_desc_reason RTupleUnknownElementFromInexact reason_op in
            let t = MixedT.make reason_mixed in
            flow cx (t, UseT (use_op, elem_t))
          else
            TypeExSet.elements tset |> List.iter (fun t -> flow cx (t, UseT (use_op, elem_t)));

          let create_tuple_type ~inexact elements =
            let (valid, arity) =
              validate_tuple_elements
                cx
                ~reason_tuple:reason_op
                ~error_on_req_after_opt:true
                elements
            in
            let inexact = inexact || inexact_spread in
            if valid then
              DefT (reason_op, ArrT (TupleAT { elem_t; elements; arity; inexact; react_dro = None }))
            else
              AnyT.error reason_op
          in

          let t =
            match (resolve_to, tuple_elements, spread_after_opt) with
            | (ResolveToArray, _, _)
            | (ResolveToArrayLiteral _, None, _)
            | (ResolveToArrayLiteral _, _, true) ->
              let arrtype =
                if as_const then
                  ROArrayAT (elem_t, None)
                else
                  ArrayAT { elem_t; tuple_view = None; react_dro = None }
              in
              DefT (reason_op, ArrT arrtype)
            | (ResolveToArrayLiteral { as_const = false }, Some elements, _) ->
              let (valid, arity) =
                validate_tuple_elements
                  cx
                  ~reason_tuple:reason_op
                  ~error_on_req_after_opt:false
                  elements
              in
              if valid then
                DefT
                  ( reason_op,
                    ArrT
                      (ArrayAT
                         {
                           elem_t;
                           tuple_view =
                             Some (TupleView { elements; arity; inexact = inexact_spread });
                           react_dro = None;
                         }
                      )
                  )
              else
                DefT (reason_op, ArrT (ArrayAT { elem_t; tuple_view = None; react_dro = None }))
            | (ResolveToTupleType { inexact }, Some elements, _) ->
              create_tuple_type ~inexact elements
            | (ResolveToArrayLiteral { as_const = true }, Some elements, _) ->
              create_tuple_type ~inexact:false elements
            | (ResolveToTupleType _, None, _) -> AnyT.error reason_op
          in
          Base.Option.value_map
            ~f:(fun id ->
              GenericT
                {
                  bound = t;
                  id;
                  name = Generic.subst_name_of_id id;
                  reason = reason_of_t t;
                  no_infer = false;
                })
            ~default:t
            generic
      in
      flow_opt_t cx ~use_op ?trace (result, tout)
    in
    (* If there are no spread elements or if all the spread elements resolved to
     * tuples or array literals, then this is easy. We just flatten them all.
     *
     * However, if we have a spread that resolved to any or to an array of
     * unknown length, then we're in trouble. Basically, any remaining argument
     * might flow to any remaining parameter.
     *)
    let flatten_call_arg =
      let rec flatten cx r args spread resolved =
        if resolved = [] then
          (args, spread)
        else
          match spread with
          | None ->
            (match resolved with
            | ResolvedArg (TupleElement { t; _ }, generic) :: rest ->
              flatten cx r ((t, generic) :: args) spread rest
            | ResolvedSpreadArg
                (_, ArrayAT { tuple_view = Some (TupleView { elements; inexact; _ }); _ }, generic)
              :: rest
            | ResolvedSpreadArg (_, TupleAT { elements; inexact; _ }, generic) :: rest ->
              let args =
                List.rev_append
                  (List.map
                     (fun (TupleElement { t; polarity = _; name = _; optional = _; reason = _ }) ->
                       (t, generic))
                     elements
                  )
                  args
              in
              if inexact then
                let spread = Some (TypeExSet.empty, None, Generic.ArraySpread.Bottom) in
                flatten cx r args spread resolved
              else
                flatten cx r args spread rest
            | ResolvedSpreadArg (r, _, _) :: _
            | ResolvedAnySpreadArg (r, _) :: _ ->
              (* We weren't able to flatten the call argument list to remove all
               * spreads. This means we need to build a spread argument, with
               * unknown arity. *)
              let spread = Some (TypeExSet.empty, None, Generic.ArraySpread.Bottom) in
              flatten cx r args spread resolved
            | [] -> failwith "Empty list already handled")
          | Some (tset, last_inexact_tuple, generic) ->
            let (tset, last_inexact_tuple, generic', ro, rest) =
              match resolved with
              | ResolvedArg (TupleElement { t; _ }, generic) :: rest ->
                let tset = TypeExSet.add t tset in
                (tset, last_inexact_tuple, generic, Generic.ArraySpread.NonROSpread, rest)
              | ResolvedSpreadArg (_, (TupleAT { inexact = true; _ } as arrtype), generic) :: []
                when TypeExSet.is_empty tset ->
                (tset, Some arrtype, generic, ro_of_arrtype arrtype, [])
              | ResolvedSpreadArg (_, arrtype, generic) :: rest ->
                let tset = TypeExSet.add (elemt_of_arrtype arrtype) tset in
                (tset, last_inexact_tuple, generic, ro_of_arrtype arrtype, rest)
              | ResolvedAnySpreadArg (reason, any_src) :: rest ->
                let tset = TypeExSet.add (AnyT.why any_src reason) tset in
                (tset, last_inexact_tuple, None, Generic.ArraySpread.NonROSpread, rest)
              | [] -> failwith "Empty list already handled"
            in
            let generic =
              Generic.ArraySpread.merge ~printer:(print_if_verbose_lazy cx) generic generic' ro
            in
            flatten cx r args (Some (tset, last_inexact_tuple, generic)) rest
      in
      fun cx ~use_op r resolved ->
        let (args, spread) = flatten cx r [] None resolved in
        let spread =
          Base.Option.map
            ~f:(fun (tset, last_inexact_tuple, generic) ->
              let generic = Generic.ArraySpread.to_option generic in
              let r = mk_reason RArray (loc_of_reason r) in
              let arrtype =
                match last_inexact_tuple with
                | Some arrtype -> arrtype
                | None ->
                  let elem_t =
                    Tvar.mk_where cx r (fun tvar ->
                        TypeExSet.iter (fun t -> flow cx (t, UseT (use_op, tvar))) tset
                    )
                  in
                  ArrayAT { elem_t; tuple_view = None; react_dro = None }
              in
              (r, arrtype, generic))
            spread
        in
        (List.rev args, spread)
    in
    (* This is used for things like Function.prototype.bind, which partially
     * apply arguments and then return the new function. *)
    let finish_multiflow_partial cx ?trace ~use_op ~reason_op ft call_reason resolved tout =
      (* Multiflows always come out of a flow *)
      let trace =
        match trace with
        | Some trace -> trace
        | None -> failwith "All multiflows show have a trace"
      in
      let { params; rest_param; return_t; def_reason; type_guard; effect_; _ } = ft in
      let (args, spread_arg) = flatten_call_arg cx ~use_op reason_op resolved in
      let (params, rest_param) =
        multiflow_partial
          cx
          ~trace
          ~use_op
          reason_op
          ~is_strict:true
          ~def_reason
          ~spread_arg
          ~rest_param
          (args, params)
      in
      let (params_names, params_tlist) = List.split params in
      (* e.g. "bound function type", positioned at reason_op *)
      let bound_reason =
        let desc = RBound (desc_of_reason reason_op) in
        replace_desc_reason desc call_reason
      in
      let def_reason = reason_op in
      let funt =
        DefT
          ( reason_op,
            FunT
              ( dummy_static bound_reason,
                mk_methodtype
                  (dummy_this (loc_of_reason reason_op))
                  params_tlist
                  return_t
                  ~type_guard
                  ~rest_param
                  ~def_reason
                  ~params_names
                  ~effect_
              )
          )
      in
      rec_flow_t cx trace ~use_op:unknown_use (funt, tout)
    in
    (* This is used for things like function application, where all the arguments
     * are applied to a function *)
    let finish_multiflow_full cx ?trace ~use_op ~reason_op ~is_strict ft resolved =
      (* Multiflows always come out of a flow *)
      let trace =
        match trace with
        | Some trace -> trace
        | None -> failwith "All multiflows show have a trace"
      in
      let { params; rest_param; def_reason; _ } = ft in
      let (args, spread_arg) = flatten_call_arg cx ~use_op reason_op resolved in
      multiflow_full
        cx
        ~trace
        ~use_op
        reason_op
        ~is_strict
        ~def_reason
        ~spread_arg
        ~rest_param
        (args, params)
    in
    fun cx ?trace ~use_op ~reason_op resolved resolve_to ->
      match resolve_to with
      | ResolveSpreadsToTupleType { id = _; inexact; elem_t; tout } ->
        finish_array
          cx
          ~use_op
          ?trace
          ~reason_op
          ~resolve_to:(ResolveToTupleType { inexact })
          resolved
          elem_t
          tout
      | ResolveSpreadsToArrayLiteral { as_const; elem_t; tout; _ } ->
        finish_array
          cx
          ~use_op
          ?trace
          ~reason_op
          ~resolve_to:(ResolveToArrayLiteral { as_const })
          resolved
          elem_t
          tout
      | ResolveSpreadsToArray (elem_t, tout) ->
        finish_array cx ~use_op ?trace ~reason_op ~resolve_to:ResolveToArray resolved elem_t tout
      | ResolveSpreadsToMultiflowPartial (_, ft, call_reason, tout) ->
        finish_multiflow_partial cx ?trace ~use_op ~reason_op ft call_reason resolved tout
      | ResolveSpreadsToMultiflowCallFull (_, ft) ->
        finish_multiflow_full cx ?trace ~use_op ~reason_op ~is_strict:true ft resolved
      | ResolveSpreadsToMultiflowSubtypeFull (_, ft) ->
        finish_multiflow_full cx ?trace ~use_op ~reason_op ~is_strict:false ft resolved

  and apply_method_action cx trace l use_op reason_call this_arg action =
    match action with
    | CallM { methodcalltype = app; return_hint; specialized_callee } ->
      let u =
        CallT
          {
            use_op;
            reason = reason_call;
            call_action = Funcalltype (call_of_method_app this_arg specialized_callee app);
            return_hint;
          }
      in
      rec_flow cx trace (l, u)
    | ChainM
        {
          exp_reason;
          lhs_reason;
          methodcalltype = app;
          voided_out = vs;
          return_hint;
          specialized_callee;
        } ->
      let u =
        OptionalChainT
          {
            reason = exp_reason;
            lhs_reason;
            t_out =
              CallT
                {
                  use_op;
                  reason = reason_call;
                  call_action = Funcalltype (call_of_method_app this_arg specialized_callee app);
                  return_hint;
                };
            voided_out = vs;
          }
      in
      rec_flow cx trace (l, u)
    | NoMethodAction prop_t -> rec_flow_t cx trace ~use_op:unknown_use (l, prop_t)

  and perform_elem_action cx trace ~use_op ~restrict_deletes reason_op l value action =
    match (action, restrict_deletes) with
    | (ReadElem { tout; _ }, _) ->
      let loc = loc_of_reason reason_op in
      rec_flow_t cx trace ~use_op:unknown_use (reposition cx ~trace loc value, OpenT tout)
    | (WriteElem { tin; tout; mode = Assign }, _)
    | (WriteElem { tin; tout; mode = Delete }, true) ->
      rec_flow cx trace (tin, UseT (use_op, value));
      Base.Option.iter ~f:(fun t -> rec_flow_t cx trace ~use_op:unknown_use (l, t)) tout
    | (WriteElem { tin; tout; mode = Delete }, false) ->
      (* Ok to delete arbitrary elements on arrays, not OK for tuples *)
      rec_flow cx trace (tin, UseT (use_op, VoidT.why (reason_of_t value)));
      Base.Option.iter ~f:(fun t -> rec_flow_t cx trace ~use_op:unknown_use (l, t)) tout
    | (CallElem (reason_call, action), _) ->
      apply_method_action cx trace value use_op reason_call l action

  (* builtins, contd. *)

  and get_builtin_typeapp cx reason ?(use_desc = false) x targs =
    let t = Flow_js_utils.lookup_builtin_type cx x reason in
    typeapp ~from_value:false ~use_desc reason t targs

  and get_builtin_react_typeapp cx reason ?(use_desc = false) purpose targs =
    let t =
      Flow_js_utils.ImportExportUtils.get_implicitly_imported_react_type
        cx
        (loc_of_reason reason)
        ~singleton_concretize_type_for_imports_exports
        ~purpose
    in
    typeapp ~from_value:false ~use_desc reason t targs

  (* Specialize a polymorphic class, make an instance of the specialized class. *)
  and mk_typeapp_instance_annot
      cx ?trace ~use_op ~reason_op ~reason_tapp ~from_value ?(use_desc = false) c ts =
    let t = Tvar.mk cx reason_tapp in
    flow_opt cx ?trace (c, SpecializeT (use_op, reason_op, reason_tapp, Some ts, t));
    if from_value then
      t
    else
      mk_instance_raw cx ?trace reason_tapp ~reason_type:(reason_of_t c) ~use_desc t

  and mk_typeapp_instance cx ?trace ~use_op ~reason_op ~reason_tapp ~from_value c ts =
    let t = Tvar.mk cx reason_tapp in
    flow_opt cx ?trace (c, SpecializeT (use_op, reason_op, reason_tapp, Some ts, t));
    if from_value then
      t
    else
      mk_instance_source cx ?trace reason_tapp ~reason_type:(reason_of_t c) t

  and mk_typeapp_instance_of_poly
      cx trace ~use_op ~reason_op ~reason_tapp ~from_value id tparams_loc xs t ts =
    let t = mk_typeapp_of_poly cx trace ~use_op ~reason_op ~reason_tapp id tparams_loc xs t ts in
    if from_value then
      t
    else
      mk_instance cx ~trace reason_tapp t

  and mk_instance cx ?type_t_kind ?trace instance_reason ?use_desc c =
    mk_instance_raw cx ?type_t_kind ?trace instance_reason ?use_desc ~reason_type:instance_reason c

  and mk_instance_source cx ?(type_t_kind = InstanceKind) ?trace instance_reason ~reason_type c =
    Tvar.mk_where cx instance_reason (fun t ->
        (* this part is similar to making a runtime value *)
        flow_opt cx ?trace (c, ValueToTypeReferenceT (unknown_use, reason_type, type_t_kind, t))
    )

  and mk_instance_raw cx ?type_t_kind ?trace instance_reason ?(use_desc = false) ~reason_type c =
    (* Make an annotation. *)
    let source = mk_instance_source cx ?type_t_kind ?trace instance_reason ~reason_type c in
    AnnotT (instance_reason, source, use_desc)

  and instance_lookup_kind
      cx trace ~reason_instance ~reason_op ~method_accessible instance_t propref lookup_action =
    match propref with
    | Named { name; from_indexed_access; _ }
      when (not from_indexed_access) || is_munged_prop_name cx name ->
      Strict reason_instance
    | _ ->
      let lookup_default =
        ( instance_t,
          Tvar.mk_where cx reason_op (fun tvar ->
              rec_flow
                cx
                trace
                ( tvar,
                  LookupT
                    {
                      reason = reason_op;
                      lookup_kind = Strict reason_instance;
                      try_ts_on_failure = [];
                      propref;
                      lookup_action;
                      ids = None;
                      method_accessible;
                      ignore_dicts = false;
                    }
                )
          )
        )
      in
      NonstrictReturning (Some lookup_default, None)

  and reposition_reason cx ?trace reason ?(use_desc = false) t =
    reposition
      cx
      ?trace
      (loc_of_reason reason)
      ?desc:
        ( if use_desc then
          Some (desc_of_reason ~unwrap:false reason)
        else
          None
        )
      ?annot_loc:(annot_loc_of_reason reason)
      t

  (* set the position of the given def type from a reason *)
  and reposition cx ?trace (loc : ALoc.t) ?desc ?annot_loc t =
    let mod_reason reason =
      let reason = opt_annot_reason ?annot_loc @@ repos_reason loc reason in
      match desc with
      | Some d -> replace_desc_new_reason d reason
      | None -> reason
    in
    let rec recurse seen = function
      | OpenT (r, id) as t_open ->
        let reason = mod_reason r in
        let use_desc = Base.Option.is_some desc in
        let constraints = Context.find_graph cx id in
        begin
          match constraints with
          | Resolved t ->
            (* A tvar may be resolved to a type that has special repositioning logic,
             * like UnionT. We want to recurse to pick up that logic, but must be
             * careful as the union may refer back to the tvar itself, causing a loop.
             * To break the loop, we pass down a map of "already seen" tvars. *)
            (match IMap.find_opt id seen with
            | Some t -> t
            | None ->
              Tvar.mk_where cx reason (fun tvar ->
                  (* All `t` in `Resolved ( t)` are concrete. Because `t` is a concrete
                   * type, `t'` is also necessarily concrete (i.e., reposition preserves
                   * open -> open, concrete -> concrete). The unification below thus
                   * results in resolving `tvar` to `t'`, so we end up with a resolved
                   * tvar whenever we started with one. *)
                  let t' = recurse (IMap.add id tvar seen) t in
                  (* resolve_id requires a trace param *)
                  let use_op = unknown_use in
                  let trace =
                    match trace with
                    | None -> DepthTrace.unit_trace
                    | Some trace -> DepthTrace.rec_trace trace
                  in
                  let (_, id) = open_tvar tvar in
                  resolve_id cx trace ~use_op id t'
              ))
          | FullyResolved s ->
            (match IMap.find_opt id seen with
            | Some t -> t
            | None ->
              let t = Context.force_fully_resolved_tvar cx s in
              let rec lazy_t = lazy (Tvar.mk_fully_resolved_lazy cx reason lazy_thunk)
              and lazy_thunk =
                lazy
                  (Context.run_in_signature_tvar_env cx (fun () ->
                       recurse (IMap.add id (Lazy.force lazy_t) seen) t
                   )
                  )
              in
              ignore (Lazy.force lazy_thunk);
              let t = Lazy.force lazy_t in
              (match t with
              | OpenT (_, repositioned_tvar_id) ->
                Context.report_array_or_object_literal_declaration_reposition
                  cx
                  repositioned_tvar_id
                  id
              | _ -> ());
              t)
          | Unresolved _ ->
            if is_instantiable_reason r && Context.in_implicit_instantiation cx then
              t_open
            else
              Tvar.mk_where cx reason (fun tvar ->
                  flow_opt
                    cx
                    ?trace
                    (t_open, ReposLowerT { reason; use_desc; use_t = UseT (unknown_use, tvar) })
              )
        end
      | EvalT (root, (TypeDestructorT (_, _, d) as defer_use_t), id) as t ->
        (* Modifying the reason of `EvalT`, as we do for other types, is not
           enough, since it will only affect the reason of the resulting tvar.
           Instead, repositioning a `EvalT` should simulate repositioning the
           resulting tvar, i.e., flowing repositioned *lower bounds* to the
           resulting tvar. (Another way of thinking about this is that a `EvalT`
           is just as transparent as its resulting tvar.) *)
        let defer_use_t = mod_reason_of_defer_use_t mod_reason defer_use_t in
        let reason = reason_of_defer_use_t defer_use_t in
        let use_desc = Base.Option.is_some desc in
        begin
          let no_unresolved =
            (not (Flow_js_utils.TvarVisitors.has_unresolved_tvars cx root))
            && not (Flow_js_utils.TvarVisitors.has_unresolved_tvars_in_destructors cx d)
          in
          match Cache.Eval.find_repos cx root defer_use_t id with
          | Some tvar ->
            (match tvar with
            | OpenT (_, id)
              when no_unresolved && Base.List.is_empty (Flow_js_utils.possible_types cx id) ->
              EmptyT.why (reason_of_t tvar)
            | _ -> tvar)
          | None ->
            Tvar.mk_where cx reason (fun tvar ->
                Cache.Eval.add_repos cx root defer_use_t id tvar;
                flow_opt
                  cx
                  ?trace
                  (t, ReposLowerT { reason; use_desc; use_t = UseT (unknown_use, tvar) });
                if no_unresolved then (
                  Tvar_resolver.resolve cx t;
                  Tvar_resolver.resolve cx tvar
                )
            )
        end
      | MaybeT (r, t) ->
        (* repositions both the MaybeT and the nested type. MaybeT represets `?T`.
           elsewhere, when we decompose into T | NullT | VoidT, we use the reason
           of the MaybeT for NullT and VoidT but don't reposition `t`, so that any
           errors on the NullT or VoidT point at ?T, but errors on the T point at
           T. *)
        let r = mod_reason r in
        MaybeT (r, recurse seen t)
      | OptionalT { reason; type_ = t; use_desc } ->
        let reason = mod_reason reason in
        OptionalT { reason; type_ = recurse seen t; use_desc }
      | UnionT (r, rep) ->
        let r = mod_reason r in
        let rep = UnionRep.ident_map ~always_keep_source:true (recurse seen) rep in
        UnionT (r, rep)
      | OpaqueT (r, opaquetype) ->
        let r = mod_reason r in
        OpaqueT
          ( r,
            {
              opaquetype with
              underlying_t = OptionUtils.ident_map (recurse seen) opaquetype.underlying_t;
              lower_t = OptionUtils.ident_map (recurse seen) opaquetype.lower_t;
              upper_t = OptionUtils.ident_map (recurse seen) opaquetype.upper_t;
            }
          )
      | DefT (r, RendersT (StructuralRenders { renders_variant; renders_structural_type = t })) ->
        let r = mod_reason r in
        DefT
          ( r,
            RendersT
              (StructuralRenders { renders_variant; renders_structural_type = recurse seen t })
          )
      | t -> mod_reason_of_t mod_reason t
    in
    recurse IMap.empty t

  and get_builtin_type cx ?trace reason ?(use_desc = false) x =
    let t = Flow_js_utils.lookup_builtin_type cx x reason in
    mk_instance cx ?trace reason ~use_desc t

  and get_builtin_react_type cx ?trace reason ?(use_desc = false) purpose =
    let t =
      Flow_js_utils.ImportExportUtils.get_implicitly_imported_react_type
        cx
        (loc_of_reason reason)
        ~singleton_concretize_type_for_imports_exports
        ~purpose
    in
    mk_instance cx ?trace reason ~use_desc t

  and flow_all_in_union cx trace rep u =
    iter_union ~f:rec_flow ~init:() ~join:(fun _ _ -> ()) cx trace rep u

  and call_args_iter f =
    List.iter (function
        | Arg t
        | SpreadArg t
        -> f t
        )

  (* There's a lot of code that looks at a call argument list and tries to do
   * something with one or two arguments. Usually this code assumes that the
   * argument is not a spread argument. This utility function helps with that *)
  and extract_non_spread cx = function
    | Arg t -> t
    | SpreadArg arr ->
      let reason = reason_of_t arr in
      let loc = loc_of_t arr in
      add_output
        cx
        (Error_message.EUnsupportedSyntax (loc, Flow_intermediate_error_types.SpreadArgument));
      AnyT.error reason

  (* Wrapper functions around __flow that manage traces. Use these functions for
     all recursive calls in the implementation of __flow. *)

  (* Call __flow while concatenating traces. Typically this is used in code that
     propagates bounds across type variables, where nothing interesting is going
     on other than concatenating subtraces to make longer traces to describe
     transitive data flows *)
  and join_flow cx ts (t1, t2) = __flow cx (t1, t2) (DepthTrace.concat_trace ts)

  (* Call __flow while embedding traces. Typically this is used in code that
     simplifies a constraint to generate subconstraints: the current trace is
     "pushed" when recursing into the subconstraints, so that when we finally hit
     an error and walk back, we can know why the particular constraints that
     caused the immediate error were generated. *)
  and rec_flow cx trace (t1, t2) = __flow cx (t1, t2) (DepthTrace.rec_trace trace)

  and rec_flow_t cx trace ~use_op (t1, t2) = rec_flow cx trace (t1, UseT (use_op, t2))

  (* Ideally this function would not be required: either we call `flow` from
     outside without a trace (see below), or we call one of the functions above
     with a trace. However, there are some functions that need to call __flow,
     which are themselves called both from outside and inside (with or without
     traces), so they call this function instead. *)
  and flow_opt cx ?trace (t1, t2) =
    let trace =
      match trace with
      | None -> DepthTrace.unit_trace
      | Some trace -> DepthTrace.rec_trace trace
    in
    __flow cx (t1, t2) trace

  and flow_opt_t cx ~use_op ?trace (t1, t2) = flow_opt cx ?trace (t1, UseT (use_op, t2))

  (* Externally visible function for subtyping. *)
  (* Calls internal entry point and traps runaway recursion. *)
  and flow cx (lower, upper) =
    try flow_opt cx (lower, upper) with
    | RecursionCheck.LimitExceeded ->
      (* log and continue *)
      let rl = reason_of_t lower in
      let ru = reason_of_use_t upper in
      let reasons =
        match upper with
        | UseT _ -> (ru, rl)
        | _ -> FlowError.ordered_reasons (rl, ru)
      in
      add_output cx (Error_message.ERecursionLimit reasons)
    | ex ->
      (* rethrow *)
      raise ex

  and flow_t cx (t1, t2) = flow cx (t1, UseT (unknown_use, t2))

  and flow_p cx ~use_op lreason ureason propref props =
    rec_flow_p cx ~use_op ~report_polarity:true lreason ureason propref props

  (* Wrapper functions around __unify that manage traces. Use these functions for
     all recursive calls in the implementation of __unify. *)
  and rec_unify cx trace ~use_op ?(unify_any = false) t1 t2 =
    __unify cx ~use_op ~unify_any t1 t2 (DepthTrace.rec_trace trace)

  and unify_opt cx ?trace ~use_op ?(unify_any = false) t1 t2 =
    let trace =
      match trace with
      | None -> DepthTrace.unit_trace
      | Some trace -> DepthTrace.rec_trace trace
    in
    __unify cx ~use_op ~unify_any t1 t2 trace

  (* Externally visible function for unification. *)
  (* Calls internal entry point and traps runaway recursion. *)
  and unify cx ?(use_op = unknown_use) t1 t2 =
    try unify_opt cx ~use_op ~unify_any:true t1 t2 with
    | RecursionCheck.LimitExceeded ->
      (* log and continue *)
      let reasons = FlowError.ordered_reasons (reason_of_t t1, reason_of_t t2) in
      add_output cx (Error_message.ERecursionLimit reasons)
    | ex ->
      (* rethrow *)
      raise ex

  and continue cx trace t = function
    | Lower (use_op, l) -> rec_flow cx trace (l, UseT (use_op, t))
    | Upper u -> rec_flow cx trace (t, u)

  and continue_repos cx trace reason ?(use_desc = false) t = function
    | Lower (use_op, l) ->
      rec_flow_t cx trace ~use_op (l, reposition_reason cx ~trace reason ~use_desc t)
    | Upper u -> rec_flow cx trace (reposition_reason cx ~trace reason ~use_desc t, u)

  and type_app_variance_check cx trace use_op reason_op reason_tapp targs tparams_loc tparams =
    let minimum_arity = poly_minimum_arity tparams in
    let maximum_arity = Nel.length tparams in
    let arity_loc = tparams_loc in
    if List.length targs > maximum_arity then
      add_output cx (Error_message.ETooManyTypeArgs { reason_tapp; arity_loc; maximum_arity })
    else
      let (unused_targs, _, _) =
        Nel.fold_left
          (fun (targs, map1, map2) tparam ->
            let { name; default; polarity; reason; _ } = tparam in
            let flow_targs t1 t2 =
              let use_op =
                Frame
                  ( TypeArgCompatibility
                      { name; targ = reason; lower = reason_op; upper = reason_tapp; polarity },
                    use_op
                  )
              in
              match polarity with
              | Polarity.Positive -> rec_flow cx trace (t1, UseT (use_op, t2))
              | Polarity.Negative -> rec_flow cx trace (t2, UseT (use_op, t1))
              | Polarity.Neutral -> rec_unify cx trace ~use_op t1 t2
            in
            match (default, targs) with
            | (None, []) ->
              (* fewer arguments than params but no default *)
              add_output cx (Error_message.ETooFewTypeArgs { reason_tapp; arity_loc; minimum_arity });
              ([], map1, map2)
            | (Some default, []) ->
              let t1 = subst cx ~use_op map1 default in
              let t2 = subst cx ~use_op map2 default in
              flow_targs t1 t2;
              ([], Subst_name.Map.add name t1 map1, Subst_name.Map.add name t2 map2)
            | (_, (t1, t2) :: targs) ->
              flow_targs t1 t2;
              (targs, Subst_name.Map.add name t1 map1, Subst_name.Map.add name t2 map2))
          (targs, Subst_name.Map.empty, Subst_name.Map.empty)
          tparams
      in
      assert (unused_targs = [])

  and possible_concrete_types kind cx reason t =
    let collector = TypeCollector.create () in
    flow cx (t, ConcretizeT { reason; kind; seen = ref ISet.empty; collector });
    TypeCollector.collect collector

  and singleton_concrete_type mk_concretization_target cx reason t =
    match possible_concrete_types mk_concretization_target cx reason t with
    | [] -> EmptyT.make reason
    | [t] -> t
    | t1 :: t2 :: ts -> UnionT (reason, UnionRep.make t1 t2 ts)

  and possible_concrete_types_for_inspection cx reason t =
    possible_concrete_types ConcretizeForInspection cx reason t

  and singleton_concrete_type_for_cjs_extract_named_exports_and_type_exports cx reason t =
    singleton_concrete_type ConcretizeForCJSExtractNamedExportsAndTypeExports cx reason t

  and singleton_concretize_type_for_imports_exports cx reason t =
    singleton_concrete_type ConcretizeForImportsExports cx reason t

  and singleton_concrete_type_for_inspection cx reason t =
    singleton_concrete_type ConcretizeForInspection cx reason t

  and add_specialized_callee_method_action cx trace l = function
    | CallM { specialized_callee; _ }
    | ChainM { specialized_callee; _ } ->
      CalleeRecorder.add_callee cx CalleeRecorder.All l specialized_callee
    | NoMethodAction prop_t -> rec_flow_t cx ~use_op:unknown_use trace (l, prop_t)
end

module rec FlowJs : Flow_common.S = struct
  module React = React_kit.Kit (FlowJs)
  module ObjectKit = Object_kit.Kit (FlowJs)
  module SpeculationKit = Speculation_kit.Make (FlowJs)
  module SubtypingKit = Subtyping_kit.Make (FlowJs)
  include M__flow (FlowJs) (React) (ObjectKit) (SpeculationKit) (SubtypingKit)

  let perform_read_prop_action = GetPropTKit.perform_read_prop_action

  let react_subtype_class_component_render = React.subtype_class_component_render

  let react_get_config = React.get_config

  let possible_concrete_types_for_imports_exports =
    possible_concrete_types ConcretizeForImportsExports

  let possible_concrete_types_for_predicate ~predicate_concretizer_variant =
    possible_concrete_types (ConcretizeForPredicate predicate_concretizer_variant)

  let possible_concrete_types_for_sentinel_prop_test =
    possible_concrete_types ConcretizeForSentinelPropTest

  let all_possible_concrete_types = possible_concrete_types ConcretizeAll

  let possible_concrete_types_for_operators_checking =
    possible_concrete_types ConcretizeForOperatorsChecking

  let possible_concrete_types_for_object_assign = possible_concrete_types ConcretizeForObjectAssign

  let singleton_concrete_type_for_match_arg cx ~keep_unions reason t =
    singleton_concrete_type (ConcretizeForMatchArg { keep_unions }) cx reason t

  let possible_concrete_types_for_match_arg cx ~keep_unions reason t =
    possible_concrete_types (ConcretizeForMatchArg { keep_unions }) cx reason t
end

include FlowJs

(* exporting this for convenience *)
let add_output = Flow_js_utils.add_output

(************* end of slab **************************************************)

(* Would rather this live elsewhere, but here because module DAG. *)
let mk_default cx reason =
  Default.fold
    ~expr:(fun t -> t)
    ~cons:(fun t1 t2 ->
      Tvar.mk_where cx reason (fun tvar ->
          flow_t cx (t1, tvar);
          flow_t cx (t2, tvar)
      ))
    ~selector:(fun r t sel ->
      Tvar.mk_no_wrap_where cx r (fun tvar ->
          eval_selector cx ~annot:false r t sel tvar (Reason.mk_id ())
      ))

(* Export some functions without the trace parameter *)

let mk_instance cx ?type_t_kind instance_reason ?use_desc c =
  mk_instance ?type_t_kind cx instance_reason ?use_desc c

let get_builtin_type cx reason ?use_desc x = get_builtin_type cx reason ?use_desc x

let get_builtin_react_type cx reason ?use_desc purpose =
  get_builtin_react_type cx reason ?use_desc purpose

let reposition_reason cx reason ?use_desc t = reposition_reason cx reason ?use_desc t

let filter_optional cx reason opt_t = filter_optional cx reason opt_t

let reposition cx loc t = reposition cx loc ?desc:None ?annot_loc:None t

let mk_typeapp_instance_annot cx ~use_op ~reason_op ~reason_tapp ~from_value c ts =
  mk_typeapp_instance_annot cx ~use_op ~reason_op ~reason_tapp ~from_value c ts

let mk_type_destructor cx use_op reason t d id =
  mk_type_destructor cx ~trace:DepthTrace.dummy_trace use_op reason t d id

let add_output cx msg = add_output cx msg
