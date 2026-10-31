/* tools/mkbootimg/samsung_dtbh.h -- build shim for the dtbhtool reference.
 *
 * The C sources "must be provided by the device tree"
 * (src/hardware_samsung-18.1/dtbhtool/dtbimg.c:38); this is the
 * verbatim copy of src/device_gts28ltexx/include/samsung_dtbh.h so the
 * reference tools build for the SM-T715 (gts28ltexx) target.  Never edit
 * src/ -- adjust this shim instead.
 */

#ifndef _SAMSUNG_DTBH_H_
#define _SAMSUNG_DTBH_H_

#define DTBH_MAGIC         "DTBH"
#define DTBH_VERSION       2
 /* taken from stock dtb.image (strings dtb.img) */
#define DTBH_PLATFORM      "gts28"
#define DTBH_SUBTYPE       "gts28_eur_open"
 /* Hardcoded entry
  *
  * Taken from /proc/last_kmsg after 'reboot bootloader'
  */
#define DTBH_PLATFORM_CODE 0x3138
#define DTBH_SUBTYPE_CODE  0x36480ee3

/* DTBH_MAGIC + DTBH_VERSION + DTB counts */
#define DT_HEADER_PHYS_SIZE 12

/*
 * keep the eight uint32_t entries first in this struct so we can memcpy them to the file
 */
#define DT_ENTRY_PHYS_SIZE (sizeof(uint32_t) * 8)

#endif // _SAMSUNG_DTBH_H_
