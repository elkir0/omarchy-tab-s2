/*
 * t715-watchdog-keeper — feeds the SoC watchdog of the Galaxy Tab S2 8.0 LTE
 * (SM-T715, Exynos 5433) once the arm64 system is up.  Unit:
 * t715-watchdog-keeper.service.  Static, no dependency but the C library.
 *
 * The design (the loader's design, elkir0/bnuuyloader's t715/docs/PRODUCTION-LOADER.md): the loader arms the watchdog
 * before it starts the kernel, and nothing in the kernel feeds it
 * (watchdog.handle_boot_enabled=0).  A kernel that hangs is reset by the
 * hardware.  This program is the only thing that keeps a booted system alive:
 * it opens /dev/watchdog, which pings it at once, and pings it again every
 * INTERVAL seconds until it is stopped.
 *
 * What the 6.12 watchdog core does around it (drivers/watchdog/watchdog_dev.c,
 * s3c2410_wdt.c), which this program relies on:
 *   - s3c2410_wdt says WDIOF_MAGICCLOSE.  So a close without the magic
 *     character leaves the watchdog RUNNING (the kernel logs "watchdog0:
 *     watchdog did not stop!" and pings once): nobody feeds it any more, and
 *     the board is reset INTERVAL-less, one timeout later.  That is what a
 *     crash or a kill of this program does, and what its stop at shutdown
 *     does: a shutdown that then hangs is still reset.  A clean reboot or
 *     poweroff stops the watchdog itself (the driver's shutdown method).
 *   - The magic character "V" as the last byte written makes the close STOP
 *     the watchdog, unless the kernel was built with nowayout: --disarm and
 *     SIGUSR1 do that, for tests.
 *   - Opening the device starts a watchdog that is stopped.  So the program
 *     first looks whether the kernel armed it and touches nothing when it
 *     did not: whether there is a watchdog at all is the kernel's decision
 *     (s3c2410_wdt.tmr_atboot=1 on its command line), never this program's.
 *     That decision is read on the command line itself: no sysfs file shows
 *     the core's WDOG_HW_RUNNING (the class's "status" holds the WDIOF_*
 *     flags of WDIOC_GETSTATUS, 0x8000 = KEEPALIVEPING on the tablet, and
 *     "state" only says whether userspace has it open), and tmr_atboot is a
 *     module parameter without a sysfs file.  The first image read "status"
 *     as WDOG_HW_RUNNING and so never fed anything (tablet, 2026-11-25).
 *     The command line is never printed: it holds the device's serial number.
 *
 * Usage:
 *   t715-watchdog-keeper [--interval SECONDS] [--device FILE] [--cmdline FILE]
 *   t715-watchdog-keeper --disarm [--device FILE]
 *   t715-watchdog-keeper --check     touches nothing, exits 0: what the boot
 *                                    mark unit runs first, so that an image
 *                                    whose keeper cannot even run never marks
 *                                    a boot as up (the loader would then try
 *                                    it again at every boot, and nothing
 *                                    would ever feed the watchdog)
 *   SIGTERM, SIGINT, SIGHUP: stop, the watchdog left running.
 *   SIGUSR1: stop it ("V"), then exit.
 * Exit: 0 when it stopped as asked or had nothing to feed; 1 when it could
 * not do its job (systemd then starts it again).
 */

#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <getopt.h>
#include <linux/watchdog.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

#define DEFAULT_DEVICE "/dev/watchdog"
#define DEFAULT_CMDLINE "/proc/cmdline"
#define ATBOOT_PARAM "s3c2410_wdt.tmr_atboot"
#define DEFAULT_INTERVAL 5
#define OPEN_RETRY_MS 15000
#define OPEN_RETRY_STEP_MS 250

static volatile sig_atomic_t asked_to_stop;
static volatile sig_atomic_t asked_to_disarm;

static void on_stop(int signal_number) { (void)signal_number; asked_to_stop = 1; }
static void on_disarm(int signal_number) { (void)signal_number; asked_to_disarm = 1; }

static int catch(int signal_number, void (*handler)(int))
{
	struct sigaction action;
	memset(&action, 0, sizeof action);
	action.sa_handler = handler;
	sigemptyset(&action.sa_mask);
	return sigaction(signal_number, &action, NULL);
}

static void sleep_ms(long milliseconds)
{
	struct timespec want = { milliseconds / 1000, (milliseconds % 1000) * 1000000L };

	while (clock_nanosleep(CLOCK_MONOTONIC, 0, &want, &want) == EINTR) {
		if (asked_to_stop || asked_to_disarm)
			return;
	}
}

/* param_is: 1 when the command-line word WORD sets the parameter NAME
 * (NAME=...), the kernel's way: "-" and "_" are the same character in a
 * parameter's name. */
static int param_is(const char *word, const char *name)
{
	for (; *name; word++, name++) {
		char a = *word == '-' ? '_' : *word, b = *name == '-' ? '_' : *name;

		if (a != b)
			return 0;
	}
	return *word == '=';
}

/* kernel_left_it_running: 1 when the kernel's command line has
 * s3c2410_wdt.tmr_atboot set to a value other than 0 (the driver then starts
 * the watchdog at its probe, or keeps the loader's running), 0 when it does
 * not (the driver's default, 0, stops a running one), -1 when CMDLINE cannot
 * be read.  The last such word counts, as in the kernel.  Nothing of the
 * command line is printed. */
