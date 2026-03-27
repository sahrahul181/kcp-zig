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

// Simple client tracking for demo
struct ClientInstance {
    ikcpcb *kcp;
    struct sockaddr_in addr;
    SOCKET sock;
};

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
    struct ClientInstance *instance = (struct ClientInstance*)user;
    sendto(instance->sock, buf, len, 0, (struct sockaddr*)&instance->addr, sizeof(instance->addr));
    return 0;
}

int main() {
    printf("C Server starting on port 9999...\n");

#ifdef _WIN32
    WSADATA wsaData;
    WSAStartup(MAKEWORD(2, 2), &wsaData);
#endif

    SOCKET sock = socket(AF_INET, SOCK_DGRAM, 0);
    if (sock == INVALID_SOCKET) {
        perror("socket");
        return 1;
    }

    struct sockaddr_in server_addr;
    memset(&server_addr, 0, sizeof(server_addr));
    server_addr.sin_family = AF_INET;
    server_addr.sin_port = htons(9999);
    server_addr.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(sock, (struct sockaddr*)&server_addr, sizeof(server_addr)) == SOCKET_ERROR) {
        perror("bind");
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

    struct ClientInstance *client_instances[10] = {NULL};
    int num_clients = 0;

    printf("C Server listening on 127.0.0.1:9999\n");

    char buffer[2048];
    while (1) {
        IUINT32 now = iclock();

        struct sockaddr_in from_addr;
        int from_len = sizeof(from_addr);
        int n = recvfrom(sock, buffer, sizeof(buffer), 0, (struct sockaddr*)&from_addr, &from_len);
        
        if (n > 0) {
            // Find or create kcp instance
            struct ClientInstance *instance = NULL;
            for (int i = 0; i < num_clients; ++i) {
                if (client_instances[i]->addr.sin_addr.s_addr == from_addr.sin_addr.s_addr &&
                    client_instances[i]->addr.sin_port == from_addr.sin_port) {
                    instance = client_instances[i];
                    break;
                }
            }
            if (!instance && num_clients < 10) {
                instance = (struct ClientInstance*)malloc(sizeof(struct ClientInstance));
                instance->sock = sock;
                memcpy(&instance->addr, &from_addr, sizeof(from_addr));
                instance->kcp = ikcp_create(0x11223344, (void*)instance);
                instance->kcp->output = udp_output;
                ikcp_nodelay(instance->kcp, 1, 10, 2, 1);
                client_instances[num_clients++] = instance;
                printf("New C Client linked: %s:%d\n", inet_ntoa(from_addr.sin_addr), ntohs(from_addr.sin_port));
            }

            if (instance) {
                ikcp_input(instance->kcp, buffer, n);
                
                char recv_buf[1024];
                int len = ikcp_recv(instance->kcp, recv_buf, sizeof(recv_buf));
                if (len > 0) {
                    recv_buf[len] = '\0';
                    printf("Received from client: %s\n", recv_buf);
                    
                    char reply[128];
                    sprintf(reply, "C Server Echo: %s", recv_buf);
                    ikcp_send(instance->kcp, reply, strlen(reply));
                    printf("Sent reply: %s\n", reply);
                }
            }
        }

        for (int i = 0; i < num_clients; ++i) {
            ikcp_update(client_instances[i]->kcp, now);
        }

#ifdef _WIN32
        Sleep(10);
#else
        usleep(10000);
#endif
    }

    // Clean up would be good but it's an infinite loop for demo
    return 0;
}
