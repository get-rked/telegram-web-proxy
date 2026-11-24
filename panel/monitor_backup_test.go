package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
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
	if err:=os.WriteFile(a.config,[]byte("{\"public_hostname\":\"changed.example\"}"),0600);err!=nil{t.Fatal(err)}
	if err:=a.restoreBackup(item.ID);err!=nil{t.Fatal(err)}
	config,err:=os.ReadFile(a.config);if err!=nil{t.Fatal(err)};if !bytes.Contains(config,[]byte("proxy.example.com")){t.Fatalf("config was not restored: %s",config)}
	doc,err:=a.readProfiles();if err!=nil{t.Fatal(err)}
	if doc.Profiles[0].Secret!="dd00112233445566778899aabbccddeeff"{t.Fatal("restore did not restore profile secret")}
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

func TestRestoreSynchronizesDefaultSecret(t *testing.T) {
	a:=testApp(t)
	a.backupRoot=filepath.Join(t.TempDir(),"backups")
	backup,err:=a.createBackup();if err!=nil{t.Fatal(err)}
	secretPath:=filepath.Join(t.TempDir(),"mtproxy.secret")
	if err:=os.WriteFile(secretPath,[]byte("ffeeddccbbaa99887766554433221100"),0600);err!=nil{t.Fatal(err)}
	a.mtproxySecret=secretPath
	before,err:=os.ReadFile(a.profiles);if err!=nil{t.Fatal(err)}
	if err:=a.restoreBackup(backup.ID);err!=nil{t.Fatalf("restore should synchronize the MTProxy secret list: %v",err)}
	after,err:=os.ReadFile(a.profiles);if err!=nil{t.Fatal(err)}
	if string(before)==string(after){t.Fatal("profiles were not restored")}
	synced,err:=os.ReadFile(secretPath);if err!=nil{t.Fatal(err)}
	if strings.TrimSpace(string(synced))!="00112233445566778899aabbccddeeff"{t.Fatalf("MTProxy secret list was not synchronized: %q",synced)}
}

type monitorRoundTripper func(*http.Request) (*http.Response,error)
func (fn monitorRoundTripper) RoundTrip(req *http.Request)(*http.Response,error){return fn(req)}

func TestDiagnosticsChecksPublicWebProxyAndBackend(t *testing.T) {
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
	if len(result.Checks)!=5{t.Fatalf("expected five checks, got %+v",result.Checks)}
	for _,check:=range result.Checks{if check.Status!="ok"{t.Fatalf("check failed: %+v",check)}}
}

func TestMetricsEndpointCollectsRelayAndBackendData(t *testing.T) {
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
	if result["backend"].(map[string]any)["uptime"]!="321"{t.Fatalf("backend metric missing: %s",response.Body.String())}
}

func TestRestoreRejectsSHA256Mismatch(t *testing.T) {
	a := testApp(t)
	a.backupRoot = filepath.Join(t.TempDir(), "backups")
	item, err := a.createBackup()
	if err != nil { t.Fatal(err) }
	path := filepath.Join(a.backupDir(), item.ID+".tar.gz")
	input, err := os.Open(path)
	if err != nil { t.Fatal(err) }
	gz, err := gzip.NewReader(input)
	if err != nil { t.Fatal(err) }
	tr := tar.NewReader(gz)
	var profileData, configData, manifestData []byte
	for {
		h, nextErr := tr.Next()
		if nextErr == io.EOF { break }
		if nextErr != nil { t.Fatal(nextErr) }
		data, readErr := io.ReadAll(tr)
		if readErr != nil { t.Fatal(readErr) }
		switch h.Name { case "profiles.json": profileData=data; case "config.json": configData=data; case "manifest.json": manifestData=data }
	}
	_ = gz.Close()
	_ = input.Close()
	profileData = bytes.Replace(profileData, []byte("default"), []byte("changed"), 1)
	out, err := os.Create(path)
	if err != nil { t.Fatal(err) }
	zw := gzip.NewWriter(out)
	tw := tar.NewWriter(zw)
	for _, entry := range []struct{name string; data []byte}{{"profiles.json",profileData},{"config.json",configData},{"manifest.json",manifestData}} {
		if err := tw.WriteHeader(&tar.Header{Name:entry.name,Mode:0600,Size:int64(len(entry.data)),Typeflag:tar.TypeReg});err!=nil{t.Fatal(err)}
		if _,err:=tw.Write(entry.data);err!=nil{t.Fatal(err)}
	}
	if err:=tw.Close();err!=nil{t.Fatal(err)}
	if err:=zw.Close();err!=nil{t.Fatal(err)}
	if err:=out.Close();err!=nil{t.Fatal(err)}
	if err:=a.restoreBackup(item.ID);err==nil{t.Fatal("restore accepted a SHA-256 mismatch")}
}

