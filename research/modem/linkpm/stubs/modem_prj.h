#ifndef STUB_MODEM_PRJ_H
#define STUB_MODEM_PRJ_H
#include "kstub.h"
#include "include/modem_v1.h"
enum { STATE_OFFLINE, STATE_BOOTING, STATE_ONLINE };
struct modem_ctl { int phone_state; spinlock_t lock; const char *name; };
struct link_device {
	char *name;
	struct modem_ctl *mc;
	bool (*suspended)(struct link_device *ld);
	void (*reload)(struct link_device *ld);
};
static inline bool cp_online(struct modem_ctl *mc) { return mc->phone_state == STATE_ONLINE; }
#endif
