#include "QingzhouRoute.h"
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <poll.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

int qz_route_match(const void *bytes,size_t length,int operation,int pid,int sequence,int *kernel_error) {
    if(!bytes || length<4)return -EPROTO;
    const unsigned char *raw=bytes;
    // 接口和地址通知使用不同头部，不能按路由确认头解读。
    if(raw[3]!=RTM_GET && raw[3]!=RTM_ADD && raw[3]!=RTM_DELETE && raw[3]!=RTM_CHANGE && raw[3]!=RTM_LOCK)return 0;
    if(length<sizeof(struct rt_msghdr))return -EPROTO;
    struct rt_msghdr h;memcpy(&h,bytes,sizeof(h));
    if(h.rtm_pid!=pid || h.rtm_seq!=sequence)return 0;
    if(h.rtm_msglen<sizeof(h) || h.rtm_msglen!=length || h.rtm_version!=RTM_VERSION || h.rtm_type!=operation)return -EPROTO;
    *kernel_error=h.rtm_errno;return 1;
}
static double system_now(void *context){(void)context;struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
static int system_open(void *context){(void)context;return socket(PF_ROUTE,SOCK_RAW,AF_UNSPEC);}
static int system_configure(void *context,int fd){(void)context;int flags=fcntl(fd,F_GETFL);if(flags<0 || fcntl(fd,F_SETFD,FD_CLOEXEC)<0)return -1;return fcntl(fd,F_SETFL,flags|O_NONBLOCK);}
static long system_send(void *context,int fd,const void *bytes,size_t size){(void)context;return send(fd,bytes,size,MSG_DONTWAIT);}
static long system_receive(void *context,int fd,void *bytes,size_t size){(void)context;return recv(fd,bytes,size,MSG_DONTWAIT|MSG_TRUNC);}
static int system_wait(void *context,int fd,int sending,int ms){
    (void)context;struct pollfd item={fd,sending ? POLLOUT:POLLIN,0};int result=poll(&item,1,ms);
    if(result>0 && (item.revents & (POLLERR|POLLHUP|POLLNVAL))){errno=EIO;return -1;}
    return result;
}
static void system_close(void *context,int fd){(void)context;close(fd);}
int qz_route_exchange_with_io(const void *request,size_t length,double timeout,QZCancelled cancelled,void *context,void *reply,size_t capacity,size_t *reply_length,int *submitted,int *kernel_error,const QZRouteIO *io){
    *submitted=0;*reply_length=0;*kernel_error=0;
    int result=qz_route_validate(request,length);if(result)return result;
    if(!isfinite(timeout) || timeout<=0 || !reply || capacity<sizeof(struct rt_msghdr) || !io || !io->now || !io->open_socket || !io->configure || !io->send_packet || !io->wait_ready || !io->receive_packet || !io->close_socket)return EINVAL;
    struct rt_msghdr wanted;memcpy(&wanted,request,sizeof(wanted));
    double deadline=io->now(io->context)+timeout;
    if(cancelled && cancelled(context))return ECANCELED;
    int fd=io->open_socket(io->context);if(fd<0)return errno;
    if(io->configure(io->context,fd)<0){result=errno;goto done;}
    int sent=0;
    for(;;){
        if(cancelled && cancelled(context)){result=ECANCELED;break;}
        double remaining=deadline-io->now(io->context);if(remaining<=0){result=ETIMEDOUT;break;}
        int ms=(int)fmin(50,fmax(1,remaining*1000));
        if(!sent){
            long n=io->send_packet(io->context,fd,request,length);
            if(n>=0){
                // 路由 socket 是报文接口，短写不发送剩余尾部；提交结果未知时由恢复事务核对。
                *submitted=1;if((size_t)n!=length){result=EIO;break;}sent=1;continue;
            }
            if(errno==EINTR)continue;
            if(errno!=EAGAIN && errno!=EWOULDBLOCK){result=errno;break;}
        }
        int ready=io->wait_ready(io->context,fd,!sent,ms);
        if(ready<0){if(errno==EINTR)continue;result=errno;break;}if(!ready || !sent)continue;
        // poll 和 recv 之间仍检查取消与总预算，避免在截止后处理一次迟到确认。
        if(cancelled && cancelled(context)){result=ECANCELED;break;}
        if(io->now(io->context)>=deadline){result=ETIMEDOUT;break;}
        long size=io->receive_packet(io->context,fd,reply,capacity);
        if(size<0){if(errno==EINTR || errno==EAGAIN || errno==EWOULDBLOCK)continue;result=errno;break;}
        if((size_t)size>capacity){result=ENOBUFS;break;}
        int match=qz_route_match(reply,size,wanted.rtm_type,wanted.rtm_pid,wanted.rtm_seq,kernel_error);
        if(match<0){result=-match;break;}if(!match)continue;
        *reply_length=size;result=0;break;
    }
done:io->close_socket(io->context,fd);return result;
}
int qz_route_exchange(const void *request,size_t length,double timeout,QZCancelled cancelled,void *context,void *reply,size_t capacity,size_t *reply_length,int *submitted,int *kernel_error){
    const QZRouteIO io={NULL,system_now,system_open,system_configure,system_send,system_wait,system_receive,system_close};
    return qz_route_exchange_with_io(request,length,timeout,cancelled,context,reply,capacity,reply_length,submitted,kernel_error,&io);
}
