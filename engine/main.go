package main

import (
	"encoding/json"
	"fmt"
	"io"
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

func startMDNSServer(port int) (*mdns.Server, error) {
	hostName, err := os.Hostname()
	if err != nil {
		return nil, err
	}

	service, err := mdns.NewMDNSService(
		hostName,
		"_airshare._tcp",
		"",
		"",
		port,
		nil,
		[]string{fmt.Sprintf("hostname=%s", hostName)},
	)
	if err != nil {
		return nil, err
	}

	server, err := mdns.NewServer(&mdns.Config{Zone: service})
	if err != nil {
		return nil, err
	}

	return server, nil
}

func main() {
	// יצירת תיקייה אם היא לא קיימת (למקרה ששכחת)
	os.Mkdir("shared_files", 0755)

	http.HandleFunc("/files", getFiles)
	http.HandleFunc("/download", downloadFile)
	http.HandleFunc("/upload", uploadFile)

	mdnsServer, err := startMDNSServer(8080)
	if err != nil {
		fmt.Printf("Failed to start mDNS: %v\n", err)
	} else {
		defer mdnsServer.Shutdown()
		fmt.Println("mDNS service started: _airshare._tcp on port 8080")
	}

	fmt.Println("AirShare Engine is scanning 'shared_files' on port 8080...")
	http.ListenAndServe("0.0.0.0:8080", nil)
}
