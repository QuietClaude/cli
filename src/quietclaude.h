#ifndef QUIETCLAUDE_H
#define QUIETCLAUDE_H

#define QUIETCLAUDE_VERSION "0.2.0"
#define QUIETCLAUDE_PRO_URL "https://github.com/QuietClaude/cli#pro"
#define QUIETCLAUDE_INSTALL_LINE "curl -fsSL https://raw.githubusercontent.com/QuietClaude/cli/main/install.sh | sh"

void qc_report_error(const char *what);

int qc_terminal_run(const char *claude_path, char *const argv[], int debug);

#endif
