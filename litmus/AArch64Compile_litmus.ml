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

module type Config = sig
  val verbose : int
  val word : Word.t
  val memory : Memory.t
  val cautious : bool
  val asmcomment : string option
  val hexa : bool
  val mode : Mode.t
  val precision : Precision.t
end

module Make(V:Constant.S)(C:Config) =
  struct
    module  A = AArch64Arch_litmus.Make(C)(V)
    open A
    open A.Out
    open CType
    open Printf

(* Return instruction *)
    let is_ret = function
      | A.I_RET None -> true
      | _ -> false

    let is_nop = function
      | A.I_NOP -> true
      | _ -> false

(* No addresses in code *)
    let extract_addrs _ins = Global_litmus.Set.empty

    let stable_regs _ins = match _ins with
    | I_LD1M (rs,_,_)
    | I_LD2 (rs,_,_,_) | I_LD2M (rs,_,_) | I_LD2R (rs,_,_)
    | I_LD3 (rs,_,_,_) | I_LD3M (rs,_,_) | I_LD3R (rs,_,_)
    | I_LD4 (rs,_,_,_) | I_LD4M (rs,_,_) | I_LD4R (rs,_,_)
    | I_ST1M (rs,_,_)
    | I_ST2 (rs,_,_,_) | I_ST2M (rs,_,_)
    | I_ST3 (rs,_,_,_) | I_ST3M (rs,_,_)
    | I_ST4 (rs,_,_,_) | I_ST4M (rs,_,_) ->
        A.RegSet.of_list rs
    | I_LD1 (r,_,_,_) -> A.RegSet.of_list [r]
    | _ ->  A.RegSet.empty

(* Handle zero reg *)
    let arg1 ppz fmt r = match r with
      | ZR -> [],ppz
      | _  -> [r],fmt "0"

    let args2 ppz fmt r1 r2 = match r1,r2 with
    | ZR,ZR -> [],ppz,[],ppz
    | ZR,_  -> [],ppz,[r2],fmt "0"
    | _,ZR  -> [r1],fmt "0",[],ppz
    | _,_ -> [r1],fmt "0",[r2],fmt "1"

    let add_type t rs = List.map (fun r -> r,t) rs
    let add_w = add_type word
    let add_q = add_type quad
    let add_v = add_type voidstar
    let add_128 = add_type int128

(* pretty prints barrel shifters *)
    let pp_shifter = function
      | S_LSL(s) -> sprintf "LSL #%d" s
      | S_LSR(s) -> sprintf "LSR #%d" s
      | S_MSL(s) -> sprintf "MSL #%d" s
      | S_ASR(s) -> sprintf "ASR #%d" s
      | S_SXTW -> "SXTW"
      | S_UXTW -> "UXTW"
      | S_NOEXT  -> ""

(* handle `ins ..,[X1,W2]` with no barrel shifter
   as a shorthand for `ins ..,[X1,W2,SXTW]`.
   Applies to instructions LDRB and LDRH *)

    let default_shift kr s = match kr,s with
      | RV (V32,_),S_NOEXT -> S_SXTW
      | _,s -> s

(************************)
(* Template compilation *)
(************************)


(* Branches *)
    let pp_cond = function
      | EQ -> "eq"
      | NE -> "ne"
      | CS -> "cs"
      | CC -> "cc"
      | MI -> "mi"
      | PL -> "pl"
      | VS -> "vs"
      | VC -> "vc"
      | HI -> "hi"
      | LS -> "ls"
      | GE -> "ge"
      | LT -> "lt"
      | GT -> "gt"
      | LE -> "le"
      | AL -> "al"

    let dump_tgt tr_lab =
      let open BranchTarget in
      function
      | Lbl lbl -> Branch lbl,A.Out.dump_label (tr_lab lbl)
      | Offset o ->
         if o mod 4 <>0 then  Warn.user_error "Non aligned branch" ;
         Disp (o/4),"." ^ pp_offset o

    let b tr_lab lbl =
      let b,lbl = dump_tgt tr_lab lbl in
      { empty_ins with
        memo = sprintf "b %s" lbl;
        branch=[b;]; }

    let br r =
      { empty_ins with
        memo = "br ^i0";
        inputs = [r;]; reg_env = [r,voidstar];
        branch=[Any] ; }

    let ret r =
      { empty_ins with
        memo = "ret ^i0";
        inputs = [r;]; reg_env = [r,voidstar];
        branch=[Any] ; }

    let bl tr_lab lbl =
      let b,lbl = dump_tgt tr_lab lbl in
      { empty_ins with
        memo = sprintf "bl %s" lbl;
        inputs=[]; outputs=[];
        branch= add_next b;
        clobbers=[linkreg;]; }

    let blr r =
      { empty_ins with
        memo = "blr ^i0";
        inputs=[r;]; outputs=[];
        reg_env = [r,voidstar;];
        branch=[Any] ;  clobbers=[linkreg;]; }

    let bcc tr_lab cond lbl =
      let b,lbl = dump_tgt tr_lab lbl in
      { empty_ins with
        memo = sprintf "b.%s %s" (pp_cond cond) lbl ;
        branch=add_next b; }

    let cbz tr_lab memo v r lbl =
      let b,lbl = dump_tgt tr_lab lbl in
      let memo =
        sprintf
          (match v with
          | V32 -> "%s ^wi0,%s"
          | V64 -> "%s ^i0,%s"
          | V128 -> assert false)
          memo lbl in
      { empty_ins with
        memo; inputs=[r;]; outputs=[];
        branch=add_next b; }

    let tbz tr_lab memo v r k lbl =
      let b,lbl = dump_tgt tr_lab lbl in
      let memo =
        sprintf
          (match v with
          | V32 -> "%s ^wi0,#%d, %s"
          | V64 -> "%s ^i0, #%d, %s"
          | V128 -> assert false)
          memo k lbl in
      { empty_ins with
        memo; inputs=[r;]; outputs=[];
        branch=add_next b ; }

