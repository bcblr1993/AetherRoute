package distributionservice

import (
	"container/list"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"
)

type Service struct {
	productID         string
	store             *Store
	signer            Signer
	publicKey         ed25519.PublicKey
	updateEnvelope    []byte
	now               func() time.Time
	concurrency       chan struct{}
	sourceLimiter     *fixedWindowLimiter
	identityLimiter   *fixedWindowLimiter
	trustForwardedFor bool
}

func NewService(
	productID string,
	store *Store,
	signer Signer,
	publicKey ed25519.PublicKey,
	updateEnvelope []byte,
) (*Service, error) {
	if err := ValidateProductID(productID); err != nil || store == nil || signer == nil ||
		len(publicKey) != ed25519.PublicKeySize || store.productID != productID {
		return nil, errors.New("invalid service configuration")
	}
	if err := VerifyUpdateEnvelope(updateEnvelope, publicKey, productID, time.Now().UTC()); err != nil {
		return nil, errors.New("invalid update envelope")
	}
	return &Service{
		productID: productID, store: store, signer: signer,
		publicKey:       append(ed25519.PublicKey(nil), publicKey...),
		updateEnvelope:  append([]byte(nil), updateEnvelope...),
		now:             time.Now,
		concurrency:     make(chan struct{}, 64),
		sourceLimiter:   newFixedWindowLimiter(6000, time.Minute, 4096),
		identityLimiter: newFixedWindowLimiter(30, time.Hour, 100000),
	}, nil
}

// TrustForwardedFor enables one reverse-proxy-supplied client IP. The Web
// listener itself remains loopback-only; the TLS proxy must overwrite, not
// append to, X-Forwarded-For before this option is enabled.
func (service *Service) TrustForwardedFor(enabled bool) {
	service.trustForwardedFor = enabled
}

func (service *Service) Handler() http.Handler {
	return http.HandlerFunc(service.serveHTTP)
}

func (service *Service) serveHTTP(response http.ResponseWriter, request *http.Request) {
	response.Header().Set("Cache-Control", "no-store")
	response.Header().Set("Content-Type", "application/json")
	response.Header().Set("X-Content-Type-Options", "nosniff")
	select {
	case service.concurrency <- struct{}{}:
		defer func() { <-service.concurrency }()
	default:
		service.reject(response, http.StatusServiceUnavailable)
		return
	}
	if !service.sourceLimiter.Allow(
		sourceIdentity(request, service.trustForwardedFor),
		service.now(),
	) {
		service.reject(response, http.StatusTooManyRequests)
		return
	}
	switch {
	case request.URL.Path == "/v1/license" && request.Method == http.MethodPost:
		service.serveLicense(response, request)
	case request.URL.Path == "/v1/update" && request.Method == http.MethodGet:
		service.serveUpdate(response, request)
	default:
		service.reject(response, http.StatusNotFound)
	}
}

func (service *Service) serveUpdate(response http.ResponseWriter, request *http.Request) {
	if request.URL.RawQuery != "" || request.ContentLength > 0 {
		service.reject(response, http.StatusBadRequest)
		return
	}
	response.Header().Set("Content-Length", decimalLength(len(service.updateEnvelope)))
	response.WriteHeader(http.StatusOK)
	_, _ = response.Write(service.updateEnvelope)
}

func (service *Service) serveLicense(response http.ResponseWriter, request *http.Request) {
	if request.URL.RawQuery != "" || !isJSONContentType(request.Header.Get("Content-Type")) ||
		request.ContentLength > MaximumRequestBytes {
		service.reject(response, http.StatusBadRequest)
		return
	}
	reader := http.MaxBytesReader(response, request.Body, MaximumRequestBytes)
	defer reader.Close()
	body, err := io.ReadAll(reader)
	if err != nil || len(body) == 0 {
		service.reject(response, http.StatusBadRequest)
		return
	}
	var licenseRequest LicenseRequest
	if err := decodeExactJSON(body, &licenseRequest); err != nil {
		service.reject(response, http.StatusBadRequest)
		return
	}
	licenseRequest.DeviceID = strings.ToLower(strings.TrimSpace(licenseRequest.DeviceID))
	if licenseRequest.Validate(service.productID) != nil {
		service.reject(response, http.StatusBadRequest)
		return
	}
	switch licenseRequest.Action {
	case "activate":
		service.activate(response, request.Context(), licenseRequest)
	case "refresh":
		service.refresh(response, request.Context(), licenseRequest)
	case "deactivate":
		service.deactivate(response, licenseRequest)
	default:
		service.reject(response, http.StatusBadRequest)
	}
}

