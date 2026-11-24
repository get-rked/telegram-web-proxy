package main

import (
	"bytes"
 "mime/multipart"
 "net/http"
 "net/http/httptest"
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