(* Load and Store *)

    let ldr_memo t = Misc.lowercase (ldr_memo t)
    let ldrbh_memo bh t = Misc.lowercase (ldrbh_memo bh t)
    let str_memo t = Misc.lowercase (str_memo t)
    let strbh_memo bh t = Misc.lowercase (strbh_memo bh t)


    let load memo v rD rA kr os = match v,kr,os with
    | V32,K 0, S_NOEXT ->
        { empty_ins with
          memo= sprintf "%s ^wo0,[^i0]" memo;
          inputs=[rA];
          outputs=[rD];
          reg_env=[(rA,voidstar);(rD,word)]; }
    | V32,K k, S_NOEXT ->
        { empty_ins with
          memo= sprintf "%s ^wo0,[^i0,#%i]" memo k;
          inputs=[rA];
          outputs=[rD];
          reg_env=[(rA,voidstar);(rD,word)];}
    | V32,RV (V32,rB), s ->
        let rB,fB = match rB with
        | ZR -> [],"wzr"
        | _  -> [rB],"^wi1" in
        let shift = match s with
        | S_NOEXT -> ""
        | s -> "," ^ pp_shifter s in
        { empty_ins with
          memo=memo^ sprintf " ^wo0,[^i0,%s%s]" fB shift;
          inputs=[rA]@rB;
          outputs=[rD];
          reg_env=add_w rB@[(rA,voidstar); (rD,word);]; }
    | V64,K 0, S_NOEXT ->
        { empty_ins with
          memo=memo ^ sprintf " ^o0,[^i0]";
          inputs=[rA];
          outputs=[rD];
          reg_env=[rA,voidstar;rD,quad;]; }
    | V64,K k, s ->
        let shift = match s with
        | S_NOEXT -> ""
        | s -> "," ^ pp_shifter s in
        { empty_ins with
          memo=memo ^ sprintf " ^o0,[^i0,#%i%s]" k shift;
          inputs=[rA];
          outputs=[rD];
          reg_env=[rA,voidstar; rD,quad;]; }
    | V64,RV (V64,rB), s ->
        let rB,fB = match rB with
        | ZR -> [],"xzr"
        | _  -> [rB],"^i1" in
        let shift = match s with
        | S_NOEXT -> ""
        | s       -> "," ^ pp_shifter s in
        { empty_ins with
          memo=memo^ sprintf " ^o0,[^i0,%s%s]" fB shift;
          inputs=[rA;]@rB;
          outputs=[rD];
          reg_env=add_q rB@[rA,voidstar;rD,quad]; }
    | V64,RV (V32,rB), s ->
        let rB,fB = match rB with
        | ZR -> [],"wzr"
        | _  -> [rB],"^wi1" in
        let shift = match s with
        | S_NOEXT -> ""
        | s -> "," ^ pp_shifter s in
        { empty_ins with
          memo=memo ^ sprintf " ^o0,[^i0,%s%s]" fB shift;
          inputs=[rA]@rB;
          outputs=[rD];
          reg_env=add_w rB@[rA,voidstar;rD,quad;]; }
    | V32,RV (V64,rB), s ->
        let rB,fB = match rB with
        | ZR -> [],"xzr"
        | _  -> [rB],"^i1" in
        let shift = match s with
        | S_NOEXT -> ""
        | s -> "," ^ pp_shifter s in
        { empty_ins with
          memo=memo^ sprintf " ^wo0,[^i0,%s%s]" fB shift;
          inputs=[rA;]@rB;
          outputs=[rD];
          reg_env=add_q rB@[rA,voidstar;rD,word]; }
    | _,_,_ -> assert false

    let load_p memo v rD rA k = match v with
    | V32 ->
        { empty_ins with
          memo= sprintf "%s ^wo0,[^i0],#%i" memo k;
          inputs=[rA];
          outputs=[rD;rA;];
          reg_env=[(rA,voidstar);(rD,word)];}
    | V64 ->
        { empty_ins with
          memo=memo ^ sprintf " ^o0,[^i0],#%i" k;
          inputs=[rA];
          outputs=[rD;rA;];
          reg_env=[rA,voidstar; rD,quad;]; }
    | V128 -> assert false

    let load_pair memo v rD1 rD2 rA kr md = match v,kr,md with
    | V32,0,Idx ->
        { empty_ins with
          memo= sprintf "%s ^wo0,^wo1,[^i0]" memo;
          inputs=[rA];
          outputs=[rD1;rD2;];
          reg_env=[(rA,voidstar);(rD1,word);(rD2,word);]; }
    | V32,k,Idx ->
        { empty_ins with
          memo= sprintf "%s ^wo0,^wo1,[^i0,#%i]" memo k;
          inputs=[rA];
          outputs=[rD1;rD2;];
          reg_env=[(rA,voidstar);(rD1,word);(rD2,word);];}
    | V64,0,Idx ->
        { empty_ins with
          memo=memo ^ sprintf " ^o0,^o1,[^i0]";
          inputs=[rA];
          outputs=[rD1;rD2;];
          reg_env=[rA,voidstar;(rD1,quad);(rD2,quad);]; }
    | V64,k,Idx ->
        { empty_ins with
          memo=memo ^ sprintf " ^o0,^o1,[^i0,#%i]" k;
          inputs=[rA];
          outputs=[rD1;rD2;];
          reg_env=[rA,voidstar; (rD1,quad);(rD2,quad);]; }
    | V32,k,PostIdx ->
        { empty_ins with
          memo= sprintf "%s ^wo0,^wo1,[^i0],#%i" memo k;
          inputs=[rA];
          outputs=[rD1;rD2;rA;];
          reg_env=[(rA,voidstar);(rD1,word);(rD2,word);];}
    | V64,k,PostIdx ->
        { empty_ins with
          memo=memo ^ sprintf " ^o0,^o1,[^i0],#%i" k;
          inputs=[rA];
          outputs=[rD1;rD2;rA];
          reg_env=[rA,voidstar; (rD1,quad);(rD2,quad);]; }
    | V32,k,PreIdx ->
        { empty_ins with
          memo= sprintf "%s ^wo0,^wo1,[^i0,#%i]!" memo k;
          inputs=[rA];
          outputs=[rD1;rD2;rA;];
          reg_env=[(rA,voidstar);(rD1,word);(rD2,word);];}
    | V64,k,PreIdx ->
        { empty_ins with
          memo=memo ^ sprintf " ^o0,^o1,[^i0,#%i]!" k;
          inputs=[rA];
          outputs=[rD1;rD2;rA];
          reg_env=[rA,voidstar; (rD1,quad);(rD2,quad);]; }
    | V128,_,_ -> assert false

    let ldpsw rD1 rD2 rA kr md = load_pair "ldpsw" V64 rD1 rD2 rA kr md

    let loadx_pair memo v rD1 rD2 rA = match v with
      | V32 ->
         { empty_ins with
           memo= sprintf "%s ^wo0,^wo1,[^i0]" memo;
           inputs=[rA];
           outputs=[rD1;rD2;];
           reg_env=[(rA,voidstar);(rD1,word);(rD2,word);]; }
      | V64 ->
        { empty_ins with
           memo= sprintf "%s ^o0,^o1,[^i0]" memo;
           inputs=[rA];
           outputs=[rD1;rD2;];
           reg_env=[(rA,voidstar);(rD1,quad);(rD2,quad);]; }
      | V128 -> assert false

    let store_pair memo v rD1 rD2 rA kr md  = match v,kr,md with
    | V32,0,Idx ->
        { empty_ins with
          memo= sprintf "%s ^wi1,^wi2,[^i0]" memo;
          inputs=[rA;rD1;rD2;];
          outputs=[];
          reg_env=[(rA,voidstar);(rD1,word);(rD2,word);]; }
    | V32,k,Idx ->
        { empty_ins with
          memo= sprintf "%s ^wi1,^wi2,[^i0,#%i]" memo k;
          inputs=[rA;rD1;rD2;];
          outputs=[];
          reg_env=[(rA,voidstar);(rD1,word);(rD2,word);];}
    | V64,0,Idx ->
        { empty_ins with
          memo=memo ^ sprintf " ^i1,^i2,[^i0]";
          inputs=[rA;rD1;rD2;];
          outputs=[];
          reg_env=[rA,voidstar;(rD1,quad);(rD2,quad);]; }
    | V64,k,Idx ->
        { empty_ins with
          memo=memo ^ sprintf " ^i1,^i2,[^i0,#%i]" k;
          inputs=[rA;rD1;rD2;];
          outputs=[];
          reg_env=[rA,voidstar; (rD1,quad);(rD2,quad);]; }
    | V32,k,PostIdx ->
        { empty_ins with
          memo= sprintf "%s ^wi1,^wi2,[^i0],#%i" memo k;
          inputs=[rA;rD1;rD2;];
          outputs=[rA;];
          reg_env=[(rA,voidstar);(rD1,word);(rD2,word);];}
    | V64,k,PostIdx ->
        { empty_ins with
          memo=memo ^ sprintf " ^i1,^i2,[^i0],#%i" k;
          inputs=[rA;rD1;rD2;];
          outputs=[rA;];
          reg_env=[rA,voidstar; (rD1,quad);(rD2,quad);]; }
    | V32,k,PreIdx ->
        { empty_ins with
          memo= sprintf "%s ^wi1,^wi2,[^i0,#%i]!" memo k;
          inputs=[rA;rD1;rD2;];
          outputs=[rA;];
          reg_env=[(rA,voidstar);(rD1,word);(rD2,word);];}
    | V64,k,PreIdx ->
        { empty_ins with
          memo=memo ^ sprintf " ^i1,^i2,[^i0,#%i]!" k;
          inputs=[rA;rD1;rD2;];
          outputs=[rA;];
          reg_env=[rA,voidstar; (rD1,quad);(rD2,quad);]; }
    | V128,_,_ -> assert false

    let storex_pair memo v rs rt1 rt2 rn =
      match v with
      | V32 ->
         { empty_ins with
           memo=memo^ " ^wo0,^wi0,^wi1,[^i2]";
           inputs=[rt1; rt2; rn;];
           outputs=[rs;];
           reg_env=[ rn,voidstar; rs,word; rt1,word; rt2,word;];
         }
      | V64 ->
         { empty_ins with
           memo=memo^ " ^wo0,^i0,^i1,[^i2]";
           inputs=[rt1; rt2; rn;];
           outputs=[rs;];
           reg_env=[ rn,voidstar; rs,word; rt1,quad; rt2,quad; ];
         }
      | V128 -> assert false

    let zr v = match v with
    | V32 -> "wzr"
    | V64 -> "xzr"
    | V128 -> assert false

    let fmt v = match v with
    | V32 -> fun s -> "^w" ^ s
    | V64 -> fun s -> "^" ^ s
    | V128 -> assert false

    let str_arg1 vA rA = match rA with
    | ZR -> [],zr vA ,"^i0"
    | _  -> [rA],fmt vA "i0","^i1"

    let str_arg2 vA rA vC rC = match rA,rC with
    | ZR,ZR -> [],zr vA,"^i0",[],zr vC
    | ZR,_  -> [],zr vA,"^i0",[rC],fmt vC "i1"
    | _,ZR  -> [rA],fmt vA "i0","^i1",[],zr vC
    | _,_   -> [rA],fmt vA "i0","^i1",[rC],fmt vC "i2"

    let store memo v rA rB kr s = match v,kr,s with
    | V32,K 0,S_NOEXT ->
        let rA,fA,fB = str_arg1 V32 rA in
        { empty_ins with
          memo=memo ^ " " ^ fA ^",["^fB^"]";
          inputs=rA@[rB;]; reg_env=[rB,voidstar]@add_w rA; }
    | V32,K k, s ->
        let rA,fA,fB = str_arg1 V32 rA in
        let shift = match s with
        | S_NOEXT -> ""
        | s -> "," ^ pp_shifter s in
        { empty_ins with
          memo=memo ^ sprintf " %s,[%s,#%i%s]" fA fB k shift;
          inputs=rA@[rB]; reg_env=[rB,voidstar;]@add_w rA; }
    | V32,RV (V32,rC),s ->
        let rA,fA,fB,rC,fC = str_arg2 V32 rA V32 rC in
        let shift = match s with
        | S_NOEXT -> ",sxtw"
        | s -> "," ^ pp_shifter s in
        { empty_ins with
          memo=memo^ sprintf " %s,[%s,%s%s]" fA fB fC shift;
          inputs=rA@[rB;]@rC; reg_env=add_w rC@[rB,voidstar]@add_w rA; }
    | V64,K 0,S_NOEXT ->
        let rA,fA,fB = str_arg1 V64 rA in
        { empty_ins with
          memo=memo ^ sprintf " %s,[%s]" fA fB;
          inputs=rA@[rB]; reg_env=[rB,voidstar;]@add_q  rA; }
    | V64,K k,s ->
        let rA,fA,fB = str_arg1 V64 rA in
        let shift = match s with
        | S_NOEXT -> ""
        | s -> "," ^ pp_shifter s in
        { empty_ins with
          memo=memo ^ sprintf " %s,[%s,#%i%s]" fA fB k shift;
          inputs=rA@[rB]; reg_env=[rB,voidstar;]@add_q  rA; }
    | V64,RV (V64,rC),s ->
        let rA,fA,fB,rC,fC = str_arg2 V64 rA V64 rC in
        let shift = match s with
        | S_NOEXT -> ""
        | s -> "," ^ pp_shifter s in
        { empty_ins with
          memo=memo ^ sprintf " %s,[%s,%s%s]" fA fB fC shift;
          inputs=rA@[rB;]@rC; reg_env=add_q rC@[rB,voidstar;]@add_q rA; }
    | V64,RV (V32,rC),s ->
        let rA,fA,fB,rC,fC = str_arg2 V64 rA V32 rC in
        let shift = match s with
        | S_NOEXT -> ",sxtw"
        | s -> "," ^ pp_shifter s in
        { empty_ins with
          memo=memo ^ sprintf " %s,[%s,%s%s]" fA fB fC shift;
          inputs=rA@[rB;]@rC; reg_env=add_w rC@[rB,voidstar;]@add_q rA; }
    | V32,RV (V64,rC),s ->
        let rA,fA,fB,rC,fC = str_arg2 V32 rA V64 rC in
        let shift = match s with
        | S_NOEXT -> ""
        | s -> "," ^ pp_shifter s in
        { empty_ins with
          memo=memo ^ sprintf " %s,[%s,%s%s]" fA fB fC shift;
          inputs=rA@[rB;]@rC; reg_env=add_q rC@[rB,voidstar;]@add_w  rA; }
    | V128,_,_
    | _,RV (V128,_),_ ->
        assert false

    let store_post memo v rA rB s = match v,s with
    | V32, k ->
        let rA,fA,fB = str_arg1 V32 rA in
        { empty_ins with
          memo=memo ^ sprintf " %s,[%s],#%i" fA fB k;
          outputs=[rB;]; inputs=rA@[rB]; reg_env=[rB,voidstar;]@add_w rA; }
    | V64, k ->
        let rA,fA,fB = str_arg1 V64 rA in
        { empty_ins with
          memo=memo ^ sprintf " %s,[%s],#%i" fA fB k;
          outputs=[rB;]; inputs=rA@[rB]; reg_env=[rB,voidstar;]@add_q  rA; }
    | V128,_ ->
        assert false


    let stxr memo v r1 r2 r3 = match v with
    | V32 ->
        let r2,f2,f3 = str_arg1 V32 r2 in
        { empty_ins with
          memo = sprintf "%s ^wo0,%s,[%s]" memo f2 f3 ;
          inputs = r2@[r3;];
          outputs = [r1;]; reg_env=[r3,voidstar; r1,word;]@add_w r2; }
    | V64 ->
        let r2,f2,f3 = str_arg1 V64 r2 in
        { empty_ins with
          memo = sprintf "%s ^wo0,%s,[%s]" memo f2 f3;
          inputs = r2@[r3;];
          outputs = [r1;]; reg_env=[r3,voidstar; r1,word;]@add_q r2}
    | V128 -> assert false

