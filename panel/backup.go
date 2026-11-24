package main

import (
	"archive/tar"
	"compress/gzip"
	"crypto/sha256"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

var backupIDPattern = regexp.MustCompile(`^[0-9]{8}T[0-9]{6}Z-[a-f0-9]{16}$`)

type backupInfo struct {
	ID        string    `json:"id"`
	CreatedAt time.Time `json:"created_at"`
	Size      int64     `json:"size_bytes"`
}

func (a *application) backupDir() string {
	if a.backupRoot != "" {
		return a.backupRoot
	}
	return filepath.Join(filepath.Dir(env("PANEL_DB", "/var/lib/tproxy-panel/panel.db")), "backups")
}

func (a *application) createBackup() (backupInfo, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	var info backupInfo
	dir := a.backupDir()
	if err := os.MkdirAll(dir, 0700); err != nil {
		return info, err
	}
	doc, err := a.readProfiles()
	if err != nil {
		return info, err
	}
	config, err := os.ReadFile(a.config)
	if err != nil {
		return info, err
	}
	if !json.Valid(config) {
		return info, errors.New("config.json is not valid JSON")
	}

	random := make([]byte, 8)
	if _, err := rand.Read(random); err != nil {
		return info, err
	}
	now := time.Now().UTC()
	info = backupInfo{
		ID:        now.Format("20060102T150405Z") + "-" + hex.EncodeToString(random),
		CreatedAt: now,
	}
	finalPath := filepath.Join(dir, info.ID+".tar.gz")
	temp, err := os.CreateTemp(dir, ".backup-*.tmp")
	if err != nil {
		return info, err
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)

	gz := gzip.NewWriter(temp)
	tw := tar.NewWriter(gz)
	add := func(name string, data []byte) error {
		header := &tar.Header{
			Name: name, Mode: 0600, Size: int64(len(data)),
			ModTime: now, Typeflag: tar.TypeReg,
		}
		if err := tw.WriteHeader(header); err != nil {
			return err
		}
		_, err := tw.Write(data)
		return err
	}

	profileData, err := json.MarshalIndent(doc, "", "  ")
	if err == nil {
		profileData = append(profileData, '\n')
		err = add("profiles.json", profileData)
	}
	if err == nil {
		err = add("config.json", config)
	}
	if err == nil {
		manifest, marshalErr := json.Marshal(map[string]any{"version": 2, "created_at": now.Format(time.RFC3339), "sha256": map[string]string{"profiles.json": fmt.Sprintf("%x", sha256.Sum256(profileData)), "config.json": fmt.Sprintf("%x", sha256.Sum256(config))}})
		if marshalErr != nil { err = marshalErr } else { err = add("manifest.json", append(manifest, 10)) }
	}
	if closeErr := tw.Close(); err == nil {
		err = closeErr
	}
	if closeErr := gz.Close(); err == nil {
		err = closeErr
	}
	if err == nil {
		err = temp.Sync()
	}
	if closeErr := temp.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return info, err
	}
	if err := os.Chmod(tempPath, 0600); err != nil {
		return info, err
	}
	// Hard-link publication is atomic and fails rather than overwriting an existing archive.
	if err := os.Link(tempPath, finalPath); err != nil {
		return info, err
	}
	if err := os.Remove(tempPath); err != nil {
		return info, err
	}
	if directory, openErr := os.Open(dir); openErr == nil {
		_ = directory.Sync()
		_ = directory.Close()
	}
	stat, err := os.Stat(finalPath)
	if err != nil {
		return info, err
	}
	info.Size = stat.Size()
	_ = a.pruneBackups(20)
	return info, nil
}

func (a *application) listBackups() ([]backupInfo, error) {
	entries, err := os.ReadDir(a.backupDir())
	if os.IsNotExist(err) {
		return []backupInfo{}, nil
	}
	if err != nil {
		return nil, err
	}
	items := []backupInfo{}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".tar.gz") {
			continue
		}
		id := strings.TrimSuffix(entry.Name(), ".tar.gz")
		if !backupIDPattern.MatchString(id) {
			continue
		}
		info, err := entry.Info()
		if err == nil && info.Mode().IsRegular() {
			items = append(items, backupInfo{ID: id, CreatedAt: info.ModTime().UTC(), Size: info.Size()})
		}
	}
	sort.Slice(items, func(i, j int) bool { return items[i].CreatedAt.After(items[j].CreatedAt) })
	return items, nil
}

