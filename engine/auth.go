package main

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"
)

const authHeader = "X-AirShare-Auth-Token"

type joinDecision struct {
	approved bool
	token    string
}

type sessionAuth struct {
	mu sync.RWMutex

	tokens map[string]string // token -> guestName

	pendingGuest string
	pendingCh    chan joinDecision

	preApprovedNames   map[string]struct{}
	preApprovedPeerIds map[string]struct{}
}

func newSessionAuth() *sessionAuth {
	return &sessionAuth{
		tokens:             map[string]string{},
		preApprovedNames:   map[string]struct{}{},
		preApprovedPeerIds: map[string]struct{}{},
	}
}

func normalizePeerId(id string) string {
	var b strings.Builder
	for _, r := range strings.ToLower(id) {
		if (r >= '0' && r <= '9') || (r >= 'a' && r <= 'f') {
			b.WriteRune(r)
		}
	}
	return b.String()
}

func decimalBtAddressToHexMac(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	for _, r := range raw {
		if r < '0' || r > '9' {
			return ""
		}
	}
	var value uint64
	for _, r := range raw {
		value = value*10 + uint64(r-'0')
	}
	if value == 0 {
		return ""
	}
	return fmt.Sprintf("%012x", value)
}

func macFromWinRTDeviceId(raw string) string {
	re := regexp.MustCompile(`(?i)([0-9a-f]{2}[:-]){5}[0-9a-f]{2}`)
	match := re.FindString(raw)
	return normalizePeerId(match)
}

func peerIdKeyVariants(raw string) []string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil
	}
	keys := []string{"id:" + raw}
	if hex := normalizePeerId(raw); hex != "" {
		keys = append(keys, "n:"+hex)
	}
	if fromDecimal := decimalBtAddressToHexMac(raw); fromDecimal != "" {
		keys = append(keys, "n:"+fromDecimal)
	}
	if fromWinRT := macFromWinRTDeviceId(raw); fromWinRT != "" {
		keys = append(keys, "n:"+fromWinRT)
	}
	return keys
}

func (s *sessionAuth) preApproveGuest(peerId, displayName string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	// Peer id only — BLE OS names are unreliable for cross-layer matching.
	for _, key := range peerIdKeyVariants(peerId) {
		s.preApprovedPeerIds[key] = struct{}{}
	}
}

func (s *sessionAuth) isPreApproved(peerId, displayName string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	for _, key := range peerIdKeyVariants(peerId) {
		if _, ok := s.preApprovedPeerIds[key]; ok {
			return true
		}
	}
	name := strings.TrimSpace(strings.ToLower(displayName))
	if name != "" {
		if _, ok := s.preApprovedNames[name]; ok {
			return true
		}
	}
	return false
}

func (s *sessionAuth) consumePreApproval(peerId, displayName string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, key := range peerIdKeyVariants(peerId) {
		delete(s.preApprovedPeerIds, key)
	}
	name := strings.TrimSpace(strings.ToLower(displayName))
	if name != "" {
		delete(s.preApprovedNames, name)
	}
}

func (s *sessionAuth) clearPreApprovals() {
	s.mu.Lock()
	s.preApprovedNames = map[string]struct{}{}
	s.preApprovedPeerIds = map[string]struct{}{}
	s.mu.Unlock()
}

func (s *sessionAuth) issueToken(guestName string) string {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	token := base64.RawURLEncoding.EncodeToString(b)
	name := strings.TrimSpace(guestName)
	if name == "" {
		name = "guest"
	}
	s.mu.Lock()
	s.tokens[token] = name
	s.mu.Unlock()
	return token
}

func (s *sessionAuth) isValidToken(token string) bool {
	token = strings.TrimSpace(token)
	if token == "" {
		return false
	}
	s.mu.RLock()
	_, ok := s.tokens[token]
	s.mu.RUnlock()
	return ok
}

func (s *sessionAuth) revokeAll() {
	s.mu.Lock()
	s.tokens = map[string]string{}
	s.preApprovedNames = map[string]struct{}{}
	s.preApprovedPeerIds = map[string]struct{}{}
	s.mu.Unlock()
}

func (s *sessionAuth) beginJoin(guestName string) (chan joinDecision, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.pendingCh != nil {
		return nil, false
	}
	s.pendingGuest = guestName
	s.pendingCh = make(chan joinDecision, 1)
	return s.pendingCh, true
}