static int kernel_left_it_running(const char *cmdline)
{
	static char line[16384];
	const size_t name_length = strlen(ATBOOT_PARAM);
	FILE *file;
	size_t length;
	char *word, *save = NULL;
	int running = 0;

	file = fopen(cmdline, "r");
	if (!file)
		return -1;
	length = fread(line, 1, sizeof line - 1, file);
	fclose(file);
	if (length == 0)
		return -1;
	line[length] = '\0';
	for (word = strtok_r(line, " \t\n", &save); word; word = strtok_r(NULL, " \t\n", &save)) {
		if (param_is(word, ATBOOT_PARAM))
			running = strtol(word + name_length + 1, NULL, 0) != 0;
	}
	memset(line, 0, sizeof line);
	return running;
}

/* open_device: a descriptor on DEVICE, retrying while another holder has not
 * let go of it (EBUSY) or its node is not there yet (ENOENT).  On failure
 * open_error says why. */
static int open_error;

static int open_device(const char *device)
{
	long waited = 0;
	int fd;

	for (;;) {
		fd = open(device, O_WRONLY | O_CLOEXEC);
		if (fd >= 0)
			return fd;
		open_error = errno;
		if (errno != EBUSY && errno != ENOENT)
			return -1;
		if (waited >= OPEN_RETRY_MS || asked_to_stop || asked_to_disarm)
			return -1;
		sleep_ms(OPEN_RETRY_STEP_MS);
		waited += OPEN_RETRY_STEP_MS;
	}
}

int main(int argc, char **argv)
{
	static const struct option options[] = {
		{ "interval", required_argument, NULL, 'i' },
		{ "device", required_argument, NULL, 'd' },
		{ "cmdline", required_argument, NULL, 'c' },
		{ "disarm", no_argument, NULL, 'D' },
		{ "check", no_argument, NULL, 'C' },
		{ "help", no_argument, NULL, 'h' },
		{ NULL, 0, NULL, 0 },
	};
	const char *device = DEFAULT_DEVICE;
	const char *cmdline = DEFAULT_CMDLINE;
	int interval = DEFAULT_INTERVAL;
	int disarm_only = 0;
	int fd, status = 0, timeout = 0, bootstatus = 0, running;
	int option;

	while ((option = getopt_long(argc, argv, "i:d:c:DCh", options, NULL)) != -1) {
		switch (option) {
		case 'i':
			interval = atoi(optarg);
			if (interval < 1 || interval > 3600) {
				fprintf(stderr, "t715-watchdog-keeper: --interval: 1 to 3600 seconds\n");
				return 2;
			}
			break;
		case 'd': device = optarg; break;
		case 'c': cmdline = optarg; break;
		case 'D': disarm_only = 1; break;
		case 'C':
			printf("t715-watchdog-keeper: ok\n");
			return 0;
		case 'h':
			printf("usage: t715-watchdog-keeper [--interval SECONDS] [--device FILE] [--cmdline FILE]\n"
			       "       t715-watchdog-keeper --disarm [--device FILE]\n");
			return 0;
		default:
			return 2;
		}
	}

	if (catch(SIGTERM, on_stop) || catch(SIGINT, on_stop) || catch(SIGHUP, on_stop) ||
	    catch(SIGUSR1, on_disarm)) {
		perror("t715-watchdog-keeper: sigaction");
		return 1;
	}

	if (!disarm_only) {
		running = kernel_left_it_running(cmdline);
		if (running < 0) {
			printf("t715-watchdog-keeper: cannot tell whether the kernel armed the watchdog"
			       " (%s unreadable): not touching %s\n", cmdline, device);
			return 0;
		}
		if (running == 0) {
			printf("t715-watchdog-keeper: the kernel left the watchdog stopped"
			       " (no %s=1 on its command line): not starting it\n", ATBOOT_PARAM);
			return 0;
		}
	}

	fd = open_device(device);
	if (fd < 0) {
		printf("t715-watchdog-keeper: cannot open %s: %s\n", device, strerror(open_error));
		return 1;
	}

	/* Information only: a driver without these ioctls keeps the defaults. */
	(void)ioctl(fd, WDIOC_GETTIMEOUT, &timeout);
	(void)ioctl(fd, WDIOC_GETBOOTSTATUS, &bootstatus);
	if (!disarm_only) {
		/* A timeout shorter than four pings: ping four times as often. */
		if (timeout > 0 && timeout < 4 * interval)
			interval = timeout / 4 >= 1 ? timeout / 4 : 1;
		printf("t715-watchdog-keeper: %s open, timeout %d s, ping every %d s%s\n",
		       device, timeout, interval,
		       (bootstatus & WDIOF_CARDRESET) ? ", the previous reset was the watchdog" : "");
	}
	fflush(stdout);

	if (!disarm_only) {
		for (;;) {
			struct timespec want = { interval, 0 }, left;
			int result;

			while (!asked_to_stop && !asked_to_disarm) {
				result = clock_nanosleep(CLOCK_MONOTONIC, 0, &want, &left);
				if (result == 0)
					break;		/* the interval is over */
				if (result == EINTR) {
					want = left;	/* a signal came: the loop's test sees it */
					continue;
				}
				printf("t715-watchdog-keeper: clock_nanosleep: %s\n", strerror(result));
				status = 1;
				goto out;
			}
			if (asked_to_stop || asked_to_disarm)
				break;
			/* Any byte but "V" is a keepalive. */
			if (write(fd, ".", 1) != 1) {
				printf("t715-watchdog-keeper: keepalive: %s\n", strerror(errno));
				status = 1;
				break;
			}
		}
	}

out:
	if (asked_to_disarm || disarm_only) {
		if (write(fd, "V", 1) == 1) {
			printf("t715-watchdog-keeper: disarm requested: magic close of %s\n", device);
		} else {
			printf("t715-watchdog-keeper: disarm requested, but the magic close failed: %s\n",
			       strerror(errno));
			status = 1;
		}
	} else {
		printf("t715-watchdog-keeper: stopped, the watchdog is left running\n");
	}
	fflush(stdout);
	close(fd);
	return status;
}
