#ifdef __linux__
#define _GNU_SOURCE
#endif
#include "quietclaude.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <time.h>
#include <termios.h>
#include <unistd.h>

#define QC_EXIT_FAIL 1
#define QC_EXIT_USAGE 2
#define KEY_MIN 8
#define KEY_MAX 128

/* The three files of a release, and where they were put. Kept in globals so a signal can clean up. */
static char g_dir[PATH_MAX];
static char g_paths[3][PATH_MAX];
static char g_home_dir[PATH_MAX];
static int g_made_home = 0;
static int g_used_saved = 0;
static int g_prompt_fd = -1;
static struct termios g_prompt_saved;

static void clean_files(void)
{
    for (int i = 0; i < 3; i++) {
        if (g_paths[i][0] != '\0') {
            unlink(g_paths[i]);
        }
    }
    if (g_dir[0] != '\0') {
        rmdir(g_dir);
    }
    if (g_made_home && g_home_dir[0] != '\0') {
        rmdir(g_home_dir); /* only if it is still empty, so an installed Pro stays */
    }
}

static void on_signal(int sig)
{
    clean_files();
    signal(sig, SIG_DFL);
    raise(sig);
}

static void restore_prompt(int sig)
{
    tcsetattr(g_prompt_fd, TCSAFLUSH, &g_prompt_saved);
    signal(sig, SIG_DFL);
    raise(sig);
}

static void trim_line(char *s)
{
    size_t n = strlen(s);
    while (n > 0 && (s[n - 1] == '\n' || s[n - 1] == '\r' || s[n - 1] == ' ' || s[n - 1] == '\t')) {
        s[--n] = '\0';
    }
    size_t lead = strspn(s, " \t");
    if (lead > 0) {
        memmove(s, s + lead, strlen(s + lead) + 1);
    }
}

/* Overwrites a buffer in a way the compiler may not drop. */
static void wipe(void *p, size_t n)
{
    volatile unsigned char *v = p;
    while (n-- > 0) {
        *v++ = 0;
    }
}

/* A write to a pipe whose reader has gone must not kill qc with SIGPIPE. */
static int safe_write(int fd, const char *buf, size_t len)
{
    void (*old)(int) = signal(SIGPIPE, SIG_IGN);
    ssize_t w = write(fd, buf, len);
    signal(SIGPIPE, old);
    return w == (ssize_t)len ? 0 : -1;
}

static int wait_for(pid_t pid)
{
    int status = 0;
    pid_t r;
    do {
        r = waitpid(pid, &status, 0);
    } while (r < 0 && errno == EINTR);
    if (r != pid) {
        return -1;
    }
    return status;
}

/* Values that go inside the quotes of a curl config line may not carry anything that could end them. */
static int config_safe(const char *s)
{
    return strpbrk(s, "\"\\\n\r") == NULL;
}

static int read_key_line(FILE *in, char *out, size_t cap)
{
    out[0] = '\0';
    if (fgets(out, (int)cap, in) == NULL) {
        return -1;
    }
    trim_line(out);
    return out[0] != '\0' ? 0 : -1;
}

/* Same characters the release server accepts in a key. Nothing else ever reaches curl. */
static int key_ok(const char *key)
{
    size_t n = strlen(key);
    if (n < KEY_MIN || n > KEY_MAX) {
        return 0;
    }
    for (size_t i = 0; i < n; i++) {
        char c = key[i];
        int good = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' || c == '_'
                   || c == '~' || c == '+' || c == '/' || c == '=' || c == '-';
        if (!good) {
            return 0;
        }
    }
    return 1;
}

static int prompt_key(char *out, size_t cap)
{
    FILE *tty = fopen("/dev/tty", "r+");
    if (tty == NULL) {
        return -1;
    }
    int have_termios = tcgetattr(fileno(tty), &g_prompt_saved) == 0;
    struct sigaction old_int;
    struct sigaction old_term;
    struct sigaction old_hup;
    if (have_termios) {
        g_prompt_fd = fileno(tty);
        struct sigaction sa;
        memset(&sa, 0, sizeof sa);
        sa.sa_handler = restore_prompt;
        sigemptyset(&sa.sa_mask);
        sigaction(SIGINT, &sa, &old_int);
        sigaction(SIGTERM, &sa, &old_term);
        sigaction(SIGHUP, &sa, &old_hup);
        struct termios quiet = g_prompt_saved;
        quiet.c_lflag &= (tcflag_t)~ECHO;
        tcsetattr(g_prompt_fd, TCSAFLUSH, &quiet);
    }
    fputs("The licence key is on your Gumroad receipt. No key yet? https://quietclaude.com/pro\n", tty);
    fputs("Licence key: ", tty);
    fflush(tty);
    int rc = read_key_line(tty, out, cap);
    if (have_termios) {
        tcsetattr(g_prompt_fd, TCSAFLUSH, &g_prompt_saved);
        sigaction(SIGINT, &old_int, NULL);
        sigaction(SIGTERM, &old_term, NULL);
        sigaction(SIGHUP, &old_hup, NULL);
        g_prompt_fd = -1;
    }
    fputs("\n", tty);
    fclose(tty);
    return rc;
}

