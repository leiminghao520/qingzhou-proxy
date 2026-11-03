#include "QingzhouRoute.h"
#include <arpa/inet.h>
#include <assert.h>
#include <errno.h>
#include <math.h>
#include <net/if_dl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// 参考请求按 Darwin 公开 ABI 独立构造，不调用被测编码器，也不打开系统 socket。
static unsigned char request[256];static size_t request_size;
static void reference_request(void){
    memset(request,0,sizeof(request));struct rt_msghdr h={0};
    h.rtm_msglen=sizeof(h)+2*sizeof(struct sockaddr_in);h.rtm_version=RTM_VERSION;h.rtm_type=RTM_ADD;
    h.rtm_flags=RTF_UP|RTF_STATIC|RTF_HOST|RTF_GATEWAY;h.rtm_addrs=RTA_DST|RTA_GATEWAY;h.rtm_pid=123;h.rtm_seq=456;
    memcpy(request,&h,sizeof(h));struct sockaddr_in dst={0},gw={0};dst.sin_len=gw.sin_len=sizeof(dst);dst.sin_family=gw.sin_family=AF_INET;
    inet_pton(AF_INET,"192.0.2.7",&dst.sin_addr);inet_pton(AF_INET,"127.0.0.1",&gw.sin_addr);
    memcpy(request+sizeof(h),&dst,sizeof(dst));memcpy(request+sizeof(h)+sizeof(dst),&gw,sizeof(gw));request_size=h.rtm_msglen;
}
typedef struct {double time;int opened,closed,configured,sends,waits,reads,mode,cancel_after,configure_error;struct rt_msghdr ack;} Fake;
static double now(void *context){Fake *f=context;f->time+=0.0001;return f->time;}
static int open_socket(void *context){Fake *f=context;f->opened++;if(f->mode==10){errno=EMFILE;return -1;}return 77;}
static int configure(void *context,int fd){assert(fd==77);Fake *f=context;f->configured++;if(f->configure_error){errno=EACCES;return -1;}return 0;}
static long send_packet(void *context,int fd,const void *data,size_t n){
    assert(fd==77 && n==request_size && !memcmp(data,request,n));Fake *f=context;f->sends++;
    if(f->mode==1 || (f->mode==2 && f->sends<3)){errno=EAGAIN;return -1;}
    if(f->mode==3 && f->sends==1){errno=EINTR;return -1;}
    if(f->mode==4)return n-1;
    if(f->mode==5){errno=EPERM;return -1;}
    return n;
}
static int wait_ready(void *context,int fd,int sending,int ms){
    assert(fd==77 && ms>=1 && ms<=50);Fake *f=context;f->waits++;f->time+=ms/1000.0;
    if(f->mode==6 && f->waits==1){errno=EINTR;return -1;}
    if(f->mode==7)return 0;
    if(f->mode==8){errno=EIO;return -1;}
    if(f->mode==9)f->time+=20;
    if(sending)assert(f->mode==1 || f->mode==2);
    return 1;
}
static long receive_packet(void *context,int fd,void *data,size_t capacity){
    assert(fd==77 && capacity>=sizeof(struct rt_msghdr));Fake *f=context;f->reads++;
    if(f->mode==11 && f->reads<3){errno=f->reads==1 ? EAGAIN:EINTR;return -1;}
    if(f->mode==12){errno=ECONNRESET;return -1;}
    if(f->mode==13)return capacity+1;
    if(f->mode==14)return 3;
    if(f->mode==20 && f->reads==1){unsigned char event[20]={20,0,RTM_VERSION,RTM_IFINFO};memcpy(data,event,sizeof(event));return sizeof(event);}
    struct rt_msghdr h=f->ack;
    if(f->mode==15 && f->reads==1)h.rtm_pid++;
    if(f->mode==16 && f->reads==1)h.rtm_seq++;
    if(f->mode==17)h.rtm_type=RTM_DELETE;
    if(f->mode==18)h.rtm_version++;
    if(f->mode==19)h.rtm_errno=EEXIST;
    memcpy(data,&h,sizeof(h));return sizeof(h);
}
static void close_socket(void *context,int fd){assert(fd==77);((Fake *)context)->closed++;}
static int cancelled(void *context){Fake *f=context;return f->cancel_after==1 || (f->cancel_after==2 && f->sends>0) || (f->cancel_after==3 && f->waits>0);}
static int checks;
static void check(int value){checks++;assert(value);}
static int run(Fake *f,int *submitted,double timeout){
    f->ack=(struct rt_msghdr){0};f->ack.rtm_msglen=sizeof(f->ack);f->ack.rtm_version=RTM_VERSION;f->ack.rtm_type=RTM_ADD;f->ack.rtm_pid=123;f->ack.rtm_seq=456;
    QZRouteIO io={f,now,open_socket,configure,send_packet,wait_ready,receive_packet,close_socket};unsigned char reply[256];size_t length;int kernel;
    int code=qz_route_exchange_with_io(request,request_size,timeout,cancelled,f,reply,sizeof(reply),&length,submitted,&kernel,&io);
    check(f->closed==f->opened-(f->mode==10 ? 1:0));
    if(code==0)check(length==sizeof(struct rt_msghdr) && kernel==(f->mode==19 ? EEXIST:0));
    else check(length==0);
    return code;
}
int main(void){
    reference_request();check(qz_route_validate(request,request_size)==0);
    for(int mode=0;mode<=20;mode++){
        Fake f={0};f.mode=mode;int submitted=-1;
        int code=run(&f,&submitted,0.2);
        int expected=0;
        if(mode==1 || mode==7 || mode==9)expected=ETIMEDOUT;
        if(mode==4 || mode==8)expected=EIO;
        if(mode==5)expected=EPERM;if(mode==10)expected=EMFILE;
        if(mode==12)expected=ECONNRESET;if(mode==13)expected=ENOBUFS;
        if(mode==14 || mode==17 || mode==18)expected=EPROTO;
        check(code==expected);check(submitted==!(mode==1 || mode==5 || mode==10));
        if(mode==4)check(f.sends==1 && f.reads==0);
        if(mode==1)check(f.reads==0 && f.time<0.3);
        if(mode==9)check(f.reads==0);
        if(mode==15 || mode==16 || mode==20)check(f.sends==1 && f.reads==2);
    }
    for(int stage=1;stage<=3;stage++){Fake f={0};f.cancel_after=stage;int submitted=-1;check(run(&f,&submitted,0.2)==ECANCELED);check(submitted==(stage==1 ? 0:1));}
    Fake denied={0};denied.configure_error=1;int submitted;check(run(&denied,&submitted,0.2)==EACCES && !submitted && !denied.sends);
    for(int i=0;i<3;i++){Fake f={0};double budget=i==0 ? -1:i==1 ? NAN:0;check(run(&f,&submitted,budget)==EINVAL && !f.opened);}
    unsigned char original[256];memcpy(original,request,sizeof(request));struct rt_msghdr *h=(void *)request;
    h->rtm_addrs|=RTA_IFP;
    Fake invalid={0};check(run(&invalid,&submitted,0.2)!=0 && !invalid.opened && !submitted);
    memcpy(request,original,sizeof(request));
    for(size_t i=0;i<request_size;i++)check(qz_route_validate(request,i)!=0);
    h->rtm_index=1;check(qz_route_validate(request,request_size)!=0);h->rtm_index=0;
    h->rtm_flags|=RTF_LLINFO;check(qz_route_validate(request,request_size)!=0);h->rtm_flags&=~RTF_LLINFO;
    h->rtm_seq=0;check(qz_route_validate(request,request_size)!=0);h->rtm_seq=456;
    check(qz_route_validate(request,request_size)==0);
    // 深层字段变异保留合法头部，使截断地址和作用域检查真正可达。
    for(size_t at=0;at<request_size;at++)for(int value=0;value<3;value++){
        unsigned char *changed=malloc(request_size);memcpy(changed,request,request_size);
        changed[at]=value==0 ? 0:value==1 ? 1:255;(void)qz_route_validate(changed,request_size);free(changed);
    }
    for(size_t size=sizeof(struct rt_msghdr);size<request_size;size++){
        unsigned char *changed=malloc(size);memcpy(changed,request,size);((struct rt_msghdr *)changed)->rtm_msglen=size;
        (void)qz_route_validate(changed,size);free(changed);
    }
    unsigned random=17;unsigned char fuzz[256];
    for(int iteration=0;iteration<20000;iteration++){
        for(size_t j=0;j<sizeof(fuzz);j++){random=random*1664525u+1013904223u;fuzz[j]=random>>24;}
        size_t n=random%sizeof(fuzz);int kernel=0;
        (void)qz_route_validate(fuzz,n);(void)qz_route_match(fuzz,n,RTM_ADD,123,456,&kernel);
    }
    printf("ROUTE_TRANSPORT_OFFLINE_OK assertions=%d realSockets=0\n",checks);
}
