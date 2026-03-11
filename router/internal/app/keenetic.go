package app

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

type RouterController struct {
	configDir string
}

type RouterBackup struct {
	CreatedAt       string `json:"createdAt"`
	TLSAddress      string `json:"tlsAddress"`
	TLSSNI          string `json:"tlsSni"`
	MainGateway     string `json:"mainGateway"`
	MainDevice      string `json:"mainDevice"`
	RunningConfig   string `json:"runningConfigPath"`
	DNSProxyStatus  string `json:"dnsProxyStatusPath"`
	KernelRoutePath string `json:"kernelRoutePath"`
}

func NewRouterController(configDir string) RouterController {
	return RouterController{configDir: configDir}
}

func (c RouterController) EnsureBackup() (*RouterBackup, error) {
	backupPath := filepath.Join(c.configDir, "router-backup.json")
	if payload, err := os.ReadFile(backupPath); err == nil {
		var backup RouterBackup
		if json.Unmarshal(payload, &backup) == nil {
			return &backup, nil
		}
	}

	timestamp := time.Now().UTC().Format("20060102-150405")
	backupDir := filepath.Join(c.configDir, "backups", timestamp)
	if err := os.MkdirAll(backupDir, 0o755); err != nil {
		return nil, err
	}

	runningConfig, err := c.ndmc("show running-config")
	if err != nil {
		return nil, err
	}
	dnsProxy, err := c.ndmc("show dns-proxy")
	if err != nil {
		return nil, err
	}
	kernelRoutes, err := c.shell("ip route show table main")
	if err != nil {
		return nil, err
	}

	runningConfigPath := filepath.Join(backupDir, "running-config.cli")
	dnsProxyPath := filepath.Join(backupDir, "dns-proxy.txt")
	routePath := filepath.Join(backupDir, "routes.txt")
	if err := os.WriteFile(runningConfigPath, []byte(runningConfig), 0o600); err != nil {
		return nil, err
	}
	if err := os.WriteFile(dnsProxyPath, []byte(dnsProxy), 0o600); err != nil {
		return nil, err
	}
	if err := os.WriteFile(routePath, []byte(kernelRoutes), 0o600); err != nil {
		return nil, err
	}

	tlsAddress, tlsSNI := parseTLSState(dnsProxy)
	mainGateway, mainDevice := parseMainRoute(kernelRoutes)
	backup := &RouterBackup{
		CreatedAt:       nowRFC3339(),
		TLSAddress:      tlsAddress,
		TLSSNI:          tlsSNI,
		MainGateway:     mainGateway,
		MainDevice:      mainDevice,
		RunningConfig:   runningConfigPath,
		DNSProxyStatus:  dnsProxyPath,
		KernelRoutePath: routePath,
	}
	payload, err := json.MarshalIndent(backup, "", "  ")
	if err != nil {
		return nil, err
	}
	if err := os.WriteFile(backupPath, payload, 0o600); err != nil {
		return nil, err
	}
	return backup, nil
}

func (c RouterController) EnsureDNSState(address string, sni string, enabled bool) (string, error) {
	backup, err := c.EnsureBackup()
	if err != nil {
		return "", err
	}

	if enabled {
		resolved, err := resolveHost(address)
		if err != nil {
			return "", err
		}
		if sni == "" {
			return "", fmt.Errorf("для включения aiway DNS нужен домен DoT/DoH в профиле VPS")
		}

		if backup.MainGateway != "" && backup.MainDevice != "" {
			if _, err := c.shell(fmt.Sprintf("ip route replace %s/32 via %s dev %s", resolved, backup.MainGateway, backup.MainDevice)); err != nil {
				return "", err
			}
		}

		currentAddress, currentSNI, err := c.CurrentTLSState()
		if err == nil && currentAddress == resolved && currentSNI == sni {
			return "", nil
		}

		if _, err := c.ndmc(fmt.Sprintf("dns-proxy tls upstream %s sni %s", resolved, sni)); err != nil {
			return "", err
		}
		if _, err := c.ndmc("system configuration save"); err != nil {
			return "", err
		}
		return fmt.Sprintf("aiway DNS включен: %s через основной WAN %s", sni, backup.MainDevice), nil
	}

	currentAddress, currentSNI, err := c.CurrentTLSState()
	if err != nil {
		return "", err
	}
	if currentAddress == "" && currentSNI == "" {
		return "", nil
	}
	if _, err := c.ndmc("no dns-proxy tls upstream"); err != nil {
		return "", err
	}
	if _, err := c.ndmc("system configuration save"); err != nil {
		return "", err
	}
	return "aiway DNS отключен; роутер вернулся к обычным name-server настройкам", nil
}