func (service *Service) activate(response http.ResponseWriter, ctx context.Context, request LicenseRequest) {
	if err := service.store.ReadLicenseByKey(*request.LicenseKey, func(_ *LicenseRecord) error {
		return nil
	}); err != nil {
		service.reject(response, http.StatusForbidden)
		return
	}
	identities := []string{
		"device:" + DigestHex([]byte(request.DeviceID)),
		"key:" + service.store.activationDigest(*request.LicenseKey),
	}
	if !service.identityLimiter.AllowAll(identities, service.now()) {
		service.reject(response, http.StatusTooManyRequests)
		return
	}
	var entitlement Entitlement
	err := service.store.WithLicenseByKey(*request.LicenseKey, func(record *LicenseRecord) error {
		entitlement = service.entitlement(record, request.DeviceID)
		if entitlement.State == StateActive {
			record.Devices[request.DeviceID] = true
		}
		return nil
	})
	if err != nil {
		service.reject(response, http.StatusForbidden)
		return
	}
	service.writeSigned(response, ctx, entitlement)
}

func (service *Service) refresh(response http.ResponseWriter, ctx context.Context, request LicenseRequest) {
	receipt, err := service.decodeRequestReceipt(request)
	if err != nil || receipt.DeviceID != request.DeviceID {
		service.reject(response, http.StatusForbidden)
		return
	}
	var entitlement Entitlement
	err = service.store.ReadLicenseByID(receipt.LicenseID, func(record *LicenseRecord) error {
		if !record.Devices[request.DeviceID] {
			return errors.New("device is not activated")
		}
		entitlement = service.entitlement(record, request.DeviceID)
		return nil
	})
	if err != nil {
		service.reject(response, http.StatusForbidden)
		return
	}
	identities := []string{
		"device:" + DigestHex([]byte(request.DeviceID)),
		"license:" + receipt.LicenseID,
	}
	if !service.identityLimiter.AllowAll(identities, service.now()) {
		service.reject(response, http.StatusTooManyRequests)
		return
	}
	service.writeSigned(response, ctx, entitlement)
}

func (service *Service) deactivate(response http.ResponseWriter, request LicenseRequest) {
	receipt, err := service.decodeRequestReceipt(request)
	if err != nil || receipt.DeviceID != request.DeviceID {
		service.reject(response, http.StatusForbidden)
		return
	}
	if err := service.store.ReadLicenseByID(receipt.LicenseID, func(record *LicenseRecord) error {
		if !record.Devices[request.DeviceID] {
			return errors.New("device is not activated")
		}
		return nil
	}); err != nil {
		service.reject(response, http.StatusForbidden)
		return
	}
	identities := []string{
		"device:" + DigestHex([]byte(request.DeviceID)),
		"license:" + receipt.LicenseID,
	}
	if !service.identityLimiter.AllowAll(identities, service.now()) {
		service.reject(response, http.StatusTooManyRequests)
		return
	}
	err = service.store.WithLicenseByID(receipt.LicenseID, func(record *LicenseRecord) error {
		if !record.Devices[request.DeviceID] {
			return errors.New("device is not activated")
		}
		delete(record.Devices, request.DeviceID)
		return nil
	})
	if err != nil {
		service.reject(response, http.StatusForbidden)
		return
	}
	response.Header().Del("Content-Type")
	response.WriteHeader(http.StatusNoContent)
}

func (service *Service) decodeRequestReceipt(request LicenseRequest) (Entitlement, error) {
	encoded := *request.SignedReceipt
	data, err := base64.StdEncoding.Strict().DecodeString(encoded)
	if err != nil || len(data) == 0 || len(data) > MaximumResponseBytes {
		return Entitlement{}, errors.New("invalid receipt")
	}
	receipt, err := DecodeReceipt(data, service.publicKey, service.productID, service.now().UTC())
	if err != nil {
		return Entitlement{}, err
	}
	receipt.DeviceID = strings.ToLower(strings.TrimSpace(receipt.DeviceID))
	return receipt, nil
}

func (service *Service) entitlement(record *LicenseRecord, deviceID string) Entitlement {
	now := service.now().UTC().Truncate(time.Second)
	state := record.State
	if state == StateActive && record.ExpiresAt != nil && !record.ExpiresAt.After(now) {
		state = StateExpired
	}
	if state == StateActive && !record.Devices[deviceID] && len(record.Devices) >= record.MaxDevices {
		state = StateDeviceLimit
	}
	return Entitlement{
		SchemaVersion: SchemaVersion, ProductID: service.productID,
		LicenseID: record.LicenseID, DeviceID: deviceID, State: state,
		IssuedAt: now, ExpiresAt: record.ExpiresAt,
	}
}

func (service *Service) writeSigned(response http.ResponseWriter, ctx context.Context, entitlement Entitlement) {
	envelope, err := service.signer.SignEntitlement(ctx, entitlement)
	if err != nil || len(envelope) > MaximumResponseBytes {
		service.reject(response, http.StatusServiceUnavailable)
		return
	}
	response.Header().Set("Content-Length", decimalLength(len(envelope)))
	response.WriteHeader(http.StatusOK)
	_, _ = response.Write(envelope)
}

