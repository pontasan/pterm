#include "pty_fork.h"

#include <errno.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <unistd.h>

pid_t pterm_fork_pty(int master_fd, int slave_fd) {
    pid_t pid = fork();
    if (pid != 0) {
        // Parent or error — return immediately.
        // On success (pid > 0), close slave in parent.
        if (pid > 0) {
            close(slave_fd);
        }
        return pid;
    }

    // ── Child process ──────────────────────────────────────────────────
    // Replicate login_tty() exactly (Apple libc source):
    //   1. close(master)
    //   2. setsid()
    //   3. ioctl(TIOCSCTTY)
    //   4. dup2(slave, 0/1/2)
    //   5. close(slave) if > 2

    close(master_fd);

    setsid();

    // Set slave as controlling terminal.
    ioctl(slave_fd, TIOCSCTTY, 0);

    dup2(slave_fd, STDIN_FILENO);
    dup2(slave_fd, STDOUT_FILENO);
    dup2(slave_fd, STDERR_FILENO);
    if (slave_fd > STDERR_FILENO) {
        close(slave_fd);
    }

    // Close all inherited file descriptors beyond stdio.
    // This prevents master fds from other PTY sessions leaking into
    // child process chains (e.g. zsh → claude).
    struct rlimit rl;
    int upper_fd;
    if (getrlimit(RLIMIT_NOFILE, &rl) == 0 && rl.rlim_cur > 3 && rl.rlim_cur <= (rlim_t)0x7FFFFFFF) {
        upper_fd = (int)rl.rlim_cur;
    } else {
        upper_fd = 4096;
    }
    for (int fd = 3; fd < upper_fd; fd++) {
        close(fd);
    }

    return 0;
}
