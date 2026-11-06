// SPDX-License-Identifier: GPL-2.0-or-later
/*
 * fsm-replay.c — the link PM state machine of the t715-linkpm kernel branch
 * (drivers/misc/modem_v1/link_device_pm.c), compiled in userspace on the
 * stand-ins of stubs/ and driven through stock's handshake (research/modem/
 * LINK-PM.md sections 2 and 4): the CP's release and remount, a send while
 * unmounted, the watchdogs, and a stop in every state.  run.sh builds it with
 * the branch's two real files.  Exit 1 on the first failed check.
 */
#include "link_device_pm.c"

#include <stdlib.h>

int kstub_verbose;
int kstub_wakeups;
int kstub_errors;
int kstub_hw_ok = 1;
unsigned long jiffies;

static struct gpio_desc cp2ap_wakeup = { "CP2AP_WAKEUP", 0 };
static struct gpio_desc ap2cp_wakeup = { "AP2CP_WAKEUP", 0 };
static struct gpio_desc cp2ap_status = { "CP2AP_STATUS", 0 };
static struct gpio_desc ap2cp_status = { "AP2CP_STATUS", 0 };

static struct modem_ctl mc = { STATE_ONLINE, { 0 }, "ss333" };
static struct mem_link_device mld;
static struct modem_link_pm pm;
static struct link_pm_svc svc;
static int reloads, pm_fails, cp_fails, lock_links;
static int checks, failed;

static void fake_reload(struct link_device *ld) { (void)ld; reloads++; }
static bool fake_suspended(struct link_device *ld) { (void)ld; return false; }
static void fake_lock_link(void *owner) { (void)owner; lock_links++; }
static void on_pm_fail(struct modem_link_pm *p) { (void)p; pm_fails++; }
static void on_cp_fail(struct modem_link_pm *p) { (void)p; cp_fails++; }

#define CHECK(cond, what)							\
	do {									\
		checks++;							\
		if (!(cond)) {							\
			printf("FAIL %s (state %s, AP2CP %d/%d)\n", what,	\
			       pm_state2str(pm.fsm.state), ap2cp_wakeup.value,	\
			       ap2cp_status.value);				\
			failed++;						\
		}								\
	} while (0)

static enum pm_state st(void) { return pm.fsm.state; }

/* the CP moves a line: the GPIO handler reads the level and calls the FSM */
static void cp_wakeup(int v) { cp2ap_wakeup.value = v; link_pm_cp2ap_wakeup(&pm, v); }
static void cp_status(int v) { cp2ap_status.value = v; link_pm_cp2ap_status(&pm, v); }

/* the deferred bits run when the test says so */
static void run_cp_free(void)
{
	if (pm.cp_free_dwork.work.pending) {
		pm.cp_free_dwork.work.pending = 0;
		jiffies += cp_hold_time;
		pm.cp_free_dwork.work.func(&pm.cp_free_dwork.work);
	}
}

static bool bark(void)
{
	if (!pm.wdog.timer.pending)
		return false;
	pm.wdog.timer.pending = 0;
	jiffies += 500;
	pm.wdog.timer.function(&pm.wdog.timer);
	return true;
}

/* the LLI driver's callbacks, as exynos-mipi-lli.c calls them */
static void lli_reset_done(void) { if (pm_svc_active(&svc)) svc.reset_cb(svc.owner); }
static void lli_mounted(void) { if (pm_svc_active(&svc)) svc.mount_cb(svc.owner); }
static void lli_unmounted(void) { if (pm_svc_active(&svc)) svc.unmount_cb(svc.owner); }

static void boot(void)
{
	cp2ap_wakeup.value = 1;		/* the CP awake at PHONE_START */
	cp2ap_status.value = 1;
	pm_fails = cp_fails = 0;
	start_link_pm(&pm, PM_EVENT_CP_BOOTING);
}

