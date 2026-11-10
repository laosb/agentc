#ifndef AGENTC_LWIP_ARCH_CC_H
#define AGENTC_LWIP_ARCH_CC_H
#include <stdint.h>
#include <stdlib.h>
/* Darwin's modular headers export endian macros too. Give the private stack
 * one unambiguous definition, without importing the system networking ABI. */
#undef LITTLE_ENDIAN
#undef BIG_ENDIAN
#undef BYTE_ORDER
#define LITTLE_ENDIAN 1234
#define BIG_ENDIAN 4321
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
#define BYTE_ORDER LITTLE_ENDIAN
#else
#define BYTE_ORDER BIG_ENDIAN
#endif
#define LWIP_NO_STDINT_H 0
#define LWIP_RAND() ((uint32_t)arc4random())
#define LWIP_PLATFORM_DIAG(x) do { } while (0)
#define LWIP_PLATFORM_ASSERT(x) abort()
#endif
