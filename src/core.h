#ifndef QUIETCLAUDE_CORE_H
#define QUIETCLAUDE_CORE_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    const char *claude_path;
    const char *header;
    void (*on_banner_removed)(void *ctx, const uint8_t *data, size_t len);
    void *ctx;
    int debug;
    const char *(*header_fn)(void *ctx, const uint8_t *data, size_t len);
} qc_launch_options;

int qc_launch(const qc_launch_options *options, int argc, char **argv);

const char *qc_core_version(void);

#endif
