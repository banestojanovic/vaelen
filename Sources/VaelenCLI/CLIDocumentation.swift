import Foundation

struct CLIHelpEntry {
    let group: String
    let path: [String]
    let forms: [String]
    let summary: String
    let examples: [String]
    let notes: [String]
    let parserExamples: [[String]]
}

enum CLIDocumentation {
    private static func command(
        _ group: String,
        _ path: [String],
        _ forms: [String],
        _ summary: String,
        examples: [String] = [],
        notes: [String] = [],
        parses: [[String]] = []
    ) -> CLIHelpEntry {
        CLIHelpEntry(group: group, path: path, forms: forms, summary: summary, examples: examples, notes: notes, parserExamples: parses)
    }

    static let groups = ["Projects", "Overview", "Web", "Runtime", "Networking", "Integration", "Help & version"]

    private static let overviewCommands: [(String, [(String, String)])] = [
        ("Projects", [("val link", "Link and serve a project."), ("val links", "List linked projects and hosts."), ("val sites", "List configured sites."), ("val park", "Discover sites inside a workspace."), ("val project status", "Inspect a project's runtime state.")]),
        ("Runtime", [("val php versions", "See available PHP runtimes."), ("val php use <version>", "Select shell PHP."), ("val composer [arguments...]", "Run Composer with the effective project PHP."), ("val mysql status", "Check managed MySQL."), ("val mailpit status", "Check Mailpit.")]),
        ("Web & networking", [("val secure [host]", "Enable local HTTPS."), ("val route list", "List configured routes."), ("val dns status", "Check local DNS."), ("val doctor", "Check Core and managed services.")])
    ]

    private static let groupOverviews: [String: [(String, String)]] = [
        "web": [("link", "Link and serve a project."), ("links", "List linked projects and hosts."), ("sites", "List configured sites."), ("secure / unsecure", "Set local HTTPS for a host."), ("open", "Open a configured site."), ("site driver / info", "Inspect the site or run Laravel Artisan about.")],
        "runtime": [("php", "Manage PHP runtimes and project PHP."), ("mysql", "Manage the MySQL service."), ("mailpit", "Manage the Mailpit service."), ("use / which-php / ini", "PHP shell-selection and configuration shortcuts.")],
        "networking": [("routing", "Control managed Caddy."), ("route", "List and manage routes."), ("dns", "Manage local DNS."), ("tls", "Manage local HTTPS trust."), ("ports", "Manage standard local ports.")],
        "project": [("status / inspect", "See project configuration and runtime state."), ("doctor", "Find project issues and suggested actions."), ("plan", "Preview supported setup operations."), ("activate", "Apply supported project setup."), ("php", "Read or set a project PHP override.")],
        "php": [("versions", "List available and installed PHP."), ("use / default", "Select shell PHP or server default."), ("install / update / remove", "Manage PHP packages."), ("start / stop / status", "Control and inspect PHP-FPM."), ("exec / resolve", "Run PHP or resolve project-effective PHP."), ("config", "Open managed PHP configuration.")],
        "mysql": [("versions", "List available and installed MySQL."), ("install / use", "Manage and select MySQL."), ("initialize", "Initialize the selected data directory."), ("start / stop / status", "Control and inspect MySQL.")],
        "mailpit": [("versions", "List available and installed Mailpit."), ("install", "Install a managed Mailpit version."), ("start / stop / status", "Control and inspect Mailpit."), ("open", "Open the Mailpit web interface.")]
        ,"site": [("driver", "Inspect framework evidence and configured routes."), ("info", "Run Laravel Artisan about with project PHP.")],
        "routing": [("status", "Show managed Caddy status."), ("start / stop", "Control managed Caddy.")],
        "route": [("list", "List configured routes."), ("add", "Add a route with an explicit target."), ("remove", "Remove a route by ID."), ("associate", "Associate a route with a project.")],
        "dns": [("status", "Show local DNS state."), ("install [--takeover]", "Install managed local DNS."), ("remove", "Remove managed local DNS.")],
        "tls": [("status", "Show certificate and trust state."), ("install / remove", "Manage the local certificate authority."), ("trust / untrust", "Manage Keychain trust.")],
        "ports": [("status", "Show standard local port forwarding."), ("install / remove", "Manage standard local ports.")],
        "shell": [("status", "Show PHP shell integration."), ("install / uninstall", "Manage shell integration.")]
    ]

