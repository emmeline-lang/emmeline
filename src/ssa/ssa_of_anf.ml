(** This transformation turns ANF join points, which are local to the case expr,
    into SSA basic blocks, which are local to the function. Here, the compiler
    compiles decision trees into switches, jumps, and phi nodes. *)

open Base

type jump_dest =
  | Label of Ir.Label.t
  | Return

type t = {
    procs : (int, Ssa.proc, Int.comparator_witness) Map.t ref;
    blocks :
      (Ir.Label.t, Ssa.basic_block, Ir.Label.comparator_witness) Map.t ref;
    label_gen : Ir.Label.gen;
    proc_gen : int ref;
    instrs : Ssa.instr Queue.t;
    curr_block : Ir.Label.t;
    jump_dest : jump_dest;
  }

(** Helper record for organizational purposes *)
type branch = {
    branch_idx : Ir.Label.t;
    label : Ir.Label.t;
    block : Ssa.basic_block;
  }

(** [fresh_block ctx ~cont] applies [cont] to the index of the next basic block,
    [cont] returns a tuple consisting of a result, the block predecessors, the
    instruction queue, and the block successor. The entire function returns
    [cont]'s result *)
let fresh_block ctx ~cont =
  let open Result.Let_syntax in
  let idx = Ir.Label.fresh ctx.label_gen in
  let%map ret, preds, instrs, jump = cont idx in
  let block = { Ssa.instrs; preds; jump } in
  ctx.blocks := Map.set !(ctx.blocks) ~key:idx ~data:block;
  (ret, block)

let rec compile_decision_tree ctx instrs this_label branches =
  let open Result.Let_syntax in
  function
  | Anf.Deref(occ, dest, tree) ->
     Queue.enqueue instrs { Ssa.dest = dest; opcode = Deref occ };
     compile_decision_tree ctx instrs this_label branches tree
  | Anf.Fail -> Ok Ssa.Fail
  | Anf.Leaf(operands, idx) ->
     let { branch_idx; block; _ } = branches.(idx) in
     block.Ssa.preds <- Set.add block.Ssa.preds this_label;
     Ok (Ssa.Break(branch_idx, operands))
  | Anf.Switch(tag_reg, occ, trees, else_tree) ->
     Queue.enqueue instrs { Ssa.dest = tag_reg; opcode = Tag occ };
     let%bind cases =
       Map.fold trees ~init:(Ok []) ~f: begin
           fun ~key:case ~data:(regs, tree) acc ->
           let%bind list = acc in
           let%map (result, _) =
             fresh_block ctx ~cont:begin fun case_idx ->
               let case_instrs = Queue.create () in
               let%map jump =
                 List.iteri ~f:(fun idx reg ->
                     Queue.enqueue case_instrs
                       { Ssa.dest = reg; opcode = Get(occ, idx) }
                   ) regs;
                 compile_decision_tree ctx case_instrs case_idx branches tree
               in
               ( (case, case_idx)::list
               , Set.singleton (module Ir.Label) this_label
               , case_instrs
               , jump )
               end
           in result
         end in
     let%map (else_block_idx, _) =
       fresh_block ctx ~cont:(fun else_idx ->
           let else_instrs = Queue.create () in
           let%map jump =
             compile_decision_tree ctx else_instrs else_idx branches else_tree
           in
           ( else_idx
           , Set.singleton (module Ir.Label) this_label
           , else_instrs
           , jump )
         )
     in Ssa.Switch(Ir.Operand.Register tag_reg, cases, else_block_idx)

let rec compile_opcode ctx anf ~cont
        : (Ir.Label.t * Ssa.jump, Message.error Sequence.t) Result.t =
  let open Result.Let_syntax in
  match anf with
  | Anf.Assign(lval, rval) -> cont ctx (Ssa.Assign(lval, rval))
  | Anf.Box(tag, contents) -> cont ctx (Ssa.Box(tag, contents))
  | Anf.Call(f, arg, args) -> cont ctx (Ssa.Call(f, arg, args))
  | Anf.Case(tree, join_points) ->
     let%map result, _ =
       (* The basic block for the case expr confluent basic block *)
       fresh_block ctx ~cont:(fun confl_idx ->
           let confl_instrs = Queue.create () in
           let%bind branches =
             List.fold_right join_points ~init:(Ok [])
               ~f:(fun (reg_args, instr) acc ->
                 let%bind list = acc in
                 (* The basic block for the join point *)
                 let%map (branch_idx, label), block =
                   fresh_block ctx ~cont:(fun branch_idx ->
                       let branch_instrs = Queue.create () in
                       List.iteri reg_args ~f:(fun i reg_arg ->
                           Queue.enqueue branch_instrs
                             { Ssa.dest = reg_arg; opcode = Phi i };
                         );
                       let%map label, jump =
                         compile_instr
                           { ctx with
                             instrs = branch_instrs
                           ; curr_block = branch_idx
                           ; jump_dest = Label confl_idx }
                           instr in
                       ( (branch_idx, label)
                       , Set.empty (module Ir.Label)
                       , branch_instrs
                       , jump )
                     )
                 in { branch_idx; label; block }::list
               ) in
           let%bind jump_from_decision_tree =
             compile_decision_tree ctx ctx.instrs ctx.curr_block
               (Array.of_list branches) tree in
           let preds =
             List.fold branches ~init:(Set.empty (module Ir.Label))
               ~f:(fun acc { label; _ } ->
                 Set.add acc label
               ) in
           (* Label of confluent block, jump of confluent block *)
           let%map label, jump =
             (* Compile the rest of the ANF in the confluent block *)
             cont { ctx with instrs = confl_instrs; curr_block = confl_idx }
               (Ssa.Phi 0) in
           ( (label, jump_from_decision_tree)
           , preds
           , confl_instrs
           , jump )
         ) in result
  | Anf.Fun proc ->
     let env = List.map ~f:(fun (_, op) -> op) proc.Anf.env in
     let%bind proc = compile_proc ctx proc in
     let idx = !(ctx.proc_gen) in
     ctx.proc_gen := idx + 1;
     let procs = Map.set !(ctx.procs) ~key:idx ~data:proc in
     ctx.procs := procs;
     cont ctx (Ssa.Fun(idx, env))
  | Anf.Load o -> cont ctx (Ssa.Load o)
  | Anf.Prim p -> cont ctx (Ssa.Prim p)
  | Anf.Ref x -> cont ctx (Ssa.Ref x)

and compile_instr ctx anf
    : (Ir.Label.t * Ssa.jump, Message.error Sequence.t) Result.t =
  let open Result.Let_syntax in
  match anf.Anf.instr with
  | Anf.Let(reg, op, next) ->
     compile_opcode ctx op ~cont:(fun ctx op ->
         Queue.enqueue ctx.instrs { Ssa.dest = reg; opcode = op };
         compile_instr ctx next
       )
  | Anf.Let_rec(bindings, next) ->
     (* Initialize registers with dummy allocations *)
     let%bind () =
       List.fold_left bindings ~init:(Ok ()) ~f:begin
           fun acc (reg, _, _, def) ->
           let%bind () = acc in
           let%map size =
             match def with
             | Anf.Box(_, list) -> Ok (List.length list)
             | Anf.Fun proc -> Ok (List.length proc.Anf.env + 1)
             | _ -> Error (Sequence.return Message.Unsafe_let_rec) in
           Queue.enqueue ctx.instrs
             { Ssa.dest = reg; opcode = Ssa.Box_dummy size }
         end in
     (* Accumulator is a function *)
     List.fold_right bindings ~init:(fun ctx ->
         compile_instr ctx next
       ) ~f:(fun (reg, temp, unused, op) acc ctx ->
         compile_opcode ctx op ~cont:(fun ctx op ->
             (* Evaluate the let-rec binding RHS *)
             Queue.enqueue ctx.instrs { Ssa.dest = temp; opcode = op };
             (* Mutate the memory that the register points to *)
             Queue.enqueue ctx.instrs
               { Ssa.dest = unused
               ; opcode =
                   Ssa.Memcopy( Ir.Operand.Register reg
                              , Ir.Operand.Register temp ) };
             acc ctx)
       ) ctx
  | Anf.Break operand ->
     Ok ( ctx.curr_block
        , match ctx.jump_dest with
          | Label label -> Ssa.Break(label, [operand])
          | Return -> Ssa.Return operand )

and compile_proc ctx proc =
  let open Result.Let_syntax in
  let blocks = ref (Map.empty (module Ir.Label)) in
  let instrs = Queue.create () in
  let label_gen = Ir.Label.create_gen () in
  let entry_label = Ir.Label.fresh label_gen in
  let state =
    { ctx with
      blocks
    ; instrs
    ; label_gen
    ; curr_block = entry_label
    ; jump_dest = Return } in
  let%map before_return, jump = compile_instr state proc.Anf.body in
  let entry_block =
    { Ssa.preds = Set.empty (module Ir.Label)
    ; instrs
    ; jump } in
  { Ssa.free_vars = List.map ~f:(fun (reg, _) -> reg) proc.Anf.env
  ; params = proc.Anf.params
  ; blocks = Map.set !blocks ~key:entry_label ~data:entry_block
  ; entry = entry_label
  ; before_return }

let compile_package anf =
  let open Result.Let_syntax in
  let label_gen = Ir.Label.create_gen () in
  let entry_label = Ir.Label.fresh label_gen in
  let ctx =
    { procs = ref (Map.empty (module Int))
    ; blocks = ref (Map.empty (module Ir.Label))
    ; instrs = Queue.create ()
    ; proc_gen = ref 0
    ; label_gen
    ; curr_block = entry_label
    ; jump_dest = Return } in
  let%map before_return, jump = compile_instr ctx anf in
  let entry_block =
    { Ssa.preds = Set.empty (module Ir.Label)
    ; instrs = ctx.instrs
    ; jump } in
  let main_proc =
    { Ssa.free_vars = []
    ; params = []
    ; blocks = Map.set !(ctx.blocks) ~key:entry_label ~data:entry_block
    ; entry = entry_label
    ; before_return } in
  { Ssa.procs = !(ctx.procs)
  ; main = main_proc }
