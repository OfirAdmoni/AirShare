package main

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/hashicorp/mdns"
)

// sharedRootRel is the configured directory (relative or absolute). sharedRootAbs
// is its cleaned absolute form used for all reads/writes after startup.
var (
	sharedRootRel string
	sharedRootAbs string
)

func sanitizeClientFileName(raw string) (string, error) {
	if strings.TrimSpace(raw) == "" {
		return "", fmt.Errorf("empty file name")
	}
	// Single path segment only (blocks "a/b", "..\\x", UNC segments in the name).
	if strings.ContainsAny(raw, `/\`) {
		return "", fmt.Errorf("path separators in name=%q", raw)
	}
	b := filepath.Base(raw)
	if b != raw {
		return "", fmt.Errorf("name=%q is not a plain base name (got base=%q)", raw, b)
	}
	if b == "." || b == ".." {
		return "", fmt.Errorf("reserved name %q", b)
	}
	return b, nil
}

func resolveSafeSharedFile(sharedAbs, fileName string) (full string, err error) {
	full = filepath.Join(sharedAbs, fileName)
	full, err = filepath.Abs(full)
	if err != nil {
		return "", err
	}
	sa, err := filepath.Abs(sharedAbs)
	if err != nil {
		return "", err
	}
	rel, err := filepath.Rel(sa, full)
	if err != nil {
		return "", err
	}
	if rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", fmt.Errorf("path escapes shared root")
	}
	return full, nil
}

// פונקציה שסורקת את התיקייה ומחזירה רשימת שמות קבצים
func getFiles(w http.ResponseWriter, r *http.Request) {
	log.Printf("[files] list request sharedRootAbs=%q", sharedRootAbs)
	files, err := os.ReadDir(sharedRootAbs)
	if err != nil {
		log.Printf("[files] ReadDir failed path=%q err=%v", sharedRootAbs, err)
		http.Error(w, "Unable to read directory", http.StatusInternalServerError)
		return
	}

	var fileNames []string
	for _, file := range files {
		fileNames = append(fileNames, file.Name())
	}

	// הפיכת הרשימה לפורמט JSON - ככה האפליקציה (Flutter) תבין אותנו
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(fileNames)
}

func downloadFile(w http.ResponseWriter, r *http.Request) {
	rawName := r.URL.Query().Get("name")
	log.Printf("[download] request remote=%q raw_query_name=%q sharedRootAbs=%q",
		r.RemoteAddr, rawName, sharedRootAbs)

	if rawName == "" {
		http.Error(w, "Missing file name", http.StatusBadRequest)
		return
	}

	fileName, err := sanitizeClientFileName(rawName)
	if err != nil {
		log.Printf("[download] reject name sanitize raw=%q err=%v", rawName, err)
		http.Error(w, "Invalid file name", http.StatusBadRequest)
		return
	}

	filePath, err := resolveSafeSharedFile(sharedRootAbs, fileName)
	if err != nil {
		log.Printf("[download] resolve path failed name=%q err=%v", fileName, err)
		http.Error(w, "Invalid file name", http.StatusBadRequest)
		return
	}

	log.Printf("[download] resolved name=%q filePath=%q", fileName, filePath)

	info, err := os.Stat(filePath)
	if err != nil {
		log.Printf("[download] stat failed name=%q filePath=%q err=%v", fileName, filePath, err)
		http.Error(w, "File not found", http.StatusNotFound)
		return
	}
	if info.IsDir() {
		log.Printf("[download] not a file name=%q filePath=%q mode=%s", fileName, filePath, info.Mode())
		http.Error(w, "File not found", http.StatusNotFound)
		return
	}

	f, err := openFileReadShared(filePath)
	if err != nil {
		log.Printf("[download] open failed name=%q filePath=%q err=%v typ=%T", fileName, filePath, err, err)
		http.Error(w, "Unable to open file", http.StatusInternalServerError)
		return
	}
	defer f.Close()

	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=%q", fileName))
	// ServeContent handles Range requests and sets Content-Length; logs copy errors via http.Server.
	http.ServeContent(w, r, fileName, info.ModTime(), f)
}

func uploadFile(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "Method not allowed", http.StatusMethodNotAllowed)
		return
	}

	err := r.ParseMultipartForm(32 << 20)
	if err != nil {
		http.Error(w, "Invalid multipart form", http.StatusBadRequest)
		return
	}

	src, header, err := r.FormFile("file")
	if err != nil {
		http.Error(w, "Missing file field", http.StatusBadRequest)
		return
	}
	defer src.Close()

	fileName := filepath.Base(header.Filename)
	if fileName == "" || fileName == "." || fileName == ".." {
		http.Error(w, "Invalid file name", http.StatusBadRequest)
		return
	}
	sfn, serr := sanitizeClientFileName(fileName)
	if serr != nil {
		log.Printf("[upload] reject name sanitize raw=%q err=%v", fileName, serr)
		http.Error(w, "Invalid file name", http.StatusBadRequest)
		return
	}
	fileName = sfn

	if err := os.MkdirAll(sharedRootRel, 0755); err != nil {
		http.Error(w, "Unable to prepare shared directory", http.StatusInternalServerError)
		return
	}

	dstPath, err := resolveSafeSharedFile(sharedRootAbs, fileName)
	if err != nil {
		log.Printf("[upload] invalid path name=%q err=%v", fileName, err)
		http.Error(w, "Invalid file name", http.StatusBadRequest)
		return
	}
	log.Printf("[upload] writing name=%q dstPath=%q", fileName, dstPath)
	dst, err := os.Create(dstPath)
	if err != nil {
		log.Printf("[upload] Create failed dstPath=%q err=%v typ=%T", dstPath, err, err)
		http.Error(w, "Unable to save file", http.StatusInternalServerError)
		return
	}
	defer dst.Close()

	if _, err = io.Copy(dst, src); err != nil {
		http.Error(w, "Unable to write file", http.StatusInternalServerError)
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	_ = json.NewEncoder(w).Encode(map[string]string{
		"status":   "ok",
		"message":  "file uploaded",
		"fileName": fileName,
	})
}

func getLocalIPv4() (net.IP, error) {
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil, err
	}

	var fallbackIPs []net.IP

	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}

		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}

		for _, addr := range addrs {
			var ip net.IP
			switch v := addr.(type) {
			case *net.IPNet:
				ip = v.IP
			case *net.IPAddr:
				ip = v.IP
			}

			if ip == nil || ip.IsLoopback() {
				continue
			}

			ip = ip.To4()
			if ip == nil {
				continue
			}

			ipStr := ip.String()
			if strings.HasPrefix(ipStr, "169.254.") || strings.HasPrefix(ipStr, "192.168.56.") {
				continue
			}

			// Prefer common real LAN ranges first (Wi-Fi/home router/VPN).
			if strings.HasPrefix(ipStr, "192.168.1.") || strings.HasPrefix(ipStr, "10.") {
				return ip, nil
			}

			// Keep other non-virtual, non-link-local candidates as fallback.
			fallbackIPs = append(fallbackIPs, ip)
		}
	}

	if len(fallbackIPs) > 0 {
		return fallbackIPs[0], nil
	}

	return nil, fmt.Errorf("no suitable non-loopback IPv4 address found")
}

func startMDNSServer(port int) (*mdns.Server, net.IP, error) {
	hostName, err := os.Hostname()
	if err != nil {
		return nil, nil, err
	}

	localIP, err := getLocalIPv4()
	if err != nil {
		return nil, nil, err
	}

	service, err := mdns.NewMDNSService(
		hostName,
		"_airshare._tcp",
		"",
		"",
		port,
		[]net.IP{localIP},
		[]string{
			fmt.Sprintf("hostname=%s", hostName),
			fmt.Sprintf("ip=%s", localIP.String()),
		},
	)
	if err != nil {
		return nil, nil, err
	}

	server, err := mdns.NewServer(&mdns.Config{Zone: service})
	if err != nil {
		return nil, nil, err
	}

	return server, localIP, nil
}

func main() {
	sharedRootRel = strings.TrimSpace(os.Getenv("AIRSHARE_SHARED_DIR"))
	if sharedRootRel == "" {
		sharedRootRel = "shared_files"
	}
	var err error
	sharedRootAbs, err = filepath.Abs(sharedRootRel)
	if err != nil {
		log.Fatalf("[airshare] cannot resolve shared directory %q: %v", sharedRootRel, err)
	}
	log.Printf("[airshare] shared directory logical=%q absolute=%q (override with AIRSHARE_SHARED_DIR)",
		sharedRootRel, sharedRootAbs)

	if err := os.MkdirAll(sharedRootRel, 0755); err != nil {
		log.Fatalf("[airshare] mkdir %q: %v", sharedRootRel, err)
	}

	http.HandleFunc("/files", getFiles)
	http.HandleFunc("/download", downloadFile)
	http.HandleFunc("/upload", uploadFile)

	mdnsServer, localIP, err := startMDNSServer(8080)
	if err != nil {
		fmt.Printf("ERROR: Failed to start mDNS server: %v\n", err)
	} else {
		defer mdnsServer.Shutdown()
		fmt.Printf("REAL Wi-Fi IP detected: %s\n", localIP.String())
		fmt.Printf("mDNS is broadcasting on IP: %s\n", localIP.String())
		fmt.Println("mDNS service started: _airshare._tcp on port 8080")
	}

	fmt.Printf("AirShare Engine is scanning %q (%q) on port 8080...\n", sharedRootRel, sharedRootAbs)
	if err := http.ListenAndServe("0.0.0.0:8080", nil); err != nil {
		fmt.Printf("ERROR: HTTP server failed on 0.0.0.0:8080: %v\n", err)
	}
}
