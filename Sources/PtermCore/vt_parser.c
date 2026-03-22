#include "vt_parser.h"
#include <stdlib.h>
#include <string.h>

#if defined(__aarch64__)
#include <arm_neon.h>
#endif
#include <limits.h>

/*
 * VT Parser State Machine
 *
 * Implements the canonical VT100/VT220/xterm parser based on
 * Paul Flo Williams' state diagram.
 *
 * Key security properties:
 * - Unknown sequences are silently discarded (never echoed back)
 * - Parameter counts are bounded (VT_PARSER_MAX_PARAMS)
 * - String buffers are bounded (VT_PARSER_MAX_STRING)
 * - No eval of sequence data
 */

/* --- Internal helpers --- */

static void parser_clear(VtParser *parser) {
    parser->param_count = 0;
    parser->intermediate_count = 0;
    parser->param_has_sub = false;
    memset(parser->params, 0, sizeof(parser->params));
    memset(parser->intermediates, 0, sizeof(parser->intermediates));
}

static void parser_string_clear(VtParser *parser) {
    parser->string_len = 0;
    parser->string_overflow = false;
    parser->osc_command = 0;
    parser->osc_command_has_digits = false;
    parser->osc_saw_separator = false;
    parser->osc_ignore_payload = false;
}

static inline bool osc_command_should_capture(uint32_t command, bool has_digits) {
    if (!has_digits) return false;
    switch (command) {
        case 0:
        case 2:
        case 7:
        case 52:
            return true;
        default:
            return false;
    }
}

static inline bool bytes_have_high_bit_set(const uint8_t *bytes, size_t count) {
    if (!bytes || count == 0) return false;

    const size_t word_mask = ~(size_t)0 / 0xFF;
    const size_t high_bit_mask = word_mask << 7;

    while (count > 0 && ((uintptr_t)bytes & (sizeof(size_t) - 1)) != 0) {
        if (*bytes & 0x80) return true;
        bytes++;
        count--;
    }

    const size_t *words = (const size_t *)bytes;
    while (count >= sizeof(size_t)) {
        if ((*words & high_bit_mask) != 0) return true;
        words++;
        count -= sizeof(size_t);
    }

    bytes = (const uint8_t *)words;
    while (count-- > 0) {
        if (*bytes & 0x80) return true;
        bytes++;
    }
    return false;
}

#if !defined(__aarch64__)
static inline bool word_has_zero_byte(size_t word) {
    const size_t ones = ~(size_t)0 / 0xFF;
    const size_t high_bits = ones << 7;
    return ((word - ones) & ~word & high_bits) != 0;
}

static inline bool word_has_non_printable_ascii(size_t word) {
    const size_t ones = ~(size_t)0 / 0xFF;
    const size_t high_bits = ones << 7;

    if ((word & high_bits) != 0) {
        return true;
    }

    const size_t spaces = ones * 0x20;
    if (((word - spaces) & ~word & high_bits) != 0) {
        return true;
    }

    return word_has_zero_byte(word ^ (ones * 0x7F));
}

static inline bool word_has_non_text_ascii(size_t word) {
    if (!word_has_non_printable_ascii(word)) {
        return false;
    }

    const uint8_t *bytes = (const uint8_t *)&word;
    for (size_t i = 0; i < sizeof(size_t); i++) {
        const uint8_t byte = bytes[i];
        if ((byte >= 0x20 && byte < 0x7F) || byte == 0x09 || byte == 0x0A || byte == 0x0D) {
            continue;
        }
        return true;
    }
    return false;
}
#endif

typedef enum {
    ASCII_SCAN_INCOMPLETE = 0,
    ASCII_SCAN_BEL,
    ASCII_SCAN_ST,
    ASCII_SCAN_ESCAPE,
    ASCII_SCAN_NON_ASCII,
} AsciiStringScanResult;

