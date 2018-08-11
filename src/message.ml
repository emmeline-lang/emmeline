type error =
  | Expected_adt of Ident.t
  | Redefined_id of Ident.t
  | Unification_fail of Type.t * Type.t
  | Unimplemented of string
  | Unknown_constr of Ident.t * string
  | Unreachable
  | Unresolved_id of Ident.t
  | Unresolved_type of Ident.t