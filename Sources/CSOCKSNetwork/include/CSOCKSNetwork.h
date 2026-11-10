#ifndef AGENTC_SOCKS_NETWORK_H
#define AGENTC_SOCKS_NETWORK_H
#include <stdint.h>
#include <stddef.h>

/* Single-owner raw-API adapter. All calls AND callbacks are synchronous on the
 * Swift engine actor. No socket IO, packet policy, threads, or resolver here.
 * Only one instance may ever be initialized in a process (private child). */
typedef void (*agentc_lwip_output)(void *, const uint8_t *, size_t);
int agentc_lwip_init(agentc_lwip_output output, void *context);
void agentc_lwip_input(const uint8_t *bytes, size_t length);
void agentc_lwip_tick(void);
int agentc_lwip_listen(unsigned slot, uint16_t port);
/* 0 = destroyed, 1 = pending handshake, 2 = accepted, 3 = closing,
 * 4 = orderly PCB destruction, but upstream bytes/FIN still need draining.
 * A slot MUST NOT be reused before state 0, including TCP TIME_WAIT. */
int agentc_lwip_state(unsigned slot);
int agentc_lwip_eof(unsigned slot);
size_t agentc_lwip_readable(unsigned slot);
size_t agentc_lwip_read(unsigned slot, uint8_t *bytes, size_t capacity);
void agentc_lwip_consume(unsigned slot, size_t length);
size_t agentc_lwip_send_capacity(unsigned slot);
int agentc_lwip_write(unsigned slot, const uint8_t *bytes, size_t length);
int agentc_lwip_finish(unsigned slot);
void agentc_lwip_release(unsigned slot);
void agentc_lwip_abort(unsigned slot);
#endif
