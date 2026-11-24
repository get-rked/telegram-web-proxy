package main

import (
	"bytes"
	"database/sql"
	"log"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func testApp(t *testing.T) *application {
	t.Helper()
	dir := t.TempDir()
	db, err := sql.Open("sqlite", filepath.Join(dir, "test.db"))
	if err != nil { t.Fatal(err) }
	t.Cleanup(func() { _ = db.Close() })
	if _, err = db.Exec("CREATE TABLE audit_log (id INTEGER PRIMARY KEY, event TEXT NOT NULL, created_at TEXT NOT NULL)"); err != nil { t.Fatal(err) }
	config := filepath.Join(dir, "config.json")
	if err = os.WriteFile(config, []byte(`{"public_hostname":"proxy.example.com","listen":"127.0.0.1:8080","admin_listen":"127.0.0.1:8081","token_key_file":"/private/token.key"}`), 0600); err != nil { t.Fatal(err) }
	profiles := filepath.Join(dir, "profiles.json")
	if err = os.WriteFile(profiles, []byte(`{"profiles":[{"name":"default","secret":"00112233445566778899aabbccddeeff","backend":"127.0.0.1:2398","carrier_mode":"https"}]}`), 0600); err != nil { t.Fatal(err) }
	return &application{db: db, user: "admin", password: "a-long-test-password", config: config, profiles: profiles}
}

func authRequest(method, path, body string, mutation bool) *http.Request {
	request := httptest.NewRequest(method, path, strings.NewReader(body))
	request.SetBasicAuth("admin", "a-long-test-password")
	request.Host = "proxy.example.com"
	if mutation {
		request.Header.Set("Origin", "https://proxy.example.com")
		request.Header.Set("X-TProxy-Request", "1")
		request.Header.Set("Content-Type", "application/json")
	}
	return request
}

func TestStatusRequiresAuthentication(t *testing.T) {
	a := testApp(t)
	mux := http.NewServeMux()
	mux.HandleFunc("/status", a.auth(a.status))
	response := httptest.NewRecorder()
	mux.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/status", nil))
	if response.Code != http.StatusUnauthorized { t.Fatalf("status=%d, want 401", response.Code) }
}

func TestStatusDoesNotExposeTokenKeyPath(t *testing.T) {
	a := testApp(t)
	response := httptest.NewRecorder()
	a.auth(a.status)(response, authRequest(http.MethodGet, "/status", "", false))
	if response.Code != http.StatusOK { t.Fatalf("status=%d body=%s", response.Code, response.Body.String()) }
	if strings.Contains(response.Body.String(), "token.key") { t.Fatal("status response leaked token key path") }
}

func TestReadProfilesAcceptsDDPrefixedLegacySecret(t *testing.T) {
	a := testApp(t)
	data := []byte(`{"profiles":[{"name":"default","secret":"dd00112233445566778899aabbccddeeff","backend":"127.0.0.1:2398","carrier_mode":"https"}]}`)
	if err := os.WriteFile(a.profiles, data, 0600); err != nil { t.Fatal(err) }
	doc, err := a.readProfiles()
	if err != nil { t.Fatal(err) }
	if doc.Profiles[0].Secret != "dd00112233445566778899aabbccddeeff" {
		t.Fatal("legacy dd-prefixed profile secret was not preserved")
	}
}

func TestProfilesDoNotExposeSecrets(t *testing.T) {
	a := testApp(t)
	response := httptest.NewRecorder()
	a.auth(a.profilesAPI)(response, authRequest(http.MethodGet, "/admin/api/profiles", "", false))
	if response.Code != http.StatusOK { t.Fatalf("status=%d body=%s", response.Code, response.Body.String()) }
	if strings.Contains(response.Body.String(), "00112233445566778899aabbccddeeff") || strings.Contains(response.Body.String(), `"secret":`) {
		t.Fatalf("profile response leaked secret: %s", response.Body.String())
	}
}

func TestProfilesRejectNonGetLegacyHandler(t *testing.T) {
	a := testApp(t)
	request := authRequest(http.MethodPut, "/admin/api/profiles", "", true)
	response := httptest.NewRecorder()
	a.auth(a.profilesAPI)(response, request)
	if response.Code != http.StatusMethodNotAllowed { t.Fatalf("status=%d, want 405", response.Code) }
}

func TestCreateProfileGeneratesSecretAndWritesBackup(t *testing.T) {
	a := testApp(t)
	response := httptest.NewRecorder()
	a.auth(a.profilesAPI)(response, authRequest(http.MethodPost, "/admin/api/profiles",
		`{"name":"mobile","backend":"127.0.0.1:2398","carrier_mode":"websocket"}`, true))
	if response.Code != http.StatusOK { t.Fatalf("status=%d body=%s", response.Code, response.Body.String()) }
	var result struct { Secret string `json:"secret"` }
	if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil { t.Fatal(err) }
	if len(result.Secret) != 32 { t.Fatalf("generated secret length=%d", len(result.Secret)) }
	if _, err := os.Stat(a.profiles + ".backup-" + ""); err == nil { t.Fatal("unexpected exact backup path") }
	backups, err := filepath.Glob(a.profiles + ".backup-*")
	if err != nil || len(backups) != 1 { t.Fatalf("backups=%v err=%v", backups, err) }
}

func TestMutationRequiresSameOriginAndCustomHeader(t *testing.T) {
	a := testApp(t)
	request := authRequest(http.MethodPost, "/admin/api/profiles", `{"name":"mobile","backend":"127.0.0.1:2398","carrier_mode":"https"}`, false)
	response := httptest.NewRecorder()
	a.auth(a.profilesAPI)(response, request)
	if response.Code != http.StatusForbidden { t.Fatalf("status=%d, want 403", response.Code) }
}

func TestDefaultProfileCannotBeDeleted(t *testing.T) {
	a := testApp(t)
	request := authRequest(http.MethodDelete, "/admin/api/profiles/default", "", true)
	response := httptest.NewRecorder()
	a.auth(a.profileItemAPI)(response, request)
	if response.Code != http.StatusConflict { t.Fatalf("status=%d body=%s", response.Code, response.Body.String()) }
}

func TestInvalidBackendIsRejected(t *testing.T) {
	if err := validateProfileRequest(profileRequest{Name:"bad", Backend:"example.com:2398", CarrierMode:"https"}); err == nil {
		t.Fatal("non-loopback backend was accepted")
	}
	if err := validateProfileRequest(profileRequest{Name:"bad", Backend:"127.0.0.1:nope", CarrierMode:"https"}); err == nil {
		t.Fatal("nonnumeric backend port was accepted")
	}
}

func TestUpdateProfilePreservesSecretAndCreatesBackup(t *testing.T) {
	a := testApp(t)
	request := authRequest(http.MethodPut, "/admin/api/profiles/default", `{"name":"default","backend":"127.0.0.1:2400","carrier_mode":"https-lanes"}`, true)
	response := httptest.NewRecorder()
	a.auth(a.profileItemAPI)(response, request)
	if response.Code != http.StatusOK { t.Fatalf("status=%d body=%s", response.Code, response.Body.String()) }
	doc, err := a.readProfiles()
	if err != nil { t.Fatal(err) }
	if doc.Profiles[0].Secret != "00112233445566778899aabbccddeeff" { t.Fatal("profile secret changed") }
	if doc.Profiles[0].Backend != "127.0.0.1:2400" { t.Fatal("backend was not updated") }
	backups, _ := filepath.Glob(a.profiles + ".backup-*")
	if len(backups) != 1 { t.Fatalf("expected one backup, got %d", len(backups)) }
}

func TestDeleteNonDefaultProfile(t *testing.T) {
	a := testApp(t)
	doc, err := a.readProfiles()
	if err != nil { t.Fatal(err) }
	doc.Profiles = append(doc.Profiles, profile{Name:"mobile", Secret:"ffeeddccbbaa99887766554433221100", Backend:"127.0.0.1:2398", CarrierMode:"https"})
	if err := os.WriteFile(a.profiles, mustJSON(t, doc), 0600); err != nil { t.Fatal(err) }
	request := authRequest(http.MethodDelete, "/admin/api/profiles/mobile", "", true)
	response := httptest.NewRecorder()
	a.auth(a.profileItemAPI)(response, request)
	if response.Code != http.StatusNoContent { t.Fatalf("status=%d body=%s", response.Code, response.Body.String()) }
	doc, err = a.readProfiles()
	if err != nil { t.Fatal(err) }
	if len(doc.Profiles) != 1 || doc.Profiles[0].Name != "default" { t.Fatalf("unexpected profiles: %+v", doc.Profiles) }
}

func mustJSON(t *testing.T, value any) []byte {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil { t.Fatal(err) }
	return data
}

func TestWriteProfilesUsesOwnerOnlyPermissions(t *testing.T) {
	a:=testApp(t)
	doc,err:=a.readProfiles();if err!=nil{t.Fatal(err)}
	if err:=a.writeProfiles(doc);err!=nil{t.Fatal(err)}
	info,err:=os.Stat(a.profiles);if err!=nil{t.Fatal(err)}
	if got:=info.Mode().Perm();got!=0600{t.Fatalf("profiles mode=%04o, want 0600",got)}
}

func TestWriteProfilesSynchronizesAllMTProxySecrets(t *testing.T) {
	a := testApp(t)
	secretPath := filepath.Join(t.TempDir(), "mtproxy.secret")
	if err := os.WriteFile(secretPath, []byte("00112233445566778899aabbccddeeff\n"), 0600); err != nil { t.Fatal(err) }
	a.mtproxySecret = secretPath
	doc, err := a.readProfiles()
	if err != nil { t.Fatal(err) }
	doc.Profiles = append(doc.Profiles, profile{Name:"mobile", Secret:"ddffeeddccbbaa99887766554433221100", Backend:"127.0.0.1:2398", CarrierMode:"websocket"})
	if err := a.writeProfiles(doc); err != nil { t.Fatal(err) }
	got, err := os.ReadFile(secretPath)
	if err != nil { t.Fatal(err) }
	want := "00112233445566778899aabbccddeeff\nffeeddccbbaa99887766554433221100\n"
	if string(got) != want { t.Fatalf("secret file mismatch: %q", got) }
}

func TestFailedAuthenticationIsLoggedWithTrustedClientIP(t *testing.T) {
	a := testApp(t)
	var output bytes.Buffer
	a.authLog = log.New(&output, "", 0)
	a.trustProxy = true
	request := httptest.NewRequest(http.MethodGet, "/admin/", nil)
	request.RemoteAddr = "172.20.0.2:1234"
	request.Header.Set("X-Real-IP", "203.0.113.9")
	request.SetBasicAuth("admin", "wrong-password")
	response := httptest.NewRecorder()
	a.auth(a.index)(response, request)
	if response.Code != http.StatusUnauthorized { t.Fatalf("status=%d, want 401", response.Code) }
	if !strings.Contains(output.String(), "auth_failed ip=203.0.113.9") { t.Fatalf("unexpected auth log: %q", output.String()) }
}

func TestAuthenticationThrottlesRepeatedFailures(t *testing.T) {
	a := testApp(t)
	request := httptest.NewRequest(http.MethodGet, "/admin/", nil)
	request.RemoteAddr = "203.0.113.25:1234"
	request.SetBasicAuth("admin", "wrong-password")
	for i := 0; i < 10; i++ {
		response := httptest.NewRecorder()
		a.auth(a.index)(response, request)
		if response.Code != http.StatusUnauthorized { t.Fatalf("attempt %d status=%d, want 401", i+1, response.Code) }
	}
	response := httptest.NewRecorder()
	a.auth(a.index)(response, request)
	if response.Code != http.StatusTooManyRequests { t.Fatalf("blocked attempt status=%d, want 429", response.Code) }
	if response.Header().Get("Retry-After") != "900" { t.Fatalf("missing Retry-After: %q", response.Header().Get("Retry-After")) }
}
