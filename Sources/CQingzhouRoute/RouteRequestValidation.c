#include "QingzhouRoute.h"
#include <errno.h>
#include <net/if_dl.h>
#include <netinet/in.h>
#include <string.h>

// 此解析器独立于编码器，采用偏移和复制读取，任何不确定字段在系统调用前拒绝。
int qz_route_validate(const void *bytes,size_t length) {
    if(!bytes || length<sizeof(struct rt_msghdr) || length>2048)return EINVAL;
    struct rt_msghdr h;memcpy(&h,bytes,sizeof(h));
    int get=h.rtm_type==RTM_GET;
    if(!get && h.rtm_type!=RTM_ADD && h.rtm_type!=RTM_DELETE)return EINVAL;
    if(h.rtm_msglen!=length || h.rtm_version!=RTM_VERSION || h.rtm_pid<=0 || h.rtm_seq<=0 || h.rtm_errno || h.rtm_inits || h.rtm_rmx.rmx_locks)return EINVAL;
    unsigned allowed=RTF_UP|RTF_IFSCOPE|(get ? 0:RTF_STATIC|RTF_GATEWAY|RTF_HOST);
    if((h.rtm_flags & ~allowed) || !(h.rtm_flags & RTF_UP) || (!get && !(h.rtm_flags & RTF_STATIC)))return EINVAL;
    if((h.rtm_flags & RTF_IFSCOPE) ? !h.rtm_index:h.rtm_index!=0)return EINVAL;
    unsigned allowed_addresses=RTA_DST|RTA_NETMASK|(get ? RTA_IFP:RTA_GATEWAY);
    if((h.rtm_addrs & ~allowed_addresses) || !(h.rtm_addrs & RTA_DST) || (get ? !(h.rtm_addrs & RTA_IFP):!(h.rtm_addrs & RTA_GATEWAY)))return EINVAL;
    const unsigned char *p=bytes,*address[RTAX_MAX]={0};size_t sizes[RTAX_MAX]={0},offset=sizeof(h);
    for(int bit=0;bit<RTAX_MAX;bit++)if(h.rtm_addrs & (1<<bit)){
        if(length-offset<2)return EPROTO;
        size_t n=p[offset],step=n ? (n+3)&~(size_t)3:4;
        if(n<2 || step>length-offset)return EPROTO;
        address[bit]=p+offset;sizes[bit]=n;
        for(size_t i=n;i<step;i++)if(p[offset+i])return EPROTO;
        offset+=step;
    }
    if(offset!=length)return EPROTO;
    int family=address[RTAX_DST][1],max=family==AF_INET ? 32:family==AF_INET6 ? 128:0;
    size_t expected=family==AF_INET ? sizeof(struct sockaddr_in):sizeof(struct sockaddr_in6),ip_offset=family==AF_INET ? 4:8;
    if(!max || sizes[RTAX_DST]!=expected)return EINVAL;
    // 请求地址只携带 IP 与必要作用域，禁止端口、流标签和未定义填充进入内核。
    for(int slot=RTAX_DST;slot<=RTAX_GATEWAY;slot++)if(address[slot] && address[slot][1]==family){
        if(sizes[slot]!=expected)return EINVAL;
        const unsigned char *ip=address[slot];
        if(ip[2] || ip[3])return EINVAL;
        if(family==AF_INET){for(int i=8;i<16;i++)if(ip[i])return EINVAL;}
        else {
            for(int i=4;i<8;i++)if(ip[i])return EINVAL;
            uint32_t scope;memcpy(&scope,ip+24,4);
            int link=ip[8]==0xfe && (ip[9]&0xc0)==0x80;
            if(link){
                unsigned embedded=(unsigned)ip[10]*256+ip[11];
                if(scope!=embedded || (!get && !scope) || ((h.rtm_flags & RTF_IFSCOPE) && scope!=h.rtm_index))return EINVAL;
                if(slot==RTAX_DST && !(h.rtm_flags & RTF_IFSCOPE) && scope)return EINVAL;
            } else if(scope)return EINVAL;
        }
    }
    if(get){
        struct sockaddr_dl dl;
        if(sizes[RTAX_IFP]!=sizeof(dl))return EINVAL;
        memcpy(&dl,address[RTAX_IFP],sizeof(dl));
        if(dl.sdl_family!=AF_LINK || dl.sdl_index || dl.sdl_type || dl.sdl_nlen || dl.sdl_alen || dl.sdl_slen)return EINVAL;
        for(size_t i=offsetof(struct sockaddr_dl,sdl_data);i<sizeof(dl);i++)if(address[RTAX_IFP][i])return EINVAL;
    }else{
        const unsigned char *gw=address[RTAX_GATEWAY];
        if(h.rtm_flags & RTF_GATEWAY){if(gw[1]!=family || sizes[RTAX_GATEWAY]!=expected)return EINVAL;}
        else {
            if(gw[1]!=AF_LINK || sizes[RTAX_GATEWAY]<offsetof(struct sockaddr_dl,sdl_data))return EINVAL;
            unsigned short index;memcpy(&index,gw+2,2);
            if(!index || !gw[5] || (size_t)gw[5]+gw[6]+gw[7]>sizes[RTAX_GATEWAY]-8)return EINVAL;
            if((h.rtm_flags & RTF_IFSCOPE) && index!=h.rtm_index)return EINVAL;
        }
        if((h.rtm_flags & RTF_HOST) && address[RTAX_NETMASK])return EINVAL;
        if(!(h.rtm_flags & RTF_HOST) && !address[RTAX_NETMASK])return EINVAL;
    }
    int bits=0,zero=0;
    if(address[RTAX_NETMASK]){
        if(sizes[RTAX_NETMASK]!=expected || address[RTAX_NETMASK][1]!=family)return EINVAL;
        for(int i=0;i<max/8;i++)for(int bit=7;bit>=0;bit--){
            if(address[RTAX_NETMASK][ip_offset+i] & (1<<bit)){if(zero)return EINVAL;bits++;}else zero=1;
        }
        // 唯一保留的非规范前缀是旧记录的 IPv6 零掩码删除；新写入一律要求规范地址。
        int legacy=h.rtm_type==RTM_DELETE && family==AF_INET6 && bits==0;
        if(!legacy)for(int i=0;i<max/8;i++)if(address[RTAX_DST][ip_offset+i] & ~address[RTAX_NETMASK][ip_offset+i])return EINVAL;
    }
    return 0;
}
