#include "ring_buffer.h"
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>

typedef struct {
    uint32_t magic;
    uint32_t version;
    uint64_t data_capacity;
    uint64_t max_data_capacity;
    uint64_t write_offset;
    uint64_t row_capacity;
    uint64_t row_count;
    uint64_t row_head;
    uint64_t row_tail;
    uint64_t bytes_used;
} RingBufferDiskHeader;

#define RING_BUFFER_DISK_MAGIC   0x5054524D  /* PTRM */
#define RING_BUFFER_DISK_VERSION 2

static void ring_buffer_zero_memory(void *ptr, size_t len) {
    if (!ptr || len == 0) return;
    volatile uint8_t *cursor = (volatile uint8_t *)ptr;
    while (len-- > 0) {
        *cursor++ = 0;
    }
}

static bool ring_buffer_mul_overflow(size_t a, size_t b, size_t *out) {
    if (a == 0 || b == 0) {
        *out = 0;
        return false;
    }
    if (a > SIZE_MAX / b) {
        return true;
    }
    *out = a * b;
    return false;
}

static bool ring_buffer_add_overflow(size_t a, size_t b, size_t *out) {
    if (a > SIZE_MAX - b) {
        return true;
    }
    *out = a + b;
    return false;
}

static size_t ring_buffer_mmap_length(size_t capacity) {
    size_t rows_bytes = 0;
    size_t total = 0;
    if (ring_buffer_mul_overflow(sizeof(RingRowEntry), (size_t)RING_BUFFER_MAX_ROWS, &rows_bytes)) {
        return 0;
    }
    if (ring_buffer_add_overflow(sizeof(RingBufferDiskHeader), rows_bytes, &total)) {
        return 0;
    }
    if (ring_buffer_add_overflow(total, capacity, &total)) {
        return 0;
    }
    return total;
}

static void ring_buffer_sync_header(RingBuffer *rb) {
    if (!rb || !(rb->flags & RING_FLAG_MMAP) || !rb->mmap_header) return;

    RingBufferDiskHeader *header = (RingBufferDiskHeader *)rb->mmap_header;
    header->magic = RING_BUFFER_DISK_MAGIC;
    header->version = RING_BUFFER_DISK_VERSION;
    header->data_capacity = (uint64_t)rb->data_capacity;
    header->max_data_capacity = (uint64_t)rb->max_data_capacity;
    header->write_offset = (uint64_t)rb->write_offset;
    header->row_capacity = (uint64_t)rb->row_capacity;
    header->row_count = (uint64_t)rb->row_count;
    header->row_head = rb->row_head;
    header->row_tail = rb->row_tail;
    header->bytes_used = (uint64_t)rb->bytes_used;
}

static RingBuffer *ring_buffer_alloc_struct(size_t capacity, size_t max_capacity) {
    RingBuffer *rb = calloc(1, sizeof(RingBuffer));
    if (!rb) return NULL;

    rb->data_capacity = capacity;
    rb->max_data_capacity = max_capacity;
    rb->write_offset = 0;
    rb->row_capacity = RING_BUFFER_MAX_ROWS;
    rb->row_count = 0;
    rb->row_head = 0;
    rb->row_tail = 0;
    rb->bytes_used = 0;
    rb->flags = 0;
    rb->mmap_fd = -1;
    rb->mmap_path = NULL;
    rb->mapping_base = NULL;
    rb->mapping_length = 0;
    rb->mmap_header = NULL;
    rb->copy_buf = NULL;
    rb->copy_buf_cap = 0;

    if (max_capacity > 0) {
        rb->rows = calloc(rb->row_capacity, sizeof(RingRowEntry));
        if (!rb->rows) {
            free(rb);
            return NULL;
        }
    }

    return rb;
}

RingBuffer *ring_buffer_create(size_t capacity) {
    return ring_buffer_create_sized(capacity, capacity);
}

RingBuffer *ring_buffer_create_sized(size_t initial_capacity, size_t max_capacity) {
    if (initial_capacity == 0 || max_capacity == 0 || initial_capacity > max_capacity) return NULL;

    RingBuffer *rb = ring_buffer_alloc_struct(initial_capacity, max_capacity);
    if (!rb) return NULL;

    rb->data = malloc(initial_capacity);
    if (!rb->data) {
        free(rb->rows);
        free(rb);
        return NULL;
    }

    memset(rb->data, 0, initial_capacity);
    return rb;
}

