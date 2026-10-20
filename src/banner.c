#include "banner.h"

#include <string.h>

enum {
    SCAN_START,
    SCAN_DIGITS,
    SCAN_BODY,
    SCAN_ESC,
    SCAN_CSI,
    SCAN_CR1,
    SCAN_CR2
};

enum { SCAN_CONTINUE, SCAN_LINE_DONE, SCAN_FAIL };

static const uint8_t START_PREFIX[] = { 0x1b, '[', '3', '8', ';', '5', ';' };
static const uint8_t LEFT_HALF_BLOCK[] = { 0xe2, 0x96, 0x90 };
static const char KEY_TEXT[] = "ClaudeCodev";

static void emit(qc_filter *f, qc_event_kind kind, const uint8_t *data, size_t len)
{
    if (len > 0 || kind == QC_EV_DISARMED) {
        f->emit(f->ctx, kind, data, len);
    }
}

static void disarm(qc_filter *f, qc_watch_state state, const char *reason)
{
    f->watch = state;
    emit(f, QC_EV_DISARMED, (const uint8_t *)reason, strlen(reason) + 1);
}

static void begin_line(qc_filter *f, int line_no)
{
    f->line_no = line_no;
    f->scan = SCAN_START;
    f->start_index = 0;
    f->start_digits = 0;
    f->line_begin = f->held_len;
    f->text_len = 0;
    f->text_overflow = 0;
}

static void begin_candidate(qc_filter *f, uint64_t now_ms)
{
    f->holding = 1;
    f->held_len = 0;
    f->recognised_end = 0;
    f->last_held_ms = now_ms;
    begin_line(f, 1);
}

static void stop_holding(qc_filter *f)
{
    f->holding = 0;
    f->held_len = 0;
    f->recognised_end = 0;
}

static void release_unchanged(qc_filter *f, size_t len)
{
    emit(f, QC_EV_OUTPUT, f->held, len);
    stop_holding(f);
}

static void add_text(qc_filter *f, uint8_t b)
{
    if (f->line_no != 1) {
        return;
    }
    if (f->text_len < sizeof f->text) {
        f->text[f->text_len++] = b;
    } else {
        f->text_overflow = 1;
    }
}

static int is_digit(uint8_t b)
{
    return b >= '0' && b <= '9';
}

static int scan_byte(qc_filter *f, uint8_t b)
{
    switch (f->scan) {
    case SCAN_START:
        if (b != START_PREFIX[f->start_index]) {
            return SCAN_FAIL;
        }
        f->start_index++;
        if (f->start_index == sizeof START_PREFIX) {
            f->scan = SCAN_DIGITS;
        }
        return SCAN_CONTINUE;
    case SCAN_DIGITS:
        if (is_digit(b) && f->start_digits < 3) {
            f->start_digits++;
            return SCAN_CONTINUE;
        }
        if (b == 'm' && f->start_digits > 0) {
            f->scan = SCAN_BODY;
            return SCAN_CONTINUE;
        }
        return SCAN_FAIL;
    case SCAN_BODY:
        if (b == 0x1b) {
            f->scan = SCAN_ESC;
            return SCAN_CONTINUE;
        }
        if (b == '\r') {
            f->scan = SCAN_CR1;
            return SCAN_CONTINUE;
        }
        if (b < 0x20 || b == 0x7f) {
            return SCAN_FAIL;
        }
        if (b != ' ') {
            add_text(f, b);
        }
        return SCAN_CONTINUE;
    case SCAN_ESC:
        if (b != '[') {
            return SCAN_FAIL;
        }
        f->scan = SCAN_CSI;
        return SCAN_CONTINUE;
    case SCAN_CSI:
        if (b >= 0x20 && b <= 0x3f) {
            return SCAN_CONTINUE;
        }
        if (b >= 0x40 && b <= 0x7e) {
            f->scan = SCAN_BODY;
            return SCAN_CONTINUE;
        }
        return SCAN_FAIL;
    case SCAN_CR1:
        if (b != '\r') {
            return SCAN_FAIL;
        }
        f->scan = SCAN_CR2;
        return SCAN_CONTINUE;
    case SCAN_CR2:
        return b == '\n' ? SCAN_LINE_DONE : SCAN_FAIL;
    default:
        return SCAN_FAIL;
    }
}

static size_t version_length(const uint8_t *s, size_t len)
{
    size_t i = 0;
    for (int group = 0; group < 3; group++) {
        size_t digits = 0;
        while (i < len && is_digit(s[i])) {
            i++;
            digits++;
        }
        if (digits == 0) {
            return 0;
        }
        if (group < 2) {
            if (i >= len || s[i] != '.') {
                return 0;
            }
            i++;
        }
    }
    return i;
}

