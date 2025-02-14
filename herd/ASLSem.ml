(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* Jade Alglave, University College London, UK.                             *)
(* Luc Maranget, INRIA Paris-Rocquencourt, France.                          *)
(*                                                                          *)
(* Copyright 2015-present Institut National de Recherche en Informatique et *)
(* en Automatique and the authors. All rights reserved.                     *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law and   *)
(* abiding by the rules of distribution of free software. You can use,      *)
(* modify and/ or redistribute the software under the terms of the CeCILL-B *)
(* license as circulated by CEA, CNRS and INRIA at the following URL        *)
(* "http://www.cecill.info". We also give a copy in LICENSE.txt.            *)
(****************************************************************************)
(* Authors:                                                                 *)
(* Hadrien Renaud, University College London, UK.                           *)
(****************************************************************************)

(*
   A quick note on monads:
   -----------------------

   We use three main connecters here:
    - the classic data binder ( [>>=] )
    - a control binder ( [>>*=] or assimilate)
    - a sequencing operator ( [M.aslseq] )
   And some specialized others:
    - the parallel operator ( [>>|] )
    - a choice operation

   Monad type has:
   - input: EventSet
   - output: EventSet
   - data_input: EventSet
   - ctrl_output: EventSet
   - iico_data: EventRel
   - iico_ctrl: EventRel

   Description of the main data binders:

   - _data_ binders:
     iico_data U= 1.output X 2.data_input
     input = 1.input (or 2.input if 1 is empty)
        same with data_input
     output = 2.ouput (or 1.output if 2.output is None)
        same-ish with ctrl_output

   - _seq_ binder (called [aslseq]):
     input = 1.input U 2.input
        same with data_input
     output = 2.output
     ctrl_output = 1.ctrl_output U 2.ctrl_output

   - _ctrl_ binder (called [bind_ctrl_seq_data]):
     iico_ctrl U= 1.ctrl_output X 2.input
     input = 1.input (or 2.input if 1 is empty)
        same with data_input
     output = 2.output (or 1.output if 2.output is None)
        same-ish with ctrl_output
 *)

module AST = Asllib.AST

module type Config = sig
  include Sem.Config

  val libfind : string -> string
end