RingBuffer *ring_buffer_create_mmap(const char *path, size_t capacity) {
    return ring_buffer_create_mmap_sized(path, capacity, capacity);
}

static bool ring_buffer_copy_row_bytes(const RingBuffer *rb,
                                       const RingRowEntry *entry,
                                       uint8_t *destination) {
    if (!rb || !entry || !destination) return false;

    size_t length = (size_t)entry->length;
    size_t offset = (size_t)entry->offset;
    if (length == 0) return true;
    if (offset >= rb->data_capacity) return false;

    size_t first_part = rb->data_capacity - offset;
    if (length <= first_part) {
        memcpy(destination, rb->data + offset, length);
    } else {
        memcpy(destination, rb->data + offset, first_part);
        memcpy(destination + first_part, rb->data, length - first_part);
    }
    return true;
}

static bool ring_buffer_repack_into(const RingBuffer *rb,
                                    uint8_t *destination_data,
                                    size_t destination_capacity,
                                    RingRowEntry *destination_rows,
                                    size_t *out_bytes_used,
                                    size_t *out_write_offset,
                                    uint32_t *out_row_count) {
    if (!rb || !destination_data || !destination_rows || destination_capacity == 0) return false;

    size_t offset = 0;
    for (uint32_t row = 0; row < rb->row_count; row++) {
        uint32_t actual_idx = (uint32_t)((rb->row_head + row) % rb->row_capacity);
        const RingRowEntry *source = &rb->rows[actual_idx];
        size_t length = (size_t)source->length;
        if (offset + length > destination_capacity) {
            return false;
        }

        if (!ring_buffer_copy_row_bytes(rb, source, destination_data + offset)) {
            return false;
        }

        destination_rows[row].offset = (uint32_t)offset;
        destination_rows[row].length = source->length;
        destination_rows[row].flags = source->flags;
        memset(destination_rows[row].reserved, 0, sizeof(destination_rows[row].reserved));
        offset += length;
    }

    *out_bytes_used = offset;
    *out_write_offset = offset % destination_capacity;
    *out_row_count = rb->row_count;
    return true;
}

static bool ring_buffer_grow_heap(RingBuffer *rb, size_t required_capacity) {
    if (!rb || (rb->flags & RING_FLAG_MMAP)) return false;

    size_t new_capacity = rb->data_capacity;
    while (new_capacity < required_capacity && new_capacity < rb->max_data_capacity) {
        size_t doubled = new_capacity * 2;
        if (doubled <= new_capacity) {
            new_capacity = rb->max_data_capacity;
            break;
        }
        new_capacity = doubled > rb->max_data_capacity ? rb->max_data_capacity : doubled;
    }
    if (new_capacity < required_capacity || new_capacity == rb->data_capacity) {
        return false;
    }

    uint8_t *new_data = calloc(1, new_capacity);
    RingRowEntry *new_rows = calloc(rb->row_capacity, sizeof(RingRowEntry));
    if (!new_data || !new_rows) {
        free(new_data);
        free(new_rows);
        return false;
    }

    size_t bytes_used = 0;
    size_t write_offset = 0;
    uint32_t row_count = 0;
    if (!ring_buffer_repack_into(rb, new_data, new_capacity, new_rows,
                                 &bytes_used, &write_offset, &row_count)) {
        free(new_data);
        free(new_rows);
        return false;
    }

    ring_buffer_zero_memory(rb->data, rb->data_capacity);
    free(rb->data);
    free(rb->rows);

    rb->data = new_data;
    rb->rows = new_rows;
    rb->data_capacity = new_capacity;
    rb->write_offset = write_offset;
    rb->bytes_used = bytes_used;
    rb->row_count = row_count;
    rb->row_head = 0;
    rb->row_tail = row_count;
    return true;
}

