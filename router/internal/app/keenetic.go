package app

import (
	"bytes"
	"crypto/md5"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

type RouterController struct {
	configDir string
}

type RouterAuth struct {
	Username string `json:"username"`
	Password string `json:"password"`
	BaseURL  string `json:"baseUrl"`
}

type RouterBackup struct {
	CreatedAt       string   `json:"createdAt"`
	TLSAddress      string   `json:"tlsAddress"`
	TLSSNI          string   `json:"tlsSni"`
	MainGateway     string   `json:"mainGateway"`
	MainDevice      string   `json:"mainDevice"`
	ISPInterface    string   `json:"ispInterface"`
	NameServers     []string `json:"nameServers"`
	RunningConfig   string   `json:"runningConfigPath"`
	DNSProxyStatus  string   `json:"dnsProxyStatusPath"`
	KernelRoutePath string   `json:"kernelRoutePath"`
}

type RuntimeDNSState struct {
	Active      bool
	Address     string
	SNI         string
	NameServers []string
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
	nameServers, err := c.providerNameServers()
	if err != nil {
		nameServers = parseNameServers(runningConfig)
	}
	backup := &RouterBackup{
		CreatedAt:       nowRFC3339(),
		TLSAddress:      tlsAddress,
		TLSSNI:          tlsSNI,
		MainGateway:     mainGateway,
		MainDevice:      mainDevice,
		ISPInterface:    parseISPInterface(runningConfig),
		NameServers:     nameServers,
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
	if err := c.ensureProviderDNSServers(backup); err != nil {
		return "", err
	}

	interfaceID, err := c.resolveInterfaceID(backup.ISPInterface)
	if err != nil {
		return "", err
	}

	if enabled {
		resolved, err := resolveHost(address)
		if err != nil {
			return "", err
		}
		if sni == "" {
			return "", fmt.Errorf("для включения aiway DNS нужен домен DoT/DoH")
		}

		state, err := c.RuntimeDNSState()
		if err == nil && state.Active && state.Address == resolved && state.SNI == sni {
			return "", nil
		}

		payload := []map[string]any{{
			"address":   resolved,
			"port":      853,
			"domain":    sni,
			"interface": interfaceID,
		}}
		if err := c.rciJSON(http.MethodPost, "/rci/dns-proxy/tls/upstream", payload, nil); err != nil {
			return "", err
		}
		if err := c.saveConfig(); err != nil {
			return "", err
		}
		if backup.MainGateway != "" && backup.MainDevice != "" {
			if _, err := c.shell(fmt.Sprintf("ip route replace %s/32 via %s dev %s", resolved, backup.MainGateway, backup.MainDevice)); err != nil {
				return "", err
			}
		}
		if err := c.restartDNSProxy(); err != nil {
			return "", err
		}

		state, err = c.waitForDNSState(true, resolved, sni)
		if err != nil {
			return "", err
		}
		return fmt.Sprintf("aiway DNS включен: %s через основной WAN %s", sni, backup.MainDevice), nil
	}

	state, err := c.RuntimeDNSState()
	if err != nil {
		return "", err
	}
	if !state.Active {
		return "", nil
	}

	if err := c.rciJSON(http.MethodPost, "/rci/dns-proxy/tls/upstream", []map[string]any{{"no": true}}, nil); err != nil {
		return "", err
	}
	if err := c.saveConfig(); err != nil {
		return "", err
	}
	if err := c.restartDNSProxy(); err != nil {
		return "", err
	}

	state, err = c.waitForDNSState(false, "", "")
	if err != nil {
		return "", err
	}
	if len(state.NameServers) == 0 {
		return "", fmt.Errorf("dns-proxy runtime has no provider DNS servers")
	}
	return "aiway DNS отключен; роутер вернулся к DNS провайдера", nil
}

func (c RouterController) RuntimeDNSState() (RuntimeDNSState, error) {
	payload, err := os.ReadFile("/var/ndnproxymain.conf")
	if err != nil {
		return RuntimeDNSState{}, err
	}
	return parseRuntimeDNSState(string(payload)), nil
}

func (c RouterController) CurrentTLSState() (string, string, error) {
	state, err := c.RuntimeDNSState()
	if err != nil {
		return "", "", err
	}
	return state.Address, state.SNI, nil
}

func (c RouterController) ensureProviderDNSServers(backup *RouterBackup) error {
	servers := cloneStrings(backup.NameServers)
	if len(servers) == 0 {
		var err error
		servers, err = c.providerNameServers()
		if err != nil {
			return err
		}
	}
	if len(servers) == 0 {
		return fmt.Errorf("could not determine provider DNS servers")
	}
	interfaceID, err := c.resolveInterfaceID(backup.ISPInterface)
	if err != nil {
		return err
	}
	payload := make([]map[string]any, 0, len(servers))
	for _, server := range servers {
		payload = append(payload, map[string]any{
			"address":   server,
			"interface": interfaceID,
		})
	}
	if err := c.rciJSON(http.MethodPost, "/rci/ip/name-server", payload, nil); err != nil {
		return err
	}
	if err := c.saveConfig(); err != nil {
		return err
	}
	for _, server := range servers {
		if backup.MainGateway != "" && backup.MainDevice != "" {
			if _, err := c.shell(fmt.Sprintf("ip route replace %s/32 via %s dev %s", server, backup.MainGateway, backup.MainDevice)); err != nil {
				return err
			}
		}
	}
	return nil
}

func (c RouterController) providerNameServers() ([]string, error) {
	var payload struct {
		Servers []struct {
			Address string `json:"address"`
		} `json:"server"`
	}
	if err := c.rciJSON(http.MethodGet, "/rci/show/ip/name-server", nil, &payload); err != nil {
		return nil, err
	}
	seen := map[string]struct{}{}
	servers := []string{}
	for _, server := range payload.Servers {
		address := strings.TrimSpace(server.Address)
		if net.ParseIP(address) == nil {
			continue
		}
		if _, ok := seen[address]; ok {
			continue
		}
		seen[address] = struct{}{}
		servers = append(servers, address)
	}
	sort.Strings(servers)
	return servers, nil
}

func (c RouterController) resolveInterfaceID(alias string) (string, error) {
	if alias == "" {
		alias = "ISP"
	}
	var payload map[string]struct {
		ID            string `json:"id"`
		InterfaceName string `json:"interface-name"`
	}
	if err := c.rciJSON(http.MethodGet, "/rci/show/interface", nil, &payload); err != nil {
		return "", err
	}
	for _, item := range payload {
		if item.InterfaceName == alias || item.ID == alias {
			return item.ID, nil
		}
	}
	return "", fmt.Errorf("could not resolve Keenetic interface ID for %s", alias)
}

func (c RouterController) saveConfig() error {
	return c.rciJSON(http.MethodPost, "/rci/system/configuration/save", map[string]any{}, nil)
}

func (c RouterController) restartDNSProxy() error {
	_, err := c.shell(`pid=$(pidof ndnproxy || true); if [ -n "$pid" ]; then kill $pid; fi; sleep 4; true`)
	return err
}

func (c RouterController) waitForDNSState(active bool, address string, sni string) (RuntimeDNSState, error) {
	var last RuntimeDNSState
	for i := 0; i < 10; i++ {
		time.Sleep(1 * time.Second)
		state, err := c.RuntimeDNSState()
		if err != nil {
			continue
		}
		last = state
		if active {
			if state.Active && state.Address == address && state.SNI == sni {
				return state, nil
			}
		} else {
			if !state.Active {
				return state, nil
			}
		}
	}
	if active {
		return last, fmt.Errorf("dns-proxy runtime did not switch to requested aiway endpoint")
	}
	return last, fmt.Errorf("dns-proxy runtime still points to aiway endpoint")
}

func (c RouterController) ndmc(command string) (string, error) {
	return c.shell(fmt.Sprintf("export LD_LIBRARY_PATH=/lib:/usr/lib; ndmc -c %s", shellQuote(command)))
}

func (c RouterController) routerAuth() (RouterAuth, error) {
	path := filepath.Join(c.configDir, "router-auth.json")
	payload, err := os.ReadFile(path)
	if err != nil {
		return RouterAuth{}, fmt.Errorf("router auth file is missing: %w", err)
	}
	var auth RouterAuth
	if err := json.Unmarshal(payload, &auth); err != nil {
		return RouterAuth{}, err
	}
	auth.BaseURL = strings.TrimRight(strings.TrimSpace(auth.BaseURL), "/")
	if auth.BaseURL == "" {
		auth.BaseURL = "http://192.168.1.1"
	}
	if auth.Username == "" || auth.Password == "" {
		return RouterAuth{}, fmt.Errorf("router auth file is incomplete")
	}
	return auth, nil
}

func (c RouterController) authSession() (RouterAuth, string, error) {
	auth, err := c.routerAuth()
	if err != nil {
		return RouterAuth{}, "", err
	}
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Get(auth.BaseURL + "/auth")
	if err != nil {
		return RouterAuth{}, "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		body, _ := io.ReadAll(resp.Body)
		return RouterAuth{}, "", fmt.Errorf("could not start Keenetic auth session: http %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	challenge := resp.Header.Get("X-NDM-Challenge")
	realm := resp.Header.Get("X-NDM-Realm")
	cookie := resp.Header.Get("Set-Cookie")
	if challenge == "" || realm == "" || cookie == "" {
		return RouterAuth{}, "", fmt.Errorf("could not start Keenetic auth session")
	}
	cookie = strings.Split(cookie, ";")[0]
	md5sum := md5.Sum([]byte(fmt.Sprintf("%s:%s:%s", auth.Username, realm, auth.Password)))
	sha := sha256.Sum256([]byte(challenge + hex.EncodeToString(md5sum[:])))
	payload, _ := json.Marshal(map[string]string{"login": auth.Username, "password": hex.EncodeToString(sha[:])})
	req, err := http.NewRequest(http.MethodPost, auth.BaseURL+"/auth", bytes.NewReader(payload))
	if err != nil {
		return RouterAuth{}, "", err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Cookie", cookie)
	resp2, err := client.Do(req)
	if err != nil {
		return RouterAuth{}, "", err
	}
	defer resp2.Body.Close()
	if resp2.StatusCode >= 400 {
		body, _ := io.ReadAll(resp2.Body)
		return RouterAuth{}, "", fmt.Errorf("router auth failed: %s", strings.TrimSpace(string(body)))
	}
	return auth, cookie, nil
}

func (c RouterController) rciJSON(method string, endpoint string, body any, out any) error {
	auth, cookie, err := c.authSession()
	if err != nil {
		return err
	}
	var reader io.Reader
	if body != nil {
		payload, err := json.Marshal(body)
		if err != nil {
			return err
		}
		reader = bytes.NewReader(payload)
	}
	req, err := http.NewRequest(method, auth.BaseURL+endpoint, reader)
	if err != nil {
		return err
	}
	req.Header.Set("Cookie", cookie)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := (&http.Client{Timeout: 15 * time.Second}).Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	payload, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	if resp.StatusCode >= 400 {
		return fmt.Errorf("router RCI %s %s failed: http %d: %s", method, endpoint, resp.StatusCode, strings.TrimSpace(string(payload)))
	}
	if out != nil {
		return json.Unmarshal(payload, out)
	}
	return nil
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

func parseISPInterface(input string) string {
	re := regexp.MustCompile(`^ip name-server .* on (\S+)$`)
	for _, line := range strings.Split(input, "\n") {
		line = strings.TrimSpace(line)
		match := re.FindStringSubmatch(line)
		if len(match) == 2 {
			return strings.TrimSpace(match[1])
		}
	}
	return "ISP"
}

func parseNameServers(input string) []string {
	re := regexp.MustCompile(`^ip name-server\s+([^\s:]+)`)
	seen := map[string]struct{}{}
	servers := []string{}
	for _, line := range strings.Split(input, "\n") {
		line = strings.TrimSpace(line)
		if strings.Contains(line, `"" on `) {
			continue
		}
		match := re.FindStringSubmatch(line)
		if len(match) != 2 {
			continue
		}
		address := strings.TrimSpace(match[1])
		if net.ParseIP(address) == nil {
			continue
		}
		if _, ok := seen[address]; ok {
			continue
		}
		seen[address] = struct{}{}
		servers = append(servers, address)
	}
	sort.Strings(servers)
	return servers
}

func parseRuntimeDNSState(input string) RuntimeDNSState {
	state := RuntimeDNSState{NameServers: []string{}}
	for _, line := range strings.Split(input, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "dns_server = ") {
			continue
		}
		body := strings.TrimPrefix(line, "dns_server = ")
		parts := strings.SplitN(body, "#", 2)
		fields := strings.Fields(strings.TrimSpace(parts[0]))
		if len(fields) > 0 {
			server := fields[0]
			if strings.Contains(server, ":") {
				server = strings.SplitN(server, ":", 2)[0]
			}
			if net.ParseIP(server) != nil {
				state.NameServers = append(state.NameServers, server)
			}
			if len(fields) > 1 {
				domain := strings.TrimSpace(fields[1])
				if domain != "." && domain != "" {
					state.SNI = domain
				}
			}
		}
		if len(parts) == 2 {
			comment := strings.TrimSpace(parts[1])
			if strings.Contains(comment, ":") {
				pieces := strings.SplitN(comment, ":", 2)
				if net.ParseIP(strings.TrimSpace(pieces[0])) != nil {
					state.Address = strings.TrimSpace(pieces[0])
					state.Active = true
				}
			}
		}
	}
	state.NameServers = mergeStrings(state.NameServers)
	if state.Active {
		providers := []string{}
		for _, server := range state.NameServers {
			if server != state.Address {
				providers = append(providers, server)
			}
		}
		state.NameServers = providers
	}
	return state
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