/* A key kept by an earlier install, so reinstalling does not ask again. */
static int saved_key(char *out, size_t cap)
{
    const char *home = getenv("HOME");
    if (home == NULL || home[0] != '/') {
        return -1;
    }
    char *path = qc_join_path(home, ".quietclaude/license");
    int fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW);
    free(path);
    if (fd < 0) {
        return -1;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode)) {
        close(fd);
        return -1;
    }
    FILE *f = fdopen(fd, "r");
    if (f == NULL) {
        close(fd);
        return -1;
    }
    int rc = read_key_line(f, out, cap);
    fclose(f);
    return rc == 0 && key_ok(out) ? 0 : -1;
}

static const char *asset_name(void)
{
    struct utsname u;
    if (uname(&u) != 0) {
        return NULL;
    }
    int linux_os = strcmp(u.sysname, "Linux") == 0;
    int mac = strcmp(u.sysname, "Darwin") == 0;
    int x86 = strcmp(u.machine, "x86_64") == 0;
    int arm = strcmp(u.machine, "aarch64") == 0 || strcmp(u.machine, "arm64") == 0;
    if (linux_os && x86) {
        return "quietclaude-pro-linux-x86_64";
    }
    if (linux_os && arm) {
        return "quietclaude-pro-linux-arm64";
    }
    if (mac && x86) {
        return "quietclaude-pro-darwin-x86_64";
    }
    if (mac && arm) {
        return "quietclaude-pro-darwin-arm64";
    }
    return NULL;
}

/* Downloads over https only. Plain http is for a local test server and nothing else. */
static const char *release_base(int *secure)
{
    const char *base = getenv("QUIETCLAUDE_PRO_BASE");
    if (base == NULL || base[0] == '\0') {
        *secure = 1;
        return "https://dl.quietclaude.com";
    }
    if (strncmp(base, "https://", 8) == 0) {
        *secure = 1;
        return base;
    }
    static const char *local[] = { "http://127.0.0.1", "http://localhost" };
    for (size_t i = 0; i < sizeof local / sizeof local[0]; i++) {
        size_t n = strlen(local[i]);
        if (strncmp(base, local[i], n) == 0 && (base[n] == '\0' || base[n] == ':' || base[n] == '/')) {
            *secure = 0;
            return base;
        }
    }
    return NULL;
}

/* Runs curl for one file. The key goes through curl's config on standard input, never its arguments,
 * so it cannot show in a process list. Returns the HTTP status, or -1 when curl itself failed. */
static int fetch(const char *url, const char *key, const char *out_path, int secure)
{
    if (!config_safe(url) || !config_safe(out_path)) {
        fprintf(stderr, "quietclaude: the download address or the temporary folder has a character that is not allowed.\n");
        return -2;
    }
    int to_curl[2];
    int from_curl[2];
    if (pipe(to_curl) != 0) {
        qc_report_error("pipe");
        return -1;
    }
    if (pipe(from_curl) != 0) {
        qc_report_error("pipe");
        close(to_curl[0]);
        close(to_curl[1]);
        return -1;
    }
    pid_t pid = fork();
    if (pid < 0) {
        qc_report_error("fork");
        close(to_curl[0]);
        close(to_curl[1]);
        close(from_curl[0]);
        close(from_curl[1]);
        return -1;
    }
    if (pid == 0) {
        dup2(to_curl[0], 0);
        dup2(from_curl[1], 1);
        close(to_curl[0]);
        close(to_curl[1]);
        close(from_curl[0]);
        close(from_curl[1]);
        /* -q first: ignore the user's .curlrc, which could change TLS checks, errors or logging */
        execlp("curl", "curl", "-q", "-sS", "--proto", secure ? "=https" : "=http", "--max-time", "300", "-K", "-", (char *)NULL);
        _exit(127);
    }
    close(to_curl[0]);
    close(from_curl[1]);
    char config[PATH_MAX * 2 + 512];
    int n = snprintf(config, sizeof config, "header = \"Authorization: Bearer %s\"\nurl = \"%s\"\noutput = \"%s\"\nwrite-out = \"%%{http_code}\"\n",
                     key, url, out_path);
    if (n > 0 && (size_t)n < sizeof config) {
        (void)safe_write(to_curl[1], config, (size_t)n);
    }
    wipe(config, sizeof config);
    close(to_curl[1]);
    char code[16] = { 0 };
    ssize_t got = read(from_curl[0], code, sizeof code - 1);
    close(from_curl[0]);
    int status = wait_for(pid);
    if (status < 0 || !WIFEXITED(status) || WEXITSTATUS(status) != 0 || got < 3) {
        return -1;
    }
    return atoi(code);
}

