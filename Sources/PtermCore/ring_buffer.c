#include "ring_buffer.h"
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

static RingBuffer *ring_buffer_alloc_struct(size_t capacity) {
    RingBuffer *rb = calloc(1, sizeof(RingBuffer));
    if (!rb) return NULL;

    rb->data_capacity = capacity;
    rb->write_offset = 0;
    rb->row_capacity = RING_BUFFER_MAX_ROWS;
    rb->row_count = 0;
    rb->row_head = 0;
    rb->row_tail = 0;
    rb->bytes_used = 0;
    rb->flags = 0;
    rb->mmap_fd = -1;
    rb->mmap_path = NULL;
    rb->copy_buf = NULL;
    rb->copy_buf_cap = 0;

    rb->rows = calloc(rb->row_capacity, sizeof(RingRowEntry));
    if (!rb->rows) {
        free(rb);
        return NULL;
    }

    return rb;
}

RingBuffer *ring_buffer_create(size_t capacity) {
    if (capacity == 0) return NULL;

    RingBuffer *rb = ring_buffer_alloc_struct(capacity);
    if (!rb) return NULL;

    rb->data = malloc(capacity);
    if (!rb->data) {
        free(rb->rows);
        free(rb);
        return NULL;
    }

    memset(rb->data, 0, capacity);
    return rb;
}

RingBuffer *ring_buffer_create_mmap(const char *path, size_t capacity) {
    if (!path || capacity == 0) return NULL;

    RingBuffer *rb = ring_buffer_alloc_struct(capacity);
    if (!rb) return NULL;

    /* O_NOFOLLOW prevents symlink attacks */
    int fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW, 0600);
    if (fd < 0) {
        free(rb->rows);
        free(rb);
        return NULL;
    }

    /* Extend file to desired capacity */
    if (ftruncate(fd, (off_t)capacity) < 0) {
        close(fd);
        free(rb->rows);
        free(rb);
        return NULL;
    }

    void *mapped = mmap(NULL, capacity, PROT_READ | PROT_WRITE,
                        MAP_SHARED, fd, 0);
    if (mapped == MAP_FAILED) {
        close(fd);
        free(rb->rows);
        free(rb);
        return NULL;
    }

    rb->data = (uint8_t *)mapped;
    rb->mmap_fd = fd;
    rb->flags |= RING_FLAG_MMAP;

    /* Store path for destroy_and_unlink */
    rb->mmap_path = strdup(path);

    return rb;
}

static void ring_buffer_free_internal(RingBuffer *rb) {
    if (rb->flags & RING_FLAG_MMAP) {
        if (rb->data) {
            /* Zero data before unmapping to prevent data recovery */
            memset_s(rb->data, rb->data_capacity, 0, rb->data_capacity);
            munmap(rb->data, rb->data_capacity);
        }
        if (rb->mmap_fd >= 0) {
            close(rb->mmap_fd);
        }
    } else {
        if (rb->data) {
            memset_s(rb->data, rb->data_capacity, 0, rb->data_capacity);
            free(rb->data);
        }
    }

    free(rb->mmap_path);
    free(rb->copy_buf);
    free(rb->rows);
    free(rb);
}

void ring_buffer_destroy(RingBuffer *rb) {
    if (!rb) return;
    ring_buffer_free_internal(rb);
}

void ring_buffer_destroy_and_unlink(RingBuffer *rb) {
    if (!rb) return;

    /* Unlink the mmap file if it exists */
    if ((rb->flags & RING_FLAG_MMAP) && rb->mmap_path) {
        unlink(rb->mmap_path);
    }

    ring_buffer_free_internal(rb);
}

/*
 * Evict oldest rows until at least `needed` bytes are free.
 * This is how the ring buffer enforces memory limits.
 */
static void ring_buffer_evict(RingBuffer *rb, size_t needed) {
    while (rb->row_count > 0 && rb->bytes_used + needed > rb->data_capacity) {
        uint32_t head_idx = rb->row_head % rb->row_capacity;
        rb->bytes_used -= rb->rows[head_idx].length;
        rb->rows[head_idx].length = 0;
        rb->row_head++;
        rb->row_count--;
    }
}

