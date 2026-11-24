package main

import (
	"bufio"
	"encoding/json"
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type systemMetrics struct {
	CPUPercent float64 `json:"cpu_percent"`
	MemTotal uint64 `json:"memory_total_bytes"`
	MemAvailable uint64 `json:"memory_available_bytes"`
	MemUsedPct float64 `json:"memory_used_percent"`
	DiskTotal uint64 `json:"disk_total_bytes"`
	DiskUsed uint64 `json:"disk_used_bytes"`
	DiskUsedPct float64 `json:"disk_used_percent"`
	PanelGoroutines int `json:"panel_goroutines"`
}
type diagnosticCheck struct { Name string `json:"name"`; Status string `json:"status"`; Detail string `json:"detail"`; Latency int64 `json:"latency_ms,omitempty"` }
type diagnosticsResponse struct { CheckedAt time.Time `json:"checked_at"`; Checks []diagnosticCheck `json:"checks"` }

func (a *application) relayRequest(ctx context.Context,path string)(int,string,time.Duration,error){
	req,err:=http.NewRequestWithContext(ctx,http.MethodGet,"http://relay:9090/relay"+path,nil);if err!=nil{return 0,"",0,err}
	start:=time.Now();resp,err:=a.monitorClient.Do(req);latency:=time.Since(start);if err!=nil{return 0,"",latency,err};defer resp.Body.Close()
	body,err:=io.ReadAll(io.LimitReader(resp.Body,2<<20));return resp.StatusCode,string(body),latency,err
}
func (a *application) backendStats(ctx context.Context)(string,error){
	req,err:=http.NewRequestWithContext(ctx,http.MethodGet,"http://relay:9090/stats",nil);if err!=nil{return "",err}
	resp,err:=a.monitorClient.Do(req);if err!=nil{return "",err};defer resp.Body.Close()
	if resp.StatusCode!=http.StatusOK{return "",fmt.Errorf("backend stats HTTP %d",resp.StatusCode)}
	body,err:=io.ReadAll(io.LimitReader(resp.Body,1<<20));return string(body),err
}
func (a *application) diagnostics(w http.ResponseWriter,r *http.Request){
	if r.Method!=http.MethodGet{http.Error(w,"method not allowed",405);return}
	ctx,cancel:=context.WithTimeout(r.Context(),5*time.Second);defer cancel()
	result:=diagnosticsResponse{CheckedAt:time.Now().UTC()}
	// Verify the public HTTPS edge (DNS, TCP, TLS certificate and HTTP response).
	// This is a transport-edge check, not a substitute for a real Telegram client handshake.
	var public struct { PublicHostname string `json:"public_hostname"` }
	configData, configErr := os.ReadFile(a.config)
	transportCheck := diagnosticCheck{Name:"webproxy_https",Status:"error"}
	if configErr == nil && json.Unmarshal(configData,&public)==nil && strings.TrimSpace(public.PublicHostname)!="" {
		req, reqErr := http.NewRequestWithContext(ctx,http.MethodGet,"https://"+public.PublicHostname+"/",nil)
		if reqErr == nil {
			started:=time.Now()
			resp, requestErr:=a.monitorClient.Do(req)
			transportCheck.Latency=time.Since(started).Milliseconds()
			if requestErr == nil {
				_ = resp.Body.Close()
				if resp.StatusCode < 500 { transportCheck.Status="ok"; transportCheck.Detail=fmt.Sprintf("HTTPS/TLS доступен, HTTP %d",resp.StatusCode) } else { transportCheck.Detail=fmt.Sprintf("публичный HTTPS вернул HTTP %d",resp.StatusCode) }
			} else { transportCheck.Detail="публичный HTTPS/TLS недоступен" }
		} else { transportCheck.Detail="не удалось сформировать HTTPS-проверку" }
	} else { transportCheck.Detail="не задан public_hostname" }
	result.Checks=append(result.Checks,transportCheck)
	for _,ep:=range []struct{name,path,expected string}{{"relay_health","/healthz","ok"},{"relay_ready","/readyz","ready"}}{
		status,body,latency,err:=a.relayRequest(ctx,ep.path);check:=diagnosticCheck{Name:ep.name,Status:"error",Latency:latency.Milliseconds()}
		if err!=nil{check.Detail="relay недоступен"}else if status==200&&strings.TrimSpace(body)==ep.expected{check.Status="ok";check.Detail="доступен"}else{check.Detail=fmt.Sprintf("HTTP %d",status)}
		result.Checks=append(result.Checks,check)
	}
	stats,err:=a.backendStats(ctx);mt:=diagnosticCheck{Name:"backend_stats",Status:"error"}
	if err!=nil{mt.Detail="статистика внутреннего backend недоступна"}else if strings.TrimSpace(stats)==""{mt.Detail="пустой ответ"}else{mt.Status="ok";mt.Detail="статистика получена"}
	result.Checks=append(result.Checks,mt)
	if _,err:=os.Stat(a.profiles);err!=nil{result.Checks=append(result.Checks,diagnosticCheck{Name:"profiles_file",Status:"error",Detail:"файл профилей недоступен"})}else{result.Checks=append(result.Checks,diagnosticCheck{Name:"profiles_file",Status:"ok",Detail:"файл профилей доступен"})}
	jsonResponse(w,result)
}
func (a *application) metrics(w http.ResponseWriter,r *http.Request){
	if r.Method!=http.MethodGet{http.Error(w,"method not allowed",405);return}
	ctx,cancel:=context.WithTimeout(r.Context(),5*time.Second);defer cancel()
	out:=map[string]any{"system":readSystemMetrics(),"sampled_at":time.Now().UTC()}
	_,relay,_,err:=a.relayRequest(ctx,"/metrics");if err==nil{out["relay"]=parsePrometheus(relay)}else{out["relay_error"]="relay metrics unavailable"}
	mt,err:=a.backendStats(ctx);if err==nil{out["backend"]=parseTabStats(mt)}else{out["backend_error"]="backend metrics unavailable"}
	jsonResponse(w,out)
}
func readSystemMetrics()systemMetrics{
	m:=systemMetrics{PanelGoroutines:runtime.NumGoroutine(),CPUPercent:readCPUPercent()}
	if f,err:=os.Open("/proc/meminfo");err==nil{
		sc:=bufio.NewScanner(f);vals:=map[string]uint64{}
		for sc.Scan(){fields:=strings.Fields(sc.Text());if len(fields)>1{if v,e:=strconv.ParseUint(fields[1],10,64);e==nil{vals[strings.TrimSuffix(fields[0],":")]=v*1024}}};_ = f.Close()
		m.MemTotal=vals["MemTotal"];m.MemAvailable=vals["MemAvailable"];if m.MemTotal>0&&m.MemAvailable<=m.MemTotal{m.MemUsedPct=float64(m.MemTotal-m.MemAvailable)/float64(m.MemTotal)*100}
	}
	var fs syscall.Statfs_t;if err:=syscall.Statfs("/",&fs);err==nil{m.DiskTotal=fs.Blocks*uint64(fs.Bsize);m.DiskUsed=(fs.Blocks-fs.Bfree)*uint64(fs.Bsize);if m.DiskTotal>0{m.DiskUsedPct=float64(m.DiskUsed)/float64(m.DiskTotal)*100}}
	return m
}
func readCPUPercent()float64{
	read:=func()(uint64,uint64){f,err:=os.Open("/proc/stat");if err!=nil{return 0,0};defer f.Close();sc:=bufio.NewScanner(f);if !sc.Scan(){return 0,0};fields:=strings.Fields(sc.Text());if len(fields)<5{return 0,0};var total,idle uint64;for i,v:=range fields[1:]{n,e:=strconv.ParseUint(v,10,64);if e!=nil{continue};total+=n;if i==3||i==4{idle+=n}};return total,idle}
	firstTotal,firstIdle:=read();time.Sleep(120*time.Millisecond);secondTotal,secondIdle:=read();if secondTotal<=firstTotal{return 0};delta:=secondTotal-firstTotal;idle:=secondIdle-firstIdle;if delta==0{return 0};return float64(delta-idle)/float64(delta)*100
}
func parsePrometheus(body string)map[string]float64{
	out:=map[string]float64{};sc:=bufio.NewScanner(strings.NewReader(body))
	for sc.Scan(){line:=strings.TrimSpace(sc.Text());if line==""||strings.HasPrefix(line,"#"){continue};f:=strings.Fields(line);if len(f)<2||strings.Contains(f[0],"{"){continue};if v,e:=strconv.ParseFloat(f[1],64);e==nil{out[f[0]]=v}}
	return out
}
func parseTabStats(body string)map[string]string{
	out:=map[string]string{};sc:=bufio.NewScanner(strings.NewReader(body))
	for sc.Scan(){p:=strings.SplitN(sc.Text(),"\t",2);if len(p)==2&&p[0]!=""{out[p[0]]=strings.TrimSpace(p[1])}}
	return out
}
