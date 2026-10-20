#ifdef __linux__
#define _GNU_SOURCE
#endif
#ifdef __APPLE__
#define _DARWIN_C_SOURCE
#endif
#include "banner.h"
#include "quietclaude.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif

#define IO_BUFFER 65536

static struct termios g_saved_termios;
static volatile sig_atomic_t g_termios_saved = 0;
static int g_signal_pipe[2] = { -1, -1 };

static void on_signal(int sig)
{
    int saved_errno = errno;
    unsigned char byte = (unsigned char)sig;
    ssize_t ignored = write(g_signal_pipe[1], &byte, 1);
    (void)ignored;
    errno = saved_errno;
}

static void restore_terminal(void)
{
    if (g_termios_saved) {
        g_termios_saved = 0;
        tcsetattr(STDIN_FILENO, TCSANOW, &g_saved_termios);
    }
}

static uint64_t now_ms(void)
{
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return 0;
    }
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

static int forward_bytes(int fd, const uint8_t *data, size_t len)
{
    while (len > 0) {
        ssize_t n = write(fd, data, len);
        if (n >= 0) {
            data += (size_t)n;
            len -= (size_t)n;
            continue;
        }
        if (errno == EINTR) {
            continue;
        }
        if (errno == EAGAIN) {
            struct pollfd pfd = { .fd = fd, .events = POLLOUT };
            if (poll(&pfd, 1, -1) < 0 && errno != EINTR) {
                return -1;
            }
            continue;
        }
        return -1;
    }
    return 0;
}

static void debug_removed(const qc_bridge_sink *b, const uint8_t *data, size_t len)
{
    const char *eol = b->stderr_is_tty ? "\r\n" : "\n";
    fprintf(stderr, "[quietclaude] removed banner: %zu bytes%s", len, eol);
    int at_line_start = 1;
    for (size_t i = 0; i < len; i++) {
        at_line_start = 0;
        switch (data[i]) {
        case 0x1b:
            fputs("^[", stderr);
            break;
        case '\r':
            fputs("\\r", stderr);
            break;
        case '\n':
            fputs("\\n", stderr);
            fputs(eol, stderr);
            at_line_start = 1;
            break;
        default:
            fputc(data[i], stderr);
            break;
        }
    }
    if (!at_line_start) {
        fputs(eol, stderr);
    }
    fflush(stderr);
}

static void sink_write(qc_bridge_sink *b, const uint8_t *data, size_t len)
{
    if (b->output_errno == 0 && len > 0 && b->write(b->io, data, len) != 0) {
        b->output_errno = errno != 0 ? errno : EIO;
    }
}

void qc_bridge_event(void *sink, qc_event_kind kind, const uint8_t *data, size_t len)
{
    qc_bridge_sink *b = sink;
    const qc_launch_options *o = b->options;
    switch (kind) {
    case QC_EV_OUTPUT:
        sink_write(b, data, len);
        break;
    case QC_EV_REMOVED:
        if (o != NULL && o->on_banner_removed != NULL) {
            o->on_banner_removed(o->ctx, data, len);
        }
        if (b->debug) {
            debug_removed(b, data, len);
        }
        if (o != NULL && (o->header != NULL || o->header_fn != NULL) && !b->header_written) {
            b->header_written = 1;
            const char *text = o->header_fn != NULL ? o->header_fn(o->ctx, data, len) : o->header;
            if (text != NULL) {
                sink_write(b, (const uint8_t *)text, strlen(text));
                sink_write(b, (const uint8_t *)"\r\n", 2);
            }
        }
        break;
    case QC_EV_DISARMED:
        if (b->debug) {
            fprintf(stderr, "[quietclaude] watch disarmed (%s)%s", (const char *)data,
                    b->stderr_is_tty ? "\r\n" : "\n");
            fflush(stderr);
        }
        break;
    }
}

static int install_handler(int sig, void (*handler)(int))
{
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = handler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = SA_RESTART;
    return sigaction(sig, &sa, NULL);
}

static int set_flag(int fd, int get_cmd, int set_cmd, int flag)
{
    int flags = fcntl(fd, get_cmd);
    if (flags < 0) {
        return -1;
    }
    return fcntl(fd, set_cmd, flags | flag);
}

static int open_signal_pipe(void)
{
    if (pipe(g_signal_pipe) != 0) {
        return -1;
    }
    for (int i = 0; i < 2; i++) {
        if (set_flag(g_signal_pipe[i], F_GETFD, F_SETFD, FD_CLOEXEC) != 0 ||
            set_flag(g_signal_pipe[i], F_GETFL, F_SETFL, O_NONBLOCK) != 0) {
            return -1;
        }
    }
    return 0;
}

static int fail(const char *what)
{
    int saved_errno = errno;
    restore_terminal();
    errno = saved_errno;
    qc_report_error(what);
    return 1;
}

static void send_eof(int master)
{
    struct termios slave;
    uint8_t eof = 0x04;
    if (tcgetattr(master, &slave) == 0 && slave.c_cc[VEOF] != _POSIX_VDISABLE) {
        eof = slave.c_cc[VEOF];
    }
    if (forward_bytes(master, &eof, 1) != 0 && errno != EIO) {
    }
}

static void forward_terminal_size(int master)
{
    struct winsize ws;
    if (ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) == 0) {
        ioctl(master, TIOCSWINSZ, &ws);
    }
}

static int exit_status(int status)
{
    if (WIFSIGNALED(status)) {
        return 128 + WTERMSIG(status);
    }
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}

static int write_stdout(void *io, const uint8_t *data, size_t len)
{
    (void)io;
    return forward_bytes(STDOUT_FILENO, data, len);
}

