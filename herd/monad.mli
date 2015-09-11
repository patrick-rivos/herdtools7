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

(** A monad for event structures *)

(* Define a monad, which is a composition of event set state and a single variable state 
   (to pick new eiids *)

module type S =
  sig
    module A     : Arch.S

    module E : Event.S 
	   with module Act.A = A

    module VC    : Valconstraint.S      
	   with type atom = A.V.v
	    and type cst = A.V.cst
	    and type solution = A.V.solution
	    and type location = A.location
	    and type state = A.state

    type 'a t
	  
    val zeroT        : 'a t
    val unitT        : 'a -> 'a t
    val (>>=) : 'a t -> ('a -> 'b t) -> ('b) t
    val (>>*=) : 'a t -> ('a -> 'b t) -> ('b) t
    val exch : 'a t -> 'a t -> ('a -> 'b t) ->  ('a -> 'b t) ->  ('b * 'b) t
    val stu : 'a t -> 'a t -> ('a -> unit t) -> (('a * 'a) -> unit t) -> unit t
    val (>>>) : 'a t -> ('a -> 'b t) -> 'b t
    val (>>|) : 'a t -> 'b t -> ('a * 'b)  t
    val (>>::) : 'a t -> 'a list t -> 'a list t
    val (|*|)   : unit t -> unit t -> unit t   (* Cross product *)
    val lockT : 'a t -> 'a t
    val forceT : 'a -> 'b t -> 'a t
    val (>>!) : 'a t -> 'b -> 'b t

    val discardT : 'a t -> unit t
    val addT : 'a -> 'b t -> ('a * 'b) t
    val filterT : A.V.v -> A.V.v t -> A.V.v t
    val choiceT : A.V.v -> 'a t -> 'a t -> 'a t  
    val altT : 'a t -> 'a t -> 'a t 
    val neqT : A.V.v -> A.V.v -> unit t 

    val tooFar : string -> 'a t

    (* read_loc mk_action loc ii:  
       for each value v that could be read,
       make an event structure comprising a single event with
       instruction id "ii", and action "mk_action v loc". *)
    val read_loc : (A.location -> A.V.v -> E.action) -> 
		   A.location -> A.inst_instance_id -> A.V.v t
                       
    (* mk_singleton_es a ii: 
       make an event structure comprising a single event with
       instruction id "ii", and action "a". *)
    val mk_singleton_es : E.action -> A.inst_instance_id -> unit t
    val mk_singleton_es_eq : E.action -> VC.cnstrnts -> A.inst_instance_id -> unit t
	

    val op1 : Op.op1 -> A.V.v -> A.V.v t
    val op : Op.op -> A.V.v -> A.V.v -> A.V.v t
    val op3 : Op.op3 -> A.V.v -> A.V.v -> A.V.v -> A.V.v t
    val add : A.V.v -> A.V.v -> A.V.v t

(* Buid evt structure for fetch_and_op *)
    val fetch :
        Op.op -> A.V.v -> (A.V.v -> A.V.v -> E.action) -> 
	  A.inst_instance_id -> A.V.v t

    val assign : A.V.v -> A.V.v -> unit t

    val initwrites : (A.location * A.V.v) list -> unit t

(* Read out monad *)
    type evt_struct
    type output = VC.cnstrnts * evt_struct

    val get_output  : 'a t -> output list
  end


