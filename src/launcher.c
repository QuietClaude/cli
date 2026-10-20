#ifdef __linux__
#define _GNU_SOURCE
#endif
#include "quietclaude.h"

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#ifdef __APPLE__
#include <mach-o/dyld.h>
#endif

#ifndef PATH_MAX
#define PATH_MAX 4096
#endif

void qc_report_error(const char *what)
{
    fprintf(stderr, "quietclaude: %s: %s\n", what, strerror(errno));
}

static void *xmalloc(size_t size)
{
    void *p = malloc(size);
    if (p == NULL) {
        qc_report_error("malloc");
        exit(1);
    }
    return p;
}

static char *xstrdup(const char *s)
{
    size_t len = strlen(s) + 1;
    char *copy = xmalloc(len);
    memcpy(copy, s, len);
    return copy;
}

static char *join_path(const char *dir, const char *name)
{
    size_t dir_len = strlen(dir);
    size_t name_len = strlen(name);
    char *out = xmalloc(dir_len + 1 + name_len + 1);
    memcpy(out, dir, dir_len);
    out[dir_len] = '/';
    memcpy(out + dir_len + 1, name, name_len + 1);
    return out;
}

static char *launcher_path(const char *argv0)
{
    char *resolved = NULL;
#ifdef __APPLE__
    char raw[PATH_MAX];
    uint32_t size = sizeof raw;
    if (_NSGetExecutablePath(raw, &size) == 0) {
        resolved = realpath(raw, NULL);
    }
#else
    resolved = realpath("/proc/self/exe", NULL);
#endif
    if (resolved == NULL && argv0 != NULL) {
        resolved = realpath(argv0, NULL);
    }
    return resolved;
}

static int is_executable_file(const char *path)
{
    struct stat st;
    if (stat(path, &st) != 0 || !S_ISREG(st.st_mode)) {
        return 0;
    }
    return access(path, X_OK) == 0;
}

static int is_launcher(const char *path, const char *self)
{
    if (self == NULL) {
        return 0;
    }
    char *resolved = realpath(path, NULL);
    if (resolved == NULL) {
        return 0;
    }
    int same = strcmp(resolved, self) == 0;
    free(resolved);
    return same;
}

static char *find_claude(const char *self)
{
    const char *forced = getenv("QUIETCLAUDE_CLAUDE_PATH");
    if (forced != NULL && forced[0] != '\0') {
        if (!is_executable_file(forced)) {
            fprintf(stderr, "quietclaude: QUIETCLAUDE_CLAUDE_PATH is set but is not an executable file: %s\n", forced);
            exit(127);
        }
        return xstrdup(forced);
    }

    const char *home = getenv("HOME");
    if (home != NULL && home[0] != '\0') {
        char *candidate = join_path(home, ".local/bin/claude");
        if (is_executable_file(candidate) && !is_launcher(candidate, self)) {
            return candidate;
        }
        free(candidate);
        candidate = join_path(home, ".local/bin/claude.real");
        if (is_executable_file(candidate)) {
            return candidate;
        }
        free(candidate);
    }

    const char *path = getenv("PATH");
    if (path == NULL) {
        return NULL;
    }
    char *dirs = xstrdup(path);
    char *cursor = dirs;
    char *found = NULL;
    while (cursor != NULL && found == NULL) {
        char *dir = cursor;
        char *colon = strchr(cursor, ':');
        if (colon != NULL) {
            *colon = '\0';
            cursor = colon + 1;
        } else {
            cursor = NULL;
        }
        char *candidate = join_path(dir[0] == '\0' ? "." : dir, "claude");
        if (is_executable_file(candidate) && !is_launcher(candidate, self)) {
            found = candidate;
        } else {
            free(candidate);
        }
    }
    free(dirs);
    return found;
}

static void exec_claude(const char *claude, char *const argv[])
{
    execv(claude, argv);
    char what[PATH_MAX + 8];
    snprintf(what, sizeof what, "exec %s", claude);
    qc_report_error(what);
    exit(1);
}

static int print_version(const char *self, const char *argv0, const char *version_arg)
{
    char *claude = find_claude(self);
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
    exec_claude(claude, child_argv);
    return 1;
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
        pro = xstrdup(forced);
    } else {
        const char *home = getenv("HOME");
        if (home != NULL && home[0] != '\0') {
            pro = join_path(home, ".quietclaude/pro");
        }
    }
    if (pro == NULL || !is_executable_file(pro)) {
        print_pro_nudge(argv[1]);
        return 2;
    }
    if (setenv("QUIETCLAUDE_CORE_VERSION", QUIETCLAUDE_VERSION, 1) != 0) {
        qc_report_error("setenv");
        return 1;
    }
    exec_claude(pro, argv);
    return 1;
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

    char *self = launcher_path(argc > 0 ? argv[0] : NULL);

    if (argc == 2 && (strcmp(argv[1], "--version") == 0 || strcmp(argv[1], "-v") == 0)) {
        return print_version(self, argv0, argv[1]);
    }

    char *claude = find_claude(self);
    if (claude == NULL) {
        fprintf(stderr, "quietclaude: Claude Code executable not found.\n"
                        "Install Claude Code, or point QUIETCLAUDE_CLAUDE_PATH at it:\n"
                        "  QUIETCLAUDE_CLAUDE_PATH=/path/to/claude claude\n");
        return 127;
    }
    free(self);

    if (setenv("CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN", "1", 1) != 0 ||
        setenv("CLAUDE_CODE_DISABLE_MOUSE_CLICKS", "1", 1) != 0) {
        qc_report_error("setenv");
        return 1;
    }

    char **child_argv = xmalloc(sizeof(char *) * ((size_t)argc + 1));
    child_argv[0] = claude;
    for (int i = 1; i < argc; i++) {
        child_argv[i] = argv[i];
    }
    child_argv[argc] = NULL;

    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)) {
        exec_claude(claude, child_argv);
    }

    const char *debug_env = getenv("QUIETCLAUDE_DEBUG");
    int debug = debug_env != NULL && debug_env[0] != '\0' && strcmp(debug_env, "0") != 0;
    return qc_terminal_run(claude, child_argv, debug);
}