/* from ACTIVE, the CP lets go and unmounts: stock's release */
static void release(void)
{
	cp_wakeup(0);
	CHECK(st() == PM_STATE_AP_FREE, "CP2AP_WAKEUP low: AP_FREE");
	CHECK(pm.cp_free_dwork.work.pending, "  the 100 ms CP_FREE work queued");
	CHECK(ap2cp_wakeup.value == 1, "  AP2CP_WAKEUP still held during the hold time");
	run_cp_free();
	CHECK(st() == PM_STATE_CP_FREE, "hold time over, no TX: CP_FREE");
	CHECK(ap2cp_wakeup.value == 0, "  AP2CP_WAKEUP released");
	cp_status(0);
	CHECK(st() == PM_STATE_UNMOUNTING, "CP2AP_STATUS low: UNMOUNTING");
	CHECK(pm.wdog.timer.pending, "  the unmount watchdog armed");
	lli_unmounted();
	CHECK(st() == PM_STATE_UNMOUNTED, "LLI unmount: UNMOUNTED");
	CHECK(ap2cp_status.value == 0, "  AP2CP_STATUS released");
	CHECK(!pm.wdog.timer.pending, "  the watchdog stopped");
	CHECK(!wake_lock_active(&pm.wlock), "  the wake lock released");
	CHECK(!link_pm_active(&pm), "  no TX on an unmounted link");
}

/* from UNMOUNTED after RESETTING was entered: reset done, then the mount */
static void remount(const char *why, bool status_first)
{
	char what[96];

	snprintf(what, sizeof(what), "%s: RESETTING, the LLI reloaded", why);
	CHECK(st() == PM_STATE_RESETTING, what);
	CHECK(ap2cp_wakeup.value == 1, "  AP2CP_WAKEUP asserted");
	CHECK(wake_lock_active(&pm.wlock), "  the wake lock held for the mount");
	lli_reset_done();
	CHECK(st() == PM_STATE_MOUNTING, "SW_RESET_DONE: MOUNTING");
	CHECK(ap2cp_status.value == 1, "  AP2CP_STATUS asserted");
	if (status_first) {
		cp_status(1);
		CHECK(st() == PM_STATE_ACTIVE, "CP2AP_STATUS high: ACTIVE");
		lli_mounted();
		CHECK(st() == PM_STATE_ACTIVE, "  the late mount callback changes nothing");
	} else {
		lli_mounted();
		CHECK(st() == PM_STATE_ACTIVE, "LLI mount: ACTIVE");
		cp2ap_status.value = 1;
	}
	CHECK(!pm.wdog.timer.pending, "  the watchdog stopped");
	CHECK(link_pm_active(&pm), "  TX allowed");
}

static void scenario_cp_cycle(void)
{
	int r;

	printf("== the CP's own cycle (stock: release, sleep, wake)\n");
	boot();
	CHECK(st() == PM_STATE_CP_BOOTING, "PHONE_START: CP_BOOTING");
	CHECK(ap2cp_wakeup.value == 1 && ap2cp_status.value == 1, "  both AP2CP lines high");
	CHECK(svc.active, "  the LLI callbacks on");
	cp_wakeup(0);
	CHECK(st() == PM_STATE_CP_BOOTING, "CP_BOOTING ignores CP2AP_WAKEUP low (stock)");
	cp_wakeup(1);
	CHECK(st() == PM_STATE_ACTIVE, "CP2AP_WAKEUP high: ACTIVE");
	for (r = 0; r < 3; r++) {
		release();
		reloads = 0;
		cp_wakeup(1);
		CHECK(reloads == 1, "CP2AP_WAKEUP high on an unmounted link: one reload");
		remount("the CP wakes", r & 1);
	}
	cp_wakeup(0);
	CHECK(st() == PM_STATE_AP_FREE, "AP_FREE again");
	cp_wakeup(1);
	CHECK(st() == PM_STATE_ACTIVE, "the CP back within the hold time: ACTIVE");
	CHECK(!pm.cp_free_dwork.work.pending, "  the CP_FREE work cancelled");
	CHECK(pm_fails == 0 && cp_fails == 0, "no failure on the way");
	stop_link_pm(&pm);
}