func (s *sessionAuth) resolveJoin(approved bool) bool {
	s.mu.Lock()
	ch := s.pendingCh
	guest := s.pendingGuest
	s.pendingCh = nil
	s.pendingGuest = ""
	s.mu.Unlock()
	if ch == nil {
		return false
	}
	var token string
	if approved {
		token = s.issueToken(guest)
	}
	ch <- joinDecision{approved: approved, token: token}
	return true
}

func isHostRequest(r *http.Request) bool {
	return strings.EqualFold(strings.TrimSpace(r.Header.Get("X-AirShare-Requester-Role")), "host")
}

func (s *sessionAuth) authMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if isHostRequest(r) {
			next(w, r)
			return
		}
		token := strings.TrimSpace(r.Header.Get(authHeader))
		if !s.isValidToken(token) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusForbidden)
			_ = json.NewEncoder(w).Encode(map[string]string{
				"error":   "unauthorized",
				"message": "Valid session auth token required — POST /join first",
			})
			return
		}
		next(w, r)
	}
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}

func handleJoin(s *sessionAuth) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
			return
		}

		var body struct {
			GuestName   string `json:"guestName"`
			GuestPeerId string `json:"guestPeerId"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "Expected JSON body", http.StatusBadRequest)
			return
		}
		guestName := strings.TrimSpace(body.GuestName)
		if guestName == "" {
			guestName = "Someone"
		}
		guestPeerId := strings.TrimSpace(body.GuestPeerId)
		if guestPeerId == "" {
			guestPeerId = strings.TrimSpace(r.Header.Get("X-AirShare-Requester-Peer-Id"))
		}

		if s.isPreApproved(guestPeerId, guestName) {
			s.consumePreApproval(guestPeerId, guestName)
			token := s.issueToken(guestName)
			log.Printf("[join] %s pre-approved via BLE — token issued immediately (peerId=%q)", guestName, guestPeerId)
			writeJSON(w, http.StatusOK, map[string]string{
				"status":    "approved",
				"guestName": guestName,
				"authToken": token,
			})
			return
		}

		log.Printf("[join] pre-approval miss name=%q peerId=%q — awaiting host dialog", guestName, guestPeerId)

		ch, ok := s.beginJoin(guestName)
		if !ok {
			// Concurrent join — auto-issue token (matches Dart hub behaviour).
			token := s.issueToken(guestName)
			writeJSON(w, http.StatusOK, map[string]string{
				"status":    "approved",
				"guestName": guestName,
				"authToken": token,
			})
			return
		}

		log.Printf("[join] %s requests entry — awaiting host approval (POST /host/join-respond)", guestName)

		var decision joinDecision
		select {
		case decision = <-ch:
		case <-time.After(30 * time.Second):
			decision = joinDecision{approved: true, token: s.issueToken(guestName)}
			log.Printf("[join] auto-approved %s after timeout", guestName)
		}

		if decision.approved {
			writeJSON(w, http.StatusOK, map[string]string{
				"status":    "approved",
				"guestName": guestName,
				"authToken": decision.token,
			})
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{
			"status":    "declined",
			"guestName": guestName,
		})
	}
}

func handleJoinRespond(s *sessionAuth) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
			return
		}
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil || (host != "127.0.0.1" && host != "::1") {
			http.Error(w, "Forbidden", http.StatusForbidden)
			return
		}
		var body struct {
			Approved bool `json:"approved"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "Expected JSON body", http.StatusBadRequest)
			return
		}
		if !s.resolveJoin(body.Approved) {
			http.Error(w, "No pending join request", http.StatusConflict)
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	}
}

func handlePreApprove(s *sessionAuth) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
			return
		}
		host, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil || (host != "127.0.0.1" && host != "::1") {
			http.Error(w, "Forbidden", http.StatusForbidden)
			return
		}
		var body struct {
			GuestName   string `json:"guestName"`
			GuestPeerId string `json:"guestPeerId"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			http.Error(w, "Expected JSON body", http.StatusBadRequest)
			return
		}
		s.preApproveGuest(body.GuestPeerId, body.GuestName)
		log.Printf("[pre-approve] guest=%q peerId=%q", body.GuestName, body.GuestPeerId)
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
	}
}
