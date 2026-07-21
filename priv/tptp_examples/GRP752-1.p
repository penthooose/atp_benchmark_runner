%------------------------------------------------------------------------------
% File     : GRP752-1 : TPTP v9.2.1. Released v4.0.0.
% Domain   : Group Theory (Quasigroups)
% Problem  : A new basis for trimedial quasigroups: part 1b
% Version  : Especial.
% English  :

% Refs     : [KP04]  Kinyon & Phillips (2004), Axioms for Trimedial Quasigr
%          : [Sta08] Stanovsky (2008), Email to G. Sutcliffe
% Source   : [Sta08]
% Names    : KP04b_1b [Sta08]

% Status   : Unsatisfiable
% Rating   : 0.43 v9.1.0, 0.45 v9.0.0, 0.50 v8.2.0, 0.58 v8.1.0, 0.50 v7.5.0, 0.58 v7.4.0, 0.65 v7.3.0, 0.63 v7.1.0, 0.56 v7.0.0, 0.58 v6.3.0, 0.59 v6.2.0, 0.64 v6.1.0, 0.69 v6.0.0, 0.76 v5.5.0, 0.74 v5.4.0, 0.67 v5.2.0, 0.64 v5.1.0, 0.67 v5.0.0, 0.64 v4.1.0, 0.55 v4.0.1, 0.64 v4.0.0
% Syntax   : Number of clauses     :    8 (   8 unt;   0 nHn;   1 RR)
%            Number of literals    :    8 (   8 equ;   1 neg)
%            Maximal clause size   :    1 (   1 avg)
%            Maximal term depth    :    4 (   2 avg)
%            Number of predicates  :    1 (   0 usr;   0 prp; 2-2 aty)
%            Number of functors    :    6 (   6 usr;   3 con; 0-2 aty)
%            Number of variables   :   17 (   0 sgn)
% SPC      : CNF_UNS_RFO_PEQ_UEQ

% Comments :
%------------------------------------------------------------------------------
cnf(f01,axiom,
    mult(A,ld(A,B)) = B ).

cnf(f02,axiom,
    ld(A,mult(A,B)) = B ).

cnf(f03,axiom,
    mult(rd(A,B),B) = A ).

cnf(f04,axiom,
    rd(mult(A,B),B) = A ).

cnf(f05,axiom,
    mult(mult(A,mult(A,A)),mult(B,C)) = mult(mult(A,B),mult(mult(A,A),C)) ).

cnf(f06,axiom,
    mult(mult(A,A),mult(B,C)) = mult(mult(A,B),mult(A,C)) ).

cnf(f07,axiom,
    mult(mult(A,B),mult(C,C)) = mult(mult(A,C),mult(B,C)) ).

cnf(goals,negated_conjecture,
    mult(mult(a,b),c) != mult(mult(a,c),mult(b,ld(c,c))) ).

%------------------------------------------------------------------------------
