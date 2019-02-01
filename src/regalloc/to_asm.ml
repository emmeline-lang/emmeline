(** This module replaces virtual registers with stack offsets and eliminates
    basic block parameters. *)

open Base

let compile_operand coloring = function
  | Ir.Operand.Extern_var path -> Ok (Asm.Extern_var path)
  | Ir.Operand.Lit lit -> Ok (Asm.Lit lit)
  | Ir.Operand.Register reg ->
     match Hashtbl.find coloring.Color.map reg with
     | Some color -> Ok (Asm.Stack color)
     | None -> Message.unreachable "to_asm compile_operand"

let compile_operands coloring =
  let open Result.Let_syntax in
  List.fold_right ~init:(Ok []) ~f:(fun operand acc ->
      let%bind operands = acc in
      let%map operand = compile_operand coloring operand in
      operand::operands)

let find_color coloring dest f =
  match Hashtbl.find coloring.Color.map dest with
  | None -> Message.unreachable "find_color compile_basic_block"
  | Some color -> f color

let compile_instr coloring opcode =
  let open Result.Let_syntax in
  match opcode with
  | Ssa.Assign(dest, lval, rval) ->
     find_color coloring dest (fun dest ->
         let%bind lval = compile_operand coloring lval in
         let%map rval = compile_operand coloring rval in
         Asm.Assign(dest, lval, rval)
       )
  | Ssa.Box(dest, tag, operands) ->
     find_color coloring dest (fun dest ->
         let%map operands = compile_operands coloring operands in
         Asm.Box(dest, tag, operands)
       )
  | Ssa.Box_dummy(dest, i) ->
     find_color coloring dest (fun dest ->
         Ok (Asm.Box_dummy(dest, i))
       )
  | Ssa.Call(dest, f, arg, args) ->
     find_color coloring dest (fun dest ->
         let%bind f = compile_operand coloring f in
         let%bind arg = compile_operand coloring arg in
         let%map args = compile_operands coloring args in
         Asm.Call(dest, f, arg, args)
       )
  | Ssa.Deref(dest, operand) ->
     find_color coloring dest (fun dest ->
         let%map operand = compile_operand coloring operand in
         Asm.Deref(dest, operand)
       )
  | Ssa.Get(dest, operand, idx) ->
     find_color coloring dest (fun dest ->
         let%map operand = compile_operand coloring operand in
         Asm.Get(dest, operand, idx)
       )
  | Ssa.Load(dest, operand) ->
     find_color coloring dest (fun dest ->
         let%map operand = compile_operand coloring operand in
         Asm.Move(dest, operand)
       )
  | Ssa.Prim(dest, str) ->
     find_color coloring dest (fun dest ->
         Ok (Asm.Prim(dest, str))
       )
  | Ssa.Ref(dest, operand) ->
     find_color coloring dest (fun dest ->
         let%map operand = compile_operand coloring operand in
         Asm.Ref(dest, operand)
       )
  | Ssa.Set_field(dest, idx, op) ->
     let%bind dest = compile_operand coloring dest in
     let%map op = compile_operand coloring op in
     Asm.Set_field(dest, idx, op)
  | Ssa.Set_tag(dest, tag) ->
     let%map dest = compile_operand coloring dest in
     Asm.Set_tag(dest, tag)
  | Ssa.Tag(dest, operand) ->
     find_color coloring dest (fun dest ->
         let%map operand = compile_operand coloring operand in
         Asm.Tag(dest, operand)
       )

let rec compile_basic_block new_blocks coloring proc label =
  let open Result.Let_syntax in
  match Map.find new_blocks label with
  | Some asm_block -> Ok (new_blocks, asm_block)
  | None ->
     match Map.find proc.Ssa2.blocks label with
     | None -> Message.unreachable "to_asm compile_basic_block 1"
     | Some block ->
        let instrs = Queue.create () in
        let%bind params =
          List.fold block.Ssa2.params ~init:(Ok []) ~f:(fun acc reg_param ->
              let%bind list = acc in
              find_color coloring reg_param (fun color -> Ok (color::list))
            ) in
        let%bind () =
          List.fold block.Ssa2.instrs ~init:(Ok ()) ~f:(fun acc instr ->
              let%bind () = acc in
              let%map instr = compile_instr coloring instr.Ssa2.opcode in
              Queue.enqueue instrs instr) in
        let%map new_blocks = match block.Ssa2.jump with
          | Ssa.Break(label, args) ->
             let args = Array.of_list args in
             let%bind new_blocks, asm_block =
               compile_basic_block new_blocks coloring proc label in
             let%map _ =
               List.fold asm_block.Asm.block_params ~init:(Ok 0)
                 ~f:(fun acc color ->
                   let%bind idx = acc in
                   let%map operand = compile_operand coloring (args.(idx)) in
                   Queue.enqueue instrs (Asm.Move(color, operand));
                   idx + 1
                 ) in
             Queue.enqueue instrs (Asm.Break label);
             new_blocks
          | Ssa.Fail ->
             Queue.enqueue instrs (Asm.Fail);
             Ok new_blocks
          | Ssa.Return operand ->
             let%map operand = compile_operand coloring operand in
             Queue.enqueue instrs (Asm.Return operand);
             new_blocks
          | Ssa.Switch(scrut, cases, else_case) ->
             let%bind scrut = compile_operand coloring scrut in
             Queue.enqueue instrs (Asm.Switch(scrut, cases, else_case));
             let%bind new_blocks =
               List.fold cases ~init:(Ok new_blocks) ~f:(fun acc (_, label) ->
                   let%bind new_blocks = acc in
                   let%map new_blocks, _ =
                     compile_basic_block new_blocks coloring proc label
                   in new_blocks
                 ) in
             let%map new_blocks, _ =
               compile_basic_block new_blocks coloring proc else_case
             in new_blocks
        in
        let new_block = { Asm.instrs; block_params = params } in
        (Map.set new_blocks ~key:label ~data:new_block, new_block)

let compile_proc coloring proc =
  let open Result.Let_syntax in
  let map = Map.empty (module Ir.Label) in
  let%bind free_vars =
    List.fold_right proc.Ssa2.free_vars ~init:(Ok []) ~f:(fun reg acc ->
        let%bind list = acc in
        match Hashtbl.find coloring.Color.map reg with
        | Some color -> Ok (color::list)
        | None -> Message.unreachable "compile_proc free_vars"
      ) in
  let%bind params =
    List.fold_right proc.Ssa2.params ~init:(Ok []) ~f:(fun reg acc ->
        let%bind list = acc in
        match Hashtbl.find coloring.Color.map reg with
        | Some color -> Ok (color::list)
        | None -> Message.unreachable "compile_proc params"
      ) in
  let%map blocks, _ = compile_basic_block map coloring proc proc.Ssa2.entry in
  { Asm.free_vars
  ; params
  ; entry = proc.Ssa2.entry
  ; blocks
  ; frame_size = coloring.Color.frame_size }

let compile { Color.colorings; main's_coloring } package =
  let open Result.Let_syntax in
  let%bind procs =
    Map.fold package.Ssa2.procs ~init:(Ok (Map.empty (module Int)))
      ~f:(fun ~key:name ~data:proc acc ->
        let%bind procs = acc in
        match Map.find colorings name with
        | None -> Message.unreachable "to_asm compile_package"
        | Some coloring ->
           let%map blocks = compile_proc coloring proc in
           Map.set procs ~key:name ~data:blocks
      ) in
  let%map main = compile_proc main's_coloring package.Ssa2.main in
  { Asm.procs; main }