static void scenario_tx(void)
{
	printf("== AP sends while unmounted (forbid_cp_sleep -> hold request)\n");
	boot();
	cp_wakeup(0);
	cp_wakeup(1);
	release();
	/* forbid_cp_sleep (link_device_lli.c): ref_cnt bit, then the request */
	atomic_or(1, &pm.ref_cnt);
	link_pm_request_hold(&pm);
	CHECK(st() == PM_STATE_HOLDING, "hold request: HOLDING");
	CHECK(ap2cp_wakeup.value == 1, "  AP2CP_WAKEUP asserted to wake the CP");
	CHECK(pm.wdog.timer.pending, "  the watchdog waits for CP2AP_WAKEUP");
	reloads = 0;
	cp_wakeup(1);
	CHECK(reloads == 1, "the CP answers: one reload");
	remount("HOLDING -> CP2AP_WAKEUP high", false);
	/* the CP wants to let go while the TX reference is still held */
	cp_wakeup(0);
	run_cp_free();
	CHECK(st() == PM_STATE_ACTIVE, "TX still referenced at the hold timeout: ACTIVE");
	CHECK(ap2cp_wakeup.value == 1, "  AP2CP_WAKEUP asserted again");
	/* permit_cp_sleep clears the bit; the CP asks again */
	atomic_andnot(1, &pm.ref_cnt);
	cp_wakeup(1);
	release();
	/* a hold request during UNMOUNTING: remount right after the unmount */
	cp_wakeup(1);
	remount("the CP wakes", false);
	cp_wakeup(0);
	run_cp_free();
	cp_status(0);
	CHECK(st() == PM_STATE_UNMOUNTING, "UNMOUNTING");
	link_pm_request_hold(&pm);
	CHECK(st() == PM_STATE_UNMOUNTING, "  a hold request is remembered, not served");
	lli_unmounted();
	CHECK(st() == PM_STATE_HOLDING, "the unmount with a pending hold: HOLDING");
	CHECK(ap2cp_wakeup.value == 1, "  AP2CP_WAKEUP asserted");
	reloads = 0;
	cp_wakeup(1);
	remount("HOLDING after UNMOUNTING", false);
	/* a hold request in CP_FREE: ACTIVATING, then ACTIVE */
	cp_wakeup(0);
	run_cp_free();
	CHECK(st() == PM_STATE_CP_FREE, "CP_FREE");
	link_pm_request_hold(&pm);
	CHECK(st() == PM_STATE_ACTIVATING, "hold request in CP_FREE: ACTIVATING");
	cp_wakeup(1);
	CHECK(st() == PM_STATE_ACTIVE, "CP2AP_WAKEUP high: ACTIVE");
	/* the CP goes on with its release while the AP asks: ACTIVATING -> UNMOUNTING */
	kstub_errors = 0;
	cp_wakeup(0);
	run_cp_free();
	link_pm_request_hold(&pm);
	CHECK(st() == PM_STATE_ACTIVATING, "ACTIVATING again");
	cp_status(0);
	CHECK(st() == PM_STATE_UNMOUNTING, "CP2AP_STATUS low in ACTIVATING: UNMOUNTING");
	CHECK(pm.wdog.timer.pending && pm.wdog.state == PM_STATE_UNMOUNTING,
	      "  the UNMOUNTING watchdog armed (6.12 port)");
	lli_unmounted();
	CHECK(st() == PM_STATE_HOLDING, "the unmount, the hold still wanted: HOLDING");
	CHECK(kstub_errors == 0, "  no 'illegal state' message on that path");
	reloads = 0;
	cp_wakeup(1);
	remount("HOLDING after ACTIVATING", false);
	/* ACTIVATING whose CP2AP_STATUS edge was lost: the bark finds it low */
	cp_wakeup(0);
	run_cp_free();
	link_pm_request_hold(&pm);
	cp2ap_status.value = 0;		/* no interrupt */
	bark();
	CHECK(st() == PM_STATE_UNMOUNTING && pm.wdog.timer.pending,
	      "lost STATUS edge in ACTIVATING: UNMOUNTING, its watchdog armed");
	CHECK(bark() && st() == PM_STATE_WDOG_TIMEOUT, "  and that watchdog ends a lost unmount");
	CHECK(cp_fails == 1, "  CP fail handler (CP2AP_STATUS low)");
	stop_link_pm(&pm);
	cp_fails = 0;
	CHECK(pm_fails == 0, "no PM failure on the way");
	stop_link_pm(&pm);
}

