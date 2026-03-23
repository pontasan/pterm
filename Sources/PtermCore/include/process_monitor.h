#ifndef PTERM_PROCESS_MONITOR_H
#define PTERM_PROCESS_MONITOR_H

#include <sys/types.h>
#include <sys/event.h>
#include <stdint.h>

/// Register a PID for EVFILT_PROC monitoring (NOTE_FORK | NOTE_EXIT | NOTE_EXEC).
/// Returns 0 on success, -1 on failure.
int pterm_kqueue_register_pid(int kq, pid_t pid);

/// Deregister a PID from EVFILT_PROC monitoring.
/// Returns 0 on success, -1 on failure (e.g. already removed).
int pterm_kqueue_deregister_pid(int kq, pid_t pid);

/// Poll pending kqueue events into the provided buffer.
/// Returns the number of events retrieved (0 if none, -1 on error).
/// `max_events` must match the capacity of the `events` array.
int pterm_kqueue_poll(int kq, struct kevent *events, int max_events);

/// Extract the child PID from a NOTE_FORK kevent.
pid_t pterm_kevent_fork_child_pid(const struct kevent *ev);

/// Check if a kevent has the specified note flag.
int pterm_kevent_has_note(const struct kevent *ev, uint32_t note);

/// Get the PID from a kevent's ident field.
pid_t pterm_kevent_pid(const struct kevent *ev);

#endif /* PTERM_PROCESS_MONITOR_H */
