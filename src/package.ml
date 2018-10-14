(** A processed compilation unit:
    - Maps type constructor names to type declarations (abstract types or ADTs)
    - Maps data constructor names to ADTs and the integer index
    - Maps variable names to types *)

open Base

type ty_state =
  | Compiled of Type.decl
  | Todo of Kind.t

type command =
  | Let of unit Pattern.decision_tree * Lambda.t
  | Let_rec of (int * Lambda.t) list

type t =
  { name : string
  ; typedefs : (string, ty_state ref) Hashtbl.t
  ; constrs : (string, Type.adt * int) Hashtbl.t
  ; vals : (string, Type.t) Hashtbl.t
  ; commands : command Queue.t }

let create name =
  { name
  ; typedefs = Hashtbl.create (module String)
  ; constrs = Hashtbl.create (module String)
  ; vals = Hashtbl.create (module String)
  ; commands = Queue.create () }

let find f self name = Hashtbl.find (f self) name

let find_typedef = find (fun package -> package.typedefs)

let find_adt = find (fun package -> package.constrs)

let find_val = find (fun package -> package.vals)

let kind_of_ident self name =
  match find_typedef self name with
  | None -> None
  | Some ptr ->
     match !ptr with
     | Compiled (Type.Manifest adt) -> Some (Type.kind_of_adt adt)
     | Compiled (Type.Abstract kind) -> Some kind
     | Todo kind -> Some kind

let add_constrs self adt =
  let open Result.Monad_infix in
  Hashtbl.fold
    ~f:(fun ~key:constr ~data:idx acc ->
      acc >>= fun () ->
      match Hashtbl.add self.constrs ~key:constr ~data:(adt, idx) with
      | `Ok -> Ok ()
      | `Duplicate -> Error (Sequence.return (Message.Redefined_constr constr))
    ) ~init:(Ok ()) adt.Type.constr_names

let add_command self command =
  Queue.enqueue self.commands command