(* Neon Extension Load and Store *)

    let print_simd_reg io offset i r = match r with
    | Vreg (_,s) -> "^" ^ io ^ string_of_int (i+offset) ^
      (try Misc.lowercase (List.assoc s arrange_specifier) with Not_found -> assert false)
    | _ -> assert false

    let print_vecreg v io i = "^" ^ (match v with
    | VSIMD8 -> "b"
    | VSIMD16 -> "h"
    | VSIMD32 -> "s"
    | VSIMD64 -> "d"
    | VSIMD128 -> "q")
    ^ io ^ string_of_int i

    let print_simd_list rs io offset =
       String.concat "," (List.mapi (print_simd_reg io offset) rs)

    let load_simd memo v r1 r2 k os = match k,os with
    | K 0,S_NOEXT ->
      { empty_ins with
        memo = sprintf "%s %s,[^i0]" memo (print_vecreg v "o" 0);
        inputs = [r2];
        outputs = [r1];
        reg_env = [(r1,int128);(r2,voidstar)]}
    | K k,S_NOEXT ->
      { empty_ins with
        memo = sprintf "%s %s,[^i0,#%i]" memo (print_vecreg v "o" 0) k;
        inputs = [r2];
        outputs = [r1];
        reg_env = [(r1,int128);(r2,voidstar)]}
    | RV (V32,rk),S_NOEXT ->
      { empty_ins with
        memo = sprintf "%s %s,[^i0,^wi1]" memo (print_vecreg v "o" 0);
        inputs = [r2;rk;];
        outputs = [r1];
        reg_env = [(r1,int128);(r2,voidstar);(rk,word)]}
    | RV (V32,rk),s ->
      { empty_ins with
        memo = sprintf "%s %s,[^i0,^wi1,%s]" memo (print_vecreg v "o" 0) (pp_shifter s);
        inputs = [r2;rk;];
        outputs = [r1];
        reg_env = [(r1,int128);(r2,voidstar);(rk,word)]}
    | RV (V64,rk), S_NOEXT ->
      { empty_ins with
        memo = sprintf "%s %s,[^i0,^i1]" memo (print_vecreg v "o" 0);
        inputs = [r2;rk;];
        outputs = [r1];
        reg_env = [(r1,int128);(r2,voidstar);(rk,quad)]}
    | RV (V64,rk), s ->
      { empty_ins with
        memo = sprintf "%s %s,[^i0,^i1,%s]" memo (print_vecreg v "o" 0) (pp_shifter s);
        inputs = [r2;rk;];
        outputs = [r1];
        reg_env = [(r1,int128);(r2,voidstar);(rk,quad)]}
    | _ -> assert false

    let load_simd_p v r1 r2 k =
      { empty_ins with
        memo = sprintf "ldr %s, [^i0],#%i" (print_vecreg v "o" 0) k;
        inputs = [r2];
        outputs = [r1];
        reg_env = [(r1,int128);(r2,voidstar)]}

    let load_simd_s memo rs i rA kr = match kr with
    | K 0 ->
        { empty_ins with
          memo = sprintf "%s {%s}[%i],[^i0]" memo (print_simd_list rs "i" 1) i;
          inputs = rA::rs;
          outputs = [];
          reg_env = (add_128 rs) @ [(rA,voidstar)]}
    | K k ->
        { empty_ins with
          memo = sprintf "%s {%s}[%i],[^i0],#%i" memo (print_simd_list rs "i" 1) i k;
          inputs = rA::rs;
          outputs = [];
          reg_env = (add_128 rs) @ [(rA,voidstar)]}
    | RV (V64,rB) ->
        { empty_ins with
          memo = sprintf "%s {%s}[%i],[^i0],^i1" memo (print_simd_list rs "i" 2) i;
          inputs = [rA;rB;]@rs;
          outputs = [];
          reg_env = (add_128 rs) @ [(rA,voidstar);(rB,quad)]}
    | _ -> Warn.fatal "Illegal form of %s instruction" memo

    let load_simd_m memo rs rA kr = match kr with
    | K 0 ->
        { empty_ins with
          memo = sprintf "%s {%s},[^i0]" memo (print_simd_list rs "o" 0);
          inputs = [rA];
          outputs = rs;
          reg_env = (add_128 rs) @ [(rA,voidstar)]}
    | K k ->
        { empty_ins with
          memo = sprintf "%s {%s},[^i0],#%i" memo (print_simd_list rs "o" 0) k;
          inputs = [rA];
          outputs = rs;
          reg_env = (add_128 rs) @ [(rA,voidstar)]}
    | RV (V64,rB) ->
        { empty_ins with
          memo = sprintf "%s {%s},[^i0],^i1" memo (print_simd_list rs "o" 0);
          inputs=[rA;rB;];
          outputs = rs;
          reg_env = (add_128 rs) @ [(rA,voidstar);(rB,quad)]}
    | _ -> Warn.fatal "Illegal form of %s instruction" memo

    let load_pair_simd memo v r1 r2 r3 k = match v,k with
    | VSIMD32,0 ->
        { empty_ins with
          memo = sprintf "%s %s,%s,[^i0]" memo (print_vecreg VSIMD32 "o" 0) (print_vecreg VSIMD32 "o" 1);
          inputs=[r3];
          outputs=[r1;r2;];
          reg_env= (add_128 [r1;r2;]) @ [(r3,voidstar)]}
    | VSIMD32,k ->
        { empty_ins with
          memo = sprintf "%s %s,%s,[^i0,#%i]" memo (print_vecreg VSIMD32 "o" 0) (print_vecreg VSIMD32 "o" 1) k;
          inputs=[r3];
          outputs=[r1;r2;];
          reg_env= (add_128 [r1;r2;]) @ [(r3,voidstar)]}
    | VSIMD64,0 ->
        { empty_ins with
          memo = sprintf "%s %s,%s,[^i0]" memo (print_vecreg VSIMD64 "o" 0) (print_vecreg VSIMD64 "o" 1);
          inputs=[r3];
          outputs=[r1;r2;];
          reg_env= (add_128 [r1;r2;]) @ [(r3,voidstar)]}
    | VSIMD64,k ->
        { empty_ins with
          memo = sprintf "%s %s,%s,[^i0,#%i]" memo (print_vecreg VSIMD64 "o" 0) (print_vecreg VSIMD64 "o" 1) k;
          inputs=[r3];
          outputs=[r1;r2;];
          reg_env= (add_128 [r1;r2;]) @ [(r3,voidstar)]}
    | VSIMD128,0 ->
        { empty_ins with
          memo = sprintf "%s %s,%s,[^i0]" memo (print_vecreg VSIMD128 "o" 0) (print_vecreg VSIMD128 "o" 1);
          inputs=[r3];
          outputs=[r1;r2;];
          reg_env= (add_128 [r1;r2;]) @ [(r3,voidstar)]}
    | VSIMD128,k ->
        { empty_ins with
          memo = sprintf "%s %s,%s,[^i0,#%i]" memo (print_vecreg VSIMD128 "o" 0) (print_vecreg VSIMD128 "o" 1) k;
          inputs=[r3];
          outputs=[r1;r2;];
          reg_env= (add_128 [r1;r2;]) @ [(r3,voidstar)]}
    | _, _ -> assert false

    let load_pair_p_simd memo v r1 r2 r3 k = match v with
    | VSIMD32 ->
        { empty_ins with
          memo = sprintf "%s %s,%s,[^i0],#%i" memo (print_vecreg VSIMD32 "o" 0) (print_vecreg VSIMD32 "o" 1) k;
          inputs=[r3];
          outputs=[r1;r2;];
          reg_env= (add_128 [r1;r2;]) @ [(r3,voidstar)]}
    | VSIMD64 ->
        { empty_ins with
          memo = sprintf "%s %s,%s,[^i0],#%i" memo (print_vecreg VSIMD64 "o" 0) (print_vecreg VSIMD64 "o" 1) k;
          inputs=[r3];
          outputs=[r1;r2;];
          reg_env= (add_128 [r1;r2;]) @ [(r3,voidstar)]}
    | VSIMD128 ->
        { empty_ins with
          memo = sprintf "%s %s,%s,[^i0],#%i" memo (print_vecreg VSIMD128 "o" 0) (print_vecreg VSIMD128 "o" 1) k;
          inputs=[r3];
          outputs=[r1;r2;];
          reg_env= (add_128 [r1;r2;]) @ [(r3,voidstar)]}
    | _ -> assert false

    let store_simd memo v r1 r2 k os = match k,os with
    | K 0,S_NOEXT ->
      { empty_ins with
        memo = sprintf "%s %s,[^i1]" memo (print_vecreg v "i" 0);
        inputs = [r1;r2];
        outputs = [];
        reg_env = [(r1,int128);(r2,voidstar)]}
    | K k,S_NOEXT ->
      { empty_ins with
        memo = sprintf "%s %s,[^i1,#%i]" memo (print_vecreg v "i" 0) k;
        inputs = [r1;r2];
        outputs = [];
        reg_env = [(r1,int128);(r2,voidstar)]}
    | RV (V32,rk),S_NOEXT ->
      { empty_ins with
        memo = sprintf "%s %s,[^i1,^wi2]" memo (print_vecreg v "i" 0);
        inputs = [r1;r2;rk];
        outputs = [];
        reg_env = [(r1,int128);(r2,voidstar);(rk,word)]}
    | RV (V32,rk),s ->
      { empty_ins with
        memo = sprintf "%s %s,[^i1,^wi2,%s]" memo (print_vecreg v "i" 0) (pp_shifter s);
        inputs = [r1;r2;rk];
        outputs = [];
        reg_env = [(r1,int128);(r2,voidstar);(rk,word)]}
    | RV (V64,rk),S_NOEXT ->
      { empty_ins with
        memo = sprintf "%s %s,[^i1,^i2]" memo (print_vecreg v "i" 0);
        inputs = [r1;r2;rk];
        outputs = [];
        reg_env = [(r1,int128);(r2,voidstar);(rk,quad)]}
    | RV (V64,rk),s ->
      { empty_ins with
        memo = sprintf "%s %s,[^i1,^i2,%s]" memo (print_vecreg v "i" 0) (pp_shifter s);
        inputs = [r1;r2;rk];
        outputs = [];
        reg_env = [(r1,int128);(r2,voidstar);(rk,quad)]}
    | _ -> assert false

    let store_simd_p v r1 r2 k1 =
      { empty_ins with
        memo = sprintf "str %s, [^i1],%i" (print_vecreg v "i" 0) k1;
        inputs = [r1;r2];
        outputs = [];
        reg_env = [(r1,int128);(r2,voidstar)]}

    let store_simd_s memo rs i rA kr = match kr with
    | K 0 ->
        { empty_ins with
          memo = sprintf "%s {%s}[%i],[^i0]" memo (print_simd_list rs "i" 1) i;
          inputs = rA :: rs;
          reg_env = (add_128 rs) @ [(rA,voidstar)]}
    | K k ->
        { empty_ins with
          memo = sprintf "%s {%s}[%i],[^i0],#%i" memo (print_simd_list rs "i" 1) i k;
          inputs = rA :: rs;
          reg_env = (add_128 rs) @ [(rA,voidstar)]}
    | RV (V64,rB) ->
        { empty_ins with
          memo = sprintf "%s {%s}[%i],[^i0],^i1" memo (print_simd_list rs "i" 2) i;
          inputs = [rA;rB;] @ rs;
          reg_env = (add_128 rs) @ [(rA,voidstar);(rB,quad)]}
    | _ -> Warn.fatal "Illegal form of %s instruction" memo

    let store_simd_m memo rs rA kr = match kr with
    | K 0 ->
      { empty_ins with
        memo = sprintf "%s {%s},[^i0]" memo (print_simd_list rs "i" 1);
        inputs = rA :: rs;
        reg_env = [(rA,voidstar)] @ (add_128 rs)}
    | K k ->
      { empty_ins with
        memo = sprintf "%s {%s},[^i0],#%i" memo (print_simd_list rs "i" 1) k;
        inputs = rA :: rs;
        reg_env = [(rA,voidstar)] @ (add_128 rs)}
    | RV (V64,rB) ->
      { empty_ins with
        memo = sprintf "%s {%s},[^i0],^i1" memo (print_simd_list rs "i" 2);
        inputs = [rA;rB;] @ rs;
        reg_env = [(rA,voidstar);(rB,quad)] @ (add_128 rs)}
    | _ -> Warn.fatal "Illegal form of %s instruction" memo

    let store_pair_simd memo v r1 r2 r3 k = match v,k with
    | VSIMD32,0 ->
        { empty_ins with
          memo = sprintf "%s %s,%s,[^i2]" memo (print_vecreg VSIMD32 "i" 0) (print_vecreg VSIMD32 "i" 1);
          inputs = [r1;r2;r3];
          outputs = [];
          reg_env = (add_128 [r1;r2;]) @ [(r3,voidstar)]}
    | VSIMD32,k ->
        { empty_ins with
          memo = sprintf "%s %s,%s,[^i2,#%i]" memo (print_vecreg VSIMD32 "i" 0) (print_vecreg VSIMD32 "i" 1) k;
          inputs = [r1;r2;r3];
          outputs = [];
          reg_env = (add_128 [r1;r2;]) @ [(r3,voidstar)]}
    | VSIMD64,0 ->
        { empty_ins with
          memo = sprintf "%s %s,%s,[^i2]" memo (print_vecreg VSIMD64 "i" 0) (print_vecreg VSIMD64 "i" 1);
          inputs = [r1;r2;r3];
          outputs = [];
          reg_env = (add_128 [r1;r2;]) @ [(r3,voidstar)]}
    | VSIMD64,k ->
        { empty_ins with
          memo = sprintf "%s %s,%s,[^i2,#%i]" memo (print_vecreg VSIMD64 "i" 0) (print_vecreg VSIMD64 "i" 1) k;
          inputs = [r1;r2;r3];
          outputs = [];
          reg_env = (add_128 [r1;r2;]) @ [(r3,voidstar)]}
    | VSIMD128,0 ->
        { empty_ins with
          memo = sprintf "%s %s,%s,[^i2]" memo (print_vecreg VSIMD128 "i" 0) (print_vecreg VSIMD128 "i" 1);
          inputs = [r1;r2;r3];
          outputs = [];
          reg_env = (add_128 [r1;r2;]) @ [(r3,voidstar)]}
    | VSIMD128,k ->
        { empty_ins with
          memo = sprintf "%s %s,%s,[^i2,#%i]" memo (print_vecreg VSIMD128 "i" 0) (print_vecreg VSIMD128 "i" 1) k;
          inputs = [r1;r2;r3];
          outputs = [];
          reg_env = (add_128 [r1;r2;]) @ [(r3,voidstar)]}
    | _,_ -> assert false

    let store_pair_p_simd memo v r1 r2 r3 k = match v with
    | VSIMD32 ->
        { empty_ins with
          memo = sprintf "%s %s,%s,[^i2],#%i" memo (print_vecreg VSIMD32 "i" 0) (print_vecreg VSIMD32 "i" 1) k;
          inputs = [r1;r2;r3];
          outputs = [];
          reg_env = (add_128 [r1;r2;]) @ [(r3,voidstar)]}
    | VSIMD64 ->
        { empty_ins with
          memo = sprintf "%s %s,%s,[^i2],#%i" memo (print_vecreg VSIMD64 "i" 0) (print_vecreg VSIMD64 "i" 1) k;
          inputs = [r1;r2;r3];
          outputs = [];
          reg_env = (add_128 [r1;r2;]) @ [(r3,voidstar)]}
    | VSIMD128 ->
        { empty_ins with
          memo = sprintf "%s %s,%s,[^i2],#%i" memo (print_vecreg VSIMD128 "i" 0) (print_vecreg VSIMD128 "i" 1) k;
          inputs = [r1;r2;r3];
          outputs = [];
          reg_env = (add_128 [r1;r2;]) @ [(r3,voidstar)]}
    | _ -> assert false

    let mov_simd_ve r1 i1 r2 i2 =
      { empty_ins with
        memo = sprintf "mov %s[%i], %s[%i]" (print_simd_reg "o" 0 0 r1) i1 (print_simd_reg "i" 0 0 r2) i2;
        inputs = [r2];
        outputs = [r1];
        reg_env = (add_128 [r1;r2;]);}

    let mov_simd_v r1 r2 =
      { empty_ins with
        memo = sprintf "mov %s, %s" (print_simd_reg "o" 0 0 r1) (print_simd_reg "i" 0 0 r2);
        inputs = [r2];
        outputs = [r1];
        reg_env = (add_128 [r1;r2]);}

    let mov_simd_s v r1 r2 i =
      { empty_ins with
        memo = sprintf "mov %s, %s[%i]" (print_vecreg v "o" 0) (print_simd_reg "i" 0 0 r2) i;
        inputs = [r2];
        outputs = [r1];
        reg_env = (add_128 [r1;r2])}

    let mov_simd_tg v r1 r2 i =
      { empty_ins with
        memo = sprintf "mov %s, %s[%i]"
          (match v with | V32 -> "^wo0" | V64 -> "^o0" | V128 -> assert false)
          (print_simd_reg "i" 0 0 r2)
          i;
        inputs = [r2];
        outputs = [r1];
        reg_env = ((match v with
          | V32 -> add_w
          | V64 -> add_q
          | V128 -> assert false)
        [r1;]) @ (add_128 [r2;])}

    let mov_simd_fg r1 i v r2 =
      { empty_ins with
        memo = sprintf "mov %s[%i],%s"
          (print_simd_reg "i" 0 0 r1)
          i
          (match v with | V32 -> "^wi1" | V64 -> "^i1" | V128 -> assert false);
        inputs = [r1;r2];
        outputs = [];
        reg_env = (add_128 [r1;]) @ ((
          match v with
          | V32 -> add_w
          | V64 -> add_q
          | V128 -> assert false) [r2;])}

    let movi_s v r k = match v with
    | VSIMD64 ->
      { empty_ins with
        memo = sprintf "movi %s, #%i" (print_vecreg v "o" 0) k;
        inputs = [];
        outputs = [r;];
        reg_env = (add_128 [r])}
    | _ -> assert false

    let movi_v r k s = match s with
    | S_NOEXT ->
      { empty_ins with
        memo = sprintf "movi %s,#%i" (print_simd_reg "o" 0 0 r) k;
        inputs = [];
        outputs = [r;];
        reg_env = (add_128 [r])}
    | S_LSL(ks) ->
      { empty_ins with
        memo = sprintf "movi %s,#%i,%s" (print_simd_reg "o" 0 0 r) k (pp_shifter (S_LSL ks));
        inputs = [];
        outputs = [r;];
        reg_env = (add_128 [r])}
    | S_MSL(ks) ->
      { empty_ins with
        memo = sprintf "movi %s,#%i,%s" (print_simd_reg "o" 0 0 r) k (pp_shifter (S_MSL ks));
        inputs = [];
        outputs = [r;];
        reg_env = (add_128 [r])}
    | _ -> assert false

    let eor_simd r1 r2 r3 =
      { empty_ins with
        memo = sprintf "eor %s,%s,%s" (print_simd_reg "o" 0 0 r1) (print_simd_reg "i" 0 0 r2) (print_simd_reg "i" 0 1 r3);
        inputs = [r2;r3;];
        outputs = [r1];
        reg_env = (add_128 [r1;r2;r3;])}

    let add_simd r1 r2 r3 =
      { empty_ins with
        memo = sprintf "add %s,%s,%s" (print_simd_reg "o" 0 0 r1) (print_simd_reg "i" 0 0 r2) (print_simd_reg "i" 0 1 r3);
        inputs = [r2;r3];
        outputs = [r1];
        reg_env = (add_128 [r1;r2;r3;])}

    let add_simd_s r1 r2 r3 =
      { empty_ins with
        memo = sprintf "add %s,%s,%s" (print_vecreg VSIMD64 "o" 0) (print_vecreg VSIMD64 "i" 0) (print_vecreg VSIMD64 "i" 1);
        inputs = [r2;r3;];
        outputs = [r1];
        reg_env = (add_128 [r1;r2;r3;])}

