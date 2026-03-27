#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#pragma comment(lib, "ws2_32.lib")
#else
#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#endif

#include "../c_kcp/i_kcp.h"

// Get current time in milliseconds
IUINT32 iclock() {
#ifdef _WIN32
    return GetTickCount();
#else
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (IUINT32)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
#endif
}

// UDP output callback for KCP
int udp_output(const char *buf, int len, ikcpcb *kcp, void *user) {
    SOCKET sock = *(SOCKET*)user;
    struct sockaddr_in server_addr;
    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_port = htons(9999);
    server_addr.sin_addr.s_addr = inet_addr("127.0.0.1");
    sendto(sock, buf, len, 0, (struct sockaddr*)&server_addr, sizeof(server_addr));
    return 0;
}

int main() {
#ifdef _WIN32
    WSADATA wsaData;
    WSAStartup(MAKEWORD(2, 2), &wsaData);
#endif

    SOCKET sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock == INVALID_SOCKET) {
        perror("socket");
        return 1;
    }

    // Set non-blocking
#ifdef _WIN32
    unsigned long mode = 1;
    ioctlsocket(sock, FIONBIO, &mode);
#else
    int flags = fcntl(sock, F_GETFL, 0);
    fcntl(sock, F_SETFL, flags | O_NONBLOCK);
#endif

    ikcpcb *kcp = ikcp_create(0x11223344, (void*)&sock);
    kcp->output = udp_output;

    // Fastest mode
    ikcp_nodelay(kcp, 1, 10, 2, 1);
    ikcp_wndsize(kcp, 128, 128);

    const char *msg = "Hello from C Client!";
    ikcp_send(kcp, msg, strlen(msg));

    printf("C Client started, sending: %s\n", msg);

    char buffer[2048];
    while (1) {
        IUINT32 now = iclock();
        ikcp_update(kcp, now);

        struct sockaddr_in from_addr;
        int from_len = sizeof(from_addr);
        int n = recvfrom(sock, buffer, sizeof(buffer), 0, (struct sockaddr*)&from_addr, &from_len);
        
        if (n > 0) {
            ikcp_input(kcp, buffer, n);
            
            char recv_buf[1024];
            int len = ikcp_recv(kcp, recv_buf, sizeof(recv_buf));
            if (len > 0) {
                recv_buf[len] = '\0';
                printf("Received from server: %s\n", recv_buf);
                break;
            }
        }

#ifdef _WIN32
        Sleep(10);
#else
        usleep(10000);
#endif
    }

    ikcp_release(kcp);
#ifdef _WIN32
    closesocket(sock);
    WSACleanup();
#else
    close(sock);
#endif

    return 0;
}
