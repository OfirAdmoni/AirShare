package main

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/hashicorp/mdns"
)

// פונקציה שסורקת את התיקייה ומחזירה רשימת שמות קבצים
func getFiles(w http.ResponseWriter, r *http.Request) {
	// שנהי את הנתיב הזה לנתיב של התיקייה שיצרת בשולחן העבודה
	dirPath := "./shared_files"

	files, err := os.ReadDir(dirPath)
	if err != nil {
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
	fileName := r.URL.Query().Get("name")
	if fileName == "" {
		http.Error(w, "Missing file name", http.StatusBadRequest)
		return
	}

	// Disallow path traversal and nested paths.
	if filepath.Base(fileName) != fileName {
		http.Error(w, "Invalid file name", http.StatusBadRequest)
		return
	}

	filePath := filepath.Join("shared_files", fileName)
	info, err := os.Stat(filePath)
	if err != nil || info.IsDir() {
		http.Error(w, "File not found", http.StatusNotFound)
		return
	}

	w.Header().Set("Content-Disposition", fmt.Sprintf("attachment; filename=%q", fileName))
	http.ServeFile(w, r, filePath)
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

	ext := filepath.Ext(fileName)
	base := strings.TrimSuffix(fileName, ext)
	finalName := fileName
	serial := 1

	for {
		dstPath := filepath.Join("shared_files", finalName)
		_, err := os.Stat(dstPath)
		if os.IsNotExist(err) {
			break
		}
		if err != nil {
			http.Error(w, "Unable to check existing files", http.StatusInternalServerError)
			return
		}
		finalName = fmt.Sprintf("%s (%d)%s", base, serial, ext)
		serial++
	}

	dstPath := filepath.Join("shared_files", finalName)
	dst, err := os.Create(dstPath)
	if err != nil {
		http.Error(w, "Unable to save file", http.StatusInternalServerError)
		return
	}
	defer dst.Close()

	if _, err = io.Copy(dst, src); err != nil {
		http.Error(w, "Unable to write file", http.StatusInternalServerError)
		return
	}

	w.WriteHeader(http.StatusCreated)
	w.Write([]byte("Uploaded"))
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
	// יצירת תיקייה אם היא לא קיימת (למקרה ששכחת)
	os.Mkdir("shared_files", 0755)

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

	fmt.Println("AirShare Engine is scanning 'shared_files' on port 8080...")
	if err := http.ListenAndServe("0.0.0.0:8080", nil); err != nil {
		fmt.Printf("ERROR: HTTP server failed on 0.0.0.0:8080: %v\n", err)
	}
}
