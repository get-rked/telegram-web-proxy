package main

import (
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