static AsciiStringScanResult scan_ascii_string_payload(
    const uint8_t *bytes,
    size_t count,
    bool allow_bel,
    size_t *terminator_index
) {
    size_t index = 0;

    while (index < count) {
        const uint8_t *cursor = bytes + index;
        size_t remaining = count - index;
        const uint8_t *esc = memchr(cursor, 0x1B, remaining);
        const uint8_t *bel = allow_bel ? memchr(cursor, 0x07, remaining) : NULL;
        const uint8_t *next = NULL;

        if (esc && bel) {
            next = esc < bel ? esc : bel;
        } else {
            next = esc ? esc : bel;
        }

        size_t span = next ? (size_t)(next - cursor) : remaining;
        if (bytes_have_high_bit_set(cursor, span)) {
            return ASCII_SCAN_NON_ASCII;
        }
        index += span;

        if (!next) {
            return ASCII_SCAN_INCOMPLETE;
        }

        if (*next == 0x07) {
            if (terminator_index) *terminator_index = index;
            return ASCII_SCAN_BEL;
        }

        if (index + 1 >= count) {
            if (terminator_index) *terminator_index = index;
            return ASCII_SCAN_INCOMPLETE;
        }
        if (bytes[index + 1] == '\\') {
            if (terminator_index) *terminator_index = index;
            return ASCII_SCAN_ST;
        }

        if (terminator_index) *terminator_index = index;
        return ASCII_SCAN_ESCAPE;
    }

    return ASCII_SCAN_INCOMPLETE;
}

#if defined(__aarch64__)
static inline size_t scan_printable_ascii_prefix_neon(
    const uint8_t *bytes,
    size_t count
) {
    const uint8x16_t space = vdupq_n_u8(0x20);
    const uint8x16_t del = vdupq_n_u8(0x7F);
    size_t index = 0;

    while (index + 16 <= count) {
        uint8x16_t chunk = vld1q_u8(bytes + index);
        uint8x16_t bad = vorrq_u8(vcltq_u8(chunk, space), vcgeq_u8(chunk, del));
        if (vmaxvq_u8(bad) != 0) break;
        index += 16;
    }

    return index;
}

static inline size_t scan_text_ascii_prefix_neon(
    const uint8_t *bytes,
    size_t count
) {
    const uint8x16_t space = vdupq_n_u8(0x20);
    const uint8x16_t del = vdupq_n_u8(0x7F);
    const uint8x16_t ht = vdupq_n_u8(0x09);
    const uint8x16_t lf = vdupq_n_u8(0x0A);
    const uint8x16_t cr = vdupq_n_u8(0x0D);
    size_t index = 0;

    while (index + 16 <= count) {
        uint8x16_t chunk = vld1q_u8(bytes + index);
        uint8x16_t low = vcltq_u8(chunk, space);
        uint8x16_t allowedLow = vorrq_u8(
            vceqq_u8(chunk, ht),
            vorrq_u8(vceqq_u8(chunk, lf), vceqq_u8(chunk, cr))
        );
        uint8x16_t badLow = vandq_u8(low, vmvnq_u8(allowedLow));
        uint8x16_t bad = vorrq_u8(badLow, vcgeq_u8(chunk, del));
        if (vmaxvq_u8(bad) != 0) break;
        index += 16;
    }

    return index;
}
#endif

size_t vt_parser_scan_printable_ascii_prefix(
    const uint8_t *bytes,
    size_t count
) {
    if (!bytes || count == 0) return 0;

    size_t index = 0;
#if defined(__aarch64__)
    index = scan_printable_ascii_prefix_neon(bytes, count);
#else
    while (index < count && ((uintptr_t)(bytes + index) & (sizeof(size_t) - 1)) != 0) {
        uint8_t byte = bytes[index];
        if (byte < 0x20 || byte >= 0x7F) return index;
        index++;
    }

    while (index + sizeof(size_t) <= count) {
        size_t word;
        memcpy(&word, bytes + index, sizeof(word));
        if (word_has_non_printable_ascii(word)) break;
        index += sizeof(size_t);
    }
#endif

    while (index < count) {
        uint8_t byte = bytes[index];
        if (byte < 0x20 || byte >= 0x7F) break;
        index++;
    }

    return index;
}

