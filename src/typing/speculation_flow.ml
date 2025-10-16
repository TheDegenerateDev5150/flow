(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open Type
module SpeculationKit = Speculation_kit.Make (Flow_js.FlowJs)

let try_custom = SpeculationKit.try_custom

let flow_t_unsafe cx (l, u) =
  SpeculationKit.try_singleton_throw_on_failure cx DepthTrace.dummy_trace l (UseT (unknown_use, u))

let is_flow_successful cx t u =
  match SpeculationKit.try_singleton_throw_on_failure cx DepthTrace.dummy_trace t u with
  | exception Flow_js_utils.SpeculationSingletonError -> false
  | () -> true

let is_subtyping_successful cx l u = is_flow_successful cx l (UseT (unknown_use, u))

let resolved_lower_flow_unsafe cx r (l, u) =
  match Flow_js.possible_concrete_types_for_inspection cx r l with
  | [] -> ()
  | [l] -> Flow_js.flow cx (l, u)
  | l0 :: ls ->
    let successful =
      Base.List.fold ls ~init:(is_flow_successful cx l0 u) ~f:(fun acc l ->
          let r = is_flow_successful cx l u in
          acc || r
      )
    in
    if not successful then raise Flow_js_utils.SpeculationSingletonError

let resolved_lower_flow_t_unsafe cx r (l, u) =
  resolved_lower_flow_unsafe cx r (l, UseT (unknown_use, u))

let resolved_upper_flow_t_unsafe cx r (l, u) =
  match Flow_js.possible_concrete_types_for_inspection cx r u with
  | [] -> ()
  | [u] -> Flow_js.flow_t cx (l, u)
  | u0 :: us ->
    let successful =
      Base.List.fold
        us
        ~init:(is_flow_successful cx l (UseT (unknown_use, u0)))
        ~f:(fun acc u ->
          let r = is_flow_successful cx l (UseT (unknown_use, u)) in
          acc || r)
    in
    if not successful then raise Flow_js_utils.SpeculationSingletonError

let get_method_type_unsafe cx t reason propref =
  Tvar.mk_where cx reason (fun prop_t ->
      let use_t = MethodT (unknown_use, reason, reason, propref, NoMethodAction prop_t) in
      resolved_lower_flow_unsafe cx reason (t, use_t)
  )

let get_method_type_opt cx t reason propref =
  match
    Tvar.mk_where cx reason (fun prop_t ->
        let use_t = MethodT (unknown_use, reason, reason, propref, NoMethodAction prop_t) in
        resolved_lower_flow_unsafe cx reason (t, use_t)
    )
  with
  | exception Flow_js_utils.SpeculationSingletonError -> None
  | t -> Some t
