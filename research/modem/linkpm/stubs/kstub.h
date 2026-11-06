/* Userspace stand-ins for the kernel APIs link_device_pm.c uses (fsm-replay.c). */
#ifndef KSTUB_H
#define KSTUB_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>

typedef uint64_t u64;
typedef uint32_t u32;
typedef uint16_t u16;
typedef uint8_t u8;

#define likely(x) (x)
#define unlikely(x) (x)
#define READ_ONCE(x) (x)
#define WRITE_ONCE(x, v) ((x) = (v))
#define container_of(p, t, m) ((t *)((char *)(p) - offsetof(t, m)))
#define ENOSYS 38
#define ENOMEM 12
#define module_param(n, t, p)
#define MODULE_PARM_DESC(n, d)

extern int kstub_verbose;
#define pr_debug(...) do { if (kstub_verbose) printf("  [debug] " __VA_ARGS__); } while (0)
#define pr_info(...) do { if (kstub_verbose) printf("  [info] " __VA_ARGS__); } while (0)
extern int kstub_errors;
#define pr_err(...) do { kstub_errors++; printf("  [err] " __VA_ARGS__); } while (0)

typedef struct { int counter; } atomic_t;
#define atomic_read(a) ((a)->counter)
#define atomic_set(a, v) ((a)->counter = (v))
static inline void atomic_or(int m, atomic_t *a) { a->counter |= m; }
static inline void atomic_andnot(int m, atomic_t *a) { a->counter &= ~m; }

typedef struct { int locked; } spinlock_t;
#define spin_lock_init(l) ((l)->locked = 0)
#define spin_lock_irqsave(l, f) do { (void)(f); if ((l)->locked) printf("  [BUG] recursive lock\n"); (l)->locked = 1; } while (0)
#define spin_unlock_irqrestore(l, f) do { (void)(f); (l)->locked = 0; } while (0)

extern unsigned long jiffies;
static inline unsigned long msecs_to_jiffies(unsigned long ms) { return ms; }
static inline u64 local_clock(void) { return (u64)jiffies * 1000000ULL; }

struct timer_list {
	void (*function)(struct timer_list *);
	unsigned long expires;
	int pending;
};
#define timer_setup(t, fn, fl) do { (t)->function = (fn); (t)->pending = 0; } while (0)
#define from_timer(var, cb, field) container_of(cb, __typeof__(*var), field)
static inline int timer_pending(const struct timer_list *t) { return t->pending; }
static inline int del_timer(struct timer_list *t) { int p = t->pending; t->pending = 0; return p; }
static inline int mod_timer(struct timer_list *t, unsigned long e) { t->expires = e; t->pending = 1; return 0; }

struct work_struct { void (*func)(struct work_struct *); int pending; };
struct delayed_work { struct work_struct work; unsigned long delay; };
struct workqueue_struct { int dummy; };
#define WQ_UNBOUND 1
#define WQ_HIGHPRI 2
static inline struct workqueue_struct *alloc_workqueue(const char *fmt, int fl, int max, ...)
{ static struct workqueue_struct wq; (void)fmt; (void)fl; (void)max; return &wq; }
#define INIT_DELAYED_WORK(w, fn) do { (w)->work.func = (fn); (w)->work.pending = 0; } while (0)
static inline bool work_pending(struct work_struct *w) { return w->pending; }
static inline bool queue_delayed_work(struct workqueue_struct *q, struct delayed_work *w, unsigned long d)
{ (void)q; if (w->work.pending) return false; w->work.pending = 1; w->delay = d; return true; }
static inline bool cancel_delayed_work(struct delayed_work *w) { int p = w->work.pending; w->work.pending = 0; return p; }

struct gpio_desc { const char *name; int value; };

typedef struct { int dummy; } wait_queue_head_t;
extern int kstub_wakeups;
#define wake_up_all(q) ((void)(q), kstub_wakeups++)

struct seq_file { int dummy; };
#define seq_printf(s, ...) printf(__VA_ARGS__)
#define seq_puts(s, str) fputs(str, stdout)
#endif