static int report_status(int status, const char *what)
{
    switch (status) {
    case 403:
        fprintf(stderr, "quietclaude: this licence key is not valid; nothing installed. Buy Pro at https://quietclaude.com/pro\n");
        if (g_used_saved) {
            fprintf(stderr, "             That was the key saved in ~/.quietclaude/license. To use another: qc pro install --key - < keyfile\n");
        }
        break;
    case -2:
        break;
    case 429: {
        /* The server counts days in UTC, so the limit resets at the next 00:00 UTC. */
        long left = 86400 - (long)(time(NULL) % 86400);
        long hours = (left + 3599) / 3600;
        char when[64];
        if (left < 3600) {
            snprintf(when, sizeof when, "in less than an hour");
        } else {
            snprintf(when, sizeof when, "in about %ld hour%s", hours, hours == 1 ? "" : "s");
        }
        fprintf(stderr, "quietclaude: too many downloads today for this key. The limit resets at 00:00 UTC, %s. Nothing installed.\n", when);
        break;
    }
    case 503:
        fprintf(stderr, "quietclaude: the licence service is not available right now. Try again in a few minutes; nothing installed.\n");
        break;
    case 404:
        fprintf(stderr, "quietclaude: there is no Pro release for this machine yet (%s); nothing installed.\n", what);
        break;
    case -1:
        fprintf(stderr, "quietclaude: could not download %s; check your connection (curl is needed). Nothing installed.\n", what);
        break;
    default:
        fprintf(stderr, "quietclaude: the download of %s failed (status %d); nothing installed.\n", what, status);
        break;
    }
    return QC_EXIT_FAIL;
}

static int usage(void)
{
    fprintf(stderr, "quietclaude: usage: qc pro install [--key -]\n"
                    "             to install from a file you already have: qc pro install <file>\n");
    return QC_EXIT_USAGE;
}

