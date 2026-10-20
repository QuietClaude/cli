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

void *qc_xmalloc(size_t size)
{
    void *p = malloc(size);
    if (p == NULL) {
        qc_report_error("malloc");
        exit(1);
    }
    return p;
}

char *qc_xstrdup(const char *s)
{
    size_t len = strlen(s) + 1;
    char *copy = qc_xmalloc(len);
    memcpy(copy, s, len);
    return copy;
}

char *qc_join_path(const char *dir, const char *name)
{
    size_t dir_len = strlen(dir);
    size_t name_len = strlen(name);
    char *out = qc_xmalloc(dir_len + 1 + name_len + 1);
    memcpy(out, dir, dir_len);
    out[dir_len] = '/';
    memcpy(out + dir_len + 1, name, name_len + 1);
    return out;
}

char *qc_launcher_path(const char *argv0)
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

int qc_is_executable_file(const char *path)
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

char *qc_find_claude(const char *self, int *status)
{
    *status = 0;
    const char *forced = getenv("QUIETCLAUDE_CLAUDE_PATH");
    if (forced != NULL && forced[0] != '\0') {
        if (!qc_is_executable_file(forced)) {
            fprintf(stderr, "quietclaude: QUIETCLAUDE_CLAUDE_PATH is set but is not an executable file: %s\n", forced);
            *status = 127;
            return NULL;
        }
        return qc_xstrdup(forced);
    }

    const char *home = getenv("HOME");
    if (home != NULL && home[0] != '\0') {
        char *candidate = qc_join_path(home, ".local/bin/claude");
        if (qc_is_executable_file(candidate) && !is_launcher(candidate, self)) {
            return candidate;
        }
        free(candidate);
        candidate = qc_join_path(home, ".local/bin/claude.real");
        if (qc_is_executable_file(candidate)) {
            return candidate;
        }
        free(candidate);
    }

    const char *path = getenv("PATH");
    if (path == NULL) {
        return NULL;
    }
    char *dirs = qc_xstrdup(path);
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
        char *candidate = qc_join_path(dir[0] == '\0' ? "." : dir, "claude");
        if (qc_is_executable_file(candidate) && !is_launcher(candidate, self)) {
            found = candidate;
        } else {
            free(candidate);
        }
    }
    free(dirs);
    return found;
}

int qc_exec_claude(const char *claude, char *const argv[])
{
    execv(claude, argv);
    char what[PATH_MAX + 8];
    snprintf(what, sizeof what, "exec %s", claude);
    qc_report_error(what);
    return 1;
}

const char *qc_core_version(void)
{
    return QUIETCLAUDE_VERSION;
}

int qc_launch(const qc_launch_options *options, int argc, char **argv)
{
    static const qc_launch_options defaults = { NULL, NULL, NULL, NULL, 0 };
    if (options == NULL) {
        options = &defaults;
    }

    char *claude;
    if (options->claude_path != NULL) {
        claude = qc_xstrdup(options->claude_path);
    } else {
        char *self = qc_launcher_path(NULL);
        int status = 0;
        claude = qc_find_claude(self, &status);
        free(self);
        if (claude == NULL) {
            if (status != 0) {
                return status;
            }
            fprintf(stderr, "quietclaude: Claude Code executable not found.\n"
                            "Install Claude Code, or point QUIETCLAUDE_CLAUDE_PATH at it:\n"
                            "  QUIETCLAUDE_CLAUDE_PATH=/path/to/claude claude\n");
            return 127;
        }
    }

    if (setenv("CLAUDE_CODE_DISABLE_ALTERNATE_SCREEN", "1", 1) != 0 ||
        setenv("CLAUDE_CODE_DISABLE_MOUSE_CLICKS", "1", 1) != 0) {
        qc_report_error("setenv");
        free(claude);
        return 1;
    }

    size_t count = argc > 0 ? (size_t)argc : 1;
    char **child_argv = qc_xmalloc(sizeof(char *) * (count + 1));
    child_argv[0] = claude;
    for (size_t i = 1; i < count; i++) {
        child_argv[i] = argv[i];
    }
    child_argv[count] = NULL;

    int result;
    if (!isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO)) {
        result = qc_exec_claude(claude, child_argv);
    } else {
        const char *debug_env = getenv("QUIETCLAUDE_DEBUG");
        int debug = options->debug != 0 ||
                    (debug_env != NULL && debug_env[0] != '\0' && strcmp(debug_env, "0") != 0);
        result = qc_terminal_run(claude, child_argv, options, debug);
    }
    free(child_argv);
    free(claude);
    return result;
}
