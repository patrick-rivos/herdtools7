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

(* Conditions inside logs, a simplified Constraint module *)

open MiscParser
open ConstrGen
open Printf

type constr = MiscParser.constr

let foralltrue =  ForallStates (And [])

module SL = StateLexer.Make(struct let debug = false end)

let parse s = 
  try
    let lxb = Lexing.from_string s in
    Some (StateParser.skip_loc_constr SL.token lxb)
  with
  | Parsing.Parse_error
  | LexMisc.Error _ -> None

let pp_atom a =
  match a with
  | LV (l,v) -> MiscParser.pp_atom (l,v)
  | LL (l1,l2) ->
      sprintf "%s=%s"
        (MiscParser.dump_location l1)
        (MiscParser.dump_location l2)

  
let dump_prop chan = ConstrGen.dump_prop pp_atom chan
let dump chan = ConstrGen.dump_constraints chan pp_atom


let get_locs_atom a =
  match a with
  | LV (loc,_) -> LocSet.add loc
  | LL (loc1,loc2) ->
      (fun k -> LocSet.add loc1 (LocSet.add loc2 k))

let get_locs c = fold_constr get_locs_atom c LocSet.empty

let parse_observed s = 
  try
    let lxb = Lexing.from_string s in
    let locs,c = StateParser.loc_constr SL.token lxb in
    Some
      (LocSet.union
         (LocSet.of_list (List.map fst locs))
         (get_locs c))
  with
  | Parsing.Parse_error
  | LexMisc.Error _ -> None

let parse_locs_cond lxb =
  try
    let locs,c = StateParser.loc_constr SL.token lxb in
    Some (locs,c)
  with
  | Parsing.Parse_error
  | LexMisc.Error _ -> None


let parse_locs s = 
  try
    let lxb = Lexing.from_string s in
    let locs,cstr = StateParser.loc_constr SL.token lxb in
    Some (LocSet.union (LocSet.of_list (List.map fst locs)) (get_locs cstr))
  with
  | Parsing.Parse_error
  | LexMisc.Error _ -> None


(* Code duplication? (with constraints) oh well! *)

module type I = sig
  type v

  type state

  val state_mem : state -> MiscParser.location -> v -> bool
  val state_eqloc : state -> MiscParser.location -> MiscParser.location -> bool
end

module Make(I:I) : sig

  type state = I.state
  type prop =  (MiscParser.location, I.v) ConstrGen.prop
  type constr = prop ConstrGen.constr

(* check proposition *)
  val check_prop : prop -> state -> bool
(* validation *)
  val validate : constr -> state list -> bool
(* Return witness of interest / total number of outcomes *)
  val witness : constr -> (state * Int64.t) list -> Int64.t * Int64.t

end  =
  struct

    type state = I.state
    type prop =  (MiscParser.location, I.v) ConstrGen.prop
    type constr = prop ConstrGen.constr


    let rec check_prop p state = match p with
    | Atom (LV (l,v)) -> I.state_mem state l v
    | Atom (LL (l1,l2)) -> I.state_eqloc state l1 l2
    | Not p -> not (check_prop p state)
    | And ps -> List.for_all (fun p -> check_prop p state) ps
    | Or ps -> List.exists (fun p -> check_prop p state) ps
    | Implies (p1, p2) -> 
        if check_prop p1 state then check_prop p2 state else true
          
    let check_constr c states = match c with
    | ForallStates p -> List.for_all (fun s -> check_prop p s) states
    | ExistsState p -> List.exists (fun s -> check_prop p s) states
    | NotExistsState p ->
        not (List.exists (fun s -> check_prop p s) states)	      

    let validate = check_constr

    let witness c states =
      let p = ConstrGen.prop_of c in
      let pos,neg =
        List.fold_left
          (fun (pos,neg) (st,c) ->
            if check_prop p st then
              Int64.add c pos, neg
            else
              pos,Int64.add c neg)
          (Int64.zero,Int64.zero) states in
      match c with
      | ExistsState _
      | NotExistsState _
        ->
          pos,neg
      | ForallStates _ ->
          neg,pos


  end
