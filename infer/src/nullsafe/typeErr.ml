(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module Hashtbl = Caml.Hashtbl
module MF = MarkupFormatter
module P = Printf

(** Module for Type Error messages. *)

(** Describe the origin of values propagated by the checker. *)
module type InstrRefT = sig
  type t [@@deriving compare]

  val equal : t -> t -> bool

  type generator

  val create_generator : Procdesc.Node.t -> generator

  val gen : generator -> t

  val get_node : t -> Procdesc.Node.t

  val hash : t -> int

  val replace_node : t -> Procdesc.Node.t -> t
end

(* InstrRefT *)

(** Per-node instruction reference. *)
module InstrRef : InstrRefT = struct
  type t = Procdesc.Node.t * int [@@deriving compare]

  let equal = [%compare.equal: t]

  type generator = Procdesc.Node.t * int ref

  let hash (n, i) = Hashtbl.hash (Procdesc.Node.hash n, i)

  let get_node (n, _) = n

  let replace_node (_, i) n' = (n', i)

  let create_generator n = (n, ref 0)

  let gen instr_ref_gen =
    let node, ir = instr_ref_gen in
    incr ir ; (node, !ir)
end

(* InstrRef *)

type origin_descr = string * Location.t option * AnnotatedSignature.t option

(* callee signature *)
(* ignore origin descr *)
let compare_origin_descr _ _ = 0

type parameter_not_nullable =
  string
  * (* description *)
    int
  * (* parameter number *)
    Typ.Procname.t
  * Location.t
  * (* callee location *)
    origin_descr
[@@deriving compare]

(** Instance of an error *)
type err_instance =
  | Condition_redundant of (bool * string option)
  | Inconsistent_subclass_return_annotation of Typ.Procname.t * Typ.Procname.t
  | Inconsistent_subclass_parameter_annotation of string * int * Typ.Procname.t * Typ.Procname.t
  | Field_not_initialized of Typ.Fieldname.t * Typ.Procname.t
  | Field_annotation_inconsistent of Typ.Fieldname.t * origin_descr
  | Field_over_annotated of Typ.Fieldname.t * Typ.Procname.t
  | Nullable_dereference of
      { nullable_object_descr: string option
      ; dereference_type: dereference_type
      ; origin_descr: origin_descr }
  | Parameter_annotation_inconsistent of parameter_not_nullable
  | Return_annotation_inconsistent of Typ.Procname.t * origin_descr
  | Return_over_annotated of Typ.Procname.t
[@@deriving compare]

and dereference_type =
  | MethodCall of Typ.Procname.t
  | AccessToField of Typ.Fieldname.t
  | AccessByIndex of {index_desc: string}
  | ArrayLengthAccess

module H = Hashtbl.Make (struct
  type t = err_instance * InstrRef.t option [@@deriving compare]

  let equal = [%compare.equal: t]

  let hash = Hashtbl.hash
end
(* H *))

type err_state =
  { loc: Location.t  (** location of the error *)
  ; mutable always: bool  (** always fires on its associated node *) }

let err_tbl : err_state H.t = H.create 1

(** Reset the error table. *)
let reset () = H.reset err_tbl

(** Get the forall status of an err_instance.
    The forall status indicates that the error should be printed only if it
    occurs on every path. *)
let get_forall = function
  | Condition_redundant _ ->
      true
  | Field_not_initialized _ ->
      false
  | Field_annotation_inconsistent _ ->
      false
  | Field_over_annotated _ ->
      false
  | Inconsistent_subclass_return_annotation _ ->
      false
  | Inconsistent_subclass_parameter_annotation _ ->
      false
  | Nullable_dereference _ ->
      false
  | Parameter_annotation_inconsistent _ ->
      false
  | Return_annotation_inconsistent _ ->
      false
  | Return_over_annotated _ ->
      false


