//go:build !darwin && !ios

package mobile

func tunnelFD() int32 { return -1 }
