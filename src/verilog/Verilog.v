(*
 * CoqUp: Verified high-level synthesis.
 * Copyright (C) 2019-2020 Yann Herklotz <yann@yannherklotz.com>
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

From Coq Require Import
  Structures.OrderedTypeEx
  FSets.FMapPositive
  Program.Basics
  PeanoNat
  ZArith
  Lists.List
  Program.

Import ListNotations.

From coqup Require Import common.Coquplib common.Show verilog.Value AssocMap.
From compcert Require Integers Events.
From compcert Require Import Errors Smallstep Globalenvs.

Import HexNotationValue.
Import AssocMapNotation.

Definition reg : Type := positive.
Definition node : Type := positive.
Definition szreg : Type := reg * nat.

Record associations : Type :=
  mkassociations {
    assoc_blocking : assocmap;
    assoc_nonblocking : assocmap
  }.

(** * Verilog AST

The Verilog AST is defined here, which is the target language of the
compilation.

** Value

The Verilog [value] is a bitvector containg a size and the actual bitvector. In
this case, the [Word.word] type is used as many theorems about that bitvector
have already been proven. *)

(** ** Binary Operators

These are the binary operations that can be represented in Verilog. Ideally,
multiplication and division would be done by custom modules which could al so be
scheduled properly. However, for now every Verilog operator is assumed to take
one clock cycle. *)

Inductive binop : Type :=
| Vadd : binop  (** addition (binary [+]) *)
| Vsub : binop  (** subtraction (binary [-]) *)
| Vmul : binop  (** multiplication (binary [*]) *)
| Vdiv : binop  (** division (binary [/]) *)
| Vdivu : binop  (** division unsigned (binary [/]) *)
| Vmod : binop  (** remainder ([%]) *)
| Vmodu : binop  (** remainder unsigned ([%]) *)
| Vlt : binop   (** less than ([<]) *)
| Vltu : binop   (** less than unsigned ([<]) *)
| Vgt : binop   (** greater than ([>]) *)
| Vgtu : binop   (** greater than unsigned ([>]) *)
| Vle : binop   (** less than or equal ([<=]) *)
| Vleu : binop   (** less than or equal unsigned ([<=]) *)
| Vge : binop   (** greater than or equal ([>=]) *)
| Vgeu : binop   (** greater than or equal unsigned ([>=]) *)
| Veq : binop   (** equal to ([==]) *)
| Vne : binop   (** not equal to ([!=]) *)
| Vand : binop  (** and (binary [&]) *)
| Vor : binop   (** or (binary [|]) *)
| Vxor : binop  (** xor (binary [^|]) *)
| Vshl : binop  (** shift left ([<<]) *)
| Vshr : binop. (** shift right ([>>]) *)

(** ** Unary Operators *)

Inductive unop : Type :=
| Vneg  (** negation ([~]) *)
| Vnot. (** not operation [!] *)

(** ** Expressions *)

Inductive expr : Type :=
| Vlit : value -> expr
| Vvar : reg -> expr
| Vinputvar : reg -> expr
| Vbinop : binop -> expr -> expr -> expr
| Vunop : unop -> expr -> expr
| Vternary : expr -> expr -> expr -> expr.

Definition posToExpr (sz : nat) (p : positive) : expr :=
  Vlit (posToValue sz p).

(** ** Statements *)

Inductive stmnt : Type :=
| Vskip : stmnt
| Vseq : stmnt -> stmnt -> stmnt
| Vcond : expr -> stmnt -> stmnt -> stmnt
| Vcase : expr -> list (expr * stmnt) -> option stmnt -> stmnt
| Vblock : expr -> expr -> stmnt
| Vnonblock : expr -> expr -> stmnt.

(** ** Edges

These define when an always block should be triggered, for example if the always
block should be triggered synchronously at the clock edge, or asynchronously for
combinational logic.

[edge] is not part of [stmnt] in this formalisation because is closer to the
semantics that are used. *)

Inductive edge : Type :=
| Vposedge : reg -> edge
| Vnegedge : reg -> edge
| Valledge : edge
| Voredge : edge -> edge -> edge.

(** ** Module Items

Module items can either be declarations ([Vdecl]) or always blocks ([Valways]).
The declarations are always register declarations as combinational logic can be
done using combinational always block instead of continuous assignments. *)

Inductive module_item : Type :=
| Vdecl : reg -> nat -> module_item
| Valways : edge -> stmnt -> module_item
| Valways_ff : edge -> stmnt -> module_item
| Valways_comb : edge -> stmnt -> module_item.

(** The main module type containing all the important control signals

- [mod_start] If set, starts the computations in the module.
- [mod_reset] If set, reset the state in the module.
- [mod_clk] The clock that controls the computation in the module.
- [mod_args] The arguments to the module.
- [mod_finish] Bit that is set if the result is ready.
- [mod_return] The return value that was computed.
- [mod_body] The body of the module, including the state machine.
*)

Record module : Type := mkmodule {
  mod_start : szreg;
  mod_reset : szreg;
  mod_clk : szreg;
  mod_finish : szreg;
  mod_return : szreg;
  mod_state : szreg; (**r Variable that defines the current state, it should be internal. *)
  mod_args : list szreg;
  mod_body : list module_item;
                        }.
(** Convert a [positive] to an expression directly, setting it to the right
    size. *)
Definition posToLit (p : positive) : expr :=
  Vlit (posToValueAuto p).

Coercion Vlit : value >-> expr.
Coercion Vvar : reg >-> expr.

Definition fext := PositiveMap.t value.
Definition fextclk := nat -> fext.

(** ** State

The [state] contains the following items:

- Current [module] that is being worked on, so that the state variable can be
retrieved and set appropriately.
- Current [module_item] which is being worked on.
- A contiunation ([cont]) which defines what to do next.  The option is to
  either evaluate another module item or go to the next clock cycle.  Finally
  it could also end if the finish flag of the module goes high.
- Association list containing the blocking assignments made, or assignments made
  in previous clock cycles.
- Nonblocking association list containing all the nonblocking assignments made
  in the current module.
- The environment containing values for the input.
- The program counter which determines the value for the state in this version of
  Verilog, as the Verilog was generated by the RTL, which means that we have to
  make an assumption about how it looks.  In this case, that it contains state
  which determines which part of the Verilog is executed.  This is then the part
  of the Verilog that should match with the RTL. *)

Inductive state : Type :=
| State:
    forall (m : module)
           (assoc : assocmap)
           (nbassoc : assocmap)
           (f : fextclk)
           (cycle : nat)
           (stvar : value),
    state
| Finishstate:
    forall v : value,
    state.

Definition binop_run (op : binop) : forall v1 v2 : value, vsize v1 = vsize v2 -> value :=
  match op with
  | Vadd => vplus
  | Vsub => vminus
  | Vmul => vmul
  | Vdiv => vdivs
  | Vdivu => vdiv
  | Vmod => vmods
  | Vmodu => vmod
  | Vlt => vlts
  | Vltu => vlt
  | Vgt => vgts
  | Vgtu => vgt
  | Vle => vles
  | Vleu => vle
  | Vge => vges
  | Vgeu => vge
  | Veq => veq
  | Vne => vne
  | Vand => vand
  | Vor => vor
  | Vxor => vxor
  | Vshl => vshl
  | Vshr => vshr
  end.

Definition unop_run (op : unop) : value -> value :=
  match op with
  | Vneg => vnot
  | Vnot => vbitneg
  end.

Inductive expr_runp : fext -> assocmap -> expr -> value -> Prop :=
  | erun_Vlit :
      forall fext assoc v,
      expr_runp fext assoc (Vlit v) v
  | erun_Vvar_empty :
      forall fext assoc r sz,
      assoc!r = None ->
      expr_runp fext assoc (Vvar r) (ZToValue sz 0)
  | erun_Vvar :
      forall fext assoc v r,
      assoc!r = Some v ->
      expr_runp fext assoc (Vvar r) v
  | erun_Vinputvar :
      forall fext assoc r v,
      fext!r = Some v ->
      expr_runp fext assoc (Vinputvar r) v
  | erun_Vbinop :
      forall fext assoc op l r lv rv oper EQ resv,
      expr_runp fext assoc l lv ->
      expr_runp fext assoc r rv ->
      oper = binop_run op ->
      resv = oper lv rv EQ ->
      expr_runp fext assoc (Vbinop op l r) resv
  | erun_Vunop :
      forall fext assoc u vu op oper resv,
      expr_runp fext assoc u vu ->
      oper = unop_run op ->
      resv = oper vu ->
      expr_runp fext assoc (Vunop op u) resv
  | erun_Vternary_true :
      forall fext assoc c ts fs vc vt,
      expr_runp fext assoc c vc ->
      expr_runp fext assoc ts vt ->
      valueToBool vc = true ->
      expr_runp fext assoc (Vternary c ts fs) vt
  | erun_Vternary_false :
      forall fext assoc c ts fs vc vf,
      expr_runp fext assoc c vc ->
      expr_runp fext assoc fs vf ->
      valueToBool vc = false ->
      expr_runp fext assoc (Vternary c ts fs) vf.
Hint Constructors expr_runp : verilog.

Definition handle_opt {A : Type} (err : errmsg) (val : option A)
  : res A :=
  match val with
  | Some a => OK a
  | None => Error err
  end.

Definition handle_def {A : Type} (a : A) (val : option A)
  : res A :=
  match val with
  | Some a' => OK a'
  | None => OK a
  end.

Local Open Scope error_monad_scope.

Definition access_fext (f : fext) (r : reg) : res value :=
  match PositiveMap.find r f with
  | Some v => OK v
  | _ => OK (ZToValue 1 0)
  end.

(* TODO FIX Vvar case without default *)
(*Fixpoint expr_run (assoc : assocmap) (e : expr)
         {struct e} : res value :=
  match e with
  | Vlit v => OK v
  | Vvar r => match s with
              | State _ assoc _ _ _ => handle_def (ZToValue 32 0) assoc!r
              | _ => Error (msg "Verilog: Wrong state")
              end
  | Vinputvar r => access_fext s r
  | Vbinop op l r =>
    let lv := expr_run s l in
    let rv := expr_run s r in
    let oper := binop_run op in
    do lv' <- lv;
    do rv' <- rv;
    handle_opt (msg "Verilog: sizes are not equal")
               (eq_to_opt lv' rv' (oper lv' rv'))
  | Vunop op e =>
    let oper := unop_run op in
    do ev <- expr_run s e;
    OK (oper ev)
  | Vternary c te fe =>
    do cv <- expr_run s c;
    if valueToBool cv then expr_run s te else expr_run s fe
  end.*)

(** Return the name of the lhs of an assignment. For now, this function is quite
simple because only assignment to normal variables is supported and needed. *)

Definition assign_name (e : expr) : res reg :=
  match e with
  | Vvar r => OK r
  | _ => Error (msg "Verilog: expression not supported on lhs of assignment")
  end.

(*Fixpoint stmnt_height (st : stmnt) {struct st} : nat :=
  match st with
  | Vseq s1 s2 => S (stmnt_height s1 + stmnt_height s2)
  | Vcond _ s1 s2 => S (Nat.max (stmnt_height s1) (stmnt_height s2))
  | Vcase _ ls (Some st) =>
    S (fold_right (fun t acc => Nat.max acc (stmnt_height (snd t))) 0%nat ls)
  | _ => 1
  end.

Fixpoint find_case_stmnt (s : state) (v : value) (cl : list (expr * stmnt))
         {struct cl} : option (res stmnt) :=
  match cl with
  | (e, st)::xs =>
    match expr_run s e with
    | OK v' =>
      match eq_to_opt v v' (veq v v') with
      | Some eq => if valueToBool eq then Some (OK st) else find_case_stmnt s v xs
      | None => Some (Error (msg "Verilog: equality check sizes not equal"))
      end
    | Error msg => Some (Error msg)
    end
  | _ => None
  end.

Fixpoint stmnt_run' (n : nat) (s : state) (st : stmnt) {struct n} : res state :=
  match n with
  | S n' =>
    match st with
    | Vskip => OK s
    | Vseq s1 s2 =>
      do s' <- stmnt_run' n' s s1;
      stmnt_run' n' s' s2
    | Vcond c st sf =>
      do cv <- expr_run s c;
      if valueToBool cv
      then stmnt_run' n' s st
      else stmnt_run' n' s sf
    | Vcase e cl defst =>
      do v <- expr_run s e;
      match find_case_stmnt s v cl with
      | Some (OK st') => stmnt_run' n' s st'
      | Some (Error msg) => Error msg
      | None => do s' <- handle_opt (msg "Verilog: no case was matched")
                                    (option_map (stmnt_run' n' s) defst); s'
      end
    | Vblock lhs rhs =>
      match s with
      | State m assoc nbassoc f c =>
        do name <- assign_name lhs;
        do rhse <- expr_run s rhs;
        OK (State m (PositiveMap.add name rhse assoc) nbassoc f c)
      | _ => Error (msg "Verilog: Wrong state")
      end
    | Vnonblock lhs rhs =>
      match s with
      | State m assoc nbassoc f c =>
        do name <- assign_name lhs;
        do rhse <- expr_run s rhs;
        OK (State m assoc (PositiveMap.add name rhse nbassoc) f c)
      | _ => Error (msg "Verilog: Wrong state")
      end
    end
  | _ => OK s
  end.

Definition stmnt_run (s : state) (st : stmnt) : res state :=
  stmnt_run' (stmnt_height st) s st. *)

Inductive stmnt_runp: fext -> associations -> stmnt -> associations -> Prop :=
| stmnt_runp_Vskip:
    forall f a, stmnt_runp f a Vskip a
| stmnt_runp_Vseq:
    forall f st1 st2 as0 as1 as2,
    stmnt_runp f as0 st1 as1 ->
    stmnt_runp f as1 st2 as2 ->
    stmnt_runp f as0 (Vseq st1 st2) as2
| stmnt_runp_Vcond_true:
    forall as0 as1 f c vc stt stf,
    expr_runp f as0.(assoc_blocking) c vc ->
    valueToBool vc = true ->
    stmnt_runp f as0 stt as1 ->
    stmnt_runp f as0 (Vcond c stt stf) as1
| stmnt_runp_Vcond_false:
    forall as0 as1 f c vc stt stf,
    expr_runp f as0.(assoc_blocking) c vc ->
    valueToBool vc = false ->
    stmnt_runp f as0 stf as1 ->
    stmnt_runp f as0 (Vcond c stt stf) as1
| stmnt_runp_Vcase_nomatch:
    forall e ve as0 f as1 me mve sc cs def,
    expr_runp f as0.(assoc_blocking) e ve ->
    expr_runp f as0.(assoc_blocking) me mve ->
    mve <> ve ->
    stmnt_runp f as0 (Vcase e cs def) as1 ->
    stmnt_runp f as0 (Vcase e ((me, sc)::cs) def) as1
| stmnt_runp_Vcase_match:
    forall e ve as0 f as1 me mve sc cs def,
    expr_runp f as0.(assoc_blocking) e ve ->
    expr_runp f as0.(assoc_blocking) me mve ->
    mve = ve ->
    stmnt_runp f as0 sc as1 ->
    stmnt_runp f as0 (Vcase e ((me, sc)::cs) def) as1
| stmnt_runp_Vcase_default:
    forall as0 as1 f st e ve,
    expr_runp f as0.(assoc_blocking) e ve ->
    stmnt_runp f as0 st as1 ->
    stmnt_runp f as0 (Vcase e nil (Some st)) as1
| stmnt_runp_Vblock:
    forall lhs name rhs rhsval assoc assoc' nbassoc f,
    assign_name lhs = OK name ->
    expr_runp f assoc rhs rhsval ->
    assoc' = (PositiveMap.add name rhsval assoc) ->
    stmnt_runp f (mkassociations assoc nbassoc)
                 (Vblock lhs rhs)
                 (mkassociations assoc' nbassoc)
| stmnt_runp_Vnonblock:
    forall lhs name rhs rhsval assoc nbassoc nbassoc' f,
    assign_name lhs = OK name ->
    expr_runp f assoc rhs rhsval ->
    nbassoc' = (PositiveMap.add name rhsval nbassoc) ->
    stmnt_runp f (mkassociations assoc nbassoc)
                 (Vnonblock lhs rhs)
                 (mkassociations assoc nbassoc').
Hint Constructors stmnt_runp : verilog.

(*Fixpoint mi_step (s : state) (m : list module_item) {struct m} : res state :=
  let run := fun st ls =>
              do s' <- stmnt_run s st;
              mi_step s' ls
  in
  match m with
  | (Valways _ st)::ls => run st ls
  | (Valways_ff _ st)::ls => run st ls
  | (Valways_comb _ st)::ls => run st ls
  | (Vdecl _ _)::ls => mi_step s ls
  | nil => OK s
  end.*)

Inductive mi_stepp : fext -> associations -> module_item -> associations -> Prop :=
| mi_stepp_Valways :
    forall f s0 st s1 c,
    stmnt_runp f s0 st s1 ->
    mi_stepp f s0 (Valways c st) s1
| mi_stepp_Valways_ff :
    forall f s0 st s1 c,
    stmnt_runp f s0 st s1 ->
    mi_stepp f s0 (Valways_ff c st) s1
| mi_stepp_Valways_comb :
    forall f s0 st s1 c,
    stmnt_runp f s0 st s1 ->
    mi_stepp f s0 (Valways_comb c st) s1
| mi_stepp_Vdecl :
    forall f s lhs rhs,
    mi_stepp f s (Vdecl lhs rhs) s.
Hint Constructors mi_stepp : verilog.

Inductive mis_stepp : fext -> associations -> list module_item -> associations -> Prop :=
| mis_stepp_Cons :
    forall f mi mis s0 s1 s2,
    mi_stepp f s0 mi s1 ->
    mis_stepp f s1 mis s2 ->
    mis_stepp f s0 (mi :: mis) s2
| mis_stepp_Nil :
    forall f s,
    mis_stepp f s nil s.
Hint Constructors mis_stepp : verilog.

(*Definition mi_step_commit (s : state) (m : list module_item) : res state :=
  match mi_step s m with
  | OK (State m assoc nbassoc f c) =>
    OK (State m (merge_assocmap nbassoc assoc) empty_assocmap f c)
  | Error msg => Error msg
  | _ => Error (msg "Verilog: Wrong state")
  end.

Fixpoint mi_run (f : fextclk) (assoc : assocmap) (m : list module_item) (n : nat)
         {struct n} : res assocmap :=
  match n with
  | S n' =>
    do assoc' <- mi_run f assoc m n';
    match mi_step_commit (State assoc' empty_assocmap f (Pos.of_nat n')) m with
    | OK (State assoc _ _ _) => OK assoc
    | Error m => Error m
    end
  | O => OK assoc
  end.*)

(** Resets the module into a known state, so that it can be executed.  This is
assumed to be the starting state of the module, and may have to be changed if
other arguments to the module are also to be supported. *)

Definition initial_fextclk (m : module) : fextclk :=
  fun x => match x with
           | S O => (AssocMap.add (fst (mod_reset m)) (ZToValue 1 1) empty_assocmap)
           | _ => (AssocMap.add (fst (mod_reset m)) (ZToValue 1 0) empty_assocmap)
           end.

(*Definition module_run (n : nat) (m : module) : res assocmap :=
  mi_run (initial_fextclk m) empty_assocmap (mod_body m) n.*)

Local Close Scope error_monad_scope.

(*Theorem value_eq_size_if_eq:
  forall lv rv EQ,
  vsize lv = vsize rv -> value_eq_size lv rv = left EQ.
Proof. intros. unfold value_eq_size.

Theorem expr_run_same:
  forall assoc e v, expr_run assoc e = OK v <-> expr_runp assoc e v.
Proof.
  split; generalize dependent v; generalize dependent assoc.
  - induction e.
    + intros. inversion H. constructor.
    + intros. inversion H. constructor. assumption.
    + intros. inversion H. destruct (expr_run assoc e1) eqn:?. destruct (expr_run assoc e2) eqn:?.
      unfold eq_to_opt in H1. destruct (value_eq_size v0 v1) eqn:?. inversion H1.
      constructor. apply IHe1. assumption. apply IHe2. assumption. reflexivity. discriminate. discriminate.
      discriminate.
    + intros. inversion H. destruct (expr_run assoc e) eqn:?. unfold option_map in H1.
      inversion H1. constructor. apply IHe. assumption. reflexivity. discriminate.
    + intros. inversion H. destruct (expr_run assoc e1) eqn:?. destruct (valueToBool v0) eqn:?.
      eapply erun_Vternary_true. apply IHe1. eassumption. apply IHe2. eassumption. assumption.
      eapply erun_Vternary_false. apply IHe1. eassumption. apply IHe3. eassumption. assumption.
      discriminate.
  - induction e.
    + intros. inversion H. reflexivity.
    + intros. inversion H. subst. simpl. assumption.
    + intros. inversion H. subst. simpl. apply IHe1 in H4. rewrite H4.
      apply IHe2 in H6. rewrite H6. unfold eq_to_opt. assert (vsize lv = vsize rv).
      apply EQ. apply (value_eq_size_if_eq lv rv EQ) in H0. rewrite H0. reflexivity.
    + intros. inversion H. subst. simpl. destruct (expr_run assoc e) eqn:?. simpl.
      apply IHe in H3. rewrite Heqo in H3.
      inversion H3. subst. reflexivity. apply IHe in H3. rewrite Heqo in H3. discriminate.
    + intros. inversion H. subst. simpl. apply IHe1 in H4. rewrite H4. rewrite H7.
      apply IHe2 in H6. rewrite H6. reflexivity.
      subst. simpl. apply IHe1 in H4. rewrite H4. rewrite H7. apply IHe3.
      assumption.
Qed.

 *)

Definition genv := Genv.t unit unit.

Inductive step : state -> state -> Prop :=
| step_module :
    forall m stvar stvar' cycle f assoc0 assoc1 assoc2 nbassoc,
    mis_stepp (f cycle) (mkassociations assoc0 empty_assocmap)
              m.(mod_body)
              (mkassociations assoc1 nbassoc) ->
    assoc2 = merge_assocmap nbassoc assoc1 ->
    Some stvar' = assoc2!(fst m.(mod_state)) ->
    step (State m assoc0 empty_assocmap f cycle stvar)
         (State m assoc2 empty_assocmap f (S cycle) stvar')
| step_finish :
    forall m assoc f cycle stvar result,
    assoc!(fst m.(mod_finish)) = Some (1'h"1") ->
    assoc!(fst m.(mod_return)) = Some result ->
    step (State m assoc empty_assocmap f cycle stvar)
         (Finishstate result).
Hint Constructors step : verilog.

(*Inductive initial_state (m: module): state -> Prop :=
| initial_state_intro:
    forall hmi tmi,
    hmi::tmi = mod_body m ->
    initial_state m (State m hmi tmi empty_assocmap empty_assocmap (initial_fextclk m) O xH).

(** A final state is a [Returnstate] with an empty call stack. *)

Inductive final_state: state -> Integers.int -> Prop :=
  | final_state_intro: forall v,
      final_state (Finishstate v) (valueToInt v).

(** The small-step semantics for a module. *)

Definition semantics (p: module) :=
  Semantics step (initial_state p) final_state (Genv.empty_genv unit unit nil).
*)
