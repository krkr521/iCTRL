#ifndef IC_LOCK_HEALTH_STATE_H
#define IC_LOCK_HEALTH_STATE_H
#include <stdbool.h>
#include <stdint.h>

typedef struct {
    bool registered;
    bool stateKnown;
    bool locked;
    uint64_t generation;
} ICLockHealthState;

ICLockHealthState ICLockHealthMake(bool registered);
/// tokenValid=false permanently invalidates this registration. Only a newly
/// registered monitor may create a new state. Unsafe reads advance generation.
void ICLockHealthObserve(ICLockHealthState *state, bool tokenValid, bool readOK, bool locked);
bool ICLockHealthReady(ICLockHealthState state);
#endif
