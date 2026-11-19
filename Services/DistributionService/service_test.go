package distributionservice

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

const testProductID = "com.aetherroute.desktop"

func TestServiceLicenseLifecycleAndUpdateContract(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	seed := bytes.Repeat([]byte{0x31}, ed25519.SeedSize)
	publicKey := ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)
	store := testStore(t)
	activationKey, summary, err := store.Issue(1, nil, now.Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	stateData, err := os.ReadFile(store.path)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(stateData, []byte(activationKey)) {
		t.Fatal("persistent state contains plaintext activation key")
	}
	if info, err := os.Stat(store.path); err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("state permissions = %v, %v", info, err)
	}

	updateEnvelope := testUpdateEnvelope(t, seed, now)
	signer, err := NewLocalSigner(seed)
	if err != nil {
		t.Fatal(err)
	}
	service, err := NewService(testProductID, store, signer, publicKey, updateEnvelope)
	if err != nil {
		t.Fatal(err)
	}
	service.now = func() time.Time { return now }
	server := httptest.NewServer(service.Handler())
	defer server.Close()

	deviceOne := "11111111-1111-4111-8111-111111111111"
	deviceTwo := "22222222-2222-4222-8222-222222222222"
	receiptOne := postLicense(t, server.URL, map[string]any{
		"schemaVersion": 1, "action": "activate", "productID": testProductID,
		"deviceID": deviceOne, "appVersion": "1.0.0", "appBuild": "100",
		"licenseKey": activationKey, "signedReceipt": nil,
	}, http.StatusOK)
	entitlement, err := DecodeReceipt(receiptOne, publicKey, testProductID, now)
	if err != nil || entitlement.State != StateActive || entitlement.LicenseID != summary.LicenseID ||
		entitlement.DeviceID != deviceOne {
		t.Fatalf("active entitlement = %+v, %v", entitlement, err)
	}

	receiptTwo := postLicense(t, server.URL, map[string]any{
		"schemaVersion": 1, "action": "activate", "productID": testProductID,
		"deviceID": deviceTwo, "appVersion": "1.0.0", "appBuild": "100",
		"licenseKey": activationKey, "signedReceipt": nil,
	}, http.StatusOK)
	deviceLimit, err := DecodeReceipt(receiptTwo, publicKey, testProductID, now)
	if err != nil || deviceLimit.State != StateDeviceLimit {
		t.Fatalf("device-limit entitlement = %+v, %v", deviceLimit, err)
	}

	refreshBody := map[string]any{
		"schemaVersion": 1, "action": "refresh", "productID": testProductID,
		"deviceID": deviceOne, "appVersion": "1.0.0", "appBuild": "100",
		"licenseKey": nil, "signedReceipt": base64.StdEncoding.EncodeToString(receiptOne),
	}
	refreshed := postLicense(t, server.URL, refreshBody, http.StatusOK)
	active, err := DecodeReceipt(refreshed, publicKey, testProductID, now)
	if err != nil || active.State != StateActive {
		t.Fatalf("refreshed entitlement = %+v, %v", active, err)
	}
	if err := store.SetState(summary.LicenseID, StateRevoked); err != nil {
		t.Fatal(err)
	}
	revokedReceipt := postLicense(t, server.URL, refreshBody, http.StatusOK)
	revoked, err := DecodeReceipt(revokedReceipt, publicKey, testProductID, now)
	if err != nil || revoked.State != StateRevoked {
		t.Fatalf("revoked entitlement = %+v, %v", revoked, err)
	}

	deactivateBody := map[string]any{
		"schemaVersion": 1, "action": "deactivate", "productID": testProductID,
		"deviceID": deviceOne, "appVersion": "1.0.0", "appBuild": "100",
		"licenseKey": nil, "signedReceipt": base64.StdEncoding.EncodeToString(revokedReceipt),
	}
	postLicense(t, server.URL, deactivateBody, http.StatusNoContent)
	postLicense(t, server.URL, refreshBody, http.StatusForbidden)

	response, err := http.Get(server.URL + "/v1/update")
	if err != nil {
		t.Fatal(err)
	}
	updateData, _ := io.ReadAll(response.Body)
	response.Body.Close()
	if response.StatusCode != http.StatusOK || !bytes.Equal(updateData, updateEnvelope) ||
		VerifyUpdateEnvelope(updateData, publicKey, testProductID, now) != nil {
		t.Fatalf("invalid update response: status=%d", response.StatusCode)
	}
}

