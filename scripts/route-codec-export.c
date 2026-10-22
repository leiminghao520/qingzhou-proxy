#include "QingzhouRoute.h"
#include <net/if.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <string.h>

typedef struct {const char *name,*dst,*gw;int family,bits,scoped,op,legacy;} Case;
int main(void){
    if(sizeof(struct rt_msghdr)!=92)return 2;
    const Case cases[]={
        {"ipv4-host","192.0.2.7","127.0.0.1",AF_INET,32,0,RTM_ADD,0},
        {"ipv4-network","192.0.2.0","127.0.0.1",AF_INET,24,0,RTM_ADD,0},
        {"ipv4-scoped","192.0.2.0","127.0.0.1",AF_INET,24,1,RTM_ADD,0},
        {"ipv6-host","2001:db8::7","::1",AF_INET6,128,0,RTM_ADD,0},
        {"ipv6-network","2001:db8::","::1",AF_INET6,64,0,RTM_ADD,0},
        {"default-get","0.0.0.0","",AF_INET,0,0,RTM_GET,0},
        {"ipv6-get","2001:db8::7","",AF_INET6,128,0,RTM_GET,0},
        {"linklocal-get","fe80::","",AF_INET6,128,0,RTM_GET,0},
        {"linklocal-scoped","fe80::","",AF_INET6,128,1,RTM_GET,0},
        {"legacy-delete","2001:db8::7","::1",AF_INET6,128,0,RTM_DELETE,1},
        {"host-delete","192.0.2.7","127.0.0.1",AF_INET,32,0,RTM_DELETE,0},
        {"direct","192.0.2.7","link",AF_INET,32,1,RTM_ADD,0},
        {"ipv6-direct","2001:db8::7","link",AF_INET6,128,0,RTM_ADD,0},
        {"ipv6-scoped-write","2001:db8::","fe80::1",AF_INET6,64,1,RTM_ADD,0},
        {"ipv6-default-get","::","",AF_INET6,0,0,RTM_GET,0},
        {"ipv4-default-add","0.0.0.0","127.0.0.1",AF_INET,0,0,RTM_ADD,0},
        {"ipv6-default-add","::","fe80::1",AF_INET6,0,0,RTM_ADD,0},
        {"ipv6-scoped-delete","fe80::7","fe80::1",AF_INET6,128,1,RTM_DELETE,0}
    };
    unsigned index=if_nametoindex("lo0");if(!index)return 3;
    for(size_t i=0;i<sizeof(cases)/sizeof(cases[0]);i++){
        Case c=cases[i];unsigned char data[2048];size_t size=0;char link[32];snprintf(link,sizeof(link),"link#%u",index);
        int error=qz_route_encode(c.op,c.dst,c.family,c.bits,!strcmp(c.gw,"link") ? link:c.gw,"lo0",c.scoped,c.legacy,123,456,data,sizeof(data),&size);
        if(error){fprintf(stderr,"编码失败 %s errno=%d\n",c.name,error);return 4;}
        printf("{\"name\":\"%s\",\"index\":%u,\"hex\":\"",c.name,index);
        for(size_t j=0;j<size;j++)printf("%02x",data[j]);printf("\"}\n");
    }
}
