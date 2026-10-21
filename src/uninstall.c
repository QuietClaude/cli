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
#include <sys/wait.h>
#include <unistd.h>

#define QC_EXIT_FAIL 1
#define QC_EXIT_USAGE 2

typedef struct {
    int dry_run;
    int purge;
    int yes;
} uninstall_options;

static int exists(const char *path)
{
    struct stat st;
    return lstat(path, &st) == 0;
}

static char *dir_of(const char *path)
{
    const char *slash = strrchr(path, '/');
    if (slash == NULL) {
        return qc_xstrdup(".");
    }
    if (slash == path) {
        return qc_xstrdup("/");
    }
    size_t len = (size_t)(slash - path);
    char *dir = qc_xmalloc(len + 1);
    memcpy(dir, path, len);
    dir[len] = '\0';
    return dir;
}

/* True when path is a symlink that resolves to target. */
static int is_link_to(const char *path, const char *target)
{
    struct stat st;
    if (lstat(path, &st) != 0 || !S_ISLNK(st.st_mode)) {
        return 0;
    }
    char *resolved = realpath(path, NULL);
    if (resolved == NULL) {
        return 0;
    }
    int same = strcmp(resolved, target) == 0;
    free(resolved);
    return same;
}

/* True when both paths name the same directory entry, however they are spelled. */
static int same_entry(const char *a, const char *b)
{
    struct stat sa;
    struct stat sb;
    return lstat(a, &sa) == 0 && lstat(b, &sb) == 0 && sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino;
}

/* The path a bare command name refers to, as the shell would find it; NULL when not found. */
static char *find_in_path(const char *name)
{
    if (strchr(name, '/') != NULL) {
        return qc_xstrdup(name);
    }
    const char *path_env = getenv("PATH");
    if (path_env == NULL) {
        return NULL;
    }
    char *copy = qc_xstrdup(path_env);
    char *found = NULL;
    char *cursor = copy;
    while (found == NULL && cursor != NULL) {
        char *colon = strchr(cursor, ':');
        if (colon != NULL) {
            *colon = '\0';
        }
        char *candidate = qc_join_path(cursor[0] != '\0' ? cursor : ".", name);
        if (exists(candidate)) {
            found = candidate;
        } else {
            free(candidate);
        }
        cursor = colon != NULL ? colon + 1 : NULL;
    }
    free(copy);
    return found;
}

/* True when the file is small enough to be this launcher and contains a name only the launcher has. */
static int looks_like_launcher(const char *path)
{
    struct stat st;
    if (stat(path, &st) != 0 || !S_ISREG(st.st_mode) || st.st_size <= 0 || st.st_size > (16 << 20)) {
        return 0;
    }
    FILE *file = fopen(path, "rb");
    if (file == NULL) {
        return 0;
    }
    size_t size = (size_t)st.st_size;
    char *data = qc_xmalloc(size);
    size_t got = fread(data, 1, size, file);
    fclose(file);
    int found = got == size && memmem(data, size, "QUIETCLAUDE_CLAUDE_PATH", strlen("QUIETCLAUDE_CLAUDE_PATH")) != NULL;
    free(data);
    return found;
}

/* The home folder of a local user, read from /etc/passwd. getpwnam is avoided because a static
 * build cannot use it without the shared libraries it was linked against. */
static char *home_from_passwd(const char *user)
{
    if (user[0] == '\0' || strpbrk(user, ":/\n") != NULL) {
        return NULL;
    }
    FILE *file = fopen("/etc/passwd", "r");
    char *home = NULL;
    if (file != NULL) {
        char line[1024];
        size_t user_len = strlen(user);
        while (home == NULL && fgets(line, sizeof line, file) != NULL) {
            if (strncmp(line, user, user_len) != 0 || line[user_len] != ':') {
                continue;
            }
            char *fields = line + user_len + 1;
            for (int skip = 0; skip < 4 && fields != NULL; skip++) {
                fields = strchr(fields, ':');
                if (fields != NULL) {
                    fields++;
                }
            }
            if (fields != NULL) {
                char *end = strpbrk(fields, ":\n");
                if (end != NULL) {
                    *end = '\0';
                }
                if (fields[0] == '/') {
                    home = qc_xstrdup(fields);
                }
            }
        }
        fclose(file);
    }
#ifdef __APPLE__
    if (home == NULL) {
        char *guess = qc_join_path("/Users", user);
        struct stat st;
        if (stat(guess, &st) == 0 && S_ISDIR(st.st_mode)) {
            home = guess;
        } else {
            free(guess);
        }
    }
#endif
    return home;
}

