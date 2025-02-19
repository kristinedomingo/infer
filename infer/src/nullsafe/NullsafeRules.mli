(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd

(** This is a single place consolidating core rules driving Nullsafe type checking.
  Nullsafe enforces similar rules in different places (e.g. places dealing with fields,
  function calls, assignments, local variables etc.).
  Those places might have additional specifics, but core checks should be done through this class.
  If you are writing a new or modifying an existing check, ask yourself if you can directly
  use already existng rules from this module.
  If you feel you need a rule of a completely new nature, add it to this module.
  As a rule of thumb, every different "check" that is responsible for detecting issues, should query
  this module instead of doing things on their own.
  *)

val passes_assignment_rule : lhs:Nullability.t -> rhs:Nullability.t -> bool
(** Assignment rule: No expression of nullable type is ever assigned to a location
    of non-nullable type.
 *)

val passes_dereference_rule : Nullability.t -> bool
(** Dereference rule: an object can be dereferenced only when it is not nullable (or believed to be so).
 *)

type type_role = Param | Ret

val passes_inheritance_rule : type_role -> base:Nullability.t -> overridden:Nullability.t -> bool
(** Inheritance rule:
  a) Return type for an overridden method is covariant:
       overridden method is allowed to narrow down the return value to a subtype of the one from the
       base method; this means it is OK to make the return value non-null when it was nullable in the base)
  b) Parameter type for an overridden method is contravariant.
       It is OK for a derived method to accept nullable in the params even if the base does not accept nullable.
  NOTE: Rule a) is based on Java covariance rule for the return type.
        In contrast, rule b) is nullsafe specific as Java does not support type contravariance for method params.
 *)

val is_overannotated : lhs:Nullability.t -> rhs_upper_bound:Nullability.t -> bool
(** Check if a type in signature (e.g. return value) can be made more specific.
   If an upper bound of `rhs_i` over ALL assignents `lhs = rhs_i` that exist in the program
   is a _strict_ subtype of lhs, `lhs`'s type can be narrowed to be that upper bound.
   NOTE: This rule is complementatary to assignment rule.
         While assignment rule checks a single assignment `lhs = rhs`, this rule
         checks checks ALL assignments to `lhs` in the program.
   NOTE: Violation of this rule is not a type violation, hence it should never be surfaced as error:
         `lhs`'s type can be intentionally made broad by code author
         (e.g. to anticipate future changes in the implementation).
         Additional heuristits are required to correctly surface overannotated rule to the user.
         This rule is useful for some scenarios, especially for nullability code conversions
         when it is expected that some signatures were annotated with @Nullable defensively, so
         surfacing such cases can improve API and make migration smooth.
 *)
