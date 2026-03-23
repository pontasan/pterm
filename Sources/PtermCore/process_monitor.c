#include "process_monitor.h"

#include <sys/event.h>
#include <sys/time.h>
#include <unistd.h>

int pterm_kqueue_register_pid(int kq, pid_t pid) {
    struct kevent ev;
    EV_SET(&ev, (uintptr_t)pid, EVFILT_PROC,
           EV_ADD | EV_ENABLE,
           NOTE_FORK | NOTE_EXIT | NOTE_EXEC,
           0, NULL);
    return kevent(kq, &ev, 1, NULL, 0, NULL);
}

int pterm_kqueue_deregister_pid(int kq, pid_t pid) {
    struct kevent ev;
    EV_SET(&ev, (uintptr_t)pid, EVFILT_PROC, EV_DELETE, 0, 0, NULL);
    return kevent(kq, &ev, 1, NULL, 0, NULL);
}

int pterm_kqueue_poll(int kq, struct kevent *events, int max_events) {
    struct timespec timeout = { 0, 0 };  /* non-blocking */
    return kevent(kq, NULL, 0, events, max_events, &timeout);
}

pid_t pterm_kevent_fork_child_pid(const struct kevent *ev) {
    return (pid_t)ev->data;
}

int pterm_kevent_has_note(const struct kevent *ev, uint32_t note) {
    return (ev->fflags & note) != 0;
}

pid_t pterm_kevent_pid(const struct kevent *ev) {
    return (pid_t)ev->ident;
}
