import Foundation

/// Simple heuristic risk classifier for Bash commands. Used by the Mac event normalizer
/// before showing a command card on iOS. Conservative — over-classifies rather than under.
public enum RiskClassifier {

    public static func risk(forBash command: String) -> RiskLevel {
        let c = command.lowercased()
        let critical: [String] = [
            "rm -rf /", "rm -rf ~", "rm -rf $home",
            ":(){", "mkfs", "dd if=", "shutdown", "halt", "reboot",
            "chmod -r 777 /", "chown -r", "kextload", "launchctl bootout system",
            "diskutil erasevolume", "fdisk", "format c:"
        ]
        for k in critical where c.contains(k) { return .critical }

        let high: [String] = [
            "rm -rf", "sudo ", "git push --force", "git push -f",
            "git reset --hard", "git clean -fd", "git checkout -- .",
            "drop table", "drop database", "truncate ",
            "npm publish", "yarn publish", "pod trunk push", "gem push", "cargo publish",
            "kubectl delete", "terraform destroy", "aws s3 rm --recursive",
            "curl ", "wget ",
            "echo .* > /etc/", "> /etc/", " >> /etc/",
            ".env", "credentials", "secrets",
            "kill -9", "pkill"
        ]
        for k in high where c.contains(k) { return .high }

        let medium: [String] = [
            "rm ", "mv ", "git rebase", "git push", "git merge",
            "npm install -g", "brew install", "brew uninstall",
            "pip install", "pip3 install", "gem install",
            "chmod ", "chown ", "ln -s",
            "open ", "code ", "xcrun ", "xcodebuild",
            "docker rm", "docker rmi", "docker-compose down"
        ]
        for k in medium where c.contains(k) { return .medium }

        return .low
    }

    public static func risk(forFileWrite path: String) -> RiskLevel {
        let p = path.lowercased()
        if p.contains("/.env") || p.contains("/.aws") || p.contains("/.ssh") || p.contains("credentials") {
            return .critical
        }
        if p.hasSuffix(".lock") || p.contains("podfile") || p.contains("package.json") || p.contains("cargo.toml") {
            return .high
        }
        if p.contains("/configurations/") || p.hasSuffix(".plist") || p.hasSuffix(".entitlements") {
            return .medium
        }
        return .low
    }
}
