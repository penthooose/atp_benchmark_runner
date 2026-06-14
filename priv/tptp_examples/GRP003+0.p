% File     : GRP003+0 : ATP Benchmark Runner extended example
% Domain   : Group Theory
% Problem  : Involutive groups are abelian (x*x = e => a*b = b*a)
% Status   : Theorem
% Rating   : 0.33
% SPC      : FOF_THM_RFO_NEQ

% Group axioms
fof(associativity, axiom,
    ! [X, Y, Z] : multiply(multiply(X, Y), Z) = multiply(X, multiply(Y, Z)) ).

fof(left_identity, axiom,
    ! [X] : multiply(e, X) = X ).

fof(left_inverse, axiom,
    ! [X] : multiply(inverse(X), X) = e ).

% Involution: every element is its own inverse
fof(involution, axiom,
    ! [X] : multiply(X, X) = e ).

% Conjecture: the group is abelian
fof(commutativity, conjecture,
    ! [A, B] : multiply(A, B) = multiply(B, A) ).