static bool ring_buffer_grow_mmap(RingBuffer *rb, size_t required_capacity) {
    if (!rb || !(rb->flags & RING_FLAG_MMAP)) return false;

    size_t new_capacity = rb->data_capacity;
    while (new_capacity < required_capacity && new_capacity < rb->max_data_capacity) {
        size_t doubled = new_capacity * 2;
        if (doubled <= new_capacity) {
            new_capacity = rb->max_data_capacity;
            break;
        }
        new_capacity = doubled > rb->max_data_capacity ? rb->max_data_capacity : doubled;
    }
    if (new_capacity < required_capacity || new_capacity == rb->data_capacity) {
        return false;
    }

    uint8_t *packed_data = calloc(1, new_capacity);
    RingRowEntry *packed_rows = calloc(rb->row_capacity, sizeof(RingRowEntry));
    if (!packed_data || !packed_rows) {
        free(packed_data);
        free(packed_rows);
        return false;
    }

    size_t bytes_used = 0;
    size_t write_offset = 0;
    uint32_t row_count = 0;
    if (!ring_buffer_repack_into(rb, packed_data, new_capacity, packed_rows,
                                 &bytes_used, &write_offset, &row_count)) {
        free(packed_data);
        free(packed_rows);
        return false;
    }

    size_t new_mapping_len = ring_buffer_mmap_length(new_capacity);
    if (new_mapping_len == 0) {
        free(packed_data);
        free(packed_rows);
        return false;
    }

    if (munmap(rb->mapping_base, rb->mapping_length) != 0) {
        free(packed_data);
        free(packed_rows);
        return false;
    }
    rb->mapping_base = NULL;

    if (ftruncate(rb->mmap_fd, (off_t)new_mapping_len) < 0) {
        free(packed_data);
        free(packed_rows);
        return false;
    }

    void *mapped = mmap(NULL, new_mapping_len, PROT_READ | PROT_WRITE,
                        MAP_SHARED, rb->mmap_fd, 0);
    if (mapped == MAP_FAILED) {
        free(packed_data);
        free(packed_rows);
        return false;
    }

    RingBufferDiskHeader *header = (RingBufferDiskHeader *)mapped;
    RingRowEntry *rows = (RingRowEntry *)((uint8_t *)mapped + sizeof(RingBufferDiskHeader));
    uint8_t *data = (uint8_t *)rows + (sizeof(RingRowEntry) * (size_t)RING_BUFFER_MAX_ROWS);
    memset(mapped, 0, new_mapping_len);
    memcpy(rows, packed_rows, sizeof(RingRowEntry) * rb->row_capacity);
    memcpy(data, packed_data, bytes_used);

    rb->mapping_base = mapped;
    rb->mapping_length = new_mapping_len;
    rb->mmap_header = header;
    rb->rows = rows;
    rb->data = data;
    rb->data_capacity = new_capacity;
    rb->write_offset = write_offset;
    rb->bytes_used = bytes_used;
    rb->row_count = row_count;
    rb->row_head = 0;
    rb->row_tail = row_count;
    ring_buffer_sync_header(rb);

    free(packed_data);
    free(packed_rows);
    return true;
}

static bool ring_buffer_grow_if_needed(RingBuffer *rb, size_t needed_capacity) {
    if (!rb) return false;
    if (needed_capacity <= rb->data_capacity) return true;
    if (needed_capacity > rb->max_data_capacity) return false;
    if (rb->flags & RING_FLAG_MMAP) {
        return ring_buffer_grow_mmap(rb, needed_capacity);
    }
    return ring_buffer_grow_heap(rb, needed_capacity);
}