func (a *application) pruneBackups(keep int) error {
	items, err := a.listBackups()
	if err != nil {
		return err
	}
	if keep < 0 {
		return errors.New("backup retention must not be negative")
	}
	if len(items) <= keep {
		return nil
	}
	for _, item := range items[keep:] {
		if err := os.Remove(filepath.Join(a.backupDir(), item.ID+".tar.gz")); err != nil {
			return err
		}
	}
	return nil
}

func pruneFileBackups(path string, keep int) error {
	if keep < 0 {
		return errors.New("backup retention must not be negative")
	}
	matches, err := filepath.Glob(path + ".backup-*")
	if err != nil {
		return err
	}
	sort.Strings(matches)
	if len(matches) <= keep {
		return nil
	}
	for _, candidate := range matches[:len(matches)-keep] {
		info, err := os.Lstat(candidate)
		if os.IsNotExist(err) {
			continue
		}
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			continue
		}
		if err := os.Remove(candidate); err != nil {
			return err
		}
	}
	return nil
}

func (a *application) restoreBackup(id string) error {
	a.mu.Lock()
	defer a.mu.Unlock()
	if !backupIDPattern.MatchString(id) {
		return errors.New("invalid backup id")
	}
	path := filepath.Join(a.backupDir(), id+".tar.gz")
	stat, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if !stat.Mode().IsRegular() || stat.Size() > 8<<20 {
		return errors.New("invalid backup file")
	}
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	gz, err := gzip.NewReader(file)
	if err != nil {
		return err
	}
	defer gz.Close()
	reader := tar.NewReader(gz)

	var profileData, configData, manifestData []byte
	seen := map[string]bool{}
	total := int64(0)
	for {
		header, err := reader.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		if header.Typeflag != tar.TypeReg || header.Size < 0 || header.Size > 4<<20 {
			return errors.New("invalid archive entry")
		}
		if seen[header.Name] {
			return errors.New("duplicate archive entry")
		}
		seen[header.Name] = true
		if len(seen) > 3 || total > (8<<20)-header.Size {
			return errors.New("archive exceeds limits")
		}
		total += header.Size

		var data []byte
		switch header.Name {
		case "profiles.json", "config.json", "manifest.json":
			data, err = io.ReadAll(reader)
			if err != nil || int64(len(data)) != header.Size {
				return errors.New("truncated archive entry")
			}
		default:
			return errors.New("archive contains unexpected path")
		}
		switch header.Name {
		case "profiles.json":
			profileData = data
		case "config.json":
			configData = data
		case "manifest.json":
			manifestData = data
		}
	}
	if len(profileData) == 0 || !json.Valid(configData) || !json.Valid(manifestData) {
		return errors.New("backup is incomplete or contains invalid JSON")
	}
	var manifest struct { Version int `json:"version"`; Files map[string]string `json:"sha256"` }
	if err := json.Unmarshal(manifestData, &manifest); err != nil || (manifest.Version != 1 && manifest.Version != 2) { return errors.New("unsupported backup manifest") }
	if manifest.Version == 2 && (manifest.Files["profiles.json"] != fmt.Sprintf("%x", sha256.Sum256(profileData)) || manifest.Files["config.json"] != fmt.Sprintf("%x", sha256.Sum256(configData))) { return errors.New("backup SHA-256 verification failed") }

	var doc profileDocument
	if err := json.Unmarshal(profileData, &doc); err != nil {
		return err
	}
	temp, err := os.CreateTemp(filepath.Dir(a.profiles), ".restore-validation-*.tmp")
	if err != nil {
		return err
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)
	if _, err := temp.Write(profileData); err != nil {
		_ = temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	original := a.profiles
	a.profiles = tempPath
	_, validationErr := a.readProfiles()
	a.profiles = original
	if validationErr != nil {
		return fmt.Errorf("backup profile validation failed: %w", validationErr)
	}
	originalConfig, err := os.ReadFile(a.config)
	if err != nil { return err }
	if err := backupFile(a.config); err != nil { return err }
	if err := writeAtomicFile(a.config, configData, 0600); err != nil { return err }
	if err := a.writeProfiles(doc); err != nil {
		if rollbackErr := writeAtomicFile(a.config, originalConfig, 0600); rollbackErr != nil { return fmt.Errorf("restore failed (%v) and config rollback failed (%v)", err, rollbackErr) }
		return fmt.Errorf("restore failed; config rolled back: %w", err)
	}
	return nil
}
