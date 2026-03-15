#ifndef RING_BUFFER_H
#define RING_BUFFER_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

/*
 * Fixed-size ring buffer for terminal scrollback.
 *
 * Stores terminal row data in a circular buffer. When the buffer is full,
 * the oldest rows are overwritten. Supports both heap allocation and
 * mmap-backed file mapping for session persistence.
 *
 * Memory management:
 *   - Default: Pre-allocate memory_initial bytes at creation.
 *   - mmap mode: Map the buffer to a file for crash-resilient persistence.
 *
 * Thread safety:
 *   - Callers must use external read-write locks.
 *   - Single writer (PTY thread), multiple readers (render thread).
 */

/* Maximum number of rows the index can track */
#define RING_BUFFER_MAX_ROWS (1 << 20)  /* ~1M rows */
#define RING_BUFFER_MIN_ROWS 16
#define RING_BUFFER_INITIAL_ROW_SOFT_LIMIT 64

/* Row metadata stored in the index */
typedef struct {
    uint32_t offset;     /* Byte offset within the data buffer */
    uint32_t length;     /* Byte length of row data */
    uint8_t  flags;      /* Bit 0: line continuation (soft wrap) */
    uint8_t  reserved[3];
} RingRowEntry;

/* Ring buffer flags */
#define RING_FLAG_MMAP   (1 << 0)

typedef struct {
    uint8_t      *data;          /* Circular data buffer */
    size_t        initial_data_capacity; /* Baseline capacity to shrink back to */
    uint32_t      initial_row_capacity;  /* Baseline row index capacity */
    size_t        data_capacity; /* Total data buffer size in bytes */
    size_t        max_data_capacity; /* Growth limit in bytes */
    size_t        write_offset;  /* Current write position in data buffer */

    RingRowEntry *rows;          /* Row index array (circular) */
    uint32_t      row_capacity;  /* Max rows in index */
    uint32_t      row_count;     /* Current number of valid rows */
    uint64_t      row_head;      /* Index of oldest row (uint64 to prevent overflow) */
    uint64_t      row_tail;      /* Index of next row to write */

    size_t        bytes_used;    /* Total bytes currently in use */
    uint32_t      flags;         /* RING_FLAG_MMAP etc. */
    int           mmap_fd;       /* File descriptor for mmap mode (-1 if heap) */
    char         *mmap_path;     /* File path for mmap mode (NULL if heap) */
    void         *mapping_base;  /* Base address of mmap region */
    size_t        mapping_length;/* Total length of mmap region */
    void         *mmap_header;   /* Internal header pointer for mmap mode */

    /* Temporary buffer for wrap-around reads */
    uint8_t      *copy_buf;
    size_t        copy_buf_cap;
} RingBuffer;

/*
 * Create a heap-backed ring buffer.
 * capacity: size in bytes (e.g., 64 * 1024 * 1024 for 64MB).
 * Returns NULL on allocation failure.
 */
RingBuffer *ring_buffer_create(size_t capacity);
RingBuffer *ring_buffer_create_sized(size_t initial_capacity, size_t max_capacity);

/*
 * Create an mmap-backed ring buffer mapped to a file.
 * path: file path for the backing store.
 * capacity: size in bytes.
 * Returns NULL on failure.
 */
RingBuffer *ring_buffer_create_mmap(const char *path, size_t capacity);
RingBuffer *ring_buffer_create_mmap_sized(const char *path,
                                          size_t initial_capacity,
                                          size_t max_capacity);

/*
 * Destroy a ring buffer and free all resources.
 * For mmap buffers, unmaps the file but does not delete it.
 */
void ring_buffer_destroy(RingBuffer *rb);

/*
 * Append a row of data to the buffer.
 * data: raw row bytes (cell data, serialized).
 * length: number of bytes.
 * continuation: true if this row is a soft-wrapped continuation.
 *
 * If the buffer is full, the oldest row is overwritten.
 * Returns the logical row number assigned, or -1 on error.
 */
int64_t ring_buffer_append_row(RingBuffer *rb,
                               const uint8_t *data, uint32_t length,
                               bool continuation);

/*
 * Append multiple rows in one batch.
 * data_blob: concatenated row bytes
 * row_offsets: byte offsets into data_blob for each row
 * row_lengths: byte length for each row
 * continuations: continuation flag for each row
 * row_count: number of rows
 *
 * Returns the logical row number assigned to the final appended row, or -1 on error.
 */
int64_t ring_buffer_append_rows(RingBuffer *rb,
                                const uint8_t *data_blob,
                                const uint32_t *row_offsets,
                                const uint32_t *row_lengths,
                                const bool *continuations,
                                uint32_t row_count);

/*
 * Read row data by logical index (0 = oldest visible row).
 * row_index: 0-based index from oldest to newest.
 * out_data: pointer set to the row data (valid until next write or get_row call).
 * out_length: set to the row byte length.
 * out_continuation: set to the continuation flag.
 *
 * For rows that wrap around the buffer boundary, data is copied to an
 * internal temporary buffer to guarantee contiguous access.
 *
 * Returns true if the row exists, false if out of range.
 */
bool ring_buffer_get_row(RingBuffer *rb, uint32_t row_index,
                         const uint8_t **out_data, uint32_t *out_length,
                         bool *out_continuation);

/* Get the number of rows currently stored. */
uint32_t ring_buffer_row_count(const RingBuffer *rb);

/* Get the current row-index capacity. */
uint32_t ring_buffer_row_index_capacity(const RingBuffer *rb);

/* Ensure the row index can track at least min_row_capacity rows. */
bool ring_buffer_reserve_row_index_capacity(RingBuffer *rb, uint32_t min_row_capacity);

/* Get the total data capacity in bytes. */
size_t ring_buffer_capacity(const RingBuffer *rb);

/* Get the number of bytes currently used. */
size_t ring_buffer_bytes_used(const RingBuffer *rb);

/* Compact underutilized data/index capacity back toward current usage. */
bool ring_buffer_compact(RingBuffer *rb);

/* Clear all data and zero the data buffer to prevent data recovery. */
void ring_buffer_clear(RingBuffer *rb);

/*
 * Destroy a ring buffer and unlink the mmap file.
 * For heap-backed buffers, equivalent to ring_buffer_destroy().
 * For mmap-backed buffers, also deletes the backing file.
 */
void ring_buffer_destroy_and_unlink(RingBuffer *rb);

#endif /* RING_BUFFER_H */
