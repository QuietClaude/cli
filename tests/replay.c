#include "../src/quietclaude.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int write_stdout(void *io, const uint8_t *data, size_t len)
{
    FILE *out = io;
    if (fwrite(data, 1, len, out) != len) {
        perror("replay: write");
        exit(2);
    }
    return 0;
}

static char fn_header[32];

static const char *header_from_length(void *ctx, const uint8_t *data, size_t len)
{
    (void)ctx;
    (void)data;
    snprintf(fn_header, sizeof fn_header, "fn:%zu", len);
    return fn_header;
}

static long parse_long(const char *text, const char *what)
{
    char *end = NULL;
    errno = 0;
    long value = strtol(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || value < 0) {
        fprintf(stderr, "replay: bad %s: %s\n", what, text);
        exit(2);
    }
    return value;
}

int main(int argc, char **argv)
{
    long chunk = 0;
    long key_after = -1;
    long resize_after = -1;
    long event_time = 5000;
    long after_time = -1;
    const char *path = NULL;
    const char *header = NULL;
    int use_header_fn = 0;
    int debug = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--chunk") == 0 && i + 1 < argc) {
            chunk = parse_long(argv[++i], "chunk");
        } else if (strcmp(argv[i], "--key-after") == 0 && i + 1 < argc) {
            key_after = parse_long(argv[++i], "key-after");
        } else if (strcmp(argv[i], "--resize-after") == 0 && i + 1 < argc) {
            resize_after = parse_long(argv[++i], "resize-after");
        } else if (strcmp(argv[i], "--event-time") == 0 && i + 1 < argc) {
            event_time = parse_long(argv[++i], "event-time");
        } else if (strcmp(argv[i], "--after-time") == 0 && i + 1 < argc) {
            after_time = parse_long(argv[++i], "after-time");
        } else if (strcmp(argv[i], "--header") == 0 && i + 1 < argc) {
            header = argv[++i];
        } else if (strcmp(argv[i], "--debug") == 0) {
            debug = 1;
        } else if (strcmp(argv[i], "--header-fn") == 0) {
            use_header_fn = 1;
        } else if (path == NULL && argv[i][0] != '-') {
            path = argv[i];
        } else {
            fprintf(stderr, "replay: unexpected argument: %s\n", argv[i]);
            return 2;
        }
    }
    if (path == NULL) {
        fprintf(stderr, "usage: replay [--chunk N] [--key-after BYTE] [--resize-after BYTE] [--header TEXT] [--header-fn] [--debug] FIXTURE\n");
        return 2;
    }
    if (after_time < 0) {
        after_time = event_time + 100;
    }

    FILE *in = fopen(path, "rb");
    if (in == NULL) {
        fprintf(stderr, "replay: %s: %s\n", path, strerror(errno));
        return 2;
    }
    uint8_t *data = NULL;
    size_t len = 0;
    size_t cap = 0;
    for (;;) {
        if (len == cap) {
            cap = cap ? cap * 2 : 4096;
            data = realloc(data, cap);
            if (data == NULL) {
                perror("replay: realloc");
                return 2;
            }
        }
        size_t got = fread(data + len, 1, cap - len, in);
        if (got == 0) {
            break;
        }
        len += got;
    }
    if (ferror(in)) {
        perror("replay: read");
        return 2;
    }
    fclose(in);

    long event_after = key_after >= 0 ? key_after : resize_after;
    size_t boundary = event_after >= 0 && (size_t)event_after < len ? (size_t)event_after + 1 : len;
    size_t step = chunk > 0 ? (size_t)chunk : len;
    if (step == 0) {
        step = 1;
    }

    qc_launch_options options = { NULL, header, NULL, NULL, debug, use_header_fn ? header_from_length : NULL };
    qc_bridge_sink sink = { write_stdout, stdout, &options, debug, 0, 0, 0 };
    qc_filter filter;
    qc_filter_init(&filter, qc_bridge_event, &sink, 0);

    uint64_t now = 0;
    size_t pos = 0;
    while (pos < len) {
        if (pos == boundary && event_after >= 0) {
            if (key_after >= 0) {
                qc_filter_keystroke(&filter, (uint64_t)event_time);
            } else {
                qc_filter_resize(&filter, (uint64_t)event_time);
            }
            now = (uint64_t)after_time;
        }
        size_t n = step;
        if (pos < boundary && pos + n > boundary) {
            n = boundary - pos;
        }
        if (pos + n > len) {
            n = len - pos;
        }
        qc_filter_feed(&filter, data + pos, n, now);
        pos += n;
    }
    qc_filter_finish(&filter, now);
    free(data);
    if (fflush(stdout) != 0) {
        perror("replay: flush");
        return 2;
    }
    return 0;
}