(* Compare and swap *)
    let type_of_variant = function
      | V32 -> word | V64 -> quad | V128 -> assert false

    let cas_memo rmw = Misc.lowercase (cas_memo rmw)
    let casp_memo rmw = Misc.lowercase (casp_memo rmw)
    let casbh_memo bh rmw = Misc.lowercase (casbh_memo bh rmw)

    let cas memo v r1 r2 r3 =
      let t = type_of_variant v in
      let r1,f1,r2,f2 = match v with
      | V32 -> args2 "wzr" (fun s -> "^wi"^s) r1 r2
      | V64 -> args2 "xzr" (fun s -> "^i"^s) r1 r2
      | V128 -> assert false in
      let idx = match r1,r2 with
      | [],[] -> "0"
      | (_::_,[])|([],_::_) -> "1"
      | _::_,_::_ -> "2" in
      { empty_ins with
        memo = sprintf "%s %s,%s,[^i%s]" memo f1 f2 idx;
        inputs = r1@r2@[r3]; outputs = r1;
        reg_env = (r3,voidstar)::add_type t (r1@r2); }

    let casp memo v r1 r2 r3 r4 r5 =
      let t = type_of_variant v in
      let rs1,rs2,rs3,rs4,rs5 = match v with
      (* How to output even consecutive registers? *)
      (* Assembler needs this proprty*)
      | V32 -> "^wi0","^wi1","^wi2","^wi3", "^i4"
      | V64 -> "^i0", "^i1", "^i2", "^i3", "^i4"
      | V128 -> assert false in
      { empty_ins with
        memo = sprintf "%s %s,%s,%s,%s,[%s]" memo rs1 rs2 rs3 rs4 rs5;
        inputs = [r1;r2;r3;r4;r5]; outputs = [r1;r2;r3;r4;r5];
        reg_env = (r5,voidstar)::add_type t [r1;r2;r3;r4]@add_type quad [r5] }