func TestRestoreRollsBackConfigAndProfilesWhenSecretSyncFails(t *testing.T) {
	a := testApp(t)
	a.backupRoot = filepath.Join(t.TempDir(), "backups")
	item, err := a.createBackup()
	if err != nil { t.Fatal(err) }
	changedProfiles := []byte("{\"profiles\":[{\"name\":\"default\",\"secret\":\"ffeeddccbbaa99887766554433221100\",\"backend\":\"127.0.0.1:2398\",\"carrier_mode\":\"https\"}]}")
	changedConfig := []byte("{\"public_hostname\":\"changed.example\"}")
	if err := os.WriteFile(a.profiles, changedProfiles, 0600); err != nil { t.Fatal(err) }
	if err := os.WriteFile(a.config, changedConfig, 0600); err != nil { t.Fatal(err) }
	a.mtproxySecret = filepath.Join(t.TempDir(), "missing-dir", "secret")
	if err := a.restoreBackup(item.ID); err == nil { t.Fatal("restore unexpectedly succeeded with an unavailable secret directory") }
	gotProfiles, err := os.ReadFile(a.profiles)
	if err != nil { t.Fatal(err) }
	gotConfig, err := os.ReadFile(a.config)
	if err != nil { t.Fatal(err) }
	if !bytes.Equal(gotProfiles, changedProfiles) { t.Fatalf("profiles were not rolled back: %s", gotProfiles) }
	if !bytes.Equal(gotConfig, changedConfig) { t.Fatalf("config was not rolled back: %s", gotConfig) }
}


func TestBackupItemAPIDownloadAndRestoreRoutes(t *testing.T) {
	a := testApp(t)
	a.backupRoot = filepath.Join(t.TempDir(), "backups")
	item, err := a.createBackup()
	if err != nil { t.Fatal(err) }

	download := httptest.NewRecorder()
	a.backupItemAPI(download, authRequest(http.MethodGet, "/api/backups/"+item.ID, "", false))
	if download.Code != http.StatusOK { t.Fatalf("download status=%d body=%s", download.Code, download.Body.String()) }
	if download.Header().Get("Content-Type") != "application/gzip" { t.Fatalf("unexpected download content type: %q", download.Header().Get("Content-Type")) }
	if download.Body.Len() == 0 { t.Fatal("backup download is empty") }

	restore := httptest.NewRecorder()
	a.backupItemAPI(restore, authRequest(http.MethodPost, "/api/backups/"+item.ID+"/restore", "{}", true))
	if restore.Code != http.StatusOK { t.Fatalf("restore status=%d body=%s", restore.Code, restore.Body.String()) }
	if !strings.Contains(restore.Body.String(), "\"status\":\"restored\"") { t.Fatalf("unexpected restore response: %s", restore.Body.String()) }
}

func TestDiagnosticsRejectsMalformedProfilesFile(t *testing.T) {
	a := testApp(t)
	if err := os.WriteFile(a.profiles, []byte("{not-json"), 0600); err != nil { t.Fatal(err) }
	a.monitorClient = &http.Client{Transport: monitorRoundTripper(func(req *http.Request) (*http.Response,error) {
		body := "ok\\n"
		if req.URL.Path == "/relay/readyz" { body = "ready\\n" }
		if req.URL.Path == "/stats" { body = "uptime\\t1\\n" }
		return &http.Response{StatusCode:200, Header:make(http.Header), Body:io.NopCloser(strings.NewReader(body)), Request:req}, nil
	})}
	response := httptest.NewRecorder()
	a.diagnostics(response, httptest.NewRequest(http.MethodGet, "/api/diagnostics", nil))
	var result diagnosticsResponse
	if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil { t.Fatal(err) }
	for _, check := range result.Checks {
		if check.Name == "profiles_file" && check.Status == "ok" { t.Fatal("malformed profiles file was reported healthy") }
	}
}