static void scenario_watchdogs(void)
{
	printf("== watchdogs\n");

	/* HOLDING, the CP never answers; CP2AP_STATUS was low (unmounted) */
	boot();
	cp_wakeup(0);
	cp_wakeup(1);
	release();
	link_pm_request_hold(&pm);
	CHECK(st() == PM_STATE_HOLDING, "HOLDING");
	CHECK(bark(), "  the watchdog fires");
	CHECK(st() == PM_STATE_WDOG_TIMEOUT, "no CP2AP_WAKEUP: WDOG_TIMEOUT");
	CHECK(cp_fails == 1 && pm_fails == 0, "  CP fail handler (CP2AP_STATUS low)");
	link_pm_cp2ap_wakeup(&pm, 1);
	CHECK(st() == PM_STATE_WDOG_TIMEOUT, "  a locked state ignores events");
	stop_link_pm(&pm);

	/* HOLDING, the CP's edge lost but the line high when the dog barks */
	boot();
	cp_wakeup(0);
	cp_wakeup(1);
	release();
	link_pm_request_hold(&pm);
	cp2ap_wakeup.value = 1;		/* no interrupt */
	reloads = 0;
	bark();
	CHECK(st() == PM_STATE_RESETTING && reloads == 1, "lost edge, line high at the bark: RESETTING");
	CHECK(pm_fails == 0 && cp_fails == 0, "  no failure");
	stop_link_pm(&pm);

	/* RESETTING, no SW_RESET_DONE */
	boot();
	cp_wakeup(0);
	cp_wakeup(1);
	release();
	cp_wakeup(1);
	CHECK(st() == PM_STATE_RESETTING, "RESETTING");
	bark();
	CHECK(st() == PM_STATE_AP_FAIL, "no SW_RESET_DONE: AP_FAIL");
	CHECK(cp_fails == 1, "  CP fail handler (3.10 without SEC_MODEM_DEBUG)");
	stop_link_pm(&pm);

	/* MOUNTING, the mount refused (remap) */
	boot();
	cp_wakeup(0);
	cp_wakeup(1);
	release();
	cp_wakeup(1);
	lli_reset_done();
	CHECK(st() == PM_STATE_MOUNTING, "MOUNTING");
	cp2ap_status.value = 1;
	bark();
	CHECK(st() == PM_STATE_WDOG_TIMEOUT, "no mount: WDOG_TIMEOUT");
	CHECK(pm_fails == 1, "  PM fail handler (CP2AP_STATUS high)");
	stop_link_pm(&pm);

	/* the CP drops CP2AP_STATUS while ACTIVE */
	boot();
	cp_wakeup(0);
	cp_wakeup(1);
	cp_status(0);
	CHECK(st() == PM_STATE_CP_FAIL && cp_fails == 1, "CP2AP_STATUS low in ACTIVE: CP_FAIL");
	stop_link_pm(&pm);
}

/* drive to a state by name, then stop: the stop must leave nothing behind */
static void stop_in(const char *name, void (*drive)(void))
{
	char what[96];

	boot();
	cp_wakeup(0);
	cp_wakeup(1);
	drive();
	snprintf(what, sizeof(what), "stop in %s", name);
	stop_link_pm(&pm);
	CHECK(!pm.active && !svc.active, what);
	CHECK(st() == PM_STATE_UNMOUNTED, "  FSM state UNMOUNTED");
	CHECK(!pm.wdog.timer.pending, "  no watchdog pending");
	CHECK(!pm.cp_free_dwork.work.pending, "  no CP_FREE work pending");
	CHECK(!wake_lock_active(&pm.wlock), "  the wake lock released");
	/* a late callback or interrupt after the stop */
	ap2cp_wakeup.value = 1;
	lli_unmounted();
	link_pm_cp2ap_wakeup(&pm, 0);
	CHECK(st() == PM_STATE_UNMOUNTED, "  a late event changes nothing");
	CHECK(ap2cp_wakeup.value == 0, "  a late event only lowers AP2CP_WAKEUP");
}

static void d_active(void) { }
static void d_ap_free(void) { cp_wakeup(0); }
static void d_cp_free(void) { cp_wakeup(0); run_cp_free(); }
static void d_unmounting(void) { cp_wakeup(0); run_cp_free(); cp_status(0); }
static void d_unmounted(void) { release(); }
static void d_holding(void) { release(); link_pm_request_hold(&pm); }
static void d_resetting(void) { release(); cp_wakeup(1); }
static void d_mounting(void) { release(); cp_wakeup(1); lli_reset_done(); }