(* Swap *)
    let swp_memo rmw = Misc.lowercase (swp_memo rmw)
    let swpbh_memo bh rmw = Misc.lowercase (swpbh_memo bh rmw)

    let swp memo v r1 r2 r3 =
      let t = type_of_variant v in
      let r1,f1 =
        match v with
        |  V32 -> arg1 "wzr" (fun s -> "^wi"^s) r1
        |  V64 -> arg1 "xzr" (fun s -> "^i"^s) r1
        |  V128 -> assert false in
      let idx = match r1 with | [] -> "0" | _::_ -> "1" in
      let r2,f2 =
        match v with
        |  V32 -> arg1 "wzr" (fun s -> "^wo"^s) r2
        |  V64 -> arg1 "xzr" (fun s -> "^o"^s) r2
        |  V128 -> assert false in
      { empty_ins with
        memo = sprintf "%s %s,%s,[^i%s]" memo f1 f2 idx;
        inputs = r1@[r3;]; outputs =r2;
        reg_env = (r3,voidstar)::add_type t (r1@r2); }

(* Fetch and Op *)
    let ldop_memo op rmw = Misc.lowercase (ldop_memo op rmw)
    let stop_memo op w = Misc.lowercase (stop_memo op w)
    let ldopbh_memo op bh rmw =  Misc.lowercase (ldopbh_memo op bh rmw)
    let stopbh_memo op bh w =  Misc.lowercase (stopbh_memo op bh w)

    let ldop memo v rs rt rn =
      let t = match v with | V32 -> word | V64 -> quad | V128 -> assert false in
      let rs,fs = match v with
      |  V32 -> arg1 "wzr" (fun s -> "^wi"^s) rs
      |  V64 -> arg1 "xzr" (fun s -> "^i"^s) rs
      |  V128 -> assert false in
      let idx = match rs with | [] -> "0" | _::_ -> "1" in
      let rt,ft =  match v with
      |  V32 -> arg1 "wzr" (fun s -> "^wo"^s) rt
      |  V64 -> arg1 "xzr" (fun s -> "^o"^s) rt
      |  V128 -> assert false in
      { empty_ins with
        memo = sprintf "%s %s,%s,[^i%s]" memo fs ft idx;
        inputs = rs@[rn]; outputs = rt;
        reg_env = (rn,voidstar)::add_type t (rs@rt);}

    let stop memo v rs rn =
      let t = match v with | V32 -> word | V64 -> quad | V128 -> assert false in
      let rs,fs = match v with
      |  V32 -> arg1 "wzr" (fun s -> "^wi"^s) rs
      |  V64 -> arg1 "xzr" (fun s -> "^i"^s) rs
      |  V128 -> assert false in
      let idx = match rs with | [] -> "0" | _::_ -> "1" in
      { empty_ins with
        memo = sprintf "%s %s,[^i%s]" memo fs idx;
        inputs = rs@[rn]; outputs = [];
        reg_env = (rn,voidstar)::add_type t rs;}

