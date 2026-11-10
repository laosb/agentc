/*
 * Mechanical adapter for the unmodified lwIP raw API. Policy, translation,
 * scheduling and all host networking live in Swift. This file owns only lwIP
 * objects, whose lifetimes cannot be expressed by Swift's Clang importer.
 */
#include "CSOCKSNetwork.h"
#include "lwip/init.h"
#include "lwip/netif.h"
#include "lwip/timeouts.h"
#include "lwip/tcp.h"
#include "lwip/etharp.h"
#include "netif/ethernet.h"
#include <string.h>
#include <time.h>

#define FLOW_COUNT 128
struct flow {
  struct tcp_pcb *listener;
  struct tcp_pcb *pcb;
  struct pbuf *received;
  int state;
  int eof;
  int tx_closed;
  int failed;
};
static struct flow flows[FLOW_COUNT];
static struct netif interface;
static agentc_lwip_output emit;
static void *emit_context;
static int initialized;
static u8_t extension_id;

u32_t sys_now(void) {
  struct timespec now;
  clock_gettime(CLOCK_MONOTONIC, &now);
  return (u32_t)((uint64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000);
}

static err_t link_output(struct netif *netif, struct pbuf *p) {
  (void)netif;
  uint8_t frame[1514];
  if (p->tot_len > sizeof(frame)) return ERR_BUF;
  pbuf_copy_partial(p, frame, p->tot_len, 0);
  emit(emit_context, frame, p->tot_len);
  return ERR_OK;
}

static err_t interface_init(struct netif *netif) {
  static const uint8_t mac[] = {2, 0, 0, 0, 0, 1};
  netif->name[0] = 's'; netif->name[1] = 'p';
  netif->output = etharp_output;
  netif->linkoutput = link_output;
  netif->mtu = 1500;
  netif->hwaddr_len = 6;
  memcpy(netif->hwaddr, mac, 6);
  netif->flags = NETIF_FLAG_BROADCAST | NETIF_FLAG_ETHARP;
  return ERR_OK;
}

static void pcb_destroyed(u8_t id, void *data) {
  (void)id;
  struct flow *f = data;
  f->pcb = NULL;
  /* A LAST_ACK ACK can destroy the PCB while Swift is still sending the
   * accepted guest bytes upstream. The application-owned pbuf chain and FIN
   * survive orderly destruction; reset/abort must not preserve that state. */
  f->state = f->state == 2 && f->eof && f->tx_closed && !f->failed ? 4 : 0;
}

static void connection_error(void *arg, err_t error) {
  struct flow *f = arg;
  if (f == NULL || error == ERR_CLSD) return;
  f->failed = 1;
  f->state = 0;
}

static const struct tcp_ext_arg_callbacks child_extensions = {
  .destroy = pcb_destroyed, .passive_open = NULL
};

static err_t passive_open(u8_t id, struct tcp_pcb_listen *listener,
                          struct tcp_pcb *pcb) {
  struct flow *f = tcp_ext_arg_get((struct tcp_pcb *)listener, id);
  if (f->pcb != NULL) return ERR_ABRT;
  f->pcb = pcb;
  tcp_ext_arg_set(pcb, id, f);
  tcp_ext_arg_set_callbacks(pcb, id, &child_extensions);
  return ERR_OK;
}

static const struct tcp_ext_arg_callbacks listener_extensions = {
  .destroy = NULL, .passive_open = passive_open
};

static err_t received(void *arg, struct tcp_pcb *pcb, struct pbuf *p, err_t err) {
  (void)pcb; (void)err;
  struct flow *f = arg;
  if (p == NULL) { f->eof = 1; return ERR_OK; }
  if (f->received != NULL) {
    if ((size_t)f->received->tot_len + p->tot_len > TCP_WND) return ERR_MEM;
    pbuf_cat(f->received, p);
  } else {
    f->received = p;
  }
  /* Accept the whole advertised receive window. Leaving refused_data on the
   * PCB would let a FIN/ACK destroy bytes before the upstream socket drains. */
  /* tcp_recved is intentionally delayed until the SOCKS socket accepts bytes. */
  return ERR_OK;
}

static err_t accepted(void *arg, struct tcp_pcb *pcb, err_t err) {
  struct flow *f = arg;
  if (err != ERR_OK || f->pcb != pcb) return ERR_VAL;
  f->state = 2;
  tcp_arg(pcb, f);
  tcp_recv(pcb, received);
  tcp_err(pcb, connection_error);
  tcp_nagle_disable(pcb);
  if (f->listener != NULL) {
    tcp_close(f->listener);
    f->listener = NULL;
  }
  return ERR_OK;
}

int agentc_lwip_init(agentc_lwip_output output, void *context) {
  if (initialized || output == NULL) return 0;
  initialized = 1;
  emit = output; emit_context = context;
  lwip_init();
  extension_id = tcp_ext_arg_alloc_id();
  ip4_addr_t address, mask, gateway;
  IP4_ADDR(&address, 10, 87, 0, 1);
  IP4_ADDR(&mask, 255, 255, 255, 0);
  ip4_addr_set_zero(&gateway);
  if (!netif_add(&interface, &address, &mask, &gateway, NULL,
                 interface_init, ethernet_input)) return 0;
  netif_set_default(&interface);
  netif_set_up(&interface);
  netif_set_link_up(&interface);
  return 1;
}

void agentc_lwip_input(const uint8_t *bytes, size_t length) {
  if (length < 14 || length > 1514) return;
  struct pbuf *p = pbuf_alloc(PBUF_RAW, (u16_t)length, PBUF_POOL);
  if (p == NULL) return;
  if (pbuf_take(p, bytes, (u16_t)length) != ERR_OK ||
      interface.input(p, &interface) != ERR_OK) pbuf_free(p);
}

void agentc_lwip_tick(void) { sys_check_timeouts(); }

int agentc_lwip_listen(unsigned slot, uint16_t port) {
  if (slot >= FLOW_COUNT) return 0;
  struct flow *f = &flows[slot];
  if (f->pcb || f->listener || f->received) return 0;
  memset(f, 0, sizeof(*f));
  struct tcp_pcb *pcb = tcp_new();
  if (pcb == NULL) return 0;
  if (tcp_bind(pcb, netif_ip_addr4(&interface), port) != ERR_OK) {
    tcp_abort(pcb); return 0;
  }
  f->listener = tcp_listen_with_backlog(pcb, 1);
  if (f->listener == NULL) { tcp_abort(pcb); return 0; }
  tcp_arg(f->listener, f);
  tcp_accept(f->listener, accepted);
  tcp_ext_arg_set(f->listener, extension_id, f);
  tcp_ext_arg_set_callbacks(f->listener, extension_id, &listener_extensions);
  f->state = 1;
  return 1;
}

int agentc_lwip_state(unsigned slot) {
  return slot < FLOW_COUNT ? flows[slot].state : 0;
}
int agentc_lwip_eof(unsigned slot) {
  return slot < FLOW_COUNT && flows[slot].eof;
}
size_t agentc_lwip_readable(unsigned slot) {
  return slot < FLOW_COUNT && flows[slot].received ? flows[slot].received->tot_len : 0;
}
size_t agentc_lwip_read(unsigned slot, uint8_t *bytes, size_t capacity) {
  if (slot >= FLOW_COUNT || !flows[slot].received) return 0;
  struct pbuf *p = flows[slot].received;
  if (capacity < p->tot_len) return 0;
  return pbuf_copy_partial(p, bytes, p->tot_len, 0);
}
void agentc_lwip_consume(unsigned slot, size_t length) {
  if (slot >= FLOW_COUNT) return;
  struct flow *f = &flows[slot];
  if (f->received && length <= f->received->tot_len) {
    /* New data may have been appended while Swift awaited its socket send.
     * Credit and remove only the prefix that was actually sent. */
    if (f->pcb && f->state == 2) tcp_recved(f->pcb, (u16_t)length);
    f->received = pbuf_free_header(f->received, (u16_t)length);
  }
}
size_t agentc_lwip_send_capacity(unsigned slot) {
  if (slot >= FLOW_COUNT || flows[slot].state != 2 || flows[slot].tx_closed) return 0;
  return tcp_sndbuf(flows[slot].pcb);
}
int agentc_lwip_write(unsigned slot, const uint8_t *bytes, size_t length) {
  if (slot >= FLOW_COUNT || length > 32768 ||
      flows[slot].state != 2 || flows[slot].tx_closed) return 0;
  struct tcp_pcb *pcb = flows[slot].pcb;
  if (tcp_write(pcb, bytes, (u16_t)length, TCP_WRITE_FLAG_COPY) != ERR_OK) return 0;
  tcp_output(pcb);
  return 1;
}
int agentc_lwip_finish(unsigned slot) {
  if (slot < FLOW_COUNT && flows[slot].state == 4) return 1;
  if (slot >= FLOW_COUNT || flows[slot].state != 2) return 0;
  struct flow *f = &flows[slot];
  if (!f->tx_closed && tcp_shutdown(f->pcb, 0, 1) != ERR_OK) return 0;
  f->tx_closed = 1;
  return 1;
}
void agentc_lwip_release(unsigned slot) {
  if (slot >= FLOW_COUNT) return;
  struct flow *f = &flows[slot];
  if (f->received) return;
  if (f->state == 4) { f->state = 0; return; }
  if (f->state != 2) return;
  f->state = 3;
  tcp_arg(f->pcb, NULL);
  tcp_recv(f->pcb, NULL);
  tcp_err(f->pcb, NULL);
  tcp_close(f->pcb);
}
void agentc_lwip_abort(unsigned slot) {
  if (slot >= FLOW_COUNT) return;
  struct flow *f = &flows[slot];
  if (f->listener) { tcp_close(f->listener); f->listener = NULL; }
  if (f->pcb) tcp_abort(f->pcb);
  if (f->received) { pbuf_free(f->received); f->received = NULL; }
  f->state = 0;
}