func TestStoreConcurrentIssueAndPrivateDigest(t *testing.T) {
	store := testStore(t)
	const count = 24
	var wait sync.WaitGroup
	errorsChannel := make(chan error, count)
	keys := make(chan string, count)
	for index := 0; index < count; index++ {
		wait.Add(1)
		go func() {
			defer wait.Done()
			key, _, err := store.Issue(2, nil, time.Now().UTC())
			if err == nil {
				keys <- key
			}
			errorsChannel <- err
		}()
	}
	wait.Wait()
	close(errorsChannel)
	close(keys)
	for err := range errorsChannel {
		if err != nil {
			t.Fatal(err)
		}
	}
	summaries, err := store.List()
	if err != nil || len(summaries) != count {
		t.Fatalf("summaries=%d err=%v", len(summaries), err)
	}
	data, err := os.ReadFile(store.path)
	if err != nil {
		t.Fatal(err)
	}
	for key := range keys {
		if strings.Contains(string(data), key) {
			t.Fatal("state leaked activation key")
		}
	}
}

func TestUnixSignerKeepsPrivateKeyOutOfWebService(t *testing.T) {
	seed := bytes.Repeat([]byte{0x72}, ed25519.SeedSize)
	publicKey := ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)
	socketDirectory, err := os.MkdirTemp("/tmp", "ar-signer-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(socketDirectory) })
	socketPath := filepath.Join(socketDirectory, "signer.sock")
	server, err := NewSignerServer(socketPath, testProductID, seed)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- server.Serve(ctx) }()
	for deadline := time.Now().Add(2 * time.Second); ; {
		if info, statErr := os.Stat(socketPath); statErr == nil {
			if info.Mode().Perm() != 0o600 {
				t.Fatalf("socket permissions = %o", info.Mode().Perm())
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("signer socket did not become ready")
		}
		time.Sleep(5 * time.Millisecond)
	}
	client, err := NewSocketSigner(socketPath, testProductID, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	now := time.Now().UTC().Truncate(time.Second)
	entitlement := Entitlement{
		SchemaVersion: 1, ProductID: testProductID,
		LicenseID: strings.Repeat("a", 32), DeviceID: "33333333-3333-4333-8333-333333333333",
		State: StateActive, IssuedAt: now,
	}
	envelope, err := client.SignEntitlement(context.Background(), entitlement)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeReceipt(envelope, publicKey, testProductID, now)
	if err != nil || decoded != entitlement {
		t.Fatalf("decoded signer receipt = %+v, %v", decoded, err)
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(socketPath); !os.IsNotExist(err) {
		t.Fatal("signer socket was not removed after shutdown")
	}
}

func TestUnixSignerCanGrantOnlyItsConfiguredGroup(t *testing.T) {
	seed := bytes.Repeat([]byte{0x73}, ed25519.SeedSize)
	socketDirectory, err := os.MkdirTemp("/tmp", "ar-signer-group-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(socketDirectory) })
	socketPath := filepath.Join(socketDirectory, "signer.sock")
	server, err := NewSignerServer(socketPath, testProductID, seed)
	if err != nil {
		t.Fatal(err)
	}
	if err := server.SetSocketGroup(os.Getgid()); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- server.Serve(ctx) }()
	for deadline := time.Now().Add(2 * time.Second); ; {
		info, statErr := os.Stat(socketPath)
		if statErr == nil {
			stat, ok := info.Sys().(*syscall.Stat_t)
			if !ok || info.Mode().Perm() != 0o660 || int(stat.Gid) != os.Getgid() {
				t.Fatalf("group socket mode=%o stat=%+v", info.Mode().Perm(), stat)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("group signer socket did not become ready")
		}
		time.Sleep(5 * time.Millisecond)
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}

func TestExactJSONAndURLValidationRejectAmbiguity(t *testing.T) {
	var request LicenseRequest
	if decodeExactJSON([]byte(`{} {}`), &request) == nil {
		t.Fatal("trailing JSON was accepted")
	}
	for _, value := range []string{
		"http://downloads.example/app.dmg", "https://user@example/app.dmg",
		"https://downloads.example/app.dmg#fragment", "https://downloads.example/app dmg",
	} {
		if validateHTTPSURL(value) == nil {
			t.Fatalf("unsafe URL accepted: %q", value)
		}
	}
}

func TestSecretStateAndLockSymlinksFailClosed(t *testing.T) {
	directory := privateTempDir(t)
	secret := filepath.Join(directory, "secret.raw")
	if err := os.WriteFile(secret, bytes.Repeat([]byte{0x22}, 32), 0o600); err != nil {
		t.Fatal(err)
	}
	secretLink := filepath.Join(directory, "secret-link.raw")
	if err := os.Symlink(secret, secretLink); err != nil {
		t.Fatal(err)
	}
	if _, err := ReadSecretFile(secretLink, 32); err == nil {
		t.Fatal("secret symlink was accepted")
	}

	statePath := filepath.Join(directory, "licenses.json")
	store, err := NewStore(statePath, testProductID, bytes.Repeat([]byte{0x44}, 32))
	if err != nil {
		t.Fatal(err)
	}
	stateTarget := filepath.Join(directory, "state-target.json")
	if err := os.WriteFile(stateTarget, []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(stateTarget, statePath); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.Issue(1, nil, time.Now().UTC()); err == nil {
		t.Fatal("state symlink was accepted")
	}
	if err := os.Remove(statePath); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(statePath + ".lock"); err != nil {
		t.Fatal(err)
	}
	lockTarget := filepath.Join(directory, "lock-target")
	if err := os.WriteFile(lockTarget, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(lockTarget, statePath+".lock"); err != nil {
		t.Fatal(err)
	}
	if _, _, err := store.Issue(1, nil, time.Now().UTC()); err == nil {
		t.Fatal("state lock symlink was accepted")
	}
}

func TestStoreRequiresExistingPrivateParent(t *testing.T) {
	root := t.TempDir()
	publicDirectory := filepath.Join(root, "public")
	if err := os.Mkdir(publicDirectory, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(publicDirectory, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := NewStore(
		filepath.Join(publicDirectory, "licenses.json"), testProductID,
		bytes.Repeat([]byte{0x33}, 32),
	); err == nil {
		t.Fatal("non-private state directory was accepted")
	}
	if _, err := NewStore(
		filepath.Join(root, "missing", "licenses.json"), testProductID,
		bytes.Repeat([]byte{0x33}, 32),
	); err == nil {
		t.Fatal("missing state directory was accepted")
	}
}

func TestRateLimiterIsAtomicBoundedAndExpires(t *testing.T) {
	now := time.Now().UTC()
	limiter := newFixedWindowLimiter(2, time.Hour, 2)
	if !limiter.AllowAll([]string{"device", "key"}, now) ||
		!limiter.AllowAll([]string{"device", "key"}, now) {
		t.Fatal("valid identity requests were rejected")
	}
	if limiter.AllowAll([]string{"device", "key"}, now) {
		t.Fatal("identity rate limit was not enforced")
	}
	if limiter.Allow("third", now) {
		t.Fatal("limiter exceeded its bounded identity map")
	}
	if !limiter.Allow("third", now.Add(time.Hour)) {
		t.Fatal("expired limiter entries were not reclaimed")
	}

	// Non-saturated one-shot entries evict LRU safely while saturated abusers stay pinned.
	lruLimiter := newFixedWindowLimiter(2, time.Minute, 2)
	if !lruLimiter.Allow("abuser", now) || !lruLimiter.Allow("abuser", now) {
		t.Fatal("initial abuser window counts failed")
	}
	if lruLimiter.Allow("abuser", now) {
		t.Fatal("saturated abuser was not blocked")
	}
	for i := 0; i < 10; i++ {
		if !lruLimiter.Allow("idle-"+leftPadHex(i, 4), now) {
			t.Fatalf("one-shot source %d was blocked by LRU churn", i)
		}
	}
	if lruLimiter.Allow("abuser", now) {
		t.Fatal("LRU churn evicted a saturated rate-limited abuser")
	}
}

func TestForwardedSourceRequiresExplicitTrustAndOneIP(t *testing.T) {
	request := httptest.NewRequest(http.MethodGet, "http://service.invalid/v1/update", nil)
	request.RemoteAddr = "127.0.0.1:12345"
	request.Header.Set("X-Forwarded-For", "203.0.113.7")
	if sourceIdentity(request, false) != "127.0.0.1" {
		t.Fatal("untrusted forwarding header changed source identity")
	}
	if sourceIdentity(request, true) != "203.0.113.7" {
		t.Fatal("trusted single forwarding IP was not used")
	}
	request.Header.Set("X-Forwarded-For", "203.0.113.7, 198.51.100.8")
	if sourceIdentity(request, true) != "127.0.0.1" {
		t.Fatal("forwarding chain was accepted")
	}
}

func TestUnauthenticatedRandomLicenseRequestsCannotExhaustIdentityLimiter(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	seed := bytes.Repeat([]byte{0x51}, ed25519.SeedSize)
	publicKey := ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)
	attackerSeed := bytes.Repeat([]byte{0x99}, ed25519.SeedSize)
	attackerPrivateKey := ed25519.NewKeyFromSeed(attackerSeed)

	store := testStore(t)
	validKey, _, err := store.Issue(2, nil, now.Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	signer, err := NewLocalSigner(seed)
	if err != nil {
		t.Fatal(err)
	}
	service, err := NewService(testProductID, store, signer, publicKey, testUpdateEnvelope(t, seed, now))
	if err != nil {
		t.Fatal(err)
	}
	service.now = func() time.Time { return now }
	// Use a tight capacity so unauthenticated pollution immediately manifests if unguarded.
	service.identityLimiter = newFixedWindowLimiter(30, time.Hour, 16)

	server := httptest.NewServer(service.Handler())
	defer server.Close()

	alphabet := "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
	for i := 0; i < 40; i++ {
		c1 := alphabet[i%len(alphabet)]
		c2 := alphabet[(i/len(alphabet))%len(alphabet)]
		bogusKey := "AR-" + string([]byte{c1, c2, 'A', 'A', 'A'}) + "-BBBBB-CCCCC-DDDDD-EEEEEEE"
		bogusDevice := "00000000-0000-4000-8000-" + leftPadHex(i, 12)
		postLicense(t, server.URL, map[string]any{
			"schemaVersion": 1, "action": "activate", "productID": testProductID,
			"deviceID": bogusDevice, "appVersion": "3.0.2", "appBuild": "2026111702",
			"licenseKey": bogusKey, "signedReceipt": nil,
		}, http.StatusForbidden)

		forgedPayload, err := MarshalEntitlement(Entitlement{
			SchemaVersion: 1,
			ProductID:     testProductID,
			LicenseID:     leftPadHex(i+1000, 32),
			DeviceID:      bogusDevice,
			State:         StateActive,
			IssuedAt:      now,
		})
		if err != nil {
			t.Fatal(err)
		}
		forgedEnvelope, err := SignPayload(attackerPrivateKey, forgedPayload)
		if err != nil {
			t.Fatal(err)
		}
		postLicense(t, server.URL, map[string]any{
			"schemaVersion": 1, "action": "refresh", "productID": testProductID,
			"deviceID": bogusDevice, "appVersion": "3.0.2", "appBuild": "2026111702",
			"licenseKey": nil, "signedReceipt": base64.StdEncoding.EncodeToString(forgedEnvelope),
		}, http.StatusForbidden)
	}

	legitDevice := "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
	receipt := postLicense(t, server.URL, map[string]any{
		"schemaVersion": 1, "action": "activate", "productID": testProductID,
		"deviceID": legitDevice, "appVersion": "3.0.2", "appBuild": "2026111702",
		"licenseKey": validKey, "signedReceipt": nil,
	}, http.StatusOK)
	entitlement, err := DecodeReceipt(receipt, publicKey, testProductID, now)
	if err != nil || entitlement.State != StateActive {
		t.Fatalf("legitimate user blocked after unauthenticated flood: %+v, %v", entitlement, err)
	}
}

func TestDeviceIDCaseInsensitiveNormalizationPreventsDuplicateSlotConsumption(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	seed := bytes.Repeat([]byte{0x52}, ed25519.SeedSize)
	publicKey := ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)
	store := testStore(t)
	activationKey, _, err := store.Issue(1, nil, now.Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	signer, err := NewLocalSigner(seed)
	if err != nil {
		t.Fatal(err)
	}
	service, err := NewService(testProductID, store, signer, publicKey, testUpdateEnvelope(t, seed, now))
	if err != nil {
		t.Fatal(err)
	}
	service.now = func() time.Time { return now }
	server := httptest.NewServer(service.Handler())
	defer server.Close()

	upperWithSpace := "  AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE  "
	lowerCanonical := "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
	mixedCase := "AaAaAaAa-BbBb-4CcC-8DdD-EeEeEeEeEeEe"

	receiptOne := postLicense(t, server.URL, map[string]any{
		"schemaVersion": 1, "action": "activate", "productID": testProductID,
		"deviceID": upperWithSpace, "appVersion": "3.0.2", "appBuild": "2026111702",
		"licenseKey": activationKey, "signedReceipt": nil,
	}, http.StatusOK)
	entOne, err := DecodeReceipt(receiptOne, publicKey, testProductID, now)
	if err != nil || entOne.State != StateActive || entOne.DeviceID != lowerCanonical {
		t.Fatalf("initial uppercase activation = %+v, %v", entOne, err)
	}

	receiptTwo := postLicense(t, server.URL, map[string]any{
		"schemaVersion": 1, "action": "activate", "productID": testProductID,
		"deviceID": lowerCanonical, "appVersion": "3.0.2", "appBuild": "2026111702",
		"licenseKey": activationKey, "signedReceipt": nil,
	}, http.StatusOK)
	entTwo, err := DecodeReceipt(receiptTwo, publicKey, testProductID, now)
	if err != nil || entTwo.State != StateActive {
		t.Fatalf("same device lowercase re-activation hit deviceLimit: %+v, %v", entTwo, err)
	}

	summaries, err := store.List()
	if err != nil || len(summaries) != 1 || summaries[0].DeviceCount != 1 {
		t.Fatalf("expected 1 occupied device slot, got %+v, err=%v", summaries, err)
	}

	refreshed := postLicense(t, server.URL, map[string]any{
		"schemaVersion": 1, "action": "refresh", "productID": testProductID,
		"deviceID": upperWithSpace, "appVersion": "3.0.2", "appBuild": "2026111702",
		"licenseKey": nil, "signedReceipt": base64.StdEncoding.EncodeToString(receiptTwo),
	}, http.StatusOK)
	entRefreshed, err := DecodeReceipt(refreshed, publicKey, testProductID, now)
	if err != nil || entRefreshed.State != StateActive || entRefreshed.DeviceID != lowerCanonical {
		t.Fatalf("case-variant refresh failed: %+v, %v", entRefreshed, err)
	}

	postLicense(t, server.URL, map[string]any{
		"schemaVersion": 1, "action": "deactivate", "productID": testProductID,
		"deviceID": mixedCase, "appVersion": "3.0.2", "appBuild": "2026111702",
		"licenseKey": nil, "signedReceipt": base64.StdEncoding.EncodeToString(refreshed),
	}, http.StatusNoContent)
}

func TestRefreshUsesReadOnlyStorePathWithoutDiskWrite(t *testing.T) {
	now := time.Now().UTC().Truncate(time.Second)
	seed := bytes.Repeat([]byte{0x53}, ed25519.SeedSize)
	publicKey := ed25519.NewKeyFromSeed(seed).Public().(ed25519.PublicKey)
	store := testStore(t)
	activationKey, summary, err := store.Issue(2, nil, now.Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	signer, err := NewLocalSigner(seed)
	if err != nil {
		t.Fatal(err)
	}
	service, err := NewService(testProductID, store, signer, publicKey, testUpdateEnvelope(t, seed, now))
	if err != nil {
		t.Fatal(err)
	}
	service.now = func() time.Time { return now }
	server := httptest.NewServer(service.Handler())
	defer server.Close()

	deviceID := "11111111-1111-4111-8111-111111111111"
	receipt := postLicense(t, server.URL, map[string]any{
		"schemaVersion": 1, "action": "activate", "productID": testProductID,
		"deviceID": deviceID, "appVersion": "3.0.2", "appBuild": "2026111702",
		"licenseKey": activationKey, "signedReceipt": nil,
	}, http.StatusOK)

	beforeBytes, err := os.ReadFile(store.path)
	if err != nil {
		t.Fatal(err)
	}
	beforeInfo, err := os.Stat(store.path)
	if err != nil {
		t.Fatal(err)
	}
	beforeInode := beforeInfo.Sys().(*syscall.Stat_t).Ino

	stateDir := filepath.Dir(store.path)
	// Make directory read+exec only (0500) after creating lock file so any writeAtomic CreateTemp would fail with EACCES.
	if err := os.Chmod(stateDir, 0o500); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = os.Chmod(stateDir, 0o700) }()

	var readCopy LicenseRecord
	if err := store.ReadLicenseByID(summary.LicenseID, func(record *LicenseRecord) error {
		readCopy = *record
		return nil
	}); err != nil || readCopy.LicenseID != summary.LicenseID || !readCopy.Devices[deviceID] {
		t.Fatalf("ReadLicenseByID failed: %+v, err=%v", readCopy, err)
	}

	var wg sync.WaitGroup
	errCh := make(chan error, 8)
	encodedReceipt := base64.StdEncoding.EncodeToString(receipt)
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			body, err := json.Marshal(map[string]any{
				"schemaVersion": 1, "action": "refresh", "productID": testProductID,
				"deviceID": deviceID, "appVersion": "3.0.2", "appBuild": "2026111702",
				"licenseKey": nil, "signedReceipt": encodedReceipt,
			})
			if err != nil {
				errCh <- err
				return
			}
			req, err := http.NewRequest(http.MethodPost, server.URL+"/v1/license", bytes.NewReader(body))
			if err != nil {
				errCh <- err
				return
			}
			req.Header.Set("Content-Type", "application/json")
			resp, err := http.DefaultClient.Do(req)
			if err != nil {
				errCh <- err
				return
			}
			respData, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			if resp.StatusCode != http.StatusOK {
				errCh <- os.ErrPermission
				return
			}
			if _, err := DecodeReceipt(respData, publicKey, testProductID, now); err != nil {
				errCh <- err
			}
		}()
	}
	wg.Wait()
	close(errCh)
	for err := range errCh {
		t.Fatalf("concurrent read-only refresh failed: %v", err)
	}

	afterBytes, err := os.ReadFile(store.path)
	if err != nil {
		t.Fatal(err)
	}
	afterInfo, err := os.Stat(store.path)
	if err != nil {
		t.Fatal(err)
	}
	afterInode := afterInfo.Sys().(*syscall.Stat_t).Ino
	if beforeInode != afterInode || !bytes.Equal(beforeBytes, afterBytes) {
		t.Fatalf("refresh mutated persistent state file: inode %d -> %d", beforeInode, afterInode)
	}
}

func leftPadHex(value int, width int) string {
	const hexDigits = "0123456789abcdef"
	buf := make([]byte, width)
	for i := width - 1; i >= 0; i-- {
		buf[i] = hexDigits[value&0xf]
		value >>= 4
	}
	return string(buf)
}

func testStore(t *testing.T) *Store {
	t.Helper()
	store, err := NewStore(filepath.Join(privateTempDir(t), "licenses.json"), testProductID, bytes.Repeat([]byte{0x45}, 32))
	if err != nil {
		t.Fatal(err)
	}
	return store
}

func privateTempDir(t *testing.T) string {
	t.Helper()
	directory := t.TempDir()
	if err := os.Chmod(directory, 0o700); err != nil {
		t.Fatal(err)
	}
	return directory
}

func testUpdateEnvelope(t *testing.T, seed []byte, now time.Time) []byte {
	t.Helper()
	manifest := UpdateManifest{
		SchemaVersion: 1, ProductID: testProductID, Version: "1.0.1", Build: 101,
		PublishedAt: now.Add(-time.Minute), MinimumSystem: "15.0", Architecture: "arm64",
		DownloadURL: "https://downloads.example.com/AetherRoute-1.0.1-arm64.dmg",
		SHA256:      strings.Repeat("a", 64),
	}
	payload, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	envelope, err := SignPayload(ed25519.NewKeyFromSeed(seed), payload)
	if err != nil {
		t.Fatal(err)
	}
	return envelope
}

func postLicense(t *testing.T, baseURL string, object map[string]any, expectedStatus int) []byte {
	t.Helper()
	body, err := json.Marshal(object)
	if err != nil {
		t.Fatal(err)
	}
	request, err := http.NewRequest(http.MethodPost, baseURL+"/v1/license", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	data, err := io.ReadAll(response.Body)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != expectedStatus {
		t.Fatalf("status=%d want=%d body=%s", response.StatusCode, expectedStatus, data)
	}
	if expectedStatus == http.StatusNoContent && len(data) != 0 {
		t.Fatalf("204 response had body: %q", data)
	}
	return data
}