(* Arithmetic *)
    let mov_const v r k =
      let memo =
        sprintf
          (match v with
            | V32 ->  "mov ^wo0,#%i"
            | V64 ->  "mov ^o0,#%i"
            | V128 -> assert false)
          k in
      { empty_ins with memo; outputs=[r;];
        reg_env = ((match v with
          | V32 -> add_w
          | V64 -> add_q
          | V128 -> assert false)
        [r;])}

    let adr tr_lab r lbl =
      let _,lbl = dump_tgt tr_lab lbl in
      let r,f = arg1 "xzr" (fun s -> "^o"^s) r in
      { empty_ins with
        memo = sprintf "adr %s,%s" f lbl;
        outputs=r; reg_env=add_v r; }

    let do_movr memo v r1 r2 = match v with
    | V32 ->
        let r1,f1 = arg1 "wzr" (fun s -> "^wo"^s) r1
        and r2,f2 = arg1 "wzr" (fun s -> "^wi"^s) r2 in
        { empty_ins with
          memo=sprintf "%s %s,%s" memo f1 f2;
          inputs = r2; outputs=r1; reg_env=add_w (r1@r2);}
    | V64 ->
        let r1,f1 = arg1 "xzr" (fun s -> "^o"^s) r1
        and r2,f2 = arg1 "xzr" (fun s -> "^i"^s) r2 in
        { empty_ins with
          memo=sprintf "%s %s,%s" memo f1 f2;
          inputs = r2; outputs=r1; reg_env=add_q (r1@r2);}
    | V128 -> assert false

    (* First 'fi' argument computes inputs from outputs *)
    let do_movz fi memo v rd k os =
      match v, k, os with
    | V32, k, S_LSL(s) ->
        let r1,f1 = arg1 "wzr" (fun s -> "^wo"^s) rd in
        { empty_ins with
          memo=sprintf "%s %s, #%d, %s" memo f1 k (pp_shifter (S_LSL s));
          inputs=fi r1; outputs=r1; reg_env=add_w r1;}
    | V32,  k, S_NOEXT ->
        let r1,f1 = arg1 "wzr" (fun s -> "^wo"^s) rd in
        { empty_ins with
          memo=sprintf "%s %s, #%d" memo f1 k;
          inputs=fi r1; outputs=r1; reg_env=add_w r1;}
    | V64, k, S_LSL(s) ->
        let r1,f1 = arg1 "xzr" (fun s -> "^o"^s) rd in
        { empty_ins with
          memo=sprintf "%s %s, #%d, %s" memo f1 k (pp_shifter (S_LSL s));
          inputs=fi r1; outputs=r1; reg_env=add_q r1;}
    | V64, k, S_NOEXT ->
        let r1,f1 = arg1 "xzr" (fun s -> "^o"^s) rd in
        { empty_ins with
          memo=sprintf "%s %s, #%d" memo f1 k;
          inputs=fi r1; outputs=r1; reg_env=add_q r1;}
    | _ -> Warn.fatal "Illegal form of %s instruction" memo

    let movr = do_movr "mov"
    and rbit = do_movr "rbit"
    and movz = do_movz (fun _ -> []) (* No input *) "movz"
    and movk = do_movz Misc.identity (* Part of register preserved *) "movk"


    let sxtw r1 r2 =
      { empty_ins with
        memo = "sxtw ^o0,^wi0";
        inputs = [r2;]; outputs=[r1;]; reg_env=[r1,quad; r2,word];}

    let xbfm s v r1 r2 k1 k2 = match v with
    | V32 ->
        let r1,fm1,r2,fm2 = args2 "wzr" (fun s -> "^wi"^s) r1 r2 in
        let rs = r1 @ r2 in
        { empty_ins with
          memo = sprintf "%s %s,%s,#%i,#%i" s fm1 fm2 k1 k2;
          inputs = rs; reg_env=List.map (fun r -> r,word) rs;}
    | V64 ->
        let r1,fm1,r2,fm2 = args2 "xzr" (fun s -> "^i"^s) r1 r2 in
        let rs = r1 @ r2 in
        { empty_ins with
          memo = sprintf "%s %s,%s,#%i,#%i" s fm1 fm2 k1 k2;
          inputs = rs; reg_env=List.map (fun r -> r,quad) rs;}
    | V128 -> assert false

    let cmpk v r k = match v with
    | V32 ->
        { empty_ins with
          memo = sprintf "cmp ^wi0,#%i" k ;
          inputs = [r;]; reg_env=[r,word];}
    | V64 ->
        { empty_ins with
          memo = sprintf "cmp ^i0,#%i" k ;
          inputs = [r;]; reg_env=[r,quad;];}
    | V128 -> assert false

    let cmp v r1 r2 s = match v with
    | V32 ->
        let r1,fm1,r2,fm2 = args2 "wzr" (fun s -> "^wi"^s) r1 r2 in
        let shift = Misc.lowercase (pp_barrel_shift "," s pp_imm) in
        let rs = r1 @ r2 in
        { empty_ins with
          memo = sprintf "cmp %s,%s%s" fm1 fm2 shift;
          inputs = rs; reg_env=List.map (fun r -> r,word) rs; }
    | V64 ->
        let r1,fm1,r2,fm2 = args2 "xzr" (fun s -> "^i"^s) r1 r2 in
        let shift = Misc.lowercase (pp_barrel_shift "," s pp_imm) in
        let rs = r1 @ r2 in
        { empty_ins with
          memo = sprintf "cmp %s,%s%s" fm1 fm2 shift;
          inputs = rs; reg_env=List.map (fun r -> r,quad) rs; }
    | V128 -> assert false

    let tst v r i =
      let add,(r,f) =  match v with
      | V32 -> add_w,arg1 "wzr" (fun s -> "^wo"^s) r
      | V64 -> add_q,arg1 "xzr" (fun s -> "^o"^s) r
      | V128 -> assert false in
      { empty_ins with
        memo = sprintf "tst %s,#%i" f i;
        outputs=r; reg_env = add r;}

    let memo_of_op op = Misc.lowercase (pp_op op)

    let mvn v r1 r2 =
      let memo = "mvn" in
      match v with
      | V32 ->
          let r1,f1 = arg1 "wzr" (fun s -> "^wo"^s) r1
          and r2,f2 = arg1 "wzr" (fun s -> "^wi"^s) r2 in
          { empty_ins with
            memo=sprintf "%s %s,%s" memo f1 f2;
            inputs=r2;
            outputs=r1; reg_env = add_w (r1@r2);}
      | V64 ->
          let r1,f1 = arg1 "xzr" (fun s -> "^o"^s) r1
          and r2,f2 = arg1 "xzr" (fun s -> "^i"^s) r2 in
          { empty_ins with
            memo=sprintf "%s %s,%s" memo f1 f2;
            inputs=r2;
            outputs=r1; reg_env = add_q (r1@r2);}
      | V128 -> assert false

    let op3 v op rD rA kr s =
      let memo = memo_of_op op in
      let shift = Misc.lowercase (pp_barrel_shift "," s pp_imm) in
      match v,kr with
      | V32,K k ->
          let rD,fD = arg1 "wzr" (fun s -> "^wo"^s) rD
          and rA,fA = arg1 "wzr" (fun s -> "^wi"^s) rA in
          { empty_ins with
            memo=sprintf "%s %s,%s,#%i%s" memo fD fA k shift;
            inputs=rA;
            outputs=rD; reg_env = add_w (rA@rD);}
      | V32,RV (V32,rB) ->
          let rD,fD = arg1 "wzr" (fun s -> "^wo"^s) rD
          and rA,fA,rB,fB = args2 "wzr"  (fun s -> "^wi"^s) rA rB in
          let inputs = rA@rB in
          { empty_ins with
            memo=sprintf "%s %s,%s,%s%s" memo fD fA fB shift;
            inputs=inputs;
            outputs=rD; reg_env = add_w (rD@inputs);}
      | V64,K k ->
          let rD,fD = arg1 "xzr" (fun s -> "^o"^s) rD
          and rA,fA = arg1 "xzr" (fun s -> "^i"^s) rA in
          { empty_ins with
            memo=sprintf "%s %s,%s,#%i%s" memo fD fA k shift;
            inputs=rA;
            outputs=rD; reg_env = add_q (rA@rD);}
      | V64,RV (V64,rB) ->
          let rD,fD = arg1 "xzr" (fun s -> "^o"^s) rD
          and rA,fA,rB,fB = args2 "xzr"  (fun s -> "^i"^s) rA rB in
          let inputs = rA@rB in
          { empty_ins with
            memo=sprintf "%s %s,%s,%s%s" memo fD fA fB shift;
            inputs=inputs;
            outputs=rD; reg_env=add_q (inputs@rD);}
      | V64,RV (V32,rB) ->
          let rD,fD = arg1 "xzr" (fun s -> "^o"^s) rD
          and rA,fA = arg1 "xzr"  (fun s -> "^i"^s) rA in
          let rB,fB = match rB with
          | ZR -> [],"wzr"
          | _ -> begin match rA with
            | [] -> [rB],"^wi0"
            | _ -> [rB],"^wi1"
          end in
          { empty_ins with
            memo=sprintf "%s %s,%s,%s%s" memo fD fA fB shift;
            inputs=rA@rB;
            outputs=rD; reg_env=add_q (rD@rA)@add_w rB; }
      | V32,RV (V64,_) -> assert false
      | V128,_
      | _,RV (V128,_) -> assert false

    let fence f =
      { empty_ins with memo = Misc.lowercase (A.pp_barrier f); }

    let cache memo r =
      match r with
      | ZR ->
          { empty_ins with memo; }
      | _ ->
          let r,f = arg1 "xzr" (fun s -> "^i"^s) r in
          { empty_ins with memo = memo ^ "," ^ f; inputs=r; reg_env=add_v r; }

    let tlbi op r =
      let op = Misc.lowercase  (TLBI.pp_op op) in
      match r with
      | ZR ->
          { empty_ins with memo = sprintf "tlbi %s" op; inputs=[]; reg_env=[]; }
      | r ->
          { empty_ins with memo = sprintf "tlbi %s,^i0" op; inputs=[r]; reg_env=add_v [r]; }

