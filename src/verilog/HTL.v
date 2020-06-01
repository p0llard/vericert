(*
 * CoqUp: Verified high-level synthesis.
 * Copyright (C) 2020 Yann Herklotz <yann@yannherklotz.com>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *)

From Coq Require Import FSets.FMapPositive.
From coqup Require Import Coquplib Value AssocMap.
From coqup Require Verilog.
From compcert Require Events Globalenvs Smallstep Integers.
From compcert Require Import Maps.

Import HexNotationValue.

(** The purpose of the hardware transfer language (HTL) is to create a more
hardware-like layout that is still similar to the register transfer language
(RTL) that it came from. The main change is that function calls become module
instantiations and that we now describe a state machine instead of a
control-flow graph. *)

Definition reg := positive.
Definition node := positive.

Definition datapath := PTree.t Verilog.stmnt.
Definition controllogic := PTree.t Verilog.stmnt.

Record module: Type :=
  mkmodule {
    mod_params : list reg;
    mod_datapath : datapath;
    mod_controllogic : controllogic;
    mod_entrypoint : node;
    mod_st : reg;
    mod_finish : reg;
    mod_return : reg
  }.

Definition fundef := AST.fundef module.

Definition program := AST.program fundef unit.

(** * Operational Semantics *)

Definition genv := Globalenvs.Genv.t fundef unit.

Inductive state : Type :=
| State :
    forall (m : module)
           (st : node)
           (assoc : assocmap),
  state
| Returnstate : forall v : value, state.

Inductive step : genv -> state -> Events.trace -> state -> Prop :=
| step_module :
    forall g t m st ctrl data assoc0 assoc1 assoc2 assoc3 nbassoc0 nbassoc1 f stval pstval,
      m.(mod_controllogic)!st = Some ctrl ->
      m.(mod_datapath)!st = Some data ->
      Verilog.stmnt_runp f
        (Verilog.mkassociations assoc0 empty_assocmap)
        ctrl
        (Verilog.mkassociations assoc1 nbassoc0) ->
      Verilog.stmnt_runp f
        (Verilog.mkassociations assoc1 nbassoc0)
        data
        (Verilog.mkassociations assoc2 nbassoc1) ->
      assoc3 = merge_assocmap nbassoc1 assoc2 ->
      assoc3!(m.(mod_st)) = Some stval ->
      valueToPos stval = pstval ->
      step g (State m st assoc0) t (State m pstval assoc3)
| step_finish :
    forall g t m st assoc retval,
    assoc!(m.(mod_finish)) = Some (1'h"1") ->
    assoc!(m.(mod_return)) = Some retval ->
    step g (State m st assoc) t (Returnstate retval).
Hint Constructors step : htl.

Inductive initial_state (p: program): state -> Prop :=
  | initial_state_intro: forall b m0 st m,
      let ge := Globalenvs.Genv.globalenv p in
      Globalenvs.Genv.init_mem p = Some m0 ->
      Globalenvs.Genv.find_symbol ge p.(AST.prog_main) = Some b ->
      Globalenvs.Genv.find_funct_ptr ge b = Some (AST.Internal m) ->
      st = m.(mod_entrypoint) ->
      initial_state p (State m st empty_assocmap).

Inductive final_state : state -> Integers.int -> Prop :=
| final_state_intro : forall retval retvali,
    value_int_eqb retval retvali = true ->
    final_state (Returnstate retval) retvali.

Definition semantics (m : program) :=
  Smallstep.Semantics step (initial_state m) final_state (Globalenvs.Genv.globalenv m).
