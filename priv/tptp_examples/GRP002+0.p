% File     : GRP002+0 : ATP Benchmark Runner extended example
% Domain   : Group Theory
% Problem  : Two-sided identity is unique in a monoid
% Status   : Theorem
% Rating   : 0.10
% SPC      : FOF_THM_RFO_NEQ

fof(associativity, axiom,
    ! [X, Y, Z] : ( multiply(multiply(X, Y), Z) = multiply(X, multiply(Y, Z)) )).

fof(left_identity_e, axiom,
    ! [X] : ( multiply(e, X) = X )).

fof(right_identity_e, axiom,
    ! [X] : ( multiply(X, e) = X )).

fof(identity_unique, conjecture,
    ! [I] :
      ( ( ! [X] : ( multiply(I, X) = X )
        & ! [X] : ( multiply(X, I) = X ) )
     => I = e )).