(* Not that useful *)
    let emit_loop _k = assert false

    let tr_ins ins =
      match ins.[String.length ins-1] with
      | ':' ->
         let lab = String.sub ins 0 (String.length ins-1) in
         { empty_ins with memo = ins; label = Some lab; }
      | _ -> { empty_ins with memo = ins; }

    let map_ins = List.map tr_ins

    type ins = A.Out.ins

    let max_handler_label = 1 (* Warning label 0 no other is used in handler code *)

    let user_mode has_handler p =
      let ins =
        (fun k ->
          "msr sp_el0,%[sp_usr]"
          ::"adr %[tr0],0f"
          ::"msr elr_el1,%[tr0]"
          ::"msr spsr_el1,xzr"
          ::"eret"
          ::"0:"
          ::k)
          (if has_handler then [sprintf "adr x29,asm_handler%d" p;] else []) in
      map_ins ins

    let kernel_mode has_handler =
      map_ins
        ((fun k -> if has_handler then "adr x29,0f"::k else k)
           ["svc #471";])

    let fault_handler_prologue _is_user p =
      map_ins ["b 0f"; sprintf  "asm_handler%d:" p;]

    and fault_handler_epilogue is_user code =
      let ins =
        if
          List.exists
            (fun i -> i.memo = "eret")
            code
        then [] (* handler is complete *)
        else if Precision.is_skip C.precision then
          [ "mrs %[tr0],elr_el1" ;
            "add %[tr0],%[tr0],#4" ;
            "msr elr_el1,%[tr0]" ;
            "eret" ]
        else if Precision.is_fatal C.precision then
          (if is_user then []
           else
             [ "adr %[tr0],0f";
               "msr elr_el1,%[tr0]";
               "eret" ])
        else
          [ "eret" ] in
      let ins = map_ins ins in
      ins@[ {empty_ins with memo="0:"; label=Some "0"; } ]

      let compile_ins tr_lab ins k = match ins with
    | I_NOP -> { empty_ins with memo = "nop"; }::k
(* Branches *)
    | I_B lbl -> b tr_lab lbl::k
    | I_BR r -> br r::k
    | I_BL lbl -> bl tr_lab lbl::k
    | I_BLR r -> blr r::k
    | I_RET None -> { empty_ins with memo="ret"; }::k
    | I_RET (Some r) -> ret r::k
    | I_ERET -> { empty_ins with memo="eret"; }::k
    | I_BC (c,lbl) -> bcc tr_lab c lbl::k
    | I_CBZ (v,r,lbl) -> cbz tr_lab "cbz" v r lbl::k
    | I_CBNZ (v,r,lbl) -> cbz tr_lab "cbnz" v r lbl::k
    | I_TBNZ (v,r,k2,lbl) -> tbz tr_lab "tbnz" v r k2 lbl::k
    | I_TBZ (v,r,k2,lbl) -> tbz tr_lab "tbz" v r k2 lbl::k