static int line1_is_key(const qc_filter *f)
{
    const size_t key_len = sizeof KEY_TEXT - 1;
    if (f->text_overflow || f->text_len < key_len) {
        return 0;
    }
    for (size_t p = 0; p + key_len <= f->text_len; p++) {
        if (memcmp(f->text + p, KEY_TEXT, key_len) != 0) {
            continue;
        }
        if (version_length(f->text + p + key_len, f->text_len - p - key_len) == 0) {
            continue;
        }
        for (size_t q = 0; q + sizeof LEFT_HALF_BLOCK <= p; q++) {
            if (memcmp(f->text + q, LEFT_HALF_BLOCK, sizeof LEFT_HALF_BLOCK) == 0) {
                return 1;
            }
        }
        return 0;
    }
    return 0;
}

static void remove_recognised(qc_filter *f, size_t recognised, size_t total)
{
    emit(f, QC_EV_REMOVED, f->held, recognised);
    emit(f, QC_EV_OUTPUT, f->held + recognised, total - recognised);
    stop_holding(f);
    disarm(f, QC_WATCH_REMOVED, "banner removed");
}

static void process_byte(qc_filter *f, uint8_t b, uint64_t now_ms);

static void hold_byte(qc_filter *f, uint8_t b, uint64_t now_ms)
{
    f->held[f->held_len++] = b;
    f->last_held_ms = now_ms;

    int result = scan_byte(f, b);
    if (result == SCAN_FAIL) {
        size_t before = f->held_len - 1;
        if (f->line_no == 1) {
            release_unchanged(f, before);
        } else {
            remove_recognised(f, f->recognised_end, before);
        }
        process_byte(f, b, now_ms);
        return;
    }
    if (result == SCAN_LINE_DONE) {
        if (f->line_no == 1 && !line1_is_key(f)) {
            release_unchanged(f, f->held_len);
            return;
        }
        f->recognised_end = f->held_len;
        if (f->line_no == 3) {
            remove_recognised(f, f->held_len, f->held_len);
            return;
        }
        begin_line(f, f->line_no + 1);
        return;
    }
    if (f->held_len > QC_HOLD_LIMIT) {
        release_unchanged(f, f->held_len);
    }
}

static void process_byte(qc_filter *f, uint8_t b, uint64_t now_ms)
{
    if (f->holding) {
        hold_byte(f, b, now_ms);
    } else if (f->watch == QC_WATCH_ARMED && b == 0x1b) {
        begin_candidate(f, now_ms);
        hold_byte(f, b, now_ms);
    } else {
        emit(f, QC_EV_OUTPUT, &b, 1);
    }
}

void qc_filter_init(qc_filter *f, qc_event_fn emit_fn, void *ctx, uint64_t now_ms)
{
    memset(f, 0, sizeof *f);
    f->emit = emit_fn;
    f->ctx = ctx;
    f->watch = QC_WATCH_ARMED;
    f->armed_at_ms = now_ms;
}

void qc_filter_tick(qc_filter *f, uint64_t now_ms)
{
    if (f->holding && now_ms - f->last_held_ms >= QC_HOLD_TIMEOUT_MS) {
        release_unchanged(f, f->held_len);
    }
    if (!f->holding && f->watch == QC_WATCH_ARMED && now_ms - f->armed_at_ms >= QC_ARM_WINDOW_MS) {
        disarm(f, QC_WATCH_TIMED_OUT, "timeout");
    }
}

void qc_filter_feed(qc_filter *f, const uint8_t *data, size_t len, uint64_t now_ms)
{
    qc_filter_tick(f, now_ms);

    size_t run_start = 0;
    for (size_t i = 0; i < len; i++) {
        if (!f->holding && !(f->watch == QC_WATCH_ARMED && data[i] == 0x1b)) {
            continue;
        }
        emit(f, QC_EV_OUTPUT, data + run_start, i - run_start);
        process_byte(f, data[i], now_ms);
        run_start = i + 1;
    }
    emit(f, QC_EV_OUTPUT, data + run_start, len - run_start);
}

void qc_filter_keystroke(qc_filter *f, uint64_t now_ms)
{
    if (f->watch != QC_WATCH_REMOVED) {
        f->watch = QC_WATCH_ARMED;
        f->armed_at_ms = now_ms;
    }
}

void qc_filter_resize(qc_filter *f, uint64_t now_ms)
{
    f->watch = QC_WATCH_ARMED;
    f->armed_at_ms = now_ms;
}

int qc_filter_wait_ms(const qc_filter *f, uint64_t now_ms)
{
    uint64_t elapsed;
    uint64_t limit;
    if (f->holding) {
        elapsed = now_ms - f->last_held_ms;
        limit = QC_HOLD_TIMEOUT_MS;
    } else if (f->watch == QC_WATCH_ARMED) {
        elapsed = now_ms - f->armed_at_ms;
        limit = QC_ARM_WINDOW_MS;
    } else {
        return -1;
    }
    return elapsed >= limit ? 0 : (int)(limit - elapsed);
}

void qc_filter_finish(qc_filter *f, uint64_t now_ms)
{
    (void)now_ms;
    if (f->holding) {
        release_unchanged(f, f->held_len);
    }
    if (f->watch == QC_WATCH_ARMED) {
        disarm(f, QC_WATCH_TIMED_OUT, "exit");
    }
}
