#ifdef __linux__
#define _GNU_SOURCE
#endif
#include "quietclaude.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int print_version(const char *argv0, const char *version_arg)
{
    char *self = qc_launcher_path(argv0);
    int status = 0;
    char *claude = qc_find_claude(self, &status);
    if (claude == NULL && status != 0) {
        return status;
    }
    printf("QuietClaude %s\n", QUIETCLAUDE_VERSION);
    printf("  %-14s%s\n", "launcher:", self != NULL ? self : argv0);
    printf("  %-14s%s\n", "claude code:", claude != NULL ? claude : "not found");
    if (fflush(stdout) != 0) {
        qc_report_error("write stdout");
        return 1;
    }
    if (claude == NULL) {
        return 0;
    }
    char *child_argv[3] = { claude, (char *)version_arg, NULL };
    return qc_exec_claude(claude, child_argv);
}

static const char *base_name(const char *path)
{
    const char *slash = strrchr(path, '/');
    return slash != NULL ? slash + 1 : path;
}

static int is_pro_word(const char *word)
{
    static const char *const words[] = { "pro", "profile", "header", "sync", "--profile" };
    if (word[0] == '@') {
        return 1;
    }
    for (size_t i = 0; i < sizeof words / sizeof words[0]; i++) {
        if (strcmp(word, words[i]) == 0) {
            return 1;
        }
    }
    return 0;
}

static void print_update_nudge(void)
{
    fprintf(stderr, "quietclaude: the free launcher does not update itself.\n"
                    "Updating is part of QuietClaude Pro. See %s\n"
                    "To update the free launcher, run the install command again: %s\n",
            QUIETCLAUDE_PRO_URL, QUIETCLAUDE_INSTALL_LINE);
}

static void print_pro_nudge(const char *word)
{
    fprintf(stderr, "quietclaude: '%s' is part of QuietClaude Pro. See %s\n"
                    "To update the free launcher, run the install command again: %s\n",
            word, QUIETCLAUDE_PRO_URL, QUIETCLAUDE_INSTALL_LINE);
}

static int run_pro(char **argv)
{
    char *pro = NULL;
    const char *forced = getenv("QUIETCLAUDE_PRO_PATH");
    if (forced != NULL && forced[0] != '\0') {
        pro = qc_xstrdup(forced);
    } else {
        const char *home = getenv("HOME");
        if (home != NULL && home[0] != '\0') {
            pro = qc_join_path(home, ".quietclaude/pro");
        }
    }
    if (pro == NULL || !qc_is_executable_file(pro)) {
        print_pro_nudge(argv[1]);
        return 2;
    }
    if (setenv("QUIETCLAUDE_CORE_VERSION", QUIETCLAUDE_VERSION, 1) != 0) {
        qc_report_error("setenv");
        return 1;
    }
    return qc_exec_claude(pro, argv);
}

int main(int argc, char **argv)
{
    const char *argv0 = argc > 0 ? argv[0] : "claude";

    if (argc >= 2) {
        if (strcmp(base_name(argv0), "qc") == 0 && strcmp(argv[1], "update") == 0) {
            print_update_nudge();
            return 2;
        }
        if (is_pro_word(argv[1])) {
            return run_pro(argv);
        }
    }

    if (argc == 2 && (strcmp(argv[1], "--version") == 0 || strcmp(argv[1], "-v") == 0)) {
        return print_version(argv0, argv[1]);
    }

    qc_launch_options options = { NULL, NULL, NULL, NULL, 0, NULL };
    return qc_launch(&options, argc, argv);
}
