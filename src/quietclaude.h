#ifndef QUIETCLAUDE_H
#define QUIETCLAUDE_H

#include <stddef.h>
#include <stdint.h>

#include "banner.h"
#include "core.h"

#define QUIETCLAUDE_VERSION "0.3.1"
#define QUIETCLAUDE_PRO_URL "https://github.com/QuietClaude/cli#pro"
#define QUIETCLAUDE_INSTALL_LINE "curl -fsSL https://quietclaude.com/install.sh | sh"

void qc_report_error(const char *what);
void *qc_xmalloc(size_t size);
char *qc_xstrdup(const char *s);
char *qc_join_path(const char *dir, const char *name);
char *qc_launcher_path(const char *argv0);
int qc_is_executable_file(const char *path);
char *qc_find_claude(const char *self, int *status);
int qc_exec_claude(const char *claude, char *const argv[]);
int qc_uninstall(int argc, char **argv);

typedef struct {
    int (*write)(void *io, const uint8_t *data, size_t len);
    void *io;
    const qc_launch_options *options;
    int debug;
    int stderr_is_tty;
    int header_written;
    int output_errno;
} qc_bridge_sink;

void qc_bridge_event(void *sink, qc_event_kind kind, const uint8_t *data, size_t len);

int qc_terminal_run(const char *claude_path, char *const argv[], const qc_launch_options *options, int debug);

#endif
