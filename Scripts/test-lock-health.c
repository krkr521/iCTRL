#include "ICLockHealthState.h"
#include <assert.h>
#include <stdio.h>

int main(void) {
    ICLockHealthState s = ICLockHealthMake(true);
    assert(!ICLockHealthReady(s));
    ICLockHealthObserve(&s, true, true, false);
    assert(ICLockHealthReady(s));
    uint64_t before = s.generation;
    ICLockHealthObserve(&s, true, false, false);
    assert(s.registered && !s.stateKnown && s.locked && s.generation > before);
    uint64_t failed = s.generation;
    ICLockHealthObserve(&s, true, true, false);
    assert(ICLockHealthReady(s) && s.generation == failed && s.generation != before);
    ICLockHealthObserve(&s, true, true, true);
    assert(s.registered && s.stateKnown && s.locked && !ICLockHealthReady(s));
    ICLockHealthObserve(&s, true, true, false);
    assert(ICLockHealthReady(s));
    ICLockHealthObserve(&s, false, true, false);
    assert(!s.registered && !s.stateKnown && s.locked);
    ICLockHealthObserve(&s, true, true, false);
    assert(!ICLockHealthReady(s) && !s.registered);
    s = ICLockHealthMake(false);
    ICLockHealthObserve(&s, true, true, false);
    assert(!ICLockHealthReady(s) && !s.registered);
    s = ICLockHealthMake(true); s.generation = UINT64_MAX;
    ICLockHealthObserve(&s, true, false, false);
    ICLockHealthObserve(&s, true, true, false);
    assert(s.generation == UINT64_MAX && !ICLockHealthReady(s));
    puts("PASS: shared C lock-health transitions, recovery, invalid token, registration failure, epoch overflow");
    return 0;
}
