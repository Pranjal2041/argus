package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
	"unicode"
)

var apiKeyVariablePattern = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
var dotenvUnquotedValuePattern = regexp.MustCompile(`^[A-Za-z0-9_./:@%+=,-]+$`)

type apiKeyResult struct {
	Variable       string `json:"variable"`
	Value          string `json:"value"`
	Credential     string `json:"credential"`
	AlreadyPresent bool   `json:"already_present"`
}

func cmdAPIKey(args []string) int {
	credentialName, err := parseAPIKeyRequest(args)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ut api-key:", err)
		return 2
	}
	cwd, err := os.Getwd()
	if err != nil || !filepath.IsAbs(cwd) {
		fmt.Fprintln(os.Stderr, "ut api-key: cannot determine the current folder")
		return 1
	}
	dotenvPath := filepath.Join(cwd, ".env")
	existingVariables, err := dotenvVariables(dotenvPath)
	if err != nil {
		fmt.Fprintln(os.Stderr, "ut api-key:", err)
		return 1
	}

	providerHost, _, err := findBrowserProvider()
	if err != nil {
		fmt.Fprintln(os.Stderr, "ut api-key: no running Argus credential provider found; open Argus on the Mac")
		return 1
	}
	fmt.Fprintf(os.Stderr, "Waiting for Argus approval to add saved key %q to %s…\n", credentialName, dotenvPath)
	response, err := callBrowser(providerHost, "api_keys.request", map[string]any{
		"name":               credentialName,
		"existing_variables": existingVariables,
	}, browserTimeout("api_keys.request"))
	if err != nil {
		fmt.Fprintln(os.Stderr, "ut api-key:", err)
		return 1
	}
	var result apiKeyResult
	if err := json.Unmarshal(response.Result, &result); err != nil ||
		!apiKeyVariablePattern.MatchString(result.Variable) ||
		!strings.EqualFold(result.Credential, credentialName) {
		fmt.Fprintln(os.Stderr, "ut api-key: Argus returned an invalid API-key response")
		return 1
	}
	if result.AlreadyPresent {
		if result.Value != "" {
			fmt.Fprintln(os.Stderr, "ut api-key: Argus returned an invalid API-key response")
			return 1
		}
		printExistingAPIKey(result.Variable, dotenvPath)
		return 0
	}
	if result.Value == "" {
		fmt.Fprintln(os.Stderr, "ut api-key: Argus returned an invalid API-key response")
		return 1
	}

	added, err := appendDotenvKey(dotenvPath, result.Variable, result.Value)
	result.Value = ""
	if err != nil {
		fmt.Fprintln(os.Stderr, "ut api-key:", err)
		return 1
	}
	if !added {
		printExistingAPIKey(result.Variable, dotenvPath)
		return 0
	}
	fmt.Printf("Added %s from saved key %q to %s.\n", result.Variable, result.Credential, dotenvPath)
	return 0
}

func parseAPIKeyRequest(args []string) (string, error) {
	if len(args) != 2 || args[0] != "request" {
		return "", fmt.Errorf("usage: ut api-key request <VARIABLE>")
	}
	name := strings.TrimSpace(args[1])
	if name == "" || len(name) > 128 || strings.IndexFunc(name, unicode.IsControl) >= 0 {
		return "", fmt.Errorf("enter a valid saved API-key name")
	}
	return name, nil
}

func printExistingAPIKey(variable, path string) {
	fmt.Printf("%s already exists in %s.\nNothing was changed. Check the project's .env before requesting a key.\n",
		variable, path)
}

func dotenvHasKey(path, variable string) (bool, error) {
	variables, err := dotenvVariables(path)
	if err != nil {
		return false, err
	}
	for _, existing := range variables {
		if existing == variable {
			return true, nil
		}
	}
	return false, nil
}

func dotenvDataHasKey(data []byte, variable string) bool {
	for _, existing := range dotenvVariablesFromData(data) {
		if existing == variable {
			return true
		}
	}
	return false
}

func dotenvVariables(path string) ([]string, error) {
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	return dotenvVariablesFromData(data), nil
}

func dotenvVariablesFromData(data []byte) []string {
	var variables []string
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(strings.TrimSuffix(line, "\r"))
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "export ") {
			line = strings.TrimSpace(strings.TrimPrefix(line, "export "))
		}
		if equals := strings.IndexByte(line, '='); equals >= 0 {
			variable := strings.TrimSpace(line[:equals])
			if apiKeyVariablePattern.MatchString(variable) {
				variables = append(variables, variable)
			}
		}
	}
	return variables
}

func appendDotenvKey(path, variable, value string) (bool, error) {
	if !apiKeyVariablePattern.MatchString(variable) {
		return false, fmt.Errorf("invalid environment-variable name %q", variable)
	}
	if value == "" || strings.ContainsAny(value, "\x00\r\n") {
		return false, fmt.Errorf("the saved API key is empty or cannot be represented safely in .env")
	}
	if len(value) > 64<<10 {
		return false, fmt.Errorf("the saved API key is unexpectedly large")
	}

	lockPath := path + ".argus-api-key.lock"
	deadline := time.Now().Add(5 * time.Second)
	for {
		err := os.Mkdir(lockPath, 0o700)
		if err == nil {
			break
		}
		if !os.IsExist(err) {
			return false, fmt.Errorf("lock %s: %w", path, err)
		}
		if info, statErr := os.Stat(lockPath); statErr == nil {
			if !info.IsDir() {
				return false, fmt.Errorf("cannot lock %s: %s already exists and is not a directory", path, lockPath)
			}
			if time.Since(info.ModTime()) > 30*time.Second {
				_ = os.Remove(lockPath)
				continue
			}
		}
		if time.Now().After(deadline) {
			return false, fmt.Errorf("timed out waiting to update %s", path)
		}
		time.Sleep(25 * time.Millisecond)
	}
	defer os.Remove(lockPath)

	exists, err := dotenvHasKey(path, variable)
	if err != nil || exists {
		return false, err
	}
	data, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return false, fmt.Errorf("read %s: %w", path, err)
	}
	prefix := ""
	if len(data) > 0 && data[len(data)-1] != '\n' {
		prefix = "\n"
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return false, fmt.Errorf("open %s: %w", path, err)
	}
	line := prefix + variable + "=" + quoteDotenvValue(value) + "\n"
	_, writeErr := file.WriteString(line)
	if writeErr == nil {
		writeErr = file.Sync()
	}
	closeErr := file.Close()
	if writeErr != nil {
		return false, fmt.Errorf("write %s: %w", path, writeErr)
	}
	if closeErr != nil {
		return false, fmt.Errorf("close %s: %w", path, closeErr)
	}
	return true, nil
}

func quoteDotenvValue(value string) string {
	if dotenvUnquotedValuePattern.MatchString(value) {
		return value
	}
	replacer := strings.NewReplacer(`\`, `\\`, `"`, `\"`, `$`, `\$`, "`", "\\`")
	return `"` + replacer.Replace(value) + `"`
}