size_t vt_parser_scan_text_ascii_prefix(
    const uint8_t *bytes,
    size_t count
) {
    if (!bytes || count == 0) return 0;

    size_t index = 0;
#if defined(__aarch64__)
    index = scan_text_ascii_prefix_neon(bytes, count);
#else
    while (index < count && ((uintptr_t)(bytes + index) & (sizeof(size_t) - 1)) != 0) {
        uint8_t byte = bytes[index];
        if (!((byte >= 0x20 && byte < 0x7F) || byte == 0x09 || byte == 0x0A || byte == 0x0D)) {
            return index;
        }
        index++;
    }

    while (index + sizeof(size_t) <= count) {
        size_t word;
        memcpy(&word, bytes + index, sizeof(word));
        if (word_has_non_text_ascii(word)) break;
        index += sizeof(size_t);
    }
#endif

    while (index < count) {
        uint8_t byte = bytes[index];
        if (!((byte >= 0x20 && byte < 0x7F) || byte == 0x09 || byte == 0x0A || byte == 0x0D)) {
            break;
        }
        index++;
    }

    return index;
}

static void parser_string_put(VtParser *parser, uint8_t byte) {
    if (parser->string_len >= VT_PARSER_MAX_STRING) {
        parser->string_overflow = true;
        return;
    }

    if (parser->string_len >= parser->string_capacity) {
        size_t new_cap = parser->string_capacity == 0 ? 256 : parser->string_capacity * 2;
        if (new_cap > VT_PARSER_MAX_STRING) new_cap = VT_PARSER_MAX_STRING;
        uint8_t *new_buf = realloc(parser->string_buf, new_cap);
        if (!new_buf) {
            parser->string_overflow = true;
            return;
        }
        parser->string_buf = new_buf;
        parser->string_capacity = new_cap;
    }

    parser->string_buf[parser->string_len++] = byte;
}

static void parser_collect(VtParser *parser, uint8_t byte) {
    if (parser->intermediate_count < VT_PARSER_MAX_INTERMEDIATES) {
        parser->intermediates[parser->intermediate_count++] = byte;
    }
}

static void parser_param_add(VtParser *parser, uint8_t byte) {
    if (byte == ';') {
        /* Move to next parameter */
        if (parser->param_count == 0) {
            parser->param_count = 1;
        }
        if (parser->param_count < VT_PARSER_MAX_PARAMS) {
            parser->param_count++;
        }
    } else if (byte == ':') {
        /* Sub-parameter separator */
        parser->param_has_sub = true;
        if (parser->param_count == 0) {
            parser->param_count = 1;
        }
        if (parser->param_count < VT_PARSER_MAX_PARAMS) {
            parser->param_count++;
        }
    } else if (byte >= '0' && byte <= '9') {
        /* Accumulate digit */
        /* Ensure param_count reflects at least one parameter */
        if (parser->param_count == 0) {
            parser->param_count = 1;
        }

        uint32_t idx = parser->param_count - 1;
        if (idx >= VT_PARSER_MAX_PARAMS) return;

        int32_t val = parser->params[idx];
        /* Clamp BEFORE multiplication to prevent signed integer overflow (UB) */
        if (val > (INT32_MAX - 9) / 10) {
            parser->params[idx] = INT32_MAX;
        } else {
            parser->params[idx] = val * 10 + (byte - '0');
        }
    }
}

static void emit(VtParser *parser, VtParserAction action, uint32_t codepoint) {
    if (parser->callback) {
        parser->callback(parser, action, codepoint, parser->user_data);
    }
}

/* --- Codepoint classification --- */

static inline bool is_c0(uint32_t cp) {
    return cp <= 0x1F || cp == 0x7F;
}