(* Load and Store *)
    | I_LDR (v,r1,r2,kr,os) -> load "ldr" v r1 r2 kr os::k
    | I_LDUR (v,r1,r2,Some(k')) -> load "ldur" v r1 r2 (K k') S_NOEXT ::k
    | I_LDUR (v,r1,r2,None) -> load "ldur" v r1 r2 (K 0) S_NOEXT ::k
    | I_LDR_P (v,r1,r2,k1) -> load_p "ldr" v r1 r2 k1::k
    | I_LDP (t,v,r1,r2,r3,kr,md) ->
        load_pair (match t with TT -> "ldp" | NT -> "ldnp") v r1 r2 r3 kr md::k
    | I_LDPSW (r1,r2,r3,kr,md) ->
       ldpsw r1 r2 r3 kr md::k
    | I_LDXP (v,t,r1,r2,r3) ->
       loadx_pair (Misc.lowercase (ldxp_memo t)) v r1 r2 r3::k
    | I_STP (t,v,r1,r2,r3,kr,md) ->
        store_pair (match t with TT -> "stp" | NT -> "stnp") v r1 r2 r3 kr md::k
    | I_STXP (v,t,r1,r2,r3,r4) ->
        storex_pair (Misc.lowercase (stxp_memo t)) v r1 r2 r3 r4::k
    | I_LDRBH (B,r1,r2,kr,s) -> load "ldrb" V32 r1 r2 kr (default_shift kr s)::k
    | I_LDRBH (H,r1,r2,kr,s) -> load "ldrh" V32 r1 r2 kr (default_shift kr s)::k
    | I_LDRS (var,B,r1,r2) -> load "ldrsb" var r1 r2 (K 0) (default_shift (K 0) S_NOEXT)::k
    | I_LDRS (var,H,r1,r2) -> load "ldrsh" var r1 r2 (K 0) (default_shift (K 0) S_NOEXT)::k
    | I_LDAR (v,t,r1,r2) -> load (ldr_memo t) v r1 r2 k0 S_NOEXT::k
    | I_LDARBH (bh,t,r1,r2) -> load (ldrbh_memo bh t) V32 r1 r2 k0 S_NOEXT::k
    | I_STR (v,r1,r2,kr, s) -> store "str" v r1 r2 kr s::k
    | I_STRBH (B,r1,r2,kr,s) -> store "strb" V32 r1 r2 kr s::k
    | I_STRBH (H,r1,r2,kr,s) -> store "strh" V32 r1 r2 kr s::k
    | I_STR_P (v,r1,r2,s) -> store_post "str" v r1 r2 s::k
    | I_STLR (v,r1,r2) -> store "stlr" v r1 r2 k0 S_NOEXT::k
    | I_STLRBH (B,r1,r2) -> store "stlrb" V32 r1 r2 k0 S_NOEXT::k
    | I_STLRBH (H,r1,r2) -> store "stlrh" V32 r1 r2 k0 S_NOEXT::k
    | I_STXR (v,t,r1,r2,r3) -> stxr (str_memo t) v r1 r2 r3::k
    | I_STXRBH (bh,t,r1,r2,r3) -> stxr (strbh_memo bh t) V32 r1 r2 r3::k
    | I_CAS (v,rmw,r1,r2,r3) -> cas (cas_memo rmw) v r1 r2 r3::k
    | I_CASP (v,rmw,r1,r2,r3,r4,r5) -> casp (casp_memo rmw) v r1 r2 r3 r4 r5::k
    | I_CASBH (bh,rmw,r1,r2,r3) -> cas (casbh_memo bh rmw) V32 r1 r2 r3::k
    | I_SWP (v,rmw,r1,r2,r3) -> swp (swp_memo rmw) v r1 r2 r3::k
    | I_SWPBH (bh,rmw,r1,r2,r3) -> swp (swpbh_memo bh rmw) V32 r1 r2 r3::k
(* Neon Extension Load and Store *)
    | I_LD1 (r1,i,r2,kr) -> load_simd_s "ld1" [r1] i r2 kr::k
    | I_LD1M (rs,r2,kr) -> load_simd_m "ld1" rs r2 kr::k
    | I_LD1R (r1,r2,kr) -> load_simd_m "ld1r" [r1] r2 kr::k
    | I_LD2 (rs,i,r2,kr) -> load_simd_s "ld2" rs i r2 kr::k
    | I_LD2M (rs,r2,kr) -> load_simd_m "ld2" rs r2 kr::k
    | I_LD2R (rs,r2,kr) -> load_simd_m "ld2r" rs r2 kr::k
    | I_LD3 (rs,i,r2,kr) -> load_simd_s "ld3" rs i r2 kr::k
    | I_LD3M (rs,r2,kr) -> load_simd_m "ld3" rs r2 kr::k
    | I_LD3R (rs,r2,kr) -> load_simd_m "ld3r" rs r2 kr::k
    | I_LD4 (rs,i,r2,kr) -> load_simd_s "ld4" rs i r2 kr::k
    | I_LD4M (rs,r2,kr) -> load_simd_m "ld4" rs r2 kr::k
    | I_LD4R (rs,r2,kr) -> load_simd_m "ld4r" rs r2 kr::k
    | I_ST1 (r1,i,r2,kr) -> store_simd_s "st1" [r1] i r2 kr::k
    | I_ST1M (rs,r2,kr) -> store_simd_m "st1" rs r2 kr::k
    | I_ST2 (rs,i,r2,kr) -> store_simd_s "st2" rs i r2 kr::k
    | I_ST2M (rs,r2,kr) -> store_simd_m "st2" rs r2 kr::k
    | I_ST3 (rs,i,r2,kr) -> store_simd_s "st3" rs i r2 kr::k
    | I_ST3M (rs,r2,kr) -> store_simd_m "st3" rs r2 kr::k
    | I_ST4 (rs,i,r2,kr) -> store_simd_s "st4" rs i r2 kr::k
    | I_ST4M (rs,r2,kr) -> store_simd_m "st4" rs r2 kr::k
    | I_LDP_SIMD (t,v,r1,r2,r3,kr) ->
        load_pair_simd (match t with TT -> "ldp" | NT -> "ldnp") v r1 r2 r3 kr::k
    | I_STP_SIMD (t,v,r1,r2,r3,kr) ->
        store_pair_simd (match t with TT -> "stp" | NT -> "stnp") v r1 r2 r3 kr::k
    | I_LDP_P_SIMD (t,v,r1,r2,r3,k1) ->
        load_pair_p_simd (match t with TT -> "ldp" | NT -> "ldnp") v r1 r2 r3 k1::k
    | I_STP_P_SIMD (t,v,r1,r2,r3,k1) ->
        store_pair_p_simd (match t with TT -> "stp" | NT -> "stnp") v r1 r2 r3 k1::k
    | I_LDR_SIMD (v,r1,r2,k1,s) -> load_simd "ldr" v r1 r2 k1 s::k
    | I_LDR_P_SIMD (v,r1,r2,k1) -> load_simd_p v r1 r2 k1::k
    | I_STR_SIMD (v,r1,r2,k1,s) -> store_simd "str" v r1 r2 k1 s::k
    | I_STR_P_SIMD (v,r1,r2,k1) -> store_simd_p v r1 r2 k1::k
    | I_LDUR_SIMD (v,r1,r2,Some(k1)) -> load_simd "ldur" v r1 r2 (K k1) S_NOEXT::k
    | I_LDUR_SIMD (v,r1,r2,None) -> load_simd "ldur" v r1 r2 (K 0) S_NOEXT::k
    | I_STUR_SIMD (v,r1,r2,Some(k1)) -> store_simd "stur" v r1 r2 (K k1) S_NOEXT::k
    | I_STUR_SIMD (v,r1,r2,None) -> store_simd "stur" v r1 r2 (K 0) S_NOEXT::k
    | I_MOV_VE (r1,i1,r2,i2) -> mov_simd_ve r1 i1 r2 i2::k
    | I_MOV_V (r1,r2) -> mov_simd_v r1 r2::k
    | I_MOV_FG (r1,i,v,r2) -> mov_simd_fg r1 i v r2::k
    | I_MOV_TG (v,r1,r2,i) -> mov_simd_tg v r1 r2 i::k
    | I_MOVI_S (v,r,k1) -> movi_s v r k1::k
    | I_MOVI_V (r,kr,s) -> movi_v r kr s::k
    | I_MOV_S (v,r1,r2,i) -> mov_simd_s v r1 r2 i::k
    | I_EOR_SIMD (r1,r2,r3) -> eor_simd r1 r2 r3::k
    | I_ADD_SIMD (r1,r2,r3) -> add_simd r1 r2 r3::k
    | I_ADD_SIMD_S (r1,r2,r3) -> add_simd_s r1 r2 r3::k
(* Arithmetic *)
    | I_MOV (v,r,K i) ->  mov_const v r i::k
    | I_MOV (v,r1,RV (_,r2)) ->  movr v r1 r2::k
    | I_MOVZ (v,rd,i,os) -> movz v rd i os::k
    | I_MOVK (v,rd,i,os) -> movk  v rd i os::k
    | I_ADR (r,lbl) -> adr tr_lab r lbl::k
    | I_RBIT (v,rd,rs) -> rbit v rd rs::k
    | I_SXTW (r1,r2) -> sxtw r1 r2::k
    | I_SBFM (v,r1,r2,k1,k2) -> xbfm "sbfm" v r1 r2 k1 k2::k
    | I_UBFM (v,r1,r2,k1,k2) -> xbfm "ubfm" v r1 r2 k1 k2::k
    | I_OP3 (v,SUBS,ZR,r,K i, S_NOEXT) ->  cmpk v r i::k
    | I_OP3 (v,SUBS,ZR,r2,RV (v3,r3), s) when v=v3->  cmp v r2 r3 s::k
    | I_OP3 (v,ANDS,ZR,r,K i, S_NOEXT) -> tst v r i::k
    | I_OP3 (v,ORN,r1,ZR,RV (_,r2),S_NOEXT) -> mvn v r1 r2::k
    | I_OP3 (V64,_,_,_,RV(V32,_),S_NOEXT) ->
        Warn.fatal "Instruction %s is illegal (extension required)"
          (dump_instruction ins)
    | I_OP3 (v,op,r1,r2,kr,s) ->  op3 v op r1 r2 kr s::k
(* Fence *)
    | I_FENCE f -> fence f::k
(* Fetch and Op *)
    |I_LDOP (op,v,rmw,rs,rt,rn) ->
        ldop (ldop_memo op rmw) v rs rt rn::k
    |I_LDOPBH  (op,v,rmw,rs,rt,rn) ->
        ldop (ldopbh_memo op v rmw) V32 rs rt rn::k
    | I_STOP (op,v,w,rs,rn) ->
        stop (stop_memo op w) v rs rn::k
    | I_STOPBH (op,v,w,rs,rn) ->
        stop (stopbh_memo op v w) V32 rs rn::k
(* Conditional selection *)
    | I_CSEL (v,r,ZR,ZR,c,Inc) ->
        let o,f = match v with
        | V32 -> arg1 "wzr" (fun s -> "^wo"^s) r
        | V64 -> arg1 "xzr" (fun s -> "^o"^s) r
        | V128 -> assert false
        and t = match v with V32 -> word | V64 -> quad | V128 -> assert false in
        let memo =
          sprintf "cset %s,%s" f (pp_cond (inverse_cond c)) in
        { empty_ins with memo; outputs=o; reg_env=add_type t o; }::k
    | I_CSEL (v,r1,r2,r3,c,op) ->
        let inputs,memo,t = match v with
        | V32 ->
            let r2,f2,r3,f3 = args2 "wzr" (fun s -> "^wi"^s) r2 r3 in
            r2@r3,sprintf "%s,%s,%s" f2 f3 (pp_cond c),word
        | V64 ->
            let r2,f2,r3,f3 = args2 "xzr" (fun s -> "^i"^s) r2 r3 in
            r2@r3,sprintf "%s,%s,%s" f2 f3 (pp_cond c),quad
        | V128 -> assert false in
        let o,f = match v with
        | V32 -> arg1 "wzr" (fun s -> "^wo"^s) r1
        | V64 -> arg1 "xzr" (fun s -> "^o"^s) r1
        | V128 -> assert false in
        let memo = Misc.lowercase (sel_memo op) ^ " " ^ f ^ "," ^ memo in
        {
         empty_ins with
         memo = memo; inputs=inputs; outputs=o;
         reg_env=add_type t (o@inputs);
       }::k
    | I_IC (op,r) ->
        cache (sprintf "ic %s" (Misc.lowercase (IC.pp_op op))) r::k
    | I_DC (op,r) ->
        cache (sprintf "dc %s" (Misc.lowercase (DC.pp_op op))) r::k
    | I_TLBI (op,r) ->
        tlbi op r::k
    | I_MRS (r,sr) ->
        let r,f = arg1 "xzr" (fun s -> "^o"^s) r in
        let memo =
          sprintf "mrs %s,%s" f (Misc.lowercase (pp_sysreg sr)) in
        {empty_ins with
         memo; outputs=r; reg_env=add_type quad r;}::k
    | I_MSR (sr,r) ->
       let r,f = arg1 "xzr" (fun s -> "^o"^s) r in
       let memo =
         sprintf "msr %s,%s" (Misc.lowercase (pp_sysreg sr)) f in
       {empty_ins with
         memo; outputs=r; reg_env=add_type quad r;}::k
    | I_STG _| I_STZG _|I_LDG _ ->
        Warn.fatal "No litmus output for instruction %s"
          (dump_instruction ins)
    | I_ALIGND _|I_ALIGNU _|I_BUILD _|I_CHKEQ _|I_CHKSLD _|I_CHKTGD _|
      I_CLRTAG _|I_CPYTYPE _|I_CPYVALUE _|I_CSEAL _|I_GC _|I_LDCT _|I_SC _|
      I_SEAL _|I_STCT _|I_UNSEAL _ ->
        Warn.fatal "No litmus output for instruction %s"
            (dump_instruction ins)
    | I_UDF _ ->
        { empty_ins with memo = ".word 0"; }::k

    let no_tr lbl = lbl
    let branch_neq r i lab k = cmpk V32 r i::bcc no_tr NE lab::k
    let branch_eq r i lab k = cmpk V32 r i::bcc no_tr EQ lab::k

    let signaling_write _i _k = Warn.fatal "no signaling write for ARM"

    let emit_tb_wait _ = Warn.fatal "no time base for ARM"
  end
