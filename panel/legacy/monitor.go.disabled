package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type systemMetrics struct {
	CPUPct       float64 `json:"cpu_percent"`
	MemTotal     uint64  `json:"memory_total_bytes"`
	MemAvailable uint64  `json:"memory_available_bytes"`
	MemUsedPct   float64 `json:"memory_used_percent"`
	DiskTotal    uint64  `json:"disk_total_bytes"`
	DiskUsed     uint64  `json:"disk_used_bytes"`
	DiskUsedPct  float64 `json:"disk_used_percent"`
	Goroutines   int     `json:"panel_goroutines"`
}

type diagnosticCheck struct {
	Name    string `json:"name"`
	Status  string `json:"status"`
	Detail  string `json:"detail"`
	Latency int64  `json:"latency_ms,omitempty"`
}

type diagnosticsResponse struct {
	CheckedAt time.Time          `json:"checked_at"`
	Checks    []diagnosticCheck `json:"checks"`
}

func (a *application) relayRequest(ctx context.Context, path string) (int, string, time.Duration, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://relay:8081"+path, nil)
	if err != nil { return 0, "", 0, err }
	start := time.Now()
	response, err := a.monitorClient.Do(request)
	latency := time.Since(start)
	if err != nil { return 0, "", latency, err }
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 2<<20))
	return response.StatusCode, string(body), latency, err
}

func (a *application) mtproxyStats(ctx context.Context) (string, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, "http://relay:9090/stats", nil)
	if err != nil { return "", err }
	response, err := a.monitorClient.Do(request)
	if err != nil { return "", err }
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK { return "", fmt.Errorf("MTProxy stats HTTP %d", response.StatusCode) }
	body, err := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	return string(body), err
}

func (a *application) diagnostics(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet { http.Error(w, "method not allowed", 405); return }
	ctx, cancel := context.WithTimeout(r.Context(), 4*time.Second)
	defer cancel()
	result := diagnosticsResponse{CheckedAt: time.Now().UTC()}
	for _, endpoint := range []struct{name,path,success string}{
		{"relay_health","/healthz","ok"},
		{"relay_ready","/readyz","ready"},
	} {
		status, body, latency, err := a.relayRequest(ctx, endpoint.path)
		check := diagnosticCheck{Name:endpoint.name,Status:"error"}
		check.Latency = latency.Milliseconds()
		if err != nil { check.Detail = "relay недоступен" } else if status == 200 && strings.TrimSpace(body) == endpoint.success {
			check.Status, check.Detail = "ok", "доступен"
		} else { check.Detail = fmt.Sprintf("HTTP %d", status) }
		result.Checks = append(result.Checks, check)
	}
	stats, err := a.mtproxyStats(ctx)
	mt := diagnosticCheck{Name:"mtproxy_stats",Status:"error"}
	if err != nil { mt.Detail = "статистика MTProxy недоступна" } else if strings.TrimSpace(stats) == "" { mt.Detail = "пустой ответ" } else {
		mt.Status, mt.Detail = "ok", "статистика получена"
	}
	result.Checks = append(result.Checks, mt)
	if _, err := os.Stat(a.profiles); err != nil {
		result.Checks = append(result.Checks, diagnosticCheck{Name:"profiles_file",Status:"error",Detail:"файл профилей недоступен"})
	} else {
		result.Checks = append(result.Checks, diagnosticCheck{Name:"profiles_file",Status:"ok",Detail:"файл профилей доступен"})
	}
	jsonResponse(w,result)
}

func (a *application) metrics(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet { http.Error(w,"method not allowed",405); return }
	ctx,cancel := context.WithTimeout(r.Context(),4*time.Second)
	defer cancel()
	metrics := map[string]any{"system": readSystemMetrics(), "sampled_at":time.Now().UTC()}
	_, relay, _, err := a.relayRequest(ctx,"/metrics")
	if err == nil { metrics["relay"] = parsePrometheus(relay) } else { metrics["relay_error"] = "relay metrics unavailable" }
	mt, err := a.mtproxyStats(ctx)
	if err == nil { metrics["mtproxy"] = parseTabStats(mt) } else { metrics["mtproxy_error"] = "MTProxy metrics unavailable" }
	jsonResponse(w,metrics)
}

func readSystemMetrics() systemMetrics {
	m := systemMetrics{Goroutines:runtime.NumGoroutine()}
	if file,err := os.Open("/proc/meminfo"); err == nil {
		scanner := bufio.NewScanner(file)
		values := map[string]uint64{}
		for scanner.Scan() {
			fields := strings.Fields(scanner.Text())
			if len(fields)>=2 { if v,e:=strconv.ParseUint(fields[1],10,64); e==nil { values[strings.TrimSuffix(fields[0],":")]=v*1024 } }
		}
		_ = file.Close()
		m.MemTotal=values["MemTotal"]; m.MemAvailable=values["MemAvailable"]
		if m.MemTotal>0 { m.MemUsedPct=float64(m.MemTotal-m.MemAvailable)/float64(m.MemTotal)*100 }
	}
	var fs syscall.Statfs_t
	if err:=syscall.Statfs("/", &fs); err==nil {
		m.DiskTotal=fs.Blocks*uint64(fs.Bsize)
		m.DiskUsed=(fs.Blocks-fs.Bfree)*uint64(fs.Bsize)
		if m.DiskTotal>0 { m.DiskUsedPct=float64(m.DiskUsed)/float64(m.DiskTotal)*100 }
	}
	return m
}

func parsePrometheus(body string) map[string]float64 {
	values:=map[string]float64{}
	scanner:=bufio.NewScanner(strings.NewReader(body))
	for scanner.Scan() {
		line:=strings.TrimSpace(scanner.Text())
		if line=="" || strings.HasPrefix(line,"#") { continue }
		fields:=strings.Fields(line)
		if len(fields)<2 || strings.Contains(fields[0],"{") { continue }
		if value,err:=strconv.ParseFloat(fields[1],64); err==nil { values[fields[0]]=value }
	}
	return values
}

func parseTabStats(body string) map[string]string {
	values:=map[string]string{}
	scanner:=bufio.NewScanner(strings.NewReader(body))
	for scanner.Scan() {
		parts:=strings.SplitN(scanner.Text(),"\t",2)
		if len(parts)==2 && parts[0]!="" { values[parts[0]]=strings.TrimSpace(parts[1]) }
	}
	return values
}

var _ sync.Locker
