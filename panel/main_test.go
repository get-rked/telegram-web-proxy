package main

import (
	"bytes"
	"crypto/sha256"
	"database/sql"
	"log"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"time"
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
	if err = os.WriteFile(profiles, []byte(`{"profiles":[{"name":"default","secret":"dd00112233445566778899aabbccddeeff","backend":"127.0.0.1:2398","carrier_mode":"https"}]}`), 0600); err != nil { t.Fatal(err) }
	salt := []byte("test-panel-password-salt")
	hash := sha256.Sum256(append(append([]byte(nil), salt...), []byte("a-long-test-password")...))
	return &application{db: db, user: "admin", basePath: "/panel-test-session-path-1234567890", passwordSalt: salt, passwordHash: hash[:], sessions: map[string]time.Time{"test-session": time.Now().Add(time.Hour)}, config: config, profiles: profiles}
}

func authRequest(method, path, body string, mutation bool) *http.Request {
	request := httptest.NewRequest(method, path, strings.NewReader(body))
	request.AddCookie(&http.Cookie{Name:"tproxy_session", Value:"test-session"})
	request.Host = "proxy.example.com"
	if mutation {
		request.Header.Set("Origin", "https://proxy.example.com")
		request.Header.Set("X-TProxy-Request", "1")
		request.Header.Set("Content-Type", "application/json")
	}
	return request
}

func TestLoginCreatesSecureBasePathScopedSession(t *testing.T) {
	a := testApp(t)
	request := httptest.NewRequest(http.MethodPost, "/api/login", strings.NewReader(`{"username":"admin","password":"a-long-test-password"}`))
	request.RemoteAddr = "203.0.113.20:1234"
	request.Host = "proxy.example.com"
	request.Header.Set("Origin", "https://proxy.example.com")
	request.Header.Set("X-TProxy-Request", "1")
	response := httptest.NewRecorder()
	a.login(response, request)
	if response.Code != http.StatusOK { t.Fatalf("status=%d body=%s", response.Code, response.Body.String()) }
	cookies := response.Result().Cookies()
	if len(cookies) != 1 { t.Fatalf("cookies=%d, want 1", len(cookies)) }
	cookie := cookies[0]
	if cookie.Name != "tproxy_session" || cookie.Path != a.basePath+"/" || !cookie.HttpOnly || !cookie.Secure || cookie.SameSite != http.SameSiteStrictMode {
		t.Fatalf("unexpected session cookie: %+v", cookie)
	}
	check := httptest.NewRequest(http.MethodGet, "/api/session", nil)
	check.AddCookie(cookie)
	status := httptest.NewRecorder()
	a.sessionStatus(status, check)
	if !strings.Contains(status.Body.String(), `"authenticated":true`) { t.Fatalf("session not recognized: %s", status.Body.String()) }
}

func TestLogoutRevokesSession(t *testing.T) {
	a := testApp(t)
	request := authRequest(http.MethodPost, "/api/logout", "{}", true)
	response := httptest.NewRecorder()
	a.auth(a.logout)(response, request)
	if response.Code != http.StatusNoContent { t.Fatalf("status=%d, want 204", response.Code) }
	if a.sessionValid("test-session") { t.Fatal("logout did not revoke session") }
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
	a.auth(a.profilesAPI)(response, authRequest(http.MethodGet, "/api/profiles", "", false))
	if response.Code != http.StatusOK { t.Fatalf("status=%d body=%s", response.Code, response.Body.String()) }
	if strings.Contains(response.Body.String(), "00112233445566778899aabbccddeeff") || strings.Contains(response.Body.String(), `"secret":`) {
		t.Fatalf("profile response leaked secret: %s", response.Body.String())
	}
}

func TestProfilesRejectNonGetLegacyHandler(t *testing.T) {
	a := testApp(t)
	request := authRequest(http.MethodPut, "/api/profiles", "", true)
	response := httptest.NewRecorder()
	a.auth(a.profilesAPI)(response, request)
	if response.Code != http.StatusMethodNotAllowed { t.Fatalf("status=%d, want 405", response.Code) }
}

