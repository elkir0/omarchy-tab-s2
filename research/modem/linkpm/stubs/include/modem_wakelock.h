#ifndef STUB_WAKELOCK_H
#define STUB_WAKELOCK_H
#define WAKE_LOCK_SUSPEND 0
struct wake_lock { int active; };
#define wake_lock_init(l, t, n) ((l)->active = 0)
#define wake_lock(l) ((l)->active = 1)
#define wake_unlock(l) ((l)->active = 0)
#define wake_lock_active(l) ((l)->active)
#endif
