//go:build darwin || ios

package mobile

import "github.com/sagernet/sing-box/experimental/libbox"

func tunnelFD() int32 { return libbox.GetTunnelFileDescriptor() }
