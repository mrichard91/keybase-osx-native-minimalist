/// Describes the selected trust/storage boundary without implying that this
/// project's reduced backend is an official Keybase-signed distribution.
enum BackendPresentation: Equatable {
    case bundled
    case compatibility
    case unselected

    var accountHeading: String {
        self == .compatibility ? "KEYBASE / COMPATIBILITY" : "KEYBASE / MINIMAL"
    }

    var connectionMessage: String {
        switch self {
        case .bundled: return "Connecting to this app's minimal service..."
        case .compatibility: return "Connecting to the installed Keybase service..."
        case .unselected: return "Locating the Keybase service..."
        }
    }

    var setupSteps: String {
        switch self {
        case .bundled:
            return "1. Click Start service.\n2. Choose Account..., then Log in / provision. Use your existing Keybase account and authorize this app as a new device.\n3. Click Connect to load your direct messages and groups.\n\nThe official Keybase app does not need to be installed. This app keeps its own account data and device credentials."
        case .compatibility:
            return "1. Click Start service if your installed Keybase service is not running.\n2. Choose Account... if you need to log in or provision a device.\n3. Click Connect to load your direct messages and groups.\n\nCOMPATIBILITY MODE\nThis uses the installed, official Keybase service and its shared local account. That service retains its broader feature set; this window displays only text."
        case .unselected:
            return "Click Connect to check the available backend. A packaged build includes its own minimal service and works without the official Keybase app. A development build can use an installed official Keybase service in compatibility mode."
        }
    }

    var accountExplanation: String {
        switch self {
        case .bundled:
            return "Use your existing Keybase account and authorize this app as a new device through Keybase's login and provisioning flow. The bundled service uses official Keybase account and encryption code with a minimalist patch. This app has separate account storage and device credentials from the official app. Start service first if it is not running."
        case .compatibility:
            return "Use the installed Keybase client's login and provisioning flow in a native text window. Passwords and paper keys go directly to that process. Login, provisioning, and sign-out affect the shared installed Keybase service. Start service first if it is not running."
        case .unselected:
            return "Connect first to check the available backend, then use Account... to log in or provision your existing Keybase account."
        }
    }

    var aboutExplanation: String {
        let storage: String
        switch self {
        case .bundled:
            storage = "This build uses its bundled minimal service, with separate account storage and device credentials. Media features and link previews are disabled in that backend."
        case .compatibility:
            storage = "This build is using an installed, officially signed Keybase service in compatibility mode. Its local account is shared with other clients, and disabling link previews changes that shared service's preference."
        case .unselected:
            storage = "Packaged builds include a minimal backend. Development builds can use an installed official Keybase service in compatibility mode."
        }
        return "A native, ASCII text chat client for Keybase accounts.\n\nThe minimal backend uses official Keybase account and encryption source with features removed. It is built by this independent project, not distributed or signed by Keybase. This project has not undergone a security audit.\n\n" + storage + "\n\nMessages and drafts stay in memory in this window. The backend maintains its own local storage."
    }

    func connectedMessage(account: String) -> String {
        switch self {
        case .bundled:
            return "Connected as @\(account). This app's separate service has media and link previews disabled."
        case .compatibility:
            return "Connected as @\(account) in compatibility mode. Link previews are disabled in the shared installed Keybase service."
        case .unselected:
            return "Connected as @\(account)."
        }
    }
}
