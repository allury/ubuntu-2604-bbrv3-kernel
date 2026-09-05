#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static void fail(const char *operation)
{
	fprintf(stderr, "BBRV3_SOCKET_FAIL: %s: %s\n", operation, strerror(errno));
	exit(EXIT_FAILURE);
}

int main(void)
{
	static const char payload[] = "bbrv3-qemu-smoke";
	struct sockaddr_in address = {
		.sin_family = AF_INET,
		.sin_addr.s_addr = htonl(INADDR_LOOPBACK),
	};
	char received[sizeof(payload)] = {0};
	char selected[32] = {0};
	socklen_t address_length = sizeof(address);
	socklen_t selected_length = sizeof(selected);
	ssize_t total = 0;
	int listener;
	int client;
	int peer;

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
	if (send(client, payload, sizeof(payload), 0) != (ssize_t)sizeof(payload))
		fail("send");
	while (total < (ssize_t)sizeof(received)) {
		ssize_t count = recv(peer, received + total, sizeof(received) - total, 0);

		if (count <= 0)
			fail("recv");
		total += count;
	}
	if (memcmp(received, payload, sizeof(payload)) != 0) {
		errno = EPROTO;
		fail("payload mismatch");
	}
	if (getsockopt(client, IPPROTO_TCP, TCP_CONGESTION, selected, &selected_length) < 0)
		fail("getsockopt(TCP_CONGESTION)");
	if (strcmp(selected, "bbr") != 0) {
		errno = EPROTO;
		fail("selected congestion control is not bbr");
	}

	close(peer);
	close(client);
	close(listener);
	puts("BBRV3_SOCKET_PASS");
	return EXIT_SUCCESS;
}