    static let entries: [CLIHelpEntry] = [
        command("Help & version", [], ["val", "val help", "val --help", "val -h", "val list"], "Show a short command overview, or use val list for the complete reference.", examples: ["val", "val list"], parses: [[], ["help"], ["--help"], ["-h"], ["list"]]),
        command("Help & version", ["help"], ["val help [COMMAND ...]"], "Show root or focused command help.", examples: ["val help", "val help php install"], parses: [["help"], ["help", "php", "install"]]),
        command("Help & version", ["--version"], ["val --version", "val -V"], "Print the CLI version.", examples: ["val --version"], parses: [["--version"], ["-V"]]),
        command("Projects", ["link"], ["val link", "val link <site-name>", "val link --path <directory>", "val link <path-like-directory>", "val link --host <hostname> [--path <directory>]"] , "Link and serve the current project or an explicit directory; an optional host adds a route.", examples: ["val link", "val link store", "val link --path ./my-app", "val link --host api.example.test"], notes: ["A simple positional token is a site name and maps to the current directory at <site-name>.test. Path-like values (`./…`, `../…`, `~/…`, absolute paths, or names ending in `.test`) select a directory. Use --path to disambiguate a bare directory name.", "Repeating an existing host is idempotent. Caddy observation is not HTTP reachability."], parses: [["link"], ["link", "store"], ["link", "--path", "./my-app"], ["link", "./my-app"], ["link", "--host", "api.example.test"], ["link", "--host", "api.example.test", "--path", "./my-app"]]),
        command("Projects", ["unlink"], ["val unlink", "val unlink <project-directory>"], "Remove Vaelen's explicit project relationship only; preserve project files and routes.", examples: ["val unlink", "val unlink ./my-app"], notes: ["With no path, the current directory is used. Remove a route separately with val route remove <route-id>."], parses: [["unlink"], ["unlink", "./my-app"]]),
        command("Projects", ["links"], ["val links", "val links --json"], "List explicitly linked projects, effective PHP and configured host observations.", examples: ["val links", "val links --json"], notes: ["Caddy route configuration observation does not prove HTTP reachability."], parses: [["links"], ["links", "--json"]]),
        command("Projects", ["edit"], ["val edit [project]"], "Open a linked project in the configured editor; defaults to the current directory.", examples: ["val edit", "val edit my-app"], parses: [["edit"], ["edit", "my-app"]]),
        command("Projects", ["park"], ["val park [workspace-folder]"], "Register a workspace folder so Vaelen can discover its sites.", examples: ["val park", "val park ~/Code"], notes: ["Default: current directory."], parses: [["park"], ["park", "~/Code"]]),
        command("Projects", ["parks"], ["val parks", "val parks --json", "val paths", "val paths --json"], "List parked workspace roots. `paths` is an alias for `parks`.", examples: ["val parks", "val paths --json"], parses: [["parks"], ["parks", "--json"], ["paths"], ["paths", "--json"]]),
        command("Projects", ["parked"], ["val parked", "val parked --json"], "List discovered projects inside parked roots; distinct from the root list `val parks`.", examples: ["val parked", "val parked --json"], parses: [["parked"], ["parked", "--json"]]),
        command("Projects", ["unpark"], ["val unpark [workspace-folder]"], "Remove a parked-folder relationship without deleting the folder.", examples: ["val unpark", "val unpark ~/Code"], notes: ["Default: current directory."], parses: [["unpark"], ["unpark", "~/Code"]]),
        command("Projects", ["sites"], ["val sites", "val sites --json"], "List configured routes, project availability and separate Caddy configuration observations.", examples: ["val sites", "val sites --json"], notes: ["A route observation is not an HTTP reachability check."], parses: [["sites"], ["sites", "--json"]]),
        command("Projects", ["open"], ["val open [hostname|project]"], "Open the selected configured host in the default browser.", examples: ["val open", "val open api.example.test", "val open my-app"], notes: ["Without a selector, the current directory must resolve to exactly one route."], parses: [["open"], ["open", "api.example.test"]]),
        command("Projects", ["db"], ["val db [project]"], "Open an eligible MySQL database in TablePlus without printing credentials.", examples: ["val db", "val db my-app"], parses: [["db"], ["db", "my-app"]]),
        command("Projects", ["site", "driver"], ["val site driver [project]", "val site driver [project] --json"], "Report detected framework evidence and every configured route separately from Caddy observation.", examples: ["val site driver", "val site driver my-app --json"], parses: [["site", "driver"], ["site", "driver", "my-app", "--json"]]),
        command("Projects", ["site", "info"], ["val site info [project]", "val site info [project] --json"], "Run Laravel Artisan about with effective project PHP; other frameworks are not supported yet.", examples: ["val site info", "val site info my-app --json"], parses: [["site", "info"], ["site", "info", "my-app", "--json"]]),
        command("Projects", ["isolated"], ["val isolated"], "List projects with explicit project-specific PHP overrides, separately from the server default.", examples: ["val isolated"], parses: [["isolated"]]),
        command("Projects", ["isolate"], ["val isolate <version> [project]"], "Set a project-specific PHP version; defaults to the current linked project.", examples: ["val isolate 8.4.23", "val isolate 8.4.23 my-app"], parses: [["isolate", "8.4.23"], ["isolate", "8.4.23", "my-app"]]),
        command("Projects", ["unisolate"], ["val unisolate [project]"], "Remove the project-specific PHP override and use the server default.", examples: ["val unisolate", "val unisolate my-app"], parses: [["unisolate"], ["unisolate", "my-app"]]),
        command("Projects", ["project", "status"], ["val project status [project]", "val project status [project] --json"], "Show desired, configured and observed project environment state.", examples: ["val project status", "val project status my-app --json"], parses: [["project", "status"], ["project", "status", "my-app", "--json"]]),
        command("Projects", ["project", "inspect"], ["val project inspect [project] [--json]"], "Inspect project configuration, diagnostics and route targets.", examples: ["val project inspect", "val project inspect my-app --json"], parses: [["project", "inspect"], ["project", "inspect", "my-app", "--json"]]),
        command("Projects", ["project", "doctor"], ["val project doctor [project] [--json]"], "Report actionable and observed project findings without applying changes.", examples: ["val project doctor"], parses: [["project", "doctor"]]),
        command("Projects", ["project", "plan"], ["val project plan [project] [--json]"], "Preview actionable project setup operations; does not apply the plan.", examples: ["val project plan", "val project plan my-app --json"], parses: [["project", "plan"], ["project", "plan", "my-app", "--json"]]),
        command("Projects", ["project", "activate"], ["val project activate [project] [--json]"], "Apply supported actionable project setup operations.", examples: ["val project activate my-app"], notes: ["May install or start managed capabilities."], parses: [["project", "activate", "my-app"]]),
        command("Projects", ["project", "php"], ["val project php [project]", "val project php [project] --version <version>", "val project php [project] --use-default", "val project php [project] --json"], "Read or set a project's PHP override. This is separate from the server default and shell-only PHP selection.", examples: ["val project php", "val project php my-app --version 8.4.23", "val project php --use-default"], parses: [["project", "php"], ["project", "php", "my-app", "--version", "8.4.23"], ["project", "php", "--use-default"], ["project", "php", "--json"]]),
        command("Overview", ["status"], ["val status", "val status --json"], "Show whether Vaelen Core is running.", examples: ["val status"], parses: [["status"], ["status", "--json"]]),
        command("Overview", ["doctor"], ["val doctor", "val doctor --json"], "Check Core and managed-service health without starting or repairing services.", examples: ["val doctor --json"], parses: [["doctor"], ["doctor", "--json"]]),
        command("Web", ["web"], ["val web"], "Show the web and site command group. Flat commands remain available.", examples: ["val web"], parses: [["web"]]),
        command("Web", ["secure"], ["val secure [hostname]"], "Enable local HTTPS on the exact host; without a hostname, select the only route for the current directory.", examples: ["val secure app.test", "val secure"], parses: [["secure"], ["secure", "app.test"]]),
        command("Web", ["unsecure"], ["val unsecure [hostname]"], "Serve the selected route over HTTP without redirect.", examples: ["val unsecure app.test"], parses: [["unsecure", "app.test"]]),
        command("Runtime", ["runtime"], ["val runtime"], "Show PHP, MySQL and Mailpit command groups. Flat commands remain available.", examples: ["val runtime"], parses: [["runtime"]]),
        command("Runtime", ["php", "versions"], ["val php versions", "val php versions --json"], "List PHP versions available and installed in Vaelen.", examples: ["val php versions --json"], parses: [["php", "versions"], ["php", "versions", "--json"]]),
        command("Runtime", ["php", "default"], ["val php default", "val php default --json", "val php default <version>", "val php default set <version>"], "Read or change the server's default PHP version. Does not change project overrides or shell-only selection.", examples: ["val php default", "val php default set 8.4.23"], notes: ["The direct version form is a legacy setter; prefer `val php default set <version>`."], parses: [["php", "default"], ["php", "default", "--json"], ["php", "default", "8.4.23"], ["php", "default", "set", "8.4.23"]]),
        command("Runtime", ["php", "install"], ["val php install <version>"], "Install a managed PHP version.", examples: ["val php install 8.4"], parses: [["php", "install", "8.4"]]),
        command("Runtime", ["php", "update"], ["val php update <version>"], "Update an installed managed PHP version.", examples: ["val php update 8.4"], parses: [["php", "update", "8.4"]]),
        command("Runtime", ["php", "remove"], ["val php remove <version>"], "Remove a managed PHP version.", examples: ["val php remove 8.3"], parses: [["php", "remove", "8.3"]]),
        command("Runtime", ["php", "operation"], ["val php operation", "val php operation --json"], "Show the current PHP package operation, if any.", examples: ["val php operation"], parses: [["php", "operation"], ["php", "operation", "--json"]]),
        command("Runtime", ["php", "use"], ["val php use <version>"], "Select the shell/CLI PHP version; this does not change the server default.", examples: ["val php use 8.4.23"], parses: [["php", "use", "8.4.23"]]),
        command("Runtime", ["php", "start"], ["val php start <version>"], "Start PHP-FPM for a managed version.", examples: ["val php start 8.4.23"], parses: [["php", "start", "8.4.23"]]),
        command("Runtime", ["php", "stop"], ["val php stop <version>"], "Stop PHP-FPM for a managed version.", examples: ["val php stop 8.4.23"], parses: [["php", "stop", "8.4.23"]]),
        command("Runtime", ["php", "status"], ["val php status <version>", "val php status <version> --json"], "Show package, FPM and health state for a managed PHP version.", examples: ["val php status 8.4.23 --json"], parses: [["php", "status", "8.4.23"], ["php", "status", "8.4.23", "--json"]]),
        command("Runtime", ["php", "config"], ["val php config", "val php config <version>"], "Open the managed PHP configuration folder or the selected version's FPM ini in the configured editor.", examples: ["val php config", "val php config 8.4.23"], parses: [["php", "config"], ["php", "config", "8.4.23"]]),
        command("Runtime", ["php", "exec"], ["val php exec [--effective] -- <arguments...>"], "Run a PHP child process and relay its output and exit code unchanged.", examples: ["val php exec -- -v", "val php exec --effective -- artisan about"], notes: ["The `--` marker is required. By default uses the currently selected CLI PHP; --effective selects this project's managed effective PHP."], parses: [["php", "exec", "--", "-v"], ["php", "exec", "--effective", "--", "artisan", "about"]]),
        command("Runtime", ["php", "resolve"], ["val php resolve --path"], "Print the effective project PHP executable path as a single plain-text line.", examples: ["val php resolve --path"], parses: [["php", "resolve", "--path"]]),
        command("Runtime", ["composer"], ["val composer [arguments...]"], "Run the PATH Composer PHP script with the effective PHP selected by Vaelen Core.", examples: ["val composer install", "val composer --version"], notes: ["Composer lookup checks `composer` and then `composer.phar` in each PATH directory, from left to right. Empty PATH entries use the invocation directory; relative entries resolve from that directory. An unset PATH has no entries. The first existing candidate must be a readable regular PHP script or PHAR stub. Vaelen follows symlinks and stops with an error if that candidate is incompatible. All arguments are forwarded unchanged."], parses: [["composer"], ["composer", "install"], ["composer", "--help"]]),
        command("Runtime", ["use"], ["val use <version>"], "Alias for val php use: select CLI/shell PHP without changing the server default.", examples: ["val use 8.4.23"], parses: [["use", "8.4.23"]]),
        command("Runtime", ["which-php"], ["val which-php"], "Print the effective project PHP executable path.", examples: ["val which-php"], parses: [["which-php"]]),
        command("Runtime", ["ini"], ["val ini", "val ini <version>"], "Open the effective project's managed FPM ini, or the requested installed version's ini.", examples: ["val ini", "val ini 8.4.23"], parses: [["ini"], ["ini", "8.4.23"]]),
        command("Runtime", ["mysql", "versions"], ["val mysql versions", "val mysql versions --json"], "List supported and installed MySQL versions.", examples: ["val mysql versions"], parses: [["mysql", "versions"], ["mysql", "versions", "--json"]]),
        command("Runtime", ["mysql", "install"], ["val mysql install <version>"], "Install a managed MySQL version.", examples: ["val mysql install 8.4"], parses: [["mysql", "install", "8.4"]]),
        command("Runtime", ["mysql", "use"], ["val mysql use <version>"], "Select the managed MySQL version.", examples: ["val mysql use 8.4"], parses: [["mysql", "use", "8.4"]]),
        command("Runtime", ["mysql", "initialize"], ["val mysql initialize"], "Initialize the selected MySQL data directory.", examples: ["val mysql initialize"], parses: [["mysql", "initialize"]]),
        command("Runtime", ["mysql", "start"], ["val mysql start"], "Start managed MySQL.", examples: ["val mysql start"], parses: [["mysql", "start"]]),
        command("Runtime", ["mysql", "stop"], ["val mysql stop"], "Stop managed MySQL without deleting its data.", examples: ["val mysql stop"], parses: [["mysql", "stop"]]),
        command("Runtime", ["mysql", "status"], ["val mysql status", "val mysql status --json"], "Show MySQL runtime state.", examples: ["val mysql status --json"], parses: [["mysql", "status"], ["mysql", "status", "--json"]]),
        command("Runtime", ["mailpit", "versions"], ["val mailpit versions", "val mailpit versions --json"], "List supported and installed Mailpit versions.", examples: ["val mailpit versions"], parses: [["mailpit", "versions"], ["mailpit", "versions", "--json"]]),
        command("Runtime", ["mailpit", "install"], ["val mailpit install <version>"], "Install a managed Mailpit version.", examples: ["val mailpit install latest"], parses: [["mailpit", "install", "latest"]]),
        command("Runtime", ["mailpit", "start"], ["val mailpit start"], "Start managed Mailpit.", examples: ["val mailpit start"], parses: [["mailpit", "start"]]),
        command("Runtime", ["mailpit", "stop"], ["val mailpit stop"], "Stop managed Mailpit.", examples: ["val mailpit stop"], parses: [["mailpit", "stop"]]),
        command("Runtime", ["mailpit", "status"], ["val mailpit status", "val mailpit status --json"], "Show Mailpit runtime state.", examples: ["val mailpit status"], parses: [["mailpit", "status"], ["mailpit", "status", "--json"]]),
        command("Runtime", ["mailpit", "open"], ["val mailpit open"], "Open the Mailpit web interface when the service is running.", examples: ["val mailpit open"], parses: [["mailpit", "open"]]),
        command("Networking", ["routing", "status"], ["val routing status"], "Show Caddy routing state.", examples: ["val routing status"], parses: [["routing", "status"]]),
        command("Networking", ["networking"], ["val networking"], "Show DNS, TLS, ports, router and route commands. Flat commands remain available.", examples: ["val networking"], parses: [["networking"]]),
        command("Networking", ["routing", "start"], ["val routing start"], "Start managed Caddy routing.", examples: ["val routing start"], parses: [["routing", "start"]]),
        command("Networking", ["routing", "stop"], ["val routing stop"], "Stop managed Caddy routing.", examples: ["val routing stop"], parses: [["routing", "stop"]]),
        command("Networking", ["route", "list"], ["val route list", "val route list --json"], "List configured route intents. A configured route is not a reachability check.", examples: ["val route list --json"], parses: [["route", "list"], ["route", "list", "--json"]]),
        command("Networking", ["route", "add"], ["val route add <hostname> <document-root> [--php-socket <path>] [--project-id <uuid>] [--tls]"], "Add a route with explicit target configuration.", examples: ["val route add app.test ./public", "val route add app.test ./public --php-socket /tmp/php.sock --tls"], notes: ["--php-socket and --project-id each take a value; --tls takes no value. Options may be combined."], parses: [["route", "add", "app.test", "./public"], ["route", "add", "app.test", "./public", "--php-socket", "/tmp/php.sock", "--tls"], ["route", "add", "app.test", "./public", "--project-id", "00000000-0000-0000-0000-000000000002"]]),
        command("Networking", ["route", "remove"], ["val route remove <route-id>"], "Remove exactly the specified route.", examples: ["val route remove 00000000-0000-0000-0000-000000000001"], parses: [["route", "remove", "00000000-0000-0000-0000-000000000001"]]),
        command("Networking", ["route", "associate"], ["val route associate <route-id> <project-id>"], "Associate an existing route with a project.", examples: ["val route associate 00000000-0000-0000-0000-000000000001 00000000-0000-0000-0000-000000000002"], parses: [["route", "associate", "00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-000000000002"]]),
        command("Networking", ["dns", "status"], ["val dns status", "val dns status --json"], "Show local DNS capability state.", examples: ["val dns status"], parses: [["dns", "status"], ["dns", "status", "--json"]]),
        command("Networking", ["dns", "install"], ["val dns install", "val dns install --takeover"], "Install local DNS; takeover must be explicitly requested.", examples: ["val dns install --takeover"], parses: [["dns", "install"], ["dns", "install", "--takeover"]]),
        command("Networking", ["dns", "remove"], ["val dns remove"], "Remove Vaelen-managed local DNS configuration.", examples: ["val dns remove"], parses: [["dns", "remove"]]),
        command("Networking", ["tls", "status"], ["val tls status", "val tls status --json"], "Show local certificate authority and HTTPS trust state.", examples: ["val tls status"], parses: [["tls", "status"], ["tls", "status", "--json"]]),
        command("Networking", ["tls", "install"], ["val tls install"], "Install the local certificate authority.", examples: ["val tls install"], parses: [["tls", "install"]]),
        command("Networking", ["tls", "remove"], ["val tls remove"], "Remove the local certificate authority.", examples: ["val tls remove"], parses: [["tls", "remove"]]),
        command("Networking", ["tls", "trust"], ["val tls trust"], "Trust the local certificate authority in Keychain.", examples: ["val tls trust"], parses: [["tls", "trust"]]),
        command("Networking", ["tls", "untrust"], ["val tls untrust"], "Remove local certificate authority trust.", examples: ["val tls untrust"], parses: [["tls", "untrust"]]),
        command("Networking", ["ports", "status"], ["val ports status", "val ports status --json"], "Show standard local port forwarding state.", examples: ["val ports status"], parses: [["ports", "status"], ["ports", "status", "--json"]]),
        command("Networking", ["ports", "install"], ["val ports install"], "Install standard local port forwarding.", examples: ["val ports install"], parses: [["ports", "install"]]),
        command("Networking", ["ports", "remove"], ["val ports remove"], "Remove standard local port forwarding.", examples: ["val ports remove"], parses: [["ports", "remove"]]),
        command("Integration", ["shell", "status"], ["val shell status"], "Show current PHP shell integration status.", examples: ["val shell status"], parses: [["shell", "status"]]),
        command("Integration", ["shell", "install"], ["val shell install"], "Install Vaelen PHP shell integration in the user's shell configuration.", examples: ["val shell install"], parses: [["shell", "install"]]),
        command("Integration", ["shell", "uninstall"], ["val shell uninstall"], "Remove Vaelen PHP shell integration from the user's shell configuration.", examples: ["val shell uninstall"], parses: [["shell", "uninstall"]])
    ]

