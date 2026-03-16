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
    uint64_t initial_data_capacity;
    uint64_t initial_row_capacity;
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
#define RING_BUFFER_DISK_VERSION 4

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

static uint32_t ring_buffer_compute_initial_row_capacity(size_t initial_data_capacity) {
    const size_t target_row_bytes = 128;
    size_t rows = (initial_data_capacity + (target_row_bytes - 1)) / target_row_bytes;
    if (rows < RING_BUFFER_MIN_ROWS) {
        rows = RING_BUFFER_MIN_ROWS;
    }
    if (rows > RING_BUFFER_INITIAL_ROW_SOFT_LIMIT) {
        rows = RING_BUFFER_INITIAL_ROW_SOFT_LIMIT;
    }
    if (rows > RING_BUFFER_MAX_ROWS) {
        rows = RING_BUFFER_MAX_ROWS;
    }
    return (uint32_t)rows;
}

static size_t ring_buffer_mmap_length(size_t capacity, uint32_t row_capacity) {
    if (capacity == 0 && row_capacity == 0) {
        return sizeof(RingBufferDiskHeader);
    }
    size_t rows_bytes = 0;
    size_t total = 0;
    if (row_capacity == 0 || row_capacity > RING_BUFFER_MAX_ROWS) {
        return 0;
    }
    if (ring_buffer_mul_overflow(sizeof(RingRowEntry), (size_t)row_capacity, &rows_bytes)) {
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
    header->initial_data_capacity = (uint64_t)rb->initial_data_capacity;
    header->initial_row_capacity = (uint64_t)rb->initial_row_capacity;
    header->data_capacity = (uint64_t)rb->data_capacity;
    header->max_data_capacity = (uint64_t)rb->max_data_capacity;
    header->write_offset = (uint64_t)rb->write_offset;
    header->row_capacity = (uint64_t)rb->row_capacity;
    header->row_count = (uint64_t)rb->row_count;
    header->row_head = rb->row_head;
    header->row_tail = rb->row_tail;
    header->bytes_used = (uint64_t)rb->bytes_used;
}

static bool ring_buffer_v3_layout_matches(const RingBufferDiskHeader *disk_header,
                                          size_t initial_capacity,
                                          size_t max_capacity,
                                          struct stat st,
                                          size_t *out_current_capacity,
                                          uint32_t *out_current_row_capacity,
                                          size_t *out_mapping_len) {
    if (!disk_header ||
        disk_header->magic != RING_BUFFER_DISK_MAGIC ||
        disk_header->version != 3 ||
        disk_header->initial_data_capacity != (uint64_t)initial_capacity ||
        disk_header->initial_row_capacity < (uint64_t)RING_BUFFER_MIN_ROWS ||
        disk_header->initial_row_capacity > (uint64_t)RING_BUFFER_MAX_ROWS ||
        disk_header->max_data_capacity != (uint64_t)max_capacity ||
        disk_header->data_capacity < initial_capacity ||
        disk_header->data_capacity > max_capacity ||
        disk_header->row_capacity < disk_header->initial_row_capacity ||
        disk_header->row_capacity > (uint64_t)RING_BUFFER_MAX_ROWS) {
        return false;
    }

    size_t mapping_len = ring_buffer_mmap_length((size_t)disk_header->data_capacity,
                                                 (uint32_t)disk_header->row_capacity);
    if (mapping_len == 0 || (size_t)st.st_size != mapping_len) {
        return false;
    }

    *out_current_capacity = (size_t)disk_header->data_capacity;
    *out_current_row_capacity = (uint32_t)disk_header->row_capacity;
    *out_mapping_len = mapping_len;
    return true;
}

static bool ring_buffer_v4_layout_matches(const RingBufferDiskHeader *disk_header,
                                          size_t initial_capacity,
                                          size_t max_capacity,
                                          struct stat st,
                                          size_t *out_current_capacity,
                                          uint32_t *out_current_row_capacity,
                                          size_t *out_mapping_len) {
    if (!disk_header ||
        disk_header->magic != RING_BUFFER_DISK_MAGIC ||
        disk_header->version != RING_BUFFER_DISK_VERSION ||
        disk_header->initial_data_capacity != (uint64_t)initial_capacity ||
        disk_header->initial_row_capacity < (uint64_t)RING_BUFFER_MIN_ROWS ||
        disk_header->initial_row_capacity > (uint64_t)RING_BUFFER_MAX_ROWS ||
        disk_header->max_data_capacity != (uint64_t)max_capacity) {
        return false;
    }

    bool is_lazy_empty = disk_header->data_capacity == 0 && disk_header->row_capacity == 0;
    bool is_materialized =
        disk_header->data_capacity >= initial_capacity &&
        disk_header->data_capacity <= max_capacity &&
        disk_header->row_capacity >= disk_header->initial_row_capacity &&
        disk_header->row_capacity <= (uint64_t)RING_BUFFER_MAX_ROWS;
    if (!is_lazy_empty && !is_materialized) {
        return false;
    }

    size_t mapping_len = ring_buffer_mmap_length((size_t)disk_header->data_capacity,
                                                 (uint32_t)disk_header->row_capacity);
    if (mapping_len == 0 || (size_t)st.st_size != mapping_len) {
        return false;
    }

    *out_current_capacity = (size_t)disk_header->data_capacity;
    *out_current_row_capacity = (uint32_t)disk_header->row_capacity;
    *out_mapping_len = mapping_len;
    return true;
}

static RingBuffer *ring_buffer_alloc_struct(size_t capacity,
                                            size_t max_capacity,
                                            uint32_t initial_row_capacity) {
    RingBuffer *rb = calloc(1, sizeof(RingBuffer));
    if (!rb) return NULL;

    rb->initial_data_capacity = capacity;
    rb->initial_row_capacity = initial_row_capacity;
    rb->data_capacity = capacity;
    rb->max_data_capacity = max_capacity;
    rb->write_offset = 0;
    rb->row_capacity = initial_row_capacity;
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

    return rb;
}

RingBuffer *ring_buffer_create(size_t capacity) {
    return ring_buffer_create_sized(capacity, capacity);
}

RingBuffer *ring_buffer_create_sized(size_t initial_capacity, size_t max_capacity) {
    if (initial_capacity == 0 || max_capacity == 0 || initial_capacity > max_capacity) return NULL;

    RingBuffer *rb = ring_buffer_alloc_struct(initial_capacity,
                                              max_capacity,
                                              ring_buffer_compute_initial_row_capacity(initial_capacity));
    if (!rb) return NULL;

    rb->data = NULL;
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

static bool ring_buffer_append_row_internal(RingBuffer *rb,
                                            const uint8_t *data,
                                            uint32_t length,
                                            bool continuation,
                                            bool *did_evict_out);
static bool ring_buffer_resize_mmap(RingBuffer *rb,
                                    size_t target_data_capacity,
                                    uint32_t target_row_capacity);
static bool ring_buffer_grow_if_needed(RingBuffer *rb, size_t needed_capacity);
static bool ring_buffer_grow_rows_if_needed(RingBuffer *rb, uint32_t needed_rows);
static bool ring_buffer_resize_heap_rows_only(RingBuffer *rb, uint32_t target_row_capacity);

static bool ring_buffer_prepare_append_batch(RingBuffer *rb,
                                             size_t total_length,
                                             uint32_t additional_rows) {
    if (!rb || additional_rows == 0) return false;

    if (!(rb->flags & RING_FLAG_MMAP) && !rb->data) {
        rb->data = calloc(1, rb->data_capacity);
        if (!rb->data) {
            return false;
        }
    }
    if (!(rb->flags & RING_FLAG_MMAP) && !rb->rows) {
        rb->rows = calloc(rb->row_capacity, sizeof(RingRowEntry));
        if (!rb->rows) {
            return false;
        }
    }

    if ((rb->flags & RING_FLAG_MMAP) && (rb->data_capacity == 0 || rb->row_capacity == 0)) {
        if (!ring_buffer_resize_mmap(rb, rb->initial_data_capacity, rb->initial_row_capacity)) {
            return false;
        }
    }

    if (total_length > rb->max_data_capacity) {
        return false;
    }

    size_t required_capacity = rb->bytes_used + total_length;
    if (required_capacity <= rb->max_data_capacity &&
        required_capacity > rb->data_capacity &&
        !ring_buffer_grow_if_needed(rb, required_capacity)) {
        return false;
    }

    uint64_t needed_rows_u64 = (uint64_t)rb->row_count + (uint64_t)additional_rows;
    uint32_t needed_rows = needed_rows_u64 > RING_BUFFER_MAX_ROWS
        ? RING_BUFFER_MAX_ROWS
        : (uint32_t)needed_rows_u64;
    if (needed_rows > rb->row_capacity &&
        !ring_buffer_grow_rows_if_needed(rb, needed_rows)) {
        return false;
    }

    return true;
}

static void ring_buffer_release_copy_buf(RingBuffer *rb) {
    if (!rb) return;
    free(rb->copy_buf);
    rb->copy_buf = NULL;
    rb->copy_buf_cap = 0;
}

static bool ring_buffer_repack_into(const RingBuffer *rb,
                                    uint8_t *destination_data,
                                    size_t destination_capacity,
                                    RingRowEntry *destination_rows,
                                    uint32_t destination_row_capacity,
                                    size_t *out_bytes_used,
                                    size_t *out_write_offset,
                                    uint32_t *out_row_count) {
    if (!rb) return false;
    if (rb->row_count == 0) {
        *out_bytes_used = 0;
        *out_write_offset = 0;
        *out_row_count = 0;
        return true;
    }
    if (!destination_data || !destination_rows || destination_capacity == 0) return false;
    if (rb->row_count > destination_row_capacity) return false;

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

static bool ring_buffer_resize_heap(RingBuffer *rb,
                                    size_t target_data_capacity,
                                    uint32_t target_row_capacity) {
    if (!rb || (rb->flags & RING_FLAG_MMAP)) return false;
    if (target_data_capacity == 0 || target_data_capacity > rb->max_data_capacity) return false;
    if (target_row_capacity == 0 || target_row_capacity > RING_BUFFER_MAX_ROWS) return false;
    if (target_data_capacity == rb->data_capacity && target_row_capacity == rb->row_capacity) {
        return false;
    }
    if (rb->bytes_used > target_data_capacity || rb->row_count > target_row_capacity) return false;

    uint8_t *new_data = calloc(1, target_data_capacity);
    RingRowEntry *new_rows = calloc(target_row_capacity, sizeof(RingRowEntry));
    if (!new_data || !new_rows) {
        free(new_data);
        free(new_rows);
        return false;
    }

    size_t bytes_used = 0;
    size_t write_offset = 0;
    uint32_t row_count = 0;
    if (!ring_buffer_repack_into(rb, new_data, target_data_capacity, new_rows, target_row_capacity,
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
    rb->data_capacity = target_data_capacity;
    rb->row_capacity = target_row_capacity;
    rb->write_offset = write_offset;
    rb->bytes_used = bytes_used;
    rb->row_count = row_count;
    rb->row_head = 0;
    rb->row_tail = row_count;
    ring_buffer_release_copy_buf(rb);
    return true;
}

static bool ring_buffer_resize_heap_rows_only(RingBuffer *rb, uint32_t target_row_capacity) {
    if (!rb || (rb->flags & RING_FLAG_MMAP)) return false;
    if (target_row_capacity == 0 || target_row_capacity > RING_BUFFER_MAX_ROWS) return false;
    if (target_row_capacity == rb->row_capacity) return false;
    if (rb->row_count > target_row_capacity) return false;

    RingRowEntry *new_rows = calloc(target_row_capacity, sizeof(RingRowEntry));
    if (!new_rows) {
        return false;
    }

    for (uint32_t row = 0; row < rb->row_count; row++) {
        uint32_t actual_idx = (uint32_t)((rb->row_head + row) % rb->row_capacity);
        new_rows[row] = rb->rows[actual_idx];
    }

    free(rb->rows);
    rb->rows = new_rows;
    rb->row_capacity = target_row_capacity;
    rb->row_head = 0;
    rb->row_tail = rb->row_count;
    return true;
}

static bool ring_buffer_resize_mmap(RingBuffer *rb,
                                    size_t target_data_capacity,
                                    uint32_t target_row_capacity) {
    if (!rb || !(rb->flags & RING_FLAG_MMAP)) return false;
    bool target_is_empty = target_data_capacity == 0 && target_row_capacity == 0;
    if (!target_is_empty && (target_data_capacity == 0 || target_data_capacity > rb->max_data_capacity)) return false;
    if (!target_is_empty && (target_row_capacity == 0 || target_row_capacity > RING_BUFFER_MAX_ROWS)) return false;
    if (target_data_capacity == rb->data_capacity && target_row_capacity == rb->row_capacity) {
        return false;
    }
    if (rb->bytes_used > target_data_capacity || rb->row_count > target_row_capacity) return false;

    uint8_t *packed_data = target_data_capacity > 0 ? calloc(1, target_data_capacity) : NULL;
    RingRowEntry *packed_rows = target_row_capacity > 0 ? calloc(target_row_capacity, sizeof(RingRowEntry)) : NULL;
    if ((target_data_capacity > 0 && !packed_data) || (target_row_capacity > 0 && !packed_rows)) {
        free(packed_data);
        free(packed_rows);
        return false;
    }

    size_t bytes_used = 0;
    size_t write_offset = 0;
    uint32_t row_count = 0;
    if (!ring_buffer_repack_into(rb, packed_data, target_data_capacity, packed_rows, target_row_capacity,
                                 &bytes_used, &write_offset, &row_count)) {
        free(packed_data);
        free(packed_rows);
        return false;
    }

    size_t new_mapping_len = ring_buffer_mmap_length(target_data_capacity, target_row_capacity);
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
    RingRowEntry *rows = target_row_capacity > 0
        ? (RingRowEntry *)((uint8_t *)mapped + sizeof(RingBufferDiskHeader))
        : NULL;
    uint8_t *data = target_data_capacity > 0
        ? (uint8_t *)mapped + sizeof(RingBufferDiskHeader) +
            (sizeof(RingRowEntry) * (size_t)target_row_capacity)
        : NULL;
    memset(mapped, 0, new_mapping_len);
    if (target_row_capacity > 0) {
        memcpy(rows, packed_rows, sizeof(RingRowEntry) * (size_t)target_row_capacity);
    }
    if (bytes_used > 0) {
        memcpy(data, packed_data, bytes_used);
    }

    rb->mapping_base = mapped;
    rb->mapping_length = new_mapping_len;
    rb->mmap_header = header;
    rb->rows = rows;
    rb->data = data;
    rb->data_capacity = target_data_capacity;
    rb->row_capacity = target_row_capacity;
    rb->write_offset = write_offset;
    rb->bytes_used = bytes_used;
    rb->row_count = row_count;
    rb->row_head = 0;
    rb->row_tail = row_count;
    ring_buffer_sync_header(rb);
    ring_buffer_release_copy_buf(rb);

    free(packed_data);
    free(packed_rows);
    return true;
}

static bool ring_buffer_grow_if_needed(RingBuffer *rb, size_t needed_capacity) {
    if (!rb) return false;
    if (needed_capacity <= rb->data_capacity) return true;
    if (needed_capacity > rb->max_data_capacity) return false;
    if ((rb->flags & RING_FLAG_MMAP) && rb->data_capacity == 0 && rb->row_capacity == 0) {
        return ring_buffer_resize_mmap(rb, rb->initial_data_capacity, rb->initial_row_capacity);
    }
    size_t new_capacity = rb->data_capacity > 0 ? rb->data_capacity : rb->initial_data_capacity;
    while (new_capacity < needed_capacity && new_capacity < rb->max_data_capacity) {
        size_t doubled = new_capacity * 2;
        if (doubled <= new_capacity) {
            new_capacity = rb->max_data_capacity;
            break;
        }
        new_capacity = doubled > rb->max_data_capacity ? rb->max_data_capacity : doubled;
    }
    if (new_capacity < needed_capacity || new_capacity == rb->data_capacity) {
        return false;
    }
    if (rb->flags & RING_FLAG_MMAP) {
        return ring_buffer_resize_mmap(rb, new_capacity, rb->row_capacity);
    }
    return ring_buffer_resize_heap(rb, new_capacity, rb->row_capacity);
}

static bool ring_buffer_grow_rows_if_needed(RingBuffer *rb, uint32_t needed_rows) {
    if (!rb) return false;
    if (needed_rows <= rb->row_capacity) return true;
    if (needed_rows > RING_BUFFER_MAX_ROWS) return false;
    if ((rb->flags & RING_FLAG_MMAP) && rb->data_capacity == 0 && rb->row_capacity == 0) {
        return ring_buffer_resize_mmap(rb, rb->initial_data_capacity, rb->initial_row_capacity);
    }

    uint32_t new_row_capacity = rb->row_capacity > 0 ? rb->row_capacity : rb->initial_row_capacity;
    while (new_row_capacity < needed_rows && new_row_capacity < RING_BUFFER_MAX_ROWS) {
        uint32_t doubled = new_row_capacity * 2;
        if (doubled <= new_row_capacity) {
            new_row_capacity = RING_BUFFER_MAX_ROWS;
            break;
        }
        new_row_capacity = doubled > RING_BUFFER_MAX_ROWS ? RING_BUFFER_MAX_ROWS : doubled;
    }
    if (new_row_capacity < needed_rows || new_row_capacity == rb->row_capacity) {
        return false;
    }
    if (rb->flags & RING_FLAG_MMAP) {
        return ring_buffer_resize_mmap(rb, rb->data_capacity, new_row_capacity);
    }
    return ring_buffer_resize_heap_rows_only(rb, new_row_capacity);
}

static bool ring_buffer_shrink_heap(RingBuffer *rb, size_t target_capacity) {
    return ring_buffer_resize_heap(rb, target_capacity, rb->row_capacity);
}

static bool ring_buffer_shrink_mmap(RingBuffer *rb, size_t target_capacity) {
    return ring_buffer_resize_mmap(rb, target_capacity, rb->row_capacity);
}

static bool ring_buffer_shrink_to(RingBuffer *rb, size_t target_capacity) {
    if (!rb) return false;
    if (rb->flags & RING_FLAG_MMAP) {
        return ring_buffer_shrink_mmap(rb, target_capacity);
    }
    return ring_buffer_shrink_heap(rb, target_capacity);
}

static bool ring_buffer_shrink_rows_to(RingBuffer *rb, uint32_t target_row_capacity) {
    if (!rb) return false;
    if (target_row_capacity >= rb->row_capacity || target_row_capacity < rb->row_count) return false;
    if (target_row_capacity < rb->initial_row_capacity) return false;
    if (rb->flags & RING_FLAG_MMAP) {
        return ring_buffer_resize_mmap(rb, rb->data_capacity, target_row_capacity);
    }
    return ring_buffer_resize_heap(rb, rb->data_capacity, target_row_capacity);
}

static void ring_buffer_maybe_shrink(RingBuffer *rb) {
    if (!rb) return;
    if (rb->data_capacity <= rb->initial_data_capacity) return;

    size_t target = rb->data_capacity;
    while (target > rb->initial_data_capacity) {
        size_t next = target / 2;
        if (next < rb->initial_data_capacity) {
            next = rb->initial_data_capacity;
        }
        if (rb->bytes_used > next / 8) {
            break;
        }
        target = next;
        if (target == rb->initial_data_capacity) {
            break;
        }
    }

    if (target < rb->data_capacity) {
        (void)ring_buffer_shrink_to(rb, target);
    }
}

static void ring_buffer_maybe_shrink_rows(RingBuffer *rb) {
    if (!rb) return;
    if (rb->row_capacity <= rb->initial_row_capacity) return;

    uint32_t target = rb->row_capacity;
    while (target > rb->initial_row_capacity) {
        uint32_t next = target / 2;
        if (next < rb->initial_row_capacity) {
            next = rb->initial_row_capacity;
        }
        if (rb->row_count > next / 4) {
            break;
        }
        target = next;
        if (target == rb->initial_row_capacity) {
            break;
        }
    }

    if (target < rb->row_capacity) {
        (void)ring_buffer_shrink_rows_to(rb, target);
    }
}

RingBuffer *ring_buffer_create_mmap_sized(const char *path,
                                          size_t initial_capacity,
                                          size_t max_capacity) {
    if (!path || initial_capacity == 0 || max_capacity == 0 || initial_capacity > max_capacity) return NULL;

    uint32_t initial_row_capacity = ring_buffer_compute_initial_row_capacity(initial_capacity);
    RingBuffer *rb = calloc(1, sizeof(RingBuffer));
    if (!rb) return NULL;
    rb->initial_data_capacity = initial_capacity;
    rb->initial_row_capacity = initial_row_capacity;
    rb->max_data_capacity = max_capacity;
    rb->mmap_fd = -1;

    /* O_NOFOLLOW prevents symlink attacks */
    int fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW, 0600);
    if (fd < 0) {
        free(rb);
        return NULL;
    }

    struct stat st;
    bool has_existing = fstat(fd, &st) == 0 && (size_t)st.st_size >= sizeof(RingBufferDiskHeader);
    size_t current_capacity = 0;
    uint32_t current_row_capacity = 0;
    size_t mapping_len = ring_buffer_mmap_length(0, 0);
    if (mapping_len == 0) {
        close(fd);
        free(rb);
        return NULL;
    }

    if (has_existing) {
        RingBufferDiskHeader disk_header = {0};
        ssize_t bytes = pread(fd, &disk_header, sizeof(disk_header), 0);
        if (bytes == (ssize_t)sizeof(disk_header)) {
            size_t existing_mapping_len = 0;
            if (ring_buffer_v4_layout_matches(&disk_header, initial_capacity, max_capacity, st,
                                              &current_capacity, &current_row_capacity, &existing_mapping_len) ||
                ring_buffer_v3_layout_matches(&disk_header, initial_capacity, max_capacity, st,
                                              &current_capacity, &current_row_capacity, &existing_mapping_len)) {
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
    RingRowEntry *rows = current_row_capacity > 0
        ? (RingRowEntry *)((uint8_t *)mapped + sizeof(RingBufferDiskHeader))
        : NULL;
    uint8_t *data = current_capacity > 0
        ? (uint8_t *)mapped + sizeof(RingBufferDiskHeader) +
            (sizeof(RingRowEntry) * (size_t)current_row_capacity)
        : NULL;

    rb->mapping_base = mapped;
    rb->mapping_length = mapping_len;
    rb->mmap_header = header;
    rb->rows = rows;
    rb->data = data;
    rb->initial_data_capacity = initial_capacity;
    rb->initial_row_capacity = initial_row_capacity;
    rb->data_capacity = current_capacity;
    rb->mmap_fd = fd;
    rb->flags |= RING_FLAG_MMAP;
    rb->row_capacity = current_row_capacity;

    /* Store path for destroy_and_unlink */
    rb->mmap_path = strdup(path);
    if (!rb->mmap_path) {
        munmap(mapped, mapping_len);
        close(fd);
        free(rb);
        return NULL;
    }

    if (header->magic == RING_BUFFER_DISK_MAGIC &&
        (header->version == 3 || header->version == RING_BUFFER_DISK_VERSION) &&
        header->initial_data_capacity == (uint64_t)initial_capacity &&
        header->initial_row_capacity == (uint64_t)initial_row_capacity &&
        header->data_capacity == (uint64_t)current_capacity &&
        header->max_data_capacity == (uint64_t)max_capacity &&
        header->row_capacity == (uint64_t)current_row_capacity &&
        header->write_offset <= (uint64_t)current_capacity &&
        header->row_count <= (uint64_t)current_row_capacity &&
        header->bytes_used <= (uint64_t)current_capacity &&
        header->row_head <= header->row_tail &&
        (header->row_tail - header->row_head) == header->row_count) {
        rb->data_capacity = (size_t)header->data_capacity;
        rb->max_data_capacity = (size_t)header->max_data_capacity;
        rb->initial_data_capacity = (size_t)header->initial_data_capacity;
        rb->initial_row_capacity = (uint32_t)header->initial_row_capacity;
        rb->row_capacity = (uint32_t)header->row_capacity;
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
    ring_buffer_release_copy_buf(rb);
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
static bool ring_buffer_evict(RingBuffer *rb, size_t needed) {
    bool evicted = false;
    while (rb->row_count > 0 && rb->bytes_used + needed > rb->data_capacity) {
        uint32_t head_idx = rb->row_head % rb->row_capacity;
        rb->bytes_used -= rb->rows[head_idx].length;
        rb->rows[head_idx].length = 0;
        rb->row_head++;
        rb->row_count--;
        evicted = true;
    }
    return evicted;
}

int64_t ring_buffer_append_row(RingBuffer *rb,
                               const uint8_t *data, uint32_t length,
                               bool continuation) {
    bool did_evict = false;
    if (!ring_buffer_append_row_internal(rb, data, length, continuation, &did_evict)) {
        return -1;
    }
    if (did_evict) {
        ring_buffer_maybe_shrink(rb);
        ring_buffer_maybe_shrink_rows(rb);
    }
    if (rb->flags & RING_FLAG_MMAP) {
        ring_buffer_sync_header(rb);
    }

    return (int64_t)(rb->row_tail - 1);
}

static bool ring_buffer_append_row_internal(RingBuffer *rb,
                                            const uint8_t *data,
                                            uint32_t length,
                                            bool continuation,
                                            bool *did_evict_out) {
    if (!rb || !data || !did_evict_out) return false;
    *did_evict_out = false;

    if (!(rb->flags & RING_FLAG_MMAP) && !rb->data) {
        rb->data = calloc(1, rb->data_capacity);
        if (!rb->data) {
            return false;
        }
    }
    if (!(rb->flags & RING_FLAG_MMAP) && !rb->rows) {
        rb->rows = calloc(rb->row_capacity, sizeof(RingRowEntry));
        if (!rb->rows) {
            return false;
        }
    }

    if ((size_t)length > rb->max_data_capacity) return false;

    if ((rb->flags & RING_FLAG_MMAP) && (rb->data_capacity == 0 || rb->row_capacity == 0)) {
        if (!ring_buffer_resize_mmap(rb, rb->initial_data_capacity, rb->initial_row_capacity)) {
            return false;
        }
    }

    size_t required_capacity = rb->bytes_used + (size_t)length;
    if (required_capacity > rb->data_capacity) {
        size_t grow_target = required_capacity <= rb->max_data_capacity
            ? required_capacity
            : rb->data_capacity;
        if (grow_target > rb->data_capacity && !ring_buffer_grow_if_needed(rb, grow_target)) {
            return false;
        }
        if ((size_t)length > rb->data_capacity && !ring_buffer_grow_if_needed(rb, (size_t)length)) {
            return false;
        }
    }

    bool did_evict = ring_buffer_evict(rb, (size_t)length);

    if (rb->row_count >= rb->row_capacity && !ring_buffer_grow_rows_if_needed(rb, rb->row_count + 1)) {
        uint32_t head_idx = rb->row_head % rb->row_capacity;
        rb->bytes_used -= rb->rows[head_idx].length;
        rb->row_head++;
        rb->row_count--;
        did_evict = true;
    }

    size_t first_part = rb->data_capacity - rb->write_offset;
    if ((size_t)length <= first_part) {
        memcpy(rb->data + rb->write_offset, data, length);
    } else {
        memcpy(rb->data + rb->write_offset, data, first_part);
        memcpy(rb->data, data + first_part, (size_t)length - first_part);
    }

    uint32_t tail_idx = rb->row_tail % rb->row_capacity;
    rb->rows[tail_idx].offset = (uint32_t)rb->write_offset;
    rb->rows[tail_idx].length = length;
    rb->rows[tail_idx].flags = continuation ? 1 : 0;
    memset(rb->rows[tail_idx].reserved, 0, sizeof(rb->rows[tail_idx].reserved));

    rb->write_offset = (rb->write_offset + (size_t)length) % rb->data_capacity;
    rb->bytes_used += (size_t)length;
    rb->row_tail++;
    rb->row_count++;
    *did_evict_out = did_evict;
    return true;
}

int64_t ring_buffer_append_rows(RingBuffer *rb,
                                const uint8_t *data_blob,
                                const uint32_t *row_offsets,
                                const uint32_t *row_lengths,
                                const bool *continuations,
                                uint32_t row_count) {
    if (!rb || !data_blob || !row_offsets || !row_lengths || !continuations || row_count == 0) {
        return -1;
    }

    size_t total_length = 0;
    for (uint32_t i = 0; i < row_count; i++) {
        total_length += (size_t)row_lengths[i];
    }
    if (!ring_buffer_prepare_append_batch(rb, total_length, row_count)) {
        return -1;
    }

    bool any_evict = false;
    for (uint32_t i = 0; i < row_count; i++) {
        bool did_evict = false;
        if (!ring_buffer_append_row_internal(rb,
                                             data_blob + row_offsets[i],
                                             row_lengths[i],
                                             continuations[i],
                                             &did_evict)) {
            return -1;
        }
        any_evict = any_evict || did_evict;
    }

    if (any_evict) {
        ring_buffer_maybe_shrink(rb);
        ring_buffer_maybe_shrink_rows(rb);
    }
    if (rb->flags & RING_FLAG_MMAP) {
        ring_buffer_sync_header(rb);
    }

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

uint32_t ring_buffer_row_index_capacity(const RingBuffer *rb) {
    return rb ? rb->row_capacity : 0;
}

bool ring_buffer_reserve_row_index_capacity(RingBuffer *rb, uint32_t min_row_capacity) {
    if (!rb) return false;
    if (min_row_capacity < RING_BUFFER_MIN_ROWS) {
        min_row_capacity = RING_BUFFER_MIN_ROWS;
    }
    if (min_row_capacity > RING_BUFFER_MAX_ROWS) {
        return false;
    }
    if (min_row_capacity <= rb->row_capacity) {
        if (min_row_capacity > rb->initial_row_capacity) {
            rb->initial_row_capacity = min_row_capacity;
            ring_buffer_sync_header(rb);
        }
        return true;
    }

    if (!(rb->flags & RING_FLAG_MMAP) && !rb->rows) {
        rb->initial_row_capacity = min_row_capacity;
        rb->row_capacity = min_row_capacity;
        return true;
    }

    if ((rb->flags & RING_FLAG_MMAP) && rb->data_capacity == 0 && rb->row_capacity == 0) {
        rb->initial_row_capacity = min_row_capacity;
        ring_buffer_sync_header(rb);
        return true;
    }

    if (!ring_buffer_grow_rows_if_needed(rb, min_row_capacity)) {
        return false;
    }
    if (min_row_capacity > rb->initial_row_capacity) {
        rb->initial_row_capacity = min_row_capacity;
        ring_buffer_sync_header(rb);
    }
    return true;
}

size_t ring_buffer_capacity(const RingBuffer *rb) {
    return rb ? rb->data_capacity : 0;
}

size_t ring_buffer_bytes_used(const RingBuffer *rb) {
    return rb ? rb->bytes_used : 0;
}

bool ring_buffer_compact(RingBuffer *rb) {
    if (!rb) return false;

    size_t original_data_capacity = rb->data_capacity;
    uint32_t original_row_capacity = rb->row_capacity;

    ring_buffer_maybe_shrink(rb);
    ring_buffer_maybe_shrink_rows(rb);
    ring_buffer_sync_header(rb);
    ring_buffer_release_copy_buf(rb);

    return rb->data_capacity != original_data_capacity ||
           rb->row_capacity != original_row_capacity;
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
    if (rb->data_capacity > rb->initial_data_capacity) {
        (void)ring_buffer_shrink_to(rb, rb->initial_data_capacity);
    }
    if (rb->row_capacity > rb->initial_row_capacity) {
        (void)ring_buffer_shrink_rows_to(rb, rb->initial_row_capacity);
    }
    if (rb->flags & RING_FLAG_MMAP) {
        (void)ring_buffer_resize_mmap(rb, 0, 0);
    }
    if (!(rb->flags & RING_FLAG_MMAP) && rb->data) {
        free(rb->data);
        rb->data = NULL;
    }
    if (!(rb->flags & RING_FLAG_MMAP) && rb->rows) {
        free(rb->rows);
        rb->rows = NULL;
    }
    ring_buffer_release_copy_buf(rb);
    ring_buffer_sync_header(rb);
}
