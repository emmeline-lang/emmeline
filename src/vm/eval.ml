open Base

type value =
  | Box of { mutable tag : int; data : value array }
  | Char of char
  | Float of float
  | Int of int
  | Ref of value ref
  | String of string
  | Uninitialized
  | Unit

type frame = {
    data : value array;
  }

type t = {
    mutable block : Asm.block;
    mutable ip : int;
    proc : Asm.proc;
    mutable return : value;
  }

let eval_operand frame = function
  | Asm.Extern_var _ -> failwith "unimplemented"
  | Asm.Lit (Literal.Char c) -> Char c
  | Asm.Lit (Literal.Float f) -> Float f
  | Asm.Lit (Literal.Int i) -> Int i
  | Asm.Lit (Literal.String s) -> String s
  | Asm.Lit Literal.Unit -> Unit
  | Asm.Stack addr -> frame.data.(addr)

let bump_ip t =
  t.ip <- t.ip + 1

let break t label =
  t.block <- Map.find_exn t.proc.Asm.blocks label;
  t.ip <- 0

let rec eval_instr t file frame =
  match Queue.get t.block.Asm.instrs t.ip with
  | Asm.Assign(dest, lval, rval) ->
     begin match eval_operand frame lval with
     | Ref r -> r := eval_operand frame rval
     | _ -> failwith "Type error"
     end;
     frame.data.(dest) <- Unit;
     bump_ip t
  | Asm.Box(dest, tag, ops) ->
     let data = Array.of_list (List.map ~f:(eval_operand frame) ops) in
     frame.data.(dest) <- Box { tag; data };
     bump_ip t
  | Asm.Box_dummy(dest, size) ->
     let data = Array.create ~len:size Uninitialized in
     frame.data.(dest) <- Box { tag = 255; data };
     bump_ip t
  | Asm.Call(dest, f, arg, args) ->
     begin match eval_operand frame f with
     | Box { data; _ } ->
        let arg = eval_operand frame arg in
        let args = List.map ~f:(eval_operand frame) args in
        frame.data.(dest) <- apply_function file data (arg::args)
     | _ -> failwith "Type error"
     end;
     bump_ip t
  | Asm.Deref(dest, r) ->
     begin match eval_operand frame r with
     | Ref r -> frame.data.(dest) <- !r
     | _ -> failwith "Type error"
     end;
     bump_ip t
  | Asm.Get(dest, data, idx) ->
     begin match eval_operand frame data with
     | Box { data; _ } -> frame.data.(dest) <- data.(idx)
     | _ -> failwith "Type error"
     end;
     bump_ip t
  | Asm.Move(dest, data) ->
     frame.data.(dest) <- eval_operand frame data;
     bump_ip t
  | Asm.Ref(dest, data) ->
     frame.data.(dest) <- Ref (ref (eval_operand frame data));
     bump_ip t
  | Asm.Set_field(dest, idx, src) ->
     let src = eval_operand frame src in
     begin match eval_operand frame dest with
     | Box { data; _ } ->
        data.(idx) <- src;
     | _ -> failwith "Type error"
     end;
     bump_ip t
  | Asm.Set_tag(dest, tag) ->
     begin match eval_operand frame dest with
     | Box box -> box.tag <- tag;
     | _ -> failwith "Type error"
     end;
     bump_ip t
  | Asm.Tag(dest, addr) ->
     begin match eval_operand frame addr with
     | Box { tag; _ } -> frame.data.(dest) <- Int tag
     | _ -> failwith "Type error"
     end;
     bump_ip t
  | Asm.Break label ->
     break t label
  | Asm.Fail -> failwith "Pattern match failure"
  | Asm.Return op ->
     t.return <- eval_operand frame op
  | Asm.Switch(scrut, cases, else_case) ->
     let scrut = eval_operand frame scrut in
     begin match scrut with
     | Int tag ->
        let rec check = function
          | [] -> break t else_case
          | (i, conseq)::_ when i = tag -> break t conseq
          | _::xs -> check xs in
        check cases
     | _ -> failwith "Unreachable"
     end
  | Asm.Prim _ -> failwith "Unimplemented"

and apply_function file proc_data args =
  match proc_data.(0) with
  | Int idx ->
     let proc = Map.find_exn file.Asm.procs idx in
     let ctx =
       { proc
       ; block = Map.find_exn proc.Asm.blocks proc.Asm.entry
       ; ip = 0
       ; return = Uninitialized } in
     let frame = { data = Array.create ~len:proc.frame_size Uninitialized } in
     (* Load environment into stack frame *)
     List.iteri proc.Asm.free_vars ~f:(fun i addr ->
         frame.data.(addr) <- proc_data.(i + 1)
       );
     let _ =
       (* Load arguments into stack frame *)
       List.iter2 proc.Asm.params args ~f:(fun addr data ->
           frame.data.(addr) <- data
         ) in
     let rec loop () =
       match ctx.return with
       | Uninitialized ->
          eval_instr ctx file frame;
          loop ()
       | _ -> ctx.return
     in loop ()
  | _ -> failwith "Type error: Expected function pointer"

let eval file =
  let proc = file.Asm.main in
  let ctx =
    { proc
    ; block = Map.find_exn proc.Asm.blocks proc.Asm.entry
    ; ip = 0
    ; return = Uninitialized } in
  let frame = { data = Array.create ~len:proc.frame_size Uninitialized } in
  let rec loop () =
    match ctx.return with
    | Uninitialized ->
       eval_instr ctx file frame;
       loop ()
    | _ -> ctx.return
  in loop ()