static inline bool is_printable(uint32_t cp) {
    return cp >= 0x20 && cp != 0x7F;
}

static inline bool is_intermediate(uint32_t cp) {
    return cp >= 0x20 && cp <= 0x2F;
}

static inline bool is_param_byte(uint32_t cp) {
    return (cp >= 0x30 && cp <= 0x39) || cp == ';' || cp == ':';
}

static inline bool is_csi_final(uint32_t cp) {
    return cp >= 0x40 && cp <= 0x7E;
}

static inline bool is_esc_final(uint32_t cp) {
    return cp >= 0x30 && cp <= 0x7E;
}

static inline bool is_private_marker(uint32_t cp) {
    return cp >= 0x3C && cp <= 0x3F;  /* <=>? */
}

/* --- C0 control handling --- */

static void handle_execute(VtParser *parser, uint32_t cp) {
    /* C0 controls that are always processed regardless of state */
    switch (cp) {
        case 0x05: /* ENQ */
        case 0x07: /* BEL */
        case 0x08: /* BS */
        case 0x09: /* HT */
        case 0x0A: /* LF */
        case 0x0B: /* VT (treated as LF) */
        case 0x0C: /* FF (treated as LF) */
        case 0x0D: /* CR */
        case 0x0E: /* SO (Shift Out) */
        case 0x0F: /* SI (Shift In) */
            emit(parser, VT_ACTION_EXECUTE, cp);
            break;
        default:
            /* Other C0 controls: silently ignore */
            break;
    }
}

/* --- State machine --- */

void vt_parser_init(VtParser *parser, VtParserCallback callback,
                    void *user_data) {
    memset(parser, 0, sizeof(VtParser));
    parser->state = VT_STATE_GROUND;
    parser->callback = callback;
    parser->user_data = user_data;
    parser->string_buf = NULL;
    parser->string_len = 0;
    parser->string_capacity = 0;
}

void vt_parser_destroy(VtParser *parser) {
    if (parser) {
        free(parser->string_buf);
        parser->string_buf = NULL;
        parser->string_capacity = 0;
    }
}

void vt_parser_reset(VtParser *parser) {
    VtParserCallback cb = parser->callback;
    void *ud = parser->user_data;
    uint8_t *sb = parser->string_buf;
    size_t sc = parser->string_capacity;

    memset(parser, 0, sizeof(VtParser));
    parser->state = VT_STATE_GROUND;
    parser->callback = cb;
    parser->user_data = ud;
    parser->string_buf = sb;
    parser->string_capacity = sc;
    parser->string_len = 0;
}

