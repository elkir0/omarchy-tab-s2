#ifndef STUB_MODEM_UTILS_H
#define STUB_MODEM_UTILS_H
#include "kstub.h"
extern int kstub_hw_ok;
static inline int mif_gpio_get_value(struct gpio_desc *d) { return d ? d->value : 0; }
static inline void mif_gpio_set_value(struct gpio_desc *d, int v) { if (d && kstub_hw_ok) d->value = v; }
static inline void mif_add_timer(struct timer_list *t, unsigned long expire)
{ if (timer_pending(t)) return; mod_timer(t, jiffies + expire); }
#endif
