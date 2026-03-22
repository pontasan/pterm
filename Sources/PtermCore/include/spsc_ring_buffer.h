#ifndef PTERM_SPSC_RING_BUFFER_H
#define PTERM_SPSC_RING_BUFFER_H

#include <stddef.h>
#include <stdint.h>

/// Lock-free single-producer single-consumer byte ring buffer.
///
/// Designed for I/O hook data delivery where a single PTY read thread
/// (producer) writes data and a single hook delivery thread (consumer)
/// reads it.  When the buffer is full, writes are lossy — the oldest
/// unread data is silently dropped to ensure the producer never blocks.
///
/// Capacity is rounded up to the next power of two for efficient
/// mask-based index wrapping.  Valid capacity range: 1024–16777216.
///
/// Thread safety: exactly one producer thread and one consumer thread
/// may operate concurrently without external synchronization.  Multiple
/// producers or multiple consumers require external locking.
typedef struct SPSCRingBuffer SPSCRingBuffer;

/// Create a ring buffer with at least `min_capacity` bytes.
/// Actual capacity is rounded up to the next power of two.
/// Returns NULL if min_capacity is outside [1024, 16777216] or allocation fails.
SPSCRingBuffer *spsc_ring_buffer_create(size_t min_capacity);

/// Destroy a ring buffer and free all resources.
/// Passing NULL is a no-op.
void spsc_ring_buffer_destroy(SPSCRingBuffer *rb);

/// Write `len` bytes from `data` into the buffer (producer side).
/// Returns the number of bytes actually written.  If the buffer has
/// insufficient space, the oldest unread data is discarded to make room,
/// and the full `len` bytes are written.  Returns 0 only if `len` is 0
/// or `rb`/`data` is NULL.
size_t spsc_ring_buffer_write(SPSCRingBuffer *rb, const uint8_t *data, size_t len);

/// Read up to `max_len` bytes from the buffer into `out` (consumer side).
/// Returns the number of bytes actually read (0 if empty).
/// Returns 0 if `rb`/`out` is NULL or `max_len` is 0.
size_t spsc_ring_buffer_read(SPSCRingBuffer *rb, uint8_t *out, size_t max_len);

/// Return the number of bytes available for reading (consumer perspective).
size_t spsc_ring_buffer_available_read(const SPSCRingBuffer *rb);

/// Return the number of bytes available for writing without discarding
/// existing data (producer perspective).
size_t spsc_ring_buffer_available_write(const SPSCRingBuffer *rb);

/// Return the actual capacity of the buffer (power-of-two).
size_t spsc_ring_buffer_capacity(const SPSCRingBuffer *rb);

#endif /* PTERM_SPSC_RING_BUFFER_H */