static void scenario_stops(void)
{
	printf("== a stop (MODEM_OFF, crash) in every state\n");
	stop_in("ACTIVE", d_active);
	stop_in("AP_FREE", d_ap_free);
	stop_in("CP_FREE", d_cp_free);
	stop_in("UNMOUNTING", d_unmounting);
	stop_in("UNMOUNTED", d_unmounted);
	stop_in("HOLDING", d_holding);
	stop_in("RESETTING", d_resetting);
	stop_in("MOUNTING", d_mounting);
}

/* the LLI's unmount handled before the CP2AP_STATUS low edge (seen on the tablet) */
static void scenario_early_unmount(void)
{
	printf("== the unmount before the STATUS low edge\n");
	boot();
	cp_wakeup(0);
	cp_wakeup(1);
	cp_wakeup(0);
	run_cp_free();
	CHECK(st() == PM_STATE_CP_FREE, "CP_FREE");
	cp2ap_status.value = 0;		/* the line is low, its interrupt not handled yet */
	kstub_errors = 0;
	lli_unmounted();
	CHECK(st() == PM_STATE_UNMOUNTED, "unmount in CP_FREE: UNMOUNTED (6.12 port)");
	CHECK(ap2cp_status.value == 0, "  AP2CP_STATUS released");
	CHECK(!pm.wdog.timer.pending, "  no watchdog left waiting");
	CHECK(pm.stats.early_unmounts == 1, "  counted as an early unmount");
	link_pm_cp2ap_status(&pm, 0);
	CHECK(st() == PM_STATE_UNMOUNTED, "the late STATUS low edge changes nothing");
	CHECK(!bark(), "  and arms no watchdog");
	CHECK(kstub_errors == 0 && pm_fails == 0 && cp_fails == 0, "  no error, no failure");
	reloads = 0;
	cp_wakeup(1);
	remount("the next wake", false);

	/* the same while a send waits: ACTIVATING */
	cp_wakeup(0);
	run_cp_free();
	link_pm_request_hold(&pm);
	CHECK(st() == PM_STATE_ACTIVATING, "ACTIVATING");
	cp2ap_status.value = 0;
	lli_unmounted();
	CHECK(st() == PM_STATE_HOLDING, "unmount in ACTIVATING with a send waiting: HOLDING");
	CHECK(pm.wdog.timer.pending && pm.wdog.state == PM_STATE_HOLDING, "  the HOLDING watchdog armed");
	CHECK(ap2cp_wakeup.value == 1 && ap2cp_status.value == 0, "  AP2CP_WAKEUP held, AP2CP_STATUS released");
	link_pm_cp2ap_status(&pm, 0);
	CHECK(st() == PM_STATE_HOLDING, "the late STATUS low edge changes nothing");
	reloads = 0;
	cp_wakeup(1);
	remount("HOLDING after the early unmount", false);
	CHECK(kstub_errors == 0 && pm_fails == 0 && cp_fails == 0, "no error, no failure");
	stop_link_pm(&pm);
}

static void scenario_not_online(void)
{
	printf("== a hold request while the CP is not ONLINE\n");
	boot();
	cp_wakeup(0);
	cp_wakeup(1);
	release();
	mc.phone_state = STATE_BOOTING;
	link_pm_request_hold(&pm);
	CHECK(st() == PM_STATE_UNMOUNTED && !pm.hold_requested, "ignored (stock: cp_online only)");
	mc.phone_state = STATE_ONLINE;
	stop_link_pm(&pm);
}

int main(int argc, char **argv)
{
	kstub_verbose = argc > 1 && !strcmp(argv[1], "-v");

	mld.link_dev.name = "lli";
	mld.link_dev.mc = &mc;
	mld.link_dev.reload = fake_reload;
	mld.link_dev.suspended = fake_suspended;
	svc.lock_link = fake_lock_link;

	if (init_link_device_pm(&mld.link_dev, &pm, &svc, &cp2ap_wakeup,
				&ap2cp_wakeup, &cp2ap_status, &ap2cp_status,
				on_pm_fail, on_cp_fail)) {
		printf("FAIL init_link_device_pm\n");
		return 1;
	}
	CHECK(!svc.active && svc.owner == &pm, "init: callbacks registered, not active");

	scenario_cp_cycle();
	scenario_tx();
	scenario_watchdogs();
	scenario_stops();
	scenario_early_unmount();
	scenario_not_online();

	printf("%d checks, %d failed\n", checks, failed);
	if (!failed)
		printf("PASS\n");
	return failed ? 1 : 0;
}
