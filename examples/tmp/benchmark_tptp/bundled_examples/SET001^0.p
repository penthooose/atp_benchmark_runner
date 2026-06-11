% File     : SET001^0 : ATP Benchmark Runner smoke example
% Domain   : Set Theory
% Status   : Theorem
% Rating   : 0.00
% SPC      : THF_THM_NEQ

thf(identity_decl,type,
    ( identity: $i > $i )).

thf(identity_axiom,axiom,
    ! [X: $i] : ( identity @ X = X )).

thf(identity_goal,conjecture,
    ! [Y: $i] : ( identity @ Y = Y )).