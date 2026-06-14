% File     : LAT001+0 : ATP Benchmark Runner extended example
% Domain   : Lattice Theory
% Problem  : In a lattice, meet is idempotent (x ∧ x = x)
% Status   : Theorem
% Rating   : 0.22
% SPC      : FOF_THM_RFO_NEQ

% Lattice axioms for meet (join defined analogously)
fof(meet_commutative, axiom,
    ! [X, Y] : meet(X, Y) = meet(Y, X) ).

fof(meet_associative, axiom,
    ! [X, Y, Z] : meet(meet(X, Y), Z) = meet(X, meet(Y, Z)) ).

fof(join_commutative, axiom,
    ! [X, Y] : join(X, Y) = join(Y, X) ).

fof(join_associative, axiom,
    ! [X, Y, Z] : join(join(X, Y), Z) = join(X, join(Y, Z)) ).

fof(absorption1, axiom,
    ! [X, Y] : meet(X, join(X, Y)) = X ).

fof(absorption2, axiom,
    ! [X, Y] : join(X, meet(X, Y)) = X ).

% Conjecture: meet is idempotent
fof(meet_idempotent, conjecture,
    ! [X] : meet(X, X) = X ).