/* The home folder of the person who ran the command, also when they used sudo. */
static char *invoking_home(void)
{
    const char *sudo_user = getenv("SUDO_USER");
    if (geteuid() == 0 && sudo_user != NULL && sudo_user[0] != '\0') {
        return home_from_passwd(sudo_user);
    }
    const char *home = getenv("HOME");
    if (home == NULL || home[0] != '/') {
        return NULL;
    }
    return qc_xstrdup(home);
}

static int confirm_purge(const char *folder)
{
    FILE *tty = fopen("/dev/tty", "r+");
    if (tty == NULL) {
        return -1;
    }
    fprintf(tty, "This deletes %s: your Pro licence, profiles (with their Claude logins) and sync files.\n"
                 "Type yes to continue: ",
            folder);
    fflush(tty);
    char answer[16];
    int yes = fgets(answer, sizeof answer, tty) != NULL && strcmp(answer, "yes\n") == 0;
    fclose(tty);
    return yes;
}

static int remove_tree(const char *path)
{
    pid_t pid = fork();
    if (pid < 0) {
        return 0;
    }
    if (pid == 0) {
        execl("/bin/rm", "rm", "-rf", "--", path, (char *)NULL);
        _exit(127);
    }
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        return 0;
    }
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

static int remove_file(const char *path, int *failures)
{
    if (unlink(path) != 0) {
        fprintf(stderr, "quietclaude: cannot remove %s: %s\n", path, strerror(errno));
        (*failures)++;
        return 0;
    }
    printf("Removed %s\n", path);
    return 1;
}

static int parse_options(int argc, char **argv, uninstall_options *options)
{
    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--dry-run") == 0) {
            options->dry_run = 1;
        } else if (strcmp(argv[i], "--purge") == 0) {
            options->purge = 1;
        } else if (strcmp(argv[i], "--yes") == 0) {
            options->yes = 1;
        } else {
            fprintf(stderr, "quietclaude: usage: qc uninstall [--dry-run] [--purge [--yes]]\n");
            return -1;
        }
    }
    if (options->yes && !options->purge) {
        fprintf(stderr, "quietclaude: --yes goes with --purge. Usage: qc uninstall [--dry-run] [--purge [--yes]]\n");
        return -1;
    }
    return 0;
}

