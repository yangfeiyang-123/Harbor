import Foundation

public enum ManagedProxyProbe {
    public static func arguments(alias: String, key: String, fallbackPort: Int) -> [String] {
        let command = "p=$(cat ~/.reverse-proxy-port 2>/dev/null); case \"$p\" in ''|*[!0-9]*) p=\(fallbackPort) ;; esac; "
            + "printf '\(key)_PORT=%s\\n' \"$p\"; "
            + "code=$(curl --silent --show-error --noproxy '' --output /dev/null --write-out '%{http_code}' --max-time 30 --proxy http://127.0.0.1:$p http://127.0.0.1:10809/); "
            + "printf '\(key)_HTTP=%s\\n' \"$code\"; test \"$code\" = 204"
        return ["-o", "BatchMode=yes", "-o", "ConnectTimeout=20", "-o", "ControlMaster=no", "-o", "ControlPath=none",
                "-o", "ClearAllForwardings=yes", "-o", "RemoteCommand=none", "-T", "--", alias, command]
    }
}
