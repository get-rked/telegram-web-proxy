package main

import (
	"archive/tar"
	"compress/gzip"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"regexp"
)

var backupIDPattern=regexp.MustCompile(`^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{8}$`)
type backupInfo struct { ID string `json:"id"`; CreatedAt time.Time `json:"created_at"`; Size int64 `json:"size_bytes"` }
func (a *application) backupDir()string{return filepath.Join(filepath.Dir(env("PANEL_DB","/var/lib/tproxy-panel/panel.db")),"backups")}
func (a *application) createBackup()(backupInfo,error){
	var info backupInfo
	if err:=os.MkdirAll(a.backupDir(),0700);err!=nil{return info,err}
	doc,err:=a.readProfiles();if err!=nil{return info,err}
	config,err:=os.ReadFile(a.config);if err!=nil{return info,err};if !json.Valid(config){return info,errors.New("config.json is not valid JSON")}
	suffix:=make([]byte,4);if _,err=rand.Read(suffix);err!=nil{return info,err}
	now:=time.Now().UTC();info=backupInfo{ID:now.Format("20060102T150405Z")+"-"+hex.EncodeToString(suffix),CreatedAt:now}
	path:=filepath.Join(a.backupDir(),info.ID+".tar.gz");tmp,err:=os.CreateTemp(a.backupDir(),".backup-*.tmp");if err!=nil{return info,err};tmpPath:=tmp.Name();defer os.Remove(tmpPath)
	gz:=gzip.NewWriter(tmp);tw:=tar.NewWriter(gz)
	add:=func(name string,data []byte)error{h:=&tar.Header{Name:name,Mode:0600,Size:int64(len(data)),ModTime:now,Typeflag:tar.TypeReg};if e:=tw.WriteHeader(h);e!=nil{return e};_,e:=tw.Write(data);return e}
	profiles,err:=json.MarshalIndent(doc,"","  ");if err==nil{profiles=append(profiles,'\n');err=add("profiles.json",profiles)}
	if err==nil{err=add("config.json",config)}
	if err==nil{manifest:=fmt.Sprintf("{\"version\":1,\"created_at\":%q}\n",now.Format(time.RFC3339));err=add("manifest.json",[]byte(manifest))}
	if closeErr:=tw.Close();err==nil{err=closeErr};if closeErr:=gz.Close();err==nil{err=closeErr};if err==nil{err=tmp.Sync()};if closeErr:=tmp.Close();err==nil{err=closeErr};if err!=nil{return info,err}
	if err=os.Chmod(tmpPath,0600);err!=nil{return info,err};if err=os.Rename(tmpPath,path);err!=nil{return info,err}
	stat,err:=os.Stat(path);if err==nil{info.Size=stat.Size()};_ = a.pruneBackups(20);return info,err
}
func (a *application) listBackups()([]backupInfo,error){
	entries,err:=os.ReadDir(a.backupDir());if os.IsNotExist(err){return []backupInfo{},nil};if err!=nil{return nil,err}
	items:=[]backupInfo{};for _,entry:=range entries{if entry.IsDir()||!strings.HasSuffix(entry.Name(),".tar.gz"){continue};id:=strings.TrimSuffix(entry.Name(),".tar.gz");if !backupIDPattern.MatchString(id){continue};info,e:=entry.Info();if e==nil{items=append(items,backupInfo{ID:id,CreatedAt:info.ModTime().UTC(),Size:info.Size()})}}
	sort.Slice(items,func(i,j int)bool{return items[i].CreatedAt.After(items[j].CreatedAt)});return items,nil
}
func (a *application) pruneBackups(keep int)error{
	items,err:=a.listBackups();if err!=nil{return err};for _,item:=range items[keep:]{if err:=os.Remove(filepath.Join(a.backupDir(),item.ID+".tar.gz"));err!=nil{return err}};return nil
}
func (a *application) restoreBackup(id string)error{
	if !backupIDPattern.MatchString(id){return errors.New("invalid backup id")}
	file,err:=os.Open(filepath.Join(a.backupDir(),id+".tar.gz"));if err!=nil{return err};defer file.Close()
	gz,err:=gzip.NewReader(file);if err!=nil{return err};defer gz.Close();tr:=tar.NewReader(gz)
	var profileData []byte;found:=false;entries:=0;total:=int64(0)
	for{h,e:=tr.Next();if e==io.EOF{break};if e!=nil{return e};entries++;total+=h.Size
		if entries>3||total>8<<20||h.Typeflag!=tar.TypeReg||h.Size<0||h.Size>4<<20{return errors.New("invalid archive entry")}
		switch h.Name{case "profiles.json":profileData,e=io.ReadAll(io.LimitReader(tr,4<<20));if e!=nil{return e};found=true
		case "config.json","manifest.json":if _,e=io.Copy(io.Discard,io.LimitReader(tr,4<<20));e!=nil{return e}
		default:return errors.New("archive contains unexpected path")}
	}
	if !found{return errors.New("profiles.json missing from archive")}
	var doc profileDocument;if err:=json.Unmarshal(profileData,&doc);err!=nil{return err}
	tmpPath:=a.profiles+".restore-validation";if err:=os.WriteFile(tmpPath,profileData,0600);err!=nil{return err}
	original:=a.profiles;a.profiles=tmpPath;_,validationErr:=a.readProfiles();a.profiles=original;_ = os.Remove(tmpPath)
	if validationErr!=nil{return fmt.Errorf("backup profile validation failed: %w",validationErr)}
	return a.writeProfiles(doc)
}