(** Reset the always field of the forall erros in the node, so if they are not set again
    we know that they don't fire on every path. *)
let node_reset_forall node =
  let iter (err_instance, instr_ref_opt) err_state =
    match (instr_ref_opt, get_forall err_instance) with
    | Some instr_ref, is_forall ->
        let node' = InstrRef.get_node instr_ref in
        if is_forall && Procdesc.Node.equal node node' then err_state.always <- false
    | None, _ ->
        ()
  in
  H.iter iter err_tbl


(** Add an error to the error table and return whether it should be printed now. *)
let add_err find_canonical_duplicate err_instance instr_ref_opt loc =
  let is_forall = get_forall err_instance in
  if H.mem err_tbl (err_instance, instr_ref_opt) then false (* don't print now *)
  else
    let instr_ref_opt_deduplicate =
      match (is_forall, instr_ref_opt) with
      | true, Some instr_ref ->
          (* use canonical duplicate for forall checks *)
          let node = InstrRef.get_node instr_ref in
          let canonical_node = find_canonical_duplicate node in
          let instr_ref' = InstrRef.replace_node instr_ref canonical_node in
          Some instr_ref'
      | _ ->
          instr_ref_opt
    in
    H.add err_tbl (err_instance, instr_ref_opt_deduplicate) {loc; always= true} ;
    not is_forall


(* print now if it's not a forall check *)

module Severity = struct
  let get_severity ia =
    if Annotations.ia_ends_with ia Annotations.generated_graphql then Some Exceptions.Error
    else None


  let this_type_get_severity tenv (signature : AnnotatedSignature.t) =
    match signature.params with
    | AnnotatedSignature.{mangled; param_annotated_type} :: _ when Mangled.is_this mangled ->
        (* TODO(T54088319) get rid of direct access to annotation *)
        Option.bind ~f:get_severity
          (PatternMatch.type_get_annotation tenv param_annotated_type.typ)
    | _ ->
        None


  let origin_descr_get_severity tenv origin_descr =
    match origin_descr with
    | _, _, Some signature ->
        this_type_get_severity tenv signature
    | _, _, None ->
        None


  let err_instance_get_severity tenv err_instance : Exceptions.severity option =
    match err_instance with
    | Nullable_dereference {origin_descr} ->
        origin_descr_get_severity tenv origin_descr
    | _ ->
        None
end

(* Severity *)

type st_report_error =
     Typ.Procname.t
  -> Procdesc.t
  -> IssueType.t
  -> Location.t
  -> ?field_name:Typ.Fieldname.t option
  -> ?exception_kind:(IssueType.t -> Localise.error_desc -> exn)
  -> ?severity:Exceptions.severity
  -> string
  -> unit

(** Report an error right now. *)
let report_error_now tenv (st_report_error : st_report_error) err_instance loc pdesc : unit =
  let pname = Procdesc.get_proc_name pdesc in
  let nullable_annotation = "@Nullable" in
  let kind, description, field_name =
    match err_instance with
    | Condition_redundant (is_always_true, s_opt) ->
        ( IssueType.eradicate_condition_redundant
        , P.sprintf "The condition %s is always %b according to the existing annotations."
            (Option.value s_opt ~default:"") is_always_true
        , None )
    | Field_not_initialized (fn, pn) ->
        let constructor_name =
          if Typ.Procname.is_constructor pn then "the constructor"
          else
            match pn with
            | Typ.Procname.Java pn_java ->
                MF.monospaced_to_string (Typ.Procname.Java.get_method pn_java)
            | _ ->
                MF.monospaced_to_string (Typ.Procname.to_simplified_string pn)
        in
        ( IssueType.eradicate_field_not_initialized
        , Format.asprintf "Field %a is not initialized in %s and is not declared %a"
            MF.pp_monospaced
            (Typ.Fieldname.to_simplified_string fn)
            constructor_name MF.pp_monospaced nullable_annotation
        , Some fn )
    | Field_annotation_inconsistent (fn, (origin_description, _, _)) ->
        let kind_s, description =
          ( IssueType.eradicate_field_not_nullable
          , Format.asprintf "Field %a can be null but is not declared %a. %s" MF.pp_monospaced
              (Typ.Fieldname.to_simplified_string fn)
              MF.pp_monospaced nullable_annotation origin_description )
        in
        (kind_s, description, None)
    | Field_over_annotated (fn, pn) ->
        let constructor_name =
          if Typ.Procname.is_constructor pn then "the constructor"
          else
            match pn with
            | Typ.Procname.Java pn_java ->
                Typ.Procname.Java.get_method pn_java
            | _ ->
                Typ.Procname.to_simplified_string pn
        in
        ( IssueType.eradicate_field_over_annotated
        , Format.asprintf "Field %a is always initialized in %s but is declared %a"
            MF.pp_monospaced
            (Typ.Fieldname.to_simplified_string fn)
            constructor_name MF.pp_monospaced nullable_annotation
        , Some fn )
    | Nullable_dereference {nullable_object_descr; dereference_type; origin_descr= origin_str, _, _}
      ->
        let nullable_object_descr =
          match dereference_type with
          | MethodCall _ | AccessToField _ -> (
            match nullable_object_descr with
            | None ->
                "Object"
            (* Just describe an object itself *)
            | Some descr ->
                MF.monospaced_to_string descr )
          | ArrayLengthAccess | AccessByIndex _ -> (
            (* In Java, those operations can be applied only to arrays *)
            match nullable_object_descr with
            | None ->
                "Array"
            | Some descr ->
                Format.sprintf "Array %s" (MF.monospaced_to_string descr) )
        in
        let action_descr =
          match dereference_type with
          | MethodCall method_name ->
              Format.sprintf "calling %s"
                (MF.monospaced_to_string (Typ.Procname.to_simplified_string method_name))
          | AccessToField field_name ->
              Format.sprintf "accessing field %s"
                (MF.monospaced_to_string (Typ.Fieldname.to_simplified_string field_name))
          | AccessByIndex {index_desc} ->
              Format.sprintf "accessing at index %s" (MF.monospaced_to_string index_desc)
          | ArrayLengthAccess ->
              "accessing its length"
        in
        let description =
          Format.sprintf "%s is nullable and is not locally checked for null when %s. %s"
            nullable_object_descr action_descr origin_str
        in
        (IssueType.eradicate_nullable_dereference, description, None)
    | Parameter_annotation_inconsistent (s, n, pn, _, (origin_desc, _, _)) ->
        let kind_s, description =
          ( IssueType.eradicate_parameter_not_nullable
          , Format.asprintf
              "%a needs a non-null value in parameter %d but argument %a can be null. %s"
              MF.pp_monospaced
              (Typ.Procname.to_simplified_string ~withclass:true pn)
              n MF.pp_monospaced s origin_desc )
        in
        (kind_s, description, None)
    | Return_annotation_inconsistent (pn, (origin_description, _, _)) ->
        let kind_s, description =
          ( IssueType.eradicate_return_not_nullable
          , Format.asprintf "Method %a may return null but it is not annotated with %a. %s"
              MF.pp_monospaced
              (Typ.Procname.to_simplified_string pn)
              MF.pp_monospaced nullable_annotation origin_description )
        in
        (kind_s, description, None)
    | Return_over_annotated pn ->
        ( IssueType.eradicate_return_over_annotated
        , Format.asprintf "Method %a is annotated with %a but never returns null." MF.pp_monospaced
            (Typ.Procname.to_simplified_string pn)
            MF.pp_monospaced nullable_annotation
        , None )
    | Inconsistent_subclass_return_annotation (pn, opn) ->
        ( IssueType.eradicate_inconsistent_subclass_return_annotation
        , Format.asprintf "Method %a is annotated with %a but overrides unannotated method %a."
            MF.pp_monospaced
            (Typ.Procname.to_simplified_string ~withclass:true pn)
            MF.pp_monospaced nullable_annotation MF.pp_monospaced
            (Typ.Procname.to_simplified_string ~withclass:true opn)
        , None )
    | Inconsistent_subclass_parameter_annotation (param_name, pos, pn, opn) ->
        let translate_position = function
          | 1 ->
              "First"
          | 2 ->
              "Second"
          | 3 ->
              "Third"
          | n ->
              string_of_int n ^ "th"
        in
        ( IssueType.eradicate_inconsistent_subclass_parameter_annotation
        , Format.asprintf
            "%s parameter %a of method %a is not %a but is declared %ain the parent class method \
             %a."
            (translate_position pos) MF.pp_monospaced param_name MF.pp_monospaced
            (Typ.Procname.to_simplified_string ~withclass:true pn)
            MF.pp_monospaced nullable_annotation MF.pp_monospaced nullable_annotation
            MF.pp_monospaced
            (Typ.Procname.to_simplified_string ~withclass:true opn)
        , None )
  in
  let severity = Severity.err_instance_get_severity tenv err_instance in
  st_report_error pname pdesc kind loc ~field_name
    ~exception_kind:(fun k d -> Exceptions.Eradicate (k, d))
    ?severity description


(** Report an error unless is has been reported already, or unless it's a forall error
    since it requires waiting until the end of the analysis and be printed by flush. *)
let report_error tenv (st_report_error : st_report_error) find_canonical_duplicate err_instance
    instr_ref_opt loc pdesc =
  let should_report_now = add_err find_canonical_duplicate err_instance instr_ref_opt loc in
  if should_report_now then report_error_now tenv st_report_error err_instance loc pdesc


(** Report the forall checks at the end of the analysis and reset the error table *)
let report_forall_checks_and_reset tenv st_report_error proc_desc =
  let iter (err_instance, instr_ref_opt) err_state =
    match (instr_ref_opt, get_forall err_instance) with
    | Some instr_ref, is_forall ->
        let node = InstrRef.get_node instr_ref in
        State.set_node node ;
        if is_forall && err_state.always then
          report_error_now tenv st_report_error err_instance err_state.loc proc_desc
    | None, _ ->
        ()
  in
  H.iter iter err_tbl ; reset ()
