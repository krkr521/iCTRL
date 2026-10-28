#include "include/ICLockHealthState.h"

ICLockHealthState ICLockHealthMake(bool registered) {
    ICLockHealthState state = {registered, false, true, 0};
    return state;
}
bool ICLockHealthReady(ICLockHealthState state) {
    return state.registered && state.stateKnown && !state.locked;
}
void ICLockHealthObserve(ICLockHealthState *state, bool tokenValid, bool readOK, bool locked) {
    if (!state->registered || !tokenValid) state->registered = false;
    state->stateKnown = state->registered && readOK;
    state->locked = !state->stateKnown || locked;
    if (!ICLockHealthReady(*state)) {
        if (state->generation < UINT64_MAX) state->generation++;
        else state->registered = false; // Never wrap and accidentally match an old lease.
    }
}