func (service *Service) reject(response http.ResponseWriter, status int) {
	response.WriteHeader(status)
	_, _ = response.Write([]byte(`{"error":"request rejected"}`))
}

func isJSONContentType(value string) bool {
	return strings.EqualFold(strings.TrimSpace(value), "application/json")
}

func sourceIdentity(request *http.Request, trustForwardedFor bool) string {
	if trustForwardedFor {
		values := request.Header.Values("X-Forwarded-For")
		if len(values) == 1 && !strings.Contains(values[0], ",") {
			candidate := strings.TrimSpace(values[0])
			if ip := net.ParseIP(candidate); ip != nil {
				return ip.String()
			}
		}
	}
	host, _, err := net.SplitHostPort(request.RemoteAddr)
	if err == nil && host != "" {
		return host
	}
	return request.RemoteAddr
}

func decimalLength(value int) string {
	if value == 0 {
		return "0"
	}
	var digits [20]byte
	position := len(digits)
	for value > 0 {
		position--
		digits[position] = byte('0' + value%10)
		value /= 10
	}
	return string(digits[position:])
}

type fixedWindowLimiter struct {
	mutex        sync.Mutex
	limit        int
	window       time.Duration
	maximumItems int
	items        map[string]*windowCounter
	expiryOrder  *list.List
	evictableLRU *list.List
}

type windowCounter struct {
	key        string
	started    time.Time
	count      int
	expiryElem *list.Element
	lruElem    *list.Element
}

func newFixedWindowLimiter(limit int, window time.Duration, maximumItems int) *fixedWindowLimiter {
	return &fixedWindowLimiter{
		limit:        limit,
		window:       window,
		maximumItems: maximumItems,
		items:        make(map[string]*windowCounter),
		expiryOrder:  list.New(),
		evictableLRU: list.New(),
	}
}

func (limiter *fixedWindowLimiter) Allow(key string, now time.Time) bool {
	return limiter.AllowAll([]string{key}, now)
}

func (limiter *fixedWindowLimiter) AllowAll(keys []string, now time.Time) bool {
	if limiter.limit <= 0 || limiter.maximumItems <= 0 {
		return false
	}
	limiter.mutex.Lock()
	defer limiter.mutex.Unlock()

	for front := limiter.expiryOrder.Front(); front != nil; {
		next := front.Next()
		entry := front.Value.(*windowCounter)
		if now.Sub(entry.started) < limiter.window {
			break
		}
		limiter.removeEntry(entry)
		front = next
	}

	unique := make([]string, 0, len(keys))
	seen := make(map[string]struct{}, len(keys))
	newItems := 0
	for _, key := range keys {
		if key == "" {
			return false
		}
		if _, duplicate := seen[key]; duplicate {
			continue
		}
		seen[key] = struct{}{}
		unique = append(unique, key)
		counter, exists := limiter.items[key]
		if !exists {
			newItems++
		}
		if exists && counter.count >= limiter.limit {
			return false
		}
	}
	if len(unique) > limiter.maximumItems {
		return false
	}
	if overflow := len(limiter.items) + newItems - limiter.maximumItems; overflow > 0 {
		victims := make([]*windowCounter, 0, overflow)
		for elem := limiter.evictableLRU.Front(); elem != nil && len(victims) < overflow; elem = elem.Next() {
			candidate := elem.Value.(*windowCounter)
			if _, requested := seen[candidate.key]; requested {
				continue
			}
			victims = append(victims, candidate)
		}
		if len(victims) < overflow {
			return false
		}
		for _, victim := range victims {
			limiter.removeEntry(victim)
		}
	}
	for _, key := range unique {
		entry, exists := limiter.items[key]
		if !exists {
			entry = &windowCounter{
				key:     key,
				started: now,
				count:   1,
			}
			entry.expiryElem = limiter.expiryOrder.PushBack(entry)
			if entry.count < limiter.limit {
				entry.lruElem = limiter.evictableLRU.PushBack(entry)
			}
			limiter.items[key] = entry
			continue
		}
		entry.count++
		if entry.count >= limiter.limit {
			if entry.lruElem != nil {
				limiter.evictableLRU.Remove(entry.lruElem)
				entry.lruElem = nil
			}
		} else if entry.lruElem != nil {
			limiter.evictableLRU.MoveToBack(entry.lruElem)
		}
	}
	return true
}

func (limiter *fixedWindowLimiter) removeEntry(entry *windowCounter) {
	if entry.expiryElem != nil {
		limiter.expiryOrder.Remove(entry.expiryElem)
		entry.expiryElem = nil
	}
	if entry.lruElem != nil {
		limiter.evictableLRU.Remove(entry.lruElem)
		entry.lruElem = nil
	}
	delete(limiter.items, entry.key)
}
