package distributionservice

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base32"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

type LicenseRecord struct {
	LicenseID  string          `json:"licenseID"`
	State      LicenseState    `json:"state"`
	MaxDevices int             `json:"maxDevices"`
	CreatedAt  time.Time       `json:"createdAt"`
	ExpiresAt  *time.Time      `json:"expiresAt"`
	Devices    map[string]bool `json:"devices"`
}

type PersistentState struct {
	SchemaVersion int                      `json:"schemaVersion"`
	ProductID     string                   `json:"productID"`
	Revision      uint64                   `json:"revision"`
	Licenses      map[string]LicenseRecord `json:"licenses"`
	LicenseIndex  map[string]string        `json:"licenseIndex"`
}

type Store struct {
	path      string
	productID string
	pepper    []byte
}

type LicenseSummary struct {
	LicenseID   string       `json:"licenseID"`
	State       LicenseState `json:"state"`
	MaxDevices  int          `json:"maxDevices"`
	DeviceCount int          `json:"deviceCount"`
	CreatedAt   time.Time    `json:"createdAt"`
	ExpiresAt   *time.Time   `json:"expiresAt"`
}

func NewStore(path, productID string, pepper []byte) (*Store, error) {
	if !filepath.IsAbs(path) || filepath.Ext(path) != ".json" || len(pepper) != 32 {
		return nil, errors.New("invalid store configuration")
	}
	if err := ValidateProductID(productID); err != nil {
		return nil, err
	}
	canonicalPath, err := canonicalPrivatePath(path)
	if err != nil {
		return nil, err
	}
	return &Store{path: canonicalPath, productID: productID, pepper: append([]byte(nil), pepper...)}, nil
}

func ReadSecretFile(path string, expectedBytes int) ([]byte, error) {
	if !filepath.IsAbs(path) {
		return nil, errors.New("secret path must be absolute")
	}
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Mode().Perm()&0o077 != 0 {
		return nil, errors.New("secret file must be regular and mode 400 or 600")
	}
	data, err := io.ReadAll(io.LimitReader(file, int64(expectedBytes)+1))
	if err != nil {
		return nil, err
	}
	if len(data) != expectedBytes {
		return nil, fmt.Errorf("secret file must contain exactly %d bytes", expectedBytes)
	}
	return data, nil
}

func (store *Store) Issue(maxDevices int, expiresAt *time.Time, now time.Time) (string, LicenseSummary, error) {
	if maxDevices < 1 || maxDevices > 100 {
		return "", LicenseSummary{}, errors.New("max devices must be between 1 and 100")
	}
	now = now.UTC()
	if expiresAt != nil {
		value := expiresAt.UTC()
		if !value.After(now) {
			return "", LicenseSummary{}, errors.New("license expiry must be in the future")
		}
		expiresAt = &value
	}
	key, err := generateActivationKey()
	if err != nil {
		return "", LicenseSummary{}, err
	}
	digest := store.activationDigest(key)
	licenseID, err := randomHex(16)
	if err != nil {
		return "", LicenseSummary{}, err
	}
	var summary LicenseSummary
	err = store.update(func(state *PersistentState) error {
		if _, exists := state.Licenses[digest]; exists {
			return errors.New("activation digest collision")
		}
		record := LicenseRecord{
			LicenseID:  licenseID,
			State:      StateActive,
			MaxDevices: maxDevices,
			CreatedAt:  now,
			ExpiresAt:  expiresAt,
			Devices:    make(map[string]bool),
		}
		state.Licenses[digest] = record
		state.LicenseIndex[licenseID] = digest
		summary = summarize(record)
		return nil
	})
	return key, summary, err
}

func (store *Store) SetState(licenseID string, newState LicenseState) error {
	if !licenseIDPattern.MatchString(licenseID) || (newState != StateActive && newState != StateRevoked) {
		return errors.New("invalid state change")
	}
	return store.update(func(state *PersistentState) error {
		digest, exists := state.LicenseIndex[licenseID]
		if !exists {
			return errors.New("license not found")
		}
		record := state.Licenses[digest]
		record.State = newState
		state.Licenses[digest] = record
		return nil
	})
}

func (store *Store) List() ([]LicenseSummary, error) {
	var summaries []LicenseSummary
	err := store.read(func(state *PersistentState) error {
		for _, record := range state.Licenses {
			summaries = append(summaries, summarize(record))
		}
		sort.Slice(summaries, func(i, j int) bool {
			return summaries[i].CreatedAt.Before(summaries[j].CreatedAt)
		})
		return nil
	})
	return summaries, err
}

func (store *Store) WithLicenseByKey(key string, action func(*LicenseRecord) error) error {
	if !ValidActivationKey(key) {
		return errors.New("license not found")
	}
	digest := store.activationDigest(key)
	return store.update(func(state *PersistentState) error {
		record, exists := state.Licenses[digest]
		if !exists {
			return errors.New("license not found")
		}
		if err := action(&record); err != nil {
			return err
		}
		state.Licenses[digest] = record
		return nil
	})
}

func (store *Store) WithLicenseByID(licenseID string, action func(*LicenseRecord) error) error {
	return store.update(func(state *PersistentState) error {
		digest, exists := state.LicenseIndex[licenseID]
		if !exists {
			return errors.New("license not found")
		}
		record, exists := state.Licenses[digest]
		if !exists || record.LicenseID != licenseID {
			return errors.New("license index is inconsistent")
		}
		if err := action(&record); err != nil {
			return err
		}
		state.Licenses[digest] = record
		return nil
	})
}

