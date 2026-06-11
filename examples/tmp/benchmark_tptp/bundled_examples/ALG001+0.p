% File     : ALG001+0 : ATP Benchmark Runner smoke example
% Domain   : Algebra
% Status   : Theorem
% Rating   : 0.00
% SPC      : FOF_THM_RFO_NEQ

fof(commutativity,axiom,
    ! [X,Y] : op(X,Y) = op(Y,X)).

fof(some_identity,axiom,
    ? [E] :
      ! [X] : op(E,X) = X).

fof(identity_left,conjecture,
    ? [E] :
      ! [X] : op(E,X) = X).
