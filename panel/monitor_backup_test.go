package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestParsePrometheusMetrics(t *testing.T) {
	got:=parsePrometheus("# HELP x\ntproxy_sessions_live 3\ntproxy_bytes_up_total 1024\n")
	if got["tproxy_sessions_live"]!=3 || got["tproxy_bytes_up_total"]!=1024 { t.Fatalf("unexpected parsed metrics: %#v",got) }
}

func TestParseMTProxyTabStats(t *testing.T) {
	got:=parseTabStats("uptime\t120\nactive_network_events\t4\n")
	if got["uptime"]!="120" || got["active_network_events"]!="4" { t.Fatalf("unexpected MTProxy stats: %#v",got) }
}

func TestReadSystemMetrics(t *testing.T) {
	got:=readSystemMetrics()
	if got.MemTotal==0 { t.Fatal("memory total was not detected") }
	if got.MemAvailable>got.MemTotal { t.Fatalf("available memory exceeds total: %+v",got) }
	if got.DiskTotal>0 && (got.DiskUsedPct<0 || got.DiskUsedPct>100) { t.Fatalf("invalid disk usage: %+v",got) }
}

func TestBackupCreateListRestore(t *testing.T) {
	a:=testApp(t)
	a.backupRoot=filepath.Join(t.TempDir(),"backups")
	item,err:=a.createBackup()
	if err!=nil { t.Fatal(err) }
	if item.Size<=0 { t.Fatalf("invalid backup size: %+v",item) }
	if err:=os.WriteFile(a.profiles,[]byte(`{"profiles":[{"name":"default","secret":"ffeeddccbbaa99887766554433221100","backend":"127.0.0.1:2398","carrier_mode":"https"}]}`),0600);err!=nil{t.Fatal(err)}
	if err:=a.restoreBackup(item.ID);err!=nil{t.Fatal(err)}
	doc,err:=a.readProfiles();if err!=nil{t.Fatal(err)}
	if doc.Profiles[0].Secret!="00112233445566778899aabbccddeeff"{t.Fatal("restore did not restore profile secret")}
	items,err:=a.listBackups();if err!=nil{t.Fatal(err)}
	if len(items)!=1 || items[0].ID!=item.ID {t.Fatalf("unexpected backup list: %+v",items)}
}

func TestRestoreRejectsInvalidBackupID(t *testing.T) {
	a:=testApp(t)
	if err:=a.restoreBackup("../config");err==nil {t.Fatal("invalid backup id was accepted")}
}

func TestPruneBackupsWhenBelowRetentionLimit(t *testing.T) {
	a:=testApp(t)
	a.backupRoot=filepath.Join(t.TempDir(),"backups")
	if err:=a.pruneBackups(20);err!=nil {t.Fatal(err)}
}

func TestRestoreRejectsDefaultSecretMismatch(t *testing.T) {
	a:=testApp(t)
	a.backupRoot=filepath.Join(t.TempDir(),"backups")
	backup,err:=a.createBackup();if err!=nil{t.Fatal(err)}
	secretPath:=filepath.Join(t.TempDir(),"mtproxy.secret")
	if err:=os.WriteFile(secretPath,[]byte("ffeeddccbbaa99887766554433221100"),0600);err!=nil{t.Fatal(err)}
	a.mtproxySecret=secretPath
	before,err:=os.ReadFile(a.profiles);if err!=nil{t.Fatal(err)}
	if err:=a.restoreBackup(backup.ID);err==nil{t.Fatal("restore accepted a mismatched default profile secret")}
	after,err:=os.ReadFile(a.profiles);if err!=nil{t.Fatal(err)}
	if string(before)!=string(after){t.Fatal("profiles changed after rejected restore")}
}

type monitorRoundTripper func(*http.Request) (*http.Response,error)
func (fn monitorRoundTripper) RoundTrip(req *http.Request)(*http.Response,error){return fn(req)}

func TestDiagnosticsChecksRelayAndMTProxy(t *testing.T) {
	a:=testApp(t)
	a.monitorClient=&http.Client{Transport:monitorRoundTripper(func(req *http.Request)(*http.Response,error){
		body:="ok\n"
		switch req.URL.Path {case "/relay/readyz":body="ready\n";case "/stats":body="uptime\t123\n"}
		return &http.Response{StatusCode:200,Header:make(http.Header),Body:io.NopCloser(bytes.NewBufferString(body)),Request:req},nil
	})}
	response:=httptest.NewRecorder()
	a.diagnostics(response,httptest.NewRequest(http.MethodGet,"/admin/api/diagnostics",nil))
	if response.Code!=http.StatusOK{t.Fatalf("status=%d body=%s",response.Code,response.Body.String())}
	var result diagnosticsResponse
	if err:=json.Unmarshal(response.Body.Bytes(),&result);err!=nil{t.Fatal(err)}
	if len(result.Checks)!=4{t.Fatalf("expected four checks, got %+v",result.Checks)}
	for _,check:=range result.Checks{if check.Status!="ok"{t.Fatalf("check failed: %+v",check)}}
}

func TestMetricsEndpointCollectsRelayAndMTProxyData(t *testing.T) {
	a:=testApp(t)
	a.monitorClient=&http.Client{Transport:monitorRoundTripper(func(req *http.Request)(*http.Response,error){
		body:="tproxy_sessions_live 7\n"
		if req.URL.Path=="/stats"{body="uptime\t321\n"}
		return &http.Response{StatusCode:200,Header:make(http.Header),Body:io.NopCloser(bytes.NewBufferString(body)),Request:req},nil
	})}
	response:=httptest.NewRecorder()
	a.metrics(response,httptest.NewRequest(http.MethodGet,"/admin/api/metrics",nil))
	if response.Code!=http.StatusOK{t.Fatalf("status=%d body=%s",response.Code,response.Body.String())}
	var result map[string]any
	if err:=json.Unmarshal(response.Body.Bytes(),&result);err!=nil{t.Fatal(err)}
	if result["relay"].(map[string]any)["tproxy_sessions_live"]!=float64(7){t.Fatalf("relay metric missing: %s",response.Body.String())}
	if result["mtproxy"].(map[string]any)["uptime"]!="321"{t.Fatalf("MTProxy metric missing: %s",response.Body.String())}
}
