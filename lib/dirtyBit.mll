(****************************************************************************)
(*                           the diy toolsuite                              *)
(*                                                                          *)
(* Jade Alglave, University College London, UK.                             *)
(* Luc Maranget, INRIA Paris France.                                        *)
(*                                                                          *)
(* Copyright 2020-present Institut National de Recherche en Informatique et *)
(* en Automatique and the authors. All rights reserved.                     *)
(*                                                                          *)
(* This software is governed by the CeCILL-B license under French law and   *)
(* abiding by the rules of distribution of free software. You can use,      *)
(* modify and/ or redistribute the software under the terms of the CeCILL-B *)
(* license as circulated by CEA, CNRS and INRIA at the following URL        *)
(* "http://www.cecill.info". We also give a copy in LICENSE.txt.            *)
(****************************************************************************)

{
 type t =
    {
     tthm : Proc.t -> bool;
     ha : Proc.t -> bool;
     hd : Proc.t -> bool;
     some_ha : bool; some_hd : bool;
     all_ha : bool; all_hd : bool;
   }

type my_t = { my_ha : unit -> bool; my_hd : unit -> bool; }

type nat = HA | HD | SW

exception Error

}

let num = ['0'-'9']+
let blank = [' ''\t''\r']
rule all k = parse
|('P'? (num as x) ':')?
 (['a'-'z''A'-'Z']+ as key)
 {
  let proc = Misc.app_opt int_of_string x
  and f = match Misc.lowercase key with
  | "sw" -> SW
  | "ha" -> HA
  | "hd" -> HD
  | _ -> Warn.user_error "'%s' is not a dirty bit managment key, keys are SW,HA,HD" key in
  all ((proc,f)::k) lexbuf }
| blank+ { all k lexbuf }
| eof { k }
| "" { raise Error }

{

let soft =
  let f _ = false in
  { tthm=f; ha=f; hd=f;
    some_ha=false; some_hd=false;
    all_ha=false; all_hd=false; }

let get info =
 match
   MiscParser.get_info_on_info
     MiscParser.tthm_key info
 with
 | None -> None
 | Some s ->
    try
      let xs = all [] (Lexing.from_string s) in
      let has = List.filter (function (_,(HA|HD)) -> true | _ -> false) xs
      and hds = List.filter (function (_,HD) -> true | _ -> false) xs in
      let soft =
        List.filter_map
          (function (Some _ as p,SW) -> p | _ -> None)
          xs in
      let tthm p = not (List.exists (Misc.int_eq p) soft) in
      let all_ha,ha =
        if List.exists (function (None,(HA|HD)) -> true | _ -> false) has then
          true,fun _ -> true
        else
          let xs =
            List.filter_map
              (function (Some _ as p,(HA|HD)) -> p | _ -> None)
              has in
          false,fun proc -> List.exists (Misc.int_eq proc) xs
      and all_hd,hd =
        if List.exists (function (None,HD) -> true | _ -> false) hds then
          true,(fun _ -> true)
        else
          let xs =
            List.filter_map
              (function (Some _ as p,HD) -> p | _ -> None)
              hds in
          false,fun proc -> List.exists (Misc.int_eq proc) xs in
      Some
        {tthm; ha; hd;
         some_ha=Misc.consp has; some_hd=Misc.consp hds;
         all_ha; all_hd; }
    with Error ->
      Warn.user_error "Incorrect dirty bit managment specification '%s'" s
}
