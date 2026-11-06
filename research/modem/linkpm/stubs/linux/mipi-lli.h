/* struct link_pm_svc as in the port's include/linux/mipi-lli.h (fsm-replay.c checks it) */
#include "kstub.h"
#ifndef STUB_MIPI_LLI_H
#define STUB_MIPI_LLI_H
struct link_pm_svc {
	void *owner;
	spinlock_t *lock;
	bool active;
	void (*reset_cb)(void *owner);
	void (*mount_cb)(void *owner);
	void (*unmount_cb)(void *owner);
	void (*lock_link)(void *owner);
	void (*unlock_link)(void *owner);
};
static inline bool pm_svc_active(const struct link_pm_svc *svc) { return svc && READ_ONCE(svc->active); }
#endif
