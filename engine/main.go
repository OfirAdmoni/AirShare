package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
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

func main() {
	// יצירת תיקייה אם היא לא קיימת (למקרה ששכחת)
	os.Mkdir("shared_files", 0755)

	http.HandleFunc("/files", getFiles)
	http.HandleFunc("/download", downloadFile)

	fmt.Println("AirShare Engine is scanning 'shared_files' on port 8080...")
	http.ListenAndServe(":8080", nil)
}
