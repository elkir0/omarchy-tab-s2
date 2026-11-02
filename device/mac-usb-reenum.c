/*
 * Ask macOS to re-enumerate the tablet: for the day the Mac keeps a dead USB
 * session (the device is still in ioreg, nothing answers on 172.16.42.1) and
 * ignores the tablet plugged back into the same port.  Touches only devices
 * named "SM-T715".
 *
 *   cc -Wno-deprecated-declarations -o /tmp/mac-usb-reenum device/mac-usb-reenum.c \
 *      -framework IOKit -framework CoreFoundation && /tmp/mac-usb-reenum
 */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdio.h>
#include <string.h>
int main(void)
{
	int found = 0;
	io_iterator_t it;
	io_service_t s;
	kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault,
			IOServiceMatching("IOUSBHostDevice"), &it);
	if (kr) { printf("match %x\n", kr); return 1; }
	while ((s = IOIteratorNext(it))) {
		io_name_t n;
		IORegistryEntryGetName(s, n);
		if (!strstr(n, "SM-T715")) { IOObjectRelease(s); continue; }
		found++;
		IOCFPlugInInterface **pi = NULL;
		SInt32 score;
		kr = IOCreatePlugInInterfaceForService(s, kIOUSBDeviceUserClientTypeID,
				kIOCFPlugInInterfaceID, &pi, &score);
		printf("%s plugin %x\n", n, kr);
		if (kr || !pi) continue;
		IOUSBDeviceInterface187 **d = NULL;
		HRESULT h = (*pi)->QueryInterface(pi,
				CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID187), (LPVOID *)&d);
		(*pi)->Release(pi);
		printf("query %x\n", (int)h);
		if (h || !d) continue;
		kr = (*d)->USBDeviceOpen(d);
		printf("open %x\n", kr);
		if (kr) { kr = (*d)->USBDeviceOpenSeize(d); printf("seize %x\n", kr); }
		kr = (*d)->USBDeviceReEnumerate(d, 0);
		printf("reenumerate %x\n", kr);
		(*d)->USBDeviceClose(d);
		(*d)->Release(d);
	}
	printf("found %d\n", found);
	return 0;
}
