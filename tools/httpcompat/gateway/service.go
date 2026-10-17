package gateway

import (
 "encoding/json"
 "errors"
 "fmt"
 "net"
 "net/http"
 "strings"
 "sync"
 "time"
)

// Service 让移动扩展和桌面服务直接管理兼容入口的生命周期。
type Service struct {server *http.Server;mixed *mixedListener;gateway *gateway;once sync.Once;done chan struct{};failure error}
func Start(raw string)(*Service,error){
 if len(raw)>4*1024*1024{return nil,errors.New("兼容配置超过限制")}
 var config configuration;decoder:=json.NewDecoder(strings.NewReader(raw));decoder.DisallowUnknownFields();if e:=decoder.Decode(&config);e!=nil{return nil,errors.New("兼容配置格式无效")}
 seen:=map[int]bool{};for _,port:=range []int{config.ListenPort,config.CorePort,config.HTTPPort,config.ControlPort}{if port<1024||port>65535||seen[port]{return nil,errors.New("兼容端口冲突")};seen[port]=true}
 g,e:=prepare(config);if e!=nil{return nil,e};listener,e:=net.Listen("tcp",fmt.Sprintf("127.0.0.1:%d",config.ListenPort));if e!=nil{return nil,e}
 mixed:=newMixedListener(listener,config.CorePort);g.connections=mixed
 s:=&Service{server:&http.Server{Handler:g,ReadHeaderTimeout:10*time.Second,MaxHeaderBytes:65536},mixed:mixed,gateway:g,done:make(chan struct{})}
 go func(){err:=s.server.Serve(mixed);if err!=nil&&err!=http.ErrServerClosed&&err!=net.ErrClosed{s.failure=errors.New("兼容入口异常退出")};close(s.done)}()
 return s,nil
}
func(s *Service)Close()error{s.once.Do(func(){s.server.Close();s.mixed.Close();s.mixed.wait();s.gateway.control.CloseIdleConnections();for _,t:=range s.gateway.transports{t.CloseIdleConnections()}});return nil}
func(s *Service)Failed()bool{select{case <-s.done:return s.failure!=nil;default:return false}}
