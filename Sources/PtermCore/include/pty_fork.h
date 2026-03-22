#ifndef PTERM_PTY_FORK_H
#define PTERM_PTY_FORK_H

#include <sys/types.h>

/// Fork and set up the child side of a PTY, replicating login_tty() behavior.
///
/// This is called from Swift because Foundation marks fork() as unavailable.
/// The function performs: fork() → child: close(master), setsid(), TIOCSCTTY,
/// dup2(slave, 0/1/2), close(slave), close fds 3..rlimit.
///
/// Returns:
///   > 0  in parent (child PID)
///   == 0 in child  (ready for execv)
///   < 0  on error  (errno is set)
///
/// On success in the parent, *slave_fd is closed by this function.
/// On failure, neither master nor slave is closed — the caller must handle cleanup.
pid_t pterm_fork_pty(int master_fd, int slave_fd);

#endif /* PTERM_PTY_FORK_H */
