#include "spsc_ring_buffer.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

#define SPSC_MIN_CAPACITY  1024
#define SPSC_MAX_CAPACITY  16777216

struct SPSCRingBuffer {
    uint8_t *buffer;
    size_t capacity;   /* always a power of two */
    size_t mask;       /* capacity - 1, for fast wrapping */

    /* head: next write position (owned by producer)
       tail: next read  position (owned by consumer)
       Both are monotonically increasing uint64 counters; actual index
       is obtained via (counter & mask).  Using 64-bit counters avoids
       ambiguity between "empty" and "full" that plagues same-sized
       head/tail designs. */
    _Atomic uint64_t head;  /* written by producer, read by consumer */
    _Atomic uint64_t tail;  /* written by consumer, read by producer */
};

/* Round up to next power of two (or return v if already power of two). */
static size_t next_power_of_two(size_t v) {
    if (v == 0) return 1;
    v--;
    v |= v >> 1;
    v |= v >> 2;
    v |= v >> 4;
    v |= v >> 8;
    v |= v >> 16;
    v |= v >> 32;
    return v + 1;
}

SPSCRingBuffer *spsc_ring_buffer_create(size_t min_capacity) {
    if (min_capacity < SPSC_MIN_CAPACITY || min_capacity > SPSC_MAX_CAPACITY) {
        return NULL;
    }

    size_t capacity = next_power_of_two(min_capacity);
    if (capacity > SPSC_MAX_CAPACITY) {
        capacity = SPSC_MAX_CAPACITY;  /* SPSC_MAX_CAPACITY is 2^24, already power of two */
    }

    SPSCRingBuffer *rb = calloc(1, sizeof(SPSCRingBuffer));
    if (!rb) return NULL;

    rb->buffer = malloc(capacity);
    if (!rb->buffer) {
        free(rb);
        return NULL;
    }

    rb->capacity = capacity;
    rb->mask = capacity - 1;
    atomic_store_explicit(&rb->head, 0, memory_order_relaxed);
    atomic_store_explicit(&rb->tail, 0, memory_order_relaxed);

    return rb;
}

void spsc_ring_buffer_destroy(SPSCRingBuffer *rb) {
    if (!rb) return;
    free(rb->buffer);
    free(rb);
}

size_t spsc_ring_buffer_write(SPSCRingBuffer *rb, const uint8_t *data, size_t len) {
    if (!rb || !data || len == 0) return 0;

    /* If the write is larger than the entire buffer, only keep the tail end. */
    if (len > rb->capacity) {
        data += len - rb->capacity;
        len = rb->capacity;
    }

    uint64_t head = atomic_load_explicit(&rb->head, memory_order_relaxed);
    uint64_t tail = atomic_load_explicit(&rb->tail, memory_order_acquire);

    uint64_t used = head - tail;
    uint64_t free_space = rb->capacity - used;

    /* If not enough space, advance tail to discard oldest data. */
    if (len > free_space) {
        uint64_t discard = len - free_space;
        atomic_store_explicit(&rb->tail, tail + discard, memory_order_release);
    }

    /* Write data in up to two segments (wrap-around). */
    size_t start = (size_t)(head & rb->mask);
    size_t first_chunk = rb->capacity - start;

    if (first_chunk >= len) {
        memcpy(rb->buffer + start, data, len);
    } else {
        memcpy(rb->buffer + start, data, first_chunk);
        memcpy(rb->buffer, data + first_chunk, len - first_chunk);
    }

    atomic_store_explicit(&rb->head, head + len, memory_order_release);
    return len;
}

size_t spsc_ring_buffer_read(SPSCRingBuffer *rb, uint8_t *out, size_t max_len) {
    if (!rb || !out || max_len == 0) return 0;

    uint64_t tail = atomic_load_explicit(&rb->tail, memory_order_relaxed);
    uint64_t head = atomic_load_explicit(&rb->head, memory_order_acquire);

    uint64_t available = head - tail;
    if (available == 0) return 0;

    size_t to_read = (available < max_len) ? (size_t)available : max_len;

    /* Read data in up to two segments (wrap-around). */
    size_t start = (size_t)(tail & rb->mask);
    size_t first_chunk = rb->capacity - start;

    if (first_chunk >= to_read) {
        memcpy(out, rb->buffer + start, to_read);
    } else {
        memcpy(out, rb->buffer + start, first_chunk);
        memcpy(out + first_chunk, rb->buffer, to_read - first_chunk);
    }

    atomic_store_explicit(&rb->tail, tail + to_read, memory_order_release);
    return to_read;
}

size_t spsc_ring_buffer_available_read(const SPSCRingBuffer *rb) {
    if (!rb) return 0;
    uint64_t tail = atomic_load_explicit(&rb->tail, memory_order_acquire);
    uint64_t head = atomic_load_explicit(&rb->head, memory_order_acquire);
    return (size_t)(head - tail);
}

size_t spsc_ring_buffer_available_write(const SPSCRingBuffer *rb) {
    if (!rb) return 0;
    uint64_t tail = atomic_load_explicit(&rb->tail, memory_order_acquire);
    uint64_t head = atomic_load_explicit(&rb->head, memory_order_acquire);
    return rb->capacity - (size_t)(head - tail);
}

size_t spsc_ring_buffer_capacity(const SPSCRingBuffer *rb) {
    if (!rb) return 0;
    return rb->capacity;
}
