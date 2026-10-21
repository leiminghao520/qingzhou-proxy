import hashlib
from pathlib import Path
import json
import re
from urllib.parse import quote

import yaml


def _hy2_uri(username, server, port, password, sni, label):
    auth = f"{username}:{password}"
    return (
        f"hysteria2://{quote(auth, safe='')}@{server}:{int(port)}/"
        f"?sni={quote(sni, safe='')}#{quote(label, safe='')}"
    )


def _shadowrocket_config(server, port, auth, sni, label):
    # Shadowrocket's line-oriented format does not quote names. Keep the
    # display label readable while preventing delimiters/newlines from
    # changing the generated configuration structure.
    node_name = re.sub(r"[\r\n,=]+", "_", label).strip() or "HY2"
    return "\n".join(
        (
            "[General]",
            "ipv6 = false",
            "dns-server = 223.5.5.5, 119.29.29.29",
            "fallback-dns-server = 1.1.1.1, 8.8.8.8",
            "bypass-system = true",
            "skip-proxy = 127.0.0.1, localhost, *.local, 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16",
            "",
            "[Proxy]",
            f"{node_name} = hysteria2, {server}, {int(port)}, auth={auth}, peer={sni}, udp=1",
            "",
            "[Proxy Group]",
            f"PROXY = select, {node_name}",
            "",
            "[Rule]",
            "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
            "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
            "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
            "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
            "GEOIP,CN,DIRECT",
            "FINAL,PROXY",
            "",
        )
    )


def _mihomo_config(server, port, auth, sni, label):
    config = {
        "mixed-port": 7890,
        "allow-lan": False,
        "mode": "rule",
        "log-level": "info",
        "ipv6": False,
        "unified-delay": True,
        "tcp-concurrent": True,
        "profile": {"store-selected": True, "store-fake-ip": True},
        "dns": {
            "enable": True,
            "ipv6": False,
            "enhanced-mode": "fake-ip",
            "fake-ip-range": "198.18.0.1/16",
            "default-nameserver": ["223.5.5.5", "119.29.29.29"],
            "nameserver": [
                "https://dns.alidns.com/dns-query",
                "https://doh.pub/dns-query",
            ],
            "fallback": [
                "https://1.1.1.1/dns-query#PROXY",
                "https://8.8.8.8/dns-query#PROXY",
            ],
            "proxy-server-nameserver": [
                "https://dns.alidns.com/dns-query",
                "https://doh.pub/dns-query",
            ],
            "fallback-filter": {
                "geoip": True,
                "geoip-code": "CN",
                "domain": [
                    "+.google.com",
                    "+.googleapis.com",
                    "+.openai.com",
                    "+.chatgpt.com",
                    "+.github.com",
                    "+.youtube.com",
                ],
            },
        },
        "proxies": [
            {
                "name": label,
                "type": "hysteria2",
                "server": server,
                "port": int(port),
                "password": auth,
                "sni": sni,
                "skip-cert-verify": False,
                "udp": True,
            }
        ],
        "proxy-groups": [
            {"name": "PROXY", "type": "select", "proxies": [label, "DIRECT"]}
        ],
        "rules": [
            "IP-CIDR,10.0.0.0/8,DIRECT,no-resolve",
            "IP-CIDR,172.16.0.0/12,DIRECT,no-resolve",
            "IP-CIDR,192.168.0.0/16,DIRECT,no-resolve",
            "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
            "GEOSITE,cn,DIRECT",
            "GEOIP,CN,DIRECT,no-resolve",
            "MATCH,PROXY",
        ],
    }
    return yaml.safe_dump(config, allow_unicode=True, sort_keys=False)


def _sing_box_config(server, port, auth, sni, label):
    config = {
        "log": {"level": "info", "timestamp": True},
        "dns": {
            "servers": [
                {
                    "type": "udp",
                    "tag": "dns-cn",
                    "server": "223.5.5.5",
                    "server_port": 53,
                },
                {
                    "type": "tls",
                    "tag": "dns-global",
                    "server": "1.1.1.1",
                    "server_port": 853,
                    "tls": {"enabled": True, "server_name": "cloudflare-dns.com"},
                    "detour": "proxy",
                },
            ],
            "rules": [
                {
                    "rule_set": "geosite-cn",
                    "action": "route",
                    "server": "dns-cn",
                }
            ],
            "final": "dns-global",
        },
        "inbounds": [
            {
                "type": "mixed",
                "tag": "mixed-in",
                "listen": "127.0.0.1",
                "listen_port": 2080,
                "set_system_proxy": False,
            }
        ],
        "outbounds": [
            {
                "type": "hysteria2",
                "tag": "proxy",
                "server": server,
                "server_port": int(port),
                "password": auth,
                "tls": {"enabled": True, "server_name": sni},
            },
            {"type": "direct", "tag": "direct"},
        ],
        "route": {
            "rules": [
                {"action": "sniff"},
                {"protocol": "dns", "action": "hijack-dns"},
                {"ip_is_private": True, "outbound": "direct"},
                {
                    "rule_set": ["geosite-cn", "geoip-cn"],
                    "outbound": "direct",
                },
            ],
            "rule_set": [
                {
                    "type": "remote",
                    "tag": "geosite-cn",
                    "format": "binary",
                    "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
                    "download_detour": "proxy",
                    "update_interval": "1d",
                },
                {
                    "type": "remote",
                    "tag": "geoip-cn",
                    "format": "binary",
                    "url": "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
                    "download_detour": "proxy",
                    "update_interval": "1d",
                },
            ],
            "final": "proxy",
            "auto_detect_interface": True,
            "default_domain_resolver": "dns-cn",
        },
        "experimental": {"cache_file": {"enabled": True}},
    }
    return json.dumps(config, ensure_ascii=False, indent=2) + "\n"


def _qingzhou_config(username, server, port, password, sni, label):
    # 规则模板只包含配置和资产，设备密码在受令牌保护的订阅响应中动态生成。
    path = Path(__file__).resolve().with_name("qingzhou-default.json")
    content = path.read_bytes()
    if len(content) > 1024 * 1024:
        raise ValueError("qingzhou template exceeds size limit")
    template = json.loads(content)
    if template.get("version") != 1 or not template.get("rules"):
        raise ValueError("invalid qingzhou template")
    configuration = json.dumps(template, ensure_ascii=False, separators=(",", ":"))
    return json.dumps({
        "format": "qingzhou.subscription", "version": 1,
        "name": "轻舟 VPS 完整配置",
        "revision": hashlib.sha256(configuration.encode("utf-8")).hexdigest(),
        "configurationJSON": configuration,
        "nodes": [_hy2_uri(username, server, port, password, sni, label)],
    }, ensure_ascii=False, separators=(",", ":")) + "\n"


def render_subscription(kind, username, server, port, password, tls_sni=None, display_name=None):
    sni = tls_sni or server
    label = display_name or username
    auth = f"{username}:{password}"
    if kind == "qingzhou":
        return _qingzhou_config(username, server, port, password, sni, label)
    if kind == "hy2":
        return _hy2_uri(username, server, port, password, sni, label) + "\n"
    if kind == "shadowrocket":
        return _hy2_uri(username, server, port, password, sni, label) + "\n"
    if kind == "shadowrocket-full":
        return _shadowrocket_config(server, port, auth, sni, label)
    if kind == "mihomo":
        return _mihomo_config(server, port, auth, sni, label)
    if kind == "sing-box":
        return _sing_box_config(server, port, auth, sni, label)
    raise ValueError("unsupported subscription format")
