#include "QingzhouRoute.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <limits.h>
#include <mach/mach_time.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/sysctl.h>
#include <unistd.h>

static size_t aligned_size(size_t length) {return length ? (length + sizeof(uint32_t)-1) & ~(sizeof(uint32_t)-1) : sizeof(uint32_t);}
void qz_route_free(void *bytes) {free(bytes);}
int qz_route_dump(void **bytes,size_t *length) {
    int mib[]={CTL_NET,PF_ROUTE,0,AF_UNSPEC,NET_RT_DUMP,0};
    *bytes=NULL;*length=0;
    // 大小查询与复制之间路由表可能增长，重试有界且不接受截断结果。
    for (int attempt=0;attempt<4;attempt++) {
        size_t size=0;
        if (sysctl(mib,6,NULL,&size,NULL,0)) return errno;
        if (size>64*1024*1024) return EOVERFLOW;
        void *data=malloc(size ? size:1);
        if (!data) return ENOMEM;
        size_t actual=size;
        if (!sysctl(mib,6,data,&actual,NULL,0)) {*bytes=data;*length=actual;return 0;}
        int error=errno;free(data);
        if (error!=ENOMEM) return error;
    }
    return EAGAIN;
}
static int prefix_length(const struct sockaddr *mask,int family,int host,int *bits) {
    int size=family==AF_INET ? 4:16,offset=family==AF_INET ? offsetof(struct sockaddr_in,sin_addr):offsetof(struct sockaddr_in6,sin6_addr);
    if (host) {*bits=size*8;return 0;}
    *bits=0;
    if (!mask) return 0;
    int zero=0;
    for (int index=0;index<size;index++) {
        unsigned char value=offset+index<mask->sa_len ? ((const unsigned char *)mask)[offset+index]:0;
        for (int bit=7;bit>=0;bit--) {
            if (value & (1u<<bit)) {if (zero) return EPROTO;(*bits)++;} else zero=1;
        }
    }
    return 0;
}
static int decode_one(const struct rt_msghdr *header,size_t size,QZRouteRow *row,int *present) {
    const unsigned char *start=(const unsigned char *)header,*cursor=start+sizeof(*header),*end=start+size;
    const struct sockaddr *addresses[RTAX_MAX]={0};
    *present=0;
    for (int index=0;index<RTAX_MAX;index++) if (header->rtm_addrs & (1<<index)) {
        if ((size_t)(end-cursor)<2) return EPROTO;
        const struct sockaddr *address=(const struct sockaddr *)cursor;
        size_t step=aligned_size(address->sa_len);
        if (step>(size_t)(end-cursor)) return EPROTO;
        addresses[index]=address;cursor+=step;
    }
    const struct sockaddr *destination=addresses[RTAX_DST],*gateway=addresses[RTAX_GATEWAY];
    if (!destination || (destination->sa_family!=AF_INET && destination->sa_family!=AF_INET6)) return 0;
    int family=destination->sa_family;
    if (destination->sa_len<(family==AF_INET ? sizeof(struct sockaddr_in):sizeof(struct sockaddr_in6))) return EPROTO;
    memset(row,0,sizeof(*row));row->family=family;row->flags=header->rtm_flags;row->interface_index=header->rtm_index;
    const struct sockaddr *ifp=addresses[RTAX_IFP];
    if (!row->interface_index && ifp && ifp->sa_family==AF_LINK && ifp->sa_len>=offsetof(struct sockaddr_dl,sdl_data)) row->interface_index=((const struct sockaddr_dl *)ifp)->sdl_index;
    if (!row->interface_index || !if_indextoname(row->interface_index,row->interface_name)) return ENXIO;
    if (family==AF_INET) {
        if (!inet_ntop(family,&((const struct sockaddr_in *)destination)->sin_addr,row->destination,sizeof(row->destination))) return errno;
    } else {
        struct in6_addr address=((const struct sockaddr_in6 *)destination)->sin6_addr;
        // KAME 将链路接口编号放在地址中；作用域单独保留，地址本体不能携带接口编号。
        if (IN6_IS_ADDR_LINKLOCAL(&address) || IN6_IS_ADDR_MC_LINKLOCAL(&address)) address.s6_addr[2]=address.s6_addr[3]=0;
        if (!inet_ntop(family,&address,row->destination,sizeof(row->destination))) return errno;
    }
    int error=prefix_length(addresses[RTAX_NETMASK],family,header->rtm_flags & RTF_HOST,&row->prefix_length);
    if (error) return error;
    if (!(header->rtm_flags & RTF_GATEWAY)) snprintf(row->gateway,sizeof(row->gateway),"link#%u",row->interface_index);
    else if (gateway && gateway->sa_family==AF_INET && gateway->sa_len>=sizeof(struct sockaddr_in)) inet_ntop(AF_INET,&((const struct sockaddr_in *)gateway)->sin_addr,row->gateway,sizeof(row->gateway));
    else if (gateway && gateway->sa_family==AF_INET6 && gateway->sa_len>=sizeof(struct sockaddr_in6)) {
        struct in6_addr address=((const struct sockaddr_in6 *)gateway)->sin6_addr;
        if (IN6_IS_ADDR_LINKLOCAL(&address)) address.s6_addr[2]=address.s6_addr[3]=0;
        inet_ntop(AF_INET6,&address,row->gateway,sizeof(row->gateway));
        // 链路本地网关需保留出口作用域，才能可靠地重新写入同一路由。
        if (IN6_IS_ADDR_LINKLOCAL(&address)) {size_t n=strlen(row->gateway);snprintf(row->gateway+n,sizeof(row->gateway)-n,"%%%s",row->interface_name);}
    } else return EPROTO;
    *present=1;return 0;
}
int qz_route_decode(const void *bytes,size_t length,QZRouteRow *rows,size_t capacity,size_t *count) {
    const unsigned char *cursor=bytes,*end=cursor+length;*count=0;
    while (cursor<end) {
        if ((size_t)(end-cursor)<sizeof(struct rt_msghdr)) return EPROTO;
        struct rt_msghdr header;memcpy(&header,cursor,sizeof(header));
        if (header.rtm_msglen<sizeof(header) || header.rtm_msglen>(size_t)(end-cursor) || header.rtm_version!=RTM_VERSION) return EPROTO;
        QZRouteRow row;int present=0;
        // 路由消息由内核按字长对齐；先复制头部，剩余地址只通过已检查的范围访问。
        int error=decode_one((const struct rt_msghdr *)cursor,header.rtm_msglen,&row,&present);
        if (error) return error;
        if (present) {if (rows && *count<capacity) rows[*count]=row;(*count)++;}
        cursor+=header.rtm_msglen;
    }
    return rows && *count>capacity ? ENOBUFS:0;
}
static int ip_sockaddr(const char *text,int family,unsigned index,int allow_unscoped,void *out,size_t *length) {
    if (family==AF_INET) {
        struct sockaddr_in *a=out;memset(a,0,sizeof(*a));a->sin_len=sizeof(*a);a->sin_family=family;
        if (inet_pton(family,text,&a->sin_addr)!=1) return EINVAL;*length=sizeof(*a);return 0;
    }
    if (family!=AF_INET6) return EAFNOSUPPORT;
    struct sockaddr_in6 *a=out;memset(a,0,sizeof(*a));a->sin6_len=sizeof(*a);a->sin6_family=family;
    char numeric[64];if (strlen(text)>=sizeof(numeric)) return EINVAL;strcpy(numeric,text);
    char *scope=strchr(numeric,'%');if(scope){*scope++=0;unsigned supplied=if_nametoindex(scope);if (!supplied) return ENXIO;if(index && supplied!=index) return EINVAL;index=supplied;}
    if(inet_pton(family,numeric,&a->sin6_addr)!=1)return EINVAL;
    // 只读查询允许由内核选择作用域，写入及网关编码仍需已确认的接口。
    if(IN6_IS_ADDR_LINKLOCAL(&a->sin6_addr)) {if(!index && !allow_unscoped)return EINVAL;a->sin6_scope_id=index;a->sin6_addr.s6_addr[2]=(index>>8)&255;a->sin6_addr.s6_addr[3]=index&255;}
    *length=sizeof(*a);return 0;
}
static int append(void *bytes,size_t capacity,size_t *length,const void *address,size_t size) {
    size_t step=aligned_size(size);if(*length>capacity || step>capacity-*length)return ENOBUFS;
    memset((char *)bytes+*length,0,step);memcpy((char *)bytes+*length,address,size);*length+=step;return 0;
}
int qz_route_encode(int operation,const char *destination,int family,int bits,const char *gateway,const char *interface_name,int scoped,int legacy,int pid,int sequence,void *bytes,size_t capacity,size_t *length) {
    if(operation!=RTM_GET && operation!=RTM_ADD && operation!=RTM_DELETE)return EINVAL;
    if(legacy && (operation!=RTM_DELETE || family!=AF_INET6 || bits!=128))return EINVAL;
    int max=family==AF_INET ? 32:family==AF_INET6 ? 128:-1;
    if(bits<0 || bits>max || capacity<sizeof(struct rt_msghdr))return EINVAL;
    unsigned index=interface_name && *interface_name ? if_nametoindex(interface_name):0;
    if(interface_name && *interface_name && !index)return ENXIO;
    if(index>UINT16_MAX)return EOVERFLOW;
    if(scoped && !index)return EINVAL;
    struct rt_msghdr header;memset(&header,0,sizeof(header));header.rtm_version=RTM_VERSION;header.rtm_type=operation;
    header.rtm_pid=pid;header.rtm_seq=sequence;header.rtm_index=scoped ? index:0;header.rtm_addrs=RTA_DST;
    header.rtm_flags=RTF_UP|(scoped ? RTF_IFSCOPE:0);
    if(operation==RTM_GET){header.rtm_addrs|=RTA_IFP;if(bits<max)header.rtm_addrs|=RTA_NETMASK;}
    if(operation!=RTM_GET){header.rtm_flags|=RTF_STATIC;if(bits==max && !legacy)header.rtm_flags|=RTF_HOST;header.rtm_addrs|=RTA_GATEWAY;if(!(header.rtm_flags & RTF_HOST))header.rtm_addrs|=RTA_NETMASK;}
    unsigned char address[sizeof(struct sockaddr_in6)];size_t n=0;int error=ip_sockaddr(destination,family,scoped ? index:0,operation==RTM_GET,address,&n);if(error)return error;
    *length=sizeof(header);if((error=append(bytes,capacity,length,address,n)))return error;
    if(operation!=RTM_GET){
        if(!gateway || !*gateway)return EINVAL;
        if(!strncmp(gateway,"link#",5)){
            char *end=NULL;unsigned long link=strtoul(gateway+5,&end,10);if(!end || *end || !index || link!=index)return EINVAL;
            // 与系统 route -interface 一致，使用真实链路地址，不能伪造空接口描述。
            struct ifaddrs *list=NULL;if(getifaddrs(&list))return errno;
            const struct sockaddr *link_address=NULL;
            for(struct ifaddrs *p=list;p;p=p->ifa_next)if(p->ifa_addr && p->ifa_addr->sa_family==AF_LINK && !strcmp(p->ifa_name,interface_name)){link_address=p->ifa_addr;break;}
            if(!link_address){freeifaddrs(list);return ENXIO;}
            error=append(bytes,capacity,length,link_address,link_address->sa_len);freeifaddrs(list);if(error)return error;
        }else{header.rtm_flags|=RTF_GATEWAY;if((error=ip_sockaddr(gateway,family,index,0,address,&n)))return error;if((error=append(bytes,capacity,length,address,n)))return error;}
    }
    if(header.rtm_addrs & RTA_NETMASK){
            memset(address,0,sizeof(address));size_t offset=family==AF_INET ? offsetof(struct sockaddr_in,sin_addr):offsetof(struct sockaddr_in6,sin6_addr);
            n=family==AF_INET ? sizeof(struct sockaddr_in):sizeof(struct sockaddr_in6);address[0]=n;address[1]=family;
            int mask_bits=legacy ? 0:bits;for(int i=0;i<max/8;i++){int kept=mask_bits-i*8;if(kept<0)kept=0;if(kept>8)kept=8;address[offset+i]=kept ? (255u<<(8-kept)) & 255:0;}
            if((error=append(bytes,capacity,length,address,n)))return error;
    }
    if(header.rtm_addrs & RTA_IFP){
        struct sockaddr_dl dl;memset(&dl,0,sizeof(dl));dl.sdl_len=sizeof(dl);dl.sdl_family=AF_LINK;
        if((error=append(bytes,capacity,length,&dl,sizeof(dl))))return error;
    }
    if(*length>UINT16_MAX)return EOVERFLOW;header.rtm_msglen=*length;memcpy(bytes,&header,sizeof(header));return qz_route_validate(bytes,*length);
}
int qz_interface_addresses(char **text,size_t *length) {
    struct ifaddrs *list=NULL;if(getifaddrs(&list))return errno;
    size_t capacity=256*1024,used=0;char *output=calloc(1,capacity);if(!output){freeifaddrs(list);return ENOMEM;}
    for(struct ifaddrs *p=list;p;p=p->ifa_next){
        if(!p->ifa_addr)continue;int family=p->ifa_addr->sa_family;if(family!=AF_INET && family!=AF_INET6)continue;
        char address[INET6_ADDRSTRLEN];const void *value=family==AF_INET ? (const void *)&((struct sockaddr_in *)p->ifa_addr)->sin_addr:(const void *)&((struct sockaddr_in6 *)p->ifa_addr)->sin6_addr;
        if(!inet_ntop(family,value,address,sizeof(address)))continue;
        int n=snprintf(output+used,capacity-used,"%s %s\n",p->ifa_name,address);if(n<0 || (size_t)n>=capacity-used){free(output);freeifaddrs(list);return EOVERFLOW;}used+=n;
    }
    freeifaddrs(list);*text=output;*length=used;return 0;
}