int qc_uninstall(int argc, char **argv)
{
    uninstall_options options = { 0, 0, 0 };
    if (parse_options(argc, argv, &options) != 0) {
        return QC_EXIT_USAGE;
    }

    char *self = qc_launcher_path(argv[0]);
    if (self == NULL) {
        fprintf(stderr, "quietclaude: cannot find where this launcher is installed.\n");
        return QC_EXIT_FAIL;
    }

    /* Only ever unlink the program that was started. If /proc is missing the path can come from the
     * current folder, so it must match what the command name resolves to and look like the launcher. */
    char *invoked = find_in_path(argv[0]);
    char *invoked_real = invoked != NULL ? realpath(invoked, NULL) : NULL;
    int genuine = invoked_real != NULL && strcmp(invoked_real, self) == 0 && looks_like_launcher(self);
    free(invoked_real);
    if (!genuine) {
        fprintf(stderr, "quietclaude: %s is not the program that was started, so nothing was removed.\n", self);
        free(invoked);
        free(self);
        return QC_EXIT_FAIL;
    }
    char *folder = dir_of(self);

    /* Links to remove: the qc link next to the launcher, and the one this command was run through. */
    char *links[2] = { NULL, NULL };
    char *beside = qc_join_path(folder, "qc");
    if (is_link_to(beside, self)) {
        links[0] = beside;
    } else {
        free(beside);
    }
    if (invoked != NULL && is_link_to(invoked, self) && (links[0] == NULL || !same_entry(invoked, links[0]))) {
        links[1] = invoked;
    } else {
        free(invoked);
    }

    char *home = invoking_home();
    char *pro_dir = home != NULL ? qc_join_path(home, ".quietclaude") : NULL;
    char *pro_binary = pro_dir != NULL ? qc_join_path(pro_dir, "pro") : NULL;
    int has_pro_binary = pro_binary != NULL && exists(pro_binary);
    struct stat dir_stat;
    int pro_dir_present = pro_dir != NULL && lstat(pro_dir, &dir_stat) == 0;
    int has_pro_dir = pro_dir_present && S_ISDIR(dir_stat.st_mode);

    int result = 0;
    int failures = 0;
    if (home == NULL) {
        printf("Could not find your home folder, so Pro files were not checked.\n");
    }
    if (options.purge && !has_pro_dir) {
        if (home == NULL) {
            printf("--purge was skipped: your home folder could not be found.\n");
        } else if (pro_dir_present) {
            printf("%s is a link, so --purge leaves it alone.\n", pro_dir);
        } else {
            printf("Nothing to purge: no %s folder.\n", pro_dir);
        }
        options.purge = 0;
    }

    if (options.dry_run) {
        for (int i = 0; i < 2; i++) {
            if (links[i] != NULL) {
                printf("Would remove %s\n", links[i]);
            }
        }
        if (options.purge) {
            printf("Would delete the folder %s\n", pro_dir);
        } else if (has_pro_binary) {
            printf("Would remove %s\n", pro_binary);
        }
        printf("Would remove %s\n", self);
        printf("Dry run: nothing was changed.\n");
        goto done;
    }

    for (int i = 0; i < 3; i++) {
        char *check = i == 0 ? qc_xstrdup(folder) : (links[i - 1] != NULL ? dir_of(links[i - 1]) : NULL);
        if (check != NULL && access(check, W_OK) != 0) {
            fprintf(stderr, "quietclaude: %s is not writable. Run: sudo qc uninstall%s%s\n", check,
                    options.purge ? " --purge" : "", options.yes ? " --yes" : "");
            free(check);
            result = QC_EXIT_FAIL;
            goto done;
        }
        free(check);
    }

    if (options.purge && !options.yes) {
        int answer = confirm_purge(pro_dir);
        if (answer < 0) {
            fprintf(stderr, "quietclaude: --purge needs a terminal to ask you first. Add --yes to skip the question.\n");
            result = QC_EXIT_FAIL;
            goto done;
        }
        if (answer == 0) {
            fprintf(stderr, "quietclaude: nothing was deleted.\n");
            result = QC_EXIT_FAIL;
            goto done;
        }
    }

    if (options.purge) {
        if (remove_tree(pro_dir)) {
            printf("Deleted the folder %s\n", pro_dir);
            pro_dir_present = 0;
        } else {
            fprintf(stderr, "quietclaude: could not delete %s\n", pro_dir);
            failures++;
        }
    } else if (has_pro_binary) {
        remove_file(pro_binary, &failures);
    }
    for (int i = 0; i < 2; i++) {
        if (links[i] != NULL) {
            remove_file(links[i], &failures);
        }
    }
    remove_file(self, &failures);

    printf("The name claude goes back to Claude Code. Run 'hash -r' or open a new terminal.\n");
    printf("If you added an alias for claude to your shell profile, remove that line too.\n");
    if (pro_dir_present) {
        printf("Left alone: %s (QuietClaude Pro: licence, profiles and sync files).\n", pro_dir);
        printf("Delete it yourself if you no longer want it: rm -rf %s\n", pro_dir);
    }
    result = failures > 0 ? QC_EXIT_FAIL : 0;

done:
    free(self);
    free(folder);
    free(links[0]);
    free(links[1]);
    free(home);
    free(pro_dir);
    free(pro_binary);
    return result;
}
