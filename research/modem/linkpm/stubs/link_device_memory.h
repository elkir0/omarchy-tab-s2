#ifndef STUB_LINK_DEVICE_MEMORY_H
#define STUB_LINK_DEVICE_MEMORY_H
#include "modem_prj.h"
struct mem_link_device { struct link_device link_dev; wait_queue_head_t wq; };
#define ld_to_mem_link_device(ld) container_of(ld, struct mem_link_device, link_dev)
#endif