func (c RouterController) CurrentTLSState() (string, string, error) {
	output, err := c.ndmc("show dns-proxy")
	if err != nil {
		return "", "", err
	}
	address, sni := parseTLSState(output)
	return address, sni, nil
}

func (c RouterController) ndmc(command string) (string, error) {
	return c.shell(fmt.Sprintf("export LD_LIBRARY_PATH=/lib:/usr/lib; ndmc -c %s", shellQuote(command)))
}

func (c RouterController) shell(command string) (string, error) {
	cmd := exec.Command("/bin/sh", "-c", command)
	output, err := cmd.CombinedOutput()
	clean := stripANSI(string(output))
	if err != nil {
		return clean, fmt.Errorf("%v: %s", err, strings.TrimSpace(clean))
	}
	return clean, nil
}

func parseTLSState(input string) (string, string) {
	addressMatch := regexp.MustCompile(`address:\s*([^\s]+)`).FindStringSubmatch(input)
	sniMatch := regexp.MustCompile(`sni:\s*([^\s]+)`).FindStringSubmatch(input)
	var address, sni string
	if len(addressMatch) == 2 {
		address = strings.TrimSpace(addressMatch[1])
	}
	if len(sniMatch) == 2 {
		sni = strings.TrimSpace(sniMatch[1])
	}
	if address == "" || address == "-" {
		address = ""
	}
	if sni == "" || sni == "-" {
		sni = ""
	}
	return address, sni
}

func parseMainRoute(input string) (string, string) {
	for _, line := range strings.Split(input, "\n") {
		line = strings.TrimSpace(line)
		if !strings.Contains(line, " via ") || !strings.Contains(line, " dev ") {
			continue
		}
		if strings.Contains(line, "opkgtun") || strings.Contains(line, " br0") {
			continue
		}
		parts := strings.Fields(line)
		for i := 0; i < len(parts)-1; i++ {
			if parts[i] == "via" && i+1 < len(parts) {
				gateway := parts[i+1]
				device := ""
				for j := i + 2; j < len(parts)-1; j++ {
					if parts[j] == "dev" {
						device = parts[j+1]
						break
					}
				}
				if gateway != "" && device != "" {
					return gateway, device
				}
			}
		}
	}
	return "", ""
}

func resolveHost(host string) (string, error) {
	host = strings.TrimSpace(host)
	if host == "" {
		return "", fmt.Errorf("в профиле не указан адрес VPS")
	}
	if ip := net.ParseIP(host); ip != nil {
		return ip.String(), nil
	}
	addresses, err := net.LookupIP(host)
	if err != nil {
		return "", fmt.Errorf("не удалось разрешить %s: %w", host, err)
	}
	for _, address := range addresses {
		if ipv4 := address.To4(); ipv4 != nil {
			return ipv4.String(), nil
		}
	}
	return "", fmt.Errorf("у %s нет IPv4 адреса", host)
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", `'"'"'`) + "'"
}

func stripANSI(value string) string {
	re := regexp.MustCompile(`\x1b\[[0-9;]*[A-Za-z]`)
	return strings.TrimSpace(re.ReplaceAllString(value, ""))
}