int qc_terminal_run(const char *claude_path, char *const argv[], const qc_launch_options *options, int debug)
{
    qc_bridge_sink bridge = { .write = write_stdout, .io = NULL, .options = options, .debug = debug,
                              .stderr_is_tty = isatty(STDERR_FILENO), .header_written = 0, .output_errno = 0 };
    struct winsize ws;
    if (ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) != 0) {
        return fail("get terminal size");
    }
    if (tcgetattr(STDIN_FILENO, &g_saved_termios) != 0) {
        return fail("get terminal settings");
    }
    if (open_signal_pipe() != 0) {
        return fail("create signal pipe");
    }
    const int handled[] = { SIGWINCH, SIGCHLD, SIGINT, SIGTERM, SIGHUP };
    for (size_t i = 0; i < sizeof handled / sizeof handled[0]; i++) {
        if (install_handler(handled[i], on_signal) != 0) {
            return fail("install signal handler");
        }
    }

    int master = -1;
    pid_t child = forkpty(&master, NULL, &g_saved_termios, &ws);
    if (child < 0) {
        return fail("open pseudoterminal");
    }
    if (child == 0) {
        for (size_t i = 0; i < sizeof handled / sizeof handled[0]; i++) {
            signal(handled[i], SIG_DFL);
        }
        execv(claude_path, argv);
        fprintf(stderr, "quietclaude: exec %s: %s\n", claude_path, strerror(errno));
        _exit(1);
    }

    if (signal(SIGPIPE, SIG_IGN) == SIG_ERR) {
        return fail("ignore SIGPIPE");
    }
    struct termios raw = g_saved_termios;
    cfmakeraw(&raw);
    g_termios_saved = 1;
    if (tcsetattr(STDIN_FILENO, TCSANOW, &raw) != 0) {
        return fail("set raw mode");
    }
    if (set_flag(master, F_GETFL, F_SETFL, O_NONBLOCK) != 0) {
        return fail("configure pseudoterminal");
    }

    uint8_t *buffer = malloc(IO_BUFFER);
    if (buffer == NULL) {
        return fail("malloc");
    }

    qc_filter filter;
    qc_filter_init(&filter, qc_bridge_event, &bridge, now_ms());

    int stdin_open = 1;
    int master_open = 1;
    int child_done = 0;
    int status = 0;
    int terminating_signal = 0;
    int result = -1;

    while (!child_done) {
        struct pollfd fds[3];
        int count = 0;
        fds[count++] = (struct pollfd){ .fd = g_signal_pipe[0], .events = POLLIN };
        int master_slot = -1;
        int stdin_slot = -1;
        if (master_open) {
            master_slot = count;
            fds[count++] = (struct pollfd){ .fd = master, .events = POLLIN };
        }
        if (stdin_open) {
            stdin_slot = count;
            fds[count++] = (struct pollfd){ .fd = STDIN_FILENO, .events = POLLIN };
        }

        int ready = poll(fds, (nfds_t)count, qc_filter_wait_ms(&filter, now_ms()));
        if (ready < 0) {
            if (errno == EINTR) {
                continue;
            }
            result = fail("poll");
            break;
        }
        uint64_t now = now_ms();
        if (ready == 0) {
            qc_filter_tick(&filter, now);
        }

        if (fds[0].revents != 0) {
            unsigned char sigs[64];
            ssize_t n;
            while ((n = read(g_signal_pipe[0], sigs, sizeof sigs)) > 0) {
                for (ssize_t i = 0; i < n; i++) {
                    int sig = sigs[i];
                    if (sig == SIGWINCH) {
                        forward_terminal_size(master);
                        qc_filter_resize(&filter, now);
                    } else if (sig == SIGINT || sig == SIGTERM || sig == SIGHUP) {
                        if (terminating_signal == sig) {
                            restore_terminal();
                            kill(child, SIGKILL);
                            free(buffer);
                            return 128 + sig;
                        }
                        terminating_signal = sig;
                        kill(child, sig);
                    }
                }
            }
        }

        if (stdin_slot >= 0 && fds[stdin_slot].revents != 0) {
            ssize_t n = read(STDIN_FILENO, buffer, IO_BUFFER);
            if (n > 0) {
                qc_filter_keystroke(&filter, now);
                if (forward_bytes(master, buffer, (size_t)n) != 0 && errno != EIO) {
                    result = fail("write to pseudoterminal");
                    break;
                }
            } else if (n == 0 || (errno != EINTR && errno != EAGAIN)) {
                stdin_open = 0;
                send_eof(master);
            }
        }

        if (master_slot >= 0 && fds[master_slot].revents != 0) {
            for (;;) {
                ssize_t n = read(master, buffer, IO_BUFFER);
                if (n > 0) {
                    qc_filter_feed(&filter, buffer, (size_t)n, now);
                    continue;
                }
                if (n < 0 && errno == EINTR) {
                    continue;
                }
                if (n < 0 && errno == EAGAIN) {
                    break;
                }
                master_open = 0;
                break;
            }
        }

        pid_t waited = waitpid(child, &status, WNOHANG);
        if (waited < 0 && errno != EINTR) {
            result = fail("waitpid");
            break;
        }
        if (waited == child) {
            child_done = 1;
            while (master_open) {
                ssize_t n = read(master, buffer, IO_BUFFER);
                if (n > 0) {
                    qc_filter_feed(&filter, buffer, (size_t)n, now_ms());
                } else if (n < 0 && errno == EINTR) {
                    continue;
                } else {
                    break;
                }
            }
        }
    }

    qc_filter_finish(&filter, now_ms());
    restore_terminal();
    free(buffer);
    close(master);

    if (result >= 0) {
        return result;
    }
    if (bridge.output_errno != 0) {
        errno = bridge.output_errno;
        qc_report_error("write stdout");
        return 1;
    }
    return exit_status(status);
}