func (store *Store) activationDigest(key string) string {
	mac := hmac.New(sha256.New, store.pepper)
	_, _ = io.WriteString(mac, strings.ToUpper(key))
	return hex.EncodeToString(mac.Sum(nil))
}

func (store *Store) update(action func(*PersistentState) error) error {
	return store.withLock(true, func(state *PersistentState) error {
		if err := action(state); err != nil {
			return err
		}
		state.Revision++
		return store.writeAtomic(*state)
	})
}

func (store *Store) read(action func(*PersistentState) error) error {
	return store.withLock(false, action)
}

func (store *Store) withLock(create bool, action func(*PersistentState) error) error {
	lock, err := os.OpenFile(
		store.path+".lock",
		os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW,
		0o600,
	)
	if err != nil {
		return err
	}
	defer lock.Close()
	lockInfo, err := lock.Stat()
	if err != nil || !lockInfo.Mode().IsRegular() || lockInfo.Mode().Perm()&0o077 != 0 {
		return errors.New("state lock must be regular and private")
	}
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	state, err := store.load(create)
	if err != nil {
		return err
	}
	return action(&state)
}

func (store *Store) load(create bool) (PersistentState, error) {
	file, err := os.OpenFile(store.path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if errors.Is(err, os.ErrNotExist) && create {
		return PersistentState{
			SchemaVersion: SchemaVersion,
			ProductID:     store.productID,
			Licenses:      make(map[string]LicenseRecord),
			LicenseIndex:  make(map[string]string),
		}, nil
	}
	if err != nil {
		return PersistentState{}, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0o077 != 0 {
		return PersistentState{}, errors.New("state file must be regular and private")
	}
	data, err := io.ReadAll(io.LimitReader(file, MaximumStateFileBytes+1))
	if err != nil || len(data) > MaximumStateFileBytes {
		return PersistentState{}, errors.New("state file exceeds the size limit")
	}
	var state PersistentState
	if err := decodeExactJSON(data, &state); err != nil {
		return PersistentState{}, err
	}
	if err := validateState(state, store.productID); err != nil {
		return PersistentState{}, err
	}
	return state, nil
}

func canonicalPrivatePath(path string) (string, error) {
	directory := filepath.Dir(filepath.Clean(path))
	resolvedDirectory, err := filepath.EvalSymlinks(directory)
	if err != nil {
		return "", errors.New("private parent directory must already exist")
	}
	info, err := os.Stat(resolvedDirectory)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0o077 != 0 {
		return "", errors.New("private parent directory must be mode 700")
	}
	return filepath.Join(resolvedDirectory, filepath.Base(path)), nil
}

func validateState(state PersistentState, productID string) error {
	if state.SchemaVersion != SchemaVersion || state.ProductID != productID ||
		state.Licenses == nil || state.LicenseIndex == nil || len(state.Licenses) > 100000 {
		return errors.New("invalid persistent state")
	}
	for digest, record := range state.Licenses {
		if !sha256Pattern.MatchString(digest) || !licenseIDPattern.MatchString(record.LicenseID) ||
			record.MaxDevices < 1 || record.MaxDevices > 100 || len(record.Devices) > record.MaxDevices ||
			record.Devices == nil || record.CreatedAt.IsZero() ||
			(record.State != StateActive && record.State != StateRevoked) ||
			(record.ExpiresAt != nil && record.ExpiresAt.Before(record.CreatedAt)) {
			return errors.New("invalid license record")
		}
		if state.LicenseIndex[record.LicenseID] != digest {
			return errors.New("invalid license index")
		}
		for device := range record.Devices {
			if !devicePattern.MatchString(device) {
				return errors.New("invalid device record")
			}
		}
	}
	if len(state.LicenseIndex) != len(state.Licenses) {
		return errors.New("invalid license index")
	}
	return nil
}

func (store *Store) writeAtomic(state PersistentState) error {
	encoded, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	encoded = append(encoded, '\n')
	directory := filepath.Dir(store.path)
	temporary, err := os.CreateTemp(directory, ".aetherroute-state-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(encoded); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporaryPath, store.path); err != nil {
		return err
	}
	directoryHandle, err := os.Open(directory)
	if err == nil {
		defer directoryHandle.Close()
		_ = directoryHandle.Sync()
	}
	return nil
}

func generateActivationKey() (string, error) {
	raw := make([]byte, 18)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	encoded := base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(raw)
	return "AR-" + encoded[0:5] + "-" + encoded[5:10] + "-" + encoded[10:15] + "-" + encoded[15:20] + "-" + encoded[20:27], nil
}

func randomHex(bytes int) (string, error) {
	raw := make([]byte, bytes)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return hex.EncodeToString(raw), nil
}

func summarize(record LicenseRecord) LicenseSummary {
	return LicenseSummary{
		LicenseID:   record.LicenseID,
		State:       record.State,
		MaxDevices:  record.MaxDevices,
		DeviceCount: len(record.Devices),
		CreatedAt:   record.CreatedAt,
		ExpiresAt:   record.ExpiresAt,
	}
}
