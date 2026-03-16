#ifndef VT_PARSER_H
#define VT_PARSER_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

/*
 * VT100/VT220/xterm escape sequence parser.
 *
 * Implements the canonical state machine based on Paul Flo Williams' diagram.
 * All unknown sequences are silently discarded (security spec item 5).
 * C1 control bytes are rejected in UTF-8 mode (handled by UTF-8 decoder layer).
 *
 * The parser is callback-based: it invokes action handlers as sequences
 * are recognized, without allocating memory or maintaining output buffers.
 *
 * Security hardening:
 *   - CSI parameter count limited to VT_PARSER_MAX_PARAMS
 *   - OSC/DCS string length limited to VT_PARSER_MAX_STRING
 *   - REP repeat count capped at VT_PARSER_MAX_REP
 */

#define VT_PARSER_MAX_PARAMS   32
#define VT_PARSER_MAX_INTERMEDIATES 4
#define VT_PARSER_MAX_STRING   (1024 * 1024)  /* 1MB DCS/OSC string limit */
#define VT_PARSER_MAX_REP      65535

/* Parser states */
typedef enum {
    VT_STATE_GROUND = 0,
    VT_STATE_ESCAPE,
    VT_STATE_ESCAPE_INTERMEDIATE,
    VT_STATE_CSI_ENTRY,
    VT_STATE_CSI_PARAM,
    VT_STATE_CSI_INTERMEDIATE,
    VT_STATE_CSI_IGNORE,
    VT_STATE_DCS_ENTRY,
    VT_STATE_DCS_PARAM,
    VT_STATE_DCS_INTERMEDIATE,
    VT_STATE_DCS_PASSTHROUGH,
    VT_STATE_DCS_IGNORE,
    VT_STATE_OSC_STRING,
    VT_STATE_SOS_PM_APC_STRING,
    VT_STATE_COUNT
} VtParserState;

/* Actions the parser can invoke */
typedef enum {
    VT_ACTION_NONE = 0,
    VT_ACTION_PRINT,           /* Printable character */
    VT_ACTION_EXECUTE,         /* C0 control character (BEL, BS, HT, LF, CR, etc.) */
    VT_ACTION_CSI_DISPATCH,    /* Complete CSI sequence */
    VT_ACTION_ESC_DISPATCH,    /* Complete ESC sequence */
    VT_ACTION_OSC_START,       /* OSC string started */
    VT_ACTION_OSC_PUT,         /* OSC string character */
    VT_ACTION_OSC_END,         /* OSC string completed */
    VT_ACTION_DCS_START,       /* DCS passthrough started */
    VT_ACTION_DCS_PUT,         /* DCS passthrough character */
    VT_ACTION_DCS_END,         /* DCS passthrough completed */
    VT_ACTION_HOOK,            /* DCS hook (start of passthrough) */
    VT_ACTION_UNHOOK,          /* DCS unhook (end of passthrough) */
} VtParserAction;

/* Forward declaration */
typedef struct VtParser VtParser;

/* Callback for parser actions */
typedef void (*VtParserCallback)(VtParser *parser, VtParserAction action,
                                 uint32_t codepoint, void *user_data);

struct VtParser {
    VtParserState state;

    /* CSI parameters */
    int32_t  params[VT_PARSER_MAX_PARAMS];
    uint32_t param_count;
    bool     param_has_sub;  /* ';' vs ':' sub-parameter separator seen */

    /* Intermediate characters (between ESC and final byte) */
    uint8_t  intermediates[VT_PARSER_MAX_INTERMEDIATES];
    uint32_t intermediate_count;

    /* OSC/DCS string accumulator */
    uint8_t *string_buf;
    size_t   string_len;
    size_t   string_capacity;
    bool     string_overflow;  /* Set when string buffer allocation fails or limit exceeded */
    uint32_t osc_command;
    bool     osc_command_has_digits;
    bool     osc_saw_separator;
    bool     osc_ignore_payload;

    /* Callback */
    VtParserCallback callback;
    void            *user_data;
};

/*
 * Initialize a parser.
 * callback: function invoked for each recognized action.
 * user_data: opaque pointer passed to callback.
 */
void vt_parser_init(VtParser *parser, VtParserCallback callback,
                    void *user_data);

/*
 * Destroy parser and free internal buffers.
 */
void vt_parser_destroy(VtParser *parser);

/*
 * Reset parser to ground state.
 */
void vt_parser_reset(VtParser *parser);

/*
 * Feed codepoints to the parser.
 * codepoints: array of Unicode codepoints (output from UTF-8 decoder).
 * count: number of codepoints.
 *
 * The parser processes each codepoint through its state machine and
 * invokes the callback for recognized actions.
 */
void vt_parser_feed(VtParser *parser, const uint32_t *codepoints, size_t count);

/*
 * Feed a single codepoint to the parser.
 */
void vt_parser_feed_one(VtParser *parser, uint32_t codepoint);

/*
 * Helper to get a CSI parameter with a default value.
 * index: 0-based parameter index.
 * default_val: value to return if parameter is missing or zero.
 */
int32_t vt_parser_param(const VtParser *parser, uint32_t index,
                         int32_t default_val);

#endif /* VT_PARSER_H */
