#ifndef UTF8_DECODER_H
#define UTF8_DECODER_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

/*
 * Streaming UTF-8 decoder.
 *
 * Decodes a byte stream into Unicode codepoints one at a time.
 * Security: Rejects C1 control bytes (0x80-0x9F) in UTF-8 mode
 * to prevent escape sequence filter bypass (spec 11, item 6).
 *
 * Based on Bjoern Hoehrmann's DFA-based UTF-8 decoder.
 */

/* Decoder states */
#define UTF8_ACCEPT 0
#define UTF8_REJECT 12

/* Special codepoint returned for invalid sequences */
#define UTF8_REPLACEMENT_CHAR 0xFFFD

typedef struct {
    uint32_t state;
    uint32_t codepoint;
    bool reject_c1;  /* If true, reject 0x80-0x9F as invalid */
} Utf8Decoder;

/* Initialize decoder. reject_c1 should be true for terminal use. */
void utf8_decoder_init(Utf8Decoder *decoder, bool reject_c1);

/* Reset decoder state (e.g., after error recovery). */
void utf8_decoder_reset(Utf8Decoder *decoder);

/*
 * Feed a single byte to the decoder.
 *
 * Returns:
 *   UTF8_ACCEPT   - a complete codepoint is available in decoder->codepoint
 *   UTF8_REJECT   - invalid byte sequence; decoder->codepoint set to
 *                   UTF8_REPLACEMENT_CHAR; decoder is auto-reset
 *   other         - need more bytes (intermediate state)
 */
uint32_t utf8_decoder_feed(Utf8Decoder *decoder, uint8_t byte);

/*
 * Decode a complete buffer.
 *
 * Writes decoded codepoints to `output`. Returns the number of codepoints
 * written. `output` must have space for at least `input_len` codepoints
 * (worst case: all ASCII).
 *
 * The decoder maintains state across calls, so partial sequences at the
 * end of `input` will be completed on the next call.
 */
size_t utf8_decoder_decode(Utf8Decoder *decoder,
                           const uint8_t *input, size_t input_len,
                           uint32_t *output, size_t output_capacity);

/*
 * Decode the longest leading prefix consisting only of ASCII bytes (< 0x80)
 * directly into output codepoints. Returns the number of bytes/codepoints
 * written. Intended for terminal hot paths that commonly see large ASCII runs.
 */
size_t utf8_decoder_decode_ascii_prefix(const uint8_t *input,
                                        size_t input_len,
                                        uint32_t *output,
                                        size_t output_capacity);

/*
 * Decode the longest leading prefix consisting only of valid 3-byte UTF-8
 * scalar sequences. Intended for Apple Silicon terminal workloads that contain
 * long contiguous runs of CJK text. Returns the number of codepoints written
 * and stores the consumed byte count in `bytes_consumed`.
 */
size_t utf8_decoder_decode_three_byte_prefix(const uint8_t *input,
                                             size_t input_len,
                                             uint32_t *output,
                                             size_t output_capacity,
                                             size_t *bytes_consumed);

/*
 * Decode the longest leading prefix consisting only of valid 3-byte UTF-8
 * sequences that map to the terminal's common width-2 ranges (CJK, kana,
 * hangul, fullwidth punctuation). This exists for the macOS + Apple Silicon
 * terminal hot path where kitty-style Unicode workloads spend most of their
 * time in these ranges. Returns the number of codepoints written and stores
 * the consumed byte count in `bytes_consumed`.
 */
size_t utf8_decoder_decode_common_wide_three_byte_prefix(const uint8_t *input,
                                                         size_t input_len,
                                                         uint32_t *output,
                                                         size_t output_capacity,
                                                         size_t *bytes_consumed);

#endif /* UTF8_DECODER_H */
