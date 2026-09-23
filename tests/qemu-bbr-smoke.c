#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef TCP_CC_INFO
#define TCP_CC_INFO 26
#endif

/* Enough data for BBR to build a delivery-rate model, small enough for TCG. */
#define TRANSFER_BYTES ((uint64_t)32 << 20)
#define CHUNK_BYTES 65536

/*
 * struct tcp_bbr_info as extended by the BBRv3 patch in
 * include/uapi/linux/inet_diag.h. The build host's UAPI headers only know the
 * original five fields, so the patched layout is mirrored here.
 */
struct bbrv3_info {
	uint32_t bbr_bw_lo;
	uint32_t bbr_bw_hi;
	uint32_t bbr_min_rtt;
	uint32_t bbr_pacing_gain;
	uint32_t bbr_cwnd_gain;
	uint32_t bbr_bw_hi_lsb;
	uint32_t bbr_bw_hi_msb;
	uint32_t bbr_bw_lo_lsb;
	uint32_t bbr_bw_lo_msb;
	uint8_t bbr_mode;
	uint8_t bbr_phase;
	uint8_t unused1;
	uint8_t bbr_version;
	uint32_t bbr_inflight_lo;
	uint32_t bbr_inflight_hi;
	uint32_t bbr_extra_acked;
};

_Static_assert(offsetof(struct bbrv3_info, bbr_version) == 39,
	       "unexpected BBRv3 tcp_bbr_info layout");
_Static_assert(sizeof(struct bbrv3_info) == 52,
	       "unexpected BBRv3 tcp_bbr_info size");

static void fail(const char *operation)
{
	fprintf(stderr, "BBRV3_SOCKET_FAIL: %s: %s\n", operation, strerror(errno));
	exit(EXIT_FAILURE);
}

static void fail_check(const char *reason)
{
	fprintf(stderr, "BBRV3_SOCKET_FAIL: %s\n", reason);
	exit(EXIT_FAILURE);
}

/* A position-dependent pattern, so lost, repeated or reordered data shows. */
static unsigned char pattern_byte(uint64_t offset)
{
	return (unsigned char)(offset * 131 + 7);
}

static void receive_and_check(int peer)
{
	static unsigned char buffer[CHUNK_BYTES];
	uint64_t received = 0;

	for (;;) {
		ssize_t count = recv(peer, buffer, sizeof(buffer), 0);

		if (count < 0) {
			if (errno == EINTR)
				continue;
			fail("recv");
		}
		if (count == 0)
			break;
		for (ssize_t i = 0; i < count; i++) {
			if (buffer[i] != pattern_byte(received + (uint64_t)i))
				fail_check("received data does not match what was sent");
		}
		received += (uint64_t)count;
	}
	if (received != TRANSFER_BYTES)
		fail_check("the connection closed before all data arrived");
	exit(EXIT_SUCCESS);
}

static void send_pattern(int client)
{
	static unsigned char buffer[CHUNK_BYTES];
	uint64_t sent = 0;

	while (sent < TRANSFER_BYTES) {
		size_t length = sizeof(buffer);
		size_t offset = 0;

		if (TRANSFER_BYTES - sent < length)
			length = (size_t)(TRANSFER_BYTES - sent);
		for (size_t i = 0; i < length; i++)
			buffer[i] = pattern_byte(sent + i);
		while (offset < length) {
			ssize_t count = send(client, buffer + offset, length - offset, MSG_NOSIGNAL);

			if (count < 0) {
				if (errno == EINTR)
					continue;
				fail("send");
			}
			offset += (size_t)count;
		}
		sent += length;
	}
}

int main(void)
{
	struct sockaddr_in address = {
		.sin_family = AF_INET,
		.sin_addr.s_addr = htonl(INADDR_LOOPBACK),
	};
	struct bbrv3_info info;
	struct timespec started;
	struct timespec finished;
	char selected[32] = {0};
	socklen_t address_length = sizeof(address);
	socklen_t selected_length = sizeof(selected);
	socklen_t info_length = sizeof(info);
	uint64_t bandwidth;
	double seconds;
	pid_t receiver;
	int status;
	int listener;
	int client;
	int peer;

	/* A stalled transfer must fail here, not only at the QEMU timeout. */
	alarm(90);

	listener = socket(AF_INET, SOCK_STREAM, 0);
	if (listener < 0)
		fail("socket(listener)");
	if (bind(listener, (struct sockaddr *)&address, sizeof(address)) < 0)
		fail("bind");
	if (getsockname(listener, (struct sockaddr *)&address, &address_length) < 0)
		fail("getsockname");
	if (listen(listener, 1) < 0)
		fail("listen");

	client = socket(AF_INET, SOCK_STREAM, 0);
	if (client < 0)
		fail("socket(client)");
	if (setsockopt(client, IPPROTO_TCP, TCP_CONGESTION, "bbr", 4) < 0)
		fail("setsockopt(TCP_CONGESTION=bbr)");
	if (connect(client, (struct sockaddr *)&address, sizeof(address)) < 0)
		fail("connect");

	peer = accept(listener, NULL, NULL);
	if (peer < 0)
		fail("accept");

	receiver = fork();
	if (receiver < 0)
		fail("fork");
	if (receiver == 0) {
		close(client);
		close(listener);
		receive_and_check(peer);
	}
	close(peer);

	if (clock_gettime(CLOCK_MONOTONIC, &started) < 0)
		fail("clock_gettime");
	send_pattern(client);

	/* Ask the sending socket itself which BBR produced its model. */
	memset(&info, 0, sizeof(info));
	if (getsockopt(client, IPPROTO_TCP, TCP_CC_INFO, &info, &info_length) < 0)
		fail("getsockopt(TCP_CC_INFO)");
	if (getsockopt(client, IPPROTO_TCP, TCP_CONGESTION, selected, &selected_length) < 0)
		fail("getsockopt(TCP_CONGESTION)");
	if (shutdown(client, SHUT_WR) < 0)
		fail("shutdown");
	if (waitpid(receiver, &status, 0) != receiver)
		fail("waitpid");
	if (clock_gettime(CLOCK_MONOTONIC, &finished) < 0)
		fail("clock_gettime");
	if (!WIFEXITED(status) || WEXITSTATUS(status) != EXIT_SUCCESS)
		fail_check("the receiving side failed");

	if (strcmp(selected, "bbr") != 0)
		fail_check("selected congestion control is not bbr");
	if (info_length != sizeof(info))
		fail_check("TCP_CC_INFO did not return the BBRv3 tcp_bbr_info layout");
	if (info.bbr_version != 3)
		fail_check("the connection's congestion control does not report BBR version 3");
	bandwidth = ((uint64_t)info.bbr_bw_hi << 32) | info.bbr_bw_lo;
	if (bandwidth == 0)
		fail_check("BBR reported no bandwidth estimate after the transfer");

	seconds = (double)(finished.tv_sec - started.tv_sec) +
		  (double)(finished.tv_nsec - started.tv_nsec) / 1e9;
	close(client);
	close(listener);
	printf("BBRV3_SOCKET_PASS: %llu MiB verified in %.2f s, bbr_version %u, "
	       "bw %llu B/s, min_rtt %u us, mode %u, phase %u\n",
	       (unsigned long long)(TRANSFER_BYTES >> 20), seconds,
	       (unsigned int)info.bbr_version, (unsigned long long)bandwidth,
	       (unsigned int)info.bbr_min_rtt, (unsigned int)info.bbr_mode,
	       (unsigned int)info.bbr_phase);
	return EXIT_SUCCESS;
}
