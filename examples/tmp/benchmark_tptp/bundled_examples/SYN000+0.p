% File     : SYN000+0 : ATP Benchmark Runner smoke example
% Domain   : Syntactic
% Status   : Theorem
% Rating   : 0.00
% SPC      : FOF_THM_RFO_NEQ

fof(modus_ponens,conjecture,
    ( ( p
      & ( p => q ) )
    => q )).
