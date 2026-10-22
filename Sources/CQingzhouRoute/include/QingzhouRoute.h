#ifndef QINGZHOU_ROUTE_H
#define QINGZHOU_ROUTE_H
#include <stddef.h>
#include <stdint.h>
#include <net/route.h>

// 数值字段保留内核身份，文本缓冲区只存本机路由信息。
typedef struct {
    char destination[64];
    char gateway[64];
    char interface_name[32];
    uint32_t flags;
    uint32_t interface_index;
    int32_t family;
    int32_t prefix_length;
} QZRouteRow;
typedef int (*QZCancelled)(void *context);
int qz_route_dump(void **bytes, size_t *length);
void qz_route_free(void *bytes);
int qz_route_decode(const void *bytes, size_t length, QZRouteRow *rows, size_t capacity, size_t *count);
int qz_route_encode(int operation, const char *destination, int family, int prefix_length,
                    const char *gateway, const char *interface_name, int scoped, int legacy,
                    int pid, int sequence, void *bytes, size_t capacity, size_t *length);
// 严格验证本组件允许提交的请求；不用于把内核响应当作请求。
int qz_route_validate(const void *bytes, size_t length);
// 0 表示无关响应，1 表示匹配响应；负值表示畸形匹配响应。
int qz_route_match(const void *bytes, size_t length, int operation, int pid, int sequence, int *kernel_error);
int qz_route_exchange(const void *request, size_t length, double timeout_seconds,
                      QZCancelled cancelled, void *context, void *reply, size_t capacity,
                      size_t *reply_length, int *submitted, int *kernel_error);
// 注入整个传输状态机，离线夹具不创建路由套接字。
typedef struct {
    void *context;
    double (*now)(void *context);
    int (*open_socket)(void *context);
    int (*configure)(void *context,int fd);
    long (*send_packet)(void *context,int fd,const void *bytes,size_t length);
    int (*wait_ready)(void *context,int fd,int sending,int milliseconds);
    long (*receive_packet)(void *context,int fd,void *bytes,size_t capacity);
    void (*close_socket)(void *context,int fd);
} QZRouteIO;
int qz_route_exchange_with_io(const void *request,size_t length,double timeout_seconds,
    QZCancelled cancelled,void *context,void *reply,size_t capacity,size_t *reply_length,
    int *submitted,int *kernel_error,const QZRouteIO *io);
int qz_interface_addresses(char **text, size_t *length);
#endif