    static func text(for path: [String], width: Int = HumanOutput.terminalWidth) -> String {
        let width = max(40, width)
        if path.isEmpty || path == ["help"] {
            return overview(width: width)
        }
        if path == ["list"] {
            return completeCatalog(width: width)
        }
        if path.count == 1, let rows = groupOverviews[path[0]] {
            let name = ["php": "PHP", "mysql": "MySQL"][path[0]] ?? path[0].capitalized
            return overview(title: "\(name) commands", sections: [(name, rows)], width: width, footer: "Run “val list” for every command and invocation form; run “val \(path[0]) <command> --help” for details.")
        }
        if path.count == 1, let root = entries.first(where: { $0.path == path }) {
            let children = entries.filter { $0.path.first == path[0] && $0.path.count > 1 }
            if !children.isEmpty {
                let overviewRows = children.map { entry in (entry.path.dropFirst().joined(separator: " "), entry.summary) }
                return overview(title: "\(root.path[0].capitalized) commands", sections: [(root.path[0].capitalized, overviewRows)], width: width, footer: "Run “val list” for every command and invocation form; run “val \(path[0]) <command> --help” for details.")
            }
        }
        guard let entry = entries.first(where: { $0.path == path }) else {
            return "No focused help for ‘val \(path.joined(separator: " "))’. Run “val list” to see available commands.\n"
        }
        var lines = [HumanOutput.heading("Usage:")]
        lines += entry.forms.map { HumanOutput.semantic("  \($0)", tint: 36) }
        lines += ["", entry.summary]
        lines += entry.notes.flatMap { note in ["", note] }
        if !entry.examples.isEmpty {
            lines += ["", HumanOutput.heading(entry.examples.count == 1 ? "Example:" : "Examples:")]
            lines += entry.examples.map { HumanOutput.semantic("  \($0)", tint: 36) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func focusedText(for arguments: [String], width: Int = HumanOutput.terminalWidth) -> String {
        let normalized = arguments.enumerated().map { index, component in
            guard index == 0 else { return component }
            return ["paths": "parks", "-V": "--version"][component] ?? component
        }
        let path = entries.map(\.path)
            .filter { !$0.isEmpty && normalized.starts(with: $0) }
            .max { $0.count < $1.count } ?? normalized
        return text(for: path, width: width)
    }

    private static func overview(width: Int) -> String {
        overview(title: "Vaelen CLI", sections: overviewCommands, width: width, footer: "Run val list for every command.")
    }

    private static func overview(title: String, sections: [(String, [(String, String)])], width: Int, footer: String) -> String {
        var lines = [HumanOutput.heading(title), ""]
        for (heading, commands) in sections {
            if sections.count > 1 { lines.append(HumanOutput.heading(heading)) }
            lines.append(HumanOutput.commandList(commands, width: width))
            lines.append("")
        }
        lines += HumanOutput.wrap(footer, width: width).components(separatedBy: "\n")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func completeCatalog(width: Int) -> String {
        var lines = HumanOutput.wrap(HumanOutput.heading("Vaelen CLI — complete reference"), width: max(1, width - 2)).components(separatedBy: "\n")
        lines += ["", "Usage: val list", ""]
        lines += HumanOutput.wrap("Run val <command> --help for detailed options and examples.", width: max(1, width - 2)).components(separatedBy: "\n")
        lines.append("")
        for group in groups {
            let groupEntries = entries.filter { $0.group == group }
            guard !groupEntries.isEmpty else { continue }
            lines.append(HumanOutput.heading(group))
            let direct = groupEntries.filter { $0.path.count == 1 }
            if !direct.isEmpty {
                lines += renderCatalogRows(direct, width: width)
            }
            let roots = groupEntries.map { $0.path.first ?? "" }.reduce(into: [String]()) { result, root in
                if !result.contains(root) { result.append(root) }
            }
            for root in roots {
                let rootEntries = groupEntries.filter { ($0.path.first ?? "") == root }
                let nested = rootEntries.filter { $0.path.count > 1 }
                if !nested.isEmpty {
                    lines.append(HumanOutput.heading("  \(root) subcommands"))
                    lines += renderCatalogRows(nested, width: width)
                }
            }
            lines.append("")
        }
        lines += HumanOutput.wrap("Run val <command> --help for detailed options and examples.", width: max(1, width - 2)).components(separatedBy: "\n")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func renderCatalogRows(_ entries: [CLIHelpEntry], width: Int) -> [String] {
        guard !entries.isEmpty else { return [] }
        let rows = entries.map { [$0.forms.joined(separator: "  ·  "), $0.summary] }
        return HumanOutput.commandList(rows.map { ($0[0], $0[1]) }, width: width).components(separatedBy: "\n")
    }
}