void vt_parser_feed_one(VtParser *parser, uint32_t cp) {
    /* ESC always transitions to ESCAPE state from anywhere */
    if (cp == 0x1B) {
        /* If we were in an OSC/DCS string, end it */
        if (parser->state == VT_STATE_OSC_STRING) {
            emit(parser, VT_ACTION_OSC_END, 0);
        } else if (parser->state == VT_STATE_DCS_PASSTHROUGH) {
            emit(parser, VT_ACTION_DCS_END, 0);
            emit(parser, VT_ACTION_UNHOOK, 0);
        }
        parser_clear(parser);
        parser->state = VT_STATE_ESCAPE;
        return;
    }

    /* CAN (0x18) and SUB (0x1A) always abort sequence and return to ground */
    if (cp == 0x18 || cp == 0x1A) {
        if (parser->state == VT_STATE_DCS_PASSTHROUGH) {
            emit(parser, VT_ACTION_DCS_END, 0);
            emit(parser, VT_ACTION_UNHOOK, 0);
        } else if (parser->state == VT_STATE_OSC_STRING) {
            emit(parser, VT_ACTION_OSC_END, 0);
        }
        parser->state = VT_STATE_GROUND;
        emit(parser, VT_ACTION_EXECUTE, cp);
        return;
    }

    switch (parser->state) {
    case VT_STATE_GROUND:
        if (is_c0(cp)) {
            handle_execute(parser, cp);
        } else if (is_printable(cp) || cp > 0x7F) {
            emit(parser, VT_ACTION_PRINT, cp);
        }
        break;

    case VT_STATE_ESCAPE:
        if (cp == '[') {
            /* CSI introducer */
            parser_clear(parser);
            parser->state = VT_STATE_CSI_ENTRY;
        } else if (cp == ']') {
            /* OSC introducer */
            parser_string_clear(parser);
            parser->state = VT_STATE_OSC_STRING;
            emit(parser, VT_ACTION_OSC_START, 0);
        } else if (cp == 'P') {
            /* DCS introducer */
            parser_clear(parser);
            parser_string_clear(parser);
            parser->state = VT_STATE_DCS_ENTRY;
        } else if (cp == 'X' || cp == '^' || cp == '_') {
            /* SOS, PM, APC - absorb and discard */
            parser->state = VT_STATE_SOS_PM_APC_STRING;
        } else if (is_intermediate(cp)) {
            parser_collect(parser, (uint8_t)cp);
            parser->state = VT_STATE_ESCAPE_INTERMEDIATE;
        } else if (is_esc_final(cp)) {
            emit(parser, VT_ACTION_ESC_DISPATCH, cp);
            parser->state = VT_STATE_GROUND;
        } else if (is_c0(cp)) {
            handle_execute(parser, cp);
            /* Stay in ESCAPE state */
        } else {
            /* Unknown: silently discard, return to ground */
            parser->state = VT_STATE_GROUND;
        }
        break;

    case VT_STATE_ESCAPE_INTERMEDIATE:
        if (is_intermediate(cp)) {
            parser_collect(parser, (uint8_t)cp);
        } else if (is_esc_final(cp)) {
            emit(parser, VT_ACTION_ESC_DISPATCH, cp);
            parser->state = VT_STATE_GROUND;
        } else if (is_c0(cp)) {
            handle_execute(parser, cp);
        } else {
            parser->state = VT_STATE_GROUND;
        }
        break;

    case VT_STATE_CSI_ENTRY:
        if (is_param_byte(cp)) {
            parser_param_add(parser, (uint8_t)cp);
            parser->state = VT_STATE_CSI_PARAM;
        } else if (is_private_marker(cp)) {
            /* Private mode marker (?, >, =, <) stored as intermediate */
            parser_collect(parser, (uint8_t)cp);
            parser->state = VT_STATE_CSI_PARAM;
        } else if (is_intermediate(cp)) {
            parser_collect(parser, (uint8_t)cp);
            parser->state = VT_STATE_CSI_INTERMEDIATE;
        } else if (is_csi_final(cp)) {
            emit(parser, VT_ACTION_CSI_DISPATCH, cp);
            parser->state = VT_STATE_GROUND;
        } else if (is_c0(cp)) {
            handle_execute(parser, cp);
        } else {
            parser->state = VT_STATE_CSI_IGNORE;
        }
        break;

    case VT_STATE_CSI_PARAM:
        if (is_param_byte(cp)) {
            parser_param_add(parser, (uint8_t)cp);
        } else if (is_intermediate(cp)) {
            parser_collect(parser, (uint8_t)cp);
            parser->state = VT_STATE_CSI_INTERMEDIATE;
        } else if (is_csi_final(cp)) {
            emit(parser, VT_ACTION_CSI_DISPATCH, cp);
            parser->state = VT_STATE_GROUND;
        } else if (is_c0(cp)) {
            handle_execute(parser, cp);
        } else if (is_private_marker(cp)) {
            /* Private marker after params: ignore rest */
            parser->state = VT_STATE_CSI_IGNORE;
        } else {
            parser->state = VT_STATE_CSI_IGNORE;
        }
        break;

    case VT_STATE_CSI_INTERMEDIATE:
        if (is_intermediate(cp)) {
            parser_collect(parser, (uint8_t)cp);
        } else if (is_csi_final(cp)) {
            emit(parser, VT_ACTION_CSI_DISPATCH, cp);
            parser->state = VT_STATE_GROUND;
        } else if (is_c0(cp)) {
            handle_execute(parser, cp);
        } else {
            parser->state = VT_STATE_CSI_IGNORE;
        }
        break;

    case VT_STATE_CSI_IGNORE:
        if (is_csi_final(cp)) {
            parser->state = VT_STATE_GROUND;
        } else if (is_c0(cp)) {
            handle_execute(parser, cp);
        }
        /* Everything else is silently consumed */
        break;

    case VT_STATE_DCS_ENTRY:
        if (is_param_byte(cp)) {
            parser_param_add(parser, (uint8_t)cp);
            parser->state = VT_STATE_DCS_PARAM;
        } else if (is_intermediate(cp)) {
            parser_collect(parser, (uint8_t)cp);
            parser->state = VT_STATE_DCS_INTERMEDIATE;
        } else if (cp >= 0x40 && cp <= 0x7E) {
            /* Final byte: enter passthrough */
            emit(parser, VT_ACTION_HOOK, cp);
            emit(parser, VT_ACTION_DCS_START, cp);
            parser->state = VT_STATE_DCS_PASSTHROUGH;
        } else {
            parser->state = VT_STATE_DCS_IGNORE;
        }
        break;

    case VT_STATE_DCS_PARAM:
        if (is_param_byte(cp)) {
            parser_param_add(parser, (uint8_t)cp);
        } else if (is_intermediate(cp)) {
            parser_collect(parser, (uint8_t)cp);
            parser->state = VT_STATE_DCS_INTERMEDIATE;
        } else if (cp >= 0x40 && cp <= 0x7E) {
            emit(parser, VT_ACTION_HOOK, cp);
            emit(parser, VT_ACTION_DCS_START, cp);
            parser->state = VT_STATE_DCS_PASSTHROUGH;
        } else {
            parser->state = VT_STATE_DCS_IGNORE;
        }
        break;

    case VT_STATE_DCS_INTERMEDIATE:
        if (is_intermediate(cp)) {
            parser_collect(parser, (uint8_t)cp);
        } else if (cp >= 0x40 && cp <= 0x7E) {
            emit(parser, VT_ACTION_HOOK, cp);
            emit(parser, VT_ACTION_DCS_START, cp);
            parser->state = VT_STATE_DCS_PASSTHROUGH;
        } else {
            parser->state = VT_STATE_DCS_IGNORE;
        }
        break;

    case VT_STATE_DCS_PASSTHROUGH:
        if (cp == 0x9C) {
            /* ST (String Terminator) */
            emit(parser, VT_ACTION_DCS_END, 0);
            emit(parser, VT_ACTION_UNHOOK, 0);
            parser->state = VT_STATE_GROUND;
        } else if (is_c0(cp)) {
            /* C0 in DCS passthrough: pass through */
            emit(parser, VT_ACTION_DCS_PUT, cp);
        } else if (cp >= 0x20 && cp <= 0x7E) {
            parser_string_put(parser, (uint8_t)cp);
            emit(parser, VT_ACTION_DCS_PUT, cp);
        } else if (cp == 0x7F) {
            /* DEL: ignore in passthrough */
        }
        /* Note: ESC is handled at the top of feed_one */
        break;

    case VT_STATE_DCS_IGNORE:
        if (cp == 0x9C) {
            parser->state = VT_STATE_GROUND;
        }
        /* ESC handled at top; everything else consumed */
        break;

    case VT_STATE_OSC_STRING:
        if (cp == 0x07) {
            /* BEL terminates OSC (xterm extension, widely used) */
            emit(parser, VT_ACTION_OSC_END, 0);
            parser->state = VT_STATE_GROUND;
        } else if (cp == 0x9C) {
            /* ST (String Terminator) */
            emit(parser, VT_ACTION_OSC_END, 0);
            parser->state = VT_STATE_GROUND;
        } else if (cp >= 0x20 && cp <= 0x7E) {
            if (!parser->osc_saw_separator) {
                if (cp >= '0' && cp <= '9') {
                    parser->osc_command_has_digits = true;
                    if (parser->osc_command > (UINT32_MAX - 9) / 10) {
                        parser->osc_command = UINT32_MAX;
                    } else {
                        parser->osc_command = parser->osc_command * 10 + (uint32_t)(cp - '0');
                    }
                } else if (cp == ';') {
                    parser->osc_saw_separator = true;
                    parser->osc_ignore_payload = !osc_command_should_capture(
                        parser->osc_command,
                        parser->osc_command_has_digits
                    );
                } else {
                    parser->osc_saw_separator = true;
                    parser->osc_ignore_payload = true;
                }
                parser_string_put(parser, (uint8_t)cp);
                emit(parser, VT_ACTION_OSC_PUT, cp);
            } else if (!parser->osc_ignore_payload) {
                parser_string_put(parser, (uint8_t)cp);
                emit(parser, VT_ACTION_OSC_PUT, cp);
            }
        } else if (is_c0(cp) && cp != 0x07) {
            /* C0 controls other than BEL: ignore in OSC string */
        }
        /* Note: ESC is handled at top of feed_one;
         * ESC \ (ST) is ESC followed by \, which transitions to
         * ESCAPE state where \ dispatches as ESC_DISPATCH.
         * The OSC_END is emitted when ESC is seen. */
        break;

    case VT_STATE_SOS_PM_APC_STRING:
        if (cp == 0x9C) {
            parser->state = VT_STATE_GROUND;
        }
        /* ESC handled at top; everything else silently consumed */
        break;

    default:
        parser->state = VT_STATE_GROUND;
        break;
    }
}

