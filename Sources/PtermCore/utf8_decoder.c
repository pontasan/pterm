#include "utf8_decoder.h"

/*
 * DFA-based UTF-8 decoder.
 *
 * State transition table derived from Bjoern Hoehrmann's design.
 * See: http://bjoern.hoehrmann.de/utf-8/decoder/dfa/
 *
 * Byte classification:
 *   0x00-0x7F: ASCII (class 0)
 *   0x80-0x8F: continuation (class 1)
 *   0x90-0x9F: continuation (class 9) - also C1 control range
 *   0xA0-0xBF: continuation (class 7)
 *   0xC0-0xC1: invalid overlong (class 8)
 *   0xC2-0xDF: 2-byte lead (class 2)
 *   0xE0:      3-byte lead, special (class 10)
 *   0xE1-0xEC: 3-byte lead (class 3)
 *   0xED:      3-byte lead, special for surrogates (class 4)
 *   0xEE-0xEF: 3-byte lead (class 3)
 *   0xF0:      4-byte lead, special (class 11)
 *   0xF1-0xF3: 4-byte lead (class 5)
 *   0xF4:      4-byte lead, special (class 6)
 *   0xF5-0xFF: invalid (class 8)
 */

static const uint8_t utf8_class[256] = {
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, /* 00-0F */
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, /* 10-1F */
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, /* 20-2F */
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, /* 30-3F */
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, /* 40-4F */
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, /* 50-5F */
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, /* 60-6F */
    0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0, /* 70-7F */
    1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1, /* 80-8F */
    9,9,9,9,9,9,9,9,9,9,9,9,9,9,9,9, /* 90-9F */
    7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7, /* A0-AF */
    7,7,7,7,7,7,7,7,7,7,7,7,7,7,7,7, /* B0-BF */
    8,8,2,2,2,2,2,2,2,2,2,2,2,2,2,2, /* C0-CF */
    2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2, /* D0-DF */
   10,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3, /* E0-EF */
   11,5,5,5,6,8,8,8,8,8,8,8,8,8,8,8, /* F0-FF */
};

/*
 * State transition table.
 * States: 0=accept, 12=reject, 24/36/48/60/72/84/96 = intermediate
 * Index: state + class
 */
static const uint8_t utf8_transition[] = {
     0,12,24,36,60,72,12,12,12,96,84,12, /* state  0 (accept) */
    12, 0,12,12,12,12,12, 0,12, 0,12,12, /* state 12 (reject) */
    12,24,12,12,12,12,12,24,12,24,12,12, /* state 24 */
    12,36,12,12,12,12,12,36,12,36,12,12, /* state 36 */
    12,12,12,12,12,12,12,12,12,12,12,12, /* state 48 (unused) */
    12,36,12,12,12,12,12,36,12,36,12,12, /* state 60 */
    12,24,12,12,12,12,12,24,12,24,12,12, /* state 72 */
    12,12,12,12,12,12,12,24,12,24,12,12, /* state 84 */
    12,24,12,12,12,12,12,12,12,24,12,12, /* state 96 */
};

void utf8_decoder_init(Utf8Decoder *decoder, bool reject_c1) {
    decoder->state = UTF8_ACCEPT;
    decoder->codepoint = 0;
    decoder->reject_c1 = reject_c1;
}

void utf8_decoder_reset(Utf8Decoder *decoder) {
    decoder->state = UTF8_ACCEPT;
    decoder->codepoint = 0;
}

uint32_t utf8_decoder_feed(Utf8Decoder *decoder, uint8_t byte) {
    /* C1 control byte rejection in UTF-8 mode (security spec item 6).
     * Bytes 0x80-0x9F as lead bytes would be invalid UTF-8 anyway,
     * but we explicitly reject them to prevent their use as
     * 8-bit CSI (0x9B) or other C1 controls. */
    if (decoder->reject_c1 && decoder->state == UTF8_ACCEPT &&
        byte >= 0x80 && byte <= 0x9F) {
        decoder->codepoint = UTF8_REPLACEMENT_CHAR;
        decoder->state = UTF8_ACCEPT;
        return UTF8_REJECT;
    }

    uint32_t type = utf8_class[byte];

    decoder->codepoint = (decoder->state != UTF8_ACCEPT)
        ? (byte & 0x3Fu) | (decoder->codepoint << 6)
        : (0xFFu >> type) & byte;

    decoder->state = utf8_transition[decoder->state + type];

    if (decoder->state == UTF8_REJECT) {
        decoder->codepoint = UTF8_REPLACEMENT_CHAR;
        decoder->state = UTF8_ACCEPT;
        return UTF8_REJECT;
    }

    return decoder->state;
}

size_t utf8_decoder_decode(Utf8Decoder *decoder,
                           const uint8_t *input, size_t input_len,
                           uint32_t *output, size_t output_capacity) {
    size_t out_count = 0;

    for (size_t i = 0; i < input_len && out_count < output_capacity; i++) {
        uint32_t result = utf8_decoder_feed(decoder, input[i]);

        if (result == UTF8_ACCEPT) {
            output[out_count++] = decoder->codepoint;
        } else if (result == UTF8_REJECT) {
            output[out_count++] = UTF8_REPLACEMENT_CHAR;
        }
        /* Intermediate state: continue feeding bytes */
    }

    return out_count;
}