func TestCreateProfileGeneratesSecretAndWritesBackup(t *testing.T) {
	a := testApp(t)
	response := httptest.NewRecorder()
	a.auth(a.profilesAPI)(response, authRequest(http.MethodPost, "/api/profiles",
		`{"name":"mobile"}`, true))
	if response.Code != http.StatusOK { t.Fatalf("status=%d body=%s", response.Code, response.Body.String()) }
	var result struct { Secret string `json:"secret"` }
	if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil { t.Fatal(err) }
	if len(result.Secret) != 34 || !strings.HasPrefix(result.Secret, "dd") { t.Fatalf("generated secret must be dd-prefixed, got %q", result.Secret) }
	if _, err := os.Stat(a.profiles + ".backup-" + ""); err == nil { t.Fatal("unexpected exact backup path") }
	backups, err := filepath.Glob(a.profiles + ".backup-*")
	if err != nil || len(backups) != 1 { t.Fatalf("backups=%v err=%v", backups, err) }
}

func TestProfileConfigReturnsDDSecretAndClientLink(t *testing.T) {
	a := testApp(t)
	response := httptest.NewRecorder()
	a.profileConfig(response, authRequest(http.MethodGet, "/api/profiles/default/config", "", false), "default")
	if response.Code != http.StatusOK { t.Fatalf("status=%d body=%s", response.Code, response.Body.String()) }
	var result struct { Secret string `json:"secret"`; Link string `json:"link"`; Port int `json:"port"` }
	if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil { t.Fatal(err) }
	if result.Secret != "00112233445566778899aabbccddeeff" { t.Fatalf("wrong client secret: %q", result.Secret) }
	if result.Port != 443 || !strings.Contains(result.Link, "https://t.me/webproxy?") || !strings.Contains(result.Link, "secret=00112233445566778899aabbccddeeff") || !strings.Contains(result.Link, "server=proxy.example.com") || strings.Contains(result.Link, "t.me/proxy?") { t.Fatalf("invalid Web Proxy link: %+v", result) }
}

func TestProfileQRReturnsPNG(t *testing.T) {
	a := testApp(t)
	response := httptest.NewRecorder()
	a.profileQR(response, authRequest(http.MethodGet, "/api/profiles/default/qr", "", false), "default")
	if response.Code != http.StatusOK { t.Fatalf("status=%d body=%s", response.Code, response.Body.String()) }
	if response.Header().Get("Content-Type") != "image/png" || len(response.Body.Bytes()) < 4 || !bytes.Equal(response.Body.Bytes()[:4], []byte{0x89, 'P', 'N', 'G'}) { t.Fatal("QR response is not a PNG image") }
}

func TestMutationRequiresSameOriginAndCustomHeader(t *testing.T) {
	a := testApp(t)
	request := authRequest(http.MethodPost, "/api/profiles", `{"name":"mobile","backend":"127.0.0.1:2398","carrier_mode":"https"}`, false)
	response := httptest.NewRecorder()
	a.auth(a.profilesAPI)(response, request)
	if response.Code != http.StatusForbidden { t.Fatalf("status=%d, want 403", response.Code) }
}

func TestDefaultProfileCannotBeDeleted(t *testing.T) {
	a := testApp(t)
	request := authRequest(http.MethodDelete, "/api/profiles/default", "", true)
	response := httptest.NewRecorder()
	a.auth(a.profileItemAPI)(response, request)
	if response.Code != http.StatusConflict { t.Fatalf("status=%d body=%s", response.Code, response.Body.String()) }
}

