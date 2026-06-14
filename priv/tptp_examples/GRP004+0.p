% File     : GRP004+0 : ATP Benchmark Runner extended example
% Domain   : Group Theory
% Problem  : Inverse of product equals product of inverses reversed
%            inv(A * B) = inv(B) * inv(A)
% Status   : Theorem
% Rating   : 0.44
% SPC      : FOF_THM_RFO_NEQ

% Full group axioms
fof(associativity, axiom,
    ! [X, Y, Z] : multiply(multiply(X, Y), Z) = multiply(X, multiply(Y, Z)) ).

fof(left_identity, axiom,
    ! [X] : multiply(identity, X) = X ).

fof(right_identity, axiom,
    ! [X] : multiply(X, identity) = X ).

fof(left_inverse, axiom,
    ! [X] : multiply(inverse(X), X) = identity ).

fof(right_inverse, axiom,
    ! [X] : multiply(X, inverse(X)) = identity ).

% Conjecture: inv(A * B) = inv(B) * inv(A)
fof(inverse_product, conjecture,
    ! [A, B] : inverse(multiply(A, B)) = multiply(inverse(B), inverse(A)) ).
