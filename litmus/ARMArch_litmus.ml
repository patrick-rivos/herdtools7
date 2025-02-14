(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* Jade Alglave, University College London, UK.                             *)
(* Luc Maranget, INRIA Paris-Rocquencourt, France.                          *)
(*                                                                          *)
(* Copyright 2010-present Institut National de Recherche en Informatique et *)
(* en Automatique and the authors. All rights reserved.                     *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law and   *)
(* abiding by the rules of distribution of free software. You can use,      *)
(* modify and/ or redistribute the software under the terms of the CeCILL-B *)
(* license as circulated by CEA, CNRS and INRIA at the following URL        *)
(* "http://www.cecill.info". We also give a copy in LICENSE.txt.            *)
(****************************************************************************)

open Printf

(* let comment = '@' *)
let comment = "#"

module Make(O:Arch_litmus.Config)(V:Constant.S) = struct
  include ARMBase
  module V = V

  module FaultType = FaultType.No

  let tab = Hashtbl.create 17
  let () =
    List.iter (fun (r,s) -> Hashtbl.add tab r s) regs

  let reg_to_string r =  match r with
  | Symbolic_reg _ -> assert false
  | Internal i -> sprintf "i%i" i
  | _ ->
      try Misc.lowercase (Hashtbl.find tab r) with Not_found -> assert false

  include
      ArchExtra_litmus.Make(O)
      (struct
        module V = V

        type arch_reg = reg
        let arch = `ARM
        let forbidden_regs = []
        let pp_reg = pp_reg
        let reg_compare = reg_compare
        let reg_to_string = reg_to_string
        let internal_init r =
          let some s = Some (s,"int") in
          if reg_compare r base = 0 then some "_a->_scratch"
          else if reg_compare r max_idx = 0 then some "max_idx"
          else if reg_compare r loop_idx = 0 then some "max_loop"
          else None
        let reg_class _ = "=&r"
        let reg_class_stable _ = "=&r"
        let comment = comment
        let error _ _ = false
        let warn _ _ = false
      end)
  let features = []
  let nop = I_NOP

  include HardwareExtra.No

  module GetInstr = GetInstr.No(struct type instr=instruction end)

end
