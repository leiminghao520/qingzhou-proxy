package config

import (
	"errors"
	"net/netip"
	"strings"
)

func ValidateBypass(domains, cidrs []string) error {
	if len(domains) > 1000 || len(cidrs) > 1000 {
		return errors.New("绕行配置超过上限")
	}
	for _, domain := range domains {
		if len(domain) > 253 || domain != strings.ToLower(domain) || netipIsAddress(domain) {
			return errors.New("保护域名无效")
		}
		for _, label := range strings.Split(domain, ".") {
			if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
				return errors.New("保护域名无效")
			}
			for _, c := range label {
				if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
					return errors.New("保护域名无效")
				}
			}
		}
	}
	for _, cidr := range cidrs {
		p, err := netip.ParsePrefix(cidr)
		if err != nil || p != p.Masked() || p.Bits() == 0 {
			return errors.New("排除网段无效，不能排除全部流量")
		}
	}
	return nil
}
func netipIsAddress(s string) bool { _, e := netip.ParseAddr(s); return e == nil }

// RouteComplement 使用前缀拆分生成排除后的接管范围，兼容 Android 10 的 Builder。
func RouteComplement(routes, excludes []string) ([]string, error) {
	included := []netip.Prefix{}
	for _, raw := range routes {
		p, err := netip.ParsePrefix(raw)
		if err != nil {
			return nil, errors.New("接管路由无效")
		}
		included = append(included, p.Masked())
	}
	for _, raw := range excludes {
		excluded, err := netip.ParsePrefix(raw)
		if err != nil {
			return nil, errors.New("排除路由无效")
		}
		excluded = excluded.Masked()
		next := []netip.Prefix{}
		var subtract func(netip.Prefix)
		subtract = func(p netip.Prefix) {
			if p.Addr().BitLen() != excluded.Addr().BitLen() || !p.Overlaps(excluded) {
				next = append(next, p)
				return
			}
			if excluded.Bits() <= p.Bits() {
				return
			}
			a := netip.PrefixFrom(p.Addr(), p.Bits()+1)
			bytes := p.Addr().AsSlice()
			bit := p.Bits()
			bytes[bit/8] |= 1 << uint(7-bit%8)
			addr, _ := netip.AddrFromSlice(bytes)
			subtract(a)
			subtract(netip.PrefixFrom(addr, p.Bits()+1))
		}
		for _, p := range included {
			subtract(p)
			if len(next) > 10000 {
				return nil, errors.New("排除后路由超过上限")
			}
		}
		included = next
	}
	result := make([]string, 0, len(included))
	for _, p := range included {
		result = append(result, p.String())
	}
	return result, nil
}