RingBuffer *ring_buffer_create_mmap_sized(const char *path,
                                          size_t initial_capacity,
                                          size_t max_capacity) {
    if (!path || initial_capacity == 0 || max_capacity == 0 || initial_capacity > max_capacity) return NULL;

    RingBuffer *rb = ring_buffer_alloc_struct(0, max_capacity);
    if (!rb) return NULL;

    /* O_NOFOLLOW prevents symlink attacks */
    int fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW, 0600);
    if (fd < 0) {
        free(rb);
        return NULL;
    }

    struct stat st;
    bool has_existing = fstat(fd, &st) == 0 && (size_t)st.st_size >= sizeof(RingBufferDiskHeader);
    size_t current_capacity = initial_capacity;
    size_t mapping_len = ring_buffer_mmap_length(initial_capacity);
    if (mapping_len == 0) {
        close(fd);
        free(rb);
        return NULL;
    }

    if (has_existing) {
        RingBufferDiskHeader disk_header = {0};
        ssize_t bytes = pread(fd, &disk_header, sizeof(disk_header), 0);
        if (bytes == (ssize_t)sizeof(disk_header) &&
            disk_header.magic == RING_BUFFER_DISK_MAGIC &&
            disk_header.version == RING_BUFFER_DISK_VERSION &&
            disk_header.max_data_capacity == (uint64_t)max_capacity &&
            disk_header.data_capacity >= initial_capacity &&
            disk_header.data_capacity <= max_capacity) {
            size_t existing_mapping_len = ring_buffer_mmap_length((size_t)disk_header.data_capacity);
            if (existing_mapping_len != 0 && (size_t)st.st_size == existing_mapping_len) {
                current_capacity = (size_t)disk_header.data_capacity;
                mapping_len = existing_mapping_len;
            }
        }
    }

    if (ftruncate(fd, (off_t)mapping_len) < 0) {
        close(fd);
        free(rb);
        return NULL;
    }

    void *mapped = mmap(NULL, mapping_len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (mapped == MAP_FAILED) {
        close(fd);
        free(rb);
        return NULL;
    }

    RingBufferDiskHeader *header = (RingBufferDiskHeader *)mapped;
    RingRowEntry *rows = (RingRowEntry *)((uint8_t *)mapped + sizeof(RingBufferDiskHeader));
    uint8_t *data = (uint8_t *)rows + (sizeof(RingRowEntry) * (size_t)RING_BUFFER_MAX_ROWS);

    rb->mapping_base = mapped;
    rb->mapping_length = mapping_len;
    rb->mmap_header = header;
    rb->rows = rows;
    rb->data = data;
    rb->data_capacity = current_capacity;
    rb->mmap_fd = fd;
    rb->flags |= RING_FLAG_MMAP;
    rb->row_capacity = RING_BUFFER_MAX_ROWS;

    /* Store path for destroy_and_unlink */
    rb->mmap_path = strdup(path);
    if (!rb->mmap_path) {
        munmap(mapped, mapping_len);
        close(fd);
        free(rb);
        return NULL;
    }

    if (header->magic == RING_BUFFER_DISK_MAGIC &&
        header->version == RING_BUFFER_DISK_VERSION &&
        header->data_capacity == (uint64_t)current_capacity &&
        header->max_data_capacity == (uint64_t)max_capacity &&
        header->row_capacity == (uint64_t)RING_BUFFER_MAX_ROWS &&
        header->write_offset <= (uint64_t)current_capacity &&
        header->row_count <= (uint64_t)RING_BUFFER_MAX_ROWS &&
        header->bytes_used <= (uint64_t)current_capacity &&
        header->row_head <= header->row_tail &&
        (header->row_tail - header->row_head) == header->row_count) {
        rb->data_capacity = (size_t)header->data_capacity;
        rb->max_data_capacity = (size_t)header->max_data_capacity;
        rb->write_offset = (size_t)header->write_offset;
        rb->row_count = (uint32_t)header->row_count;
        rb->row_head = header->row_head;
        rb->row_tail = header->row_tail;
        rb->bytes_used = (size_t)header->bytes_used;
    } else {
        memset(mapped, 0, mapping_len);
        ring_buffer_sync_header(rb);
    }

    return rb;
}

static void ring_buffer_free_internal(RingBuffer *rb) {
    if (rb->flags & RING_FLAG_MMAP) {
        ring_buffer_sync_header(rb);
        if (rb->mapping_base) {
            msync(rb->mapping_base, rb->mapping_length, MS_SYNC);
            munmap(rb->mapping_base, rb->mapping_length);
        }
        if (rb->mmap_fd >= 0) {
            close(rb->mmap_fd);
        }
    } else {
        if (rb->data) {
            ring_buffer_zero_memory(rb->data, rb->data_capacity);
            free(rb->data);
        }
    }

    free(rb->mmap_path);
    free(rb->copy_buf);
    if (!(rb->flags & RING_FLAG_MMAP)) {
        free(rb->rows);
    }
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
        if (rb->mapping_base) {
            memset(rb->mapping_base, 0, rb->mapping_length);
            msync(rb->mapping_base, rb->mapping_length, MS_SYNC);
        }
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

    size_t required_capacity = rb->bytes_used + (size_t)length;
    if (!ring_buffer_grow_if_needed(rb, required_capacity)) return -1;

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
    ring_buffer_sync_header(rb);

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
        ring_buffer_zero_memory(rb->data, rb->data_capacity);
    }
    rb->write_offset = 0;
    rb->row_count = 0;
    rb->row_head = 0;
    rb->row_tail = 0;
    rb->bytes_used = 0;
    if (rb->rows) {
        memset(rb->rows, 0, sizeof(RingRowEntry) * rb->row_capacity);
    }
    ring_buffer_sync_header(rb);
}
