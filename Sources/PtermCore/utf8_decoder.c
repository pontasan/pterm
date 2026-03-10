#include "utf8_decoder.h"

/*
 * DFA-based UTF-8 decoder.
 *
 * Byte classification (12 classes for the transition table):
 *   class 0:  0x00-0x7F  ASCII
 *   class 1:  0x80-0x8F  continuation (low)
 *   class 2:  0xC2-0xDF  2-byte lead
 *   class 3:  0xE1-0xEC, 0xEE-0xEF  3-byte lead (normal)
 *   class 5:  0xF1-0xF3  4-byte lead (normal)
 *   class 6:  0xF4       4-byte lead (high-range constraint)
 *   class 7:  0xA0-0xBF  continuation (high)
 *   class 8:  0xC0-0xC1, 0xF5-0xFF  invalid
 *   class 9:  0x90-0x9F  continuation (mid)
 *   class 10: 0xE0       3-byte lead (overlong constraint)
 *   class 11: 0xF0       4-byte lead (overlong constraint)
 *
 * DFA states:
 *    0: ACCEPT  — start/accept state
 *   12: REJECT  — invalid sequence detected
 *   24: need 1 more continuation byte (any 0x80-0xBF)
 *   36: need 2 more continuation bytes (any)
 *   48: after E0 — need 2 more, first must be 0xA0-0xBF
 *   60: (unused)
 *   72: need 3 more continuation bytes (any) — after F1-F3
 *   84: after F0 — need 3 more, first must be 0x90-0xBF
 *   96: after F4 — need 3 more, first must be 0x80-0x8F
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
 * State transition table.  Index = state + class.
 *
 * Continuation classes 1/7/9 advance toward ACCEPT through the
 * intermediate state chain; lead/invalid classes trigger REJECT.
 * Constrained states (48, 84, 96) accept only the valid subset
 * of continuation bytes for their respective lead bytes.
 */
static const uint8_t utf8_transition[] = {
  /* class:  0  1  2  3  4  5  6  7  8  9 10 11 */
     0,12,24,36,12,72,96,12,12,12,48,84, /* state  0: ACCEPT  */
    12,12,12,12,12,12,12,12,12,12,12,12, /* state 12: REJECT  */
    12, 0,12,12,12,12,12, 0,12, 0,12,12, /* state 24: need 1 cont (any 80-BF) */
    12,24,12,12,12,12,12,24,12,24,12,12, /* state 36: need 2 cont (any) */
    12,12,12,12,12,12,12,24,12,12,12,12, /* state 48: E0: first must be A0-BF */
    12,12,12,12,12,12,12,12,12,12,12,12, /* state 60: (unused) */
    12,36,12,12,12,12,12,36,12,36,12,12, /* state 72: need 3 cont (any) */
    12,12,12,12,12,12,12,36,12,36,12,12, /* state 84: F0: first must be 90-BF */
    12,36,12,12,12,12,12,12,12,12,12,12, /* state 96: F4: first must be 80-8F */
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

    /* Lead-byte payload mask: extracts the significant bits from the
     * first byte of a UTF-8 sequence.  A lookup table is used instead
     * of the (0xFF >> type) trick because class 6 (F4) and class 11 (F0)
     * need 3 payload bits (mask 0x07) but their class numbers would
     * produce incorrect shift amounts. */
    static const uint8_t lead_mask[12] = {
        0x7F, /* class 0:  ASCII — 7 bits */
        0x3F, /* class 1:  continuation — not used as lead */
        0x1F, /* class 2:  C2-DF — 5 bits */
        0x0F, /* class 3:  E1-EC/EE-EF — 4 bits */
        0x0F, /* class 4:  (unused) */
        0x07, /* class 5:  F1-F3 — 3 bits */
        0x07, /* class 6:  F4 — 3 bits */
        0x3F, /* class 7:  continuation — not used as lead */
        0x00, /* class 8:  invalid */
        0x3F, /* class 9:  continuation — not used as lead */
        0x0F, /* class 10: E0 — 4 bits */
        0x07, /* class 11: F0 — 3 bits */
    };

    decoder->codepoint = (decoder->state != UTF8_ACCEPT)
        ? (byte & 0x3Fu) | (decoder->codepoint << 6)
        : byte & lead_mask[type];

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
