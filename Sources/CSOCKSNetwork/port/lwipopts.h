#ifndef AGENTC_LWIPOPTS_H
#define AGENTC_LWIPOPTS_H
/* Single-threaded raw API; one stack per child process. No native IP forwarding,
 * resolver, DHCP, socket API, or IPv6 path exists in this build. */
#define NO_SYS 1
#define SYS_LIGHTWEIGHT_PROT 0
#define LWIP_SOCKET 0
#define LWIP_NETCONN 0
#define LWIP_DONT_PROVIDE_BYTEORDER_FUNCTIONS 1
#define LWIP_IPV4 1
#define LWIP_IPV6 0
#define LWIP_ARP 1
#define LWIP_ETHERNET 1
#define LWIP_TCP 1
#define LWIP_UDP 0
#define LWIP_ICMP 0
#define LWIP_RAW 0
#define LWIP_DNS 0
#define LWIP_DHCP 0
#define LWIP_AUTOIP 0
#define IP_FORWARD 0
#define IP_REASSEMBLY 0
#define IP_FRAG 0
#define LWIP_STATS 0
#define MEM_ALIGNMENT 8
#define MEM_SIZE (4 * 1024 * 1024)
#define MEMP_NUM_TCP_PCB 256
#define MEMP_NUM_TCP_PCB_LISTEN 128
#define MEMP_NUM_TCP_SEG 4096
#define PBUF_POOL_SIZE 256
#define TCP_MSS 1460
#define TCP_WND 32768
#define TCP_SND_BUF 32768
#define TCP_SND_QUEUELEN 128
#define LWIP_TCP_KEEPALIVE 1
#define LWIP_TCP_PCB_NUM_EXT_ARGS 1
#define TCP_LISTEN_BACKLOG 1
#define LWIP_NETIF_HOSTNAME 0
#endif
