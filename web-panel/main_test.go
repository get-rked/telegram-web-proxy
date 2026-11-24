package main

import (
	"bytes"
 "mime/multipart"
 "net/http"
 "net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDeriveIsDeterministicAndSalted(t *testing.T) {
	a := passwordHash("test-password", []byte("0123456789abcdef"))
	b := passwordHash("test-password", []byte("0123456789abcdef"))
	c := passwordHash("test-password", []byte("fedcba9876543210"))
	if !bytes.Equal(a, b) {
		t.Fatal("same password and salt must produce same hash")
	}
	if bytes.Equal(a, c) {
		t.Fatal("different salts must produce different hashes")
	}
	if len(a) != 32 {
		t.Fatalf("unexpected hash length: %d", len(a))
	}
}

func TestRandomToken(t *testing.T) {
	a, err := randomToken(24)
	if err != nil {
		t.Fatal(err)
	}
	b, err := randomToken(24)
	if err != nil {
		t.Fatal(err)
	}
	if a == b {
		t.Fatal("random tokens unexpectedly equal")
	}
	if len(a) < 30 {
		t.Fatalf("token too short: %d", len(a))
	}
}

func TestInitCreatesProtectedBootstrapCredentials(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("PANEL_DB", filepath.Join(dir, "panel.db"))
	a := &App{}
	if err := a.init(); err != nil {
		t.Fatal(err)
	}
	defer a.db.Close()
	if len(a.base) != 32 {
		t.Fatalf("unexpected basepath length: %d", len(a.base))
	}
	raw, err := os.ReadFile(filepath.Join(dir, "panel-credentials.txt"))
	if err != nil {
		t.Fatal(err)
	}
	st, err := os.Stat(filepath.Join(dir, "panel-credentials.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if st.Mode().Perm() != 0600 {
		t.Fatalf("credentials file permissions are %o", st.Mode().Perm())
	}
	lines := strings.Split(strings.TrimSpace(string(raw)), "\n")
	if len(lines) != 3 || !strings.HasPrefix(lines[0], "URL_PATH=/") || !strings.HasPrefix(lines[1], "LOGIN=") || !strings.HasPrefix(lines[2], "PASSWORD=") {
		t.Fatalf("invalid bootstrap credential file: %q", raw)
	}
	login := strings.TrimPrefix(lines[1], "LOGIN=")
	password := strings.TrimPrefix(lines[2], "PASSWORD=")
	var salt, hash []byte
	if err := a.db.QueryRow("SELECT salt,password_hash FROM users WHERE username=?", login).Scan(&salt, &hash); err != nil {
		t.Fatal(err)
	}
	if bytes.Equal(hash, []byte(password)) || !bytes.Equal(passwordHash(password, salt), hash) {
		t.Fatal("password is not stored as a valid password hash")
	}
}

func TestRedactConfigHidesSecretsRecursively(t *testing.T) {
	input := map[string]any{"profiles": []any{map[string]any{"secret": "cleartext", "name": "alpha"}}, "api_token": "sensitive"}
	got := redactConfig(input).(map[string]any)
	profiles := got["profiles"].([]any)[0].(map[string]any)
	if profiles["secret"] != "[REDACTED]" || got["api_token"] != "[REDACTED]" {
		t.Fatal("sensitive config values were not redacted")
	}
}

func TestProfileImportUsesValidatedInstallerArguments(t *testing.T) {
 dir:=t.TempDir()
 capture:=filepath.Join(dir,"args.txt")
 script:=filepath.Join(dir,"capture.sh")
 scriptBody:="#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$CAPTURE_ARGS\"\n"
 if err:=os.WriteFile(script,[]byte(scriptBody),0700);err!=nil{t.Fatal(err)}
 t.Setenv("CAPTURE_ARGS",capture)

 var body bytes.Buffer
 writer:=multipart.NewWriter(&body)
 part,err:=writer.CreateFormFile("archive","profile.tar.gz");if err!=nil{t.Fatal(err)}
 if _,err=part.Write([]byte("test-archive"));err!=nil{t.Fatal(err)}
 if err=writer.WriteField("target","new");err!=nil{t.Fatal(err)}
 if err=writer.WriteField("name","alpha");err!=nil{t.Fatal(err)}
 if err=writer.Close();err!=nil{t.Fatal(err)}

 req:=httptest.NewRequest(http.MethodPost,"/panel/api/profiles/import",&body)
 req.Header.Set("Content-Type",writer.FormDataContentType())
 response:=httptest.NewRecorder()
 a:=&App{script:script,backupDir:dir}
 a.profileImport(response,req)
 if response.Code!=http.StatusOK{t.Fatalf("unexpected status %d: %s",response.Code,response.Body.String())}
 raw,err:=os.ReadFile(capture);if err!=nil{t.Fatal(err)}
 args:=strings.Split(strings.TrimSpace(string(raw)),"\n")
 if len(args)!=6||args[0]!="profile"||args[1]!="import"||args[3]!="--name"||args[4]!="alpha"||args[5]!="--yes"{t.Fatalf("unexpected installer arguments: %#v",args)}
}

func TestLoginRejectsSQLInjectionUsername(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("PANEL_DB", filepath.Join(dir, "panel.db"))

	a := &App{authSem: make(chan struct{}, 2)}
	if err := a.init(); err != nil {
		t.Fatal(err)
	}
	defer a.db.Close()

	credentials, err := os.ReadFile(filepath.Join(dir, "panel-credentials.txt"))
	if err != nil {
		t.Fatal(err)
	}
	var username, password string
	for _, line := range strings.Split(strings.TrimSpace(string(credentials)), "\n") {
		switch {
		case strings.HasPrefix(line, "LOGIN="):
			username = strings.TrimPrefix(line, "LOGIN=")
		case strings.HasPrefix(line, "PASSWORD="):
			password = strings.TrimPrefix(line, "PASSWORD=")
		}
	}
	if username == "" || password == "" {
		t.Fatal("bootstrap credentials are missing")
	}

	// With unsafe SQL string concatenation, this username could turn the
	// WHERE clause into an always-true expression and select the admin row.
	form := url.Values{}
	form.Set("username", "' OR 1=1 --")
	form.Set("password", password)
	req := httptest.NewRequest(http.MethodPost, "/"+a.base+"/login", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	response := httptest.NewRecorder()
	a.login(response, req)

	if response.Code != http.StatusUnauthorized {
		t.Fatalf("SQL injection attempt returned status %d, want %d", response.Code, http.StatusUnauthorized)
	}
	var sessions int
	if err := a.db.QueryRow("SELECT COUNT(*) FROM sessions").Scan(&sessions); err != nil {
		t.Fatal(err)
	}
	if sessions != 0 {
		t.Fatalf("SQL injection attempt created %d session(s)", sessions)
	}

	// A real credential pair must still work after the rejected injection.
	form.Set("username", username)
	req = httptest.NewRequest(http.MethodPost, "/"+a.base+"/login", strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	response = httptest.NewRecorder()
	a.login(response, req)
	if response.Code != http.StatusSeeOther {
		t.Fatalf("valid login returned status %d, want %d", response.Code, http.StatusSeeOther)
	}
}

func TestProxyClientSecretMatchesInstallerFormat(t *testing.T) {
	got := proxyClientSecret("0123456789abcdef0123456789abcdef", "random-base")
	want := "cAEjRWeJq83vASNFZ4mrze8"
	if got != want {
		t.Fatalf("unexpected client secret: %q", got)
	}
	if dd := proxyClientSecret("dd0123456789abcdef0123456789abcdef", "random-base"); dd != "cN0BI0VniavN7wEjRWeJq83v" { t.Fatalf("unexpected dd client secret: %q", dd) }
	if plain := proxyClientSecret("0123456789abcdef0123456789abcdef", ""); plain != "0123456789abcdef0123456789abcdef" {
		t.Fatalf("unexpected plain secret: %q", plain)
	}
}

func TestProfileDetailsUsesPublicConnectionDataNotBackend(t *testing.T) {
	dir := t.TempDir()
	configDir := filepath.Join(dir, "config")
	profileDir := filepath.Join(configDir, "profiles", "alpha")
	if err := os.MkdirAll(profileDir, 0700); err != nil { t.Fatal(err) }
	config := `{"public_hostname":"proxy.example.test","base_path":"random-path"}`
	profile := `{"name":"alpha","secret":"0123456789abcdef0123456789abcdef","backend":"127.0.0.1:2398","carrier_mode":"https-lanes"}`
	if err := os.WriteFile(filepath.Join(configDir, "config.json"), []byte(config), 0600); err != nil { t.Fatal(err) }
	if err := os.WriteFile(filepath.Join(profileDir, "profile.json"), []byte(profile), 0600); err != nil { t.Fatal(err) }
	a := &App{configDir: configDir}
	got, err := a.profileDetails("alpha")
	if err != nil { t.Fatal(err) }
	if got["server"] != "proxy.example.test/random-path" { t.Fatalf("unexpected server: %q", got["server"]) }
	if strings.Contains(strings.Join([]string{got["server"], got["link"]}, " "), "127.0.0.1:2398") {
		t.Fatal("internal backend leaked into client configuration")
	}
	if got["carrier_mode"] != "https-lanes" || got["name"] != "alpha" { t.Fatalf("unexpected profile metadata: %#v", got) }
	if got["secret"] != "cAEjRWeJq83vASNFZ4mrze8" { t.Fatalf("unexpected client-facing secret: %q", got["secret"]) }
	if !strings.Contains(got["link"], "https://t.me/webproxy?") { t.Fatalf("unexpected Telegram link: %q", got["link"]) }
	if !strings.Contains(got["tg_link"], "tg://webproxy?") { t.Fatalf("unexpected direct Telegram link: %q", got["tg_link"]) }
}

func TestProfileActionExportReturnsDownloadURL(t *testing.T) {
	dir := t.TempDir()
	backupDir := filepath.Join(dir, "backups")
	script := filepath.Join(dir, "export.sh")
	body := "#!/bin/sh\nmkdir -p \"$TEST_BACKUP_DIR/profile-backups\"\n: > \"$TEST_BACKUP_DIR/profile-backups/trpoxy-profile-backup-alpha-20261124-120000.tar.gz\"\n"
	if err := os.WriteFile(script, []byte(body), 0700); err != nil { t.Fatal(err) }
	t.Setenv("TEST_BACKUP_DIR", backupDir)
	a := &App{base: "panel", script: script, backupDir: backupDir}
	req := httptest.NewRequest(http.MethodPost, "/panel/api/profiles/alpha", strings.NewReader(`{"Action":"export"}`))
	response := httptest.NewRecorder()
	a.profileAction(response, req)
	if response.Code != http.StatusOK { t.Fatalf("unexpected status %d: %s", response.Code, response.Body.String()) }
	if !strings.Contains(response.Body.String(), `"download_url":"/panel/api/profile-backups/trpoxy-profile-backup-alpha-20261124-120000.tar.gz"`) {
		t.Fatalf("export did not return the generated archive URL: %s", response.Body.String())
	}
}

func TestProfileActionUpdatePassesCarrierAndRotationFlags(t *testing.T) {
	dir := t.TempDir()
	capture := filepath.Join(dir, "args.txt")
	script := filepath.Join(dir, "capture.sh")
	scriptBody := "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$CAPTURE_ARGS\"\n"
	if err := os.WriteFile(script, []byte(scriptBody), 0700); err != nil { t.Fatal(err) }
	t.Setenv("CAPTURE_ARGS", capture)
	a := &App{base: "panel", script: script}
	req := httptest.NewRequest(http.MethodPost, "/panel/api/profiles/alpha", strings.NewReader(`{"Action":"update","CarrierMode":"websocket-lanes","RegenerateSecret":true}`))
	response := httptest.NewRecorder()
	a.profileAction(response, req)
	if response.Code != http.StatusOK { t.Fatalf("unexpected status %d: %s", response.Code, response.Body.String()) }
	raw, err := os.ReadFile(capture); if err != nil { t.Fatal(err) }
	args := strings.Split(strings.TrimSpace(string(raw)), "\n")
	want := []string{"profile", "update", "alpha", "--carrier-mode", "websocket-lanes", "--generate"}
	if strings.Join(args, "|") != strings.Join(want, "|") { t.Fatalf("unexpected installer arguments: %#v", args) }
}