int64_t ring_buffer_append_row(RingBuffer *rb,
                               const uint8_t *data, uint32_t length,
                               bool continuation) {
    if (!rb || !data) return -1;

    /* Reject rows larger than the entire buffer */
    if ((size_t)length > rb->data_capacity) return -1;

    /* Evict old rows to make space */
    ring_buffer_evict(rb, (size_t)length);

    /* Also evict if row index is full */
    if (rb->row_count >= rb->row_capacity) {
        uint32_t head_idx = rb->row_head % rb->row_capacity;
        rb->bytes_used -= rb->rows[head_idx].length;
        rb->row_head++;
        rb->row_count--;
    }

    /* Write data, handling wrap-around */
    size_t first_part = rb->data_capacity - rb->write_offset;
    if ((size_t)length <= first_part) {
        memcpy(rb->data + rb->write_offset, data, length);
    } else {
        memcpy(rb->data + rb->write_offset, data, first_part);
        memcpy(rb->data, data + first_part, (size_t)length - first_part);
    }

    /* Record row in index */
    uint32_t tail_idx = rb->row_tail % rb->row_capacity;
    rb->rows[tail_idx].offset = (uint32_t)rb->write_offset;
    rb->rows[tail_idx].length = length;
    rb->rows[tail_idx].flags = continuation ? 1 : 0;
    memset(rb->rows[tail_idx].reserved, 0, sizeof(rb->rows[tail_idx].reserved));

    /* Advance write pointer */
    rb->write_offset = (rb->write_offset + (size_t)length) % rb->data_capacity;
    rb->bytes_used += (size_t)length;
    rb->row_tail++;
    rb->row_count++;

    return (int64_t)(rb->row_tail - 1);
}

bool ring_buffer_get_row(RingBuffer *rb, uint32_t row_index,
                         const uint8_t **out_data, uint32_t *out_length,
                         bool *out_continuation) {
    if (!rb || row_index >= rb->row_count) return false;

    uint32_t actual_idx = (rb->row_head + row_index) % rb->row_capacity;
    const RingRowEntry *entry = &rb->rows[actual_idx];

    if (entry->length == 0) return false;

    /* Check for wrap-around read */
    size_t end = (size_t)entry->offset + (size_t)entry->length;
    if (end <= rb->data_capacity) {
        /* Contiguous read */
        if (out_data) *out_data = rb->data + entry->offset;
    } else {
        /* Data wraps around the buffer boundary.
         * Copy both segments into a contiguous temporary buffer. */
        size_t first = rb->data_capacity - entry->offset;
        size_t second = (size_t)entry->length - first;

        if ((size_t)entry->length > rb->copy_buf_cap) {
            uint8_t *new_buf = realloc(rb->copy_buf, (size_t)entry->length);
            if (!new_buf) return false;
            rb->copy_buf = new_buf;
            rb->copy_buf_cap = (size_t)entry->length;
        }

        memcpy(rb->copy_buf, rb->data + entry->offset, first);
        memcpy(rb->copy_buf + first, rb->data, second);
        if (out_data) *out_data = rb->copy_buf;
    }

    if (out_length) *out_length = entry->length;
    if (out_continuation) *out_continuation = (entry->flags & 1) != 0;

    return true;
}

uint32_t ring_buffer_row_count(const RingBuffer *rb) {
    return rb ? rb->row_count : 0;
}

size_t ring_buffer_capacity(const RingBuffer *rb) {
    return rb ? rb->data_capacity : 0;
}

size_t ring_buffer_bytes_used(const RingBuffer *rb) {
    return rb ? rb->bytes_used : 0;
}

void ring_buffer_clear(RingBuffer *rb) {
    if (!rb) return;
    /* Zero data to prevent recovery of sensitive terminal content */
    if (rb->data) {
        memset_s(rb->data, rb->data_capacity, 0, rb->data_capacity);
    }
    rb->write_offset = 0;
    rb->row_count = 0;
    rb->row_head = 0;
    rb->row_tail = 0;
    rb->bytes_used = 0;
}
