(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module F = Format

module CallEvent : sig
  type t =
    | Call of Typ.Procname.t  (** known function with summary *)
    | Model of string  (** hardcoded model *)
    | SkippedKnownCall of Typ.Procname.t  (** known function without summary *)
    | SkippedUnknownCall of Exp.t  (** couldn't link the expression to a proc name *)

  val describe : F.formatter -> t -> unit
end

module Invalidation : sig
  type std_vector_function =
    | Assign
    | Clear
    | Emplace
    | EmplaceBack
    | Insert
    | PushBack
    | Reserve
    | ShrinkToFit
  [@@deriving compare]

  val pp_std_vector_function : Format.formatter -> std_vector_function -> unit

  type t =
    | CFree
    | CppDelete
    | GoneOutOfScope of Pvar.t * Typ.t
    | Nullptr
    | StdVector of std_vector_function
  [@@deriving compare]

  val issue_type_of_cause : t -> IssueType.t

  val describe : Format.formatter -> t -> unit
end

module ValueHistory : sig
  type event =
    | Assignment of Location.t
    | Call of {f: CallEvent.t; location: Location.t; in_call: t}
    | Capture of {captured_as: Pvar.t; location: Location.t}
    | CppTemporaryCreated of Location.t
    | FormalDeclared of Pvar.t * Location.t
    | VariableAccessed of Pvar.t * Location.t
    | VariableDeclared of Pvar.t * Location.t

  and t = event list [@@deriving compare]

  val add_to_errlog : nesting:int -> t -> Errlog.loc_trace_elem list -> Errlog.loc_trace_elem list
end

module Trace : sig
  type 'a t =
    | Immediate of {imm: 'a; location: Location.t; history: ValueHistory.t}
    | ViaCall of
        { f: CallEvent.t
        ; location: Location.t  (** location of the call event *)
        ; history: ValueHistory.t  (** the call involves a value with this prior history *)
        ; in_call: 'a t  (** last step of the trace is in a call to [f] made at [location] *) }
  [@@deriving compare]

  val get_outer_location : 'a t -> Location.t
  (** skip histories and go straight to the where the action is: either the action itself or the
      call that leads to the action *)

  val get_start_location : 'a t -> Location.t
  (** initial step in the history if not empty, or else same as {!get_outer_location} *)

  val get_immediate : 'a t -> 'a

  val add_to_errlog :
       nesting:int
    -> (F.formatter -> 'a -> unit)
    -> 'a t
    -> Errlog.loc_trace_elem list
    -> Errlog.loc_trace_elem list
end

module Attribute : sig
  type t =
    | AddressOfCppTemporary of Var.t * ValueHistory.t
    | AddressOfStackVariable of Var.t * Location.t * ValueHistory.t
    | Closure of Typ.Procname.t
    | Constant of Const.t
    | Invalid of Invalidation.t Trace.t
    | MustBeValid of unit Trace.t
    | StdVectorReserve
    | WrittenTo of unit Trace.t
  [@@deriving compare]
end

module Attributes : sig
  include PrettyPrintable.PPUniqRankSet with type elt = Attribute.t

  val get_must_be_valid : t -> unit Trace.t option

  val get_invalid : t -> Invalidation.t Trace.t option

  val get_written_to : t -> unit Trace.t option

  val get_address_of_stack_variable : t -> (Var.t * Location.t * ValueHistory.t) option

  val is_modified : t -> bool
end

module AbstractAddress : sig
  type t = private int [@@deriving compare]

  val equal : t -> t -> bool

  val init : unit -> unit

  val pp : F.formatter -> t -> unit [@@warning "-32"]

  val mk_fresh : unit -> t

  type state

  val get_state : unit -> state

  val set_state : state -> unit
end

module AbstractAddressSet : PrettyPrintable.PPSet with type elt = AbstractAddress.t

module AbstractAddressMap : PrettyPrintable.PPMap with type key = AbstractAddress.t

module AddrTracePair : sig
  type t = AbstractAddress.t * ValueHistory.t [@@deriving compare]
end

module Stack : sig
  include PrettyPrintable.MonoMap with type key = Var.t and type value = AddrTracePair.t

  (* need to shadow the declaration in [MonoMap] even though it is unused since [MapS.compare] has a
     different type *)
  val compare : t -> t -> int [@@warning "-32"]
end

module Memory : sig
  module Access :
    PrettyPrintable.PrintableOrderedType with type t = AbstractAddress.t HilExp.Access.t

  module Edges : PrettyPrintable.PPMap with type key = Access.t

  type edges = AddrTracePair.t Edges.t

  val pp_edges : F.formatter -> edges -> unit [@@warning "-32"]

  type cell = edges * Attributes.t

  type t

  val filter : (AbstractAddress.t -> bool) -> t -> t

  val filter_heap : (AbstractAddress.t -> edges -> bool) -> t -> t

  val find_opt : AbstractAddress.t -> t -> cell option

  val fold_attrs : (AbstractAddress.t -> Attributes.t -> 'acc -> 'acc) -> t -> 'acc -> 'acc

  val set_attrs : AbstractAddress.t -> Attributes.t -> t -> t

  val set_edges : AbstractAddress.t -> edges -> t -> t

  val set_cell : AbstractAddress.t -> cell -> t -> t

  val find_edges_opt : AbstractAddress.t -> t -> edges option

  val mem_edges : AbstractAddress.t -> t -> bool

  val register_address : AbstractAddress.t -> t -> t

  val add_edge : AbstractAddress.t -> Access.t -> AddrTracePair.t -> t -> t

  val find_edge_opt : AbstractAddress.t -> Access.t -> t -> AddrTracePair.t option

  val add_attribute : AbstractAddress.t -> Attribute.t -> t -> t

  val invalidate : AbstractAddress.t * ValueHistory.t -> Invalidation.t -> Location.t -> t -> t

  val check_valid : AbstractAddress.t -> t -> (unit, Invalidation.t Trace.t) result

  val get_closure_proc_name : AbstractAddress.t -> t -> Typ.Procname.t option

  val get_constant : AbstractAddress.t -> t -> Const.t option

  val std_vector_reserve : AbstractAddress.t -> t -> t

  val is_std_vector_reserved : AbstractAddress.t -> t -> bool
end

type t = {heap: Memory.t; stack: Stack.t}

val empty : t

include AbstractDomain.NoJoin with type t := t

val reachable_addresses : t -> AbstractAddressSet.t
(** compute the set of abstract addresses that are "used" in the abstract state, i.e. reachable
    from the stack variables *)

type mapping

val empty_mapping : mapping

type isograph_relation =
  | NotIsomorphic  (** no mapping was found that can make LHS the same as the RHS *)
  | IsomorphicUpTo of mapping  (** [mapping(lhs)] is isomorphic to [rhs] *)

val isograph_map : lhs:t -> rhs:t -> mapping -> isograph_relation

val is_isograph : lhs:t -> rhs:t -> mapping -> bool