int qc_pro_download_install(int argc, char **argv)
{
    signal(SIGCHLD, SIG_DFL); /* an inherited "ignore" would make waitpid fail and hide a failed install */
    const char *key_arg = NULL;
    for (int i = 3; i < argc; i++) {
        if (strcmp(argv[i], "--key") == 0 && i + 1 < argc && key_arg == NULL) {
            key_arg = argv[++i];
        } else {
            return usage();
        }
    }

    char key[KEY_MAX + 64];
    int from_argv = 0;
    if (key_arg != NULL && strcmp(key_arg, "-") == 0) {
        if (read_key_line(stdin, key, sizeof key) != 0) {
            fprintf(stderr, "quietclaude: no licence key on standard input.\n");
            return QC_EXIT_USAGE;
        }
    } else if (key_arg != NULL) {
        snprintf(key, sizeof key, "%s", key_arg);
        from_argv = 1;
    } else if (saved_key(key, sizeof key) == 0) {
        g_used_saved = 1;
        printf("Using the saved licence key %.4s\u2026%s (from ~/.quietclaude/license).\n", key, key + strlen(key) - 4);
    } else if (prompt_key(key, sizeof key) != 0) {
        fprintf(stderr, "quietclaude: a licence key is needed. Type it when asked, or run: qc pro install --key - < keyfile\n");
        return QC_EXIT_USAGE;
    }
    if (!key_ok(key)) {
        fprintf(stderr, "quietclaude: this does not look like a licence key; nothing installed.\n");
        return QC_EXIT_USAGE;
    }
    if (from_argv) {
        fprintf(stderr, "quietclaude: note: a key typed on the command line can end up in your shell history. Next time leave out --key and type it when asked.\n");
    }

    const char *asset = asset_name();
    if (asset == NULL) {
        fprintf(stderr, "quietclaude: there is no Pro build for this system.\n");
        return QC_EXIT_FAIL;
    }
    int secure = 1;
    const char *base = release_base(&secure);
    if (base == NULL) {
        fprintf(stderr, "quietclaude: QUIETCLAUDE_PRO_BASE must start with https://.\n");
        return QC_EXIT_FAIL;
    }

    /* The downloaded program is run from here, so it goes under ~/.quietclaude (a place the user can run
     * programs from) rather than a /tmp that may be mounted noexec. */
    const char *home = getenv("HOME");
    const char *tmp = getenv("TMPDIR");
    if (home != NULL && home[0] == '/') {
        int hn = snprintf(g_home_dir, sizeof g_home_dir, "%s/.quietclaude", home);
        struct stat hs;
        if (hn > 0 && (size_t)hn < sizeof g_home_dir && lstat(g_home_dir, &hs) != 0 && mkdir(g_home_dir, 0700) == 0) {
            g_made_home = 1;
        }
        if (hn > 0 && (size_t)hn < sizeof g_home_dir) {
            int dn = snprintf(g_dir, sizeof g_dir, "%s/.qcpro.XXXXXX", g_home_dir);
            if (dn < 0 || (size_t)dn >= sizeof g_dir) {
                g_dir[0] = '\0';
            }
        }
    }
    if (g_dir[0] == '\0') {
        snprintf(g_dir, sizeof g_dir, "%s/qcpro.XXXXXX", tmp != NULL && tmp[0] == '/' ? tmp : "/tmp");
    }
    if (mkdtemp(g_dir) == NULL) {
        g_dir[0] = '\0';
        qc_report_error("mkdtemp");
        clean_files();
        return QC_EXIT_FAIL;
    }
    const char *names[3] = { "SHA256SUMS", "SHA256SUMS.sig", asset };
    for (int i = 0; i < 3; i++) {
        int n = snprintf(g_paths[i], sizeof g_paths[i], "%s/%s", g_dir, names[i]);
        if (n < 0 || (size_t)n >= sizeof g_paths[i]) {
            g_paths[i][0] = '\0';
            fprintf(stderr, "quietclaude: the temporary folder path is too long.\n");
            clean_files();
            return QC_EXIT_FAIL;
        }
    }
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGHUP, on_signal);

    printf("Downloading QuietClaude Pro for this machine (%s).\n", asset);
    fflush(stdout);
    int result = QC_EXIT_FAIL;
    for (int i = 0; i < 3; i++) {
        char url[1024];
        snprintf(url, sizeof url, "%s/pro/download/%s", base, names[i]);
        int status = fetch(url, key, g_paths[i], secure);
        if (status != 200) {
            result = report_status(status, names[i]);
            goto done;
        }
        if (i == 0) {
            /* The server asks Gumroad about the key before it sends the first file. */
            printf("Licence key accepted.\n");
            fflush(stdout);
        }
    }
    if (chmod(g_paths[2], 0700) != 0) {
        qc_report_error("chmod");
        goto done;
    }

    int to_pro[2];
    if (pipe(to_pro) != 0) {
        qc_report_error("pipe");
        goto done;
    }
    pid_t pid = fork();
    if (pid < 0) {
        qc_report_error("fork");
        close(to_pro[0]);
        close(to_pro[1]);
        goto done;
    }
    if (pid == 0) {
        dup2(to_pro[0], 0);
        close(to_pro[0]);
        close(to_pro[1]);
        setenv("QUIETCLAUDE_CORE_VERSION", QUIETCLAUDE_VERSION, 1);
        execl(g_paths[2], g_paths[2], "pro", "install", g_paths[2], "--key", "-", (char *)NULL);
        fprintf(stderr, "quietclaude: could not run the downloaded file: %s\n", strerror(errno));
        _exit(127);
    }
    close(to_pro[0]);
    char line[KEY_MAX + 66];
    int len = snprintf(line, sizeof line, "%s\n", key);
    if (len > 0) {
        (void)safe_write(to_pro[1], line, (size_t)len);
    }
    wipe(line, sizeof line);
    close(to_pro[1]);
    int status = wait_for(pid);
    if (status < 0) {
        fprintf(stderr, "quietclaude: could not tell how the installer ended; check with qc pro.\n");
        result = QC_EXIT_FAIL;
    } else {
        result = WIFEXITED(status) ? WEXITSTATUS(status) : 128 + (WIFSIGNALED(status) ? WTERMSIG(status) : 0);
    }

done:
    wipe(key, sizeof key);
    clean_files();
    return result;
}