module Make (C : Config) = struct
  module V = ASLValue.V

  module ConfLoc = struct
    include SemExtra.ConfigToArchConfig (C)

    let default_to_symb = C.variant Variant.ASL
  end

  module ASL64AH = struct
    include GenericArch_herd.Make (ASLBase) (ConfLoc) (V)
    include ASLBase

    let opt_env = true
  end

  module Act = ASLAction.Make (ASL64AH)
  include SemExtra.Make (C) (ASL64AH) (Act)

  let barriers = []
  let isync = None
  let atomic_pair_allowed _ _ = true

  module Mixed (SZ : ByteSize.S) : sig
    val build_semantics : test -> A.inst_instance_id -> (proc * branch) M.t
    val spurious_setaf : A.V.v -> unit M.t
  end = struct
    module Mixed = M.Mixed (SZ)

    let ( let* ) = M.( >>= )
    let ( and* ) = M.( >>| )
    let return = M.unitT
    let ( >>= ) = M.( >>= )
    let ( >>! ) = M.( >>! )

    (**************************************************************************)
    (* ASL-PO handling                                                        *)
    (**************************************************************************)

    let incr (poi : A.program_order_index ref) : A.program_order_index =
      let i = !poi in
      let () = poi := A.next_po_index i in
      i

    let use_ii_with_poi ii poi =
      let program_order_index = incr poi in
      { ii with A.program_order_index }

    (**************************************************************************)
    (* Values handling                                                        *)
    (**************************************************************************)

    let as_constant = function
      | V.Val c -> c
      | V.Var _ as v ->
          Warn.fatal "Cannot convert value %s into constant" (V.pp_v v)

    let v_of_parsed_v =
      let open AST in
      let open ASLScalar in
      let concrete v = Constant.Concrete v in
      let vector li = Constant.ConcreteVector li in
      let rec tr = function
        | V_Int i -> S_Int (Int64.of_int i) |> concrete
        | V_Bool b -> S_Bool b |> concrete
        | V_BitVector bv -> S_BitVector bv |> concrete
        | V_Tuple li -> List.map tr li |> vector
        | V_Record li -> List.map (fun (_, v) -> tr v) li |> vector
        | V_Exception li -> List.map (fun (_, v) -> tr v) li |> vector
        | V_Real _f -> Warn.fatal "Cannot use reals yet."
      in
      fun v -> V.Val (tr v)

    let v_to_int = function
      | V.Val (Constant.Concrete (ASLScalar.S_Int i)) -> Some (Int64.to_int i)
      | _ -> None

    let v_as_int = function
      | V.Val (Constant.Concrete i) -> V.Cst.Scalar.to_int i
      | v -> Warn.fatal "Cannot concretise symbolic value: %s" (V.pp_v v)

    let v_to_bv = function
      | V.Val (Constant.Concrete (ASLScalar.S_BitVector bv)) -> bv
      | v -> Warn.fatal "Cannot construct a bitvector out of %s." (V.pp_v v)

    let datasize_to_machsize v =
      match v_as_int v with
      | 32 -> MachSize.Word
      | 64 -> MachSize.Quad
      | 128 -> MachSize.S128
      | _ -> Warn.fatal "Cannot access a register with size %s" (V.pp_v v)

    let to_bv = M.op1 (Op.ArchOp1 ASLValue.ASLArchOp.ToBV)
    let to_int = M.op1 (Op.ArchOp1 ASLValue.ASLArchOp.ToInt)

    (**************************************************************************)
    (* Special monad interations                                              *)
    (**************************************************************************)

    let resize_from_quad = function
      | MachSize.Quad -> return
      | sz -> (
          function
          | V.Val (Constant.Symbolic _) as v -> return v
          | v -> M.op1 (Op.Mask sz) v)

    let write_loc sz loc v ii =
      let* resized_v = resize_from_quad sz v in
      let mk_action loc' = Act.Access (Dir.W, loc', resized_v, sz) in
      M.write_loc mk_action loc ii

    let read_loc sz loc ii =
      let mk_action loc' v' = Act.Access (Dir.R, loc', v', sz) in
      let* v = M.read_loc false mk_action loc ii in
      resize_from_quad sz v

    let loc_of_scoped_id ii x scope =
      A.Location_reg (ii.A.proc, ASLBase.ASLLocalId (scope, x))

    (**************************************************************************)
    (* ASL-Backend implementation                                             *)
    (**************************************************************************)

    let choice (m1 : V.v M.t) (m2 : 'b M.t) (m3 : 'b M.t) : 'b M.t =
      M.bind_ctrl_seq_data m1 (function
        | V.Val (Constant.Concrete (ASLScalar.S_Bool b)) -> if b then m2 else m3
        | b -> M.bind_ctrl_seq_data (to_int b) (fun v -> M.choiceT v m2 m3))

    let binop =
      let open AST in
      let to_bool op v1 v2 =
        op v1 v2 >>= M.op1 (Op.ArchOp1 ASLValue.ASLArchOp.ToBool)
      in
      let to_bv op v1 v2 =
        op v1 v2 >>= M.op1 (Op.ArchOp1 ASLValue.ASLArchOp.ToBV)
      in
      let or_ v1 v2 =
        match (v1, v2) with
        | V.Val (Constant.Concrete (ASLScalar.S_BitVector bv)), v
          when Asllib.Bitvector.is_zeros bv ->
            return v
        | v, V.Val (Constant.Concrete (ASLScalar.S_BitVector bv))
          when Asllib.Bitvector.is_zeros bv ->
            return v
        | _ -> to_bv (M.op Op.Or) v1 v2
      in
      function
      | AND -> M.op Op.And |> to_bv
      | BAND -> M.op Op.And
      | BEQ -> M.op Op.Eq |> to_bool
      | BOR -> M.op Op.Or
      | DIV -> M.op Op.Div
      | EOR -> M.op Op.Xor |> to_bv
      | EQ_OP -> M.op Op.Eq |> to_bool
      | GT -> M.op Op.Gt |> to_bool
      | GEQ -> M.op Op.Ge |> to_bool
      | LT -> M.op Op.Lt |> to_bool
      | LEQ -> M.op Op.Le |> to_bool
      | MINUS -> M.op Op.Sub
      | MUL -> M.op Op.Mul
      | NEQ -> M.op Op.Ne |> to_bool
      | OR -> or_
      | PLUS -> M.op Op.Add
      | SHL -> M.op Op.ShiftLeft
      | SHR -> M.op Op.ShiftRight
      | IMPL | MOD | RDIV -> Warn.fatal "Not yet implemented operation."

    let unop op =
      let open AST in
      match op with
      | BNOT -> (
          function
          | V.Val (Constant.Concrete (ASLScalar.S_Bool b)) ->
              V.Val (Constant.Concrete (ASLScalar.S_Bool (not b))) |> return
          | v -> M.op1 Op.Not v >>= M.op1 (Op.ArchOp1 ASLValue.ASLArchOp.ToBool)
          )
      | NEG -> M.op Op.Sub V.zero
      | NOT ->
          fun v -> M.op1 Op.Inv v >>= M.op1 (Op.ArchOp1 ASLValue.ASLArchOp.ToBV)

    let on_write_identifier (ii, poi) x scope v =
      let loc = loc_of_scoped_id ii x scope in
      let action = Act.Access (Dir.W, loc, v, MachSize.Quad) in
      M.mk_singleton_es action (use_ii_with_poi ii poi)

    let on_read_identifier (ii, poi) x scope v =
      let loc = loc_of_scoped_id ii x scope in
      let action = Act.Access (Dir.R, loc, v, MachSize.Quad) in
      M.mk_singleton_es action (use_ii_with_poi ii poi)

    let create_vector _ty li =
      let li = List.map as_constant li in
      return (V.Val (Constant.ConcreteVector li))

    let get_i i v =
      match v with
      | V.Val (Constant.ConcreteVector li) -> (
          match List.nth_opt li i with
          | None ->
              Warn.user_error "Index %d out of bounds for value %s" i (V.pp_v v)
          | Some v -> return (V.Val v))
      | V.Val _ ->
          Warn.user_error "Trying to index non-indexable value %s" (V.pp_v v)
      | V.Var _ -> Warn.fatal "Cannot write to a symbolic value %s." (V.pp_v v)

    let list_update i v li =
      let rec aux acc i li =
        match (li, i) with
        | [], _ -> None
        | _ :: t, 0 -> Some (List.rev_append acc (v :: t))
        | h :: t, i -> aux (h :: acc) (i - 1) t
      in
      aux [] i li

    let set_i i v vec =
      let li =
        match vec with
        | V.Val (Constant.ConcreteVector li) -> li
        | V.Val _ ->
            Warn.user_error "Trying to index non-indexable value %s"
              (V.pp_v vec)
        | V.Var _ ->
            Warn.fatal "Not yet implemented: writing to a symbolic value."
      and c = match v with V.Val c -> c | V.Var i -> V.freeze i in
      match list_update i c li with
      | None ->
          Warn.user_error "Index %d out of bounds for value %s" i (V.pp_v vec)
      | Some li -> return (V.Val (Constant.ConcreteVector li))

    let read_from_bitvector positions bvs =
      let positions = Asllib.ASTUtils.slices_to_positions v_as_int positions in
      let arch_op1 = ASLValue.ASLArchOp.BVSlice positions in
      M.op1 (Op.ArchOp1 arch_op1) bvs

    let write_to_bitvector positions w v =
      let bv_src, bv_dst =
        match (w, v) with
        | ( V.Val (Constant.Concrete (ASLScalar.S_BitVector bv_src)),
            V.Val (Constant.Concrete (ASLScalar.S_BitVector bv_dst)) ) ->
            (bv_src, bv_dst)
        | _ -> Warn.fatal "Not yet implemented: writing to symbolic bitvector"
      in
      let positions = Asllib.ASTUtils.slices_to_positions v_as_int positions in
      let bv_res = Asllib.Bitvector.write_slice bv_dst bv_src positions in
      return (V.Val (Constant.Concrete (ASLScalar.S_BitVector bv_res)))

    let concat_bitvectors bvs =
      let bvs =
        let filter = function
          | V.Val (Constant.Concrete (ASLScalar.S_BitVector bv)) ->
              Asllib.Bitvector.length bv > 0
          | _ -> true
        in
        List.filter filter bvs
      in
      match bvs with
      | [ x ] -> return x
      | [ V.Val (Constant.Concrete (ASLScalar.S_BitVector bv)); V.Var x ]
        when Asllib.Bitvector.to_int bv = 0 ->
          return (V.Var x)
      | [ (V.Var _ as x); V.Val (Constant.Concrete (ASLScalar.S_BitVector bv)) ]
        when Asllib.Bitvector.is_zeros bv ->
          M.op1 (Op.LeftShift (Asllib.Bitvector.length bv)) x
      | bvs ->
          let as_concrete_bv = function
            | V.Val (Constant.Concrete (ASLScalar.S_BitVector bv)) -> bv
            | _ ->
                Warn.fatal
                  "Not yet implemented: concatenating symbolic bitvectors: \
                   [%s]."
                  (String.concat "," (List.map V.pp_v bvs))
          in
          let bv_res = Asllib.Bitvector.concat (List.map as_concrete_bv bvs) in
          return (V.Val (Constant.Concrete (ASLScalar.S_BitVector bv_res)))

    (**************************************************************************)
    (* Primitives and helpers                                                 *)
    (**************************************************************************)

    let virtual_to_loc_reg rv ii =
      let i = v_as_int rv in
      if i >= List.length AArch64Base.gprs || i < 0 then
        Warn.fatal "Invalid register number: %d" i
      else
        let arch_reg = AArch64Base.Ireg (List.nth AArch64Base.gprs i) in
        A.Location_reg (ii.A.proc, ASLBase.ArchReg arch_reg)

    let read_register (ii, poi) r_m =
      let* rval = r_m in
      let loc = virtual_to_loc_reg rval ii in
      read_loc MachSize.Quad loc (use_ii_with_poi ii poi) >>= to_bv

    let write_register (ii, poi) r_m v_m =
      let* v = v_m >>= to_int and* r = r_m in
      let loc = virtual_to_loc_reg r ii in
      write_loc MachSize.Quad loc v (use_ii_with_poi ii poi) >>! []

    let read_memory (ii, poi) addr_m datasize_m =
      let* addr = addr_m and* datasize = datasize_m in
      let sz = datasize_to_machsize datasize in
      read_loc sz (A.Location_global addr) (use_ii_with_poi ii poi) >>= to_bv

    let write_memory (ii, poi) = function
      | [ addr_m; datasize_m; value_m ] ->
          let value_m = M.as_data_port value_m in
          let* addr = addr_m and* datasize = datasize_m and* value = value_m in
          let sz = datasize_to_machsize datasize in
          write_loc sz (A.Location_global addr) value (use_ii_with_poi ii poi)
          >>! []
      | li ->
          Warn.fatal
            "Bad number of arguments passed to write_memory: 3 expected, and \
             only %d provided."
            (List.length li)

    let loc_sp ii = A.Location_reg (ii.A.proc, ASLBase.ArchReg AArch64Base.SP)

    let read_sp (ii, poi) () =
      read_loc MachSize.Quad (loc_sp ii) (use_ii_with_poi ii poi) >>= to_bv

    let write_sp (ii, poi) v_m =
      let* v = v_m >>= to_int in
      write_loc MachSize.Quad (loc_sp ii) v (use_ii_with_poi ii poi) >>! []

    let read_pstate_nzcv (ii, poi) () =
      let loc = A.Location_reg (ii.A.proc, ASLBase.ArchReg AArch64Base.NZCV) in
      read_loc MachSize.Quad loc (use_ii_with_poi ii poi) >>= to_bv

    let write_pstate_nzcv (ii, poi) v_m =
      let loc = A.Location_reg (ii.A.proc, ASLBase.ArchReg AArch64Base.NZCV) in
      let* v = v_m >>= to_int in
      write_loc MachSize.Quad loc v (use_ii_with_poi ii poi) >>! []

    let replicate bv_m v_m =
      let* bv = bv_m and* v = v_m in
      let return_bv res =
        V.Val (Constant.Concrete (ASLScalar.S_BitVector res)) |> return
      in
      match v_as_int v with
      | 0 -> Asllib.Bitvector.of_string "" |> return_bv
      | 1 -> return bv
      | i ->
          let bv = v_to_bv bv in
          List.init i (Fun.const bv) |> Asllib.Bitvector.concat |> return_bv

    let sign_extend v_m n_m =
      let* v = v_m and* n = n_m in
      M.op1 (Op.Sxt (datasize_to_machsize n)) v

    let uint bv_m = bv_m >>= to_int
    let sint bv_m = bv_m >>= M.op1 Op.Not >>= to_int >>= M.op1 (Op.AddK 1)
    let processor_id (ii, _poi) () = return (V.intToV ii.A.proc)

    (**************************************************************************)
    (* ASL environment                                                        *)
    (**************************************************************************)

    (* Helpers *)
    let build_primitive name args return_type body =
      let return_type, make_return_type = return_type in
      let body = make_return_type body in
      let parameters =
        let open AST in
        let get_param t =
          match t.desc with
          | T_Bits (BitWidth_Determined { desc = E_Var x; _ }, _) ->
              Some (x, None)
          | _ -> None
        in
        args |> List.filter_map get_param (* |> List.sort String.compare *)
      and args =
        List.mapi (fun i arg_ty -> ("arg_" ^ string_of_int i, arg_ty)) args
      in
      AST.{ name; args; body; return_type; parameters }

    let arity_zero name return_type f =
      build_primitive name [] return_type @@ function
      | [] -> f ()
      | _ :: _ -> Warn.fatal "Arity error for function %s." name

    let arity_one name args return_type f =
      build_primitive name args return_type @@ function
      | [ x ] -> f x
      | [] | _ :: _ :: _ -> Warn.fatal "Arity error for function %s." name

    let arity_two name args return_type f =
      build_primitive name args return_type @@ function
      | [ x; y ] -> f x y
      | [] | [ _ ] | _ :: _ :: _ :: _ ->
          Warn.fatal "Arity error for function %s." name

    let return_one ty = (Some ty, fun body args -> return [ body args ])
    let return_zero = (None, Fun.id)

    (* Primitives *)
    let extra_funcs ii_env =
      let open AST in
      let with_pos = Asllib.ASTUtils.add_dummy_pos in
      let d = T_Int None |> with_pos in
      let reg = T_Int None |> with_pos in
      let var x = E_Var x |> with_pos in
      let lit x = E_Literal (V_Int x) |> with_pos in
      let bv x = T_Bits (BitWidth_Determined x, None) |> with_pos in
      let bv_var x = bv @@ var x in
      let bv_lit x = bv @@ lit x in
      let mul x y = E_Binop (MUL, x, y) |> with_pos in
      let t_named x = T_Named x |> with_pos in
      let getter = Asllib.ASTUtils.getter_name in
      let setter = Asllib.ASTUtils.setter_name in
      [
        arity_one "read_register" [ reg ]
          (return_one (bv_lit 64))
          (read_register ii_env);
        arity_two "write_register"
          [ bv_lit 64; reg ]
          return_zero (write_register ii_env);
        arity_two "read_memory" [ reg; d ] (return_one d) (read_memory ii_env);
        build_primitive "write_memory" [ reg; d; d ] return_zero
          (write_memory ii_env);
        arity_zero (getter "PSTATE")
          (return_one (t_named "ProcState"))
          (read_pstate_nzcv ii_env);
        arity_one (setter "PSTATE")
          [ t_named "ProcState" ]
          return_zero (write_pstate_nzcv ii_env);
        arity_zero (getter "SP_EL0") (return_one (bv_lit 64)) (read_sp ii_env);
        arity_one (setter "SP_EL0") [ bv_lit 64 ] return_zero (write_sp ii_env);
        arity_two "Replicate"
          [ bv_var "N"; d ]
          (return_one (bv (mul (var "N") (var "arg_1"))))
          replicate;
        arity_one "UInt" [ bv_var "N" ] (return_one d) uint;
        arity_one "SInt" [ bv_var "N" ] (return_one d) sint;
        arity_two "SignExtend"
          [ bv_var "M"; d ]
          (return_one (bv_var "arg_1"))
          sign_extend;
        arity_zero "ProcessorID" (return_one d) (processor_id ii_env);
      ]

    (**************************************************************************)
    (* Execution                                                              *)
    (**************************************************************************)

    let build_semantics _t ii =
      let ii_env = (ii, ref ii.A.program_order_index) in
      let module ASLBackend = struct
        type value = V.v
        type 'a m = 'a M.t
        type scope = string * int

        let debug_value = V.pp_v
        let v_of_int = V.intToV
        let v_of_parsed_v = v_of_parsed_v
        let v_to_int = v_to_int
        let bind_data = M.( >>= )
        let bind_seq = M.aslseq
        let bind_ctrl = M.bind_ctrl_seq_data
        let prod = M.( >>| )
        let choice = choice
        let return = M.unitT
        let on_write_identifier = on_write_identifier ii_env
        let on_read_identifier = on_read_identifier ii_env
        let binop = binop
        let unop = unop
        let create_vector = create_vector
        let get_i = get_i
        let set_i = set_i
        let read_from_bitvector = read_from_bitvector
        let write_to_bitvector = write_to_bitvector
        let concat_bitvectors = concat_bitvectors
      end in
      let module ASLInterpreter = Asllib.Interpreter.Make (ASLBackend) in
      let ast =
        if C.variant Variant.ASL_AArch64 then
          let build ?ast_type version fname =
            Filename.concat "asl-pseudocode" fname
            |> C.libfind
            |> ASLBase.build_ast_from_file ?ast_type version
          in
          let patches = build `ASLv1 "patches.asl"
          and custom_implems = build `ASLv1 "implementations.asl"
          and shared = build `ASLv0 "shared_pseudocode.asl" in
          let shared =
            Asllib.ASTUtils.patch
              ~patches:(List.rev_append custom_implems patches)
              ~src:shared
          in
          ii.A.inst @ shared
        else ii.A.inst
      in
      let exec () = ASLInterpreter.run ast (extra_funcs ii_env) in
      let* () =
        match Asllib.Error.intercept exec () with
        | Ok m -> m
        | Error err -> Asllib.Error.error_to_string err |> Warn.fatal "%s"
      in
      M.addT !(snd ii_env) B.nextT

    let spurious_setaf _ = assert false
  end
end