func TestCreateProfileUsesDDSecretAndInternalDefaults(t *testing.T) {
	a := testApp(t)
	response := httptest.NewRecorder()
	a.auth(a.profilesAPI)(response, authRequest(http.MethodPost, "/api/profiles", `{"name":"mobile"}`, true))
	if response.Code != http.StatusOK { t.Fatalf("status=%d body=%s", response.Code, response.Body.String()) }
	var result struct { Secret string `json:"secret"` }
	if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil { t.Fatal(err) }
	if len(result.Secret) != 34 || !strings.HasPrefix(result.Secret, "dd") { t.Fatalf("invalid generated secret: %q", result.Secret) }
	doc, err := a.readProfiles(); if err != nil { t.Fatal(err) }
	created := doc.Profiles[findProfile(doc.Profiles, "mobile")]
	if created.Backend != "127.0.0.1:2398" || created.CarrierMode != "https" || !strings.HasPrefix(created.Secret, "dd") { t.Fatalf("unexpected generated profile: %+v", created) }
}

func TestDeleteNonDefaultProfile(t *testing.T) {
	a := testApp(t)
	doc, err := a.readProfiles()
	if err != nil { t.Fatal(err) }
	doc.Profiles = append(doc.Profiles, profile{Name:"mobile", Secret:"ffeeddccbbaa99887766554433221100", Backend:"127.0.0.1:2398", CarrierMode:"https"})
	if err := os.WriteFile(a.profiles, mustJSON(t, doc), 0600); err != nil { t.Fatal(err) }
	request := authRequest(http.MethodDelete, "/api/profiles/mobile", "", true)
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
	request := httptest.NewRequest(http.MethodPost, "/api/login", strings.NewReader(`{"username":"admin","password":"wrong-password"}`))
	request.RemoteAddr = "172.20.0.2:1234"
	request.Host = "proxy.example.com"
	request.Header.Set("Origin", "https://proxy.example.com")
	request.Header.Set("X-TProxy-Request", "1")
	request.Header.Set("X-Real-IP", "203.0.113.9")
	response := httptest.NewRecorder()
	a.login(response, request)
	if response.Code != http.StatusUnauthorized { t.Fatalf("status=%d, want 401", response.Code) }
	if !strings.Contains(output.String(), "auth_failed ip=203.0.113.9") { t.Fatalf("unexpected auth log: %q", output.String()) }
}

func TestAuthenticationThrottlesRepeatedFailures(t *testing.T) {
	a := testApp(t)
	newRequest := func() *http.Request {
		request := httptest.NewRequest(http.MethodPost, "/api/login", strings.NewReader(`{"username":"admin","password":"wrong-password"}`))
		request.RemoteAddr = "203.0.113.25:1234"
		request.Host = "proxy.example.com"
		request.Header.Set("Origin", "https://proxy.example.com")
		request.Header.Set("X-TProxy-Request", "1")
		return request
	}
	for i := 0; i < 10; i++ {
		response := httptest.NewRecorder()
		a.login(response, newRequest())
		if response.Code != http.StatusUnauthorized { t.Fatalf("attempt %d status=%d, want 401", i+1, response.Code) }
	}
	response := httptest.NewRecorder()
	a.login(response, newRequest())
	if response.Code != http.StatusTooManyRequests { t.Fatalf("blocked attempt status=%d, want 429", response.Code) }
	if response.Header().Get("Retry-After") != "900" { t.Fatalf("missing Retry-After: %q", response.Header().Get("Retry-After")) }
}

func TestFail2banBanlistBlocksTrustedProxyClient(t *testing.T) {
	a := testApp(t)
	a.trustProxy = true
	a.banDir = filepath.Join(t.TempDir(), "banlist")
	jailDir := filepath.Join(a.banDir, "tproxy-panel")
	if err := os.MkdirAll(jailDir, 0700); err != nil { t.Fatal(err) }
	if err := os.WriteFile(filepath.Join(jailDir, "203.0.113.44"), []byte("banned"), 0600); err != nil { t.Fatal(err) }
	request := httptest.NewRequest(http.MethodGet, "/admin/", nil)
	request.RemoteAddr = "172.20.0.2:1234"
	request.Header.Set("X-Real-IP", "203.0.113.44")
	request.AddCookie(&http.Cookie{Name:"tproxy_session", Value:"test-session"})
	response := httptest.NewRecorder()
	a.auth(a.index)(response, request)
	if response.Code != http.StatusTooManyRequests { t.Fatalf("status=%d, want 429", response.Code) }
}
