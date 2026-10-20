#ifndef QUIETCLAUDE_H
#define QUIETCLAUDE_H

#define QUIETCLAUDE_VERSION "0.1.0"

void qc_report_error(const char *what);

int qc_terminal_run(const char *claude_path, char *const argv[], int debug);

#endif
