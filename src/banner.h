#ifndef QUIETCLAUDE_BANNER_H
#define QUIETCLAUDE_BANNER_H

#include <stddef.h>
#include <stdint.h>

#define QC_HOLD_LIMIT 4096u
#define QC_HOLD_TIMEOUT_MS 200u
#define QC_ARM_WINDOW_MS 4000u

typedef enum {
    QC_EV_OUTPUT,
    QC_EV_REMOVED,
    QC_EV_DISARMED
} qc_event_kind;

typedef void (*qc_event_fn)(void *ctx, qc_event_kind kind, const uint8_t *data, size_t len);

typedef enum {
    QC_WATCH_ARMED,
    QC_WATCH_TIMED_OUT,
    QC_WATCH_REMOVED
} qc_watch_state;

typedef struct {
    qc_event_fn emit;
    void *ctx;

    qc_watch_state watch;
    uint64_t armed_at_ms;
    uint64_t last_held_ms;

    uint8_t held[QC_HOLD_LIMIT + 1];
    size_t held_len;
    int holding;

    int line_no;
    int scan;
    size_t start_index;
    int start_digits;
    size_t line_begin;
    size_t recognised_end;
    uint8_t text[256];
    size_t text_len;
    int text_overflow;
} qc_filter;

void qc_filter_init(qc_filter *f, qc_event_fn emit, void *ctx, uint64_t now_ms);

void qc_filter_feed(qc_filter *f, const uint8_t *data, size_t len, uint64_t now_ms);

void qc_filter_keystroke(qc_filter *f, uint64_t now_ms);

void qc_filter_resize(qc_filter *f, uint64_t now_ms);

void qc_filter_tick(qc_filter *f, uint64_t now_ms);

int qc_filter_wait_ms(const qc_filter *f, uint64_t now_ms);

void qc_filter_finish(qc_filter *f, uint64_t now_ms);

#endif
