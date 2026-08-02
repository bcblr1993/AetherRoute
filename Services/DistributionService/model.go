package distributionservice

import (
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"regexp"
	"strings"
	"time"
)

const (
	SchemaVersion          = 1
	MaximumRequestBytes    = 64 * 1024
	MaximumResponseBytes   = 64 * 1024
	MaximumSignedPayload   = 32 * 1024
	MaximumUpdateFileBytes = 64 * 1024
	MaximumStateFileBytes  = 128 * 1024 * 1024
)

var (
	productPattern   = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$`)
	devicePattern    = regexp.MustCompile(`^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$`)
	licenseIDPattern = regexp.MustCompile(`^[a-f0-9]{32}$`)
	versionPattern   = regexp.MustCompile(`^[0-9]+\.[0-9]+(?:\.[0-9]+)?$`)
	buildPattern     = regexp.MustCompile(`^[1-9][0-9]{0,17}$`)
	sha256Pattern    = regexp.MustCompile(`^[a-f0-9]{64}$`)
)

type Envelope struct {
	Payload   string `json:"payload"`
	Signature string `json:"signature"`
}

type LicenseState string

const (
	StateActive      LicenseState = "active"
	StateExpired     LicenseState = "expired"
	StateRevoked     LicenseState = "revoked"
	StateDeviceLimit LicenseState = "deviceLimit"
)

type Entitlement struct {
	SchemaVersion int          `json:"schemaVersion"`
	ProductID     string       `json:"productID"`
	LicenseID     string       `json:"licenseID"`
	DeviceID      string       `json:"deviceID"`
	State         LicenseState `json:"state"`
	IssuedAt      time.Time    `json:"issuedAt"`
	ExpiresAt     *time.Time   `json:"expiresAt"`
}

type UpdateManifest struct {
	SchemaVersion   int       `json:"schemaVersion"`
	ProductID       string    `json:"productID"`
	Version         string    `json:"version"`
	Build           int       `json:"build"`
	PublishedAt     time.Time `json:"publishedAt"`
	MinimumSystem   string    `json:"minimumSystemVersion"`
	Architecture    string    `json:"architecture"`
	DownloadURL     string    `json:"downloadURL"`
	SHA256          string    `json:"sha256"`
	ReleaseNotesURL *string   `json:"releaseNotesURL"`
}

type LicenseRequest struct {
	SchemaVersion int     `json:"schemaVersion"`
	Action        string  `json:"action"`
	ProductID     string  `json:"productID"`
	DeviceID      string  `json:"deviceID"`
	AppVersion    string  `json:"appVersion"`
	AppBuild      string  `json:"appBuild"`
	LicenseKey    *string `json:"licenseKey"`
	SignedReceipt *string `json:"signedReceipt"`
}

func ValidateProductID(productID string) error {
	if !productPattern.MatchString(productID) {
		return errors.New("invalid product ID")
	}
	return nil
}

func (request LicenseRequest) Validate(productID string) error {
	if request.SchemaVersion != SchemaVersion || request.ProductID != productID {
		return errors.New("invalid request identity")
	}
	if !devicePattern.MatchString(request.DeviceID) ||
		!versionPattern.MatchString(request.AppVersion) ||
		!buildPattern.MatchString(request.AppBuild) {
		return errors.New("invalid client metadata")
	}
	switch request.Action {
	case "activate":
		if request.LicenseKey == nil || request.SignedReceipt != nil ||
			!ValidActivationKey(*request.LicenseKey) {
			return errors.New("invalid activation request")
		}
	case "refresh", "deactivate":
		if request.LicenseKey != nil || request.SignedReceipt == nil ||
			len(*request.SignedReceipt) == 0 || len(*request.SignedReceipt) > MaximumRequestBytes {
			return errors.New("invalid receipt request")
		}
	default:
		return errors.New("invalid action")
	}
	return nil
}

func (entitlement Entitlement) Validate(productID string, now time.Time) error {
	if entitlement.SchemaVersion != SchemaVersion || entitlement.ProductID != productID ||
		!licenseIDPattern.MatchString(entitlement.LicenseID) ||
		!devicePattern.MatchString(entitlement.DeviceID) {
		return errors.New("invalid entitlement identity")
	}
	if entitlement.IssuedAt.After(now.Add(5 * time.Minute)) {
		return errors.New("entitlement issued in the future")
	}
	switch entitlement.State {
	case StateActive, StateExpired, StateRevoked, StateDeviceLimit:
	default:
		return errors.New("invalid entitlement state")
	}
	if entitlement.ExpiresAt != nil && entitlement.ExpiresAt.Before(entitlement.IssuedAt) {
		return errors.New("invalid entitlement expiry")
	}
	return nil
}

func (manifest UpdateManifest) Validate(productID string, now time.Time) error {
	if manifest.SchemaVersion != SchemaVersion || manifest.ProductID != productID ||
		!versionPattern.MatchString(manifest.Version) || manifest.Build < 1 ||
		!versionPattern.MatchString(manifest.MinimumSystem) ||
		manifest.Architecture != "arm64" || !sha256Pattern.MatchString(manifest.SHA256) ||
		manifest.PublishedAt.After(now.Add(5*time.Minute)) {
		return errors.New("invalid update manifest")
	}
	if err := validateHTTPSURL(manifest.DownloadURL); err != nil {
		return err
	}
	if manifest.ReleaseNotesURL != nil {
		if err := validateHTTPSURL(*manifest.ReleaseNotesURL); err != nil {
			return err
		}
	}
	return nil
}

func validateHTTPSURL(value string) error {
	if len(value) < len("https://a.b") || len(value) > 2048 || strings.ContainsAny(value, " \t\r\n") {
		return errors.New("invalid HTTPS URL")
	}
	parsed, err := url.Parse(value)
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" || parsed.User != nil || parsed.Fragment != "" {
		return errors.New("invalid HTTPS URL")
	}
	return nil
}

func ValidActivationKey(value string) bool {
	if len(value) != 34 || !strings.HasPrefix(value, "AR-") {
		return false
	}
	for index, character := range value[3:] {
		position := index + 3
		if position == 8 || position == 14 || position == 20 || position == 26 {
			if character != '-' {
				return false
			}
			continue
		}
		if !strings.ContainsRune("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567", character) {
			return false
		}
	}
	return true
}

func SignPayload(privateKey ed25519.PrivateKey, payload []byte) ([]byte, error) {
	if len(payload) == 0 || len(payload) > MaximumSignedPayload || len(privateKey) != ed25519.PrivateKeySize {
		return nil, errors.New("invalid signing input")
	}
	envelope := Envelope{
		Payload:   base64.StdEncoding.EncodeToString(payload),
		Signature: base64.StdEncoding.EncodeToString(ed25519.Sign(privateKey, payload)),
	}
	encoded, err := json.Marshal(envelope)
	if err != nil || len(encoded) > MaximumResponseBytes {
		return nil, errors.New("invalid signed envelope")
	}
	return encoded, nil
}

func VerifyEnvelope(data []byte, publicKey ed25519.PublicKey) ([]byte, error) {
	if len(data) == 0 || len(data) > MaximumResponseBytes || len(publicKey) != ed25519.PublicKeySize {
		return nil, errors.New("invalid envelope")
	}
	var envelope Envelope
	if err := decodeExactJSON(data, &envelope); err != nil {
		return nil, errors.New("invalid envelope")
	}
	payload, payloadErr := base64.StdEncoding.Strict().DecodeString(envelope.Payload)
	signature, signatureErr := base64.StdEncoding.Strict().DecodeString(envelope.Signature)
	if payloadErr != nil || signatureErr != nil || len(payload) == 0 ||
		len(payload) > MaximumSignedPayload || len(signature) != ed25519.SignatureSize ||
		!ed25519.Verify(publicKey, payload, signature) {
		return nil, errors.New("invalid envelope signature")
	}
	return payload, nil
}

func DecodeReceipt(data []byte, publicKey ed25519.PublicKey, productID string, now time.Time) (Entitlement, error) {
	payload, err := VerifyEnvelope(data, publicKey)
	if err != nil {
		return Entitlement{}, err
	}
	var entitlement Entitlement
	if err := decodeExactJSON(payload, &entitlement); err != nil {
		return Entitlement{}, err
	}
	if err := entitlement.Validate(productID, now); err != nil {
		return Entitlement{}, err
	}
	return entitlement, nil
}

func VerifyUpdateEnvelope(data []byte, publicKey ed25519.PublicKey, productID string, now time.Time) error {
	payload, err := VerifyEnvelope(data, publicKey)
	if err != nil {
		return err
	}
	var manifest UpdateManifest
	if err := decodeExactJSON(payload, &manifest); err != nil {
		return err
	}
	return manifest.Validate(productID, now)
}

func decodeExactJSON(data []byte, destination any) error {
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(destination); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return errors.New("trailing JSON")
	}
	return nil
}

func DigestHex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func MarshalEntitlement(entitlement Entitlement) ([]byte, error) {
	data, err := json.Marshal(entitlement)
	if err != nil {
		return nil, fmt.Errorf("marshal entitlement: %w", err)
	}
	if len(data) > MaximumSignedPayload {
		return nil, errors.New("entitlement payload is too large")
	}
	return data, nil
}
