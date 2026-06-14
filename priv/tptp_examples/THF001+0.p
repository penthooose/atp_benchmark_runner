% File     : THF001+0 : ATP Benchmark Runner extended example
% Domain   : Higher-Order Logic
% Problem  : Idempotency of logical conjunction
% Status   : Theorem
% Rating   : 0.10
% SPC      : THF_THM_NEQ

thf(conj_idempotent, conjecture,
    ! [P: $o] :
      ( ( P & P )
    <=> P )).
