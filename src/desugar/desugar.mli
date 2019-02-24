type t

val create : Package.t -> (string, Package.t) Base.Hashtbl.t -> t
(** Create a fresh desugarer state *)

val term_of_expr :
  t ->
  (string, Ident.t, Base.String.comparator_witness) Env.t
  -> 'a Ast.expr
  -> ('a Term.t, 'a Message.t) result
(** [term_of_expr desugarer env expr] converts [expr] from an [Ast.expr] to a
    [Term.t]. *)

val desugar :
  Typecheck.t ->
  (string, Ident.t, Base.String.comparator_witness) Env.t ->
  Package.t ->
  (string, Package.t) Base.Hashtbl.t ->
  'a Ast.file ->
  ('a Term.file, 'a Message.t) result