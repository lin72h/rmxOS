/* Bounded socket datagrams and kernel-log stream framing. */
#include <sys/types.h>
#include <sys/socket.h>
#include <sys/uio.h>
#include <string.h>
#include <unistd.h>
#include "asl_input.h"

/* Caller supplies ASL_SOCKET_MAX + 1 bytes, including the terminator. */
ssize_t
asl_bsd_receive(int fd, char *line, uint64_t *truncated)
{
	struct iovec iov = { .iov_base = line, .iov_len = ASL_SOCKET_MAX };
	struct msghdr msg = { .msg_iov = &iov, .msg_iovlen = 1 };
	ssize_t n = recvmsg(fd, &msg, 0);
	if (n < 0) return n;
	if ((msg.msg_flags & MSG_TRUNC) != 0) {
		__atomic_fetch_add(truncated, 1, __ATOMIC_RELAXED);
		/* Never misrepresent an incomplete structured record as complete. */
		line[0] = '\0';
		return 0;
	}
	line[n] = '\0';
	return n;
}

ssize_t
asl_klog_read(int fd, struct asl_klog_state *state, asl_input_emit_t emit, void *ctx)
{
	ssize_t n = read(fd, state->bytes + state->used, ASL_KLOG_SIZE - state->used);
	if (n <= 0) return n;
	size_t total = state->used + (size_t)n, start = 0;
	for (size_t i = state->used; i < total; i++) {
		if (state->bytes[i] != '\n') continue;
		state->bytes[i] = '\0';
		if (i > start) emit(state->bytes + start, i - start, ctx);
		start = i + 1;
	}
	state->used = total - start;
	if (start != 0) memmove(state->bytes, state->bytes + start, state->used);
	if (state->used == ASL_KLOG_SIZE) {
		state->bytes[state->used] = '\0';
		emit(state->bytes, state->used, ctx);
		state->used = 0;
	}
	return n;
}