void vt_parser_feed(VtParser *parser, const uint32_t *codepoints, size_t count) {
    for (size_t i = 0; i < count; i++) {
        if (parser->state == VT_STATE_OSC_STRING &&
            parser->osc_saw_separator &&
            parser->osc_ignore_payload) {
            for (; i < count; i++) {
                uint32_t cp = codepoints[i];
                if (cp == 0x07) {
                    emit(parser, VT_ACTION_OSC_END, 0);
                    parser->state = VT_STATE_GROUND;
                    break;
                }
                if (cp == 0x9C) {
                    emit(parser, VT_ACTION_OSC_END, 0);
                    parser->state = VT_STATE_GROUND;
                    break;
                }
                if (cp == 0x1B) {
                    emit(parser, VT_ACTION_OSC_END, 0);
                    parser_clear(parser);
                    parser->state = VT_STATE_ESCAPE;
                    break;
                }
            }
            continue;
        }
        vt_parser_feed_one(parser, codepoints[i]);
    }
}

size_t vt_parser_consume_ascii_ignored_string_fast_path(
    VtParser *parser,
    const uint8_t *bytes,
    size_t count
) {
    if (!parser || !bytes || count == 0) {
        return 0;
    }

    if (parser->state == VT_STATE_GROUND && count >= 2 && bytes[0] == 0x1B) {
        if (bytes[1] == ']') {
            size_t index = 2;
            uint32_t command = 0;
            bool has_digits = false;

            while (index < count) {
                const uint8_t byte = bytes[index];
                if (byte >= '0' && byte <= '9') {
                    has_digits = true;
                    if (command > (UINT32_MAX - 9) / 10) {
                        command = UINT32_MAX;
                    } else {
                        command = command * 10 + (uint32_t)(byte - '0');
                    }
                    index++;
                    continue;
                }
                break;
            }

            if (!has_digits || index >= count || bytes[index] != ';' ||
                osc_command_should_capture(command, has_digits)) {
                return 0;
            }

            parser_string_clear(parser);
            parser->state = VT_STATE_OSC_STRING;
            parser->osc_command = command;
            parser->osc_command_has_digits = true;
            parser->osc_saw_separator = true;
            parser->osc_ignore_payload = true;
            index++;

            size_t terminator_index = 0;
            switch (scan_ascii_string_payload(bytes + index, count - index, true, &terminator_index)) {
                case ASCII_SCAN_BEL:
                    emit(parser, VT_ACTION_OSC_END, 0);
                    parser->state = VT_STATE_GROUND;
                    return index + terminator_index + 1;
                case ASCII_SCAN_ST:
                    emit(parser, VT_ACTION_OSC_END, 0);
                    parser_clear(parser);
                    parser->state = VT_STATE_GROUND;
                    return index + terminator_index + 2;
                case ASCII_SCAN_ESCAPE:
                    emit(parser, VT_ACTION_OSC_END, 0);
                    parser_clear(parser);
                    parser->state = VT_STATE_ESCAPE;
                    return index + terminator_index + 1;
                case ASCII_SCAN_NON_ASCII:
                    return 0;
                case ASCII_SCAN_INCOMPLETE:
                    return count;
            }
        }

        if (bytes[1] == 'X' || bytes[1] == '^' || bytes[1] == '_') {
            parser->state = VT_STATE_SOS_PM_APC_STRING;
            size_t terminator_index = 0;
            switch (scan_ascii_string_payload(bytes + 2, count - 2, false, &terminator_index)) {
                case ASCII_SCAN_ST:
                    parser_clear(parser);
                    parser->state = VT_STATE_GROUND;
                    return 2 + terminator_index + 2;
                case ASCII_SCAN_ESCAPE:
                    parser_clear(parser);
                    parser->state = VT_STATE_ESCAPE;
                    return 2 + terminator_index + 1;
                case ASCII_SCAN_NON_ASCII:
                    return 0;
                case ASCII_SCAN_BEL:
                case ASCII_SCAN_INCOMPLETE:
                    return count;
            }
        }
    }

    if (parser->state == VT_STATE_OSC_STRING &&
        parser->osc_saw_separator &&
        parser->osc_ignore_payload) {
        size_t terminator_index = 0;
        switch (scan_ascii_string_payload(bytes, count, true, &terminator_index)) {
            case ASCII_SCAN_BEL:
                emit(parser, VT_ACTION_OSC_END, 0);
                parser->state = VT_STATE_GROUND;
                return terminator_index + 1;
            case ASCII_SCAN_ST:
                emit(parser, VT_ACTION_OSC_END, 0);
                parser_clear(parser);
                parser->state = VT_STATE_GROUND;
                return terminator_index + 2;
            case ASCII_SCAN_ESCAPE:
                emit(parser, VT_ACTION_OSC_END, 0);
                parser_clear(parser);
                parser->state = VT_STATE_ESCAPE;
                return terminator_index + 1;
            case ASCII_SCAN_NON_ASCII:
                return 0;
            case ASCII_SCAN_INCOMPLETE:
                return count;
        }
    }

    if (parser->state == VT_STATE_SOS_PM_APC_STRING) {
        size_t terminator_index = 0;
        switch (scan_ascii_string_payload(bytes, count, false, &terminator_index)) {
            case ASCII_SCAN_ST:
                parser_clear(parser);
                parser->state = VT_STATE_GROUND;
                return terminator_index + 2;
            case ASCII_SCAN_ESCAPE:
                parser_clear(parser);
                parser->state = VT_STATE_ESCAPE;
                return terminator_index + 1;
            case ASCII_SCAN_NON_ASCII:
                return 0;
            case ASCII_SCAN_BEL:
            case ASCII_SCAN_INCOMPLETE:
                return count;
        }
    }

    return 0;
}

int32_t vt_parser_param(const VtParser *parser, uint32_t index,
                         int32_t default_val) {
    if (index >= parser->param_count || parser->params[index] <= 0) {
        return default_val;
    }
    return parser->params[index];
}
