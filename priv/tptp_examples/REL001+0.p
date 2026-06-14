% File     : REL001+0 : ATP Benchmark Runner extended example
% Domain   : Relation Theory
% Problem  : Composition of two symmetric relations is commutative
% Status   : Theorem
% Rating   : 0.55
% SPC      : FOF_THM_RFO_NEQ

% A relation R on a set with 5 elements
fof(r1_a, axiom, r(a, b)).
fof(r1_b, axiom, r(b, c)).
fof(r1_c, axiom, r(c, d)).
fof(r1_d, axiom, r(d, e)).
fof(r1_e, axiom, r(e, a)).

% Symmetry of R
fof(r_symmetric, axiom,
    ! [X, Y] : ( r(X, Y) => r(Y, X) )).

% Transitivity of R
fof(r_transitive, axiom,
    ! [X, Y, Z] : ( ( r(X, Y) & r(Y, Z) ) => r(X, Z) )).

% A second relation S
fof(s1_a, axiom, s(a, c)).
fof(s1_b, axiom, s(c, e)).
fof(s1_c, axiom, s(e, b)).
fof(s1_d, axiom, s(b, d)).

% Symmetry of S
fof(s_symmetric, axiom,
    ! [X, Y] : ( s(X, Y) => s(Y, X) )).

% Transitivity of S
fof(s_transitive, axiom,
    ! [X, Y, Z] : ( ( s(X, Y) & s(Y, Z) ) => s(X, Z) )).

% Definition of relational composition
fof(composition_def, axiom,
    ! [X, Y] :
      ( composition(X, Y)
    <=> ? [Z] : ( r(X, Z) & s(Z, Y) ) )).

% Alternative composition (S then R)
fof(composition2_def, axiom,
    ! [X, Y] :
      ( composition2(X, Y)
    <=> ? [Z] : ( s(X, Z) & r(Z, Y) ) )).

% Conjecture: composition is symmetric in the sense that
% composition(X,Y) iff composition2(Y,X)
fof(composition_symmetry, conjecture,
    ! [X, Y] :
      ( composition(X, Y)
    <=> composition2(Y, X) )).
